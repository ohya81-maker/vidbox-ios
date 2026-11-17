import AVFoundation
import SwiftUI

// MARK: - 쇼츠 목록

@MainActor
final class ShortsFeed: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var errorMessage: String?
    private var continuation: String?
    private var queryIndex = 0
    private var isLoading = false

    // 앱을 열 때마다 다른 주제로 시작하도록 순서를 섞는다
    private let queries = ["#shorts 인기", "#shorts 웃긴", "#shorts 음악", "#shorts 동물", "#shorts 게임",
                           "#shorts 요리", "#shorts 스포츠", "#shorts 댄스", "#shorts 브이로그", "#shorts 여행",
                           "#shorts 일상", "#shorts 먹방", "#shorts 챌린지", "#shorts 감동"].shuffled()

    // 이미 본 쇼츠는 다시 앞에 나오지 않게 (최근 500개 기억)
    private static let seenKey = "seenShorts.v1"
    private var seen: [String] = UserDefaults.standard.stringArray(forKey: ShortsFeed.seenKey) ?? []
    private lazy var seenSet = Set(seen)

    func markSeen(_ id: String) {
        guard !seenSet.contains(id) else { return }
        seenSet.insert(id)
        seen.append(id)
        if seen.count > 500 { seen.removeFirst(seen.count - 500); seenSet = Set(seen) }
        UserDefaults.standard.set(seen, forKey: Self.seenKey)
    }

    /// 홈의 Shorts 줄에서 고른 쇼츠들을 맨 앞에
    func prepend(_ list: [VideoItem]) {
        let ids = Set(list.map(\.id))
        items = list + items.filter { !ids.contains($0.id) }
    }

    func loadInitial() async {
        guard items.isEmpty else { return }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        for _ in 0..<3 {
            let query = queries[queryIndex % queries.count]
            do {
                let page = try await InnerTubeClient.shared.shorts(query, continuation: continuation)
                let known = Set(items.map(\.id))
                let fresh = page.items.filter { !known.contains($0.id) && !seenSet.contains($0.id) }.shuffled()
                items.append(contentsOf: fresh)
                if let next = page.continuation, !fresh.isEmpty {
                    continuation = next
                } else {
                    continuation = nil
                    queryIndex += 1
                }
                if !fresh.isEmpty { return }
            } catch {
                continuation = nil
                queryIndex += 1
                errorMessage = "쇼츠를 불러오지 못했습니다."
            }
        }
    }
}

// MARK: - 쇼츠 전용 플레이어 (반복 재생)
//
// 실제 YouTube 쇼츠 방식: 피드를 받을 때 다음 영상들의 재생 정보를 미리 받아 두고,
// 바로 다음 쇼츠는 '자기 화면에 붙은 플레이어'로 첫 몇 초를 미리 받아 첫 프레임까지 그려 둔다.
// 넘기면 이미 준비된 플레이어의 재생만 누르므로 기다림이 없다.
// (1.8.x의 깜빡임은 플레이어 하나의 화면을 대기 플레이어로 통째로 바꿔 끼워서였다 —
//  여기서는 쇼츠마다 화면과 플레이어가 짝으로 붙어 있어 바꿔 끼우는 일이 없다)
// 지금 쇼츠가 재생을 시작한 뒤에 다음 것을 받기 시작해 대역폭을 뺏지 않는다.

@MainActor
final class ShortsPlayer: ObservableObject {
    /// 쇼츠 한 편 = 플레이어 하나
    final class Slot {
        let id: String
        let player = AVPlayer()
        var candidates: [PlaybackSource] = []
        var candidateIndex = 0
        var loadTask: Task<Void, Never>?
        var endObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
        var itemObservation: NSKeyValueObservation?
        var failed = false
        // 시간 기록 (원인 분석용)
        let created = Date()
        var resolved: Date?
        var attached: Date?

        init(id: String) {
            self.id = id
            player.automaticallyWaitsToMinimizeStalling = true
            player.appliesMediaSelectionCriteriaAutomatically = false   // 자막 자동 표시 끔
            player.isMuted = true
            player.actionAtItemEnd = .none
        }

