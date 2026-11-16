import SwiftUI
import UIKit

// MARK: - 전체 화면 플레이어

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var dragOffset: CGFloat = 0
    @State private var showDescription = false
    @State private var showSave = false
    @State private var showDownload = false
    @State private var relatedFilter = 0
    @State private var showComments = false
    /// 댓글 창을 위로 쓸어 올려 화면 전체로 키운 상태
    @State private var commentsFull = false
    @State private var commentsDrag: CGFloat = 0
    /// 아래 목록을 위로 올린 만큼 (세로 영상은 이만큼 재생 화면이 줄어든다)
    @State private var scrollY: CGFloat = 0

    var body: some View {
        // 화면이 가로가 되면(폰을 돌리거나 전체화면 버튼) 영상만 꽉 차게
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if (player.isFullscreen || landscape) && !player.audioOnly {
                    PlayerStage(fullscreen: true)
                        .ignoresSafeArea()
                        .statusBarHidden()
                        .persistentSystemOverlays(.hidden)
                } else if player.isQueueMode && (player.audioOnly || player.musicVideoMode) {
                    MusicPlayerView()
                } else {
                    portrait(width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: landscape) { _, isLandscape in
                player.deviceRotated(landscape: isLandscape)
            }
        }
        .background(player.isFullscreen ? Color.black : Color(.systemBackground))
        // 아래로 끌면 영상만이 아니라 재생 화면 전체가 같이 내려간다 (YouTube처럼)
        .offset(y: dragOffset)
        .sheet(isPresented: $showSave) {
            if let item = player.current { SaveToFolderSheet(item: item) }
        }
    }

    /// 세로 영상(쇼츠형)은 처음엔 화면을 크게 채우고, 아래 목록을 위로 쓸어 올리면
    /// YouTube처럼 재생 화면이 16:9 크기까지 줄어들며 목록이 따라 올라온다.
    private func portrait(width: CGFloat) -> some View {
        let aspect = player.audioOnly ? 16 / 9 : min(16 / 9, max(player.videoAspect, 0.65))
        let tallHeight = width / aspect
        let compactHeight = min(tallHeight, width * 9 / 16)
        let stageHeight = showComments ? compactHeight : max(compactHeight, tallHeight - max(0, scrollY))
        return ZStack(alignment: .top) {
            if let item = player.current {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // 재생 화면(처음 크기)만큼 비워 두면, 목록 윗부분이 줄어드는 재생 화면 아래에 딱 붙어 따라 올라간다
                            Color.clear.frame(height: tallHeight - 4).id("top")
                            info(item)
                            commentsCard
                            upNext
                        }
                        .padding(.bottom, 12)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        geo.contentOffset.y + geo.contentInsets.top
                    } action: { _, y in
                        scrollY = y
                    }
                    .onChange(of: item.id) { _, _ in
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            } else {
                Spacer()
            }

            PlayerStage(fullscreen: false, height: stageHeight, expanded: stageHeight >= tallHeight - 1)
                .animation(.easeInOut(duration: 0.25), value: tallHeight)
                .zIndex(1)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .global)
                        .onChanged { value in
                            if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 120 { player.isExpanded = false }
                            withAnimation(.spring) { dragOffset = 0 }
                        }
                )

            // 댓글: YouTube처럼 영상은 위에서 계속 재생되고, 그 아래를 댓글 창이 채운다
            if showComments, let page = player.commentsPreview {
                VStack(spacing: 0) {
                    // 영상 자리는 비워 둔다 (터치는 그대로 영상으로). 위로 쓸어 올리면 0까지 줄어 화면 전체가 댓글
                    Color.clear
                        .frame(height: min(compactHeight, max(0, (commentsFull ? 0 : compactHeight) + commentsDrag)))
                        .allowsHitTesting(false)
                    CommentsPanel(first: page, onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) { showComments = false; commentsFull = false }
                    }, onDrag: { dy in
                        commentsDrag = dy
                    }, onDragEnd: { dy in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            if dy < -60 {
                                commentsFull = true
                            } else if dy > 60 {
                                // 아래로 쓸어내리면 (화면 전체 상태였어도) 바로 닫는다
                                showComments = false
                                commentsFull = false
                            }
                            commentsDrag = 0
                        }
                    })
                    .id(player.current?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
                }
                .transition(.move(edge: .bottom))
                .zIndex(1.5)
            }

            // 위로 올린 목록이 상단 시계(상태 표시줄) 영역으로 비쳐 보이지 않게 덮는다
            Color.clear
                .frame(height: 0)
                .background(Color(.systemBackground), ignoresSafeAreaEdges: .top)
                .zIndex(2)
        }
    }

    private func info(_ item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .lineLimit(showDescription ? nil : 2)
                .onTapGesture { showDescription.toggle() }
            let channelName = player.watchInfo?.channelName.isEmpty == false ? player.watchInfo!.channelName : item.channel
            (Text(channelName).foregroundStyle(.primary).fontWeight(.semibold)
             + Text([player.watchInfo?.subscriberText, item.views, item.published]
                    .compactMap { $0 }.map { "  " + $0 }.joined()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // YouTube처럼 한 줄에: 채널 사진 · 구독 ……… 저장 · 다운로드 · 자동재생 · 공유 (아이콘만)
            HStack(spacing: 10) {
                AvatarView(url: player.watchInfo?.channelAvatar ?? item.channelThumbnail, size: 36)
                if player.watchInfo != nil {
                    let on = player.isSubscribedToCurrent
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { player.toggleSubscribe() }
                    } label: {
                        Label(on ? "구독중" : "구독", systemImage: on ? "bell" : "")
                            .labelStyle(SubscribeLabelStyle(showIcon: on))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(on ? Color.primary : Color(.systemBackground))
                            .background(on ? Color(.tertiarySystemFill) : Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 16)
                iconActions(item)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
    }

    /// YouTube처럼 「댓글 1.2만」 + 첫 댓글 한 줄. 누르면 전체 댓글 창
    @ViewBuilder
    private var commentsCard: some View {
        if let page = player.commentsPreview, let first = page.comments.first {
            Button { withAnimation(.easeInOut(duration: 0.25)) { showComments = true } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("댓글").font(.subheadline.weight(.semibold))
                        if let count = page.countText?.replacingOccurrences(of: "댓글", with: "")
                            .replacingOccurrences(of: "개", with: "").trimmingCharacters(in: .whitespaces) {
                            Text(count).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        AvatarView(url: first.avatar, size: 24)
                        Text(first.text)
                            .font(.footnote)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
        }
    }

    private func actions(_ item: VideoItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(library.isInAnyFolder(item) ? "저장됨" : "저장",
                     icon: library.isInAnyFolder(item) ? "checkmark.circle.fill" : "plus.circle") {
                    showSave = true
                }
                // 다운로드: 영상(소리 포함) 또는 음원만
                Button { showDownload = true } label: {
                    DownloadPillLabel(id: item.id)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .confirmationDialog("다운로드", isPresented: $showDownload, titleVisibility: .visible) {
                    downloadButtons(item)
                } message: {
                    Text("받아 두면 인터넷 없이 재생할 수 있어요. 보관함 → 오프라인 저장에서 볼 수 있습니다.")
                }
                pill("자동재생", icon: "infinity", isOn: player.autoplay) {
                    player.autoplay.toggle()
                }
                ShareLink(item: item.shareURL) {
                    pillLabel("공유", icon: "square.and.arrow.up", isOn: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
        }
    }

    private func iconActions(_ item: VideoItem) -> some View {
        let saved = library.isInAnyFolder(item)
        return HStack(spacing: 2) {
            iconButton(saved ? "checkmark.circle.fill" : "plus.circle", label: "저장") { showSave = true }
            // 다운로드: 영상(소리 포함) 또는 음원만
            Button { showDownload = true } label: {
                DownloadIconLabel(id: item.id).frame(width: 38, height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("다운로드")
            .confirmationDialog("다운로드", isPresented: $showDownload, titleVisibility: .visible) {
                downloadButtons(item)
            } message: {
                Text("받아 두면 인터넷 없이 재생할 수 있어요. 보관함 → 오프라인 저장에서 볼 수 있습니다.")
            }
            iconButton("infinity", label: "자동재생", tint: player.autoplay ? .accentColor : nil) {
                player.autoplay.toggle()
            }
            ShareLink(item: item.shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("공유")
        }
    }

    private func iconButton(_ icon: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func downloadButtons(_ item: VideoItem) -> some View {
        let downloads = DownloadManager.shared
        ForEach([DownloadKind.video, .audio], id: \.self) { kind in
            let title = kind == .video ? "영상 (소리 포함, 720p)" : "음원만 (m4a)"
            if let file = downloads.file(item.id, kind) {
                Button("\(kind.label) 삭제", role: .destructive) { downloads.delete(file) }
            } else if downloads.isDownloading(item.id, kind) {
                Button("\(kind.label) 다운로드 취소", role: .destructive) { downloads.cancel(item.id, kind) }
            } else {
                Button(title) { downloads.start(item, kind: kind) }
            }
        }
    }

    private func pill(_ title: String, icon: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, icon: icon, isOn: isOn) }
            .buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, icon: String, isOn: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isOn ? Color(.systemBackground) : .primary)
            .background(isOn ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            if player.isQueueMode {
                Text("재생목록")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
            } else {
                relatedChips
            }
            let list = player.isQueueMode ? player.queue : filteredRelated
            if list.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            if player.isQueueMode {
                ForEach(list) { item in
                    VideoRow(item: item, expand: true, queue: player.queue)
                        .padding(.horizontal, 14)
                }
            } else {
                // YouTube처럼: 다음 영상은 홈 피드와 같은 큰 카드로, 내릴수록 끝없이
                LazyVStack(spacing: 18) {
                    ForEach(list) { item in
                        VideoCard(item: item)
                            .onAppear {
                                // 필터로 일부만 보일 때도 끝에 닿으면 전체 목록을 더 불러온다
                                let anchor = item.id == list.last?.id ? (player.related.last ?? item) : item
                                player.loadMoreRelatedIfNeeded(current: anchor)
                            }
                    }
                }
            }
        }
        .onChange(of: player.current?.id) { _, _ in
            relatedFilter = 0
            showComments = false
            commentsFull = false
        }
    }

    /// YouTube처럼 다음 영상 위의 필터: 모두 / 이 채널 / 관련 콘텐츠(다른 채널)
    private var filteredRelated: [VideoItem] {
        guard let channel = player.current?.channel, !channel.isEmpty else { return player.related }
        switch relatedFilter {
        case 1: return player.related.filter { $0.channel == channel }
        case 2: return player.related.filter { $0.channel != channel }
        default: return player.related
        }
    }

    private var relatedChips: some View {
        let channel = player.current?.channel ?? ""
        let titles = channel.isEmpty ? ["모두"] : ["모두", "\(channel) 제공", "관련 콘텐츠"]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { index in
                    ChipButton(title: titles[index], isOn: index == relatedFilter) {
                        relatedFilter = index
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - 영상 + 컨트롤 영역

struct PlayerStage: View {
    let fullscreen: Bool
    /// 세로 화면에서 정해 준 높이 (nil이면 영상 비율대로)
    var height: CGFloat? = nil
    /// 처음 크기(가장 큰 상태)인지 — 줄어드는 중에는 영상이 잘리지 않게 전부 보여 준다
    var expanded = true
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var clock = PlayerManager.shared.clock
    @State private var showControls = true
    @State private var scrubTime: Double?
    @State private var hideTask: Task<Void, Never>?

    // 더블탭 탐색 피드백
    @State private var seekAmount = 0
    @State private var seekForward = true
    @State private var seekTask: Task<Void, Never>?

    /// 재생 화면 비율: 가로 영상은 16:9, 세로 영상(직캠 등)은 YouTube처럼 더 길게 — 최대 2:3 (세로가 가로의 1.5배)
    private var stageAspect: CGFloat {
        if player.audioOnly { return 16 / 9 }
        return min(16 / 9, max(player.videoAspect, 0.65))
    }

    /// 세로 영상은 YouTube처럼 가로를 꽉 채우고 위아래를 살짝 잘라낸다 (전체화면에선 전부 보이게)
    private var fillsStage: Bool {
        !fullscreen && !player.audioOnly && player.videoAspect < 0.9 && expanded
    }

    var body: some View {
        ZStack {
            Color.black

            if player.audioOnly, let item = player.current {
                audioArtwork(item)
            } else {
                VideoSurface(manager: player, gravity: fillsStage ? .resizeAspectFill : .resizeAspect)
            }

            // 영상 로딩 중에는 썸네일을 먼저 보여줘서 체감 지연을 줄임
            if player.isLoading, !player.audioOnly, let item = player.current {
                AsyncImage(url: item.bestThumbnail) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Color.black }
                .overlay(Color.black.opacity(0.25))
                .allowsHitTesting(false)
            }

            tapZones

            if seekAmount > 0 { seekFeedback }

            if player.isLoading {
                ProgressView().tint(.white).controlSize(.large).allowsHitTesting(false)
            }

            if let message = player.errorMessage {
                errorView(message)
            } else if showControls {
                controls.transition(.opacity)
            }

        }
        .stageFrame(fullscreen, aspect: stageAspect, height: height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .onAppear { scheduleHide() }
    }

    // MARK: 좌/우 반쪽 터치 영역 — 한 번: 컨트롤 표시, 두 번: 10초 이동

    private var tapZones: some View {
        HStack(spacing: 0) {
            zone(forward: false)
            zone(forward: true)
        }
    }

    private func zone(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTap(forward: forward) }
            .onTapGesture {
                if seekAmount > 0 {
                    doubleTap(forward: forward) // 연속 탭은 계속 누적
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    scheduleHide()
                }
            }
    }

    private func doubleTap(forward: Bool) {
        if seekAmount > 0 && seekForward != forward { seekAmount = 0 }
        seekForward = forward
        withAnimation(.easeOut(duration: 0.15)) { seekAmount += 10 }
        withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        player.skip(by: forward ? 10 : -10)

        seekTask?.cancel()
        seekTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { seekAmount = 0 }
        }
    }

    private var seekFeedback: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if seekForward { Spacer(minLength: 0) }
                ZStack {
                    Ellipse()
                        .fill(.white.opacity(0.18))
                        .frame(width: geo.size.width * 0.9, height: geo.size.height * 1.6)
                        .offset(x: seekForward ? geo.size.width * 0.25 : -geo.size.width * 0.25)
                    VStack(spacing: 6) {
                        Image(systemName: seekForward ? "forward.fill" : "backward.fill")
                            .font(.title3)
                        Text("\(seekAmount)초")
                            .font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: geo.size.width / 2, height: geo.size.height)
                .clipped()
                if !seekForward { Spacer(minLength: 0) }
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: 컨트롤

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.4).allowsHitTesting(false)

            VStack {
                HStack {
                    Button {
                        if fullscreen { player.setFullscreen(false) } else { player.isExpanded = false }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .plainIcon(size: 38)
                    }
                    Spacer()
                    Button { player.setAudioOnly(!player.audioOnly) } label: {
                        Image(systemName: player.audioOnly ? "headphones.circle.fill" : "headphones")
                            .font(.system(size: 16, weight: .medium))
                            .plainIcon(size: 38)
                    }
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .plainIcon(size: 38)
                    }
                }
                .padding(.horizontal, fullscreen ? 28 : 10)
                .padding(.top, fullscreen ? 16 : 10)
                Spacer()
            }

            if !player.isLoading {
                HStack(spacing: fullscreen ? 64 : 40) {
                    Button { player.skip(by: -10); scheduleHide() } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 26, weight: .regular))
                            .plainIcon(size: 48)
                    }
                    Button { player.togglePlayPause(); scheduleHide() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 40, weight: .regular))
                            .contentTransition(.symbolEffect(.replace))
                            .plainIcon(size: 66)
                    }
                    Button { player.skip(by: 10); scheduleHide() } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 26, weight: .regular))
                            .plainIcon(size: 48)
                    }
                }
            }

            VStack(spacing: 2) {
                Spacer()
                HStack(alignment: .center) {
                    Text("\(formatTime(scrubTime ?? player.currentTime)) / \(formatTime(player.duration))")
                        .font(.caption.monospacedDigit().weight(.medium))
                    if player.sourceKind == "limited-360p" && !player.audioOnly {
                        // YouTube가 이 영상의 고화질을 앞부분만 허용 → 끝까지 재생되는 360p로 재생 중
                        Text("360p · YouTube 제한")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.2), in: Capsule())
                    }
                    Spacer()
                    Button { player.setFullscreen(!fullscreen) } label: {
                        Image(systemName: fullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 30)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, fullscreen ? 32 : 12)
                Scrubber(current: player.currentTime, duration: player.duration) { time in
                    scrubTime = time
                    if time == nil { scheduleHide() } else { hideTask?.cancel() }
                } onCommit: { time in
                    player.seek(to: time)
                }
                .padding(.horizontal, fullscreen ? 26 : 6)
                .padding(.bottom, fullscreen ? 14 : 0)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain) // iOS 26 기본 버튼 모양(원형 배경) 없이 아이콘만
    }

    private func audioArtwork(_ item: VideoItem) -> some View {
        ZStack {
            AsyncImage(url: item.bestThumbnail) { image in
                image.resizable().scaledToFill().blur(radius: 30).opacity(0.6)
            } placeholder: { Color.black }
            AsyncImage(url: item.bestThumbnail) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(radius: 12)
                    .padding(.vertical, 28)
            } placeholder: { Color.clear }
        }
        .clipped()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").font(.title2)
            Text(message).font(.caption).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("다시 시도") { player.retry() }
                    .buttonStyle(.bordered)
                Button("닫기") { player.stop() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, player.isPlaying, scrubTime == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }
}

