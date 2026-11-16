import AVFoundation
import SwiftUI
import UIKit

// MARK: - Liquid Glass (iOS 26+) / 이전 버전은 반투명 재질로 대체

extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    /// 영상 위 컨트롤용 원형 유리 버튼 모양
    func glassCircle(size: CGFloat) -> some View {
        self.frame(width: size, height: size)
            .contentShape(Circle())
            .glass(Circle(), interactive: true)
    }
}

// MARK: - 썸네일

struct ThumbnailView: View {
    let url: URL
    var duration: String?
    var isLive = false
    var cornerRadius: CGFloat = 0
    var aspect: CGFloat = 16 / 9

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemBackground)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    badge("● 실시간", background: .black.opacity(0.75))
                } else if let duration, !duration.isEmpty {
                    badge(duration, background: .black.opacity(0.75))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func badge(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.gray.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - 홈/검색용 큰 카드

struct VideoCard: View {
    let item: VideoItem
    /// 누르면 할 일 (기본: 재생). 채널 화면처럼 먼저 닫고 재생해야 할 때 바꿔 쓴다
    var onPlay: ((VideoItem) -> Void)? = nil
    /// 재생기를 "지켜보지" 않는다 — 재생 상태가 바뀔 때마다 피드의 카드가 전부 다시 그려지지 않도록
    private var player: PlayerManager { PlayerManager.shared }

    private func play() {
        if let onPlay { onPlay(item) } else { player.play(item) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ThumbnailView(url: item.bestThumbnail, duration: item.duration, isLive: item.isLive)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(alignment: .top, spacing: 12) {
                // 채널 사진: 누르면 채널 화면 (내 미디어 항목은 채널이 없어 숨김)
                if let channelID = item.channelID {
                    NavigationLink(value: ChannelRoute(id: channelID, name: item.channel, avatar: item.channelThumbnail)) {
                        AvatarView(url: item.channelThumbnail)
                    }
                    .buttonStyle(.plain)
                } else if !item.id.hasPrefix("jf:") {
                    Button(action: play) { AvatarView(url: item.channelThumbnail) }
                        .buttonStyle(.plain)
                }
                Button(action: play) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(item.metaLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                VideoMenu(item: item)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 18)
        // 화면에 보이는 영상은 재생 주소를 미리 받아 둬서 누르면 바로 시작
        .onAppear { Task { await StreamResolver.shared.prefetch([item.id]) } }
    }
}

// MARK: - 다음 동영상/보관함용 작은 행

struct VideoRow: View {
    let item: VideoItem
    var expand = true
    var queue: [VideoItem]? = nil
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Button {
            player.play(item, queue: queue, expand: expand)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ThumbnailView(url: item.bestThumbnail, duration: item.duration, isLive: item.isLive, cornerRadius: 8)
                    .frame(width: 160)
                    .overlay {
                        if player.current?.id == item.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.black.opacity(0.45))
                                .overlay(Image(systemName: "waveform").foregroundStyle(.white).font(.title3))
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let views = item.views {
                        Text([views, item.published].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VideoMenu(item: item)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VideoMenu: View {
    let item: VideoItem
    @EnvironmentObject private var library: LibraryStore
    @State private var showSave = false

    var body: some View {
        Menu {
            Button {
                library.toggleSaved(item)
            } label: {
                if library.isSaved(item) {
                    Label("나중에 볼 동영상에서 빼기", systemImage: "clock.badge.xmark")
                } else {
                    Label("나중에 볼 동영상에 저장", systemImage: "clock")
                }
            }
            Button { showSave = true } label: {
                Label("폴더에 저장…", systemImage: "folder.badge.plus")
            }
            ShareLink(item: item.shareURL) {
                Label("공유", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 28)
        }
        .sheet(isPresented: $showSave) { SaveToFolderSheet(item: item) }
    }
}

// MARK: - 영상 출력 화면

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoSurface: UIViewRepresentable {
    /// 메인 플레이어(백그라운드 처리 포함)
    var manager: PlayerManager? = nil
    /// 쇼츠처럼 별도 플레이어를 쓸 때
    var avPlayer: AVPlayer? = nil
    var gravity: AVLayerVideoGravity = .resizeAspect
    /// 영상 뒤 배경. 쇼츠는 투명 — 프레임이 그려지기 전엔 아래 썸네일이 그대로 보인다
    var background: UIColor = .black
    /// 첫 프레임이 실제로 화면에 그려졌는지 (쇼츠: 그 전까지 썸네일을 보여 준다)
    var onReadyForDisplay: ((Bool, AVPlayer?) -> Void)? = nil

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = background
        view.playerLayer.videoGravity = gravity
        if let manager {
            manager.register(view.playerLayer)
        } else {
            view.playerLayer.player = avPlayer
        }
        if let onReadyForDisplay {
            context.coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                let shown = layer.player
                DispatchQueue.main.async { onReadyForDisplay(ready, shown) }
            }
        }
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = gravity
        if manager == nil, uiView.playerLayer.player !== avPlayer {
            uiView.playerLayer.player = avPlayer
        }
    }
}

// MARK: - 앱 로고

struct AppLogo: View {
    var suffix: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 18)
                .background(
                    LinearGradient(colors: [Color(red: 1, green: 0.32, blue: 0.28), Color(red: 0.75, green: 0, blue: 0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            Text("K-TUBE")
                .font(.system(size: 20, weight: .heavy))
                .tracking(-0.8)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 20, weight: .regular))
                    .tracking(-0.5)
            }
        }
        .fixedSize()
    }
}

// MARK: - 칩

struct ChipButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isOn ? Color(.systemBackground) : .primary)
                .background(isOn ? Color.primary : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
