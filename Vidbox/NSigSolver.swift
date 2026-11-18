import Foundation
import JavaScriptCore

/// YouTube 영상 주소의 암호값(n · sig)을 YouTube 재생기 스크립트(base.js)로 푼다.
/// yt-dlp의 EJS 풀이기(meriyah + astring + yt_ejs_helper)를 JavaScriptCore에서 실행한다.
/// 방식은 YouTubeKit(MIT, Resources/ejs/YouTubeKit-LICENSE.txt)의 SignatureSolver를 따랐다.
actor NSigSolver {
    static let shared = NSigSolver()

    private var ctx: JSContext?
    private var playerURL: String?
    /// 한 번 분석한 재생기 스크립트 (다음부터는 다시 분석하지 않아 빠르다)
    private var preprocessed: String?
    private var memo: [String: String] = [:]
    private(set) var lastError: String?
    private var sts: Int?
    var knownPlayerPath: String? { playerURL }

    /// 재생기 스크립트를 준비하고 signatureTimestamp를 돌려준다 (TV 방식 요청에 필요)
    func prepare(playerPath: String) async -> Int? {
        do { try await load(playerPath) } catch { lastError = "\(error)"; return nil }
        return sts
    }

    /// n · 서명(sig) 함께 풀기
    func solve(n: [String], sig: [String], playerPath: String) async -> (n: [String: String], sig: [String: String]) {
        do {
            try await load(playerPath)
            let nTodo = n.filter { memo[$0] == nil }
            if !nTodo.isEmpty || !sig.isEmpty {
                let (nm, sm) = try run(n: Array(Set(nTodo)), sig: Array(Set(sig)))
                memo.merge(nm) { _, new in new }
                var nOut: [String: String] = [:]
                for i in n { if let v = memo[i] { nOut[i] = v } }
                return (nOut, sm)
            }
            var nOut: [String: String] = [:]
            for i in n { if let v = memo[i] { nOut[i] = v } }
            return (nOut, [:])
        } catch {
            lastError = "\(error)"
            PlaybackDiag.note("sig fail: " + String(String(describing: error).prefix(200)))
            return ([:], [:])
        }
    }

    /// n 값들을 푼다. 실패하면 빈 사전
    func solveN(_ inputs: [String], playerPath: String) async -> [String: String] {
        let todo = inputs.filter { memo[$0] == nil }
        if !todo.isEmpty {
            do {
                try await load(playerPath)
                let solved = try run(n: todo, sig: []).0
                memo.merge(solved) { _, new in new }
                if memo.count > 500 { memo.removeAll() }
            } catch {
                lastError = "\(error)"
                PlaybackDiag.note("nsig fail: \(String(describing: error).prefix(200))")
            }
        }
        var out: [String: String] = [:]
        for i in inputs { if let v = memo[i] { out[i] = v } }
        return out
    }

    private func load(_ path: String) async throws {
        if playerURL == path, ctx != nil { return }
        let url = URL(string: path.hasPrefix("http") ? path : "https://www.youtube.com" + path)!
        var request = URLRequest(url: url)
        request.setValue(StreamResolver.safariUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let js = String(decoding: data, as: UTF8.self)
        guard js.count > 10_000 else { throw SolveError.badPlayer }
        if let r = js.range(of: #"(?:signatureTimestamp|sts)\s*:\s*(\d{5})"#, options: .regularExpression) {
            sts = Int(js[r].filter(\.isNumber).suffix(5))
        }
        ctx = try makeContext()
        playerURL = path
        preprocessed = nil
        memo.removeAll()
        playerJS = js
    }

    private var playerJS = ""

    private func makeContext() throws -> JSContext {
        guard let c = JSContext() else { throw SolveError.context }
        c.exceptionHandler = { _, exc in
            PlaybackDiag.note("nsig js error: \(exc?.toString() ?? "-")")
        }
        c.evaluateScript(#"""
            globalThis.XMLHttpRequest = { prototype: {} };
            globalThis.URL = class URL {
                constructor(url) {
                    this.href = url;
                    const match = url.match(/^(https?:)\/\/([^/:]+)(:(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
                    this.protocol = match ? match[1] : '';
                    this.hostname = match ? match[2] : '';
                    this.port = match && match[4] ? match[4] : '';
                    this.pathname = match && match[5] ? match[5] : '/';
                    this.search = match && match[6] ? match[6] : '';
                    this.hash = match && match[7] ? match[7] : '';
                }
            };
            globalThis.navigator = { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36' };
            const window = Object.assign(Object.create(null), globalThis);
            window.location = new URL("https://www.youtube.com/watch?v=ktube");
            const document = {};
            let self = globalThis;
        """#)
        for name in ["meriyah.umd", "astring.umd", "yt_ejs_helper"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else { throw SolveError.resource(name) }
            c.evaluateScript(src)
        }
        return c
    }

    private func run(n: [String], sig: [String]) throws -> ([String: String], [String: String]) {
        guard let ctx else { throw SolveError.context }
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }
        if requests.isEmpty { return ([:], [:]) }
        var input: [String: Any] = [
            "requests": requests,
        ]
        if let preprocessed {
            input["type"] = "preprocessed_player"
            input["preprocessed_player"] = preprocessed
        } else {
            input["type"] = "player"
            input["player"] = playerJS
            input["output_preprocessed"] = true
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        ctx.setObject(json, forKeyedSubscript: "ktubeInput" as NSString)
        guard let text = ctx.evaluateScript("JSON.stringify(jsc(JSON.parse(ktubeInput)))")?.toString(),
              let out = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw SolveError.eval }
        if let pre = out["preprocessed_player"] as? String, !pre.isEmpty {
            preprocessed = pre
            playerJS = ""
        }
        guard let items = out["responses"] as? [[String: Any]], !items.isEmpty else {
            throw SolveError.message((out["error"] as? String) ?? "no responses")
        }
        var nMap: [String: String] = [:], sMap: [String: String] = [:]
        for (req, item) in zip(requests, items) {
            if let err = item["error"] as? String { throw SolveError.message(err) }
            let data = (item["data"] as? [String: String]) ?? [:]
            if req["type"] as? String == "n" { nMap = data } else { sMap = data }
        }
        return (nMap, sMap)
    }

    enum SolveError: Error, CustomStringConvertible {
        case badPlayer, context, eval
        case resource(String)
        case message(String)
        var description: String {
            switch self {
            case .badPlayer: return "player js too small"
            case .context: return "no JSContext"
            case .eval: return "eval failed"
            case .resource(let n): return "missing \(n).js"
            case .message(let m): return m
            }
        }
    }
}
