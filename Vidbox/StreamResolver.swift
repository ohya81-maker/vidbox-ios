import Foundation
import YouTubeKit

/// 영상 ID → 실제 스트림 URL 변환기.
/// - 한 번 추출하면 영상/오디오 URL을 함께 3시간 캐시 (YouTube 스트림 URL은 약 6시간 유효)
/// - 같은 영상을 동시에 요청하면 추출을 한 번만 수행
/// - 다음 곡/다음 쇼츠를 미리 추출(prefetch)해서 재생 시작 지연을 줄임
actor StreamResolver {
    static let shared = StreamResolver()

    private struct Entry {
        let video: URL?
        let audio: URL?
        let date: Date
    }

    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<Entry, Error>] = [:]
    private let ttl: TimeInterval = 3 * 3600

    func resolve(id: String, audioOnly: Bool) async throws -> URL {
        let entry = try await entry(for: id)
        if audioOnly, let audio = entry.audio { return audio }
        if let video = entry.video { return video }
        if let audio = entry.audio { return audio }
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

    private func entry(for id: String) async throws -> Entry {
        if let cached = cache[id], Date().timeIntervalSince(cached.date) < ttl {
            return cached
        }
        if let running = inflight[id] {
            return try await running.value
        }
        let task = Task { try await Self.fetch(id: id) }
        inflight[id] = task
        defer { inflight[id] = nil }
        let entry = try await task.value
        cache[id] = entry
        return entry
    }

    private static func fetch(id: String) async throws -> Entry {
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
        return Entry(video: muxed?.url, audio: audio?.url, date: Date())
    }
}