        func tearDown() {
            loadTask?.cancel()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            statusObservation = nil
            itemObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    @Published private(set) var isReady = false
    @Published private(set) var isPaused = false
    @Published private(set) var failed = false
    /// 준비가 0.4초 넘게 걸릴 때만 로딩 표시 (미리 받아 둔 쇼츠에서 동그라미가 번쩍이지 않게)
    @Published private(set) var showSpinner = false
    /// 플레이어가 붙은 쇼츠 목록 (바뀌면 각 페이지가 자기 플레이어를 다시 붙인다)
    @Published private(set) var slotIDs: [String] = []
    private(set) var currentID: String?
    private var slots: [String: Slot] = [:]
    private var upcoming: [String] = []
    private var watchdog: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?

    func player(for id: String) -> AVPlayer? { slots[id]?.player }

    private var restartObserver: NSObjectProtocol?

    init() {
        // 중계 서버가 새로 켜지면 예전 주소로 준비해 둔 쇼츠는 못 쓴다 → 모두 다시 준비
        restartObserver = NotificationCenter.default.addObserver(forName: LocalHLS.didRestart, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAll() }
        }
    }

    private func rebuildAll() {
        guard !slots.isEmpty else { return }
        for (_, slot) in slots { slot.tearDown() }
        slots.removeAll()
        if let id = currentID {
            isReady = false
            failed = false
            _ = makeSlot(id)
            armSpinner()
            armWatchdog(for: id)
        }
        publishSlots()
    }

    /// item을 재생. previous는 뒤로 넘길 때를 위해 남겨 두고, upcoming[0]은 첫 프레임까지 미리 받는다
    /// 넘긴 순간부터 재생 시작까지 걸린 시간을 NAS 진단 기록으로 (어디서 늦는지 보기 위해)
    private var playStarted = Date()
    private var startedPreloaded = false

    private func reportTiming(_ id: String) {
        guard let slot = slots[id] else { return }
        let total = Date().timeIntervalSince(playStarted)
        func since(_ d: Date?) -> String { d.map { String(format: "%.2f", $0.timeIntervalSince(slot.created)) } ?? "-" }
        let kind = slot.candidateIndex < slot.candidates.count ? slot.candidates[slot.candidateIndex].kind : "-"
        PlaybackDiag.report("shorts-timing", id: id, details: [
            String(format: "toPlay=%.2f", total), "preloaded=\(startedPreloaded)",
            "resolve=\(since(slot.resolved))", "attach=\(since(slot.attached))", "source=\(kind)#\(slot.candidateIndex)",
        ])
    }

    func play(_ item: VideoItem, previous: String?, upcoming next: [String]) {
        upcoming = next
        if currentID != item.id {
            playStarted = Date()
            startedPreloaded = slots[item.id]?.player.currentItem != nil
        }
        if currentID == item.id {
            resume()
            return
        }
        // 이전 쇼츠: 소리 끄고 처음으로 (뒤로 넘기면 바로 다시 나오게 남겨 둔다)
        if let old = currentID.flatMap({ slots[$0] }) {
            old.player.pause()
            old.player.isMuted = true
            old.player.seek(to: .zero)
        }
        currentID = item.id
        isPaused = false
        PlayerManager.shared.activateAudioSession()

        let slot = slots[item.id] ?? makeSlot(item.id)
        slot.player.isMuted = false
        isReady = slot.player.timeControlStatus == .playing
        failed = slot.failed
        if slot.player.currentItem != nil { slot.player.play() }

        // 앞뒤 하나씩만 남기고 정리 (메모리·디코더 절약)
        let keep = Set([previous, item.id, next.first].compactMap { $0 })
        for (id, s) in slots where !keep.contains(id) {
            s.tearDown()
            slots[id] = nil
        }
        publishSlots()

        armSpinner()
        armWatchdog(for: item.id)
        // 다음 쇼츠들의 재생 정보(주소)는 지금 바로 미리 받아 둔다 (가벼운 요청)
        Task { await StreamResolver.shared.prefetch(next) }
        // 바로 다음 쇼츠의 영상 데이터는 지금 쇼츠가 재생을 시작한 뒤(또는 1.5초 뒤)에
        preloadTask?.cancel()
        if isReady {
            preloadNext()
        } else {
            preloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.preloadNext()
            }
        }
    }

    private func preloadNext() {
        preloadTask?.cancel()
        guard let id = upcoming.first, slots[id] == nil else { return }
        _ = makeSlot(id)
        publishSlots()
    }

    private func publishSlots() {
        let ids = Array(slots.keys).sorted()
        if ids != slotIDs { slotIDs = ids }
    }

