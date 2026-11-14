import Foundation

/// 시청 기록과 저장한 동영상을 기기 안(UserDefaults)에만 보관한다.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var history: [VideoItem] = []
    @Published private(set) var saved: [VideoItem] = []

    private let historyKey = "history.v1"
    private let savedKey = "saved.v1"
    private let maxHistory = 300

    private init() {
        history = Self.load(historyKey)
        saved = Self.load(savedKey)
    }

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

    private static func load(_ key: String) -> [VideoItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([VideoItem].self, from: data)
        else { return [] }
        return items
    }

    private static func store(_ items: [VideoItem], _ key: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
