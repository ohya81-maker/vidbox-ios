// CI 전용: macOS의 AVFoundation으로 재생 경로를 실제로 시험한다.
// swiftc ci/main.swift Vidbox/StreamResolver.swift Vidbox/Models.swift -o playtest
import AVFoundation
import Foundation

let cases: [(String, Bool)] = [
    ("dQw4w9WgXcQ", false),
    ("dQw4w9WgXcQ", true),
    ("9bZkp7q19f0", false), // 앞부분만 허용되는 영상 → Android 360p가 맨 앞이어야 함 (CI IP에서는 봇 확인으로 막힐 수 있음)
]

/// 재생 시작 → 2초 진행 확인 → 중간(60초)으로 이동 → 다시 진행되는지 확인
func measure(_ label: String, _ item: AVPlayerItem) async throws {
    let t0 = Date()
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.play()

    func waitUntil(_ target: Double, timeout: Double) async throws -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let t = player.currentTime().seconds
            if t.isFinite, t > target { return Date().timeIntervalSince(start) }
            if item.status == .failed { return nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    let started = try await waitUntil(2, timeout: 20)
    var seekResult = "-"
    if started != nil {
        let seekStart = Date()
        let done: Bool = await withCheckedContinuation { c in
            player.seek(to: CMTime(seconds: 60, preferredTimescale: 600)) { c.resume(returning: $0) }
        }
        let resumed = try await waitUntil(62, timeout: 20)
        seekResult = resumed.map { _ in String(format: "OK %.2fs (seekDone=%@)", Date().timeIntervalSince(seekStart), done ? "Y" : "N") }
            ?? "FAIL t=\(String(format: "%.1f", player.currentTime().seconds)) tcs=\(player.timeControlStatus.rawValue) wait=\(player.reasonForWaitingToPlay?.rawValue ?? "-") log=\(item.errorLog()?.events.last.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "-")"
    }
    print("PLAYTEST \(started != nil ? "OK  " : "FAIL") \(label) start=\(started.map { _ in String(format: "%.2fs", Date().timeIntervalSince(t0) - 0) } ?? "-") seek60=\(seekResult) err=\(item.error.map { "\($0)" } ?? "none")")
    player.pause()
}

for (id, audioOnly) in cases {
    do {
        let list = try await StreamResolver.shared.candidates(id: id, audioOnly: audioOnly)
        print("PLAYTEST \(id) audio=\(audioOnly) candidates=\(list.map(\.kind))")
        for source in list.prefix(4) {
            do {
                try await measure("\(id) audio=\(audioOnly) \(source.kind)", try await StreamResolver.makeItem(source))
            } catch {
                print("PLAYTEST FAIL \(id) \(source.kind) makeItem error=\(error)")
            }
        }
    } catch {
        print("PLAYTEST FAIL \(id) audio=\(audioOnly) error=\(error)")
    }
}
print("PLAYTEST done")
