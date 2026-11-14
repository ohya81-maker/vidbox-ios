import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 앱 전체에서 하나만 존재하는 플레이어.
/// - 백그라운드/화면 꺼짐: AVAudioSession(.playback) + UIBackgroundModes(audio)
///   + 백그라운드 진입 시 AVPlayerLayer에서 플레이어를 떼어내어 영상 트랙 때문에 멈추지 않게 함
/// - 잠금화면/제어센터: MPNowPlayingInfoCenter + MPRemoteCommandCenter
/// - 재생목록(queue): 음악 탭처럼 목록을 넘겨주면 그 순서대로, 없으면 추천 영상 순서로 다음 곡 재생
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
    @Published private(set) var queue: [VideoItem] = []
    /// 현재 재생 중인 스트림이 오디오 전용인지
    @Published private(set) var audioOnly = false
    @Published var isExpanded = false {
        didSet { if !isExpanded && isFullscreen { setFullscreen(false) } }
    }
    @Published private(set) var isFullscreen = false
    @Published var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    /// 새 영상을 열 때 기본으로 오디오 전용으로 재생할지 (보관함 설정)
    @Published var audioOnlyPreference: Bool = UserDefaults.standard.bool(forKey: "audioOnly") {
        didSet { UserDefaults.standard.set(audioOnlyPreference, forKey: "audioOnly") }
    }

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var isInBackground = false
    private let layers = NSHashTable<AVPlayerLayer>.weakObjects()
    // 재생 후보와 자동 전환(감시 장치)
    private var candidates: [PlaybackSource] = []
    private var candidateIndex = 0
    private var usedSlowPath = false
    private var watchdog: Task<Void, Never>?
    private var userPaused = false
    /// 지금 재생 중인 방식 (진단용)
    @Published private(set) var sourceKind = ""

    enum RepeatMode { case off, all, one }

    /// 음악 재생 도구
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    /// 실제 재생 순서 (무작위가 켜지면 섞인 순서)
    @Published private(set) var playOrder: [VideoItem] = []

    /// 재생목록이 있으면 그 다음 곡들(전체 반복이면 처음으로 이어짐), 없으면 추천 영상
    var upNext: [VideoItem] {
        if let current, let index = playOrder.firstIndex(where: { $0.id == current.id }) {
            var next = Array(playOrder.dropFirst(index + 1))
            if repeatMode == .all { next += playOrder.prefix(index) }
            return next
        }
        return related
    }

    var isQueueMode: Bool { !queue.isEmpty }

    func toggleShuffle() {
        shuffle.toggle()
        rebuildOrder()
        prefetchNext()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func rebuildOrder() {
        guard !queue.isEmpty else { playOrder = []; return }
        if shuffle {
            var rest = queue.filter { $0.id != current?.id }.shuffled()
            if let current, queue.contains(where: { $0.id == current.id }) { rest.insert(current, at: 0) }
            playOrder = rest
        } else {
            playOrder = queue
        }
    }

    private init() {
        // 이전 버전이 저장한 "안 되는 방식" 기록 삭제 (오디오만 재생되는 문제의 원인)
        UserDefaults.standard.removeObject(forKey: "brokenSourceKinds")
        // 주의: false로 두면 HLS가 '재생 중' 상태로 0초에 멈춘다 (CI에서 확인). 기본값(true) 유지.
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        observeAppLifecycle()
    }

    // MARK: - Public controls

    func play(_ item: VideoItem, queue newQueue: [VideoItem]? = nil, audio: Bool? = nil, expand: Bool = true) {
        let continuingQueue = newQueue == nil && queue.contains { $0.id == item.id }
        if let newQueue {
            queue = newQueue
        } else if !continuingQueue {
            queue = []
        }
        if let audio {
            audioOnly = audio
        } else if !continuingQueue {
            audioOnly = audioOnlyPreference
        }

        loadTask?.cancel()
        current = item
        if newQueue != nil || !continuingQueue { rebuildOrder() }
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

        userPaused = false
        beginLoading(item: item, audio: audioOnly, position: 0, autoPlay: true)
        AccountStore.shared.markWatched(item.id)

        Task { [weak self] in
            let list = (try? await InnerTubeClient.shared.related(videoID: item.id)) ?? []
            guard let self, self.current?.id == item.id else { return }
            self.related = list
            self.prefetchNext()
        }
    }

    func retry() {
        guard let item = current else { return }
        Task {
            await StreamResolver.shared.invalidate(item.id)
            play(item, audio: audioOnly, expand: false)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        userPaused = false
        guard player.currentItem != nil else {
            if let current { play(current, audio: audioOnly, expand: false) }
            return
        }
        activateAudioSession()
        player.play()
    }

    func pause() {
        userPaused = true
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func skip(by delta: Double) {
        let now = player.currentTime().seconds
        seek(to: (now.isFinite ? now : currentTime) + delta)
    }

    func playNext() {
        guard let next = upNext.first else { return }
        play(next, expand: false)
    }

    func playPrevious() {
        if currentTime > 5 { seek(to: 0); return }
        guard let current, let index = playOrder.firstIndex(where: { $0.id == current.id }) else {
            seek(to: 0)
            return
        }
        if index > 0 {
            play(playOrder[index - 1], expand: false)
        } else if repeatMode == .all, let last = playOrder.last {
            play(last, expand: false)
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        loadTask?.cancel()
        watchdog?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        related = []
        queue = []
        playOrder = []
        isExpanded = false
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setFullscreen(_ on: Bool) {
        guard on != isFullscreen else { return }
        isFullscreen = on
        OrientationController.set(landscape: on)
    }

    /// 재생 중에 영상 ↔ 오디오 전용 스트림 전환 (같은 위치에서 이어서)
    func setAudioOnly(_ value: Bool) {
        guard value != audioOnly else { return }
        audioOnly = value
        guard let item = current else { return }

        let position = player.currentTime().seconds
        let wasPlaying = isPlaying || player.currentItem == nil
        beginLoading(item: item, audio: value, position: position.isFinite ? position : 0, autoPlay: wasPlaying)
    }

    /// 영상 화면(AVPlayerLayer)을 등록한다. 백그라운드에서는 자동으로 분리된다.
    func register(_ layer: AVPlayerLayer) {
        layers.add(layer)
        layer.player = isInBackground ? nil : player
    }

    // MARK: - Playback internals

    private func prefetchNext() {
        let ids = upNext.prefix(2).map(\.id)
        guard !ids.isEmpty else { return }
        Task { await StreamResolver.shared.prefetch(ids) }
    }

    /// 쇼츠 등 감시 장치 없이 쓰는 곳: 첫 번째로 만들어지는 후보
    nonisolated static func loadItem(id: String, audioOnly: Bool) async throws -> AVPlayerItem {
        for source in try await StreamResolver.shared.candidates(id: id, audioOnly: audioOnly) {
            if let item = try? await StreamResolver.makeItem(source) { return item }
        }
        throw AppError.noPlayableStream
    }

    // MARK: 후보를 차례로 시도 + 재생이 안 되면 자동 전환

    private func beginLoading(item: VideoItem, audio: Bool, position: Double, autoPlay: Bool) {
        loadTask?.cancel()
        watchdog?.cancel()
        candidates = []
        candidateIndex = 0
        usedSlowPath = false
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            do {
                let list = try await StreamResolver.shared.candidates(id: item.id, audioOnly: audio)
                guard !Task.isCancelled, let self, self.current?.id == item.id else { return }
                self.candidates = list
                await self.tryCandidates(item: item, position: position, autoPlay: autoPlay)
                self.prefetchNext()
            } catch {
                guard !Task.isCancelled, let self, self.current?.id == item.id else { return }
                await self.tryCandidates(item: item, position: position, autoPlay: autoPlay)
            }
        }
    }

    private func tryCandidates(item: VideoItem, position: Double, autoPlay: Bool) async {
        while candidateIndex < candidates.count {
            let source = candidates[candidateIndex]
            if let playerItem = try? await StreamResolver.makeItem(source) {
                guard !Task.isCancelled, current?.id == item.id else { return }
                sourceKind = source.kind
                startPlayback(playerItem, seekTo: position, autoPlay: autoPlay)
                armWatchdog(item: item, position: position, autoPlay: autoPlay)
                return
            }
            candidateIndex += 1
        }
        // 빠른 후보가 모두 실패 → YouTubeKit(느림)
        if !usedSlowPath {
            usedSlowPath = true
            if let slow = try? await StreamResolver.shared.slowCandidates(id: item.id, audioOnly: audioOnly),
               !Task.isCancelled, current?.id == item.id {
                candidates = slow
                candidateIndex = 0
                await tryCandidates(item: item, position: position, autoPlay: autoPlay)
                return
            }
        }
        guard current?.id == item.id else { return }
        isLoading = false
        errorMessage = "재생할 수 없는 영상입니다."
    }

    /// 재생 시작 5초 뒤에도 시간이 흐르지 않으면 다음 후보로 전환
    private func armWatchdog(item: VideoItem, position: Double, autoPlay: Bool) {
        watchdog?.cancel()
        guard autoPlay else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.current?.id == item.id, !self.userPaused else { return }
            let now = self.player.currentTime().seconds
            let kind = self.sourceKind
            if now.isFinite, now > position + 0.5 { return }
            _ = kind
            self.failover(item: item)
        }
    }

    private func failover(item: VideoItem) {
        guard current?.id == item.id else { return }
        watchdog?.cancel()
        let position = max(0, currentTime)
        candidateIndex += 1
        isLoading = true
        errorMessage = nil
        player.pause()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.tryCandidates(item: item, position: position, autoPlay: true)
        }
    }

    /// 플레이어 화면을 길게 누르면 보이는 진단 정보
    var diagnostics: String {
        let item = player.currentItem
        let buffered = item?.loadedTimeRanges.first.map { String(format: "%.1f", $0.timeRangeValue.duration.seconds) } ?? "0"
        let wait = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let log = item?.errorLog()?.events.last.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "-"
        let status: String
        switch player.timeControlStatus {
        case .paused: status = "일시정지"
        case .waitingToPlayAtSpecifiedRate: status = "대기중"
        case .playing: status = "재생중"
        @unknown default: status = "?"
        }
        return "방식: \(sourceKind) (\(candidateIndex + 1)/\(max(candidates.count, 1)))\n상태: \(status) / \(wait)\n버퍼: \(buffered)s · 시간: \(String(format: "%.1f", currentTime))s\n오류: \(log)"
    }

    private func startPlayback(_ item: AVPlayerItem, seekTo position: Double, autoPlay: Bool = true) {
        activateAudioSession()

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
                    // 이 방식이 실패하면 다음 후보로 자동 전환
                    _ = message
                    if let item = self.current { self.failover(item: item) }
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
        if repeatMode == .one {
            player.seek(to: .zero)
            player.play()
            return
        }
        if (autoplay || isQueueMode), let next = upNext.first {
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

    func activateAudioSession() {
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
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.playPrevious() }
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
        let elapsed = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
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

// MARK: - 화면 회전 (전체화면)

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

@MainActor
enum OrientationController {
    static func set(landscape: Bool) {
        AppDelegate.orientationLock = landscape ? .landscape : .portrait
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                while let vc = controller {
                    vc.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = vc.presentedViewController
                }
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        }
    }
}
