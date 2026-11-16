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
    case home, shorts, music, kids, media, library, search
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var tab: AppTab = .home
    @ObservedObject private var search = SearchRouter.shared
    @State private var showDownloadsTest = false
    /// 실제 화면 폭 구분 (아이패드 = regular). 탭바만 아래에 두려고 TabView에는 compact를 주고, 화면 내용에는 이 값을 돌려준다
    @Environment(\.horizontalSizeClass) private var realSizeClass

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: AppTab.home) {
                HomeView().miniPlayerInset().environment(\.horizontalSizeClass, realSizeClass)
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("홈") } icon: { Image(uiImage: UIImage(systemName: tab == .home ? "house.fill" : "house")!) }
            }
            Tab(value: AppTab.shorts) {
                ShortsView(isActive: tab == .shorts).environment(\.horizontalSizeClass, realSizeClass)
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("Shorts") } icon: { Image(uiImage: UIImage(systemName: tab == .shorts ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle")!) }
            }
            Tab(value: AppTab.music) {
                MusicView().miniPlayerInset().environment(\.horizontalSizeClass, realSizeClass)
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("음악") } icon: { Image(uiImage: UIImage(systemName: tab == .music ? "headphones.circle.fill" : "headphones.circle")!) }
            }
            Tab(value: AppTab.kids) {
                KidsView().miniPlayerInset().environment(\.horizontalSizeClass, realSizeClass)
            } label: {
                // UIImage로 넘겨 탭바의 자동 채움(.fill)을 막는다: 선택 탭만 채운 아이콘
                Label { Text("KIDS") } icon: { Image(uiImage: UIImage(systemName: tab == .kids ? "face.smiling.inverse" : "face.smiling")!) }
            }
            Tab(value: AppTab.media) {
                MediaView().miniPlayerInset().environment(\.horizontalSizeClass, realSizeClass)
            } label: {
                Label { Text("미디어") } icon: { Image(uiImage: UIImage(systemName: tab == .media ? "play.tv.fill" : "play.tv")!) }
            }
        }
        // 아이패드에서도 YouTube처럼 탭바를 화면 아래에 (기본은 위쪽 떠 있는 탭바)
        .environment(\.horizontalSizeClass, .compact)
        // 검색은 하단 탭이 아니라 홈·쇼츠 위의 검색창에서 (하단에는 홈·쇼츠·음악·KIDS·미디어 다섯 개만).
        // 화면 전체를 덮는 겹침으로 띄운다 — 검색 결과에서 영상을 열면 재생 화면이 그 위에 정상으로 뜬다
        .overlay {
            if search.isPresented {
                SearchScreen()
                    .miniPlayerInset()
                    .background(Color(.systemBackground))
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: search.isPresented)
        .fullScreenCover(isPresented: $player.isExpanded) {
            PlayerView()
        }
        .sheet(isPresented: $showDownloadsTest) {
            NavigationStack { DownloadsView() }
        }
        .task { await runLaunchHooks() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            FullScreenLock.apply()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            FullScreenLock.apply()
        }
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            search.open(q)
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
        // 아이패드는 숨기지 않는다 (탭바를 숨겼다 보였다 하면 목록이 위아래로 흔들린다)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
        } else {
            phone(content)
        }
    }

    private func phone(_ content: Content) -> some View {
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


/// 아이패드(iPadOS 26 창 모드): 앱 창의 최소 크기를 화면 전체로 묶어 작은 창으로 줄일 수 없게 한다
@MainActor
enum FullScreenLock {
    static func apply() {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene, let r = ws.sizeRestrictions else { continue }
            let size = ws.screen.bounds.size
            r.minimumSize = size
            r.maximumSize = size
        }
    }
}
