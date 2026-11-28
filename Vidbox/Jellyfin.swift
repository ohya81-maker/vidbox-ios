import Foundation
import SwiftUI

// MARK: - Jellyfin (내 미디어 서버) 연결
//
// 로그인: POST /Users/AuthenticateByName → AccessToken, User.Id (기기에 저장, 비밀번호는 저장하지 않음)
// 목록: /UserViews, /UserItems/Resume, /Items/Latest, /Items?parentId=
// 재생: 영상은 HLS(master.m3u8, 가능하면 원본 그대로), 음악은 /Audio/{id}/universal
// 앱 안에서는 영상 ID를 "jf:<itemId>"로 써서 K-TUBE 플레이어(백그라운드·잠금화면)로 그대로 재생한다.

struct JFItem: Identifiable, Hashable, Decodable {
    let Id: String
    let Name: String?
    let `Type`: String?
    let CollectionType: String?
    let IsFolder: Bool?
    let MediaType: String?
    let SeriesName: String?
    let SeasonName: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let Overview: String?
    let AlbumArtist: String?
    let Album: String?
    let Container: String?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    let ParentBackdropItemId: String?
    let SeriesId: String?
    let SeasonId: String?
    let AlbumId: String?
    let UserData: UserDataInfo?
    /// 재생 위치 미리보기 이미지 정보 (서버가 만들어 둔 경우): [미디어소스ID: [폭: 정보]]
    let Trickplay: [String: [String: TrickplayInfo]]?

    struct TrickplayInfo: Hashable, Decodable {
        let Width: Int?
        let Height: Int?
        let TileWidth: Int?
        let TileHeight: Int?
        let ThumbnailCount: Int?
        let Interval: Int?
    }