private extension View {
    @ViewBuilder
    func stageFrame(_ fullscreen: Bool, aspect: CGFloat, height: CGFloat? = nil) -> some View {
        if fullscreen {
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let height {
            self.frame(maxWidth: .infinity).frame(height: height)
        } else {
            self.aspectRatio(aspect, contentMode: .fit)
                .animation(.easeInOut(duration: 0.25), value: aspect)
        }
    }
}

// MARK: - 얇은 진행 막대 (드래그로 탐색)
//
// SwiftUI DragGesture는 스크롤 뷰나 다른 제스처에 의해 취소되면 "손 뗌(onEnded)"이 오지 않아
// 이동 명령이 전달되지 않는다. iOS 기본 UISlider는 손을 떼거나 취소될 때 확실히 알려주므로 그것을 쓴다.

struct Scrubber: View {
    let current: Double
    let duration: Double
    var tint: Color = .white
    var onScrub: (Double?) -> Void
    var onCommit: (Double) -> Void

    var body: some View {
        ScrubberSlider(current: current, duration: duration, tint: UIColor(tint), onScrub: onScrub, onCommit: onCommit)
            .frame(height: 30)
    }
}

private final class ThinSlider: UISlider {
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let height: CGFloat = isTracking ? 6 : 3
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    // 막대 근처를 넓게 잡아도 반응하도록
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6, dy: -12).contains(point)
    }
}

