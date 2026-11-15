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
// 다음 쇼츠 2개는 대기용 플레이어에 미리 넣어 두어 앞부분을 받아 둔다.
// 넘기면 대기 플레이어를 그대로 화면에 붙이므로 바로 재생된다.

@MainActor
final class ShortsPlayer: ObservableObject {
    @Published private(set) var player = AVPlayer()
    @Published private(set) var isReady = false
    @Published private(set) var isPaused = false
    @Published private(set) var failed = false
    private(set) var currentID: String?
    private var endObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

    /// 미리 준비한 플레이어 (영상 ID → 플레이어)
    private var standby: [String: AVPlayer] = [:]
    private var preparing: [String: Task<Void, Never>] = [:]

    init() {
        attach(player)
    }

    private static func makePlayer(_ item: AVPlayerItem? = nil) -> AVPlayer {
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        return p
    }

    /// 화면에 붙일 플레이어 교체 + 상태 관찰
    private func attach(_ p: AVPlayer) {
        player = p
        statusObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                if playing { self.isReady = true }
            }
        }
        loop(p.currentItem)
    }

    /// 끝나면 처음으로 되감아 반복
    private func loop(_ item: AVPlayerItem?) {
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = nil
        guard let item else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }
    }

    func play(_ item: VideoItem) {
        if currentID == item.id {
            resume()
            return
        }
        currentID = item.id
        isPaused = false
        failed = false
        task?.cancel()
        player.pause()
        PlayerManager.shared.activateAudioSession()

        // 미리 준비해 둔 플레이어가 있으면 바로 교체
        if let ready = standby.removeValue(forKey: item.id) {
            isReady = false
            attach(ready)
            ready.seek(to: .zero)
            ready.play()
            return
        }
        // 준비 중이면 끝나기를 기다렸다가, 아니면 새로 만든다
        isReady = false
        let fresh = Self.makePlayer()
        attach(fresh)
        let pending = preparing[item.id]
        task = Task { [weak self] in
            if let pending {
                await pending.value
                guard !Task.isCancelled, let self, self.currentID == item.id else { return }
                if let ready = self.standby.removeValue(forKey: item.id) {
                    self.attach(ready)
                    ready.play()
                    return
                }
            }
            do {
                let playerItem = try await PlayerManager.loadItem(id: item.id, audioOnly: false)
                guard !Task.isCancelled, let self, self.currentID == item.id else { return }
                self.player.replaceCurrentItem(with: playerItem)
                self.loop(playerItem)
                self.player.play()
            } catch {
                guard !Task.isCancelled, let self, self.currentID == item.id else { return }
                self.failed = true
            }
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

    /// 다음 쇼츠들을 대기 플레이어에 미리 넣어 앞부분을 받아 둔다 (그 밖의 대기 플레이어는 정리)
    func prefetch(_ items: [VideoItem]) {
        let keep = Set(items.map(\.id))
        for (id, p) in standby where !keep.contains(id) {
            p.replaceCurrentItem(with: nil)
            standby[id] = nil
        }
        for (id, t) in preparing where !keep.contains(id) {
            t.cancel()
            preparing[id] = nil
        }
        for item in items where standby[item.id] == nil && preparing[item.id] == nil && item.id != currentID {
            let id = item.id
            preparing[id] = Task { [weak self] in
                guard let playerItem = try? await PlayerManager.loadItem(id: id, audioOnly: false),
                      !Task.isCancelled, let self else { self?.preparing[id] = nil; return }
                let p = Self.makePlayer(playerItem)
                p.isMuted = false
                p.pause()               // 재생하지 않고 앞부분만 받아 둔다
                self.standby[id] = p
                self.preparing[id] = nil
            }
        }
    }
}

// MARK: - 쇼츠 화면 (세로 페이징)

struct ShortsView: View {
    let isActive: Bool
    @StateObject private var feed = ShortsFeed()
    @StateObject private var shorts = ShortsPlayer()
    @EnvironmentObject private var player: PlayerManager
    @State private var currentID: String?

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
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .contentMargins(0, for: .scrollContent)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        }
        .background(Color.black)
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
            if currentID == nil { currentID = feed.items.first?.id }
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
                        VideoSurface(avPlayer: shorts.player, gravity: .resizeAspect)
                            .opacity(shorts.isReady ? 1 : 0)
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