    private func makeSlot(_ id: String) -> Slot {
        let slot = Slot(id: id)
        slots[id] = slot
        slot.statusObservation = slot.player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor in
                guard let self, self.currentID == id else { return }
                ScreenAwake.shorts = playing
                guard playing else { return }
                if !self.isReady {
                    self.isReady = true
                    self.showSpinner = false
                    self.preloadNext()
                    self.reportTiming(id)
                }
            }
        }
        slot.loadTask = Task { [weak self] in
            guard let list = try? await StreamResolver.shared.candidates(id: id, audioOnly: false) else {
                guard !Task.isCancelled, let self else { return }
                PlaybackDiag.report("shorts-resolve", id: id, details: [])
                slot.failed = true
                if self.currentID == id { self.failed = true; self.showSpinner = false }
                return
            }
            guard !Task.isCancelled, let self else { return }
            slot.candidates = list
            slot.resolved = Date()
            await self.tryCandidate(slot, from: 0)
        }
        return slot
    }

    /// index번째 후보부터 재생 항목을 만들어 붙인다 (만들기에 실패하면 다음 후보)
    private func tryCandidate(_ slot: Slot, from index: Int) async {
        var i = index
        while i < slot.candidates.count {
            if let item = try? await StreamResolver.makeItem(slot.candidates[i]) {
                guard slots[slot.id] === slot else { return }
                slot.candidateIndex = i
                attach(item, to: slot)
                return
            }
            i += 1
        }
        guard slots[slot.id] === slot else { return }
        PlaybackDiag.report("shorts", id: slot.id, details: ["candidates=\(slot.candidates.map(\.kind))",
                                                              "last=" + PlaybackDiag.describe(slot.player.currentItem)])
        slot.failed = true
        if currentID == slot.id { failed = true; showSpinner = false }
    }

    private func attach(_ playerItem: AVPlayerItem, to slot: Slot) {
        slot.attached = Date()
        Self.tuneForQuickStart(playerItem)
        // 끝나면 처음으로 되감아 반복
        if let old = slot.endObserver { NotificationCenter.default.removeObserver(old) }
        let slotID = slot.id
        let slotPlayer = slot.player
        slot.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                slotPlayer.seek(to: .zero)
                if self?.currentID == slotID, self?.isPaused == false { slotPlayer.play() }
            }
        }
        // 미리 받는 쇼츠: 재생 준비가 되면 디코더까지 데워 둔다 (첫 프레임이 화면에 그려짐)
        slot.itemObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            // 이 재생 방식이 실패하면 3초를 기다리지 않고 바로 다음 방식으로
            if item.status == .failed {
                Task { @MainActor in
                    guard let self, let slot = self.slots[slotID], slot.player.currentItem === item else { return }
                    PlaybackDiag.note("shorts candidate failed fast: " + PlaybackDiag.describe(item))
                    LocalHLS.shared.healIfDead(item)
                    slot.player.replaceCurrentItem(with: nil)
                    await self.tryCandidate(slot, from: slot.candidateIndex + 1)
                }
                return
            }
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, self.currentID != slotID, slotPlayer.rate == 0,
                      slotPlayer.currentItem === item else { return }
                slotPlayer.preroll(atRate: 1) { _ in }
            }
        }
        slot.player.replaceCurrentItem(with: playerItem)
        if currentID == slot.id, !isPaused { slot.player.play() }
    }

    private func armSpinner() {
        spinnerTask?.cancel()
        showSpinner = false
        guard !isReady else { return }
        spinnerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.isReady, !self.failed else { return }
            self.showSpinner = true
        }
    }

    /// 재생이 시작되지 않으면(서버 일시 오류·멈춘 스트림 등) 같은 주소를 다시 기다리지 않고
    /// 3초마다 다음 재생 방식으로 바꾼다. 모두 안 되면 실패 표시
    private func armWatchdog(for id: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            for _ in 0..<8 {
                // 쇼츠는 짧다: 3초 안에 시작하지 않으면 다음 재생 방식으로
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.currentID == id, let slot = self.slots[id] else { return }
                if self.isReady || self.isPaused || self.failed { return }
                if slot.candidates.isEmpty { continue }   // 아직 주소를 받는 중
                guard slot.candidateIndex + 1 < slot.candidates.count else {
                    PlaybackDiag.report("shorts-stall", id: id, details: ["candidates=\(slot.candidates.map(\.kind))",
                                                                         "last=" + PlaybackDiag.describe(slot.player.currentItem)])
                    self.failed = true
                    self.showSpinner = false
                    return
                }
                slot.player.replaceCurrentItem(with: nil)
                await self.tryCandidate(slot, from: slot.candidateIndex + 1)
            }
        }
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    func resume() {
        guard let id = currentID, let slot = slots[id] else { return }
        isPaused = false
        slot.player.isMuted = false
        slot.player.play()
    }

    func pause() {
        isPaused = true
        ScreenAwake.shorts = false
        currentID.flatMap { slots[$0] }?.player.pause()
    }

    /// 쇼츠는 짧고 화면이 작다: 2초만 받아 두면 바로 시작, 화질은 720p까지만
    /// (기본값은 몇 초~십수 초를 미리 받고 1080p를 고르기도 해 첫 재생이 늦었다)
    static func tuneForQuickStart(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 2
        item.preferredMaximumResolution = CGSize(width: 720, height: 1280)
    }
}