private struct ScrubberSlider: UIViewRepresentable {
    let current: Double
    let duration: Double
    let tint: UIColor
    let onScrub: (Double?) -> Void
    let onCommit: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = ThinSlider()
        slider.minimumValue = 0
        slider.isContinuous = true
        slider.minimumTrackTintColor = tint
        slider.maximumTrackTintColor = tint.withAlphaComponent(0.3)
        slider.setThumbImage(Self.dot(12, tint), for: .normal)
        slider.setThumbImage(Self.dot(18, tint), for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)),
                         for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // 막대의 아무 곳이나 탭해도 그 위치로 이동
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        slider.addGestureRecognizer(tap)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.maximumValue = Float(max(duration, 1))
        if !context.coordinator.isTracking {
            slider.value = Float(min(max(current, 0), max(duration, 1)))
        }
    }

    private static func dot(_ size: CGFloat, _ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            color.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    final class Coordinator: NSObject {
        var parent: ScrubberSlider
        var isTracking = false

        init(_ parent: ScrubberSlider) { self.parent = parent }

        @objc func began(_ slider: UISlider) {
            isTracking = true
            slider.setNeedsLayout()
        }

        @objc func changed(_ slider: UISlider) {
            isTracking = true
            didDrag = true
            parent.onScrub(Double(slider.value))
        }

        private var didDrag = false

        @objc func ended(_ slider: UISlider) {
            guard isTracking else { return }
            isTracking = false
            slider.setNeedsLayout()
            // 드래그로 값이 바뀐 경우만 이동 (단순 탭은 tapped에서 처리)
            if didDrag { parent.onCommit(Double(slider.value)) }
            didDrag = false
            parent.onScrub(nil)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let slider = gesture.view as? UISlider, slider.bounds.width > 0 else { return }
            let x = gesture.location(in: slider).x
            let ratio = Float(min(max(x / slider.bounds.width, 0), 1))
            let value = slider.minimumValue + ratio * (slider.maximumValue - slider.minimumValue)
            slider.setValue(value, animated: true)
            isTracking = false
            didDrag = false
            parent.onCommit(Double(value))
            parent.onScrub(nil)
        }
    }
}

