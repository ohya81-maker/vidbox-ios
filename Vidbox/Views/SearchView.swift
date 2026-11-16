import SwiftUI

/// 검색 탭. 검색창은 TabView의 .searchable 이 제공한다
/// (iOS 26: 검색 버튼을 누르면 하단 탭이 왼쪽으로 접히고 그 자리에 검색창이 나온다)
struct SearchView: View {
    @Binding var text: String
    @Binding var query: String
    /// 검색 화면으로 따로 띄울 때: 위쪽에 검색창 + 닫기 버튼
    var onClose: (() -> Void)? = nil
    @State private var searchFocused = false

    @EnvironmentObject private var library: LibraryStore
    @StateObject private var results = FeedViewModel()
    @StateObject private var trending = FeedViewModel()
    @State private var suggestions: [String] = []

    private let categories: [(title: String, icon: String, query: String, colors: [Color])] = [
        ("음악", "music.note", "인기 음악", [.pink, .purple]),
        ("게임", "gamecontroller.fill", "게임 영상", [.indigo, .blue]),
        ("뉴스", "newspaper.fill", "오늘 뉴스", [.blue, .cyan]),
        ("스포츠", "figure.run", "스포츠 하이라이트", [.green, .teal]),
        ("영화·드라마", "film.fill", "영화 드라마 리뷰", [.orange, .red]),
        ("요리", "fork.knife", "요리 레시피", [.yellow, .orange]),
        ("여행", "airplane", "여행 브이로그", [.teal, .mint]),
        ("코미디", "face.smiling.inverse", "웃긴 영상", [.purple, .pink]),
        ("과학·기술", "cpu", "IT 테크 리뷰", [.gray, .blue]),
        ("ASMR", "ear.fill", "ASMR", [.brown, .orange]),
    ]

    private var typing: Bool { !text.isEmpty && text != query }

    var body: some View {
        NavigationStack {
            Group {
                if typing {
                    suggestionList
                } else if !query.isEmpty {
                    ScrollView { FeedList(model: results) }
                } else {
                    explore
                }
            }
            .scrollDismissesKeyboard(.immediately)
            // 검색 결과/입력 중 → 왼쪽 가장자리 스와이프로 검색 첫 화면
            .edgeSwipeBack(!query.isEmpty || typing) {
                text = ""
                query = ""
            }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, isPresented: $searchFocused,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: "동영상, 채널, 음악 검색")
            .onSubmit(of: .search) { submit(text) }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onClose) { Image(systemName: "chevron.left") }
                    }
                }
            }
            .onAppear { if query.isEmpty { searchFocused = true } }
            .task(id: text) {
                guard typing else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await InnerTubeClient.shared.suggestions(for: text)
            }
            .onChange(of: query) { _, q in
                guard !q.isEmpty else { return }
                Task { await runSearch(q) }
            }
            .onChange(of: text) { _, t in
                if t.isEmpty { query = "" }
            }
        }
    }

    private func submit(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = trimmed
        if query == trimmed {
            Task { await runSearch(trimmed) }
        } else {
            query = trimmed
        }
    }

    private func runSearch(_ q: String) async {
        library.addSearch(q)
        await results.load(q)
        // 검색 기록 옆에 보여줄 대표 영상 썸네일
        library.setSearchThumbnail(q, results.items.first?.bestThumbnail)
    }

    // MARK: 입력 중 — 자동완성

    private var suggestionList: some View {
        List {
            ForEach(suggestions, id: \.self) { s in
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(s).lineLimit(1)
                    Spacer()
                    Button { text = s + " " } label: {
                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture { submit(s) }
            }
        }
        .listStyle(.plain)
    }

    // MARK: 검색 전 — 검색 기록(썸네일) · 탐색 · 인기

    private var explore: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !library.searches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("최근 검색").font(.title3.weight(.bold))
                            Spacer()
                            Button("전체 삭제") { library.clearSearches() }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        ForEach(library.searches.prefix(12)) { record in
                            historyRow(record)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("탐색").font(.title3.weight(.bold))
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(categories.indices, id: \.self) { i in
                            let c = categories[i]
                            categoryCard(c.title, icon: c.icon, colors: c.colors) { submit(c.query) }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("지금 인기 있는 동영상").font(.title3.weight(.bold))
                        .padding(.horizontal, 16)
                    FeedList(model: trending, limit: 12)
                }
            }
            .padding(.top, 8)
        }
        .task { if !trending.hasLoaded { await trending.load("인기 급상승 동영상") } }
    }

    /// YouTube처럼: 시계 아이콘 · 검색어 · 오른쪽에 그 검색의 대표 영상 사진
    private func historyRow(_ record: SearchRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(record.query)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let thumb = record.thumbnail {
                AsyncImage(url: thumb) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color(.secondarySystemBackground) }
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { submit(record.query) }
        .contextMenu {
            Button(role: .destructive) { library.removeSearch(record.query) } label: {
                Label("검색 기록에서 삭제", systemImage: "trash")
            }
        }
    }

    private func categoryCard(_ title: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 검색 화면 (홈·쇼츠 위의 검색창을 누르면 전체 화면으로)

@MainActor
final class SearchRouter: ObservableObject {
    static let shared = SearchRouter()
    @Published var isPresented = false
    @Published var text = ""
    @Published var query = ""

    func open(_ q: String? = nil) {
        if let q { text = q; query = q }
        isPresented = true
    }
}

struct SearchScreen: View {
    @ObservedObject private var router = SearchRouter.shared

    var body: some View {
        SearchView(text: $router.text, query: $router.query) {
            router.isPresented = false
        }
        // 왼쪽 가장자리에서 쓸어도 닫힘 (검색 결과가 없을 때)
        .edgeSwipeBack(router.query.isEmpty) { router.isPresented = false }
    }
}

/// 홈·쇼츠 위에 놓는 YouTube식 검색창 (누르면 검색 화면)
struct SearchBarButton: View {
    var dark = false
    var body: some View {
        Button { SearchRouter.shared.open() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("검색").foregroundStyle(dark ? Color.white.opacity(0.75) : Color.secondary)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(dark ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
