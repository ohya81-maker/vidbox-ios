import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// 앱 전체에서 하나만 존재하는 플레이어.
/// - 백그라운드/화면 꺼짐: AVAudioSession(.playback) + UIBackgroundModes(audio)
///   + 백그라운드 진입 시 AVPlayerLayer에서 플레이어를 떼어내어 영상 트랙 때문에 멈추지 않게 함
/// - 잠금화면/제어센터: MPNowPlayingInfoCenter + MPRemoteCommandCenter
/// - 재생목록(queue): 음악 탭처럼 목록을 넘겨주면 그 순서대로, 없으면 추천 영상 순서로 다음 곡 재생
/// 재생 위치만 알려주는 작은 객체 (재생 막대·시간 표시만 지켜본다)
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var current: VideoItem?
    @Published private(set) var isPlaying = false {
        didSet { if oldValue != isPlaying { ScreenAwake.main = isPlaying && !audioOnly } }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 재생 위치는 0.5초마다 바뀌므로 따로 둔다 — 여기(PlayerManager)에 두면 이것을 지켜보는
    /// 모든 화면(탭 전체, 영상 카드들)이 0.5초마다 다시 그려져 스크롤·버튼이 버벅인다
    let clock = PlaybackClock()
    private(set) var currentTime: Double {
        get { clock.time }
        set { clock.time = newValue }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var related: [VideoItem] = []
    /// 지금 영상의 채널(구독)·댓글 정보
    @Published private(set) var watchInfo: WatchInfo?
    @Published private(set) var commentsPreview: CommentPage?
    /// 추천 영상 다음 페이지 (YouTube처럼 아래로 내리면 끝없이 이어짐)
    private var relatedToken: String?
    private var relatedLoading = false
    @Published private(set) var queue: [VideoItem] = []
    /// 현재 재생 중인 스트림이 오디오 전용인지
    @Published private(set) var audioOnly = false {
        didSet {
            if oldValue != audioOnly { updateRotationPolicy() }
            ScreenAwake.main = isPlaying && !audioOnly
        }
    }
    @Published var isExpanded = false {
        didSet {
            if !isExpanded && isFullscreen { setFullscreen(false) }
            if oldValue != isExpanded { updateRotationPolicy() }
            // 하단 재생 막대를 끈 상태에서 재생 화면을 내리면 재생을 끝낸다
            if oldValue && !isExpanded && !miniPlayerEnabled && current != nil { stop() }
        }
    }
    /// 재생 화면을 내렸을 때 하단 재생 막대로 계속 재생할지 (보관함 설정, 기본 꺼짐)
    @Published var miniPlayerEnabled: Bool = {
        PlayerManager.applyDefaultsOnce()
        return UserDefaults.standard.bool(forKey: "miniPlayer")
    }() {
        didSet { UserDefaults.standard.set(miniPlayerEnabled, forKey: "miniPlayer") }
    }
    @Published private(set) var isFullscreen = false
    /// 음악 플레이어에서 「동영상」을 고른 상태 — 음악 플레이어 화면 그대로 앨범아트 자리에 영상
    @Published var musicVideoMode = false
    @Published var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    /// 새 영상을 열 때 기본으로 오디오 전용으로 재생할지 (보관함 설정)
    @Published var audioOnlyPreference: Bool = UserDefaults.standard.bool(forKey: "audioOnly") {
        didSet { UserDefaults.standard.set(audioOnlyPreference, forKey: "audioOnly") }
    }

    let player = AVPlayer()

    /// 기본 설정 (설치·업데이트 후 한 번): 화면 내려도 하단 재생 막대로 계속 재생 켬, 다음 동영상 자동재생 끔.
    /// 그 뒤 사용자가 바꾼 값은 그대로 둔다.
    nonisolated static func applyDefaultsOnce() {
        let d = UserDefaults.standard
        guard d.integer(forKey: "defaultsVersion") < 2 else { return }
        d.set(true, forKey: "miniPlayer")
        d.set(false, forKey: "autoplay")
        d.set(2, forKey: "defaultsVersion")
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    /// 영상의 가로/세로 비율 (세로 직캠이면 1보다 작음). 재생 화면 높이를 정할 때 쓴다.
    @Published private(set) var videoAspect: CGFloat = 16 / 9
    private var rateObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var artwork: MPMediaItemArtwork?
    private var isInBackground = false
    private var backgroundedAt: Date?
    private let layers = NSHashTable<AVPlayerLayer>.weakObjects()
    // 재생 후보와 자동 전환(감시 장치)
    private var candidates: [PlaybackSource] = []
    private var candidateIndex = 0
    private var usedSlowPath = false
    private var watchdog: Task<Void, Never>?
    private var userPaused = false
    private var seekWatchdog: Task<Void, Never>?
    private var seekGeneration = 0
    private var seekRecoveryKey: String?
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
            if audio { musicVideoMode = false }
        } else if !continuingQueue {
            audioOnly = audioOnlyPreference
            musicVideoMode = false
        }

        loadTask?.cancel()
        current = item
        if audioOnly { MusicTaste.record(item) }
        if newQueue != nil || !continuingQueue { rebuildOrder() }
        isLoading = true
        errorMessage = nil
        related = []
        currentTime = 0
        videoAspect = 16 / 9
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

        relatedToken = nil
        relatedLoading = true
        watchInfo = nil
        commentsPreview = nil
        Task { [weak self] in
            let result = try? await InnerTubeClient.shared.relatedWithInfo(videoID: item.id)
            guard let self, self.current?.id == item.id else { return }
            let page = result?.0
            self.related = page?.items ?? []
            self.relatedToken = page?.continuation
            self.relatedLoading = false
            self.watchInfo = result?.1
            self.prefetchNext()
            if let token = result?.1?.commentsToken,
               let comments = try? await InnerTubeClient.shared.comments(token),
               self.current?.id == item.id {
                self.commentsPreview = comments
            }
        }
    }

    /// 추천 목록 끝에 가까워지면 다음 페이지를 붙인다. 이어받을 페이지가 없으면 마지막 영상들의 추천으로 계속 채운다.
    func loadMoreRelatedIfNeeded(current item: VideoItem) {
        guard !relatedLoading, let playing = current,
              let index = related.firstIndex(where: { $0.id == item.id }),
              index >= related.count - 5
        else { return }
        relatedLoading = true
        let token = relatedToken
        let seed = related.suffix(8).randomElement()?.id ?? playing.id
        Task { [weak self] in
            var page: FeedPage?
            if let token { page = try? await InnerTubeClient.shared.relatedContinuation(token) }
            var fromSeed = false
            if (page?.items.isEmpty ?? true) {
                page = try? await InnerTubeClient.shared.related(videoID: seed)
                fromSeed = true
            }
            guard let self, self.current?.id == playing.id else { return }
            self.relatedLoading = false
            guard let page else { return }
            let known = Set(self.related.map(\.id)).union([playing.id])
            self.related.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.relatedToken = page.continuation ?? (fromSeed ? nil : self.relatedToken)
        }
    }

    /// 지금 채널을 구독/취소. 로그인했으면 YouTube 계정에, 아니면 이 기기에 저장
    var isSubscribedToCurrent: Bool {
        guard let info = watchInfo else { return false }
        return info.subscribed ?? SubscriptionStore.shared.isSubscribed(info.channelID)
    }

    func toggleSubscribe() {
        guard let info = watchInfo else { return }
        let channel = SubscribedChannel(id: info.channelID, name: info.channelName, avatar: info.channelAvatar)
        setSubscribed(channel, !isSubscribedToCurrent)
    }

    /// 아무 채널이나 구독/취소 (채널 화면에서도 사용). 지금 영상의 채널이면 재생 화면 버튼도 같이 바뀐다
    func isSubscribed(_ channelID: String) -> Bool {
        if let info = watchInfo, info.channelID == channelID, let on = info.subscribed { return on }
        return SubscriptionStore.shared.isSubscribed(channelID)
    }

    func setSubscribed(_ channel: SubscribedChannel, _ on: Bool) {
        SubscriptionStore.shared.set(channel, subscribed: on)
        if AuthStore.shared.isLoggedIn {
            Task { try? await InnerTubeClient.shared.setSubscribed(channel.id, on) }
        }
        if var info = watchInfo, info.channelID == channel.id, info.subscribed != nil {
            info.subscribed = on
            watchInfo = info
        } else {
            objectWillChange.send()
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
        // 재생을 눌렀는데 시간이 흐르지 않으면(끊긴 스트림) 같은 위치에서 다시 불러온다
        let now = player.currentTime().seconds
        seekGeneration += 1
        armSeekWatchdog(target: now.isFinite ? now : currentTime, generation: seekGeneration)
    }

    func pause() {
        userPaused = true
        player.pause()
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        currentTime = target
        seekGeneration += 1
        let generation = seekGeneration
        let shouldPlay = !userPaused
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.updateNowPlaying()
                // 이동이 끝나면 재생 상태를 확실히 되살린다
                if finished, shouldPlay, self.seekGeneration == generation { self.player.play() }
            }
        }
        armSeekWatchdog(target: target, generation: generation)
    }

    /// 이동 후 6초가 지나도 재생 시간이 앞으로 가지 않으면: 같은 방식으로 그 위치에서 다시 불러오기 → 그래도 안 되면 다른 방식으로
    private func armSeekWatchdog(target: Double, generation: Int) {
        seekWatchdog?.cancel()
        guard !userPaused, let item = current else { return }
        seekWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.seekGeneration == generation,
                  self.current?.id == item.id, !self.userPaused else { return }
            let now = self.player.currentTime().seconds
            if now.isFinite, now > target + 0.3 { return }

            let key = "\(item.id)@\(Int(target))"
            if self.seekRecoveryKey == key {
                self.failover(item: item)
                return
            }
            self.seekRecoveryKey = key
            guard self.candidateIndex < self.candidates.count,
                  let fresh = try? await StreamResolver.makeItem(self.candidates[self.candidateIndex]),
                  self.current?.id == item.id
            else {
                self.failover(item: item)
                return
            }
            self.startPlayback(fresh, seekTo: target)
            self.seekGeneration += 1
            self.armSeekWatchdog(target: target, generation: self.seekGeneration)
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
        seekWatchdog?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        related = []
        relatedToken = nil
        watchInfo = nil
        commentsPreview = nil
        queue = []
        playOrder = []
        isExpanded = false
        errorMessage = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 전체화면 버튼: 화면을 가로/세로로 돌린다
    func setFullscreen(_ on: Bool) {
        guard on != isFullscreen else { return }
        isFullscreen = on
        OrientationController.rotate(to: on ? .landscapeRight : .portrait)
    }

    /// 사용자가 폰을 직접 돌렸을 때 (가로 = 전체화면, 세로 = 일반)
    func deviceRotated(landscape: Bool) {
        if isFullscreen != landscape { isFullscreen = landscape }
    }

    /// 영상 플레이어가 펼쳐져 있을 때만 가로 회전을 허용 (목록 화면·음악 플레이어는 세로 고정)
    private func updateRotationPolicy() {
        let allow = isExpanded && !audioOnly
        OrientationController.allowRotation(allow)
        if !allow, isFullscreen { isFullscreen = false }
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

    /// 재생 시작 9초 뒤에도 시간이 흐르지 않으면 다음 후보로 전환
    private func armWatchdog(item: VideoItem, position: Double, autoPlay: Bool) {
        watchdog?.cancel()
        guard autoPlay else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
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

        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] observed, _ in
            let size = observed.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor in self?.videoAspect = size.width / size.height }
        }

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
                    // 재생기가 길이를 실제보다 길게(예: 2배) 계산하면 YouTube가 알려준 길이로 바로잡는다
                    if let id = self.current?.id {
                        Task { @MainActor in
                            if let real = await StreamResolver.shared.length(id: id), real > 0,
                               self.current?.id == id, self.duration > real * 1.3 {
                                self.duration = real
                                self.updateNowPlaying()
                            }
                        }
                    }
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
        backgroundedAt = Date()
        let wasPlaying = player.timeControlStatus != .paused
        for layer in layers.allObjects { layer.player = nil }
        if wasPlaying { player.play() }
    }

    private func enterForeground() {
        isInBackground = false
        for layer in layers.allObjects { layer.player = player }
        guard let item = current, !audioOnly || player.currentItem == nil else { return }
        let away = Date().timeIntervalSince(backgroundedAt ?? Date())
        let playing = player.timeControlStatus != .paused
        let broken = player.currentItem == nil || player.currentItem?.status == .failed
        // 멈춘 채로 오래 나가 있으면 앱 안의 재생 중계(127.0.0.1)가 iOS에 의해 끊겨 화면이 검게 남는다
        // → 같은 위치에서 새로 불러온다 (자동 재생은 하지 않음)
        if broken || (!playing && away > 15) {
            let position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime
            Task { [weak self] in
                if away > 1800 { await StreamResolver.shared.invalidate(item.id) }
                guard let self, self.current?.id == item.id else { return }
                self.beginLoading(item: item, audio: self.audioOnly, position: position, autoPlay: false)
            }
        } else if !playing {
            // 화면을 다시 붙인 직후 멈춘 영상이 검게 보이지 않도록 같은 위치로 한 번 이동해 프레임을 다시 그린다
            player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
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
        Task { [weak self] in
            // 잠금화면·제어센터 표지도 고화질로
            guard let image = await ArtworkLoader.shared.image(for: item) else { return }
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
    /// 회전 허용 여부. 허용하지 않으면 세로로 되돌린다.
    static func allowRotation(_ allow: Bool) {
        AppDelegate.orientationLock = allow ? .allButUpsideDown : .portrait
        refresh()
        if !allow { request(.portrait) }
    }

    /// 특정 방향으로 돌린다 (전체화면 버튼)
    static func rotate(to mask: UIInterfaceOrientationMask) {
        if !AppDelegate.orientationLock.contains(mask) {
            AppDelegate.orientationLock = .allButUpsideDown
        }
        refresh()
        request(mask)
    }

    private static func refresh() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var controller = window.rootViewController
                while let vc = controller {
                    vc.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = vc.presentedViewController
                }
            }
        }
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

/// 영상이 재생되는 동안 화면이 꺼지지 않게 한다 (일반 재생 + 쇼츠)
@MainActor
enum ScreenAwake {
    static var main = false { didSet { apply() } }
    static var shorts = false { didSet { apply() } }
    private static func apply() {
        let on = main || shorts
        if UIApplication.shared.isIdleTimerDisabled != on { UIApplication.shared.isIdleTimerDisabled = on }
    }
}