// MARK: - 쇼츠 화면 (세로 페이징)

/// 홈의 Shorts 줄에서 누른 쇼츠: 홈 화면 안에서 그대로 재생 (Shorts 탭으로 넘어가지 않음)
struct ShortsSeed: Hashable {
    let items: [VideoItem]
    let start: String
}

struct ShortsView: View {
    let isActive: Bool
    /// 홈에서 밀어 넣은 쇼츠 화면이면 그 목록부터 (오른쪽으로 쓸면 홈으로 돌아감)
    var seed: ShortsSeed? = nil
    @Environment(\.dismiss) private var dismiss
    /// 왼쪽으로 쓸어 들어가는 채널 화면
    @State private var channelPush: ChannelRoute?
    @StateObject private var feed = ShortsFeed()
    @StateObject private var shorts = ShortsPlayer()
    @EnvironmentObject private var player: PlayerManager
    @State private var currentID: String?
    /// 스크롤 위치 (넘기는 도중에도 바뀜). 재생할 쇼츠(currentID)는 넘김이 완전히 멈춘 뒤에 바꾼다 —
    /// 도중에 바꾸면 영상 교체·화면 갱신이 넘김 애니메이션과 겹쳐 '덜컹'하고 걸린다
    @State private var scrollID: String?
    /// 채널 화면으로 넘어가 있는 동안
    @State private var pushedAway = false
    @ObservedObject private var router = ShortsRouter.shared
    @Environment(\.scenePhase) private var scenePhase
    /// 백그라운드로 갈 때 재생 중이었는지 (돌아오면 이어서)
    @State private var pausedForBackground = false
    /// 앱 전체 모드 (쇼츠 화면 자체는 어둡게 강제하므로 그 전에 읽어 둔다)
    @Environment(\.colorScheme) private var appScheme
    @ObservedObject private var search = SearchRouter.shared
    /// 쇼츠 위쪽 검색 줄 높이 (영상은 이 아래부터)
    static let topBar: CGFloat = 44

