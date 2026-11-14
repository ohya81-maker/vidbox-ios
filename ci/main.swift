// CI 전용: macOS의 AVFoundation으로 재생 경로를 실제로 시험한다.
// swiftc ci/main.swift Vidbox/StreamResolver.swift Vidbox/Models.swift -o playtest
import AVFoundation
import Foundation


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

func measure(_ label: String, _ item: AVPlayerItem, waits: Bool = false) async throws {
    let t0 = Date()
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = waits
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
    print("PLAYTEST \(playing != nil ? "OK  " : "FAIL") \(label) waits=\(waits) ready=\(item.status == .readyToPlay) playing2s=\(playing.map { String(format: "%.2fs", $0.timeIntervalSince(t0)) } ?? "-") t=\(String(format: "%.1f", maxTime)) tcs=\(player.timeControlStatus.rawValue) buffered=\(item.loadedTimeRanges.first.map { String(format: "%.1f", $0.timeRangeValue.duration.seconds) } ?? "0") err=\(item.error.map { "\($0)" } ?? "none")")
    player.pause()
}

for (label, source) in (try? await controlSources("dQw4w9WgXcQ")) ?? [] {
    try await measure(label, try await StreamResolver.makeItem(source), waits: false)
    try await measure(label, try await StreamResolver.makeItem(source), waits: true)
}

var failures = 0
for (id, audioOnly) in cases {
    do {
        let list = try await StreamResolver.shared.candidates(id: id, audioOnly: audioOnly)
        print("PLAYTEST \(id) audio=\(audioOnly) candidates=\(list.map(\.kind))")
        for source in list {
            do {
                try await measure("\(id) audio=\(audioOnly) \(source.kind)", try await StreamResolver.makeItem(source), waits: true)
            } catch {
                print("PLAYTEST FAIL \(id) \(source.kind) makeItem error=\(error)")
            }
        }
    } catch {
        failures += 1
        print("PLAYTEST FAIL \(id) audio=\(audioOnly) error=\(error)")
    }
}
print("PLAYTEST done")
