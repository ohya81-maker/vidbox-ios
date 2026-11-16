import SwiftUI

/// 채널 화면 (재생 화면에서 채널 사진·이름을 누르면): 배너 · 사진 · 이름 · 구독 · 최신 동영상(끝없이)
struct ChannelView: View {
    let channelID: String
    var fallbackName: String = ""
    var fallbackAvatar: URL? = nil

    @EnvironmentObject private var player: PlayerManager
    @State private var page: ChannelPage?
    @State private var videos: [VideoItem] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LazyVStack(spacing: 18) {
                        ForEach(videos) { item in
                            VideoCard(item: item)
                                .onAppear { if item.id == videos.last?.id { Task { await loadMore() } } }
                        }
                        if loading {
                            ProgressView().padding(24)
                        } else if failed && videos.isEmpty {
                            Button("다시 시도") { Task { await load() } }
                                .buttonStyle(.bordered)
                                .padding(32)
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .navigationTitle(page?.name ?? fallbackName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
        .task {
            if page == nil { await load() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = page?.banner {
                AsyncImage(url: banner) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color(.tertiarySystemFill) }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)
            }
            HStack(alignment: .center, spacing: 14) {
                AvatarView(url: page?.avatar ?? fallbackAvatar, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page?.name ?? fallbackName)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    if let handle = page?.handle {
                        Text(handle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text([page?.subscriberText, page?.videoCountText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)

            let on = player.isSubscribed(channelID)
            Button {
                let ch = SubscribedChannel(id: channelID, name: page?.name ?? fallbackName, avatar: page?.avatar ?? fallbackAvatar)
                withAnimation(.easeInOut(duration: 0.15)) { player.setSubscribed(ch, !on) }
            } label: {
                HStack(spacing: 6) {
                    if on { Image(systemName: "bell") }
                    Text(on ? "구독중" : "구독")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(on ? Color.primary : Color(.systemBackground))
                .background(on ? Color(.tertiarySystemFill) : Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)

            Text("동영상")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 6)
        }
        .padding(.top, 8)
    }

    private func load() async {
        loading = true
        failed = false
        defer { loading = false }
        guard let p = try? await InnerTubeClient.shared.channel(channelID) else { failed = true; return }
        page = p
        videos = p.videos.items
        next = p.videos.continuation
    }

    private func loadMore() async {
        guard !loading, let token = next else { return }
        loading = true
        defer { loading = false }
        guard let more = try? await InnerTubeClient.shared.browseContinuation(token) else { return }
        let known = Set(videos.map(\.id))
        let name = page?.name ?? fallbackName
        let avatar = page?.avatar ?? fallbackAvatar
        videos.append(contentsOf: more.items.filter { !known.contains($0.id) }.map { v in
            var v = v
            if v.channel.isEmpty { v.channel = name }
            if v.channelThumbnail == nil { v.channelThumbnail = avatar }
            return v
        })
        next = more.continuation
    }
}

/// 채널 화면으로 가는 길 (YouTube처럼 옆으로 밀려 들어오는 화면)
struct ChannelRoute: Hashable {
    let id: String
    var name: String = ""
    var avatar: URL? = nil
}

extension View {
    /// 이 화면 묶음(NavigationStack)에서 채널 화면으로 넘어갈 수 있게
    func channelDestination() -> some View {
        navigationDestination(for: ChannelRoute.self) { r in
            ChannelView(channelID: r.id, fallbackName: r.name, fallbackAvatar: r.avatar)
        }
    }
}
