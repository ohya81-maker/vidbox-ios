import SwiftUI

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var continuation: String?
    private var query = ""
    private var requestID = 0

    var hasLoaded: Bool { !items.isEmpty }

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
            .task { if !model.hasLoaded { await model.load(chips[selected].query) } }
        }
    }

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips.indices, id: \.self) { index in
                    ChipButton(title: chips[index].title, isOn: index == selected) {
                        guard index != selected else { return }
                        selected = index
                        Task { await model.load(chips[index].query) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 보관함

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        NavigationStack {
            List {
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
                            Text("최근 본 동영상").font(.headline).foregroundStyle(.primary)
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
            .navigationTitle("보관함")
        }
    }
}
