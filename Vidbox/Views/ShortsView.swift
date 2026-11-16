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

struct ShortsView: View {
    let isActive: Bool
    @StateObject private var feed = ShortsFeed()
    @StateObject private var shorts = ShortsPlayer()
    @EnvironmentObject private var player: PlayerManager
    @State private var currentID: String?
    /// 스크롤 위치 (넘기는 도중에도 바뀜). 재생할 쇼츠(currentID)는 넘김이 완전히 멈춘 뒤에 바꾼다 —
    /// 도중에 바꾸면 영상 교체·화면 갱신이 넘김 애니메이션과 겹쳐 '덜컹'하고 걸린다
    @State private var scrollID: String?
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
                    ForEach(feed.items) { item in
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
        .task {
            await feed.loadInitial()
            // 첫 쇼츠들의 재생 주소를 바로 미리 받아 둔다 (탭을 열자마자 시작되게)
            let first = Array(feed.items.prefix(3).map(\.id))
            Task { await StreamResolver.shared.prefetch(first) }
            if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        }
        .onChange(of: currentID) { _, _ in playCurrent() }
        .onChange(of: isActive) { _, active in
            if active { playCurrent() } else { shorts.pause() }
        }
        .onChange(of: feed.items.count) { old, _ in
            if old == 0, currentID == nil { currentID = feed.items.first?.id }
        }
    }

    private func playCurrent() {
        guard isActive, let id = currentID,
              let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if player.isPlaying { player.pause() }
        let previous = index > 0 ? feed.items[index - 1].id : nil
        let upcoming = feed.items.dropFirst(index + 1).prefix(4).map(\.id)
        shorts.play(feed.items[index], previous: previous, upcoming: upcoming)
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
        .sheet(isPresented: $showSave) { SaveToFolderSheet(item: item) }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.channel.isEmpty {
                        HStack(spacing: 8) {
                            AvatarView(url: item.channelThumbnail, size: 30)
                            Text(item.channel).font(.subheadline.weight(.semibold))
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
            .padding(.bottom, bottomInset + 16)
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
