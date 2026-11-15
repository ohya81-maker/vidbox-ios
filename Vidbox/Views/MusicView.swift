import SwiftUI

struct MusicSection: Identifiable, Codable {
    let id: String
    let title: String
    let query: String
    var items: [VideoItem] = []
    /// 불러오기를 마쳤는지 (마쳤는데 비어 있으면 섹션을 숨긴다)
    var loaded = false
}

/// 음악 탭에서 들은 곡 기록 (추천 「내 취향」의 씨앗) — 기기에만 저장
enum MusicTaste {
    private static let key = "musicTaste.recent"

    struct Entry: Codable { let id: String; let title: String; let artist: String }

    static func record(_ item: VideoItem) {
        var list = recent()
        list.removeAll { $0.id == item.id }
        list.insert(Entry(id: item.id, title: item.title, artist: item.channel), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(40))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func recent() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    /// 많이 들은 아티스트 순
    static func topArtists(_ n: Int) -> [String] {
        var count: [String: Int] = [:]
        for e in recent() where !e.artist.isEmpty { count[e.artist, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.prefix(n).map(\.key)
    }
}

@MainActor
final class MusicViewModel: ObservableObject {
    /// 앱 시작 때 미리 불러 두고, 음악 탭은 이 하나를 같이 쓴다 (탭에 들어가면 바로 보이게)
    static let shared = MusicViewModel()
    /// 섹션마다 검색어 후보 여러 개 — 새로고침할 때마다 다른 후보로 바꿔 최신곡이 돌아가며 나온다
    private static let pools: [(id: String, title: String, queries: [String])] = [
        ("quick", "빠른 선곡", ["요즘 인기 노래", "요즘 많이 듣는 노래", "최신 인기곡", "이번 주 인기 노래"]),
        ("chart", "인기 차트", ["멜론 차트 인기곡", "멜론 TOP 100", "지니 차트 인기곡", "벅스 실시간 차트"]),
        ("kpop", "K-POP 최신곡", ["케이팝 최신곡", "아이돌 신곡", "K-POP 신곡 발매", "케이팝 컴백 신곡"]),
        ("ballad", "감성 발라드", ["발라드 명곡", "최신 발라드", "감성 발라드 신곡", "이별 발라드"]),
        ("hiphop", "힙합 · R&B", ["국내 힙합 알앤비", "국힙 신곡", "알앤비 감성", "힙합 플레이리스트"]),
        ("pop", "해외 팝", ["pop hits", "new pop songs", "billboard hot 100", "top pop songs this week"]),
        ("indie", "인디 · 어쿠스틱", ["인디 어쿠스틱", "인디 신곡", "어쿠스틱 감성", "밴드 음악"]),
    ]

    @Published var sections: [MusicSection] = MusicViewModel.initialSections()
    /// 내가 들은 곡에서 이어지는 추천 (YouTube Music 라디오) — 들은 곡이 없으면 비어 있다
    @Published private(set) var forYou: [MusicSection] = MusicViewModel.cached?.forYou ?? []

    /// 지난번에 불러온 목록 — 다음 실행 때 로딩 없이 먼저 보여주고 뒤에서 새로 고친다
    private struct Snapshot: Codable { var sections: [MusicSection]; var forYou: [MusicSection] }
    private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("music-home.json")
    private static let cached: Snapshot? = {
        guard let data = try? Data(contentsOf: cacheURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.sections.contains(where: { !$0.items.isEmpty }) else { return nil }
        return snap
    }()
    /// 검색어는 새로 고르되, 곡 목록은 지난번 것을 채워 넣어 바로 보이게 한다
    private static func initialSections() -> [MusicSection] {
        var fresh = makeSections()
        guard let cached else { return fresh }
        for i in fresh.indices {
            if let old = cached.sections.first(where: { $0.id == fresh[i].id }), !old.items.isEmpty {
                fresh[i].items = old.items
                fresh[i].loaded = true
            }
        }
        return fresh
    }

    private func saveCache() {
        let snap = Snapshot(sections: sections.filter { !$0.items.isEmpty }, forYou: forYou)
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snap) { try? data.write(to: url, options: .atomic) }
        }
    }
    @Published private(set) var moodSection: MusicSection?
    @Published private(set) var isLoadingMood = false
    private var loaded = false

    private static func makeSections() -> [MusicSection] {
        let year = Calendar.current.component(.year, from: Date())
        return pools.map { p in
            var q = p.queries.randomElement() ?? p.queries[0]
            if p.id == "kpop" || p.id == "quick" { q += " \(year)" }   // 그 해 노래 위주
            return MusicSection(id: p.id, title: p.title, query: q)
        }
    }

    func loadAll() async {
        guard !loaded else { return }
        loaded = true
        async let personal: Void = loadForYou()
        await withTaskGroup(of: (String, [VideoItem]).self) { group in
            for section in sections {
                let id = section.id, query = section.query
                group.addTask { (id, await InnerTubeClient.shared.musicSongs(query)) }
            }
            for await (id, items) in group {
                // 불러오기 실패(빈 결과)면 지난번 목록을 그대로 둔다
                if let index = sections.firstIndex(where: { $0.id == id }), !(items.isEmpty && !sections[index].items.isEmpty) {
                    // 「빠른 선곡」은 매번 순서를 섞는다
                    sections[index].items = id == "quick" ? items.shuffled() : items
                    sections[index].loaded = true
                }
            }
        }
        await personal
        saveCache()
    }

    /// 최근 들은 곡 하나 → 비슷한 곡 라디오, 많이 들은 아티스트 → 그 아티스트 노래
    private func loadForYou() async {
        let recent = MusicTaste.recent()
        guard !recent.isEmpty else { forYou = []; return }
        var result: [MusicSection] = []
        let seed = recent.prefix(5).randomElement()!
        let radio = await InnerTubeClient.shared.musicRadio(seed: seed.id)
        if radio.count >= 4 {
            result.append(MusicSection(id: "radio", title: "'\(seed.title)'와 비슷한 곡", query: seed.title,
                                       items: radio, loaded: true))
        }
        if let artist = MusicTaste.topArtists(3).randomElement() {
            let songs = await InnerTubeClient.shared.musicSongs(artist + " 노래")
            if songs.count >= 4 {
                result.append(MusicSection(id: "artist", title: "\(artist) 추천", query: artist,
                                           items: songs.shuffled(), loaded: true))
            }
        }
        if !result.isEmpty || forYou.isEmpty { forYou = result }   // 실패하면 지난번 추천 유지
    }

    func reload() async {
        loaded = false
        // 기존 곡은 남겨둔 채 검색어만 새로 골라 다시 불러온다
        let fresh = Self.makeSections()
        for i in sections.indices where i < fresh.count {
            sections[i] = MusicSection(id: fresh[i].id, title: fresh[i].title, query: fresh[i].query,
                                       items: sections[i].items, loaded: sections[i].loaded)
        }
        await loadAll()
    }

    func selectMood(_ mood: String?) async {
        guard let mood else { moodSection = nil; return }
        isLoadingMood = true
        let items = await InnerTubeClient.shared.musicSongs(mood + " 플레이리스트 노래")
        moodSection = MusicSection(id: "mood", title: mood, query: mood, items: items, loaded: true)
        isLoadingMood = false
    }
}

struct MusicView: View {
    @ObservedObject private var model = MusicViewModel.shared
    @EnvironmentObject private var player: PlayerManager
    @State private var selectedMood: String?
    @State private var searchText = ""
    @State private var searchedQuery = ""
    @State private var searchResults: [VideoItem] = []
    @State private var isSearching = false
    @State private var suggestions: [String] = []
    @FocusState private var searchFocused: Bool

    static let savedChip = "저장됨"
    private let moods = ["운동", "휴식", "집중", "출퇴근", "신나는", "잠잘 때", "드라이브", "카페", "비 오는 날", "슬픔"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        AppLogo(suffix: "Music")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    searchBar

                    if searchFocused && !searchText.isEmpty && !suggestions.isEmpty {
                        suggestionList
                    } else if !searchedQuery.isEmpty {
                        searchResultList
                    } else if selectedMood == Self.savedChip {
                        moodBar
                        SavedFoldersList(music: true)
                    } else {
                        moodBar

                        if model.isLoadingMood {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if let mood = model.moodSection {
                            quickPicks(mood)
                        }

                        if let quick = model.sections.first, !(quick.loaded && quick.items.isEmpty) {
                            quickPicks(quick)
                        }
                        // 내가 들은 곡 기반 추천
                        ForEach(model.forYou) { section in
                            shelf(section)
                        }
                        ForEach(model.sections.dropFirst().filter { !($0.loaded && $0.items.isEmpty) }) { section in
                            shelf(section)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            // 검색 결과·선택한 태그 → 왼쪽 가장자리 스와이프로 「전체」
            .edgeSwipeBack(!searchedQuery.isEmpty || selectedMood != nil) {
                if !searchedQuery.isEmpty {
                    searchText = ""
                    searchedQuery = ""
                    searchResults = []
                } else {
                    selectedMood = nil
                    Task { await model.selectMood(nil) }
                }
            }
            // 음악 탭은 스크롤해도 하단 탭바를 그대로 둔다 (쇼츠처럼)
            // 새로고침 제스처가 끝나며 작업이 취소되지 않도록 별도 작업으로 실행
            .refreshable { await Task { await model.reload() }.value }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FolderRef.self) { ref in FolderDetailView(ref: ref) }
            .task { await model.loadAll() }
            .task(id: searchText) {
                guard searchFocused, !searchText.isEmpty else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await InnerTubeClient.shared.suggestions(for: searchText)
            }
        }
    }

    // MARK: 검색

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("노래, 아티스트, 앨범 검색", text: $searchText)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { runSearch(searchText) }
            if !searchText.isEmpty || !searchedQuery.isEmpty {
                Button {
                    searchText = ""
                    searchedQuery = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glass(Capsule(), interactive: true)
        .padding(.horizontal, 14)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { s in
                Button {
                    searchText = s
                    runSearch(s)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text(s).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchResultList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("'\(searchedQuery)' 검색 결과").font(.title3.weight(.bold)).lineLimit(1)
                Spacer()
                if let first = searchResults.first {
                    Button {
                        player.play(first, queue: searchResults, audio: true, expand: true)
                    } label: {
                        Label("모두 재생", systemImage: "play.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            if isSearching {
                placeholder
            } else if searchResults.isEmpty {
                Text("검색 결과가 없습니다")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(searchResults) { song in
                        songRow(song, queue: searchResults)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchFocused = false
        searchedQuery = q
        isSearching = true
        Task {
            let songs = await InnerTubeClient.shared.musicSongs(q)
            guard searchedQuery == q else { return }
            searchResults = songs
            isSearching = false
        }
    }

    private var moodBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 맨 앞: 전체(기본 화면) · 음악에서 저장한 폴더
                ChipButton(title: "전체", isOn: selectedMood == nil) {
                    selectedMood = nil
                    Task { await model.selectMood(nil) }
                }
                ChipButton(title: Self.savedChip, isOn: selectedMood == Self.savedChip) {
                    selectedMood = selectedMood == Self.savedChip ? nil : Self.savedChip
                }
                ForEach(moods, id: \.self) { mood in
                    ChipButton(title: mood, isOn: selectedMood == mood) {
                        selectedMood = selectedMood == mood ? nil : mood
                        Task { await model.selectMood(selectedMood) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 빠른 선곡 — 4줄씩 가로로 넘기는 목록

    private func quickPicks(_ section: MusicSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(section)
            if section.items.isEmpty {
                placeholder
            } else {
                // 곡 수만큼만 줄을 만들고 높이를 고정해서 아래 섹션과의 간격이 벌어지지 않게
                let rows = min(4, section.items.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 8), count: rows), spacing: 16) {
                        ForEach(section.items) { song in
                            songRow(song, queue: section.items)
                                .frame(width: 300)
                        }
                    }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .frame(height: CGFloat(rows) * 56 + CGFloat(rows - 1) * 8)
            }
        }
    }

    private func songRow(_ song: VideoItem, queue: [VideoItem]) -> some View {
        Button {
            player.play(song, queue: queue, audio: true, expand: true)
        } label: {
            HStack(spacing: 12) {
                artwork(song, size: 52, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text([song.channel, song.duration].compactMap { s in
                        guard let s, !s.isEmpty else { return nil }
                        return s
                    }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.current?.id == song.id {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 가로 선반 — 정사각형 앨범 카드

    private func shelf(_ section: MusicSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(section)
            if section.items.isEmpty {
                placeholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(section.items) { song in
                            Button {
                                player.play(song, queue: section.items, audio: true, expand: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    artwork(song, size: 150, radius: 10)
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(song.channel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func header(_ section: MusicSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title).font(.title2.weight(.bold))
            Spacer()
            if let first = section.items.first {
                Button {
                    player.play(first, queue: section.items, audio: true, expand: true)
                } label: {
                    Label("모두 재생", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func artwork(_ song: VideoItem, size: CGFloat, radius: CGFloat) -> some View {
        AsyncImage(url: song.bestThumbnail) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(.secondarySystemBackground)
                .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var placeholder: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: 80)
    }
}