    /// 멈춘 위치의 화면: 미리보기 묶음 이미지 URL + 그 안의 칸 위치(열, 행, 열 수, 행 수, 가로세로비)
    var pausedFrame: (url: URL, col: Int, row: Int, cols: Int, rows: Int, aspect: Double)? {
        guard let entry = Trickplay?.first,
              let best = entry.value.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }).last,
              case let (source, width, info) = (entry.key, best.key, best.value),
              let interval = info.Interval, interval > 0,
              let cols = info.TileWidth, let rows = info.TileHeight, cols > 0, rows > 0,
              let token = JellyfinSession.shared.token
        else { return nil }
        let ms = Int((UserData?.PlaybackPositionTicks ?? 0) / 10_000)
        var thumb = ms / interval
        if let count = info.ThumbnailCount, count > 0 { thumb = min(thumb, count - 1) }
        let perSheet = cols * rows
        let sheet = thumb / perSheet
        let inSheet = thumb % perSheet
        let aspect = Double(info.Width ?? 16) / Double(max(info.Height ?? 9, 1))
        guard let url = URL(string: "\(JellyfinSession.shared.server)/Videos/\(Id)/Trickplay/\(width)/\(sheet).jpg?MediaSourceId=\(source)&ApiKey=\(token)")
        else { return nil }
        return (url, inSheet % cols, inSheet / cols, cols, rows, aspect)
    }

    struct UserDataInfo: Hashable, Decodable {
        let PlaybackPositionTicks: Int64?
        let PlayedPercentage: Double?
        let Played: Bool?
    }

    var id: String { Id }
    var isFolder: Bool { IsFolder ?? false }
    var isAudio: Bool { MediaType == "Audio" || `Type` == "Audio" }

    var title: String {
        if `Type` == "Episode" {
            let s = ParentIndexNumber.map { "S\($0)" } ?? ""
            let e = IndexNumber.map { "E\($0)" } ?? ""
            let code = s + e
            return code.isEmpty ? (Name ?? "") : "\(code) · \(Name ?? "")"
        }
        if `Type` == "Audio", let n = IndexNumber { return "\(n). \(Name ?? "")" }
        return Name ?? ""
    }

    var subtitle: String {
        if let series = SeriesName { return series }
        if let artist = AlbumArtist { return artist }
        if let year = ProductionYear { return "\(year)" }
        return ""
    }

    var resumeSeconds: Double {
        Double(UserData?.PlaybackPositionTicks ?? 0) / 10_000_000
    }

    var progress: Double? {
        guard let p = UserData?.PlayedPercentage, p > 0 else { return nil }
        return min(1, p / 100)
    }

    var durationText: String? {
        guard let ticks = RunTimeTicks, ticks > 0 else { return nil }
        let total = Int(ticks / 10_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct JFItemsResponse: Decodable {
    let Items: [JFItem]
    let TotalRecordCount: Int?
}

private struct JFAuthResponse: Decodable {
    struct User: Decodable { let Id: String; let Name: String? }
    let AccessToken: String
    let User: User
}

/// 로그인 정보 (토큰은 키체인, 나머지는 기기 설정에)
final class JellyfinSession: @unchecked Sendable {
    static let shared = JellyfinSession()
    private let lock = NSLock()
    private var _server: String
    private var _token: String?
    private var _userID: String?
    private var _userName: String?
    let deviceID: String

    private init() {
        let d = UserDefaults.standard
        var saved = d.string(forKey: "jf.server")
        // 미디어 서버가 https로 바뀜: 예전에 저장된 http 주소를 옮겨 준다
        if let s = saved, s.hasPrefix("http://mistylake.duckdns.org") {
            saved = "https://" + String(s.dropFirst("http://".count))
            d.set(saved, forKey: "jf.server")
        }
        _server = saved ?? "https://mistylake.duckdns.org"
        _userID = d.string(forKey: "jf.userID")
        _userName = d.string(forKey: "jf.userName")
        _token = Keychain.read("jf.token").flatMap { String(data: $0, encoding: .utf8) }
        if let id = d.string(forKey: "jf.deviceID") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            d.set(deviceID, forKey: "jf.deviceID")
        }
    }

    var server: String { lock.lock(); defer { lock.unlock() }; return _server }
    var token: String? { lock.lock(); defer { lock.unlock() }; return _token }
    var userID: String? { lock.lock(); defer { lock.unlock() }; return _userID }
    var userName: String? { lock.lock(); defer { lock.unlock() }; return _userName }
    var isLoggedIn: Bool { token != nil && userID != nil }

    func save(server: String, token: String, userID: String, userName: String?) {
        lock.lock()
        _server = server; _token = token; _userID = userID; _userName = userName
        lock.unlock()
        let d = UserDefaults.standard
        d.set(server, forKey: "jf.server")
        d.set(userID, forKey: "jf.userID")
        d.set(userName, forKey: "jf.userName")
        Keychain.write("jf.token", Data(token.utf8))
    }

    func clear() {
        lock.lock()
        _token = nil; _userID = nil; _userName = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: "jf.userID")
        UserDefaults.standard.removeObject(forKey: "jf.userName")
        Keychain.delete("jf.token")
    }

    var authHeader: String {
        var h = "MediaBrowser Client=\"K-TUBE\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    // MARK: 주소 만들기

    func imageURL(_ item: JFItem, backdrop: Bool = false, width: Int = 480) -> URL? {
        if backdrop {
            if let tag = item.BackdropImageTags?.first {
                return URL(string: "\(server)/Items/\(item.Id)/Images/Backdrop?fillWidth=\(width)&quality=85&tag=\(tag)")
            }
            if let parent = item.ParentBackdropItemId {
                return URL(string: "\(server)/Items/\(parent)/Images/Backdrop?fillWidth=\(width)&quality=85")
            }
        }
        if let tag = item.ImageTags?["Primary"] {
            return URL(string: "\(server)/Items/\(item.Id)/Images/Primary?fillWidth=\(width)&quality=85&tag=\(tag)")
        }
        if let series = item.SeriesId {
            return URL(string: "\(server)/Items/\(series)/Images/Primary?fillWidth=\(width)&quality=85")
        }
        if let album = item.AlbumId {
            return URL(string: "\(server)/Items/\(album)/Images/Primary?fillWidth=\(width)&quality=85")
        }
        return nil
    }

    /// 재생 후보 (앞에서부터 시도): 원본 그대로 → HLS(가능하면 원본 복사) → HLS(H.264로 변환)
    func playbackURLs(itemID: String, audio: Bool, container: String?, choice: JFPlaybackChoice? = nil) -> [URL] {
        guard let token, let userID else { return [] }
        let s = server
        let session = UUID().uuidString
        if audio {
            let q = "UserId=\(userID)&DeviceId=\(deviceID)&ApiKey=\(token)&PlaySessionId=\(session)"
                + "&MaxStreamingBitrate=320000&Container=mp3,aac,m4a%7Caac,m4b%7Caac,flac,alac,m4a%7Calac,wav"
                + "&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac"
            return [URL(string: "\(s)/Audio/\(itemID)/universal?\(q)")].compactMap { $0 }
        }
        var urls: [URL?] = []
        let c = (choice?.container ?? container ?? "").lowercased()
        let source = choice?.mediaSourceID ?? itemID
        // 그림 자막을 입혀야 하면 원본 파일 직접 재생은 건너뛴다 (글자 자막은 앱이 따로 그리므로 상관없음)
        if choice?.subtitleIsText != false || choice?.subtitleIndex == nil, JFQuality.current == .original, c.contains("mp4") || c.contains("m4v") || c.contains("mov") {
            urls.append(URL(string: "\(s)/Videos/\(itemID)/stream?static=true&ApiKey=\(token)&MediaSourceId=\(source)"))
        }
        var base = "\(s)/Videos/\(itemID)/master.m3u8?ApiKey=\(token)&MediaSourceId=\(source)&DeviceId=\(deviceID)&PlaySessionId=\(session)"
        // Jellyfin 계정 설정(선호 음성·자막 언어, 자막 모드)에 따라 서버가 고른 트랙
        if let a = choice?.audioIndex { base += "&AudioStreamIndex=\(a)" }
        // 글자 자막(srt·ass 등)은 파일로 따로 받아 앱이 재생 시간에 맞춰 그린다 (HLS 자막은 싱크가 어긋났다).
        // 그림 자막(PGS 등)만 영상에 입혀서 받는다
        if let sub = choice?.subtitleIndex, choice?.subtitleIsText == false {
            base += "&SubtitleStreamIndex=\(sub)&SubtitleMethod=Encode"
        }
        let quality = JFQuality.current
        if quality != .original {
            return [URL(string: base + "&VideoCodec=h264&AudioCodec=aac&SegmentContainer=ts"
                        + "&MaxStreamingBitrate=\(quality.rawValue)&VideoBitrate=\(quality.rawValue - 192_000)"
                        + "&TranscodingMaxAudioChannels=2&AllowVideoStreamCopy=false")].compactMap { $0 }
        }
        if choice?.subtitleIndex != nil, choice?.subtitleIsText == false {
            return [URL(string: base + "&VideoCodec=h264&AudioCodec=aac&SegmentContainer=ts"
                        + "&MaxStreamingBitrate=10000000&TranscodingMaxAudioChannels=2&AllowVideoStreamCopy=false")].compactMap { $0 }
        }
        // 음성이 아이폰이 못 트는 코덱(DTS·TrueHD 등)이라 변환해야 하면: 영상은 그대로, 음성만 AAC로 바꿔 TS 조각으로.
        // fMP4 조각에 '영상 복사 + 음성 변환'을 섞으면 재생 중 갑자기 소리가 끊기는 일이 있었다 (예: DTS 영화)
        let audioCodec = choice?.audioCodec ?? ""
        if !audioCodec.isEmpty, !["aac", "mp3", "ac3", "eac3"].contains(audioCodec), choice?.videoCodec == "h264" {
            urls.append(URL(string: base + "&VideoCodec=h264&AudioCodec=aac&SegmentContainer=ts"
                            + "&MaxStreamingBitrate=60000000&TranscodingMaxAudioChannels=2&EnableAutoStreamCopy=true"
                            + "&AllowVideoStreamCopy=true&AllowAudioStreamCopy=false&BreakOnNonKeyFrames=true"))
        }
        urls.append(URL(string: base + "&VideoCodec=h264,hevc&AudioCodec=aac,mp3,ac3,eac3&SegmentContainer=mp4"
                        + "&MaxStreamingBitrate=60000000&TranscodingMaxAudioChannels=2&EnableAutoStreamCopy=true"
                        + "&AllowVideoStreamCopy=true&AllowAudioStreamCopy=true&BreakOnNonKeyFrames=true"))
        urls.append(URL(string: base + "&VideoCodec=h264&AudioCodec=aac&SegmentContainer=ts"
                        + "&MaxStreamingBitrate=10000000&TranscodingMaxAudioChannels=2&AllowVideoStreamCopy=false"))
        return urls.compactMap { $0 }
    }
}

// MARK: - API

enum JellyfinError: LocalizedError {
    case server(Int)
    case badLogin
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .server(let code): return "서버 응답 오류 (\(code))"
        case .badLogin: return "아이디나 비밀번호가 맞지 않아요."
        case .notLoggedIn: return "로그인이 필요해요."
        }
    }
}

