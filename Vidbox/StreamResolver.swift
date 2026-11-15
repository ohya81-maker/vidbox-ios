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

    func candidates(id: String, audioOnly: Bool) async throws -> [PlaybackSource] {
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
    func prefetch(_ ids: [String]) {
        for id in ids {
            if let cached = cache[id], Date().timeIntervalSince(cached.date) < ttl { continue }
            guard inflight[id] == nil, prefetching < 4 else { continue }
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

    /// 마지막 수단: YouTubeKit (느림)
    func slowCandidates(id: String, audioOnly: Bool) async throws -> [PlaybackSource] {
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
            if let fast = try? await Self.fetchFromInnerTube(id: id) { return fast }
            return try await Self.fetchWithYouTubeKit(id: id)
        }
        inflight[id] = task
        defer { inflight[id] = nil }
        let entry = try await task.value
        cache[id] = entry
        return entry
    }

    // MARK: - InnerTube player (iOS 클라이언트)

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

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK",
              let streaming = json["streamingData"] as? [String: Any]
        else { throw AppError.noPlayableStream }

        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(DashFormat.init)
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
        async let audioPathTask = Self.audioPath(id: id, audio: audioFormat)
        async let videoPathTask = Self.videoPath(id: id, videos: videoFormats, audio: audioFormat)
        async let gatedTask = Self.probeGated(audioFormat ?? videoFormats.first)

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
        var gatedMuxed: URL?
        if await gatedTask, let full = try? await fetchAndroidMuxed(id: id) {
            video.insert(.limited(full), at: 0)
            audio.insert(.limited(full), at: 0)
            gatedMuxed = full
        }

        guard !video.isEmpty || !audio.isEmpty else { throw AppError.noPlayableStream }
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
        request.timeoutInterval = 5
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
        let options: [String: Any] = [AVURLAssetHTTPUserAgentKey: iosUserAgent]
        switch source {
        case .single(let url), .limited(let url):
            return AVPlayerItem(asset: AVURLAsset(url: url, options: options))

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
            // 영상 구간: 느린 서버면 보조 서버로 우회해서 받아 넘긴다
            if self.lookup(path) == nil, let source = self.upstreamURL(path) {
                Task {
                    let response: Data
                    if let (body, http) = await Self.hedgedFetch(source, range: range) {
                        var header = http.statusCode == 206 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
                        header += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4")\r\n"
                        header += "Content-Length: \(body.count)\r\n"
                        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                            header += "Content-Range: \(contentRange)\r\n"
                        }
                        header += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                        response = Data(header.utf8) + body
                    } else {
                        response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    }
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
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
        let urls = [url] + alternateHosts(url)
        let claim = Claim()
        return await withTaskGroup(of: (Data, HTTPURLResponse)?.self) { group in
            for (index, target) in urls.enumerated() {
                group.addTask {
                    if index > 0 {
                        try? await Task.sleep(for: .milliseconds(1200 * index))
                        if Task.isCancelled { return nil }
                        if await claim.taken { return nil }
                    }
                    var request = URLRequest(url: target)
                    request.timeoutInterval = 12
                    request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
                    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
                    guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
                          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
                    else { return nil }
                    guard await claim.take() else { return nil }
                    var body = Data()
                    if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
                    do {
                        var buffer = [UInt8]()
                        buffer.reserveCapacity(64 * 1024)
                        for try await byte in bytes {
                            buffer.append(byte)
                            if buffer.count == 64 * 1024 {
                                body.append(contentsOf: buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        body.append(contentsOf: buffer)
                    } catch { return nil }
                    return (body, http)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
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
