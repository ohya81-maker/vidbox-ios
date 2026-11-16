import UIKit

/// 글을 쓰는 중(키보드가 떠 있을 때) 입력칸 밖을 누르면 키보드를 내린다 — 앱 전체 공통.
/// 누른 곳의 원래 동작(버튼, 영상 터치 등)은 그대로 실행된다.
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private weak var installedWindow: UIWindow?

    func install() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              window !== installedWindow
        else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        installedWindow = window
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        gesture.view?.endEditing(true)
    }

    // 입력칸 안을 누른 것은 무시 (커서 이동 등)
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UITextView || v is UITextField { return false }
            view = v.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