// MARK: - 미니 플레이어 (탭바 위에 떠 있는 유리 캡슐)

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var clock = PlayerManager.shared.clock

    var body: some View {
        if let item = player.current {
            HStack(spacing: 10) {
                Group {
                    if player.audioOnly || player.isExpanded {
                        AsyncImage(url: item.bestThumbnail) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.black }
                    } else {
                        VideoSurface(manager: player)
                    }
                }
                // 조금 더 두꺼운 막대: 영상이 잘 보이도록 크게
                .frame(width: 104, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(item.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 42, height: 44)
                        .contentShape(Rectangle())
                }
                Button { withAnimation { player.stop() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 38, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: player.duration > 0 ? geo.size.width * min(player.currentTime / player.duration, 1) : 0,
                               height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 22)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .onTapGesture { player.isExpanded = true }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

private extension View {
    /// 배경 없이 아이콘만 (밝은 영상 위에서도 보이도록 옅은 그림자)
    func plainIcon(size: CGFloat) -> some View {
        self.frame(width: size, height: size)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }
}

// MARK: - 구독 버튼 라벨 (구독중일 때만 종 아이콘)

struct SubscribeLabelStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showIcon { configuration.icon }
            configuration.title
        }
    }
}

// MARK: - 댓글 창 (영상 아래)

