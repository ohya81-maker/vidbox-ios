import SwiftUI

/// YouTube Music 스타일 음악 플레이어 (음악 탭에서 재생할 때)
struct MusicPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var scrubTime: Double?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            background
            if let item = player.current {
                ScrollView {
                    VStack(spacing: 22) {
                        topBar
                        artwork(item)
                        titleRow(item)
                        progress
                        transport
                        queueList
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
        .offset(y: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 25)
                .onChanged { value in
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 140 { player.isExpanded = false }
                    withAnimation(.spring) { dragOffset = 0 }
                }
        )
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    // MARK: 배경 — 앨범아트를 흐리게

    private var background: some View {
        ZStack {
            Color.black
            if let item = player.current {
                AsyncImage(url: item.bestThumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.black }
                .blur(radius: 70)
                .opacity(0.7)
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button { player.isExpanded = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            Spacer()
            // 노래 / 동영상 전환
            HStack(spacing: 0) {
                modeButton("노래", selected: true) {}
                modeButton("동영상", selected: false) { player.setAudioOnly(false) }
            }
            .padding(3)
            .background(.white.opacity(0.12), in: Capsule())
            Spacer()
            Button { player.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.top, 8)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(selected ? Color.white : Color.clear, in: Capsule())
        }
    }

    private func artwork(_ item: VideoItem) -> some View {
        Color.white.opacity(0.08)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.bestThumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .overlay {
                if player.isLoading { ProgressView().tint(.white).controlSize(.large) }
            }
            .padding(.top, 6)
    }

    private func titleRow(_ item: VideoItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(item.channel)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Button { library.toggleSaved(item) } label: {
                Image(systemName: library.isSaved(item) ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 22))
                    .frame(width: 40, height: 40)
            }
            ShareLink(item: item.shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 21))
                    .frame(width: 40, height: 40)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Scrubber(current: player.currentTime, duration: player.duration) { time in
                scrubTime = time
            } onCommit: { time in
                player.seek(to: time)
            }
            HStack {
                Text(formatTime(scrubTime ?? player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 무작위 · 이전 · 재생 · 다음 · 반복

    private var transport: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(player.shuffle ? .white : .white.opacity(0.45))
                    .overlay(alignment: .bottom) {
                        if player.shuffle { Circle().fill(.white).frame(width: 4, height: 4).offset(y: 10) }
                    }
                    .frame(width: 48, height: 48)
            }
            Spacer()
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 76, height: 76)
            }
            Spacer()
            Button { player.playNext() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.45) : .white)
                    .overlay(alignment: .bottom) {
                        if player.repeatMode != .off { Circle().fill(.white).frame(width: 4, height: 4).offset(y: 10) }
                    }
                    .frame(width: 48, height: 48)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: 다음 트랙

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("다음 트랙").font(.headline)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 10)

            ForEach(player.playOrder) { song in
                Button {
                    player.play(song, expand: false)
                } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: song.bestThumbnail) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.white.opacity(0.08) }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            if song.id == player.current?.id {
                                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.5))
                                Image(systemName: "waveform")
                                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.subheadline.weight(song.id == player.current?.id ? .bold : .medium))
                                .lineLimit(1)
                            Text(song.channel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let d = song.duration {
                            Text(d).font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private var statusText: String {
        var parts: [String] = []
        if player.shuffle { parts.append("무작위") }
        switch player.repeatMode {
        case .off: break
        case .all: parts.append("전체 반복")
        case .one: parts.append("한 곡 반복")
        }
        return parts.joined(separator: " · ")
    }
}
