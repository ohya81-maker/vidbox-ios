import SwiftUI

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var continuation: String?
    private var query = ""
    private var requestID = 0

    func load(_ query: String) async {
        self.query = query
        requestID += 1
        let id = requestID
        isLoading = true
        errorMessage = nil
        do {
            let page = try await InnerTubeClient.shared.search(query)
            guard id == requestID else { return }
            items = page.items
            continuation = page.continuation
            if page.items.isEmpty { errorMessage = "결과가 없습니다." }
        } catch {
            guard id == requestID else { return }
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
        guard let page = try? await InnerTubeClient.shared.searchContinuation(token), id == requestID else { return }
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !known.contains($0.id) })
        continuation = page.continuation
    }

    func reload() async {
        await load(query)
    }
}

struct FeedList: View {
    @ObservedObject var model: FeedViewModel

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
                VideoCard(item: item)
                    .task { await model.loadMoreIfNeeded(current: item) }
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
    @State private var selected = 0

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
                    chipBar
                    FeedList(model: model)
                }
            }
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AppLogo() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { if model.items.isEmpty { await model.load(chips[selected].query) } }
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips.indices, id: \.self) { index in
                    let isOn = index == selected
                    Button {
                        guard index != selected else { return }
                        selected = index
                        Task { await model.load(chips[index].query) }
                    } label: {
                        Text(chips[index].title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(isOn ? Color(.systemBackground) : .primary)
                            .background(isOn ? Color.primary : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 검색

struct SearchView: View {
    @StateObject private var model = FeedViewModel()
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var submitted = ""
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if submitted.isEmpty {
                    recentList
                } else {
                    FeedList(model: model)
                }
            }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "검색")
            .searchSuggestions {
                ForEach(suggestions, id: \.self) { s in
                    Label(s, systemImage: "magnifyingglass").searchCompletion(s)
                }
            }
            .onSubmit(of: .search) { submit(text) }
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await InnerTubeClient.shared.suggestions(for: text)
            }
            .onChange(of: text) { _, newValue in
                if newValue.isEmpty { submitted = "" }
            }
        }
    }

    private var recentList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(recent, id: \.self) { q in
                Button {
                    text = q
                    submit(q)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(q).foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        submitted = q
        recentRaw = ([q] + recent.filter { $0 != q }).prefix(20).joined(separator: "\n")
        Task { await model.load(q) }
    }
}

// MARK: - 보관함

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) })) {
                        Label("오디오 전용 모드 (데이터 절약)", systemImage: "headphones")
                    }
                    Toggle(isOn: $player.autoplay) {
                        Label("다음 동영상 자동재생", systemImage: "infinity")
                    }
                } header: {
                    Text("재생 설정")
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
                    Text("나중에 볼 동영상")
                }

                Section {
                    if library.history.isEmpty {
                        Text("시청 기록이 없습니다").foregroundStyle(.secondary)
                    }
                    ForEach(library.history) { item in
                        VideoRow(item: item)
                    }
                    .onDelete { library.removeHistory(at: $0) }
                } header: {
                    HStack {
                        Text("시청 기록")
                        Spacer()
                        if !library.history.isEmpty {
                            Button("모두 지우기") { library.clearHistory() }
                                .font(.caption)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("보관함")
        }
    }
}
