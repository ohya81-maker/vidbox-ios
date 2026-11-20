import Foundation
import UIKit
import WebKit

/// YouTube 영상 서버(googlevideo)가 웹 방식 재생에 요구하는 보안 토큰(PO 토큰)을 만든다.
/// 화면에 보이지 않는 웹 화면(youtube.com 출처)에서 YouTube의 보안 스크립트(BotGuard)를 실행해 만든다.
/// 로그인한 경우 토큰은 계정 세션(DATASYNC_ID)에 묶이며 몇 시간 동안 여러 영상에 재사용할 수 있다.
@MainActor
final class PoTokenProvider: NSObject, WKNavigationDelegate {
    static let shared = PoTokenProvider()

    private var webView: WKWebView?
    private var ready = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var cached: [String: (token: String, expires: Date)] = [:]
    private var running: [String: Task<String?, Never>] = [:]
    private(set) var lastError: String?

    /// binding(계정 세션 ID 또는 방문자 ID)에 묶인 토큰. 실패하면 nil
    func token(binding: String) async -> String? {
        if let c = cached[binding], Date() < c.expires { return c.token }
        if let running = running[binding] { return await running.value }
        let task = Task<String?, Never> { await self.mint(binding: binding) }
        running[binding] = task
        let value = await task.value
        running[binding] = nil
        return value
    }

    /// 재생이 403으로 거절되면 토큰을 버리고 다음에 새로 만든다
    func invalidate() { cached.removeAll(); minterExpires = .distantPast }

    /// 페이지 안에 만들어 둔 토큰 생성기(BotGuard 결과)의 유효 시각 — 지나면 새로 만든다
    private var minterExpires = Date.distantPast

    private func mint(binding: String) async -> String? {
        let t0 = Date()
        await prepare()
        guard let webView else { lastError = "no webview"; return nil }
        do {
            let reuse = Date() < minterExpires
            let result = try await webView.callAsyncJavaScript(Self.script, arguments: ["binding": binding, "reuse": reuse],
                                                               in: nil, contentWorld: .page)
            guard let text = result as? String,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { lastError = "bad result"; return nil }
            if let err = json["error"] as? String {
                lastError = err
                PlaybackDiag.note("pot fail: \(err.prefix(160))")
                return nil
            }
            guard let token = json["token"] as? String, !token.isEmpty else { lastError = "empty"; return nil }
            // 서버가 알려준 유효 시간보다 넉넉히 짧게 (우선 최대 1시간 — 안정되면 늘린다)
            let ttl = min((json["ttl"] as? Double) ?? 3600, 3600) * 0.8
            if cached.count > 60 { cached = cached.filter { Date() < $0.value.expires } }
            cached[binding] = (token, Date().addingTimeInterval(ttl))
            if !reuse { minterExpires = Date().addingTimeInterval(ttl) }
            lastError = nil
            if !reuse {
                PlaybackDiag.note(String(format: "pot ok len=%d ttl=%.0f t=%.2f", token.count, ttl, Date().timeIntervalSince(t0)))
            }
            return token
        } catch {
            lastError = error.localizedDescription
            PlaybackDiag.note("pot fail: \(error.localizedDescription.prefix(160))")
            return nil
        }
    }

