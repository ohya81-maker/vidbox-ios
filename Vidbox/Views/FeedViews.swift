import SwiftUI

enum FeedSource: Equatable {
    case search(String)
    case browse(String)
}

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var continuation: String?
    private var source: FeedSource = .search("")
    private var requestID = 0

    var hasLoaded: Bool { !items.isEmpty }

    func load(_ query: String) async {
        await load(source: .search(query))
    }

    func load(source: FeedSource) async {
        self.source = source
        requestID += 1
        let id = requestID
        isLoading = true
        errorMessage = nil
        do {
            let page: FeedPage
            switch source {
            case .search(let q): page = try await InnerTubeClient.shared.search(q)
            case .browse(let b): page = try await InnerTubeClient.shared.browse(b)
            }
            guard id == requestID else { return }
            items = page.items
            continuation = page.continuation
            if page.items.isEmpty { errorMessage = "표시할 동영상이 없습니다." }
        } catch {
            guard id == requestID else { return }
            // 취소된 요청은 실패가 아님 — 기존 목록을 그대로 둔다. 목록이 있으면 실패해도 비우지 않는다.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if cancelled || !items.isEmpty {
                isLoading = false
                return
            }
            errorMessage = "불러오지 못했습니다.\n\(error.localizedDescription)"
        }
        isLoading = false
    }

    func loadMoreIfNeeded(current item: VideoItem) async {
        guard !isLoading, let token = continuation,
              let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 4
        else { return }
        let id = requestID
        isLoading = true
        defer { isLoading = false }
        let page: FeedPage?
        switch source {
        case .search: page = try? await InnerTubeClient.shared.searchContinuation(token)
        case .browse: page = try? await InnerTubeClient.shared.browseContinuation(token)
        }
        guard let page, id == requestID else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !known.contains($0.id) })
        continuation = page.continuation
    }

    func reload() async {
        await load(source: source)
    }
}

struct FeedList: View {
    @ObservedObject var model: FeedViewModel
    var limit: Int? = nil

    var body: some View {
        LazyVStack(spacing: 0) {
            let shown = limit.map { Array(model.items.prefix($0)) } ?? model.items
            ForEach(shown) { item in
                VideoCard(item: item)
                    .task { if limit == nil { await model.loadMoreIfNeeded(current: item) } }
            }
            if model.isLoading {
                ProgressView().padding(24)
            } else if let message = model.errorMessage {
                VStack(spacing: 12) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("다시 시도") { Task { await model.reload() } }
                        .buttonStyle(.bordered)
                }
                .padding(32)
            }
        }
    }
}

// MARK: - 홈

struct HomeView: View {
    @StateObject private var model = FeedViewModel()
    @EnvironmentObject private var account: AccountStore
    @State private var selected = 0
    @State private var showLibrary = false