enum JellyfinAPI {
    static let fields = "Overview,PrimaryImageAspectRatio,Container,ParentId"

    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                server: String? = nil) async throws -> Data {
        let s = JellyfinSession.shared
        guard let url = URL(string: (server ?? s.server) + path) else { throw JellyfinError.server(0) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue(s.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw JellyfinError.badLogin }
        guard (200..<300).contains(code) else { throw JellyfinError.server(code) }
        return data
    }

    static func login(server: String, user: String, password: String) async throws {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/web") { s.removeLast(4) }
        if !s.hasPrefix("http") { s = "http://" + s }
        let data = try await request("/Users/AuthenticateByName", method: "POST",
                                     body: ["Username": user, "Pw": password], server: s)
        let auth = try JSONDecoder().decode(JFAuthResponse.self, from: data)
        JellyfinSession.shared.save(server: s, token: auth.AccessToken, userID: auth.User.Id, userName: auth.User.Name ?? user)
    }

    static func items(_ path: String) async throws -> [JFItem] {
        let data = try await request(path)
        if let list = try? JSONDecoder().decode(JFItemsResponse.self, from: data) { return list.Items }
        return try JSONDecoder().decode([JFItem].self, from: data)
    }

    private static var user: String {
        get throws {
            guard let id = JellyfinSession.shared.userID else { throw JellyfinError.notLoggedIn }
            return id
        }
    }

    static func libraries() async throws -> [JFItem] {
        let u = try user
        if let list = try? await items("/UserViews?userId=\(u)") { return list }
        return try await items("/Users/\(u)/Views")
    }

    static func resume() async throws -> [JFItem] {
        let u = try user
        let q = "limit=16&mediaTypes=Video&fields=\(fields),Trickplay&enableImageTypes=Primary,Backdrop,Thumb"
        if let list = try? await items("/UserItems/Resume?userId=\(u)&\(q)") { return list }
        return try await items("/Users/\(u)/Items/Resume?\(q)")
    }

    static func latest(in library: String) async throws -> [JFItem] {
        let u = try user
        let q = "parentId=\(library)&limit=16&fields=\(fields)"
        if let list = try? await items("/Items/Latest?userId=\(u)&\(q)") { return list }
        return try await items("/Users/\(u)/Items/Latest?\(q)")
    }

    static func children(of parent: String, start: Int = 0, limit: Int = 60) async throws -> [JFItem] {
        let u = try user
        return try await items("/Items?userId=\(u)&parentId=\(parent)&sortBy=ParentIndexNumber,IndexNumber,SortName"
                               + "&sortOrder=Ascending&fields=\(fields)&startIndex=\(start)&limit=\(limit)")
    }

    /// 서버가 이 사용자 설정(자막 모드·선호 언어)으로 고른 기본 음성·자막 트랙
    static func playbackChoice(itemID: String) async -> JFPlaybackChoice? {
        guard let u = JellyfinSession.shared.userID,
              let data = try? await request("/Items/\(itemID)/PlaybackInfo?userId=\(u)", method: "POST", body: ["UserId": u]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = (json["MediaSources"] as? [[String: Any]])?.first
        else { return nil }
        let streams = source["MediaStreams"] as? [[String: Any]] ?? []
        let subIndex = source["DefaultSubtitleStreamIndex"] as? Int
        let sub = streams.first { ($0["Index"] as? Int) == subIndex && ($0["Type"] as? String) == "Subtitle" }
        func tracks(_ type: String) -> [JFTrack] {
            streams.filter { ($0["Type"] as? String) == type }.compactMap { st in
                guard let i = st["Index"] as? Int else { return nil }
                let title = (st["DisplayTitle"] as? String) ?? (st["Language"] as? String) ?? "\(type) \(i)"
                return JFTrack(index: i, title: title, isText: st["IsTextSubtitleStream"] as? Bool ?? true,
                               codec: (st["Codec"] as? String)?.lowercased(), language: st["Language"] as? String)
            }
        }
        return JFPlaybackChoice(
            mediaSourceID: source["Id"] as? String,
            container: source["Container"] as? String,
            audioIndex: source["DefaultAudioStreamIndex"] as? Int,
            subtitleIndex: (subIndex ?? -1) >= 0 && sub != nil ? subIndex : nil,
            subtitleIsText: sub?["IsTextSubtitleStream"] as? Bool ?? true,
            audioTracks: tracks("Audio"),
            subtitleTracks: tracks("Subtitle"),
            videoCodec: (streams.first { ($0["Type"] as? String) == "Video" }?["Codec"] as? String)?.lowercased()
        )
    }

    /// 시리즈·시즌을 「재생」했을 때 틀 화: 이어 볼 화(NextUp) → 없으면 첫 화
    static func episodeToPlay(for item: JFItem) async -> JFItem? {
        guard let u = JellyfinSession.shared.userID else { return nil }
        let seriesID = item.Type == "Series" ? item.Id : item.SeriesId
        if let s = seriesID, item.Type == "Series",
           let next = try? await items("/Shows/NextUp?seriesId=\(s)&userId=\(u)&limit=1&fields=\(fields)"),
           let first = next.first {
            return first
        }
        if let s = seriesID {
            var path = "/Shows/\(s)/Episodes?userId=\(u)&fields=\(fields)"
            if item.Type == "Season" { path += "&seasonId=\(item.Id)" }
            if let all = try? await items(path), !all.isEmpty {
                // 끝까지 본 화는 건너뛰고 처음 안 본 화부터
                return all.first { ($0.progress ?? 0) < 0.95 } ?? all.first
            }
        }
        // 그 밖의 폴더(모음집 등): 안에 든 첫 영상
        if let kids = try? await children(of: item.Id, limit: 20) {
            return kids.first { !$0.isFolder }
        }
        return nil
    }

    /// 다음에 볼 것: 에피소드면 같은 시리즈의 다음 화들, 아니면 비슷한 작품
    static func upNext(after itemID: String) async -> [JFItem] {
        guard let u = JellyfinSession.shared.userID,
              let data = try? await request("/Items/\(itemID)?userId=\(u)"),
              let item = try? JSONDecoder().decode(JFItem.self, from: data)
        else { return [] }
        if item.Type == "Episode", let series = item.SeriesId,
           let all = try? await items("/Shows/\(series)/Episodes?userId=\(u)&fields=\(fields)") {
            if let i = all.firstIndex(where: { $0.Id == itemID }) { return Array(all.dropFirst(i + 1).prefix(30)) }
            return all
        }
        return (try? await items("/Items/\(itemID)/Similar?userId=\(u)&limit=16&fields=\(fields)")) ?? []
    }

    // MARK: 시청 위치 알리기 (웹·TV에서 이어 보기)

    static func report(_ event: String, itemID: String, seconds: Double, paused: Bool = false) {
        let ticks = Int64(max(0, seconds) * 10_000_000)
        let body: [String: Any] = ["ItemId": itemID, "PositionTicks": ticks, "IsPaused": paused,
                                   "CanSeek": true, "PlayMethod": "Transcode", "MediaSourceId": itemID]
        let path = event == "start" ? "/Sessions/Playing"
            : event == "stop" ? "/Sessions/Playing/Stopped" : "/Sessions/Playing/Progress"
        Task { _ = try? await request(path, method: "POST", body: body) }
    }
}

// MARK: - K-TUBE 플레이어와 연결

extension JFItem {
    /// K-TUBE 플레이어에 넘길 항목. id = "jf:<itemId>"
    var videoItem: VideoItem {
        let s = JellyfinSession.shared
        var item = VideoItem(
            id: "jf:" + Id,
            title: title,
            channel: SeriesName ?? AlbumArtist ?? "내 미디어",
            channelThumbnail: nil,
            thumbnail: s.imageURL(self, backdrop: !isAudio, width: 960) ?? s.imageURL(self, width: 960),
            duration: durationText,
            views: nil,
            published: ProductionYear.map { "\($0)" },
            isLive: false
        )
        item.channelID = nil
        JellyfinCatalog.shared.remember(self)
        return item
    }
}

/// 재생에 필요한 항목 정보를 잠시 기억 (컨테이너·음악 여부)
final class JellyfinCatalog: @unchecked Sendable {
    static let shared = JellyfinCatalog()
    private let lock = NSLock()
    private var items: [String: JFItem] = [:]

    func remember(_ item: JFItem) {
        lock.lock(); items[item.Id] = item; lock.unlock()
    }

    func item(_ id: String) -> JFItem? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    static func isJellyfin(_ id: String) -> Bool { id.hasPrefix("jf:") }

    func sources(for id: String, audioOnly: Bool) async -> [PlaybackSource] {
        let raw = String(id.dropFirst(3))
        let info = item(raw)
        let audio = info?.isAudio ?? audioOnly
        var choice = audio ? nil : await JellyfinAPI.playbackChoice(itemID: raw)
        lock.lock()
        let override = overrides[raw]
        lock.unlock()
        if var c = choice, let o = override {
            if let a = o.audioIndex { c.audioIndex = a }
            if let sIdx = o.subtitleIndex {
                if sIdx < 0 {
                    c.subtitleIndex = nil
                } else {
                    c.subtitleIndex = sIdx
                    c.subtitleIsText = c.subtitleTracks.first { $0.index == sIdx }?.isText ?? true
                }
            }
            choice = c
        }
        lock.lock(); choices[raw] = choice; lock.unlock()
        return JellyfinSession.shared.playbackURLs(itemID: raw, audio: audio, container: info?.Container, choice: choice)
            .map { PlaybackSource.single($0) }
    }

    private var choices: [String: JFPlaybackChoice?] = [:]
    private var overrides: [String: JFOverride] = [:]

    /// 지금 재생 중인 영상의 트랙 정보 (⚙️ 화면에서 사용)
    func choice(for id: String) -> JFPlaybackChoice? {
        lock.lock(); defer { lock.unlock() }
        return choices[String(id.dropFirst(3))] ?? nil
    }

    func setOverride(_ id: String, audio: Int? = nil, subtitle: Int? = nil) {
        let raw = String(id.dropFirst(3))
        lock.lock()
        var o = overrides[raw] ?? JFOverride()
        if let audio { o.audioIndex = audio }
        if let subtitle { o.subtitleIndex = subtitle }
        overrides[raw] = o
        lock.unlock()
    }
    /// 이 영상에 자막을 켜기로 했는지 (재생기가 자막 트랙을 골라 켤 때 사용)
    /// 켜야 할 자막 트랙 (없으면 nil = 자막 끔)
    func wantedSubtitle(_ id: String) -> JFTrack? {
        lock.lock(); defer { lock.unlock() }
        guard let c = choices[String(id.dropFirst(3))] ?? nil, let idx = c.subtitleIndex else { return nil }
        return c.subtitleTracks.first { $0.index == idx }
    }

    /// 앱이 직접 그릴 글자 자막 파일 주소 (WebVTT로 변환해서 받는다)
    func subtitleFileURL(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let raw = String(id.dropFirst(3))
        guard let c = choices[raw] ?? nil, let idx = c.subtitleIndex, c.subtitleIsText,
              let token = JellyfinSession.shared.token else { return nil }
        let source = c.mediaSourceID ?? raw
        return URL(string: "\(JellyfinSession.shared.server)/Videos/\(raw)/\(source)/Subtitles/\(idx)/0/Stream.vtt?ApiKey=\(token)")
    }

    /// 같은 종류(글자 자막) 안에서 몇 번째인지 — 언어로 못 찾을 때 순서로 고른다
    func textSubtitlePosition(_ id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let c = choices[String(id.dropFirst(3))] ?? nil, let idx = c.subtitleIndex else { return nil }
        return c.subtitleTracks.filter(\.isText).firstIndex { $0.index == idx }
    }

    /// 자막 싱크 (초, +면 자막을 늦게 · -면 빠르게). 같은 시리즈는 보통 같은 파일 묶음이라 시리즈 단위로 기억
    private func subtitleOffsetKey(_ id: String) -> String {
        let raw = String(id.dropFirst(3))
        return "subOffset." + (item(raw)?.SeriesId ?? raw)
    }
    func subtitleOffset(_ id: String) -> Double { UserDefaults.standard.double(forKey: subtitleOffsetKey(id)) }
    func setSubtitleOffset(_ id: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: subtitleOffsetKey(id))
    }

    func wantsSubtitles(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (choices[String(id.dropFirst(3))] ?? nil)?.subtitleIndex != nil
    }
}

