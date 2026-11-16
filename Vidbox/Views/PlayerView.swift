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
                    portrait
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

    private var portrait: some View {
        VStack(spacing: 0) {
            PlayerStage(fullscreen: false)
                // 아래 목록과 높이를 반씩 나누지 않고, 영상 비율만큼의 높이를 먼저 차지한다
                .layoutPriority(1)
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
            Text(player.isQueueMode ? "재생목록" : "다음 동영상")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
            let list = player.isQueueMode ? player.queue : player.related
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
                            .onAppear { player.loadMoreRelatedIfNeeded(current: item) }
                    }
                }
            }
        }
    }
}

// MARK: - 영상 + 컨트롤 영역

struct PlayerStage: View {
    let fullscreen: Bool
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
        !fullscreen && !player.audioOnly && player.videoAspect < 0.9
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
        .stageFrame(fullscreen, aspect: stageAspect)
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
    func stageFrame(_ fullscreen: Bool, aspect: CGFloat) -> some View {
        if fullscreen {
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
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
