import SwiftUI

@main
struct VidboxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerManager.shared
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .tint(.primary)
        }
    }
}

enum AppTab: Hashable {
    case home, shorts, music, library, search
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
            Tab("보관함", systemImage: "person.crop.circle", value: AppTab.library) {
                LibraryView().miniPlayerInset()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView().miniPlayerInset()
            }
        }
        .minimizeTabBarOnScroll()
        .fullScreenCover(isPresented: $player.isExpanded) {
            PlayerView()
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

extension View {
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }

    @ViewBuilder
    func minimizeTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
