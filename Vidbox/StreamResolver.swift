import AVFoundation
import Foundation
import Network
#if canImport(YouTubeKit)
import YouTubeKit
#endif

/// 재생할 소스
enum PlaybackSource: Sendable {
    /// YouTube가 준 HLS(.m3u8) 또는 단일 파일(m4a/mp4)
    case single(URL)
    /// 앱이 직접 만든 HLS 재생목록. 앱 안의 로컬 서버(127.0.0.1)가 제공한다. 값은 경로("/<id>/master.m3u8")
    case local(String)
    /// 영상/오디오 분리 파일을 AVMutableComposition으로 합쳐 재생
    case split(video: URL, audio: URL)
    /// YouTube가 앞부분만 허용하는 영상용 Android 360p 합본 (끝까지 재생 가능)
    case limited(URL)

    var kind: String {
        switch self {
        case .single(let url): return url.absoluteString.contains("m3u8") ? "youtube-hls" : "file"
        case .local: return "local-hls"
        case .split: return "split"
        case .limited: return "limited-360p"
        }
    }
}

/// 영상 ID → 재생 후보 목록.
///
/// InnerTube `player` API를 iOS 앱 클라이언트로 한 번 호출(≈0.3~0.5초)해서 여러 재생 후보를 만든다.
/// 플레이어는 첫 후보부터 시도하고, 재생이 시작되지 않으면 다음 후보로 넘어간다.
/// 어떤 방식이 이 기기에서 계속 실패하면 기억해 두고 다음부터는 뒤로 미룬다.
actor StreamResolver {
    static let shared = StreamResolver()

    static let iosUserAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    private struct Entry: Sendable {
        let video: [PlaybackSource]
        let audio: [PlaybackSource]
        let date: Date
        /// YouTube가 알려준 실제 길이(초). 재생기가 잘못 계산한 길이를 바로잡을 때 쓴다
        var length: Double? = nil
        /// 다운로드용: 영상(720p 우선) / 원본 오디오 / 앞부분만 허용될 때의 360p 합본
        var downloadVideo: DashFormat? = nil
        var downloadAudio: DashFormat? = nil
        var downloadMuxed: URL? = nil
    }

    /// 다운로드에 쓸 파일 주소
    struct DownloadSources: Sendable {
        let video: DashFormat?
        let audio: DashFormat?
        let muxed: URL?
    }

    func downloadSources(id: String) async throws -> DownloadSources {
        let e = try await entry(for: id)
        return DownloadSources(video: e.downloadVideo, audio: e.downloadAudio, muxed: e.downloadMuxed)
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry, Error>] = [:]
    private var prefetching = 0
    private let ttl: TimeInterval = 3 * 3600

    // MARK: Public

    /// YouTube가 아닌 영상의 재생 주소 (id → 후보, 해당 없으면 nil). 앱 시작 때 등록
    /// 특정 주소(예: Jellyfin 서버)로 재생할 때 붙일 HTTP 헤더
    nonisolated(unsafe) static var externalHeaders: (@Sendable (URL) -> [String: String]?)?
    nonisolated(unsafe) static var externalSources: (@Sendable (String, Bool) async -> [PlaybackSource]?)?

    func candidates(id: String, audioOnly: Bool) async throws -> [PlaybackSource] {
        // 내 미디어(Jellyfin) 등 YouTube가 아닌 영상: 앱이 등록한 곳에서 재생 주소를 받는다
        if let list = await Self.externalSources?(id, audioOnly) {
            if list.isEmpty { throw AppError.noPlayableStream }
            return list
        }
        // 다운로드해 둔 파일이 있으면 그것부터 (인터넷 없이 재생)
        let offline = DownloadIndex.shared.files(for: id, audioOnly: audioOnly).map { PlaybackSource.single($0) }
        guard let entry = try? await entry(for: id) else {
            if !offline.isEmpty { return offline }
            throw AppError.noPlayableStream
        }
        // 영상 모드에서는 영상 후보를 반드시 먼저 (오디오 파일이 앞에 오면 화면 없이 소리만 나옴)
        let list = offline + (audioOnly ? entry.audio + entry.video : entry.video + entry.audio)
        guard !list.isEmpty else { throw AppError.noPlayableStream }
        return list
    }

    /// 백그라운드로 미리 준비. 동시에 너무 많이 요청하지 않도록 4개로 제한.
    /// 미리 받기는 YouTube에 요청을 많이 보낸다 → 너무 잦으면 「봇이 아님을 확인」 차단을 부른다.
    /// 20초에 8개까지만, 차단 응답을 받으면 10분간 미리 받기를 멈춘다 (직접 누른 영상은 그대로 재생 시도)
    private var prefetchTimes: [Date] = []
    static let blockedUntil = BlockClock()

    func prefetch(_ ids: [String]) {
        // 「봇 확인」으로 막힌 동안은 미리 받기를 아예 하지 않는다 (요청이 쌓이면 차단이 더 오래 간다)
        // 단, 로그인돼 있으면 로그인 재생으로 다음 1개만 미리 받는다 (쇼츠가 멈칫하지 않게)
        let blocked = Self.blockedUntil.isBlocked
        if blocked && !AuthStore.shared.isLoggedIn { return }
        let targets = blocked ? Array(ids.prefix(3)) : ids
        for id in targets where !id.hasPrefix("jf:") {
            if let cached = cache[id], Date().timeIntervalSince(cached.date) < ttl { continue }
            guard inflight[id] == nil, prefetching < 3 else { continue }
            prefetchTimes = prefetchTimes.filter { Date().timeIntervalSince($0) < 20 }
            guard prefetchTimes.count < (blocked ? 3 : 8) else { return }
            prefetchTimes.append(Date())
            prefetching += 1
            Task {
                _ = try? await self.entry(for: id)
                self.prefetchDone()
            }
        }
    }

    private func prefetchDone() { prefetching -= 1 }

    /// 캐시에 있는 실제 길이(초)
    func length(id: String) -> Double? { cache[id]?.length }

    func invalidate(_ id: String) {
        cache[id] = nil
    }

    private var refreshed: Set<String> = []

    /// 로그인 재생 주소가 영상 서버에서 거절(403)되면: 보안 토큰을 새로 만들어 한 번만 다시 받는다
    func refreshLoggedIn(id: String, audioOnly: Bool) async -> [PlaybackSource]? {
        guard AuthStore.shared.isLoggedIn, !id.hasPrefix("jf:"), !refreshed.contains(id) else { return nil }
        refreshed.insert(id)
        if refreshed.count > 300 { refreshed.removeAll() }
        cache[id] = nil
        await PoTokenProvider.shared.invalidate()
        guard let entry = await Self.signedIn(id: id) else {
            PlaybackDiag.note("login-retry \(id) fail")
            return nil
        }
        PlaybackDiag.note("login-retry \(id) ok")
        // 거절된 영상: 화질별로 어디서 거절되는지 (앱 실행마다 한 번)
        if let first = entry.video.first, case .single(let url) = first, Self.failProbed.once() {
            Task.detached { await Self.probeHLS(url, id: id) }
        }
        cache[id] = entry
        let list = audioOnly ? entry.audio + entry.video : entry.video + entry.audio
        return list.isEmpty ? nil : list
    }

    /// 마지막 수단: YouTubeKit (느림)
    func slowCandidates(id: String, audioOnly: Bool) async throws -> [PlaybackSource] {
        if Self.blockedUntil.isBlocked { throw AppError.noPlayableStream }
        let entry = try await Self.fetchWithYouTubeKit(id: id)
        let list = audioOnly ? entry.audio + entry.video : entry.video + entry.audio
        guard !list.isEmpty else { throw AppError.noPlayableStream }
        return list
    }

    private func entry(for id: String) async throws -> Entry {
        if let cached = cache[id], Date().timeIntervalSince(cached.date) < ttl {
            return cached
        }
        if let running = inflight[id] {
            return try await running.value
        }
        let task = Task<Entry, Error> {
            // 이미 막힌 상태면 한 번만 확인하고 끝낸다 (다른 방법들로 여러 번 다시 묻지 않기 — 차단을 길게 만든다)
            if Self.blockedUntil.isBlocked {
                // 막힌 동안 로그인돼 있으면 로그인 재생으로 바로 (로그인 안 한 요청을 더 보내지 않기)
                if AuthStore.shared.isLoggedIn, let signed = await Self.signedIn(id: id) { return signed }
                if let fast = try? await Self.fetchFromInnerTube(id: id) { return fast }
                throw AppError.noPlayableStream
            }
            if let fast = try? await Self.fetchFromInnerTube(id: id) { return fast }
            // 「봇 확인」으로 막혔고 로그인돼 있으면: 로그인한 계정으로 재생 정보를 받는다
            if Self.blockedUntil.isBlocked, AuthStore.shared.isLoggedIn,
               let signed = await Self.signedIn(id: id) { return signed }
            // 「봇 확인」 응답은 잠깐씩 섞여 온다 → 느린 방법(4~5초)으로 가기 전에 한 번만 빨리 다시
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let again = try? await Self.fetchFromInnerTube(id: id) { return again }
            // 그래도 막히면 Android 앱 방식(360p 합본)으로 — 빠르고, 봇 확인에 덜 걸린다
            if let muxed = try? await Self.fetchAndroidMuxed(id: id) {
                PlaybackDiag.note("fallback android-muxed \(id)")
                return Entry(video: [.single(muxed)], audio: [], date: Date())
            }
            if Self.blockedUntil.isBlocked { throw AppError.noPlayableStream }
            return try await Self.fetchWithYouTubeKit(id: id)
        }
        inflight[id] = task
        defer { inflight[id] = nil }
        let entry = try await task.value
        cache[id] = entry
        return entry
    }

    // MARK: - 로그인 재생 (봇 확인으로 막혔을 때의 예비)

    private static let tvFailures = FailCounter()
    private static let tvReported = OnceFlag()

    private static let mwebFailures = FailCounter()
    private static let mwebReported = OnceFlag()

    /// 로그인 재생: 웹(watch 페이지 HLS) → 모바일 웹(MWEB, 파일 주소 + 보안 토큰) → TV 앱 방식
    /// (2026-11-18 밤부터 웹은 HLS 없이 SABR만 줘서, 모바일 웹 방식을 추가)
    private static func signedIn(id: String) async -> Entry? {
        if let web = try? await fetchLoggedIn(id: id) { return web }
        if mwebFailures.allowed {
            if let m = try? await fetchMWebLoggedIn(id: id) {
                mwebFailures.success()
                if mwebReported.once() { PlaybackDiag.report("mweb-play", id: id, details: ["ok"]) }
                return m
            }
            mwebFailures.failure()
        }
        if tvFailures.allowed {
            if let tv = try? await fetchTVLoggedIn(id: id) {
                tvFailures.success()
                if tvReported.once() { PlaybackDiag.report("tv-play", id: id, details: ["ok"]) }
                return tv
            }
            tvFailures.failure()
        }
        return nil
    }

    /// Safari로 보는 watch 페이지를 로그인 쿠키와 함께 받아, 그 안의 재생 정보(HLS 주소)를 쓴다.
    /// 로그인된 요청은 「봇이 아님을 확인하세요」를 거의 받지 않는다. 일반 요청이 막혔을 때만 쓴다 (계정 부담 줄이기)
    private static let loginReported = OnceFlag()
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private static func fetchLoggedIn(id: String) async throws -> Entry {
        let t0 = Date()
        var request = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(id)&bpctr=9999999999&has_verified=1")!)
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ko-KR,ko;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (k, v) in AuthStore.shared.headers(origin: "https://www.youtube.com") where k == "Cookie" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let raw = extractJSON(html, after: "ytInitialPlayerResponse = "),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else {
            PlaybackDiag.note("login-watch http=\((response as? HTTPURLResponse)?.statusCode ?? 0) no player json (\(data.count) bytes)")
            throw AppError.noPlayableStream
        }
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "-"
        let streaming = json["streamingData"] as? [String: Any]
        webSession.current = WebSessionStore.Value(
            datasync: firstMatch(html, #""DATASYNC_ID":"([^"|]*)"#).flatMap { $0.isEmpty ? nil : $0 },
            visitor: firstMatch(html, #""VISITOR_DATA":"([^"]+)""#),
            player: firstMatch(html, #""jsUrl":"([^"]+base\.js)""#))
        var hls = (streaming?["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        // 서명 없이 바로 쓸 수 있는 파일 주소 (있으면 예비로)
        var formats = ((streaming?["formats"] as? [[String: Any]]) ?? []).compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        // 주소 속 암호값 n을 YouTube 재생기 스크립트로 풀어 바꾼다 (안 바꾸면 영상 조각이 403으로 거절됨)
        var nState = "none"
        if let playerPath = firstMatch(html, #""jsUrl":"([^"]+base\.js)""#) {
            var inputs: [String] = []
            if let hls, let n = pathValue(hls, "n") { inputs.append(n) }
            for f in formats { if let n = URLComponents(url: f, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value { inputs.append(n) } }
            if !inputs.isEmpty {
                let t1 = Date()
                let map = await NSigSolver.shared.solveN(inputs, playerPath: playerPath)
                let solverErr = await NSigSolver.shared.lastError ?? "-"
                nState = map.isEmpty ? "fail: " + solverErr : String(format: "ok %.2fs", Date().timeIntervalSince(t1))
                if map.isEmpty { PlaybackDiag.note("login-n \(id) " + nState) }
                if let h = hls, let n = pathValue(h, "n"), let solved = map[n] {
                    hls = URL(string: h.absoluteString.replacingOccurrences(of: "/n/\(n)/", with: "/n/\(solved)/"))
                }
                formats = formats.map { f in
                    guard var c = URLComponents(url: f, resolvingAgainstBaseURL: false),
                          let n = c.queryItems?.first(where: { $0.name == "n" })?.value, let solved = map[n] else { return f }
                    c.queryItems = c.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: solved) : $0 }
                    return c.url ?? f
                }
            }
        } else {
            nState = "no jsUrl"
        }
        PlaybackDiag.note(String(format: "login-watch %@ status=%@ hls=%@ files=%d t=%.2f", id, status,
                                 hls == nil ? "N" : "Y", formats.count, Date().timeIntervalSince(t0)))
        if hls == nil, let streaming {
            let af = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
            let keyList: String = streaming.keys.sorted().joined(separator: ",")
            let withURL: Int = af.filter { $0["url"] != nil }.count
            let withCipher: Int = af.filter { $0["signatureCipher"] != nil }.count
            let line: String = "login-watch keys=\(keyList) adaptive=\(af.count) url=\(withURL) cipher=\(withCipher)"
            PlaybackDiag.note(line)
        }
        guard status == "OK", hls != nil || !formats.isEmpty else { throw AppError.noPlayableStream }
        // 영상 서버가 요구하는 보안 토큰(PO 토큰): 로그인 세션 ID에 묶어 만든다 (없으면 방문자 ID)
        let session = firstMatch(html, #""DATASYNC_ID":"([^"|]*)"#).flatMap { $0.isEmpty ? nil : $0 }
        let binding = session ?? firstMatch(html, #""VISITOR_DATA":"([^"]+)""#) ?? ""
        let pot = binding.isEmpty ? nil : await PoTokenProvider.shared.token(binding: binding)
        // 로그인 재생이 실제로 되는지 확인용 (앱 실행마다 처음 한 번만 기록)
        if loginReported.once() {
            let err = await PoTokenProvider.shared.lastError ?? "-"
            PlaybackDiag.report("login-play", id: id, details: ["hls=\(hls != nil)", "files=\(formats.count)",
                                                              "binding=\(session != nil ? "session" : binding.isEmpty ? "none" : "visitor")",
                                                              "pot=\(pot.map { "len\($0.count)" } ?? "fail: \(err)")", "n=\(nState)"])
        }
        CaptionStore.shared.save(id, json["captions"])
        var video: [PlaybackSource] = []
        if let hls {
            if let pot, let withPot = URL(string: hls.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/pot/" + pot) {
                video.append(.single(withPot))
            } else {
                video.append(.single(hls))
            }
        }
        // 단일 파일(360p)은 웹 방식에서 늘 거절돼(-11828) 시간만 잡아먹으므로, HLS가 없을 때만 넣는다
        if video.isEmpty {
            video += formats.map { url in
                guard let pot, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .single(url) }
                c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "pot", value: pot)]
                return .single(c.url ?? url)
            }
        }
        // 진단: 앱 실행마다 한 번, 재생목록 → 조각 순서로 어디서 거절되는지 기록 (주소 자체는 보내지 않고 이름만)
        if let first = video.first, case .single(let url) = first, hlsProbed.once() {
            Task.detached { await probeHLS(url, id: id) }
        }
        let length = ((json["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String).flatMap(Double.init)
        return Entry(video: video, audio: [], date: Date(), length: length)
    }

    private static let hlsProbed = OnceFlag()
    private static let failProbed = OnceFlag()

    private static func probeHLS(_ master: URL, id: String) async {
        var out: [String] = []
        func get(_ url: URL, range: Bool = false) async -> (Int, String) {
            var r = URLRequest(url: url)
            r.timeoutInterval = 10
            r.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
            if range { r.setValue("bytes=0-2000", forHTTPHeaderField: "Range") }
            guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return (-1, "") }
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, range ? "" : String(decoding: d, as: UTF8.self))
        }
        func keys(_ url: URL) -> String {
            // /videoplayback/key/value/key/value... 의 key 이름과 쿼리 이름만
            let parts = url.path.split(separator: "/").map(String.init)
            var names: [String] = []
            if let i = parts.firstIndex(where: { $0.hasPrefix("videoplayback") || $0 == "hls_variant" || $0 == "hls_playlist" }) {
                var j = i + 1
                while j < parts.count { names.append(parts[j]); j += 2 }
            }
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
            return (names + q.map { "?" + $0 }).joined(separator: ",")
        }
        let (ms, mtext) = await get(master)
        out.append("masterStatus=\(ms)")
        // 화질(해상도)별로 첫 조각이 받아지는지: 어느 화질이 거절되는지 확인
        let lines = mtext.split(separator: "\n").map(String.init)
        var checked = 0
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && checked < 10 {
            guard i + 1 < lines.count, let variant = URL(string: lines[i + 1]) else { continue }
            checked += 1
            let res = line.range(of: #"RESOLUTION=(\d+x\d+)"#, options: .regularExpression).map { String(line[$0].dropFirst(11)) } ?? "audio"
            let (vs, vtext) = await get(variant)
            var segStatus = -2
            if let sLine = vtext.split(separator: "\n").first(where: { $0.hasPrefix("http") }), let seg = URL(string: String(sLine)) {
                segStatus = await get(seg, range: true).0
            }
            out.append("\(res) v\(vs) s\(segStatus)")
        }
        PlaybackDiag.report("hls-probe", id: id, details: out)
    }

    /// /key/value/ 형태 주소에서 값 꺼내기 (HLS 주소의 n 등)
    private static func pathValue(_ url: URL, _ key: String) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// HTML 안의 `name = {...};` 에서 JSON 객체 부분만 잘라낸다 (문자열 안의 괄호는 건너뜀)
    private static func extractJSON(_ html: String, after marker: String) -> String? {
        guard let r = html.range(of: marker) else { return nil }
        let chars = Array(html[r.upperBound...].utf8)
        guard chars.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if c == UInt8(ascii: "\"") { inString = true }
            else if c == UInt8(ascii: "{") { depth += 1 }
            else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(decoding: chars[0...i], as: UTF8.self) }
            }
        }
        return nil
    }

    // MARK: - InnerTube player (iOS 클라이언트)

    private static let webSession = WebSessionStore()
    static let mwebUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
    static let mwebClientVersion = "2.20250925.01.00"

    /// 로그인한 계정으로 모바일 웹(MWEB) 재생 정보 → 서명·n을 풀고 보안 토큰(pot)을 붙여 자체 HLS로 재생
    private static func fetchMWebLoggedIn(id: String) async throws -> Entry {
        guard let web = webSession.current else {
            PlaybackDiag.note("mweb no web session")
            throw AppError.noPlayableStream
        }
        let fallbackPlayer = await currentPlayerPath()
        guard let player = web.player ?? fallbackPlayer,
              let sts = await NSigSolver.shared.prepare(playerPath: player) else {
            PlaybackDiag.note("mweb no player/sts")
            throw AppError.noPlayableStream
        }
        let binding = web.datasync ?? web.visitor ?? ""
        let pot = binding.isEmpty ? nil : await PoTokenProvider.shared.token(binding: binding)
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(mwebUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(mwebClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        for (k, v) in AuthStore.shared.headers(origin: "https://www.youtube.com") { request.setValue(v, forHTTPHeaderField: k) }
        var client: [String: Any] = ["clientName": "MWEB", "clientVersion": mwebClientVersion, "userAgent": mwebUserAgent,
                                     "hl": "ko", "gl": "KR"]
        if let visitor = web.visitor {
            client["visitorData"] = visitor
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        var body: [String: Any] = [
            "context": ["client": client],
            "videoId": id,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": sts]],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        if let pot { body["serviceIntegrityDimensions"] = ["poToken": pot] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetchFromInnerTube(id: id, prepared: request, tvPlayer: player, label: "mweb", pot: pot)
    }

    static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
    static let tvClientVersion = "7.20250923.13.00"

    /// 로그인한 계정으로 TV 앱 방식 재생 정보 → 서명·n 암호를 풀어 일반(IOS)과 같은 방법으로 재생
    /// (보안 토큰이 필요 없고, 자체 HLS로 고화질·빠른 시작이 된다)
    private static let tvConfig = TVConfigStore()

    /// TV 앱 화면(youtube.com/tv)의 설정: 현재 TV 앱 버전 · 방문자 ID · TV용 재생기 스크립트
    /// (이 값들이 로그인 세션과 맞지 않으면 「페이지를 새로고침해야 합니다」로 거절된다)
    private static func loadTVConfig() async -> TVConfigStore.Config? {
        if let c = tvConfig.current { return c }
        var r = URLRequest(url: URL(string: "https://www.youtube.com/tv")!)
        r.timeoutInterval = 10
        r.httpShouldHandleCookies = false
        r.setValue(tvUserAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("ko-KR,ko;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let cookie = AuthStore.shared.headers(origin: "https://www.youtube.com")["Cookie"] {
            r.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        let html = String(decoding: d, as: UTF8.self)
        let version = firstMatch(html, #""INNERTUBE_CLIENT_VERSION":"([^"]+)""#)
        let visitor = firstMatch(html, #""VISITOR_DATA":"([^"]+)""#)
        let player = firstMatch(html, #""PLAYER_JS_URL":"([^"]+)""#)?.replacingOccurrences(of: "\\/", with: "/")
        PlaybackDiag.note("tv cfg ver=\(version ?? "-") visitor=\(visitor == nil ? "N" : "Y") player=\(player ?? "-") bytes=\(d.count)")
        guard version != nil || visitor != nil || player != nil else { return nil }
        let c = TVConfigStore.Config(version: version ?? tvClientVersion, visitor: visitor, player: player)
        tvConfig.current = c
        return c
    }

    private static func fetchTVLoggedIn(id: String) async throws -> Entry {
        let cfg = await loadTVConfig()
        let fallbackPlayer = await currentPlayerPath()
        guard let player = cfg?.player ?? fallbackPlayer,
              let sts = await NSigSolver.shared.prepare(playerPath: player) else {
            PlaybackDiag.note("tv no player/sts")
            throw AppError.noPlayableStream
        }
        let version = cfg?.version ?? tvClientVersion
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tvUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("7", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        for (k, v) in AuthStore.shared.headers(origin: "https://www.youtube.com") { request.setValue(v, forHTTPHeaderField: k) }
        var client: [String: Any] = ["clientName": "TVHTML5", "clientVersion": version, "userAgent": tvUserAgent,
                                     "hl": "ko", "gl": "KR"]
        if let visitor = cfg?.visitor {
            client["visitorData"] = visitor
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": id,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": sts]],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetchFromInnerTube(id: id, prepared: request, tvPlayer: player, label: "tv", pot: nil)
    }

    /// 재생기 스크립트 주소: 로그인 watch 페이지에서 본 것, 없으면 iframe_api에서 찾는다
    private static func currentPlayerPath() async -> String? {
        if let known = await NSigSolver.shared.knownPlayerPath { return known }
        var r = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!)
        r.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        guard let pid = firstMatch(text, #"player\\?/([0-9a-fA-F]{8})\\?/"#) else { return nil }
        return "/s/player/\(pid)/player_ias.vflset/en_US/base.js"
    }

    /// TV 응답의 영상 파일 주소: signatureCipher(s · sp · url)와 n을 풀어 바로 쓸 수 있는 url로 바꾼다
    private static func decipher(_ streaming: [String: Any], player: String, pot: String? = nil) async -> [String: Any] {
        var out = streaming
        var nIn: [String] = [], sIn: [String] = []
        func parts(_ f: [String: Any]) -> (url: URLComponents, s: String?, sp: String)? {
            if let u = f["url"] as? String, let c = URLComponents(string: u) { return (c, nil, "sig") }
            guard let cipher = f["signatureCipher"] as? String,
                  let q = URLComponents(string: "?" + cipher)?.queryItems,
                  let u = q.first(where: { $0.name == "url" })?.value, let c = URLComponents(string: u) else { return nil }
            return (c, q.first { $0.name == "s" }?.value, q.first { $0.name == "sp" }?.value ?? "signature")
        }
        for key in ["adaptiveFormats", "formats"] {
            for f in streaming[key] as? [[String: Any]] ?? [] {
                guard let p = parts(f) else { continue }
                if let s = p.s { sIn.append(s) }
                if let n = p.url.queryItems?.first(where: { $0.name == "n" })?.value { nIn.append(n) }
            }
        }
        let solved = await NSigSolver.shared.solve(n: nIn, sig: sIn, playerPath: player)
        for key in ["adaptiveFormats", "formats"] {
            out[key] = (streaming[key] as? [[String: Any]] ?? []).compactMap { f -> [String: Any]? in
                guard var p = parts(f) else { return nil }
                var items = p.url.queryItems ?? []
                if let n = items.first(where: { $0.name == "n" })?.value {
                    guard let v = solved.n[n] else { return nil }
                    items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: v) : $0 }
                }
                if let s = p.s {
                    guard let v = solved.sig[s] else { return nil }
                    items.append(URLQueryItem(name: p.sp, value: v))
                }
                if let pot { items.append(URLQueryItem(name: "pot", value: pot)) }
                p.url.queryItems = items
                guard let url = p.url.url?.absoluteString else { return nil }
                var g = f
                g["url"] = url
                g["signatureCipher"] = nil
                return g
            }
        }
        return out
    }

    private static func fetchFromInnerTube(id: String) async throws -> Entry {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("20.10.4", forHTTPHeaderField: "X-Youtube-Client-Version")
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": "20.10.4",
                    "deviceMake": "Apple",
                    "deviceModel": "iPhone16,2",
                    "osName": "iPhone",
                    "osVersion": "18.3.2.22D82",
                    "hl": "ko",
                    "gl": "KR",
                ],
            ],
            "videoId": id,
            // iOS 앱의 재생 파라미터. 이것이 없으면 일부 영상(음원사 뮤직비디오 등)의 고화질 파일이
            // 처음 약 1분까지만 허용된다. 넣으면 1080p/HLS가 끝까지 받아진다 (2026-11 확인).
            "params": "2AMB",
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetchFromInnerTube(id: id, prepared: request, tvPlayer: nil)
    }

    private static func fetchFromInnerTube(id: String, prepared request: URLRequest, tvPlayer: String?,
                                           label: String = "", pot: String? = nil) async throws -> Entry {
        let tv = tvPlayer != nil
        let tStart = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let playerTime = Date().timeIntervalSince(tStart)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let playability = json?["playabilityStatus"] as? [String: Any]
        guard let json, playability?["status"] as? String == "OK",
              let streamingData = json["streamingData"] as? [String: Any]
        else {
            let prefix: String = tv ? label + " " : ""
            let msg: String = "player http=\((response as? HTTPURLResponse)?.statusCode ?? 0) status=\(playability?["status"] as? String ?? "-") reason=\(playability?["reason"] as? String ?? "-")"
            PlaybackDiag.note(prefix + msg)
            if !tv, playability?["status"] as? String == "LOGIN_REQUIRED" { StreamResolver.blockedUntil.block(minutes: 2) }
            if label == "tv" { tvConfig.current = nil }
            throw AppError.noPlayableStream
        }

        if !tv { StreamResolver.blockedUntil.clear() }
        CaptionStore.shared.save(id, json["captions"])
        var streaming: [String: Any] = streamingData
        if let tvPlayer { streaming = await decipher(streaming, player: tvPlayer, pot: pot) }
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(DashFormat.init)
        if tv {
            let raw: Int = (streamingData["adaptiveFormats"] as? [[String: Any]])?.count ?? 0
            let keyList: String = streamingData.keys.sorted().joined(separator: ",")
            let potMark: String = pot == nil ? "N" : "Y"
            let line: String = label + " " + id + " raw=" + String(raw) + " formats=" + String(formats.count) + " pot=" + potMark + " keys=" + keyList
            PlaybackDiag.note(line)
        }
        if tv, formats.isEmpty { throw AppError.noPlayableStream }
        // 오디오: YouTube 자동 더빙(영어 등)은 빼고, 원본(기본) 트랙을 고른다
        let allAudio = formats.filter { $0.isAudio }
        let notDubbed = allAudio.filter { !$0.isAutoDubbed }
        let originals = notDubbed.filter { $0.isDefaultAudio }
        let pool0 = !originals.isEmpty ? originals : (!notDubbed.isEmpty ? notDubbed : allAudio)
        let pool = pool0.contains { !$0.isDrc } ? pool0.filter { !$0.isDrc } : pool0
        let audioFormat = pool.first { $0.itag == 140 } ?? pool.max { $0.bitrate < $1.bitrate }
        // 화질 후보: 720p 먼저(빠른 시작), 그다음 1080p / 480p 로 자동 전환
        // 쇼츠 같은 세로 영상은 720p가 720x1280이므로 "짧은 변" 기준으로 고른다
        let videoFormats: [DashFormat] = [720, 1080, 480, 360].compactMap { p in
            formats.first { $0.isVideo && $0.codecs.hasPrefix("avc1") && min($0.width, $0.height) == p }
        }
        let youtubeHLS = (streaming["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        let muxed = (streaming["formats"] as? [[String: Any]])?
            .first(where: { $0["url"] is String })
            .flatMap { ($0["url"] as? String).flatMap(URL.init(string:)) }

        // 오디오 후보: 자체 HLS 먼저 → m4a 파일 직접
        // (m4a를 직접 재생하면 아이폰이 길이를 실제의 2배로 계산하는 문제가 있어 뒤로 미룸)
        // m4a 직접 재생은 길이가 2배로 나오므로, 자체 HLS를 한 번 더 시도하고 YouTube HLS를 그다음에 둔다
        // 오디오 재생목록 · 영상 재생목록 · "앞부분만 허용" 검사를 동시에 진행 (차례로 하면 시작이 늦어진다)
        // 쇼츠처럼 짧은 영상(90초 이하)은 "앞부분만 허용" 검사가 필요 없다 (허용되는 앞부분이 1분 이상)
        let lengthSeconds = ((json["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String).flatMap(Double.init) ?? 0
        let needsGateCheck = !tv && lengthSeconds > 90
        let tPaths = Date()
        async let audioPathTask = Self.audioPath(id: id, audio: audioFormat)
        async let videoPathTask = Self.videoPath(id: id, videos: videoFormats, audio: audioFormat)
        async let gatedTask = needsGateCheck ? Self.probeGated(audioFormat ?? videoFormats.first) : false

        var audio: [PlaybackSource] = []
        if let audioFormat {
            if let path = await audioPathTask { audio.append(.local(path)) }
            if let youtubeHLS { audio.append(.single(youtubeHLS)) }
            audio.append(.single(audioFormat.url))
        }

        // 영상 후보: 자체 HLS(가장 빠름) → YouTube HLS → 분리 파일 합치기 → 360p 단일 파일
        var video: [PlaybackSource] = []
        if let path = await videoPathTask {
            video.append(.local(path))
        }
        if let youtubeHLS { video.append(.single(youtubeHLS)) }
        if let audioFormat, let first = videoFormats.first {
            video.append(.split(video: first.url, audio: audioFormat.url))
        }
        if let muxed { video.append(.single(muxed)) }

        // 안전장치: 그래도 고화질 파일이 앞부분만 허용되면(뒤쪽 1KB 요청이 403)
        // 끝까지 받아지는 Android 360p 합본 파일을 맨 앞에 둔다.
        let pathsTime = Date().timeIntervalSince(tPaths)
        var gatedMuxed: URL?
        if await gatedTask, let full = try? await fetchAndroidMuxed(id: id) {
            video.insert(.limited(full), at: 0)
            audio.insert(.limited(full), at: 0)
            gatedMuxed = full
        }

        guard !video.isEmpty || !audio.isEmpty else { throw AppError.noPlayableStream }
        PlaybackDiag.note(String(format: "resolve %@ player=%.2f paths=%.2f total=%.2f gate=%@", id, playerTime, pathsTime,
                                 Date().timeIntervalSince(tStart), needsGateCheck ? "Y" : "N"))
        let length = ((json["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String).flatMap(Double.init)
        return Entry(video: video, audio: audio, date: Date(), length: length,
                     downloadVideo: videoFormats.first, downloadAudio: audioFormat, downloadMuxed: gatedMuxed)
    }

    private static func audioPath(id: String, audio: DashFormat?) async -> String? {
        guard let audio else { return nil }
        if let p = try? await LocalHLS.shared.buildAudio(id: id, audio: audio) { return p }
        return try? await LocalHLS.shared.buildAudio(id: id, audio: audio)
    }

    private static func videoPath(id: String, videos: [DashFormat], audio: DashFormat?) async -> String? {
        guard let audio, !videos.isEmpty else { return nil }
        return try? await LocalHLS.shared.buildVideo(id: id, videos: videos, audio: audio)
    }

    private static func probeGated(_ format: DashFormat?) async -> Bool {
        guard let format else { return false }
        return await isGated(format)
    }

    /// 파일 뒤쪽(85%)을 1KB만 요청해서 403이면 "앞부분만 허용"된 영상
    private static func isGated(_ format: DashFormat) async -> Bool {
        let length = format.contentLength ?? 0
        guard length > 100_000 else { return false }
        let offset = Int(Double(length) * 0.85)
        var request = URLRequest(url: format.url)
        request.timeoutInterval = 0.8   // 늦으면 "제한 없음"으로 보고 바로 시작 (드문 제한 영상은 재생 중 감시가 처리)
        request.setValue("bytes=\(offset)-\(offset + 1023)", forHTTPHeaderField: "Range")
        request.setValue(iosUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 403
    }

    /// Android 앱 클라이언트의 itag 18 (360p 영상+소리 합본) — 끝까지 받아진다
    private static func fetchAndroidMuxed(id: String) async throws -> URL {
        let ua = "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("3", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("20.10.38", forHTTPHeaderField: "X-Youtube-Client-Version")
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38",
                    "androidSdkVersion": 30,
                    "osName": "Android",
                    "osVersion": "11",
                    "hl": "ko",
                    "gl": "KR",
                ],
            ],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formats = (json["streamingData"] as? [String: Any])?["formats"] as? [[String: Any]],
              let muxed = formats.first(where: { $0["itag"] as? Int == 18 && $0["url"] is String }),
              let url = (muxed["url"] as? String).flatMap(URL.init(string:))
        else { throw AppError.noPlayableStream }
        return url
    }

    // MARK: - YouTubeKit (느린 대체 경로)

    private static func fetchWithYouTubeKit(id: String) async throws -> Entry {
        #if canImport(YouTubeKit)
        let streams = try await YouTube(videoID: id, methods: [.local, .remote]).streams

        let audio = streams
            .filterAudioOnly()
            .filter { $0.fileExtension == .m4a }
            .highestAudioBitrateStream()

        let muxed = streams
            .filterVideoAndAudio()
            .filter { $0.isNativelyPlayable }
            .highestResolutionStream()

        guard muxed != nil || audio != nil else { throw AppError.noPlayableStream }
        return Entry(video: muxed.map { [.single($0.url)] } ?? [],
                     audio: audio.map { [.single($0.url)] } ?? [],
                     date: Date())
        #else
        throw AppError.noPlayableStream
        #endif
    }

    // MARK: - AVPlayerItem 만들기

    nonisolated static func makeItem(_ source: PlaybackSource) async throws -> AVPlayerItem {
        var options: [String: Any] = [AVURLAssetHTTPUserAgentKey: iosUserAgent]
        // 내 미디어(Jellyfin) 서버: 영상·조각 요청에도 로그인 헤더를 붙인다
        if case .single(let url) = source, let headers = externalHeaders?(url) {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        switch source {
        case .single(let url), .limited(let url):
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
            // 로그인 재생(웹 방식 HLS)은 720p 넘는 화질이 영상 서버에서 거절된다(403) → 720p까지만 고르게
            if url.path.contains("/pot/") {
                item.preferredMaximumResolution = CGSize(width: 1280, height: 1280)
            }
            return item

        case .local(let path):
            let base = try await LocalHLS.shared.baseURL()
            guard let url = URL(string: base + path) else { throw AppError.noPlayableStream }
            return AVPlayerItem(asset: AVURLAsset(url: url, options: options))

        case .split(let videoURL, let audioURL):
            let videoAsset = AVURLAsset(url: videoURL, options: options)
            let audioAsset = AVURLAsset(url: audioURL, options: options)
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            async let videoDuration = videoAsset.load(.duration)
            async let audioDuration = audioAsset.load(.duration)

            guard let videoTrack = (try await videoTracks).first,
                  let audioTrack = (try await audioTracks).first
            else { throw AppError.noPlayableStream }
            let duration = CMTimeMinimum(try await videoDuration, try await audioDuration)

            let composition = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: duration)
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: videoTrack, at: .zero)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: audioTrack, at: .zero)
            return AVPlayerItem(asset: composition)
        }
    }
}

// MARK: - DASH 포맷 정보

struct DashFormat: Sendable {
    let itag: Int
    let url: URL
    let mime: String
    let codecs: String
    let bitrate: Int
    let width: Int
    let height: Int
    let initRange: ClosedRange<Int>
    let indexRange: ClosedRange<Int>
    let contentLength: Int?
    /// 여러 언어 오디오가 있을 때: 원본(기본) 트랙인지 / YouTube 자동 더빙인지
    let isDefaultAudio: Bool
    let isAutoDubbed: Bool
    /// 음량 압축(DRC) 버전 — 같은 원본이 보통판과 DRC판 두 개로 올 때 보통판을 쓴다
    let isDrc: Bool

    var isAudio: Bool { mime.hasPrefix("audio/mp4") }
    var isVideo: Bool { mime.hasPrefix("video/mp4") }

    init?(_ d: [String: Any]) {
        guard let itag = d["itag"] as? Int,
              let urlString = d["url"] as? String, let url = URL(string: urlString),
              let mimeType = d["mimeType"] as? String,
              let initRange = Self.range(d["initRange"]),
              let indexRange = Self.range(d["indexRange"])
        else { return nil }
        self.itag = itag
        self.url = url
        self.mime = mimeType.components(separatedBy: ";").first ?? mimeType
        if let start = mimeType.range(of: "codecs=\"") {
            let rest = mimeType[start.upperBound...]
            self.codecs = String(rest.prefix { $0 != "\"" })
        } else {
            self.codecs = ""
        }
        self.bitrate = d["bitrate"] as? Int ?? 0
        self.width = d["width"] as? Int ?? 0
        self.height = d["height"] as? Int ?? 0
        self.initRange = initRange
        self.indexRange = indexRange
        self.contentLength = Int("\(d["contentLength"] ?? "")")
        let track = d["audioTrack"] as? [String: Any]
        self.isDefaultAudio = track == nil || (track?["audioIsDefault"] as? Bool ?? false)
        self.isAutoDubbed = track?["isAutoDubbed"] as? Bool ?? false
        self.isDrc = d["isDrc"] as? Bool ?? false
    }

    private static func range(_ any: Any?) -> ClosedRange<Int>? {
        guard let d = any as? [String: Any],
              let start = Int("\(d["start"] ?? "")"), let end = Int("\(d["end"] ?? "")"), end >= start
        else { return nil }
        return start...end
    }
}

// MARK: - 앱이 만든 HLS 재생목록 + 로컬 HTTP 서버 (127.0.0.1)

final class LocalHLS: @unchecked Sendable {
    static let shared = LocalHLS()

    private let lock = NSLock()
    private var files: [String: String] = [:]
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "ktube.localhls")

    private func store(_ path: String, _ text: String) {
        lock.lock(); files[path] = text; lock.unlock()
    }

    func lookup(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    /// "/<id>/s<itag>" → 실제 googlevideo 파일 주소 (구간은 앱이 대신 받아 넘긴다)
    private var upstream: [String: URL] = [:]

    private func storeUpstream(_ path: String, _ url: URL) {
        lock.lock(); upstream[path] = url; lock.unlock()
    }

    private func upstreamURL(_ path: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return upstream[path]
    }

    // MARK: 서버

    /// "http://127.0.0.1:<port>" — 서버가 꺼져 있으면 다시 켠다
    /// 앱이 백그라운드에서 멈춰 있던 동안 iOS가 중계 서버(127.0.0.1)를 끊는다 → 돌아오면 새로 켠다.
    /// 예전 주소로 준비된 재생 항목은 쓸 수 없으므로 알림을 보내 다시 준비하게 한다
    static let didRestart = Notification.Name("LocalHLS.didRestart")

    func restart() async {
        _ = try? await startServer()
        NotificationCenter.default.post(name: Self.didRestart, object: nil)
    }

    private var lastHeal = Date.distantPast
    /// 재생 항목이 127.0.0.1에 연결하지 못했다(-1004 등)면 중계 서버가 죽은 것 → 10초에 한 번까지 새로 켠다
    func healIfDead(_ item: AVPlayerItem?) {
        guard let error = item?.error as NSError?,
              error.domain == NSURLErrorDomain,
              [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(error.code)
        else { return }
        lock.lock()
        let due = Date().timeIntervalSince(lastHeal) > 10
        if due { lastHeal = Date() }
        lock.unlock()
        guard due else { return }
        PlaybackDiag.note("proxy dead (\(error.code)) → restart")
        Task { await restart() }
    }

    func baseURL() async throws -> String {
        if let port = currentPort() { return "http://127.0.0.1:\(port)" }
        let port = try await startServer()
        return "http://127.0.0.1:\(port)"
    }

    private func currentPort() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        guard let listener, listener.state == .ready, port != 0 else { return nil }
        return port
    }

    private func startServer() async throws -> UInt16 {
        lock.lock()
        listener?.cancel()
        listener = nil
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            newListener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: newListener.port?.rawValue ?? 0)
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }
        guard port != 0 else { throw AppError.noPlayableStream }

        lock.lock()
        listener = newListener
        self.port = port
        lock.unlock()
        return port
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            var path = ""
            var range: String?
            if let data, let request = String(data: data, encoding: .utf8) {
                let lines = request.components(separatedBy: "\r\n")
                let parts = (lines.first ?? "").split(separator: " ")
                if parts.count >= 2 { path = String(parts[1]).components(separatedBy: "?").first ?? "" }
                range = lines.first { $0.lowercased().hasPrefix("range:") }
                    .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            }
            // 영상 구간: 응답이 먼저 오는 서버(느리면 1.2초 뒤 보조 서버)에서 받는 대로 바로 넘긴다
            if self.lookup(path) == nil, let source = self.upstreamURL(path) {
                HedgedStream.start(source, range: range, to: connection)
                return
            }
            let response: Data
            if let body = self.lookup(path) {
                let bodyData = Data(body.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                response = Data(header.utf8) + bodyData
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: 느린 서버 우회 (YouTube 앱처럼 보조 서버로 동시 요청)
    //
    // YouTube가 정해 주는 근처 캐시 서버는 아직 캐시되지 않은 뒷부분 구간을 6~30초씩 늦게 주기도 한다
    // (영상 중간으로 넘기면 멈춘 것처럼 보임). 같은 주소의 mn/fvip 목록에 있는 보조 서버는 같은 구간을
    // 1초 안에 준다. 응답이 1.2초 안에 시작되지 않으면 보조 서버에도 요청하고, 먼저 응답한 쪽을 쓴다.

    /// 같은 파일을 주는 보조 서버 주소들 (rrN---sn-xxx.googlevideo.com 의 N·sn 을 바꿈)
    static func alternateHosts(_ url: URL) -> [URL] {
        guard let host = url.host, host.hasSuffix(".googlevideo.com"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dashes = host.range(of: "---") else { return [] }
        let number = String(host[..<dashes.lowerBound].drop { !$0.isNumber })   // "rr4" → "4"
        let current = String(host[dashes.upperBound...].prefix { $0 != "." })
        let query = components.queryItems ?? []
        let nodes = (query.first { $0.name == "mn" }?.value ?? "").split(separator: ",").map(String.init)
        let fvips = (query.first { $0.name == "fvip" }?.value ?? "").split(separator: ",").map(String.init)
        var hosts: [String] = []
        for node in [current] + nodes.filter({ $0 != current }) {
            for n in [number] + fvips where !n.isEmpty {
                let candidate = "rr\(n)---\(node).googlevideo.com"
                if candidate != host, !hosts.contains(candidate) { hosts.append(candidate) }
            }
        }
        // 다른 노드를 먼저 (같은 노드의 다른 번호보다 빠른 경우가 많았다)
        hosts.sort { !$0.contains(current) && $1.contains(current) }
        return hosts.prefix(3).compactMap { alt in
            var c = components
            c.host = alt
            return c.url
        }
    }

    private actor Claim {
        var taken = false
        func take() -> Bool {
            if taken { return false }
            taken = true
            return true
        }
    }

    /// 원래 서버 → (1.2초마다) 보조 서버 순으로 요청을 걸고, 응답이 먼저 시작된 쪽에서 받는다
    static func hedgedFetch(_ url: URL, range: String?) async -> (Data, HTTPURLResponse)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse)?, Never>) in
            let collector = HedgedStream.Collector { result in continuation.resume(returning: result) }
            HedgedStream.run(url, range: range, sink: collector)
            // 재생목록용 작은 요청이 오래 멈추면(33초까지 본 적 있음) 6초에서 포기 → 다른 재생 방식으로
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { collector.finish(ok: false) }
        }
    }

    // MARK: 재생목록 만들기 (마스터 안의 하위 목록은 상대 경로 → 포트가 바뀌어도 유효)

    /// 영상(여러 화질) + 오디오 그룹 마스터 재생목록. 반환값은 경로.
    func buildVideo(id: String, videos: [DashFormat], audio: DashFormat) async throws -> String {
        async let audioPlaylist = mediaPlaylist(audio, id: id)
        var variants: [(DashFormat, String)] = []
        try await withThrowingTaskGroup(of: (Int, String)?.self) { group in
            for (index, format) in videos.enumerated() {
                group.addTask { (try? await self.mediaPlaylist(format, id: id)).map { (index, $0) } }
            }
            var built: [(Int, String)] = []
            for try await result in group { if let result { built.append(result) } }
            variants = built.sorted { $0.0 < $1.0 }.map { (videos[$0.0], $0.1) }
        }
        guard !variants.isEmpty else { throw AppError.noPlayableStream }
        store("/\(id)/a.m3u8", try await audioPlaylist)

        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\"\n"
        for (format, playlist) in variants {
            store("/\(id)/v\(format.itag).m3u8", playlist)
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(format.bitrate + audio.bitrate),CODECS=\"\(format.codecs),\(audio.codecs)\",RESOLUTION=\(format.width)x\(format.height),AUDIO=\"aud\"\n"
            master += "v\(format.itag).m3u8\n"
        }
        store("/\(id)/master.m3u8", master)
        return "/\(id)/master.m3u8"
    }

    /// 오디오만 있는 재생목록
    func buildAudio(id: String, audio: DashFormat) async throws -> String {
        let playlist = try await mediaPlaylist(audio, id: id)
        store("/\(id)/a.m3u8", playlist)
        let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=\(max(audio.bitrate, 64000)),CODECS=\"\(audio.codecs)\"\n"
            + "a.m3u8\n"
        store("/\(id)/audio.m3u8", master)
        return "/\(id)/audio.m3u8"
    }

    /// sidx를 읽어서 바이트 범위 기반 fMP4 미디어 재생목록 생성
    /// 구간 주소는 로컬 서버 경로("s<itag>", 상대 경로)로 두고, 요청이 오면 앱이 대신 받아 넘긴다
    private func mediaPlaylist(_ format: DashFormat, id: String) async throws -> String {
        guard let (data, _) = await Self.hedgedFetch(
            format.url, range: "bytes=\(format.indexRange.lowerBound)-\(format.indexRange.upperBound)")
        else { throw AppError.noPlayableStream }
        let segments = try Self.parseSidx([UInt8](data), anchor: format.indexRange.upperBound + 1)
        guard !segments.isEmpty else { throw AppError.noPlayableStream }

        storeUpstream("/\(id)/s\(format.itag)", format.url)
        let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
        let url = "s\(format.itag)"
        let initLength = format.initRange.upperBound - format.initRange.lowerBound + 1
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(initLength)@\(format.initRange.lowerBound)\"",
        ]
        lines.reserveCapacity(segments.count * 3 + 10)
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Segment {
        let offset: Int
        let size: Int
        let duration: Double
    }

    private static func parseSidx(_ b: [UInt8], anchor: Int) throws -> [Segment] {
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }

        guard b.count >= 32, b[4] == 0x73, b[5] == 0x69, b[6] == 0x64, b[7] == 0x78 else {
            throw AppError.noPlayableStream // "sidx" 아님
        }
        let version = b[8]
        var p = 12 + 4 // reference_ID 건너뜀
        let timescale = u32(p); p += 4
        let firstOffset: Int
        if version == 0 {
            firstOffset = u32(p + 4); p += 8
        } else {
            firstOffset = u64(p + 8); p += 16
        }
        p += 2 // reserved
        let count = u16(p); p += 2
        guard timescale > 0, b.count >= p + count * 12 else { throw AppError.noPlayableStream }

        var segments: [Segment] = []
        var offset = anchor + firstOffset
        for _ in 0..<count {
            let size = u32(p) & 0x7fff_ffff
            let duration = Double(u32(p + 4)) / Double(timescale)
            segments.append(Segment(offset: offset, size: size, duration: duration))
            offset += size
            p += 12
        }
        return segments
    }
}


// MARK: - 보조 서버로 우회하며 받는 대로 흘려보내기
//
// 처음 서버가 1.2초 안에 응답(헤더)하지 않으면 보조 서버에도 요청한다. 헤더가 먼저 온 서버 하나로 정하고
// 나머지는 바로 취소 → 같은 구간을 여러 번 받지 않는다 (예전처럼 다 받을 때까지 기다렸다가 넘기지 않고,
// 받는 즉시 플레이어로 보내므로 쇼츠처럼 첫 구간이 1~3MB로 커도 바로 재생이 시작된다)

protocol HedgedSink: AnyObject {
    /// 이긴 응답의 헤더
    func begin(_ response: HTTPURLResponse)
    func receive(_ data: Data)
    /// ok=false: 모든 서버 실패 또는 도중 끊김
    func finish(ok: Bool)
}

final class HedgedStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let shared = HedgedStream()
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    private let lock = NSLock()
    /// 요청 하나 = 여러 서버 시도를 묶은 묶음
    private final class Race {
        let sink: HedgedSink
        var tasks: [URLSessionDataTask] = []
        var winner: Int?
        var failed = 0
        var total = 0
        var done = false
        init(sink: HedgedSink) { self.sink = sink }
    }
    private var races: [Int: Race] = [:]   // taskIdentifier → 묶음

    static func start(_ url: URL, range: String?, to connection: NWConnection) {
        run(url, range: range, sink: ConnectionSink(connection))
    }

    static func run(_ url: URL, range: String?, sink: HedgedSink) {
        shared.race(url, range: range, sink: sink)
    }

    private func race(_ url: URL, range: String?, sink: HedgedSink) {
        let urls = [url] + LocalHLS.alternateHosts(url)
        let race = Race(sink: sink)
        race.total = urls.count
        for (index, target) in urls.enumerated() {
            let launch = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if race.done || race.winner != nil { self.lock.unlock(); return }
                var request = URLRequest(url: target)
                request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
                if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                let task = self.session.dataTask(with: request)
                race.tasks.append(task)
                self.races[task.taskIdentifier] = race
                self.lock.unlock()
                task.resume()
            }
            if index == 0 {
                launch()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.2 * Double(index), execute: launch)
            }
        }
    }

    // 헤더 도착: 처음 온 정상 응답만 채택, 나머지는 취소
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let race = races[dataTask.taskIdentifier], !race.done else {
            lock.unlock(); completionHandler(.cancel); return
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            lock.unlock(); completionHandler(.cancel); return
        }
        if let winner = race.winner, winner != dataTask.taskIdentifier {
            lock.unlock(); completionHandler(.cancel); return
        }
        race.winner = dataTask.taskIdentifier
        let losers = race.tasks.filter { $0.taskIdentifier != dataTask.taskIdentifier }
        lock.unlock()
        losers.forEach { $0.cancel() }
        race.sink.begin(http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let race = races[dataTask.taskIdentifier]
        let isWinner = race?.winner == dataTask.taskIdentifier
        lock.unlock()
        if let race, isWinner { race.sink.receive(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let race = races.removeValue(forKey: task.taskIdentifier), !race.done else { lock.unlock(); return }
        if race.winner == task.taskIdentifier {
            race.done = true
            lock.unlock()
            race.sink.finish(ok: error == nil)
            return
        }
        if race.winner == nil {
            race.failed += 1
            // 모든 서버가 실패(아직 시작 안 한 보조 서버는 실패한 것으로 보고 곧바로 시작하지 않음)
            if race.failed >= race.total {
                race.done = true
                lock.unlock()
                race.sink.finish(ok: false)
                return
            }
        }
        lock.unlock()
    }

    // MARK: 받는 쪽

    /// 플레이어(127.0.0.1 연결)로 바로 흘려보냄
    final class ConnectionSink: HedgedSink {
        let connection: NWConnection
        private var started = false
        init(_ connection: NWConnection) { self.connection = connection }

        func begin(_ http: HTTPURLResponse) {
            started = true
            var header = http.statusCode == 206 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4")\r\n"
            if http.expectedContentLength > 0 { header += "Content-Length: \(http.expectedContentLength)\r\n" }
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                header += "Content-Range: \(contentRange)\r\n"
            }
            header += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        }

        func receive(_ data: Data) {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func finish(ok: Bool) {
            if !started {
                let bad = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: bad, completion: .contentProcessed { [connection] _ in connection.cancel() })
                return
            }
            let conn = connection
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// 다 모아서 한 번에 돌려줌 (재생목록용 작은 데이터)
    final class Collector: HedgedSink, @unchecked Sendable {
        private var response: HTTPURLResponse?
        private var body = Data()
        private let lock = NSLock()
        private var completion: (((Data, HTTPURLResponse)?) -> Void)?
        init(_ completion: @escaping ((Data, HTTPURLResponse)?) -> Void) { self.completion = completion }

        func begin(_ response: HTTPURLResponse) {
            lock.lock(); self.response = response
            if response.expectedContentLength > 0 { body.reserveCapacity(Int(response.expectedContentLength)) }
            lock.unlock()
        }
        func receive(_ data: Data) { lock.lock(); body.append(data); lock.unlock() }
        func finish(ok: Bool) {
            lock.lock()
            let done = completion
            completion = nil
            let result = ok ? response.map { (body, $0) } : nil
            lock.unlock()
            done?(result)
        }
    }
}


// MARK: - 재생 실패 진단 (실패했을 때만 집 NAS로 짧은 기록을 보낸다: 원인 파악용)

enum PlaybackDiag {
    nonisolated(unsafe) private static var notes: [String] = []
    private static let lock = NSLock()

    static func note(_ s: String) {
        lock.lock(); notes.append(s); if notes.count > 30 { notes.removeFirst(notes.count - 30) }; lock.unlock()
    }

    static func report(_ kind: String, id: String, details: [String]) {
        lock.lock(); let recent = notes; notes.removeAll(); lock.unlock()
        let body: [String: Any] = [
            "kind": kind, "id": id,
            "app": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                + "(" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")",
            "details": details, "notes": recent,
        ]
        guard let url = URL(string: "https://mistylake.synology.me/ktube/diag.php"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    /// AVPlayerItem 오류 요약 (HTTP 상태·주소의 서버 이름)
    static func describe(_ item: AVPlayerItem?) -> String {
        guard let item else { return "item=nil" }
        let err = item.error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + " " + $0.localizedDescription } ?? "-"
        let log = item.errorLog()?.events.suffix(3).map { "\($0.errorStatusCode) \($0.errorDomain) \(URL(string: $0.uri ?? "")?.host ?? "-") \($0.errorComment ?? "")" } ?? []
        return "status=\(item.status.rawValue) err=\(err) log=\(log)"
    }
}


/// 로그인 watch 페이지에서 본 세션 값 (모바일 웹 방식에 다시 쓴다, 1시간 기억)
final class WebSessionStore: @unchecked Sendable {
    struct Value: Sendable { let datasync: String?; let visitor: String?; let player: String? }
    private let lock = NSLock()
    private var value: (Value, Date)?
    var current: Value? {
        get { lock.lock(); defer { lock.unlock() }; guard let v = value, Date().timeIntervalSince(v.1) < 3600 else { return nil }; return v.0 }
        set { lock.lock(); value = newValue.map { ($0, Date()) }; lock.unlock() }
    }
}

/// TV 앱 설정 (1시간 기억)
final class TVConfigStore: @unchecked Sendable {
    struct Config: Sendable { let version: String; let visitor: String?; let player: String? }
    private let lock = NSLock()
    private var value: (Config, Date)?
    var current: Config? {
        get { lock.lock(); defer { lock.unlock() }; guard let v = value, Date().timeIntervalSince(v.1) < 3600 else { return nil }; return v.0 }
        set { lock.lock(); value = newValue.map { ($0, Date()) }; lock.unlock() }
    }
}

/// 연속 3번 실패하면 30분 동안 쉬기
final class FailCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = 0
    private var pausedUntil = Date.distantPast
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return Date() >= pausedUntil }
    func success() { lock.lock(); fails = 0; lock.unlock() }
    func failure() {
        lock.lock(); fails += 1
        if fails >= 3 { pausedUntil = Date().addingTimeInterval(1800); fails = 0 }
        lock.unlock()
    }
}

/// 한 번만 true
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func once() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// YouTube가 「봇이 아님을 확인하세요」로 막았을 때 잠시 미리 받기를 멈추기 위한 시계
final class BlockClock: @unchecked Sendable {
    private let lock = NSLock()
    private var until = Date.distantPast
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return Date() < until }
    func block(minutes: Double) { lock.lock(); until = Date().addingTimeInterval(minutes * 60); lock.unlock() }
    func clear() { lock.lock(); until = .distantPast; lock.unlock() }
}


/// YouTube 자막 목록 (player 응답의 captionTracks). 자막은 앱이 WebVTT로 받아 직접 그린다
final class CaptionStore: @unchecked Sendable {
    static let shared = CaptionStore()
    struct Track { let url: String; let language: String; let isAuto: Bool }
    private let lock = NSLock()
    private var map: [String: [Track]] = [:]

    func save(_ id: String, _ captions: Any?) {
        let renderer = (captions as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let list = (renderer?["captionTracks"] as? [[String: Any]] ?? []).compactMap { t -> Track? in
            guard let url = t["baseUrl"] as? String else { return nil }
            return Track(url: url, language: (t["languageCode"] as? String ?? "").lowercased(),
                         isAuto: (t["kind"] as? String) == "asr")
        }
        lock.lock(); map[id] = list; lock.unlock()
    }

    func tracks(_ id: String) -> [Track]? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }

    /// 한국어 자막 → 한국어 자동 자막 → 다른 언어 자막 → 아무거나
    func best(_ id: String) -> Track? {
        guard let list = tracks(id), !list.isEmpty else { return nil }
        return list.first { $0.language.hasPrefix("ko") && !$0.isAuto }
            ?? list.first { $0.language.hasPrefix("ko") }
            ?? list.first { !$0.isAuto }
            ?? list.first
    }
}