    var body: some View {
        // 바깥: 하단 탭바/홈 인디케이터 높이만 읽는다. 안쪽: 화면 전체를 한 페이지로 써서
        // 페이지 높이와 넘김 단위가 정확히 같게 (다음 영상이 아래에 걸쳐 보이지 않게)
        GeometryReader { outer in
        let bottomInset = outer.safeAreaInsets.bottom
        let topInset = outer.safeAreaInsets.top
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Blocklist.shared.filter(feed.items)) { item in
                        ShortPage(item: item, isCurrent: item.id == currentID, shorts: shorts,
                                  // 아이패드: 돋보기는 오른쪽 끝이라 가운데 영상과 겹치지 않는다 → 영상을 상태바 바로 아래부터
                                  topInset: topInset + (UIDevice.current.userInterfaceIdiom == .pad ? 0 : Self.topBar),
                                  bottomInset: bottomInset)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(item.id)
                            .onAppear {
                                if let index = feed.items.firstIndex(of: item), index >= feed.items.count - 3 {
                                    Task { await feed.loadMore() }
                                }
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollID)
            .onScrollPhaseChange { _, phase in
                if phase == .idle, let id = scrollID, id != currentID { currentID = id }
            }
            .scrollIndicators(.hidden)
            .contentMargins(0, for: .scrollContent)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        }
        .background(Color.black)
        // 탭바 뒤 띠를 앱 배경색으로: 유리 탭바가 검은 쇼츠 위에서 어둡게 바뀌지 않고
        // 다른 탭과 같은 색(라이트 모드 흰색)으로 보이게
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                (appScheme == .light ? Color.white : Color.black)
                    .frame(height: g.safeAreaInsets.bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea()
            }
            .allowsHitTesting(false)
        }
        // YouTube 쇼츠처럼 위쪽 검색창
        // YouTube 쇼츠처럼 위쪽 줄 오른쪽에 돋보기 (영상은 이 줄 아래부터라 겹치지 않음)
        .overlay(alignment: .top) {
            HStack {
                if seed != nil {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("홈으로")
                }
                Spacer()
                SearchIconButton(dark: true)
            }
            .frame(height: Self.topBar)
            .padding(.horizontal, 10)
        }
        .onChange(of: search.isPresented) { _, open in
            if open { shorts.pause() } else if isActive { playCurrent() }
        }
        .overlay {
            if feed.items.isEmpty {
                if let message = feed.errorMessage {
                    VStack(spacing: 12) {
                        Text(message).foregroundStyle(.white)
                        Button("다시 시도") { Task { await feed.loadMore() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        // YouTube처럼: 오른쪽으로 쓸면 홈으로(홈에서 연 쇼츠), 왼쪽으로 쓸면 이 쇼츠의 채널
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > abs(dy) * 1.5, abs(dx) > 80,
                          Date().timeIntervalSince(ShortsProgressBar.lastScrub) > 0.5 else { return }
                    if dx < 0 { openChannel() } else if seed != nil { dismiss() }
                }
        )
        .navigationDestination(item: $channelPush) { r in
            ChannelView(channelID: r.id, fallbackName: r.name, fallbackAvatar: r.avatar, fromShorts: true)
        }
        .onChange(of: router.request) { _, r in if let r, seed == nil { open(r) } }
        // 쇼츠는 앱을 나가면(홈 화면·잠금) 멈춘다 — 돌아오면 이어서
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if isActive && !pushedAway && !shorts.isPaused { pausedForBackground = true }
                shorts.pause()
            } else if phase == .active, pausedForBackground {
                pausedForBackground = false
                if isActive && !pushedAway && !player.isPlaying { shorts.resume() }
            }
        }
        .task {
            if let seed, feed.items.isEmpty {
                feed.prepend(seed.items)
                currentID = seed.start
                scrollID = seed.start
            } else if let r = router.request, seed == nil { open(r) }
            await feed.loadInitial()
            // 첫 쇼츠들의 재생 주소를 바로 미리 받아 둔다 (탭을 열자마자 시작되게)
            let first = Array(feed.items.prefix(3).map(\.id))
            Task { await StreamResolver.shared.prefetch(first) }
            if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        }
        .onChange(of: currentID) { _, _ in playCurrent() }
        .onDisappear {
            if isActive { pushedAway = true; shorts.pause() }
        }
        .onAppear {
            if pushedAway {
                pushedAway = false
                if isActive && !player.isPlaying { shorts.resume() }
            }
        }
        .onChange(of: isActive) { _, active in
            if active { playCurrent() } else { shorts.pause() }
        }
        .onChange(of: feed.items.count) { old, _ in
            if old == 0, currentID == nil { currentID = feed.items.first?.id }
        }
    }

    /// 지금 쇼츠의 채널로
    private func openChannel() {
        guard let id = currentID, let item = feed.items.first(where: { $0.id == id }) else { return }
        let info = ShortInfoCache.shared.get(id)
        let cid = info?.channelID.isEmpty == false ? info!.channelID : item.channelID
        guard let cid, !cid.isEmpty else { return }
        channelPush = ChannelRoute(id: cid, name: info?.channelName ?? item.channel,
                                   avatar: info?.channelAvatar ?? item.channelThumbnail, shorts: true)
    }

    /// 홈에서 누른 쇼츠부터 보기
    private func open(_ r: ShortsRouter.Request) {
        router.request = nil
        feed.prepend(r.items)
        currentID = r.start
        scrollID = r.start
    }

    private func playCurrent() {
        guard isActive, let id = currentID,
              let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if player.isPlaying { player.pause() }
        let previous = index > 0 ? feed.items[index - 1].id : nil
        let upcoming = feed.items.dropFirst(index + 1).prefix(4).map(\.id)
        shorts.play(feed.items[index], previous: previous, upcoming: upcoming)
        // 채널 이름·구독 버튼: 지금 것과 다음 두 개를 미리 받아 둔다 (넘기자마자 바로 보이게)
        ShortInfoCache.shared.prefetch([id] + upcoming.prefix(2))
        feed.markSeen(id)
    }
}

struct ShortPage: View {
    let item: VideoItem
    let isCurrent: Bool
    @ObservedObject var shorts: ShortsPlayer
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @State private var showSave = false
    /// 채널(구독) 정보: 지금 보는 쇼츠만 가져온다 (한 번 받은 것은 기억)
    @State private var info: WatchInfo?
    @State private var commentPage: CommentPage?
    @State private var showComments = false
    @ObservedObject private var likes = LikeStore.shared
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        GeometryReader { geo in
            // 영상은 화면 높이의 약 80%: 위쪽 상태바 아래부터, 하단 탭바 위까지 가리지 않게.
            // 가로는 화면 폭 그대로, 세로 영상 비율(9:16)에 맞춰 높이를 정한다
            // 하단 탭바(약 64pt)에 가리지 않게 빼고, 9:16 비율로 잘림 없이 맞춘다
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            // 아이패드: 아래 탭바 높이만 비우고 위아래를 꽉 채운다
            let usable = isPad
                ? geo.size.height - topInset - max(bottomInset, 74) - 4
                : geo.size.height - topInset - bottomInset - 64
            // 아이패드: YouTube처럼 위아래를 꽉 채운 세로 영상
            let boxHeight = isPad
                ? usable : min(geo.size.width * 16 / 9, geo.size.height * 0.8, usable)
            let boxWidth = min(geo.size.width, boxHeight * 9 / 16)
            ZStack(alignment: .top) {
                Color.black
                ZStack {
                    Color.black
                        .overlay {
                            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg")) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else if phase.error != nil {
                                    AsyncImage(url: item.bestThumbnail) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.black }
                                } else {
                                    Color.black
                                }
                            }
                        }
                        .clipped()

