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

    private let queries = ["#shorts 인기", "#shorts 웃긴", "#shorts 음악", "#shorts 동물", "#shorts 게임", "#shorts 요리", "#shorts 스포츠"]

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
                let fresh = page.items.filter { !known.contains($0.id) }
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

@MainActor
final class ShortsPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isReady = false
    @Published private(set) var isPaused = false
    @Published private(set) var failed = false
    private(set) var currentID: String?
    private var endObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
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

        task = Task { [weak self] in
            do {
                let playerItem = try await PlayerManager.loadItem(id: item.id, audioOnly: false)
                guard !Task.isCancelled, let self, self.currentID == item.id else { return }
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
                PlayerManager.shared.activateAudioSession()
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

    var body: some View {
        // 바깥: 하단 탭바/홈 인디케이터 높이만 읽는다. 안쪽: 화면 전체를 한 페이지로 써서
        // 페이지 높이와 넘김 단위가 정확히 같게 (다음 영상이 아래에 걸쳐 보이지 않게)
        GeometryReader { outer in
        let bottomInset = outer.safeAreaInsets.bottom
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { item in
                        ShortPage(item: item, isCurrent: item.id == currentID, shorts: shorts, bottomInset: bottomInset)
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
        .overlay(alignment: .topLeading) {
            Text("Shorts")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .padding(.horizontal, 16)
                .padding(.top, 4)
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
        shorts.prefetch(Array(feed.items.dropFirst(index + 1).prefix(2)))
    }
}

struct ShortPage: View {
    let item: VideoItem
    let isCurrent: Bool
    @ObservedObject var shorts: ShortsPlayer
    var bottomInset: CGFloat = 0
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        ZStack {
            // 썸네일은 레이아웃을 밀어내지 않도록 검은 배경의 overlay로, 세로(9:16) 썸네일을 원본 비율 그대로
            Color.black
                .overlay {
                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg")) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error != nil {
                            AsyncImage(url: item.bestThumbnail) { image in
                                image.resizable().scaledToFit()
                            } placeholder: { Color.black }
                        } else {
                            Color.black
                        }
                    }
                }
                .clipped()

            if isCurrent {
                // 영상도 원본 비율 그대로 (잘라서 확대하지 않음)
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

            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isCurrent { shorts.togglePause() } }
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
                    sideButton(library.isSaved(item) ? "checkmark.circle.fill" : "plus.circle", label: "저장") {
                        library.toggleSaved(item)
                    }
                    ShareLink(item: item.shareURL) {
                        sideLabel("arrowshape.turn.up.right", label: "공유")
                    }
                    sideButton("arrow.up.left.and.arrow.down.right", label: "크게") {
                        shorts.pause()
                        player.play(item)
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
