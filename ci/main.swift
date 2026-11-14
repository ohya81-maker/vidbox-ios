// CI 전용: macOS의 AVFoundation으로 재생 경로를 실제로 시험한다.
// swiftc ci/main.swift Vidbox/StreamResolver.swift Vidbox/Models.swift -o playtest
import AVFoundation
import Foundation

func describe(_ source: PlaybackSource) -> String {
    switch source {
    case .single(let url): return url.absoluteString.contains("m3u8") ? "youtube-hls" : "single-file"
    case .local: return "local-hls"
    case .split: return "split"
    }
}

let cases: [(String, Bool)] = [
    ("9bZkp7q19f0", false), // 뮤직비디오 (HLS 없음 → local-hls 예상)
    ("9bZkp7q19f0", true),
    ("dQw4w9WgXcQ", false),
    ("kJQP7kiw5Fk", false),
]

// 진단: iOS 클라이언트 응답과 sidx 재생목록 생성 단계를 직접 확인
for id in ["9bZkp7q19f0", "kJQP7kiw5Fk"] {
    var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
    let body: [String: Any] = ["context": ["client": ["clientName": "IOS", "clientVersion": "20.10.4", "deviceMake": "Apple",
                                                        "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82",
                                                        "hl": "ko", "gl": "KR"]],
                               "videoId": id, "contentCheckOk": true, "racyCheckOk": true]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await URLSession.shared.data(for: request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let status = (json["playabilityStatus"] as? [String: Any]) ?? [:]
    let streaming = json["streamingData"] as? [String: Any] ?? [:]
    let raw = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
    let formats = raw.compactMap(DashFormat.init)
    print("DIAG \(id) status=\(status["status"] ?? "-") reason=\(status["reason"] ?? "-") hls=\(streaming["hlsManifestUrl"] != nil) adaptive=\(raw.count) withUrl=\(raw.filter { $0["url"] != nil }.count) parsed=\(formats.count)")
    if let first = raw.first { print("DIAG sample keys: \(first.keys.sorted())") }
    if let audio = formats.first(where: { $0.itag == 140 }) {
        do {
            let url = try await HLSPlaylistLoader.shared.buildAudio(id: id, audio: audio)
            print("DIAG audio playlist ok \(url)")
        } catch {
            print("DIAG audio playlist error \(error)")
        }
    }
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