    /// youtube.com 출처의 빈 페이지를 띄워 둔다 (네트워크로 페이지를 받지 않음)
    private func prepare() async {
        if ready { return }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
            view.alpha = 0.01
            view.isUserInteractionEnabled = false
            view.navigationDelegate = self
            view.customUserAgent = StreamResolver.safariUserAgent
            // 창에 붙어 있어야 스크립트 타이머가 느려지지 않는다
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } ?? ($0 as? UIWindowScene)?.windows.first }
                .first
            window?.addSubview(view)
            webView = view
            view.loadHTMLString("<!doctype html><html><head></head><body></body></html>",
                                baseURL: URL(string: "https://www.youtube.com/"))
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if ready { c.resume() } else { loadWaiters.append(c) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad() }
    }

    private func finishLoad() {
        ready = true
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// BotGuard 실행 → 무결성 토큰 → binding에 묶인 PO 토큰 (BgUtils와 같은 순서)
    private static let script = """
    const KEY = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw', RK = 'O43z0dpjhgX20SCx4KAo';
    const H = {'content-type': 'application/json+protobuf', 'x-goog-api-key': KEY, 'x-user-agent': 'grpc-web-javascript/0.1'};
    const b64ToU8 = (s) => { s = s.replace(/-/g, '+').replace(/_/g, '/').replace(/\\./g, '='); const b = atob(s); return Uint8Array.from(b, c => c.charCodeAt(0)); };
    const u8ToB64 = (u) => { let s = ''; for (const x of u) s += String.fromCharCode(x); return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_'); };
    const timeout = (ms, what) => new Promise((_, rej) => setTimeout(() => rej(new Error('timeout ' + what)), ms));
    const run = async () => {
      if (reuse && globalThis.__ktMint) {
        const o = await globalThis.__ktMint(new TextEncoder().encode(binding));
        if (o instanceof Uint8Array) return JSON.stringify({token: u8ToB64(o), ttl: globalThis.__ktTTL || 3600});
      }
      let r = await fetch('https://www.youtube.com/api/jnn/v1/Create', {method: 'POST', headers: H, body: JSON.stringify([RK])});
      if (!r.ok) throw new Error('create http ' + r.status);
      const raw = await r.json();
      let data = [];
      if (raw.length > 1 && typeof raw[1] === 'string') {
        data = JSON.parse(new TextDecoder().decode(b64ToU8(raw[1]).map(b => b + 97)) || '[]');
      } else if (raw.length && typeof raw[0] === 'object') {
        data = raw[0];
      }
      const [, wrappedScript, wrappedUrl, , program, globalName] = data;
      let code = Array.isArray(wrappedScript) ? wrappedScript.find(v => v && typeof v === 'string') : null;
      if (!code) {
        const url = Array.isArray(wrappedUrl) ? wrappedUrl.find(v => v && typeof v === 'string') : null;
        if (!url) throw new Error('no interpreter');
        code = await (await fetch(url.startsWith('//') ? 'https:' + url : url)).text();
      }
      (0, eval)(code);
      const vm = globalThis[globalName];
      if (!vm || !vm.a) throw new Error('no vm ' + globalName);
      let snap = null;
      await vm.a(program, (a) => { snap = a; }, true, undefined, () => {}, [[], []])[0];
      for (let i = 0; i < 100 && !snap; i++) await new Promise(res => setTimeout(res, 50));
      if (!snap) throw new Error('no snapshot fn');
      const webPoSignalOutput = [];
      const bgResponse = await new Promise(res => snap(res, [undefined, undefined, webPoSignalOutput, undefined]));
      r = await fetch('https://www.youtube.com/api/jnn/v1/GenerateIT', {method: 'POST', headers: H, body: JSON.stringify([RK, bgResponse])});
      if (!r.ok) throw new Error('generateIT http ' + r.status);
      const it = await r.json();
      if (!it || !it[0]) throw new Error('no integrity token');
      const getMinter = webPoSignalOutput[0];
      if (typeof getMinter !== 'function') throw new Error('no minter');
      const mint = await getMinter(b64ToU8(it[0]));
      if (typeof mint !== 'function') throw new Error('minter not fn');
      globalThis.__ktMint = mint; globalThis.__ktTTL = it[1] || 3600;
      const out = await mint(new TextEncoder().encode(binding));
      if (!(out instanceof Uint8Array)) throw new Error('mint result');
      return JSON.stringify({token: u8ToB64(out), ttl: it[1] || 3600});
    };
    try {
      return await Promise.race([run(), timeout(20000, 'pot')]);
    } catch (e) {
      return JSON.stringify({error: String(e && e.message || e)});
    }
    """
}
