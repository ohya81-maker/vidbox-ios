import SwiftUI

@main
struct VidboxApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .tint(.red)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .miniPlayerInset()
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(0)
            SearchView()
                .miniPlayerInset()
                .tabItem { Label("검색", systemImage: "magnifyingglass") }
                .tag(1)
            LibraryView()
                .miniPlayerInset()
                .tabItem { Label("보관함", systemImage: "play.square.stack.fill") }
                .tag(2)
        }
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
                    .transition(.move(edge: .bottom))
            }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }
}
