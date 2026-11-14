import SwiftUI
import UIKit

// MARK: - 왼쪽 가장자리에서 오른쪽으로 쓸면 뒤로 가기

/// 내비게이션 바를 숨긴 화면(홈·음악 등)에서는 iOS 기본 "가장자리 스와이프 뒤로 가기"가 꺼진다.
/// 모든 화면에서 다시 켠다 (밀어 넣은 화면이 있을 때만 동작).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// 화면 전환이 아니라 "상태"로 바뀌는 페이지(검색 결과, 선택한 태그 등)도
/// 왼쪽 가장자리에서 쓸면 이전 상태로 돌아가게 한다.
private struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if enabled {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                if value.translation.width > 60, abs(value.translation.height) < 90 {
                                    withAnimation(.easeInOut(duration: 0.25)) { action() }
                                }
                            }
                    )
            }
        }
    }
}

extension View {
    func edgeSwipeBack(_ enabled: Bool, perform action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, action: action))
    }
}
