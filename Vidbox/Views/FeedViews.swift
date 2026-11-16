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
    /// 불러오기는 됐는데 비어 있음 (오류가 아니므로 「다시 시도」 없이 안내만)
    @Published private(set) var isEmptyResult = false
    /// 비었을 때 보여줄 문구 (화면마다 다르게)
    var emptyText: String?
    private var continuation: String?
    /// 여러 검색어를 섞은 홈: 검색어마다 다음 페이지 토큰
    private var mixedTokens: [String] = []
    private var source: FeedSource = .search("")
    private var requestID = 0
    /// 끝까지 내리면 추천 영상으로 계속 이어 붙일지 (시청 기록·좋아요 목록은 끔)
    var endless = true

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
        isEmptyResult = false
        do {
            let page: FeedPage
            switch source {
            case .search(let q): page = try await InnerTubeClient.shared.search(q)
            case .browse(let b): page = try await InnerTubeClient.shared.browse(b)
            }
            guard id == requestID else { return }
            items = page.items
            continuation = page.continuation
            mixedTokens = []
            if page.items.isEmpty { errorMessage = emptyText ?? "표시할 동영상이 없어요."; isEmptyResult = true }
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

    /// 여러 검색어 결과를 번갈아 섞어서 보여준다 (열 때마다 다른 홈 화면). 이미 본 영상은 뺀다.
    /// deeper: 검색어마다 절반 확률로 두 번째 페이지까지 넘겨서 가져온다 (새로고침할 때 같은 영상이 반복되지 않게)
    func loadMixed(_ queries: [String], exclude: Set<String>, deeper: Bool = false) async {
        guard let first = queries.first else { return }
        source = .search(first)
        requestID += 1
        let id = requestID
        isLoading = true
        errorMessage = nil
        let pages: [FeedPage] = await withTaskGroup(of: (Int, FeedPage?).self) { group in
            for (index, q) in queries.enumerated() {
                group.addTask {
                    guard let page = try? await InnerTubeClient.shared.search(q) else { return (index, nil) }
                    if deeper, Bool.random(), let token = page.continuation,
                       let next = try? await InnerTubeClient.shared.searchContinuation(token), next.items.count >= 6 {
                        return (index, next)
                    }
                    return (index, page)
                }
            }
            var result = [FeedPage?](repeating: nil, count: queries.count)
            for await (index, page) in group { result[index] = page }
            return result.compactMap { $0 }
        }
        guard id == requestID else { return }
        var seen = Set<String>()
        var mixed: [VideoItem] = []
        let lists = pages.map { $0.items.filter { !exclude.contains($0.id) } }
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in lists.shuffled() where i < list.count {
                if seen.insert(list[i].id).inserted { mixed.append(list[i]) }
            }
        }
        if !mixed.isEmpty {
            items = mixed
            mixedTokens = pages.compactMap(\.continuation)
            continuation = mixedTokens.first
        } else if items.isEmpty {
            errorMessage = "불러오지 못했습니다."
        }
        isLoading = false
    }

    /// 목록 끝에 가까워지면 다음 영상을 붙인다 — YouTube처럼 끝없이.
    /// 1) 다음 페이지 토큰들로 이어받고  2) 더 없으면 최근에 보인 영상들의 추천(알고리즘)으로 계속 채운다
    func loadMoreIfNeeded(current item: VideoItem) async {
        guard !isLoading,
              let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 6
        else { return }
        let id = requestID
        isLoading = true
        defer { if id == requestID { isLoading = false } }
        for _ in 0..<3 {
            let fresh = await fetchMore()
            guard id == requestID else { return }
            let known = Set(items.map(\.id))
            var seen = Set<String>()
            let added = fresh.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
            if !added.isEmpty {
                items.append(contentsOf: added)
                return
            }
        }
    }

    private func fetchMore() async -> [VideoItem] {
        let client = InnerTubeClient.shared
        // 여러 검색어를 섞은 홈: 각 검색어의 다음 페이지를 번갈아 섞는다
        if !mixedTokens.isEmpty {
            let tokens = mixedTokens
            let pages: [FeedPage] = await withTaskGroup(of: FeedPage?.self) { group in
                for t in tokens { group.addTask { try? await InnerTubeClient.shared.searchContinuation(t) } }
                var out: [FeedPage] = []
                for await page in group { if let page { out.append(page) } }
                return out
            }
            mixedTokens = pages.compactMap(\.continuation)
            var mixed: [VideoItem] = []
            let longest = pages.map(\.items.count).max() ?? 0
            for i in 0..<longest { for page in pages where i < page.items.count { mixed.append(page.items[i]) } }
            if !mixed.isEmpty { return mixed }
        } else if let token = continuation {
            let page: FeedPage?
            switch source {
            case .search: page = try? await client.searchContinuation(token)
            case .browse: page = try? await client.browseContinuation(token)
            }
            continuation = page?.continuation
            if let page, !page.items.isEmpty { return page.items }
        }
        // 더 이어받을 페이지가 없으면: 최근 영상 두 개의 추천 목록을 섞어서 이어 붙인다
        guard endless else { return [] }
        let seeds = Array(items.suffix(12).shuffled().prefix(2)).map(\.id)
        let pages: [FeedPage] = await withTaskGroup(of: FeedPage?.self) { group in
            for seed in seeds { group.addTask { try? await InnerTubeClient.shared.related(videoID: seed) } }
            var out: [FeedPage] = []
            for await page in group { if let page { out.append(page) } }
            return out
        }
        return pages.flatMap(\.items).shuffled()
    }

    func reload() async {
        await load(source: source)
    }

    /// 직접 만든 목록 (이 기기에 저장한 구독 채널의 새 영상)
    func loadCustom(empty: String, _ fetch: @escaping () async -> [VideoItem]) async {
        requestID += 1
        let id = requestID
        isLoading = true
        errorMessage = nil
        isEmptyResult = false
        continuation = nil
        mixedTokens = []
        let list = await fetch()
        guard id == requestID else { return }
        items = list
        if list.isEmpty { errorMessage = empty; isEmptyResult = true }
        isLoading = false
    }

    /// 지금 화면의 영상을 빼고 순서를 섞는다 (새로고침 때 같은 목록이 그대로 나오지 않게)
    func freshen(excluding old: Set<String>) {
        let fresh = items.filter { !old.contains($0.id) }
        items = (fresh.count >= 8 ? fresh : items).shuffled()
    }
}

