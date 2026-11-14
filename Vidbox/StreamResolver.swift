import AVFoundation
import Foundation
#if canImport(YouTubeKit)
import YouTubeKit
#endif

/// 재생할 소스
enum PlaybackSource: Sendable {
    /// YouTube가 준 HLS(.m3u8) 또는 단일 파일
    case single(URL)
    /// 앱이 직접 만든 HLS 재생목록 (ktube:// — HLSPlaylistLoader가 제공)
    case local(URL)
    /// 영상/오디오 분리 파일을 AVMutableComposition으로 합쳐 재생 (최후 수단)
    case split(video: URL, audio: URL)
}

/// 영상 ID → 재생 소스 변환기.
///
/// 1) InnerTube `player` API를 iOS 앱 클라이언트로 한 번 호출 (≈0.3~0.5초)
/// 2) hlsManifestUrl이 있으면 그대로 HLS 재생
/// 3) 없으면(뮤직비디오 등) DASH 영상/오디오의 sidx(조각 위치표, 수백 바이트)만 받아
///    HLS 재생목록을 앱에서 직접 만들어 재생 → 파일 전체를 훑지 않아 즉시 시작
/// 4) 모두 실패하면 YouTubeKit(느림)
///
/// 결과는 3시간 캐시하고, 화면에 보이는 영상/다음 곡은 미리 준비(prefetch)한다.
actor StreamResolver {
    static let shared = StreamResolver()

    static let iosUserAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    private struct Entry: Sendable {
        let video: PlaybackSource?
        let audio: PlaybackSource?
        let date: Date
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry, Error>] = [:]
    private var prefetching = 0
    private let ttl: TimeInterval = 3 * 3600

    func resolve(id: String, audioOnly: Bool) async throws -> PlaybackSource {
        let entry = try await entry(for: id)
        if audioOnly, let audio = entry.audio { return audio }
        if let video = entry.video { return video }
        if let audio = entry.audio { return audio }
        throw AppError.noPlayableStream
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

    func invalidate(_ id: String) {
        cache[id] = nil
    }

    func resolveSlow(id: String, audioOnly: Bool) async throws -> PlaybackSource {
        let entry = try await Self.fetchWithYouTubeKit(id: id)
        cache[id] = entry
        if audioOnly, let audio = entry.audio { return audio }
        if let video = entry.video { return video }
        if let audio = entry.audio { return audio }
        throw AppError.noPlayableStream
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
        let audioFormat = formats.first { $0.itag == 140 }
            ?? formats.filter { $0.isAudio }.max { $0.bitrate < $1.bitrate }

        // 화질 후보: 720p 먼저(빠른 시작), 그다음 1080p / 480p 로 자동 전환
        let videoFormats: [DashFormat] = [720, 1080, 480].compactMap { height in
            formats.first { $0.isVideo && $0.codecs.hasPrefix("avc1") && $0.height == height }
        }

        // 오디오: 자체 HLS(즉시 시작) → 실패 시 원본 파일
        var audio: PlaybackSource?
        if let audioFormat {
            if let local = try? await HLSPlaylistLoader.shared.buildAudio(id: id, audio: audioFormat) {
                audio = .local(local)
            } else {
                audio = .single(audioFormat.url)
            }
        }

        // 가장 빠른 순서: 앱이 만든 HLS(0.5초) → YouTube HLS(라이브 등, 720p부터) → 분리 파일 합치기
        var video: PlaybackSource?
        let youtubeHLS = (streaming["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        if let audioFormat, !videoFormats.isEmpty,
           let local = try? await HLSPlaylistLoader.shared.buildVideo(id: id, videos: videoFormats, audio: audioFormat) {
            video = .local(local)
        } else if let youtubeHLS {
            if let local = try? await HLSPlaylistLoader.shared.reorderYouTubeHLS(id: id, master: youtubeHLS) {
                video = .local(local)
            } else {
                video = .single(youtubeHLS)
            }
        } else if let audioFormat, let first = videoFormats.first {
            video = .split(video: first.url, audio: audioFormat.url)
        } else if let muxed = (streaming["formats"] as? [[String: Any]])?
                    .first(where: { $0["url"] is String })
                    .flatMap({ ($0["url"] as? String).flatMap(URL.init(string:)) }) {
            video = .single(muxed)
        }

        guard video != nil || audio != nil else { throw AppError.noPlayableStream }
        return Entry(video: video, audio: audio, date: Date())
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
        return Entry(video: muxed.map { .single($0.url) }, audio: audio.map { .single($0.url) }, date: Date())
        #else
        throw AppError.noPlayableStream
        #endif
    }

    // MARK: - AVPlayerItem 만들기

    nonisolated static func makeItem(_ source: PlaybackSource) async throws -> AVPlayerItem {
        let options: [String: Any] = [AVURLAssetHTTPUserAgentKey: iosUserAgent]
        switch source {
        case .single(let url):
            return AVPlayerItem(asset: AVURLAsset(url: url, options: options))

        case .local(let url):
            let asset = AVURLAsset(url: url, options: options)
            asset.resourceLoader.setDelegate(HLSPlaylistLoader.shared, queue: HLSPlaylistLoader.shared.queue)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0
            return item

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
    }

    private static func range(_ any: Any?) -> ClosedRange<Int>? {
        guard let d = any as? [String: Any],
              let start = Int("\(d["start"] ?? "")"), let end = Int("\(d["end"] ?? "")"), end >= start
        else { return nil }
        return start...end
    }
}

// MARK: - 앱이 만든 HLS 재생목록 제공 (AVAssetResourceLoader, ktube:// 스킴)

final class HLSPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = HLSPlaylistLoader()
    let queue = DispatchQueue(label: "ktube.hls.loader")

    private let lock = NSLock()
    private var files: [String: String] = [:]

    private func store(_ key: String, _ text: String) {
        lock.lock(); files[key] = text; lock.unlock()
    }

    private func lookup(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[key]
    }

    /// 영상(여러 화질) + 오디오 그룹으로 된 마스터 재생목록
    func buildVideo(id: String, videos: [DashFormat], audio: DashFormat) async throws -> URL {
        async let audioPlaylist = Self.mediaPlaylist(audio)
        var variants: [(DashFormat, String)] = []
        try await withThrowingTaskGroup(of: (Int, String)?.self) { group in
            for (index, format) in videos.enumerated() {
                group.addTask { (try? await Self.mediaPlaylist(format)).map { (index, $0) } }
            }
            var built: [(Int, String)] = []
            for try await result in group { if let result { built.append(result) } }
            variants = built.sorted { $0.0 < $1.0 }.map { (videos[$0.0], $0.1) }
        }
        guard !variants.isEmpty else { throw AppError.noPlayableStream }
        store("/\(id)/a.m3u8", try await audioPlaylist)

        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"ktube://p/\(id)/a.m3u8\"\n"
        for (format, playlist) in variants {
            store("/\(id)/v\(format.itag).m3u8", playlist)
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(format.bitrate + audio.bitrate),CODECS=\"\(format.codecs),\(audio.codecs)\",RESOLUTION=\(format.width)x\(format.height),AUDIO=\"aud\"\n"
            master += "ktube://p/\(id)/v\(format.itag).m3u8\n"
        }
        store("/\(id)/master.m3u8", master)
        return URL(string: "ktube://p/\(id)/master.m3u8")!
    }

    /// YouTube HLS 마스터 재생목록에서 720p(없으면 가장 가까운 화질) 변형을 맨 앞으로
    func reorderYouTubeHLS(id: String, master: URL) async throws -> URL {
        var request = URLRequest(url: master)
        request.timeoutInterval = 6
        request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw AppError.noPlayableStream
        }

        var header: [String] = []
        var variants: [(info: String, uri: String, height: Int)] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF"), i + 1 < lines.count {
                let uri = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let absolute = URL(string: uri, relativeTo: master)?.absoluteString ?? uri
                var height = 0
                if let r = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                    height = Int(line[r].split(separator: "x").last ?? "") ?? 0
                }
                variants.append((line, absolute, height))
                i += 2
                continue
            }
            if !line.isEmpty {
                // EXT-X-MEDIA 등의 상대 URI도 절대 주소로
                if line.hasPrefix("#EXT-X-MEDIA"), let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                    let raw = String(line[r].dropFirst(5).dropLast())
                    let absolute = URL(string: raw, relativeTo: master)?.absoluteString ?? raw
                    header.append(line.replacingCharacters(in: r, with: "URI=\"\(absolute)\""))
                } else {
                    header.append(line)
                }
            }
            i += 1
        }
        guard !variants.isEmpty else { throw AppError.noPlayableStream }

        let preferred = variants.min { abs($0.height - 720) < abs($1.height - 720) }!.height
        let ordered = variants.filter { $0.height == preferred } + variants.filter { $0.height != preferred }
        var out = header
        for v in ordered {
            out.append(v.info)
            out.append(v.uri)
        }
        store("/\(id)/yt.m3u8", out.joined(separator: "\n") + "\n")
        return URL(string: "ktube://p/\(id)/yt.m3u8")!
    }

    /// 오디오만 있는 재생목록 (음악 모드)
    func buildAudio(id: String, audio: DashFormat) async throws -> URL {
        let playlist = try await Self.mediaPlaylist(audio)
        store("/\(id)/a.m3u8", playlist)
        let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=\(max(audio.bitrate, 64000)),CODECS=\"\(audio.codecs)\"\n"
            + "ktube://p/\(id)/a.m3u8\n"
        store("/\(id)/audio.m3u8", master)
        return URL(string: "ktube://p/\(id)/audio.m3u8")!
    }

    /// sidx를 읽어서 바이트 범위 기반 fMP4 미디어 재생목록 생성
    private static func mediaPlaylist(_ format: DashFormat) async throws -> String {
        var request = URLRequest(url: format.url)
        request.timeoutInterval = 8
        request.setValue("bytes=\(format.indexRange.lowerBound)-\(format.indexRange.upperBound)", forHTTPHeaderField: "Range")
        request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let segments = try parseSidx([UInt8](data), anchor: format.indexRange.upperBound + 1)
        guard !segments.isEmpty else { throw AppError.noPlayableStream }

        let target = Int((segments.map(\.duration).max() ?? 10).rounded(.up))
        let url = format.url.absoluteString
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

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // 영상 ID는 대소문자를 구분하므로 호스트가 아닌 경로에 담는다: ktube://p/<id>/master.m3u8
        guard let url = loadingRequest.request.url, url.scheme == "ktube",
              let text = lookup(url.path)
        else { return false }
        let data = Data(text.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}
