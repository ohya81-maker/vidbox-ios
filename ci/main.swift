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

// 대조군: YouTube 원본 HLS / 단일 m4a 파일을 같은 조건으로 재생
func controlSources(_ id: String) async throws -> [(String, PlaybackSource)] {
    var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
    let body: [String: Any] = ["context": ["client": ["clientName": "IOS", "clientVersion": "20.10.4", "deviceMake": "Apple",
                                                        "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82",
                                                        "hl": "ko", "gl": "KR"]], "videoId": id]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let sd = json["streamingData"] as? [String: Any] ?? [:]
    var out: [(String, PlaybackSource)] = []
    if let hls = (sd["hlsManifestUrl"] as? String).flatMap(URL.init(string:)) { out.append(("control-youtube-hls", .single(hls))) }
    if let a = (sd["adaptiveFormats"] as? [[String: Any]] ?? []).first(where: { $0["itag"] as? Int == 140 }),
       let u = (a["url"] as? String).flatMap(URL.init(string:)) { out.append(("control-m4a-file", .single(u))) }
    return out
}

func measure(_ label: String, _ item: AVPlayerItem) async throws {
    let t0 = Date()
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.isMuted = true
    player.play()
    var maxTime = 0.0
    var playing: Date?
    while Date().timeIntervalSince(t0) < 20 {
        let t = player.currentTime().seconds
        if t.isFinite { maxTime = max(maxTime, t) }
        if maxTime > 2 { playing = Date(); break }
        if item.status == .failed { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    print("PLAYTEST \(playing != nil ? "OK  " : "FAIL") \(label) playing2s=\(playing.map { String(format: "%.2fs", $0.timeIntervalSince(t0)) } ?? "-") t=\(String(format: "%.1f", maxTime)) tcs=\(player.timeControlStatus.rawValue) buffered=\(item.loadedTimeRanges.first.map { String(format: "%.1f", $0.timeRangeValue.duration.seconds) } ?? "0") err=\(item.error.map { "\($0)" } ?? "none")")
    player.pause()
}

for (label, source) in (try? await controlSources("dQw4w9WgXcQ")) ?? [] {
    try await measure(label, try await StreamResolver.makeItem(source))
}

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
        var playing: Date?
        var maxTime = 0.0
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if item.status == .failed { break }
            if ready == nil, item.status == .readyToPlay { ready = Date() }
            let t = player.currentTime().seconds
            if t.isFinite { maxTime = max(maxTime, t) }
            if playing == nil, maxTime > 2 { playing = Date(); break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let resolveTime = t1.timeIntervalSince(t0)
        let ok = playing != nil
        if !ok { failures += 1 }
        let lastError = item.errorLog()?.events.last.map { "status=\($0.errorStatusCode) domain=\($0.errorDomain) comment=\($0.errorComment ?? "-") uri=\(($0.uri ?? "-").prefix(60))" } ?? "none"
        let buffered = item.loadedTimeRanges.first.map { String(format: "%.1fs", $0.timeRangeValue.duration.seconds) } ?? "0"
        print("PLAYTEST \(ok ? "OK  " : "FAIL") \(id) audio=\(audioOnly ? "Y" : "N") source=\(describe(source)) resolve=\(String(format: "%.2f", resolveTime))s ready=\(ready.map { String(format: "%.2fs", $0.timeIntervalSince(t0)) } ?? "-") playing2s=\(playing.map { String(format: "%.2fs", $0.timeIntervalSince(t0)) } ?? "-") t=\(String(format: "%.1f", maxTime)) tcs=\(player.timeControlStatus.rawValue) wait=\(player.reasonForWaitingToPlay?.rawValue ?? "-") buffered=\(buffered) size=\(item.presentationSize) itemErr=\(item.error.map { "\($0)" } ?? "none") log=\(lastError)")
        player.pause()
    } catch {
        failures += 1
        print("PLAYTEST FAIL \(id) audio=\(audioOnly) error=\(error)")
    }
}
print("PLAYTEST done failures=\(failures)")