struct CommentsPanel: View {
    let first: CommentPage
    var onClose: () -> Void
    /// 상단바를 위/아래로 끄는 중 (위로 올리면 화면 전체, 내리면 원래 크기·닫기)
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: (CGFloat) -> Void = { _ in }
    @EnvironmentObject private var account: AccountStore
    @State private var comments: [Comment] = []
    @State private var next: String?
    @State private var loading = false
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var showLogin = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 36, height: 5).padding(.top, 6)
                HStack {
                    Text("댓글").font(.headline)
                    if let count = first.countText?.replacingOccurrences(of: "댓글", with: "")
                        .replacingOccurrences(of: "개", with: "").trimmingCharacters(in: .whitespaces) {
                        Text(count).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.height) }
                    .onEnded { v in
                        if v.translation.height > 60 { typing = false }
                        onDragEnd(v.translation.height)
                    }
            )
            Divider()

            List {
                ForEach(comments) { c in
                    CommentRow(comment: c)
                        .listRowSeparator(.hidden)
                        .onAppear { if c.id == comments.last?.id { Task { await loadMore() } } }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            // 목록 맨 위에서 아래로 더 당기면 닫는다
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top < -90
            } action: { _, pulled in
                if pulled { typing = false; onDragEnd(100) }
            }

            Divider()
            composer
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged { v in if v.translation.height > 0 { onDrag(v.translation.height) } }
                        .onEnded { v in
                            if v.translation.height > 60 { typing = false }
                            onDragEnd(v.translation.height > 0 ? v.translation.height : 0)
                        }
                )
        }
        .onAppear {
            if comments.isEmpty {
                comments = first.comments
                next = first.next
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
    }

    @ViewBuilder
    private var composer: some View {
        if account.isLoggedIn {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    AvatarView(url: account.avatar, size: 30)
                    TextField("댓글 추가...", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($typing)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { Task { await send() } } label: {
                            if sending { ProgressView() } else {
                                Image(systemName: "paperplane.fill").font(.system(size: 18))
                            }
                        }
                        .disabled(sending || first.createParams == nil)
                    }
                }
                if let sendError {
                    Text(sendError).font(.caption).foregroundStyle(.red)
                } else if first.createParams == nil {
                    Text("이 영상은 댓글을 쓸 수 없어요.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            Button { showLogin = true } label: {
                HStack {
                    Image(systemName: "person.crop.circle")
                    Text("댓글을 쓰려면 YouTube 계정으로 로그인하세요")
                    Spacer()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let params = first.createParams else { return }
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            try await InnerTubeClient.shared.postComment(text, params: params)
            comments.insert(Comment(id: UUID().uuidString, author: account.handle ?? account.name ?? "나",
                                    avatar: account.avatar, text: text, published: "방금 전"), at: 0)
            draft = ""
            typing = false
        } catch {
            sendError = "댓글을 올리지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }

    private func loadMore() async {
        guard !loading, let token = next else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await InnerTubeClient.shared.comments(token) else { return }
        let known = Set(comments.map(\.id))
        comments.append(contentsOf: page.comments.filter { !known.contains($0.id) })
        next = page.next
    }
}

struct CommentRow: View {
    let comment: Comment
    var isReply = false
    @State private var expanded = false
    @State private var showReplies = false
    @State private var replies: [Comment] = []
    @State private var repliesNext: String?
    @State private var loadingReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(url: comment.avatar, size: isReply ? 24 : 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text([comment.author, comment.published].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(comment.text)
                        .font(.subheadline)
                        .lineLimit(expanded ? nil : 5)
                        .onTapGesture { expanded.toggle() }
                    HStack(spacing: 16) {
                        Label(comment.likes ?? "", systemImage: "hand.thumbsup")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                    // 답글(대댓글): 누르면 바로 아래에 펼쳐진다
                    if let count = comment.replies, comment.repliesToken != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showReplies.toggle() }
                            if showReplies && replies.isEmpty { Task { await loadReplies(comment.repliesToken) } }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showReplies ? "chevron.up" : "chevron.down")
                                Text(showReplies ? "답글 숨기기" : "답글 \(count)개")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if showReplies {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(replies) { r in
                        CommentRow(comment: r, isReply: true)
                    }
                    if loadingReplies {
                        ProgressView().padding(.vertical, 4)
                    } else if let next = repliesNext {
                        Button { Task { await loadReplies(next) } } label: {
                            Label("답글 더보기", systemImage: "arrow.turn.down.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, isReply ? 0 : 4)
    }

    private func loadReplies(_ token: String?) async {
        guard let token, !loadingReplies else { return }
        loadingReplies = true
        defer { loadingReplies = false }
        guard let page = try? await InnerTubeClient.shared.comments(token) else { return }
        let known = Set(replies.map(\.id)).union([comment.id])
        replies.append(contentsOf: page.comments.filter { !known.contains($0.id) })
        repliesNext = page.next
    }
}

/// 다운로드 아이콘 (받는 중이면 진행 고리)
struct DownloadIconLabel: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let id: String

    var body: some View {
        if let p = downloads.anyProgress(id) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(p)).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
        } else {
            let done = downloads.file(id, .video) != nil || downloads.file(id, .audio) != nil
            Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 20, weight: .regular))
        }
    }
}
