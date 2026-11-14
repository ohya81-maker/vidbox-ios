import Foundation

/// YouTube 웹이 내부적으로 사용하는 InnerTube API로 검색/추천 목록을 가져온다.
/// 응답 구조가 자주 바뀌므로 JSON 전체를 재귀적으로 훑어서 영상 정보를 찾는 방식으로 파싱한다.
final class InnerTubeClient {
    static let shared = InnerTubeClient()

    private let base = "https://www.youtube.com/youtubei/v1/"
    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private var context: [String: Any] {
        [
            "client": [
                "clientName": "WEB",
                "clientVersion": "2.20251110.01.00",
                "hl": "ko",
                "gl": "KR",
            ],
        ]
    }

    private func post(_ endpoint: String, body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: base + endpoint + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        var payload = body
        payload["context"] = context
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AppError.badResponse(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Public API

    func search(_ query: String) async throws -> FeedPage {
        Self.parsePage(try await post("search", body: ["query": query]))
    }

    func searchContinuation(_ token: String) async throws -> FeedPage {
        Self.parsePage(try await post("search", body: ["continuation": token]))
    }

    func related(videoID: String) async throws -> [VideoItem] {
        let json = try await post("next", body: ["videoId": videoID])
        return Self.parsePage(json).items.filter { $0.id != videoID }
    }

    func suggestions(for query: String) async -> [String] {
        guard !query.isEmpty,
              var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        else { return [] }
        comps.queryItems = [
            .init(name: "client", value: "firefox"),
            .init(name: "ds", value: "yt"),
            .init(name: "hl", value: "ko"),
            .init(name: "q", value: query),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1,
              let list = json[1] as? [String]
        else { return [] }
        return list
    }

    // MARK: - Parsing

    static func parsePage(_ json: Any) -> FeedPage {
        var items: [VideoItem] = []
        var seen = Set<String>()
        var token: String?

        walk(json) { key, value in
            guard let dict = value as? [String: Any] else { return }
            var parsed: VideoItem?
            switch key {
            case "videoRenderer", "compactVideoRenderer", "gridVideoRenderer":
                parsed = parseVideoRenderer(dict)
            case "lockupViewModel":
                parsed = parseLockup(dict)
            case "continuationCommand":
                if token == nil { token = dict["token"] as? String }
            default:
                break
            }
            if let parsed, seen.insert(parsed.id).inserted {
                items.append(parsed)
            }
        }
        return FeedPage(items: items, continuation: token)
    }

    private static func walk(_ node: Any, _ visit: (String, Any) -> Void) {
        if let dict = node as? [String: Any] {
            for (key, value) in dict {
                visit(key, value)
                walk(value, visit)
            }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit) }
        }
    }

    private static func dig(_ node: Any?, _ path: String...) -> Any? {
        var current = node
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let s = dict["simpleText"] as? String { return s }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        if let s = dict["content"] as? String { return s }
        return nil
    }

    private static func makeURL(_ string: String?) -> URL? {
        guard let string else { return nil }
        return URL(string: string.hasPrefix("//") ? "https:" + string : string)
    }

    private static func lastThumbnail(_ node: Any?) -> URL? {
        guard let list = dig(node, "thumbnails") as? [[String: Any]] else { return nil }
        return makeURL(list.last?["url"] as? String)
    }

    private static func lastSource(_ node: Any?) -> URL? {
        guard let list = node as? [[String: Any]] else { return nil }
        return makeURL(list.last?["url"] as? String)
    }

    private static func contains(_ node: Any?, _ needle: String) -> Bool {
        guard let node else { return false }
        if let s = node as? String { return s.contains(needle) }
        var found = false
        walk(node) { _, value in
            if !found, let s = value as? String, s.contains(needle) { found = true }
        }
        return found
    }

    private static func parseVideoRenderer(_ d: [String: Any]) -> VideoItem? {
        guard let id = d["videoId"] as? String else { return nil }
        let channelThumb = lastThumbnail(dig(d, "channelThumbnailSupportedRenderers", "channelThumbnailWithLinkRenderer", "thumbnail"))
            ?? lastThumbnail(d["channelThumbnail"])
        let isLive = contains(d["badges"], "LIVE_NOW") || contains(d["thumbnailOverlays"], "LIVE")
        return VideoItem(
            id: id,
            title: text(d["title"]) ?? "",
            channel: text(d["ownerText"]) ?? text(d["longBylineText"]) ?? text(d["shortBylineText"]) ?? "",
            channelThumbnail: channelThumb,
            thumbnail: lastThumbnail(d["thumbnail"]),
            duration: text(d["lengthText"]),
            views: text(d["shortViewCountText"]) ?? text(d["viewCountText"]),
            published: text(d["publishedTimeText"]),
            isLive: isLive && d["lengthText"] == nil
        )
    }

    private static func parseLockup(_ d: [String: Any]) -> VideoItem? {
        guard (d["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = d["contentId"] as? String
        else { return nil }

        let meta = dig(d, "metadata", "lockupMetadataViewModel")
        let title = dig(meta, "title", "content") as? String ?? ""
        let rows = dig(meta, "metadata", "contentMetadataViewModel", "metadataRows") as? [[String: Any]] ?? []
        let parts: [[String]] = rows.map { row in
            (row["metadataParts"] as? [[String: Any]] ?? []).compactMap { dig($0, "text", "content") as? String }
        }

        var duration: String?
        if let image = dig(d, "contentImage") {
            walk(image) { key, value in
                if duration == nil, key == "thumbnailBadgeViewModel", let s = dig(value, "text") as? String {
                    duration = s
                }
            }
        }

        let secondRow = parts.count > 1 ? parts[1] : []
        return VideoItem(
            id: id,
            title: title,
            channel: parts.first?.first ?? "",
            channelThumbnail: lastSource(dig(meta, "image", "decoratedAvatarViewModel", "avatar", "avatarViewModel", "image", "sources")),
            thumbnail: lastSource(dig(d, "contentImage", "thumbnailViewModel", "image", "sources")),
            duration: duration,
            views: secondRow.first,
            published: secondRow.count > 1 ? secondRow[1] : nil,
            isLive: (duration ?? "").contains("실시간") || (duration ?? "").uppercased().contains("LIVE")
        )
    }
}
