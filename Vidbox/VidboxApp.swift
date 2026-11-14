import SwiftUI

@main
struct VidboxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerManager.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var account = AccountStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(account)
                .tint(.primary)
        }
    }
}

enum AppTab: String, Hashable {
    case home, shorts, music, kids, library, search
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("홈", systemImage: "house.fill", value: AppTab.home) {
                HomeView().miniPlayerInset()
            }
            Tab("Shorts", systemImage: "play.rectangle.on.rectangle.fill", value: AppTab.shorts) {
                ShortsView(isActive: tab == .shorts)
            }
            Tab("음악", systemImage: "music.note", value: AppTab.music) {
                MusicView().miniPlayerInset()
            }
            Tab("KIDS", systemImage: "face.smiling.inverse", value: AppTab.kids) {
                KidsView().miniPlayerInset()
            }
            Tab("보관함", systemImage: "person.crop.circle", value: AppTab.library) {
                LibraryView().miniPlayerInset()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView().miniPlayerInset()
            }
        }
        .fullScreenCover(isPresented: $player.isExpanded) {
            PlayerView()
        }
        .task { await runLaunchHooks() }
    }

    /// 자동 화면 점검용 실행 인자 (CI 시뮬레이터 스크린샷): -ktubeTab music / -ktubePlay <id> / -ktubeSeek 100
    private func runLaunchHooks() async {
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "ktubeTab"), let target = AppTab(rawValue: name) {
            tab = target
        }
        if let id = defaults.string(forKey: "ktubePlay") {
            let audio = defaults.bool(forKey: "ktubeAudio")
            let item = VideoItem(id: id, title: "테스트 재생", channel: "KTUBE", channelThumbnail: nil, thumbnail: nil,
                                 duration: nil, views: nil, published: nil, isLive: false)
            player.play(item, queue: audio ? [item] : nil, audio: audio)
            let seek = defaults.double(forKey: "ktubeSeek")
            if seek > 0 {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                player.seek(to: seek)
            }
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: PlayerManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// 아래로 스크롤하면 하단 탭바를 완전히 숨기고, 위로 스크롤하면 다시 보여준다 (YouTube 방식)
private struct HideTabBarOnScroll: ViewModifier {
    @State private var hidden = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { old, new in
                let delta = new - old
                if new < 40 {
                    if hidden { withAnimation(.easeInOut(duration: 0.25)) { hidden = false } }
                } else if delta > 6, !hidden {
                    withAnimation(.easeInOut(duration: 0.25)) { hidden = true }
                } else if delta < -6, hidden {
                    withAnimation(.easeInOut(duration: 0.25)) { hidden = false }
                }
            }
            .toolbar(hidden ? .hidden : .visible, for: .tabBar)
    }
}

extension View {
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }

    func hidesTabBarOnScroll() -> some View {
        modifier(HideTabBarOnScroll())
    }
}
