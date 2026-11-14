// CI 전용: macOS의 AVFoundation으로 재생 경로를 실제로 시험한다.
// swiftc ci/main.swift Vidbox/StreamResolver.swift Vidbox/Models.swift -o playtest
import AVFoundation
import Foundation

func describe(_ source: PlaybackSource) -> String {
    switch source {
    case .single(let url): return url.absoluteString.contains("m3u8") ? "youtube-hls" : "single-file"
    case .local(let url): return url.lastPathComponent == "yt.m3u8" ? "youtube-hls(720p-first)" : "local-hls(\(url.lastPathComponent))"
    case .split: return "split"
    }
}

let cases: [(String, Bool)] = [
    ("dQw4w9WgXcQ", false),
    ("dQw4w9WgXcQ", true),
    ("jNQXAC9IVRw", false),
    ("9bZkp7q19f0", false), // 뮤직비디오 — 데이터센터 IP에서는 봇 확인으로 막힐 수 있음
]

var failures = 0
for (id, audioOnly) in cases {
    let t0 = Date()
    do {
        let source = try await StreamResolver.shared.resolve(id: id, audioOnly: audioOnly)
        let t1 = Date()
        let item = try await StreamResolver.makeItem(source)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        player.play()

        var ready: Date?
        var buffered: Date?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if item.status == .failed { break }
            if ready == nil, item.status == .readyToPlay { ready = Date() }
            if buffered == nil, let r = item.loadedTimeRanges.first?.timeRangeValue, r.duration.seconds > 1 {
                buffered = Date()
            }
            if ready != nil, buffered != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let resolveTime = t1.timeIntervalSince(t0)
        let readyTime = ready.map { $0.timeIntervalSince(t0) }
        let bufferTime = buffered.map { $0.timeIntervalSince(t0) }
        let ok = ready != nil && buffered != nil
        if !ok { failures += 1 }
        print(String(format: "PLAYTEST %@ %@ audio=%@ source=%@ resolve=%.2fs ready=%@ buffered=%@ size=%@ err=%@",
                     ok ? "OK  " : "FAIL", id, audioOnly ? "Y" : "N", describe(source), resolveTime,
                     readyTime.map { String(format: "%.2fs", $0) } ?? "-",
                     bufferTime.map { String(format: "%.2fs", $0) } ?? "-",
                     "\(item.presentationSize)",
                     item.error.map { "\($0)" } ?? "none"))
        player.pause()
    } catch {
        failures += 1
        print("PLAYTEST FAIL \(id) audio=\(audioOnly) error=\(error)")
    }
}
print("PLAYTEST done failures=\(failures)")
