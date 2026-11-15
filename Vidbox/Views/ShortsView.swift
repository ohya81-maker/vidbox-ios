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
// 플레이어 하나를 계속 화면에 붙여 두고 영상만 바꾼다.
// (1.8.0~1.8.9는 다음 쇼츠마다 대기 플레이어를 따로 만들어 미리 받아 두었는데,
//  넘길 때마다 화면에 붙은 플레이어가 통째로 바뀌어 검은 화면이 깜빡였고,
//  대기 플레이어 2개가 지금 영상과 동시에 받느라 시작이 오히려 늦어졌다)
// 다음 쇼츠는 스트림 주소만 미리 풀어 두어(가벼움) 넘기면 바로 받기 시작한다.

@MainActor
final class ShortsPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isReady = false
    @Published private(set) var isPaused = false
    @Published private(set) var failed = false
    private(set) var currentID: String?
    private var endObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor in
                if playing { self?.isReady = true }
            }
        }
    }

    /// 화면이 첫 프레임을 그렸을 때 (재생 시작 신호를 놓친 경우의 보조)
    func displayChanged(_ ready: Bool, player shown: AVPlayer?) {
        guard shown === player, ready, player.currentItem != nil, player.timeControlStatus == .playing else { return }
        isReady = true
    }

    func play(_ item: VideoItem) {
        if currentID == item.id {
            resume()
            return
        }
        currentID = item.id
        isReady = false
        isPaused = false
        failed = false
        task?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        PlayerManager.shared.activateAudioSession()
        load(item.id)
        armWatchdog(for: item.id)
    }

    private func load(_ id: String) {
        task?.cancel()
        task = Task { [weak self] in
            do {
                let playerItem = try await PlayerManager.loadItem(id: id, audioOnly: false)
                guard !Task.isCancelled, let self, self.currentID == id else { return }
                // HLS도 반복되도록 끝나면 처음으로 되감기
                if let old = self.endObserver { NotificationCenter.default.removeObserver(old) }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.player.seek(to: .zero)
                        self?.player.play()
                    }
                }
                self.player.replaceCurrentItem(with: playerItem)
                if !self.isPaused { self.player.play() }
            } catch {
                guard !Task.isCancelled, let self, self.currentID == id else { return }
                self.failed = true
            }
        }
    }

    /// 8초 안에 재생이 시작되지 않으면 한 번 새로 받아 보고, 그래도 안 되면 실패 표시
    private func armWatchdog(for id: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.currentID == id, !self.isReady, !self.isPaused, !self.failed else { return }
            self.player.replaceCurrentItem(with: nil)
            self.load(id)
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self.currentID == id, !self.isReady, !self.isPaused else { return }
            self.failed = true
        }
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    func resume() {
        guard currentID != nil else { return }
        isPaused = false
        player.play()
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    /// 다음 쇼츠들의 스트림 주소만 미리 풀어 둔다 (영상 데이터는 받지 않아 지금 영상과 대역폭을 다투지 않음)
    func prefetch(_ items: [VideoItem]) {
        let ids = items.map(\.id)
        Task { await StreamResolver.shared.prefetch(ids) }
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
                                  topInset: topInset, bottomInset: bottomInset)
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
        shorts.play(feed.items[index])
        feed.markSeen(id)
        shorts.prefetch(Array(feed.items.dropFirst(index + 1).prefix(2)))
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
            let usable = geo.size.height - topInset - bottomInset - 64
            let boxHeight = min(geo.size.width * 16 / 9, geo.size.height * 0.8, usable)
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

                    if isCurrent {
                        // 넘길 때 검은 화면이 보이지 않도록 배경을 투명하게 두고 항상 표시한다.
                        // 프레임이 오기 전까지는 아래의 썸네일이 보이고, 첫 프레임부터 영상이 덮는다
                        VideoSurface(avPlayer: shorts.player, gravity: .resizeAspect, background: .clear) { ready, shown in
                            shorts.displayChanged(ready, player: shown)
                        }
                        if !shorts.isReady && !shorts.failed {
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
