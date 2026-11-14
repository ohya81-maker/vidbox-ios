import CryptoKit
import Foundation
import Security
import SwiftUI
import WebKit

// MARK: - 쿠키 보관 (Keychain) + 인증 헤더 생성. 어느 스레드에서나 사용 가능.

final class AuthStore: @unchecked Sendable {
    static let shared = AuthStore()

    private let lock = NSLock()
    private var cookies: [String: String] = [:]
    private let keychainKey = "youtube.cookies.v1"

    private init() {
        if let data = Keychain.read(keychainKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = saved
        }
    }

    var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookies["SAPISID"] != nil || cookies["__Secure-3PAPISID"] != nil
    }

    func save(_ newCookies: [String: String]) {
        lock.lock()
        cookies = newCookies
        lock.unlock()
        if let data = try? JSONEncoder().encode(newCookies) {
            Keychain.write(keychainKey, data)
        }
    }

    func clear() {
        lock.lock()
        cookies = [:]
        lock.unlock()
        Keychain.delete(keychainKey)
    }

    /// 로그인 상태일 때 InnerTube 요청에 붙일 헤더 (Cookie + SAPISIDHASH)
    func headers(origin: String) -> [String: String] {
        lock.lock()
        let jar = cookies
        lock.unlock()
        guard !jar.isEmpty else { return [:] }

        let timestamp = Int(Date().timeIntervalSince1970)
        func hash(_ sid: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sid) \(origin)".utf8))
            return "\(timestamp)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let sid = jar["SAPISID"] ?? jar["__Secure-3PAPISID"] { parts.append("SAPISIDHASH " + hash(sid)) }
        if let sid = jar["__Secure-1PAPISID"] { parts.append("SAPISID1PHASH " + hash(sid)) }
        if let sid = jar["__Secure-3PAPISID"] { parts.append("SAPISID3PHASH " + hash(sid)) }

        var headers = [
            "Cookie": jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
            "X-Origin": origin,
            "X-Goog-AuthUser": "0",
        ]
        if !parts.isEmpty { headers["Authorization"] = parts.joined(separator: " ") }
        return headers
    }
}

enum Keychain {
    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ key: String, _ data: Data) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 화면용 계정 상태

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var isLoggedIn = AuthStore.shared.isLoggedIn
    @Published private(set) var name: String?
    @Published private(set) var handle: String?
    @Published private(set) var avatar: URL?
    /// 로그인/로그아웃할 때마다 바뀌어서 홈 피드를 다시 불러오게 함
    @Published private(set) var revision = 0

    private init() {
        if isLoggedIn { Task { await refreshProfile() } }
    }

    func completeLogin(cookies: [String: String]) {
        AuthStore.shared.save(cookies)
        isLoggedIn = AuthStore.shared.isLoggedIn
        revision += 1
        Task { await refreshProfile() }
    }

    func logout() {
        AuthStore.shared.clear()
        isLoggedIn = false
        name = nil
        handle = nil
        avatar = nil
        revision += 1
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
    }

    func refreshProfile() async {
        guard let profile = await InnerTubeClient.shared.accountProfile() else { return }
        name = profile.name
        handle = profile.handle
        avatar = profile.avatar
    }

    /// YouTube 시청 기록에 남겨서 추천 알고리즘에 반영되게 함
    func markWatched(_ videoID: String) {
        guard isLoggedIn else { return }
        Task.detached { await InnerTubeClient.shared.markWatched(videoID: videoID) }
    }
}

// MARK: - Google 로그인 화면 (웹뷰)

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&hl=ko&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Dko%26next%3Dhttps%253A%252F%252Fwww.youtube.com%252F")!

    var body: some View {
        NavigationStack {
            LoginWebView(url: Self.loginURL, isLoading: $isLoading) { cookies in
                AccountStore.shared.completeLogin(cookies: cookies)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle("YouTube 로그인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onLogin: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        // Google은 앱 내장 웹뷰 로그인을 막는 경우가 있어 Safari로 표시
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        private var finished = false

        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            guard !finished, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] all in
                guard let self, !self.finished else { return }
                var jar: [String: String] = [:]
                for cookie in all where cookie.domain.hasSuffix("youtube.com") {
                    jar[cookie.name] = cookie.value
                }
                guard jar["SAPISID"] != nil || jar["__Secure-3PAPISID"] != nil else { return }
                self.finished = true
                DispatchQueue.main.async { self.parent.onLogin(jar) }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
