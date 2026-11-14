import AVFoundation
import Foundation
import YouTubeKit

/// 재생할 소스
enum PlaybackSource: Sendable {
    /// HLS(.m3u8) 또는 영상+소리가 합쳐진 단일 파일
    case single(URL)
    /// 영상 트랙과 오디오 트랙이 분리된 경우 (AVMutableComposition으로 합쳐서 재생)
    case split(video: URL, audio: URL)
}

/// 영상 ID → 재생 소스 변환기.
///
/// 빠른 경로: InnerTube `player` API를 iOS 앱 클라이언트로 한 번 호출 (≈0.3~0.5초)
///   1) hlsManifestUrl 이 있으면 HLS (화질 자동 조절, 최대 1080p+)
///   2) 없으면 H.264 mp4 영상(≤1080p) + m4a 오디오를 합쳐서 재생
/// 느린 경로(대체): YouTubeKit 로컬 추출
///
/// 결과는 3시간 캐시, 같은 영상 동시 요청은 한 번만 수행, 다음 곡 미리 추출.
actor StreamResolver {
    static let shared = StreamResolver()

    static let iosUserAgent = "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    private struct Entry: Sendable {
        let video: PlaybackSource?
        let audio: URL?
        let date: Date
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry, Error>] = [:]
    private let ttl: TimeInterval = 3 * 3600

    func resolve(id: String, audioOnly: Bool) async throws -> PlaybackSource {
        let entry = try await entry(for: id)
        if audioOnly, let audio = entry.audio { return .single(audio) }
        if let video = entry.video { return video }
        if let audio = entry.audio { return .single(audio) }
        throw AppError.noPlayableStream
    }

    func prefetch(_ ids: [String]) {
        for id in ids where cache[id] == nil && inflight[id] == nil {
            Task { _ = try? await self.entry(for: id) }
        }
    }

    func invalidate(_ id: String) {
        cache[id] = nil
    }

    /// 빠른 경로의 소스가 재생되지 않을 때 YouTubeKit으로 다시 추출
    func resolveSlow(id: String, audioOnly: Bool) async throws -> PlaybackSource {
        let entry = try await Self.fetchWithYouTubeKit(id: id)
        cache[id] = entry
        if audioOnly, let audio = entry.audio { return .single(audio) }
        if let video = entry.video { return video }
        if let audio = entry.audio { return .single(audio) }
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

    // MARK: - 빠른 경로: InnerTube player (iOS 클라이언트)

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

        let adaptive = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []).filter { $0["url"] is String }
        func url(_ f: [String: Any]?) -> URL? { (f?["url"] as? String).flatMap(URL.init(string:)) }
        func mime(_ f: [String: Any]) -> String { f["mimeType"] as? String ?? "" }

        let audioFormat = adaptive.first { $0["itag"] as? Int == 140 }
            ?? adaptive.filter { mime($0).hasPrefix("audio/mp4") }
                .max { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }
        let audio = url(audioFormat)

        var video: PlaybackSource?
        if let hls = (streaming["hlsManifestUrl"] as? String).flatMap(URL.init(string:)) {
            video = .single(hls)
        } else if let audio,
                  let best = adaptive
                      .filter({ mime($0).hasPrefix("video/mp4") && mime($0).contains("avc1") && ($0["height"] as? Int ?? 0) <= 1080 })
                      .max(by: { ($0["height"] as? Int ?? 0) < ($1["height"] as? Int ?? 0) }),
                  let videoURL = url(best) {
            video = .split(video: videoURL, audio: audio)
        } else if let muxed = url((streaming["formats"] as? [[String: Any]])?.first(where: { $0["url"] is String })) {
            video = .single(muxed)
        }

        guard video != nil || audio != nil else { throw AppError.noPlayableStream }
        return Entry(video: video, audio: audio, date: Date())
    }

    // MARK: - 느린 경로: YouTubeKit

    private static func fetchWithYouTubeKit(id: String) async throws -> Entry {
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
        return Entry(video: muxed.map { .single($0.url) }, audio: audio?.url, date: Date())
    }

    // MARK: - AVPlayerItem 만들기

    nonisolated static func makeItem(_ source: PlaybackSource) async throws -> AVPlayerItem {
        let options: [String: Any] = [AVURLAssetHTTPUserAgentKey: iosUserAgent]
        switch source {
        case .single(let url):
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
