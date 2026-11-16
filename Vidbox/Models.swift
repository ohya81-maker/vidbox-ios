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
    /// 채널 ID (UC...) — 채널 사진을 누르면 채널 화면으로
    var channelID: String? = nil

    var bestThumbnail: URL {
        thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    /// 큰 카드(아이패드 등)에서 쓰는 1280x720 썸네일. 추천 목록의 썸네일은 작아서 크게 늘리면 깨져 보인다
    var largeThumbnail: URL? {
        guard id.count == 11, !id.contains(":") else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hq720.jpg")
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
