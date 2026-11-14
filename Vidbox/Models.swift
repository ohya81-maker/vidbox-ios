import Foundation

struct VideoItem: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var channel: String
    var channelThumbnail: URL?
    var thumbnail: URL?
    var duration: String?
    var views: String?
    var published: String?
    var isLive: Bool

    var bestThumbnail: URL {
        thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    /// "채널 · 조회수 · 날짜" 형태의 메타 정보
    var metaLine: String {
        [channel, views, published].compactMap { s in
            guard let s, !s.isEmpty else { return nil }
            return s
        }.joined(separator: " · ")
    }

    var shareURL: URL {
        URL(string: "https://youtu.be/\(id)")!
    }
}

struct FeedPage {
    var items: [VideoItem]
    var continuation: String?
}

enum AppError: LocalizedError {
    case badResponse(Int)
    case noPlayableStream

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "서버 응답 오류 (\(code))"
        case .noPlayableStream: return "재생 가능한 스트림을 찾지 못했습니다."
        }
    }
}
