import SwiftUI

/// 채널 화면: 배너 · 사진 · 이름 · 구독 + 탭
/// - 홈 피드 등에서 열면: 홈 · 동영상 · 재생목록 · 게시물
/// - 쇼츠에서 열면: Shorts · 재생목록 · 게시물
struct ChannelView: View {
    let channelID: String
    var fallbackName: String = ""
    var fallbackAvatar: URL? = nil
    var fromShorts = false

    @EnvironmentObject private var player: PlayerManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var page: ChannelPage?
    @State private var headerFailed = false
    @State private var tab: ChannelTab?
    @State private var content: [ChannelTab: ChannelTabPage] = [:]
    @State private var loading: Set<ChannelTab> = []
    @State private var failed: Set<ChannelTab> = []

    private var tabs: [ChannelTab] { fromShorts ? [.shorts, .playlists, .posts] : [.home, .videos, .playlists, .posts] }
    private var current: ChannelTab { tab ?? tabs[0] }
    private var name: String { page?.name.isEmpty == false ? page!.name : fallbackName }
    private var avatar: URL? { page?.avatar ?? fallbackAvatar }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                Section {
                    tabContent
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                } header: {
                    tabBar
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(for: ChannelPlaylist.self) { pl in
            BrowseFeedScreen(title: pl.title, browseID: "VL" + pl.id, empty: "재생목록이 비어 있어요.")
        }
        .task {
            if page == nil { await loadHeader() }
            await loadTab(current)
        }
        .onChange(of: tab) { _, t in
            if let t { Task { await loadTab(t) } }
        }
    }