struct JFTrack: Sendable, Hashable, Identifiable {
    var index: Int
    var title: String
    var isText: Bool = true
    /// 코덱 (예: aac, dts, truehd)
    var codec: String? = nil
    /// 언어 코드 (예: kor, eng)
    var language: String? = nil
    var id: Int { index }
}

struct JFPlaybackChoice: Sendable {
    var mediaSourceID: String?
    var container: String?
    var audioIndex: Int?
    var subtitleIndex: Int?
    var subtitleIsText: Bool
    var audioTracks: [JFTrack] = []
    var subtitleTracks: [JFTrack] = []
    var videoCodec: String? = nil

    /// 고른 음성 트랙의 코덱
    var audioCodec: String? {
        let t = audioTracks.first { $0.index == audioIndex } ?? audioTracks.first
        return t?.codec
    }
}

/// 재생 화면 ⚙️에서 고른 값 (영상마다 음성·자막, 화질은 전체 공통)
struct JFOverride: Sendable {
    var audioIndex: Int?
    /// -1 = 자막 끄기
    var subtitleIndex: Int?
}

enum JFQuality: Int, CaseIterable, Identifiable {
    case original = 0, high = 20_000_000, hd = 8_000_000, sd = 3_000_000, low = 1_200_000
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: return "원본 (가능하면 변환 없이)"
        case .high: return "최대 20Mbps"
        case .hd: return "최대 8Mbps (1080p)"
        case .sd: return "최대 3Mbps (720p)"
        case .low: return "최대 1.2Mbps (데이터 절약)"
        }
    }
    /// 탭 제목용 짧은 이름
    var short: String {
        switch self {
        case .original: return "원본"
        case .high: return "20M"
        case .hd: return "1080p"
        case .sd: return "720p"
        case .low: return "절약"
        }
    }
    static var current: JFQuality {
        get { JFQuality(rawValue: UserDefaults.standard.integer(forKey: "jf.maxBitrate")) ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "jf.maxBitrate") }
    }
}

