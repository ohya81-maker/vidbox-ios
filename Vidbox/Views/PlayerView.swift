import SwiftUI

// MARK: - 전체 화면 플레이어

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var dragOffset: CGFloat = 0
    @State private var showDescription = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerStage()
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in dragOffset = max(0, value.translation.height) }
                        .onEnded { value in
                            if value.translation.height > 120 { player.isExpanded = false }
                            withAnimation(.spring) { dragOffset = 0 }
                        }
                )

            if let item = player.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        info(item)
                        actions(item)
                        Divider()
                        upNext
                    }
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
            }
        }
        .background(Color(.systemBackground))
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
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
    }

    private func actions(_ item: VideoItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(library.isSaved(item) ? "저장됨" : "저장",
                     icon: library.isSaved(item) ? "bookmark.fill" : "bookmark") {
                    library.toggleSaved(item)
                }
                pill(player.audioOnly ? "오디오 전용 켜짐" : "오디오 전용",
                     icon: player.audioOnly ? "headphones.circle.fill" : "headphones") {
                    player.setAudioOnly(!player.audioOnly)
                }
                pill(player.autoplay ? "자동재생 켜짐" : "자동재생 꺼짐", icon: "infinity") {
                    player.autoplay.toggle()
                }
                ShareLink(item: item.shareURL) {
                    pillLabel("공유", icon: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
        }
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, icon: icon) }
            .buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("다음 동영상")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
            if player.related.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            ForEach(player.related) { item in
                VideoRow(item: item, expand: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

// MARK: - 영상 + 컨트롤 영역

struct PlayerStage: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var showControls = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            if player.audioOnly, let item = player.current {
                AsyncImage(url: item.bestThumbnail) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Color.black }
                .overlay(alignment: .topLeading) {
                    Label("오디오 전용", systemImage: "headphones")
                        .font(.caption2.weight(.semibold))
                        .padding(6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            } else {
                VideoSurface(player: player)
            }

            if player.isLoading {
                ProgressView().tint(.white).scaleEffect(1.3)
            }

            if let message = player.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2)
                    Text(message).font(.caption).multilineTextAlignment(.center)
                    Button("다시 시도") {
                        if let item = player.current { player.play(item, expand: true) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .foregroundStyle(.white)
                .padding()
            }

            if showControls && player.errorMessage == nil {
                controls
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            scheduleHide()
        }
        .onAppear { scheduleHide() }
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack {
                HStack {
                    Button { player.isExpanded = false } label: {
                        Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Button { player.stop() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold))
                    }
                }
                .padding(12)
                Spacer()
            }

            if !player.isLoading {
                HStack(spacing: 48) {
                    Button { player.skip(by: -10); scheduleHide() } label: {
                        Image(systemName: "gobackward.10").font(.title)
                    }
                    Button { player.togglePlayPause(); scheduleHide() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                    }
                    Button { player.skip(by: 10); scheduleHide() } label: {
                        Image(systemName: "goforward.10").font(.title)
                    }
                }
            }

            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Text("\(formatTime(scrubbing ?? player.currentTime)) / \(formatTime(player.duration))")
                        .font(.caption2.monospacedDigit())
                    Spacer()
                    Button { player.playNext() } label: {
                        Image(systemName: "forward.end.fill").font(.footnote)
                    }
                }
                .padding(.horizontal, 12)
                Slider(
                    value: Binding(
                        get: { scrubbing ?? player.currentTime },
                        set: { scrubbing = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            player.seek(to: target)
                            scrubbing = nil
                        }
                        scheduleHide()
                    }
                )
                .tint(.red)
                .padding(.horizontal, 8)
            }
        }
        .foregroundStyle(.white)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard showControls else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, player.isPlaying, scrubbing == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        }
    }
}

// MARK: - 미니 플레이어 (탭바 위)

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        if let item = player.current {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: player.duration > 0 ? geo.size.width * player.currentTime / player.duration : 0)
                }
                .frame(height: 2)

                HStack(spacing: 10) {
                    Group {
                        if player.audioOnly || player.isExpanded {
                            AsyncImage(url: item.bestThumbnail) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { Color.black }
                        } else {
                            VideoSurface(player: player)
                        }
                    }
                    .frame(width: 100, height: 56)
                    .clipped()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text(item.channel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                    }
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.trailing, 6)
                .foregroundStyle(.primary)
            }
            .background(.bar)
            .contentShape(Rectangle())
            .onTapGesture { player.isExpanded = true }
        }
    }
}