struct FeedList: View {
    @ObservedObject var model: FeedViewModel
    var limit: Int? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var blocklist = Blocklist.shared

    var body: some View {
        // 아이패드처럼 넓은 화면은 YouTube처럼 여러 줄 격자로
        if sizeClass == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 8) {
                cards
            }
            .padding(.horizontal, 16)
            footer
        } else {
            LazyVStack(spacing: 0) {
                cards
                footer
            }
        }
    }

    @ViewBuilder private var cards: some View {
        let all = blocklist.filter(model.items)
        let shown = limit.map { Array(all.prefix($0)) } ?? all
        ForEach(shown) { item in
            VideoCard(item: item)
                .task { if limit == nil { await model.loadMoreIfNeeded(current: item) } }
        }
    }

    @ViewBuilder private var footer: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(24)
            } else if let message = model.errorMessage {
                VStack(spacing: 12) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !model.isEmptyResult {
                        Button("다시 시도") { Task { await model.reload() } }
                            .buttonStyle(.bordered)
                    }
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
    @State private var path = NavigationPath()
    @ObservedObject private var update = AppUpdate.shared

    private let chips: [(title: String, query: String)] = [
        ("전체", "인기 동영상"),
        ("구독", ""),            // 구독한 채널의 새 영상
        ("저장됨", ""),          // 내가 만든 저장 폴더 목록
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
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    chipBar
                    if chips[selected].title == "저장됨" {
                        SavedFoldersList()
                    } else {
                        FeedList(model: model)
                    }
                }
            }
            // 새로고침 제스처가 끝나며 작업이 취소되지 않도록 별도 작업으로 실행
            .refreshable { await Task { await loadSelected(refresh: true) }.value }  // 당길 때마다 다른 영상
            // 다른 태그를 보고 있을 때 왼쪽 가장자리 스와이프 → 「전체」
            .edgeSwipeBack(selected != 0) {
                selected = 0
                Task { await loadSelected() }
            }
            .hidesTabBarOnScroll()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: account.revision) { await loadSelected() }
            .profileDestinations()
            .navigationDestination(for: FolderRef.self) { ref in FolderDetailView(ref: ref) }
            .channelDestination()
        }
    }

    /// 로그인하지 않았을 때 「전체」에 섞어 쓸 주제들 (열 때마다 3개를 무작위로)
    private let homePool = [
        "인기 동영상", "요즘 화제 영상", "인기 급상승", "예능 하이라이트", "드라마 명장면", "최신 뮤직비디오",
        "웃긴 영상", "브이로그", "먹방", "여행 영상", "스포츠 명장면", "게임 하이라이트", "IT 리뷰",
        "다큐멘터리", "라이브 클립", "커버곡", "애니메이션", "자동차 리뷰", "동물 영상", "요리 영상",
    ]

    /// refresh: 당겨서 새로고침 — 방금 보던 영상은 빼고 다른 영상으로 채운다
    private func loadSelected(refresh: Bool = false) async {
        if chips[selected].title == "저장됨" { return }
        model.endless = chips[selected].title != "구독"
        if chips[selected].title == "구독" {
            if account.isLoggedIn {
                await model.load(source: .browse("FEsubscriptions"))
            } else {
                await model.loadCustom(empty: "구독한 채널이 없어요.\n영상 아래 「구독」을 누르면 여기에 새 영상이 모여요.") {
                    await SubscriptionStore.shared.latestVideos()
                }
            }
            return
        }
        let shown = refresh ? Set(model.items.map(\.id)) : []
        if selected == 0 && account.isLoggedIn {
            await model.load(source: .browse("FEwhat_to_watch"))
            if model.items.isEmpty { await model.load(chips[0].query) }
            if refresh { model.freshen(excluding: shown) }
        } else if selected == 0 {
            let watched = Set(LibraryStore.shared.history.prefix(200).map(\.id))
            await model.loadMixed(Array(homePool.shuffled().prefix(refresh ? 4 : 3)),
                                  exclude: watched.union(shown), deeper: refresh)
        } else if refresh {
            // 태그 화면: 같은 검색어 결과의 다른 페이지를 섞어서 보여준다
            await model.loadMixed([chips[selected].query, chips[selected].query + " 최신"],
                                  exclude: shown, deeper: true)
        } else {
            await model.load(chips[selected].query)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppLogo()
            Spacer()
            // YouTube처럼 맨 위 오른쪽에 돋보기 아이콘
            SearchIconButton()
            // 보관함 (계정·시청 기록·저장한 동영상·설정)
            Button { path.append(ProfileRoute.library) } label: {
                Group {
                    if account.isLoggedIn {
                        AvatarView(url: account.avatar, size: 30)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.primary)
                    }
                }
                // 새 버전이 있으면 작은 빨간 점
                .overlay(alignment: .topTrailing) {
                    if update.available {
                        Circle().fill(.red).frame(width: 9, height: 9).offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        // YouTube처럼 맨 위 줄을 넉넉하게
        .frame(minHeight: 48)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
    /// 비었을 때 문구
    var empty: String? = nil
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
        .task {
            model.endless = false
            model.emptyText = empty
            if !model.hasLoaded { await model.load(source: .browse(browseID)) }
        }
    }
}