                    // 쇼츠마다 자기 플레이어 화면 (다음 쇼츠는 첫 프레임이 이미 그려져 있다).
                    // 배경이 투명해 프레임이 오기 전까지는 아래의 썸네일이 보인다
                    if let avPlayer = shorts.player(for: item.id) {
                        VideoSurface(avPlayer: avPlayer, gravity: .resizeAspect, background: .clear)
                    }
                    if isCurrent {
                        if shorts.showSpinner && !shorts.isReady && !shorts.failed {
                            ProgressView().tint(.white)
                        }
                        if shorts.failed {
                            Label("재생할 수 없는 쇼츠입니다", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.white)
                        }
                        if shorts.isPaused {
                            Image(systemName: "play.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 6)
                                .allowsHitTesting(false)
                        }
                    }

                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
                .frame(width: boxWidth, height: boxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, topInset + 4)
                .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isCurrent { shorts.togglePause() } }
        .task(id: isCurrent) {
            guard info == nil else { return }
            if let cached = ShortInfoCache.shared.get(item.id) { info = cached; return }
            guard isCurrent else { return }
            if let got = await ShortInfoCache.shared.load(item.id) { info = got }
        }
        .sheet(isPresented: $showSave) { SaveToFolderSheet(item: item) }
        .sheet(isPresented: $showComments) {
            if let page = commentPage {
                CommentsPanel(first: page, onClose: { showComments = false }, video: item)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    let name = info?.channelName.isEmpty == false ? info!.channelName : item.channel
                    if !name.isEmpty {
                        HStack(spacing: 8) {
                            let cid = info?.channelID.isEmpty == false ? info!.channelID : item.channelID
                            if let cid, !cid.isEmpty {
                                NavigationLink(value: ChannelRoute(id: cid, name: name,
                                                                   avatar: info?.channelAvatar ?? item.channelThumbnail, shorts: true)) {
                                    HStack(spacing: 8) {
                                        AvatarView(url: info?.channelAvatar ?? item.channelThumbnail, size: 32)
                                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                AvatarView(url: info?.channelAvatar ?? item.channelThumbnail, size: 32)
                                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            if let info, !info.channelID.isEmpty {
                                let on = info.subscribed ?? player.isSubscribed(info.channelID)
                                Button {
                                    let channel = SubscribedChannel(id: info.channelID, name: info.channelName, avatar: info.channelAvatar)
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        player.setSubscribed(channel, !on)
                                        self.info?.subscribed = !on
                                    }
                                } label: {
                                    Text(on ? "구독중" : "구독")
                                        .font(.footnote.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .foregroundStyle(on ? Color.white : Color.black)
                                        .background(on ? Color.white.opacity(0.22) : Color.white, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Text(item.title)
                        .font(.subheadline)
                        .lineLimit(2)
                    if let views = item.views {
                        Text(views).font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 18) {
                    let liked = info?.liked ?? likes.isLiked(item.id)
                    sideButton(liked ? "hand.thumbsup.fill" : "hand.thumbsup", label: info?.likeCount ?? "좋아요") {
                        toggleLike()
                    }
                    sideButton("text.bubble", label: commentCount ?? "댓글") {
                        openComments()
                    }
                    sideButton(library.isInAnyFolder(item) ? "checkmark.circle.fill" : "plus.circle", label: "저장") {
                        showSave = true
                    }
                    ShareLink(item: item.shareURL) {
                        sideLabel("arrowshape.turn.up.right", label: "공유")
                    }
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.bottom, bottomInset + 26)
        }
        // YouTube처럼 맨 아래 얇은 진행 막대 (누르거나 끌어서 이동)
        .overlay(alignment: .bottom) {
            if isCurrent, let avPlayer = shorts.player(for: item.id) {
                GeometryReader { g in
                    let isPad = UIDevice.current.userInterfaceIdiom == .pad
                    let usable = g.size.height - topInset - max(bottomInset, 74) - 4
                    let width = isPad ? min(g.size.width, usable * 9 / 16) : g.size.width
                    ShortsProgressBar(player: avPlayer)
                        .id(item.id)
                        .frame(width: width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, bottomInset + 2)
                }
            }
        }
    }

    private var commentCount: String? {
        guard let text = commentPage?.countText else { return nil }
        let t = text.replacingOccurrences(of: "댓글", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func toggleLike() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let on = !(info?.liked ?? likes.isLiked(item.id))
        likes.set(item, on)
        if info?.liked != nil { info?.liked = on }
        if AuthStore.shared.isLoggedIn {
            Task { try? await InnerTubeClient.shared.setLiked(item.id, on) }
        }
    }

    private func openComments() {
        if commentPage != nil { showComments = true; return }
        Task {
            if info == nil { info = await ShortInfoCache.shared.load(item.id) }
            guard let token = info?.commentsToken,
                  let page = try? await InnerTubeClient.shared.comments(token) else {
                commentPage = CommentPage(comments: [], next: nil, countText: nil)
                showComments = true
                return
            }
            commentPage = page
            showComments = true
        }
    }

    private func sideButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { sideLabel(icon, label: label) }
            .buttonStyle(.plain)
    }

    private func sideLabel(_ icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            // 배경 없이 아이콘만 (밝은 화면에서도 보이도록 옅은 그림자)
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .frame(width: 44, height: 34)
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}


/// 쇼츠 채널 정보 캐시 (같은 쇼츠로 돌아와도 다시 묻지 않게)
@MainActor
final class ShortInfoCache {
    static let shared = ShortInfoCache()
    private var map: [String: WatchInfo] = [:]
    private var pending: [String: Task<WatchInfo?, Never>] = [:]
    func get(_ id: String) -> WatchInfo? { map[id] }
    func set(_ id: String, _ info: WatchInfo) {
        if map.count > 300 { map.removeAll() }
        map[id] = info
    }
    /// 받는 중이면 그 결과를 같이 기다린다 (같은 쇼츠를 두 번 묻지 않게)
    func load(_ id: String) async -> WatchInfo? {
        if let v = map[id] { return v }
        if let t = pending[id] { return await t.value }
        let t = Task<WatchInfo?, Never> {
            guard let r = try? await InnerTubeClient.shared.relatedWithInfo(videoID: id) else { return nil }
            return r.1
        }
        pending[id] = t
        let v = await t.value
        pending[id] = nil
        if let v { set(id, v) }
        return v
    }
    func prefetch(_ ids: [String]) {
        for id in ids where map[id] == nil && pending[id] == nil {
            Task { _ = await load(id) }
        }
    }
}


/// 쇼츠 진행 막대: 평소엔 얇은 선, 누르고 끄는 동안 두꺼워지고 시간 표시
struct ShortsProgressBar: View {
    /// 진행 막대를 끈 때 (그 끌기로 채널·홈 이동이 되지 않게)
    @MainActor static var lastScrub = Date.distantPast
    let player: AVPlayer
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var dragging: Double?
    @State private var observer: Any?
    @State private var observedPlayer: AVPlayer?

    var body: some View {
        GeometryReader { g in
            let p = dragging ?? progress
            let thick = dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                    .frame(height: thick ? 8 : 3)
                Capsule().fill(Color.red)
                    .frame(width: max(0, g.size.width * p), height: thick ? 8 : 3)
                if thick {
                    Circle().fill(Color.red)
                        .frame(width: 16, height: 16)
                        .offset(x: g.size.width * p - 8)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                if let d = dragging, duration > 0 {
                    Text("\(Self.clock(d * duration)) / \(Self.clock(duration))")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .frame(maxWidth: .infinity)
                        .offset(y: -70)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        Self.lastScrub = Date()
                        guard duration > 0, g.size.width > 0 else { return }
                        dragging = min(1, max(0, v.location.x / g.size.width))
                    }
                    .onEnded { _ in
                        Self.lastScrub = Date()
                        if let d = dragging, duration > 0 {
                            progress = d
                            player.seek(to: CMTime(seconds: d * duration, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        dragging = nil
                    }
            )
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.15), value: dragging == nil)
        .onAppear { attach() }
        .onDisappear { detach() }
        // 같은 쇼츠라도 플레이어가 새로 만들어지면 새 플레이어에 다시 붙인다
        .onChange(of: ObjectIdentifier(player)) { _, _ in attach() }
    }

    private func attach() {
        detach()
        observedPlayer = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
            let total = player.currentItem?.duration.seconds ?? 0
            if total.isFinite, total > 0 {
                duration = total
                if dragging == nil { progress = min(1, max(0, t.seconds / total)) }
            }
        }
    }

    /// 관찰자는 「붙인 그 플레이어」에서 떼야 한다 (다른 플레이어에서 떼면 앱이 종료됨)
    private func detach() {
        if let observer, let observedPlayer { observedPlayer.removeTimeObserver(observer) }
        observer = nil
        observedPlayer = nil
    }

    static func clock(_ s: Double) -> String {
        let v = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}


// MARK: - 홈 피드의 Shorts 줄 (YouTube처럼 2×2)

/// 홈에서 쇼츠를 누르면 Shorts 탭으로 넘어가 그 쇼츠부터
@MainActor
final class ShortsRouter: ObservableObject {
    static let shared = ShortsRouter()
    struct Request: Equatable {
        let token = UUID()
        let items: [VideoItem]
        let start: String
    }
    @Published var request: Request?
}

@MainActor
final class HomeShortsModel: ObservableObject {
    static let shared = HomeShortsModel()
    @Published private(set) var items: [VideoItem] = []
    private var loading = false
    private let queries = ["#shorts 인기", "#shorts 웃긴", "#shorts 음악", "#shorts 브이로그", "#shorts 동물", "#shorts 스포츠"]

    func load(force: Bool = false) async {
        if loading || (!items.isEmpty && !force) { return }
        loading = true
        defer { loading = false }
        guard let page = try? await InnerTubeClient.shared.shorts(queries.randomElement() ?? "#shorts", continuation: nil) else { return }
        let fresh = Blocklist.shared.filter(page.items).shuffled()
        if !fresh.isEmpty { items = Array(fresh.prefix(12)) }
    }
}

struct ShortsShelf: View {
    @ObservedObject private var model = HomeShortsModel.shared
    @ObservedObject private var blocklist = Blocklist.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let list = blocklist.filter(model.items)
        let regular = sizeClass == .regular
        // 아이패드: YouTube처럼 가로로 넘기는 한 줄 (12개), 폰: 2×2
        let shown = Array(list.prefix(regular ? 12 : 4))
        VStack(alignment: .leading, spacing: 12) {
            if !shown.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.red)
                    Text("Shorts").font(.title3.weight(.bold))
                }
                .padding(.horizontal, 16)
                if regular {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(shown) { item in
                                NavigationLink(value: ShortsSeed(items: list, start: item.id)) {
                                    tile(item, aspect: 9 / 15)
                                }
                                .buttonStyle(.plain)
                                // 화면에 4개 반쯤 보이게 (다음 것이 살짝 보여 넘길 수 있음을 알림)
                                .containerRelativeFrame(.horizontal, count: 9, span: 2, spacing: 12)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(shown) { item in
                            NavigationLink(value: ShortsSeed(items: list, start: item.id)) {
                                tile(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .padding(.vertical, 6)
        .task { await model.load() }
    }

    private func tile(_ item: VideoItem, aspect: CGFloat = 9 / 16) -> some View {
        Color(.tertiarySystemFill)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg")) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        AsyncImage(url: item.bestThumbnail) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color(.tertiarySystemFill) }
                    } else {
                        Color(.tertiarySystemFill)
                    }
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let views = item.views {
                        Text(views).font(.caption2).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}