// MARK: - 앱이 직접 그리는 자막

struct SubtitleCue: Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleParser {
    /// WebVTT/SRT → 자막 목록 (시작 시간 순)
    static func parse(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1].split(separator: " ").first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timeIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(start: a, end: b, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03.456" · "02:03.456" · "00:01:02,345" → 초
    private static func time(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":").map(String.init)
        guard !comps.isEmpty, let last = Double(comps.last!) else { return nil }
        var total = last
        if comps.count >= 2, let m = Double(comps[comps.count - 2]) { total += m * 60 }
        if comps.count >= 3, let h = Double(comps[comps.count - 3]) { total += h * 3600 }
        return total
    }
}

/// 지금 보여 줄 자막 한 줄 (자주 바뀌므로 재생 화면 전체와 따로)
@MainActor
final class SubtitleClock: ObservableObject {
    @Published var text: String?
    var cues: [SubtitleCue] = []
    /// 자막 싱크 보정 (초, +면 자막을 늦게)
    private(set) var offset: Double = 0
    private var index = 0
    private var lastTime: Double?

    func reset(_ new: [SubtitleCue], offset: Double = 0) {
        cues = new; index = 0; text = nil; self.offset = offset
        if new.isEmpty { lastTime = nil }
        if let lastTime, !new.isEmpty { update(lastTime) }
    }

    func setOffset(_ value: Double) {
        offset = value
        index = 0
        if let lastTime { update(lastTime) }
    }

    func update(_ playerTime: Double) {
        lastTime = playerTime
        let t = playerTime - offset
        guard !cues.isEmpty else { if text != nil { text = nil }; return }
        // 앞으로 진행하면 이어서, 뒤로 가면 처음부터 찾는다
        if index >= cues.count || cues[index].start > t { index = 0 }
        while index + 1 < cues.count, cues[index + 1].start <= t { index += 1 }
        // 지금 시각에 걸쳐 있는 자막 (겹치는 줄은 함께)
        var active: [String] = []
        var i = index
        while i >= 0, index - i < 8 {
            let cue = cues[i]
            if cue.start <= t, t < cue.end { active.insert(cue.text, at: 0) }
            i -= 1
        }
        let now: String? = active.isEmpty ? nil : active.joined(separator: "\n")
        if now != text { text = now }
    }
}
