import SwiftUI

/// 검색 탭. 검색창은 TabView의 .searchable 이 제공한다
/// (iOS 26: 검색 버튼을 누르면 하단 탭이 왼쪽으로 접히고 그 자리에 검색창이 나온다)
struct SearchView: View {
    @Binding var text: String
    @Binding var query: String
    /// 검색 화면으로 따로 띄울 때: 위쪽에 검색창 + 닫기 버튼
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var library: LibraryStore
    @StateObject private var results = FeedViewModel()
    @State private var suggestions: [String] = []

    private var typing: Bool { !text.isEmpty && text != query }

    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // YouTube처럼: 뒤로 · 검색칸 (X·취소 버튼 없음)
                HStack(spacing: 6) {
                    Button { close() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    TextField("YouTube 검색", text: $text)
                        .focused($fieldFocused)
                        .submitLabel(.search)
                        .onSubmit { submit(text) }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .padding(.vertical, 6)

                Group {
                    if typing {
                        suggestionList
                    } else if !query.isEmpty {
                        ScrollView { FeedList(model: results) }
                    } else {
                        history
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: text) {
                guard typing else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await InnerTubeClient.shared.suggestions(for: text)
            }
            .onChange(of: query) { _, q in
                guard !q.isEmpty else { return }
                fieldFocused = false
                Task { await runSearch(q) }
            }
            .onChange(of: text) { _, t in
                if t.isEmpty { query = "" }
            }
            .onAppear {
                if query.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fieldFocused = true }
                }
            }
        }
    }

    private func close() {
        fieldFocused = false
        text = ""
        query = ""
        onClose?()
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
                    Button { text = s + " "; fieldFocused = true } label: {
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

    // MARK: 검색 전 — 검색 기록만 (YouTube처럼)

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(library.searches.prefix(30)) { record in
                    historyRow(record)
                }
            }
            .padding(.top, 4)
        }
    }

    /// YouTube처럼: 시계 아이콘 · 검색어 · 오른쪽에 그 검색의 대표 영상 사진
    private func historyRow(_ record: SearchRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20))
                .frame(width: 28)
            Text(record.query)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let thumb = record.thumbnail {
                AsyncImage(url: thumb) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color(.secondarySystemBackground) }
                .frame(width: 60, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Button {
                text = record.query + " "
                fieldFocused = true
            } label: {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 17))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { submit(record.query) }
        .contextMenu {
            Button(role: .destructive) { library.removeSearch(record.query) } label: {
                Label("검색 기록에서 삭제", systemImage: "trash")
            }
        }
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

/// YouTube처럼 돋보기 아이콘만 (누르면 검색 화면)
struct SearchIconButton: View {
    var dark = false
    var body: some View {
        Button { SearchRouter.shared.open() } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(dark ? Color.white : Color.primary)
                .shadow(color: dark ? .black.opacity(0.4) : .clear, radius: 3)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("검색")
    }
}
