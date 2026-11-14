import Foundation

/// 사용자가 만든 저장 폴더(재생목록)
struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var items: [VideoItem] = []
    var created: Date = Date()
    /// 음악 플레이어에서 만든 폴더 (음악 탭 「저장됨」에 표시, 오디오로 재생)
    var isMusic: Bool? = nil
}

/// 최근 검색어 + 그 검색의 대표 영상 썸네일 (YouTube처럼 옆에 사진)
struct SearchRecord: Codable, Hashable, Identifiable {
    var query: String
    var thumbnail: URL?
    var id: String { query }
}

/// 시청 기록, 저장한 동영상, 저장 폴더, 검색 기록을 기기 안(UserDefaults)에만 보관한다.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var history: [VideoItem] = []
    /// 기본 폴더 "나중에 볼 동영상"
    @Published private(set) var saved: [VideoItem] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var searches: [SearchRecord] = []

    private let historyKey = "history.v1"
    private let savedKey = "saved.v1"
    private let playlistsKey = "playlists.v1"
    private let searchesKey = "searchHistory.v2"
    private let maxHistory = 300

    static let watchLaterName = "나중에 볼 동영상"

    private init() {
        history = Self.load(historyKey)
        saved = Self.load(savedKey)
        playlists = Self.decode([Playlist].self, playlistsKey) ?? []
        searches = Self.decode([SearchRecord].self, searchesKey)
            ?? (UserDefaults.standard.string(forKey: "recentSearches") ?? "")
                .split(separator: "\n").map { SearchRecord(query: String($0), thumbnail: nil) }
    }

    // MARK: 시청 기록

    func addHistory(_ item: VideoItem) {
        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)
        if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        Self.store(history, historyKey)
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        Self.store(history, historyKey)
    }

    func clearHistory() {
        history = []
        Self.store(history, historyKey)
    }

    // MARK: 나중에 볼 동영상 (기본 폴더)

    func isSaved(_ item: VideoItem) -> Bool {
        saved.contains { $0.id == item.id }
    }

    func toggleSaved(_ item: VideoItem) {
        if isSaved(item) {
            saved.removeAll { $0.id == item.id }
        } else {
            saved.insert(item, at: 0)
        }
        Self.store(saved, savedKey)
    }

    func removeSaved(at offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        Self.store(saved, savedKey)
    }

    /// 어느 폴더에든 저장돼 있는지 (저장 아이콘 표시용)
    func isInAnyFolder(_ item: VideoItem) -> Bool {
        isSaved(item) || playlists.contains { p in p.items.contains { $0.id == item.id } }
    }

    // MARK: 저장 폴더

    @discardableResult
    func createPlaylist(_ name: String, music: Bool = false) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? (music ? "내 음악" : "새 폴더") : trimmed, isMusic: music)
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist.id
    }

    var musicPlaylists: [Playlist] { playlists.filter { $0.isMusic == true } }

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func contains(_ item: VideoItem, in id: UUID) -> Bool {
        playlist(id)?.items.contains { $0.id == item.id } ?? false
    }

    func toggle(_ item: VideoItem, in id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playlists[index].items.contains(where: { $0.id == item.id }) {
            playlists[index].items.removeAll { $0.id == item.id }
        } else {
            playlists[index].items.insert(item, at: 0)
        }
        savePlaylists()
    }

    func removeItems(at offsets: IndexSet, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].items.remove(atOffsets: offsets)
        savePlaylists()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[index].name = trimmed
        savePlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    private func savePlaylists() {
        Self.encode(playlists, playlistsKey)
    }

    // MARK: 검색 기록

    func addSearch(_ query: String) {
        let old = searches.first { $0.query == query }
        searches.removeAll { $0.query == query }
        searches.insert(SearchRecord(query: query, thumbnail: old?.thumbnail), at: 0)
        if searches.count > 30 { searches.removeLast(searches.count - 30) }
        Self.encode(searches, searchesKey)
    }

    func setSearchThumbnail(_ query: String, _ url: URL?) {
        guard let url, let index = searches.firstIndex(where: { $0.query == query }) else { return }
        searches[index].thumbnail = url
        Self.encode(searches, searchesKey)
    }

    func removeSearch(_ query: String) {
        searches.removeAll { $0.query == query }
        Self.encode(searches, searchesKey)
    }

    func clearSearches() {
        searches = []
        Self.encode(searches, searchesKey)
    }

    // MARK: 저장

    private static func load(_ key: String) -> [VideoItem] {
        decode([VideoItem].self, key) ?? []
    }

    private static func store(_ items: [VideoItem], _ key: String) {
        encode(items, key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