    private let chips: [(title: String, query: String)] = [
        ("전체", "인기 동영상"),
        ("음악", "인기 음악"),
        ("K-POP", "케이팝 최신 뮤직비디오"),
        ("플레이리스트", "노래 모음 플레이리스트"),
        ("뉴스", "오늘 뉴스"),
        ("게임", "게임 영상"),
        ("실시간", "라이브"),
        ("요리", "요리 레시피"),
        ("스포츠", "스포츠 하이라이트"),
        ("영화", "영화 리뷰"),
        ("팟캐스트", "팟캐스트"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    chipBar
                    FeedList(model: model)
                }
            }
            // 새로고침 제스처가 끝나며 작업이 취소되지 않도록 별도 작업으로 실행
            .refreshable { await Task { await model.reload() }.value }
            .hidesTabBarOnScroll()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: account.revision) { await loadSelected() }
            .navigationDestination(isPresented: $showLibrary) { LibraryView() }
        }
    }

    private func loadSelected() async {
        if selected == 0 && account.isLoggedIn {
            await model.load(source: .browse("FEwhat_to_watch"))
            if model.items.isEmpty { await model.load(chips[0].query) }
        } else {
            await model.load(chips[selected].query)
        }
    }

    private var header: some View {
        HStack {
            AppLogo()
            Spacer()
            // 보관함 (계정·시청 기록·저장한 동영상·설정)
            Button { showLibrary = true } label: {
                if account.isLoggedIn {
                    AvatarView(url: account.avatar, size: 30)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips.indices, id: \.self) { index in
                    ChipButton(title: chips[index].title, isOn: index == selected) {
                        guard index != selected else { return }
                        selected = index
                        Task { await loadSelected() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 로그인 계정의 피드 화면 (시청 기록, 구독)

struct BrowseFeedScreen: View {
    let title: String
    let browseID: String
    @StateObject private var model = FeedViewModel()

    var body: some View {
        ScrollView {
            FeedList(model: model)
        }
        // 새로고침 제스처가 끝나며 작업이 취소되지 않도록 별도 작업으로 실행
            .refreshable { await Task { await model.reload() }.value }
        .hidesTabBarOnScroll()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if !model.hasLoaded { await model.load(source: .browse(browseID)) } }
    }
}

// MARK: - 보관함

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false
    @State private var confirmLogout = false

    /// 홈 화면 안으로 밀어 넣어(push) 보여주므로 자체 NavigationStack은 없다
    var body: some View {
            List {
                accountSection

                if !library.history.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(library.history.prefix(20)) { item in
                                    Button { player.play(item) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ThumbnailView(url: item.bestThumbnail, duration: item.duration, cornerRadius: 10)
                                                .frame(width: 150)
                                            Text(item.title)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(2)
                                                .frame(width: 150, alignment: .leading)
                                            Text(item.channel)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    } header: {
                        HStack {
                            Text("이 기기에서 본 동영상").font(.headline).foregroundStyle(.primary)
                            Spacer()
                            Button("모두 지우기") { library.clearHistory() }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if library.saved.isEmpty {
                        Text("저장한 동영상이 없습니다").foregroundStyle(.secondary)
                    }
                    ForEach(library.saved) { item in
                        VideoRow(item: item)
                    }
                    .onDelete { library.removeSaved(at: $0) }
                } header: {
                    Text("나중에 볼 동영상").font(.headline).foregroundStyle(.primary)
                }

                Section {
                    Toggle(isOn: $player.audioOnlyPreference) {
                        Label("기본으로 오디오 전용 재생", systemImage: "headphones")
                    }
                    Toggle(isOn: $player.autoplay) {
                        Label("다음 동영상 자동재생", systemImage: "infinity")
                    }
                } header: {
                    Text("재생 설정").font(.headline).foregroundStyle(.primary)
                }
                .tint(.green)
            }
            .listStyle(.plain)
            .hidesTabBarOnScroll()
            .navigationTitle("보관함")
            .toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $showLogin) { LoginView() }
            .confirmationDialog("로그아웃할까요?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("로그아웃", role: .destructive) { account.logout() }
            }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isLoggedIn {
                HStack(spacing: 14) {
                    AvatarView(url: account.avatar, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name ?? "YouTube 계정").font(.headline)
                        if let handle = account.handle {
                            Text(handle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("로그아웃") { confirmLogout = true }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
                NavigationLink {
                    BrowseFeedScreen(title: "YouTube 시청 기록", browseID: "FEhistory")
                } label: {
                    Label("YouTube 시청 기록", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    BrowseFeedScreen(title: "구독", browseID: "FEsubscriptions")
                } label: {
                    Label("구독 채널 새 동영상", systemImage: "play.square.stack")
                }
                NavigationLink {
                    BrowseFeedScreen(title: "좋아요 표시한 동영상", browseID: "VLLL")
                } label: {
                    Label("좋아요 표시한 동영상", systemImage: "hand.thumbsup")
                }
            } else {
                Button { showLogin = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("YouTube 계정으로 로그인").font(.headline)
                            Text("내 시청 기록·구독·추천을 그대로 가져옵니다")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
