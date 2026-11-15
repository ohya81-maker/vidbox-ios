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

    private func context(music: Bool, hl: String = "ko") -> [String: Any] {
        [
            "client": [
                "clientName": music ? "WEB_REMIX" : "WEB",
                "clientVersion": music ? "1.20251110.01.00" : "2.20251110.01.00",
                "hl": hl,
                "gl": "KR",
            ],
        ]
    }

    private func post(_ endpoint: String, body: [String: Any], music: Bool = false, hl: String = "ko") async throws -> Any {
        let host = music ? "https://music.youtube.com" : "https://www.youtube.com"
        var request = URLRequest(url: URL(string: host + "/youtubei/v1/" + endpoint + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(host, forHTTPHeaderField: "Origin")
        request.setValue(music ? "67" : "1", forHTTPHeaderField: "X-Youtube-Client-Name")
        for (key, value) in AuthStore.shared.headers(origin: host) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        var payload = body
        payload["context"] = context(music: music, hl: hl)
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

    // MARK: YouTube Kids (어린이용 콘텐츠만 나오는 별도 API)

    enum KidsAge: String, CaseIterable, Identifiable {
        case preschool = "KIDS_CORPUS_PREFERENCE_PRESCHOOL"
        case younger = "KIDS_CORPUS_PREFERENCE_YOUNGER"
        case tween = "KIDS_CORPUS_PREFERENCE_TWEEN"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .preschool: return "유아 (4세 이하)"
            case .younger: return "어린이 (5~8세)"
            case .tween: return "초등 고학년 (9~12세)"
            }
        }
        /// 나이 선택 아이콘 (플랫한 SF Symbol)
        var symbol: String {
            switch self {
            case .preschool: return "teddybear.fill"
            case .younger: return "figure.child"
            case .tween: return "graduationcap.fill"
            }
        }
    }

    private func postKids(_ endpoint: String, body: [String: Any], age: KidsAge) async throws -> Any {
        let host = "https://www.youtubekids.com"
        var request = URLRequest(url: URL(string: host + "/youtubei/v1/" + endpoint + "?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(host, forHTTPHeaderField: "Origin")
        var payload = body
        payload["context"] = [
            "client": [
                "clientName": "WEB_KIDS",
                "clientVersion": "2.20251110.00.00",
                "hl": "ko",
                "gl": "KR",
                "kidsAppInfo": [
                    "contentSettings": [
                        "corpusPreference": age.rawValue,
                        "kidsNoSearchMode": "YT_KIDS_NO_SEARCH_MODE_OFF",
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AppError.badResponse(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// params: nil=추천, "kgQCCAI="=프로그램, "kgQCCAM="=음악, "kgQCCAQ="=학습, "kgQCCAU="=탐험
    func kidsHome(params: String?, age: KidsAge) async throws -> [VideoItem] {
        var body: [String: Any] = ["browseId": "FEkids_home"]
        if let params { body["params"] = params }
        return Self.parsePage(try await postKids("browse", body: body, age: age)).items
    }

    func kidsSearch(_ query: String, age: KidsAge) async throws -> [VideoItem] {
        Self.parsePage(try await postKids("search", body: ["query": query], age: age)).items
    }

    // MARK: 로그인 계정 전용

    /// FEwhat_to_watch(맞춤 홈), FEhistory(시청 기록), FEsubscriptions(구독) 등
    func browse(_ browseID: String) async throws -> FeedPage {
        Self.parsePage(try await post("browse", body: ["browseId": browseID]))
    }

    func browseContinuation(_ token: String) async throws -> FeedPage {
        Self.parsePage(try await post("browse", body: ["continuation": token]))
    }

    struct Profile {
        var name: String?
        var handle: String?
        var avatar: URL?
    }

    func accountProfile() async -> Profile? {
        guard let json = try? await post("account/account_menu", body: [:]) else { return nil }
        var profile: Profile?
        Self.walk(json) { key, value in
            guard profile == nil, key == "activeAccountHeaderRenderer", let d = value as? [String: Any] else { return }
            profile = Profile(
                name: Self.text(d["accountName"]),
                handle: Self.text(d["channelHandle"]),
                avatar: Self.lastThumbnail(d["accountPhoto"])
            )
        }
        return profile
    }

    /// 로그인한 계정의 YouTube 시청 기록에 남긴다 (yt-dlp --mark-watched 와 같은 방식)
    func markWatched(videoID: String) async {
        guard AuthStore.shared.isLoggedIn,
              let json = try? await post("player", body: ["videoId": videoID]),
              let base = Self.dig(json, "playbackTracking", "videostatsPlaybackUrl", "baseUrl") as? String,
              var comps = URLComponents(string: base)
        else { return }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cpn = String((0..<16).map { _ in alphabet.randomElement()! })
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "ver" || $0.name == "cpn" }
        items.append(URLQueryItem(name: "ver", value: "2"))
        items.append(URLQueryItem(name: "cpn", value: cpn))
        comps.queryItems = items
        guard let url = comps.url else { return }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in AuthStore.shared.headers(origin: "https://www.youtube.com") {
            request.setValue(value, forHTTPHeaderField: key)
        }
        _ = try? await session.data(for: request)
    }

    /// 쇼츠 목록: 검색 결과 안의 쇼츠 선반 + 3분 이하 세로 영상
    func shorts(_ query: String, continuation: String? = nil) async throws -> FeedPage {
        var body: [String: Any] = ["query": query]
        if let continuation { body = ["continuation": continuation] }
        return Self.parseShortsPage(try await post("search", body: body))
    }

    /// YouTube Music 노래 검색. 실패하면 일반 검색으로 대체한다.
    func musicSongs(_ query: String) async -> [VideoItem] {
        var songs: [VideoItem] = []
        var playlists: [String] = []
        if let json = try? await post("search", body: ["query": query], music: true) {
            songs = Self.parseMusicPage(json)
            if songs.count >= 8 { return songs }
            playlists = Self.playlistIDs(in: json)
        }
        // 비로그인 상태의 YouTube Music 검색은 노래 대신 재생목록을 주므로, 재생목록을 열어 노래를 꺼낸다
        for id in playlists.prefix(3) {
            guard let json = try? await post("browse", body: ["browseId": id], music: true) else { continue }
            let known = Set(songs.map(\.id))
            songs += Self.parseMusicPage(json).filter { !known.contains($0.id) }
            if songs.count >= 8 { return Array(songs.prefix(60)) }
        }
        // 그래도 부족하면 일반 검색에서 노래 길이(1~20분) 영상으로 보충
        let known = Set(songs.map(\.id))
        let extra = ((try? await search(query))?.items ?? []).filter { item in
            guard !known.contains(item.id), let s = Self.seconds(of: item.duration) else { return false }
            return (60...1200).contains(s)
        }
        return songs + extra
    }

    /// YouTube Music 가사 (가사가 등록된 노래만). 본문과 출처(예: "출처: LyricFind")
    /// 가사. YouTube Music 가사가 한국 노래인데 로마자(영어 발음 표기)로만 오는 경우가 있어서,
    /// 한글이 하나도 없으면 LRCLIB(무료 가사 DB)에서 한글 원문을 찾아 대신 보여준다.
    func lyrics(videoID: String, title: String = "", artist: String = "", seconds: Double? = nil) async -> (text: String, source: String?)? {
        let yt = await lyrics(videoID: videoID, hl: "ko")
        if let yt, Self.hangulCount(yt.text) > 0 { return yt }
        if let original = await Self.lrclib(title: title, artist: artist, seconds: seconds,
                                            requireHangul: yt != nil) {
            return original
        }
        return yt
    }

    static func hangulCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
    }

    /// "아이유 (IU) - Topic", "[MV] 밤편지 (Official)" 같은 표기를 검색어로 정리
    static func cleanLyricsQuery(_ s: String) -> String {
        var t = s.replacingOccurrences(of: " - Topic", with: "")
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|【[^】]*】"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(official|music video|m/?v|lyrics?|audio|video)\b"#, with: " ", options: .regularExpression)
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func lrclib(title: String, artist: String, seconds: Double?, requireHangul: Bool) async -> (text: String, source: String?)? {
        var parts = title.components(separatedBy: " - ")
        var track = cleanLyricsQuery(parts.count > 1 ? parts.removeLast() : title)
        var singer = cleanLyricsQuery(parts.count >= 1 && title.contains(" - ") ? parts.joined(separator: " - ") : artist)
        if track.isEmpty { track = cleanLyricsQuery(title) }
        if singer.isEmpty { singer = cleanLyricsQuery(artist) }
        guard !track.isEmpty else { return nil }
        var queries: [[URLQueryItem]] = [[URLQueryItem(name: "track_name", value: track), URLQueryItem(name: "artist_name", value: singer)]]
        queries.append([URLQueryItem(name: "q", value: "\(singer) \(track)")])
        queries.append([URLQueryItem(name: "q", value: track)])
        for items in queries {
            var comps = URLComponents(string: "https://lrclib.net/api/search")!
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            req.setValue("KTUBE/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let picked = list.compactMap { r -> (String, Double)? in
                guard let text = r["plainLyrics"] as? String, !text.isEmpty else { return nil }
                if requireHangul && hangulCount(text) == 0 { return nil }
                let diff = seconds.map { abs(((r["duration"] as? Double) ?? 0) - $0) } ?? 0
                if let seconds, seconds > 0, diff > 15 { return nil }
                return (text, diff)
            }.min { $0.1 < $1.1 }
            if let picked { return (picked.0, "출처: LRCLIB") }
        }
        return nil
    }

    private func lyrics(videoID: String, hl: String) async -> (text: String, source: String?)? {
        guard let next = try? await post("next", body: ["videoId": videoID], music: true, hl: hl) else { return nil }
        var browseID: String?
        Self.walk(next) { key, value in
            if browseID == nil, key == "browseId", let id = value as? String, id.hasPrefix("MPLY") { browseID = id }
        }
        guard let browseID, let json = try? await post("browse", body: ["browseId": browseID], music: true, hl: hl) else { return nil }
        var text: String?
        var source: String?
        Self.walk(json) { key, value in
            guard key == "musicDescriptionShelfRenderer", let d = value as? [String: Any] else { return }
            text = Self.runsText(d["description"])
            source = Self.runsText(d["footer"])
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, source)
    }

    private static func runsText(_ node: Any?) -> String? {
        if let runs = dig(node, "runs") as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return text(node)
    }

    /// YouTube Music 「라디오」 — 이 노래와 비슷한 곡들 (YouTube Music 추천 알고리즘)
    func musicRadio(seed videoID: String) async -> [VideoItem] {
        guard let json = try? await post("next", body: ["videoId": videoID, "playlistId": "RDAMVM" + videoID], music: true)
        else { return [] }
        return Self.parseRadio(json).filter { $0.id != videoID }
    }

    static func parseRadio(_ json: Any) -> [VideoItem] {
        var items: [VideoItem] = []
        var seen = Set<String>()
        walk(json) { key, value in
            guard key == "playlistPanelVideoRenderer", let d = value as? [String: Any],
                  let id = d["videoId"] as? String, seen.insert(id).inserted else { return }
            let title = text(d["title"]) ?? ""
            let byline = (dig(d, "longBylineText", "runs") as? [[String: Any]])?.first?["text"] as? String
                ?? (dig(d, "shortBylineText", "runs") as? [[String: Any]])?.first?["text"] as? String ?? ""
            let thumb = lastThumbnail(d["thumbnail"])
            items.append(VideoItem(id: id, title: title, channel: byline, channelThumbnail: nil,
                                   thumbnail: upscaleMusicThumbnail(thumb), duration: text(d["lengthText"]),
                                   views: nil, published: nil, isLive: false))
        }
        return items
    }

    /// 검색 결과 안의 재생목록 ID ("VL..." browseId), 나온 순서대로
    static func playlistIDs(in json: Any) -> [String] {
        var ids: [String] = []
        walk(json) { key, value in
            if key == "browseId", let id = value as? String, id.hasPrefix("VL"), !ids.contains(id) { ids.append(id) }
        }
        return ids
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

    static func parseShortsPage(_ json: Any) -> FeedPage {
        var items: [VideoItem] = []
        var seen = Set<String>()
        var token: String?

        walk(json) { key, value in
            guard let dict = value as? [String: Any] else { return }
            var parsed: VideoItem?
            switch key {
            case "shortsLockupViewModel":
                parsed = parseShortsLockup(dict)
            case "reelItemRenderer":
                if let id = dict["videoId"] as? String {
                    parsed = VideoItem(id: id, title: text(dict["headline"]) ?? "", channel: "",
                                       channelThumbnail: nil, thumbnail: lastThumbnail(dict["thumbnail"]),
                                       duration: nil, views: text(dict["viewCountText"]), published: nil, isLive: false)
                }
            case "videoRenderer":
                if let video = parseVideoRenderer(dict), let seconds = seconds(of: video.duration), seconds <= 180 {
                    parsed = video
                }
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

    static func parseMusicPage(_ json: Any) -> [VideoItem] {
        var items: [VideoItem] = []
        var seen = Set<String>()
        walk(json) { key, value in
            guard key == "musicResponsiveListItemRenderer", let d = value as? [String: Any] else { return }
            // 노래/동영상만 (재생목록·앨범·아티스트·에피소드는 playlistItemData가 없거나 타입으로 걸러냄)
            guard let id = dig(d, "playlistItemData", "videoId") as? String else { return }

            let columns = d["flexColumns"] as? [[String: Any]] ?? []
            func column(_ i: Int) -> [String] {
                guard columns.count > i,
                      let runs = dig(columns[i], "musicResponsiveListItemFlexColumnRenderer", "text", "runs") as? [[String: Any]]
                else { return [] }
                return runs.compactMap { $0["text"] as? String }
                    .filter { $0.trimmingCharacters(in: .whitespaces) != "•" && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            let title = column(0).joined()
            var meta = column(1)
            let typeLabels: Set<String> = ["노래", "Song", "동영상", "Video"]
            let excluded: Set<String> = ["에피소드", "Episode", "팟캐스트", "Podcast", "재생목록", "Playlist"]
            if let first = meta.first, excluded.contains(first) { return }
            if let first = meta.first, typeLabels.contains(first) { meta.removeFirst() }
            guard seen.insert(id).inserted else { return }
            // 재생목록 안의 노래는 재생 시간이 오른쪽 고정 칸(fixedColumns)에 있다
            let fixed = (d["fixedColumns"] as? [[String: Any]])?.first
                .flatMap { text(dig($0, "musicResponsiveListItemFixedColumnRenderer", "text")) }
            let duration = meta.last.flatMap { seconds(of: $0) != nil ? $0 : nil } ?? fixed.flatMap { seconds(of: $0) != nil ? $0 : nil }
            let artist = meta.first { seconds(of: $0) == nil } ?? ""
            let thumb = lastThumbnail(dig(d, "thumbnail", "musicThumbnailRenderer", "thumbnail"))

            items.append(VideoItem(id: id, title: title, channel: artist, channelThumbnail: nil,
                                   thumbnail: upscaleMusicThumbnail(thumb), duration: duration,
                                   views: nil, published: nil, isLive: false))
        }
        return items
    }

    /// "3:45", "1:02:03" → 초. 형식이 아니면 nil
    static func seconds(of text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let n = Int(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    private static func upscaleMusicThumbnail(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let s = url.absoluteString
        if let range = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: range, with: "=w400-h400"))
        }
        return url
    }

    private static func parseShortsLockup(_ d: [String: Any]) -> VideoItem? {
        var id = dig(d, "onTap", "innertubeCommand", "reelWatchEndpoint", "videoId") as? String
        if id == nil, let entity = d["entityId"] as? String {
            id = entity.replacingOccurrences(of: "shorts-shelf-item-", with: "")
        }
        guard let id, !id.isEmpty else { return nil }
        return VideoItem(
            id: id,
            title: dig(d, "overlayMetadata", "primaryText", "content") as? String ?? "",
            channel: "",
            channelThumbnail: nil,
            thumbnail: lastSource(dig(d, "thumbnail", "sources")),
            duration: nil,
            views: dig(d, "overlayMetadata", "secondaryText", "content") as? String,
            published: nil,
            isLive: false
        )
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
