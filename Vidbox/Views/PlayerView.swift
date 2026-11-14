import SwiftUI

// MARK: - 전체 화면 플레이어

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var dragOffset: CGFloat = 0
    @State private var showDescription = false

    var body: some View {
        Group {
            if player.isFullscreen {
                PlayerStage(fullscreen: true)
                    .ignoresSafeArea()
                    .statusBarHidden()
                    .persistentSystemOverlays(.hidden)
            } else {
                portrait
            }
        }
        .background(player.isFullscreen ? Color.black : Color(.systemBackground))
    }

    private var portrait: some View {
        VStack(spacing: 0) {
            PlayerStage(fullscreen: false)
                .offset(y: dragOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
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

            if let item = player.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        info(item)
                        actions(item)
                        upNext
                    }
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
            }
        }
    }

    private func info(_ item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .lineLimit(showDescription ? nil : 2)
                .onTapGesture { showDescription.toggle() }
            Text([item.views, item.published].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                AvatarView(url: item.channelThumbnail, size: 34)
                Text(item.channel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
    }

    private func actions(_ item: VideoItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(library.isSaved(item) ? "저장됨" : "저장",
                     icon: library.isSaved(item) ? "bookmark.fill" : "bookmark") {
                    library.toggleSaved(item)
                }
                pill("오디오 전용", icon: player.audioOnly ? "headphones.circle.fill" : "headphones",
                     isOn: player.audioOnly) {
                    player.setAudioOnly(!player.audioOnly)
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
            Text(player.isQueueMode ? "재생목록" : "다음 동영상")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
            let list = player.isQueueMode ? player.queue : player.related
            if list.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            ForEach(list) { item in
                VideoRow(item: item, expand: true, queue: player.isQueueMode ? player.queue : nil)
                    .padding(.horizontal, 14)
            }
        }
    }
}

// MARK: - 영상 + 컨트롤 영역

struct PlayerStage: View {
    let fullscreen: Bool
    @EnvironmentObject private var player: PlayerManager
    @State private var showControls = true
    @State private var scrubTime: Double?
    @State private var hideTask: Task<Void, Never>?

    // 더블탭 탐색 피드백
    @State private var seekAmount = 0
    @State private var seekForward = true
    @State private var seekTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black

            if player.audioOnly, let item = player.current {
                audioArtwork(item)
            } else {
                VideoSurface(manager: player)
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
        .stageFrame(fullscreen)
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
    func stageFrame(_ fullscreen: Bool) -> some View {
        if fullscreen {
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            self.aspectRatio(16 / 9, contentMode: .fit)
        }
    }
}

// MARK: - 얇은 진행 막대 (드래그로 탐색)

struct Scrubber: View {
    let current: Double
    let duration: Double
    var onScrub: (Double?) -> Void
    var onCommit: (Double) -> Void
    @State private var dragTime: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = dragTime ?? current
            let progress = duration > 0 ? min(max(shown / duration, 0), 1) : 0
            let active = dragTime != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: active ? 6 : 3)
                Capsule().fill(.white)
                    .frame(width: width * progress, height: active ? 6 : 3)
                Circle().fill(.white)
                    .frame(width: active ? 18 : 12, height: active ? 18 : 12)
                    .offset(x: width * progress - (active ? 9 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let t = min(max(value.location.x / width, 0), 1) * duration
                        dragTime = t
                        onScrub(t)
                    }
                    .onEnded { _ in
                        if let t = dragTime { onCommit(t) }
                        dragTime = nil
                        onScrub(nil)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 26)
    }
}

// MARK: - 미니 플레이어 (탭바 위에 떠 있는 유리 캡슐)

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager

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
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(item.channel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                Button { withAnimation { player.stop() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 34, height: 38)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
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
            .contentShape(Capsule())
            .glass(Capsule(), interactive: true)
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
