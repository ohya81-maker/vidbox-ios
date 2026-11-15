import SwiftUI

/// 지금 노래의 가사 (YouTube Music에 등록된 가사). 다음 곡으로 넘어가면 그 곡 가사로 바뀐다
struct LyricsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var lyrics: (text: String, source: String?)?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item = player.current {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.channel).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                if loading {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 40)
                } else if let lyrics {
                    Text(lyrics.text)
                        .font(.system(size: 21, weight: .bold))
                        .lineSpacing(8)
                        .textSelection(.enabled)
                    if let source = lyrics.source {
                        Text(source).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "quote.bubble").font(.system(size: 34))
                        Text("이 노래는 가사가 없어요").font(.headline)
                        Text("YouTube Music에 가사가 등록된 노래만 볼 수 있어요")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .foregroundStyle(.white)
        .task(id: player.current?.id) {
            guard let id = player.current?.id else { return }
            loading = true
            lyrics = await InnerTubeClient.shared.lyrics(videoID: id)
            loading = false
        }
    }
}

/// YouTube Music 스타일 음악 플레이어 (음악 탭에서 재생할 때)
struct MusicPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @State private var scrubTime: Double?
    @State private var dragOffset: CGFloat = 0
    @State private var showSave = false

    var body: some View {
        Group {
            if let item = player.current {
                // YouTube Music처럼 스크롤 없이 한 화면에 꽉 차게: 위 막대 · 큰 앨범아트 · 제목 · 버튼 · 진행 막대 · 재생 버튼 · 다음 트랙
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 12)
                    artwork(item)
                    Spacer(minLength: 16)
                    titleRow(item)
                    actionRow(item)
                        .padding(.top, 16)
                    progress
                        .padding(.top, 22)
                    transport
                        .padding(.top, 6)
                    Spacer(minLength: 8)
                    upNextHandle
                }
                .padding(.horizontal, 24)
            } else {
                Color.clear
            }
        }
        // 배경은 레이아웃에 영향을 주지 않도록 background로 (ZStack에 넣으면 큰 이미지가 화면을 밀어냄)
        .background { background }
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
        .sheet(isPresented: $showSave) {
            if let item = player.current { SaveToFolderSheet(item: item, music: true) }
        }
        .sheet(isPresented: $showLyrics) {
            LyricsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black.opacity(0.85))
                .environment(\.colorScheme, .dark)
        }
        .sheet(isPresented: $showQueue) {
            ScrollView {
                queueList
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black.opacity(0.85))
            .environment(\.colorScheme, .dark)
        }
    }

    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var confirmDeleteDownload = false

    /// 맨 아래 손잡이 — 누르거나 위로 밀면 다음 트랙 목록
    private var upNextHandle: some View {
        Button { showQueue = true } label: {
            VStack(spacing: 8) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5)
                Text(nextTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(DragGesture(minimumDistance: 15).onEnded { v in
            if v.translation.height < -30 { showQueue = true }
        })
    }

    private var nextTitle: String {
        let order = player.playOrder
        if let i = order.firstIndex(where: { $0.id == player.current?.id }), i + 1 < order.count {
            return "다음 곡: " + order[i + 1].title
        }
        return "다음 트랙"
    }

    /// 저장 · 공유 · 동영상으로 보기 — 둥근 알약 버튼
    private func actionRow(_ item: VideoItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                pill("가사", icon: "quote.bubble") { showLyrics = true }
                pill(library.isInAnyFolder(item) ? "저장됨" : "저장",
                     icon: library.isInAnyFolder(item) ? "checkmark" : "text.badge.plus") { showSave = true }
                // 음원 다운로드 (인터넷 없이 듣기)
                Button {
                    let downloads = DownloadManager.shared
                    if downloads.file(item.id, .audio) != nil {
                        confirmDeleteDownload = true
                    } else if downloads.isDownloading(item.id, .audio) {
                        downloads.cancel(item.id, .audio)
                    } else {
                        downloads.start(item, kind: .audio)
                    }
                } label: {
                    DownloadPillLabel(id: item.id, dark: true)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .confirmationDialog("다운로드한 음원을 삭제할까요?", isPresented: $confirmDeleteDownload, titleVisibility: .visible) {
                    Button("삭제", role: .destructive) {
                        if let f = DownloadManager.shared.file(item.id, .audio) { DownloadManager.shared.delete(f) }
                    }
                }
                ShareLink(item: item.shareURL) {
                    pillLabel("공유", icon: "arrowshape.turn.up.right")
                }
                pill("다음 트랙", icon: "list.bullet") { showQueue = true }
            }
        }
        .scrollClipDisabled()
    }

    private func pill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, icon: icon) }
    }

    private func pillLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.white.opacity(0.12), in: Capsule())
    }

    // MARK: 배경 — 앨범아트를 흐리게

    private var background: some View {
        ZStack {
            Color.black
            if let item = player.current {
                HiResArtwork(item: item)
                .blur(radius: 70)
                .opacity(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
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
                // 고화질 표지 (1280x720 / 앨범아트 1200px)
                HiResArtwork(item: item)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .overlay {
                if player.isLoading { ProgressView().tint(.white).controlSize(.large) }
            }
            // 화면이 작아도 아래 버튼들이 밀리지 않게 남는 높이만큼만
            .frame(maxWidth: .infinity)
            .layoutPriority(-1)
    }

    private func titleRow(_ item: VideoItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(item.channel)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var progress: some View { MusicProgressBar() }

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
            .padding(.top, 14)

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

/// 음악 재생 막대 — 재생 위치(0.5초마다)를 이 작은 화면만 지켜본다
private struct MusicProgressBar: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var clock = PlayerManager.shared.clock
    @State private var scrubTime: Double?

    var body: some View {
        VStack(spacing: 4) {
            Scrubber(current: clock.time, duration: player.duration) { time in
                scrubTime = time
            } onCommit: { time in
                player.seek(to: time)
            }
            HStack {
                Text(formatTime(scrubTime ?? clock.time))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}
