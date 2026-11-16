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
    let AlbumId: String?
    let UserData: UserDataInfo?

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
        _server = d.string(forKey: "jf.server") ?? "http://mistylake.duckdns.org"
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
    func playbackURLs(itemID: String, audio: Bool, container: String?) -> [URL] {
        guard let token, let userID else { return [] }
        let s = server
        let session = UUID().uuidString
        if audio {
            let q = "UserId=\(userID)&DeviceId=\(deviceID)&api_key=\(token)&PlaySessionId=\(session)"
                + "&MaxStreamingBitrate=320000&Container=mp3,aac,m4a%7Caac,m4b%7Caac,flac,alac,m4a%7Calac,wav"
                + "&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac"
            return [URL(string: "\(s)/Audio/\(itemID)/universal?\(q)")].compactMap { $0 }
        }
        var urls: [URL?] = []
        let c = (container ?? "").lowercased()
        if c.contains("mp4") || c.contains("m4v") || c.contains("mov") {
            urls.append(URL(string: "\(s)/Videos/\(itemID)/stream?static=true&api_key=\(token)&MediaSourceId=\(itemID)"))
        }
        let base = "\(s)/Videos/\(itemID)/master.m3u8?api_key=\(token)&MediaSourceId=\(itemID)&DeviceId=\(deviceID)&PlaySessionId=\(session)"
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

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
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

    private static func items(_ path: String) async throws -> [JFItem] {
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
        let q = "limit=16&mediaTypes=Video&fields=\(fields)&enableImageTypes=Primary,Backdrop,Thumb"
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
            channel: subtitle.isEmpty ? "내 미디어" : subtitle,
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

    func sources(for id: String, audioOnly: Bool) -> [PlaybackSource] {
        let raw = String(id.dropFirst(3))
        let info = item(raw)
        let audio = info?.isAudio ?? audioOnly
        return JellyfinSession.shared.playbackURLs(itemID: raw, audio: audio, container: info?.Container)
            .map { PlaybackSource.single($0) }
    }
}
