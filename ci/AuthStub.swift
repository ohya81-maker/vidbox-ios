// CI 재생 테스트(macOS)용: 앱의 로그인 저장소 대신 쓰는 빈 구현
final class AuthStore: @unchecked Sendable {
    static let shared = AuthStore()
    var isLoggedIn: Bool { false }
    func headers(origin: String) -> [String: String] { [:] }
}

@MainActor
final class PoTokenProvider {
    static let shared = PoTokenProvider()
    var lastError: String?
    func token(binding: String) async -> String? { nil }
}

actor NSigSolver {
    static let shared = NSigSolver()
    var lastError: String?
    func solveN(_ inputs: [String], playerPath: String) async -> [String: String] { [:] }
}
