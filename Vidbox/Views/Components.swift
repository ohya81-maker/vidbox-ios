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
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Button {
            player.play(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThumbnailView(url: item.bestThumbnail, duration: item.duration, isLive: item.isLive)
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(url: item.channelThumbnail)
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
                    VideoMenu(item: item)
                }
                .padding(.horizontal, 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 18)
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

    var body: some View {
        Menu {
            Button {
                library.toggleSaved(item)
            } label: {
                if library.isSaved(item) {
                    Label("저장 취소", systemImage: "bookmark.slash")
                } else {
                    Label("나중에 볼 동영상에 저장", systemImage: "bookmark")
                }
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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = gravity
        if let manager {
            manager.register(view.playerLayer)
        } else {
            view.playerLayer.player = avPlayer
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
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 20)
                .background(
                    LinearGradient(colors: [Color(red: 1, green: 0.32, blue: 0.28), Color(red: 0.75, green: 0, blue: 0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            Text("Vidbox")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.6)
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
