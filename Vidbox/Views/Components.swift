import AVFoundation
import SwiftUI
import UIKit

// MARK: - 썸네일

struct ThumbnailView: View {
    let url: URL
    var duration: String?
    var isLive = false
    var cornerRadius: CGFloat = 0

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(16 / 9, contentMode: .fit)
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
                    badge("실시간", background: .red)
                } else if let duration, !duration.isEmpty {
                    badge(duration, background: .black.opacity(0.8))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func badge(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
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
                    .foregroundStyle(.gray)
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
    @EnvironmentObject private var library: LibraryStore

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
        .padding(.bottom, 16)
    }
}

// MARK: - 다음 동영상/보관함용 작은 행

struct VideoRow: View {
    let item: VideoItem
    var expand = true
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Button {
            player.play(item, expand: expand)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ThumbnailView(url: item.bestThumbnail, duration: item.duration, isLive: item.isLive, cornerRadius: 8)
                    .frame(width: 160)
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
    let player: PlayerManager

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        player.register(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

// MARK: - 앱 로고

struct AppLogo: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text("Vidbox")
                .font(.title3.weight(.bold))
                .tracking(-0.5)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