    // MARK: 머리말

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
                AvatarView(url: avatar, size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
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
                let ch = SubscribedChannel(id: channelID, name: name, avatar: avatar)
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

            if headerFailed && page == nil {
                Button("다시 시도") { Task { await loadHeader(); await loadTab(current) } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// YouTube처럼 글자 탭 + 선택한 탭 아래 밑줄 (위로 올려도 맨 위에 붙어 있다)
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(tabs, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 8) {
                            Text(t.title)
                                .font(.subheadline.weight(current == t ? .semibold : .regular))
                                .foregroundStyle(current == t ? Color.primary : Color.secondary)
                            Capsule()
                                .fill(current == t ? Color.primary : Color.clear)
                                .frame(height: 2.5)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: 탭 내용

    @ViewBuilder
    private var tabContent: some View {
        let t = current
        let data = content[t]
        if let data, !(data.videos.isEmpty && data.playlists.isEmpty && data.posts.isEmpty) {
            switch t {
            case .home, .videos: videoList(data.videos, tab: t)
            case .shorts: shortsGrid(data.videos)
            case .playlists: playlistList(data.playlists)
            case .posts: postList(data.posts)
            }
        }
        if loading.contains(t) {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if failed.contains(t) && data == nil {
            Button("다시 시도") { Task { await loadTab(t) } }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(32)
        } else if let data, data.videos.isEmpty && data.playlists.isEmpty && data.posts.isEmpty {
            Text(emptyText(t))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(32)
        }
    }

    private func emptyText(_ t: ChannelTab) -> String {
        switch t {
        case .home, .videos: return "동영상이 없어요."
        case .shorts: return "Shorts가 없어요."
        case .playlists: return "재생목록이 없어요."
        case .posts: return "게시물이 없어요."
        }
    }

    @ViewBuilder
    private func videoList(_ items: [VideoItem], tab t: ChannelTab) -> some View {
        if sizeClass == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 22) {
                ForEach(items) { item in
                    VideoCard(item: item).onAppear { more(item, items, t) }
                }
            }
            .padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 18) {
                ForEach(items) { item in
                    VideoCard(item: item).onAppear { more(item, items, t) }
                }
            }
        }
    }

    private func shortsGrid(_ items: [VideoItem]) -> some View {
        let columns = sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 170), spacing: 6)]
            : Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(items) { item in
                Button { player.play(item) } label: {
                    Color(.tertiarySystemFill)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg")) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    AsyncImage(url: item.bestThumbnail) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color(.tertiarySystemFill) }
                                }
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
                                if let views = item.views { Text(views).font(.caption2) }
                            }
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .onAppear { more(item, items, .shorts) }
            }
        }
        .padding(.horizontal, 4)
    }

    private func playlistList(_ lists: [ChannelPlaylist]) -> some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(lists) { pl in
                NavigationLink(value: pl) {
                    HStack(alignment: .top, spacing: 12) {
                        Color(.tertiarySystemFill)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(width: 168)
                            .overlay {
                                if let thumb = pl.thumbnail {
                                    AsyncImage(url: thumb) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color(.tertiarySystemFill) }
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Label(pl.count ?? "재생목록", systemImage: "list.bullet")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(5)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pl.title).font(.subheadline.weight(.medium)).lineLimit(3)
                            Text("재생목록 전체 보기").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onAppear { if pl.id == lists.last?.id { Task { await loadMore(.playlists) } } }
            }
        }
        .padding(.horizontal, 16)
    }

    private func postList(_ posts: [ChannelPost]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(posts) { post in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        AvatarView(url: avatar, size: 32)
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let published = post.published {
                            Text(published).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    if !post.text.isEmpty {
                        Text(post.text).font(.subheadline).textSelection(.enabled)
                    }
                    if !post.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(post.images, id: \.self) { url in
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color(.tertiarySystemFill) }
                                    .frame(width: post.images.count == 1 ? 300 : 240, height: post.images.count == 1 ? 300 : 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                    }
                    if let video = post.video {
                        VideoRow(item: video)
                    }
                    if let likes = post.likes, !likes.isEmpty {
                        Label(likes, systemImage: "hand.thumbsup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { Divider() }
                .onAppear { if post.id == posts.last?.id { Task { await loadMore(.posts) } } }
            }
        }
    }

    // MARK: 불러오기

    private func more(_ item: VideoItem, _ items: [VideoItem], _ t: ChannelTab) {
        if item.id == items.last?.id { Task { await loadMore(t) } }
    }

    private func fill(_ items: [VideoItem]) -> [VideoItem] {
        items.map { v in
            var v = v
            if v.channel.isEmpty { v.channel = name }
            if v.channelThumbnail == nil { v.channelThumbnail = avatar }
            if v.channelID == nil { v.channelID = channelID }
            return v
        }
    }

    private func loadHeader() async {
        headerFailed = false
        guard let p = try? await InnerTubeClient.shared.channel(channelID) else { headerFailed = true; return }
        page = p
        if content[.videos] == nil {
            content[.videos] = ChannelTabPage(videos: fill(p.videos.items), next: p.videos.continuation)
        }
    }

    private func loadTab(_ t: ChannelTab) async {
        guard content[t] == nil, !loading.contains(t) else { return }
        loading.insert(t)
        failed.remove(t)
        defer { loading.remove(t) }
        guard var got = try? await InnerTubeClient.shared.channelTab(channelID, tab: t, params: page?.tabParams[t]) else {
            failed.insert(t)
            return
        }
        got.videos = fill(got.videos)
        content[t] = got
    }

    private func loadMore(_ t: ChannelTab) async {
        guard !loading.contains(t), let token = content[t]?.next else { return }
        loading.insert(t)
        defer { loading.remove(t) }
        guard let more = try? await InnerTubeClient.shared.channelTabMore(token, tab: t) else { return }
        var cur = content[t] ?? ChannelTabPage()
        let knownV = Set(cur.videos.map(\.id))
        cur.videos += fill(more.videos.filter { !knownV.contains($0.id) })
        let knownP = Set(cur.playlists.map(\.id))
        cur.playlists += more.playlists.filter { !knownP.contains($0.id) }
        let knownPost = Set(cur.posts.map(\.id))
        cur.posts += more.posts.filter { !knownPost.contains($0.id) }
        cur.next = more.next
        content[t] = cur
    }
}

/// 채널 화면으로 가는 길 (YouTube처럼 옆으로 밀려 들어오는 화면)
struct ChannelRoute: Hashable {
    let id: String
    var name: String = ""
    var avatar: URL? = nil
    /// 쇼츠에서 열었으면 Shorts · 재생목록 · 게시물 탭
    var shorts = false
}

extension View {
    /// 이 화면 묶음(NavigationStack)에서 채널 화면으로 넘어갈 수 있게
    func channelDestination() -> some View {
        navigationDestination(for: ChannelRoute.self) { r in
            ChannelView(channelID: r.id, fallbackName: r.name, fallbackAvatar: r.avatar, fromShorts: r.shorts)
        }
    }
}
