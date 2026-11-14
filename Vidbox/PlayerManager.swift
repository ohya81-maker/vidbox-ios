import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import YouTubeKit

/// 앱 전체에서 하나만 존재하는 플레이어.
/// - 백그라운드/화면 꺼짐: AVAudioSession(.playback) + UIBackgroundModes(audio)
///   + 백그라운드 진입 시 AVPlayerLayer에서 플레이어를 떼어내어 영상 트랙 때문에 멈추지 않게 함
/// - 잠금화면/제어센터: MPNowPlayingInfoCenter + MPRemoteCommandCenter
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var current: VideoItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var related: [VideoItem] = []
    @Published var isExpanded = false
    @Published var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    @Published private(set) var audioOnly: Bool = UserDefaults.standard.bool(forKey: "audioOnly")

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var isInBackground = false
    private let layers = NSHashTable<AVPlayerLayer>.weakObjects()

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        observeAppLifecycle()
    }

    // MARK: - Public controls

    func play(_ item: VideoItem, expand: Bool = true) {
        loadTask?.cancel()
        current = item
        isLoading = true
        errorMessage = nil
        related = []
        currentTime = 0
        duration = 0
        artwork = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if expand { isExpanded = true }
        LibraryStore.shared.addHistory(item)
        updateNowPlaying()
        loadArtwork(for: item)

        let audioOnly = self.audioOnly
        loadTask = Task { [weak self] in
            do {
                let url = try await Self.resolveStreamURL(id: item.id, audioOnly: audioOnly)
                guard !Task.isCancelled, let self, self.current?.id == item.id else { return }
                self.startPlayback(url: url, seekTo: 0)
            } catch {
                guard !Task.isCancelled, let self, self.current?.id == item.id else { return }
                self.isLoading = false
                self.errorMessage = "재생할 수 없는 영상입니다.\n\(error.localizedDescription)"
            }
        }

        Task { [weak self] in
            let list = (try? await InnerTubeClient.shared.related(videoID: item.id)) ?? []
            guard let self, self.current?.id == item.id else { return }
            self.related = list
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard player.currentItem != nil else {
            if let current { play(current, expand: false) }
            return
        }
        activateAudioSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func skip(by delta: Double) {
        seek(to: player.currentTime().seconds + delta)
    }

    func playNext() {
        guard let next = related.first else { return }
        play(next, expand: false)
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        related = []
        isExpanded = false
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setAudioOnly(_ value: Bool) {
        guard value != audioOnly else { return }
        audioOnly = value
        UserDefaults.standard.set(value, forKey: "audioOnly")
        guard let item = current else { return }

        // 같은 위치에서 다른 스트림(영상 ↔ 오디오)으로 갈아탄다.
        let position = player.currentTime().seconds
        let wasPlaying = isPlaying || player.currentItem == nil
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let url = try await Self.resolveStreamURL(id: item.id, audioOnly: value)
                guard !Task.isCancelled, let self, self.current?.id == item.id else { return }
                self.startPlayback(url: url, seekTo: position.isFinite ? position : 0, autoPlay: wasPlaying)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 영상 화면(AVPlayerLayer)을 등록한다. 백그라운드에서는 자동으로 분리된다.
    func register(_ layer: AVPlayerLayer) {
        layers.add(layer)
        layer.player = isInBackground ? nil : player
    }

    // MARK: - Stream resolving

    nonisolated private static func resolveStreamURL(id: String, audioOnly: Bool) async throws -> URL {
        let video = YouTube(videoID: id, methods: [.local, .remote])
        let streams = try await video.streams

        let audio = streams
            .filterAudioOnly()
            .filter { $0.fileExtension == .m4a }
            .highestAudioBitrateStream()

        if audioOnly, let audio { return audio.url }

        if let muxed = streams
            .filterVideoAndAudio()
            .filter({ $0.isNativelyPlayable })
            .highestResolutionStream() {
            return muxed.url
        }

        if let audio { return audio.url }
        throw AppError.noPlayableStream
    }

    // MARK: - Playback internals

    private func startPlayback(url: URL, seekTo position: Double, autoPlay: Bool = true) {
        activateAudioSession()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let seconds = observed.duration.seconds
            let message = observed.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    self.duration = seconds.isFinite ? seconds : 0
                    self.updateNowPlaying()
                case .failed:
                    self.isLoading = false
                    self.errorMessage = message ?? "재생에 실패했습니다."
                default:
                    break
                }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }

        player.replaceCurrentItem(with: item)
        if position > 1 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        if autoPlay { player.play() }
        updateNowPlaying()
    }

    private func handleEnded() {
        if autoplay, let next = related.first {
            play(next, expand: false)
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
            }
        }

        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - Background handling

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                if type == .ended,
                   AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                    self.resume()
                }
            }
        }
    }

    private func enterBackground() {
        isInBackground = true
        let wasPlaying = player.timeControlStatus != .paused
        for layer in layers.allObjects { layer.player = nil }
        if wasPlaying { player.play() }
    }

    private func enterForeground() {
        isInBackground = false
        for layer in layers.allObjects { layer.player = player }
    }

    // MARK: - Audio session & Now Playing

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.playNext() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 10) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -10) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for item: VideoItem) {
        let url = item.bestThumbnail
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let art = Self.makeArtwork(image)
            guard let self, self.current?.id == item.id else { return }
            self.artwork = art
            self.updateNowPlaying()
        }
    }

    /// MPMediaItemArtwork의 클로저는 백그라운드 스레드에서 호출되므로 MainActor 밖에서 만든다.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
