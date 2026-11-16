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
    @State private var searchText = ""
    @State private var searchQuery = ""
    @State private var showDownloadsTest = false

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: AppTab.home) {
                HomeView().miniPlayerInset()
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("홈") } icon: { Image(uiImage: UIImage(systemName: tab == .home ? "house.fill" : "house")!) }
            }
            Tab(value: AppTab.shorts) {
                ShortsView(isActive: tab == .shorts)
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("Shorts") } icon: { Image(uiImage: UIImage(systemName: tab == .shorts ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle")!) }
            }
            Tab(value: AppTab.music) {
                MusicView().miniPlayerInset()
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("음악") } icon: { Image(uiImage: UIImage(systemName: tab == .music ? "headphones.circle.fill" : "headphones.circle")!) }
            }
            Tab(value: AppTab.kids) {
                KidsView().miniPlayerInset()
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("KIDS") } icon: { Image(uiImage: UIImage(systemName: tab == .kids ? "face.smiling.inverse" : "face.smiling")!) }
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView(text: $searchText, query: $searchQuery).miniPlayerInset()
            }
        }
        // 선택 탭은 기본 유리 탭바 그대로(빨강 없이 .primary): 선택 표시는 유리 캡슐 + 채운 아이콘
        // iOS 26: 검색 탭을 누르면 하단 탭이 왼쪽으로 접히고 그 자리에 검색창이 나온다
        .searchable(text: $searchText, prompt: "동영상, 채널, 음악 검색")
        .onSubmit(of: .search) {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { searchQuery = q }
        }
        .fullScreenCover(isPresented: $player.isExpanded) {
            PlayerView()
        }
        .sheet(isPresented: $showDownloadsTest) {
            NavigationStack { DownloadsView() }
        }
        .task { await runLaunchHooks() }
    }

    /// 자동 화면 점검용 실행 인자 (CI 시뮬레이터 스크린샷): -ktubeTab music / -ktubePlay <id> / -ktubeSeek 100
    private func runLaunchHooks() async {
        // 입력칸 밖을 누르면 키보드(작성 화면) 닫기
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            KeyboardDismisser.shared.install()
        }
        let defaults = UserDefaults.standard
        // 음악 탭 목록을 미리 불러 둔다 (홈 로딩과 겹치지 않게 조금 뒤에)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MusicViewModel.shared.loadAll()
        }
        if let name = defaults.string(forKey: "ktubeTab"), let target = AppTab(rawValue: name) {
            tab = target
        }
        // 테스트: 영상·음원 다운로드 후 목록 화면 (-ktubeDownload <id>)
        if let id = defaults.string(forKey: "ktubeDownload") {
            let item = VideoItem(id: id, title: "다운로드 테스트", channel: "KTUBE", channelThumbnail: nil, thumbnail: nil,
                                 duration: nil, views: nil, published: nil, isLive: false)
            DownloadManager.shared.start(item, kind: .audio)
            DownloadManager.shared.start(item, kind: .video)
            showDownloadsTest = true
            return
        }
        if let q = defaults.string(forKey: "ktubeSearch") {
            tab = .search
            try? await Task.sleep(nanoseconds: 500_000_000)
            searchText = q
            searchQuery = q
        }
        if let id = defaults.string(forKey: "ktubePlay") {
            let audio = defaults.bool(forKey: "ktubeAudio")
            let item = VideoItem(id: id, title: "테스트 재생", channel: "KTUBE", channelThumbnail: nil, thumbnail: nil,
                                 duration: nil, views: nil, published: nil, isLive: false)
            player.play(item, queue: audio ? [item] : nil, audio: audio)
            // 테스트: 음악 플레이어에서 「동영상」 (-ktubeMusicVideo YES)
            if audio && defaults.bool(forKey: "ktubeMusicVideo") {
                player.musicVideoMode = true
                player.setAudioOnly(false)
            }
            let seek = defaults.double(forKey: "ktubeSeek")
            if seek > 0 {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                player.seek(to: seek)
            }
            if defaults.bool(forKey: "ktubeCollapse") {
                player.miniPlayerEnabled = true   // 테스트: 하단 재생 막대 화면 확인용
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                player.isExpanded = false
            }
            if defaults.bool(forKey: "ktubeFullscreen") {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                player.setFullscreen(true)
            }
        }
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: PlayerManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // 하단 재생 막대 (영상은 막대 안에서 계속 재생)
            if player.current != nil && player.miniPlayerEnabled {
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
