import Foundation
import SwiftUI

// MARK: - 영상의 채널·댓글 정보 (재생 화면 아래 표시용)

struct WatchInfo: Equatable {
    var channelID: String
    var channelName: String
    var channelAvatar: URL?
    var subscriberText: String?
    /// 로그인했을 때 YouTube 계정의 구독 여부 (로그인 안 했으면 nil)
    var subscribed: Bool?
    var commentsToken: String?
}

struct Comment: Identifiable, Hashable {
    let id: String
    var author: String
    var avatar: URL?
    var text: String
    var published: String?
    var likes: String?
    var replies: String?
    /// 답글(대댓글)을 불러올 토큰
    var repliesToken: String? = nil
}

struct CommentPage {
    var comments: [Comment]
    var next: String?
    var countText: String?
    /// 로그인했을 때만 오는 댓글 작성 정보
    var createParams: String? = nil
}

struct ChannelPage {
    var name: String
    var handle: String?
    var avatar: URL?
    var banner: URL?
    var subscriberText: String?
    var videoCountText: String?
    var videos: FeedPage
    /// 탭마다 YouTube가 알려 준 요청 값 (없으면 알려진 기본값)
    var tabParams: [ChannelTab: String] = [:]
}

enum ChannelTab: String, CaseIterable, Hashable {
    case home, videos, shorts, playlists, posts

    var title: String {
        switch self {
        case .home: return "홈"
        case .videos: return "동영상"
        case .shorts: return "Shorts"
        case .playlists: return "재생목록"
        case .posts: return "게시물"
        }
    }

    var fallbackParams: String {
        switch self {
        case .home: return "EghmZWF0dXJlZPIGBAoCMgA%3D"
        case .videos: return "EgZ2aWRlb3PyBgQKAjoA"
        case .shorts: return "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"
        case .playlists: return "EglwbGF5bGlzdHPyBgQKAkIA"
        case .posts: return "Egljb21tdW5pdHnyBgQKAkoA"
        }
    }

    /// 탭 주소(…/videos, …/shorts …)로 어느 탭인지
    static func fromURL(_ url: String) -> ChannelTab? {
        let last = url.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        switch last {
        case "featured": return .home
        case "videos": return .videos
        case "shorts": return .shorts
        case "playlists": return .playlists
        case "community", "posts": return .posts
        default: return nil
        }
    }
}

struct ChannelPlaylist: Identifiable, Hashable {
    let id: String
    var title: String
    var thumbnail: URL?
    var count: String?
}

struct ChannelPost: Identifiable, Hashable {
    let id: String
    var text: String
    var published: String?
    var likes: String?
    var images: [URL] = []
    var video: VideoItem?
}

struct ChannelTabPage {
    var videos: [VideoItem] = []
    var playlists: [ChannelPlaylist] = []
    var posts: [ChannelPost] = []
    var next: String?
}

struct SubscribedChannel: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var avatar: URL?
}

// MARK: - 구독 (로그인 안 했을 때는 이 기기에만 저장, 로그인했으면 YouTube 계정에도 반영)

@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()
    @Published private(set) var channels: [SubscribedChannel] = []
    private let key = "localSubscriptions"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([SubscribedChannel].self, from: data) {
            channels = list
        }
    }

    func isSubscribed(_ id: String) -> Bool { channels.contains { $0.id == id } }

    func set(_ channel: SubscribedChannel, subscribed: Bool) {
        channels.removeAll { $0.id == channel.id }
        if subscribed { channels.insert(channel, at: 0) }
        if let data = try? JSONEncoder().encode(channels) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 구독한 채널들의 최신 영상을 번갈아 섞어서 (채널마다 최근 영상 위주)
    func latestVideos() async -> [VideoItem] {
        let list = Array(channels.prefix(15))
        let lists: [[VideoItem]] = await withTaskGroup(of: (Int, [VideoItem]).self) { group in
            for (index, ch) in list.enumerated() {
                group.addTask {
                    let items = (try? await InnerTubeClient.shared.channelVideos(ch.id)) ?? []
                    return (index, items.prefix(12).map { v in
                        var v = v
                        if v.channel.isEmpty { v.channel = ch.name }
                        if v.channelThumbnail == nil { v.channelThumbnail = ch.avatar }
                        return v
                    })
                }
            }
            var out = [[VideoItem]](repeating: [], count: list.count)
            for await (i, items) in group { out[i] = items }
            return out
        }
        var seen = Set<String>()
        var mixed: [VideoItem] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for l in lists where i < l.count {
                if seen.insert(l[i].id).inserted { mixed.append(l[i]) }
            }
        }
        return mixed
    }
}

// MARK: - InnerTube: 채널 정보·댓글·구독

extension InnerTubeClient {
    /// next 응답에서 채널(구독 버튼)과 댓글 첫 페이지 토큰을 꺼낸다
    static func parseWatchInfo(_ json: Any) -> WatchInfo? {
        var owner: [String: Any]?
        var subscribed: Bool?
        var token: String?
        walkJSON(json) { key, value in
            guard let d = value as? [String: Any] else { return }
            if key == "videoOwnerRenderer", owner == nil { owner = d }
            if key == "subscribeButtonRenderer", subscribed == nil { subscribed = d["subscribed"] as? Bool }
            if key == "itemSectionRenderer", token == nil, (d["sectionIdentifier"] as? String) == "comment-item-section" {
                walkJSON(d) { k, v in
                    if token == nil, k == "continuationCommand", let c = v as? [String: Any] { token = c["token"] as? String }
                }
            }
        }
        guard let owner,
              let id = digJSON(owner, "navigationEndpoint", "browseEndpoint", "browseId") as? String
        else { return nil }
        return WatchInfo(
            channelID: id,
            channelName: plainText(owner["title"]) ?? "",
            channelAvatar: thumbnailURL(owner["thumbnail"]),
            subscriberText: plainText(owner["subscriberCountText"]),
            subscribed: AuthStore.shared.isLoggedIn ? subscribed : nil,
            commentsToken: token
        )
    }

    func comments(_ token: String) async throws -> CommentPage {
        let json = try await postPublic("next", body: ["continuation": token])
        guard let root = json as? [String: Any] else { return CommentPage(comments: [], next: nil, countText: nil) }

        // 댓글 내용은 frameworkUpdates 안의 commentEntityPayload에 있다
        var entities: [String: Comment] = [:]
        let mutations = Self.digJSON(root, "frameworkUpdates", "entityBatchUpdate", "mutations") as? [[String: Any]] ?? []
        for m in mutations {
            guard let p = Self.digJSON(m, "payload", "commentEntityPayload") as? [String: Any],
                  let props = p["properties"] as? [String: Any],
                  let cid = props["commentId"] as? String
            else { continue }
            let author = p["author"] as? [String: Any]
            let toolbar = p["toolbar"] as? [String: Any]
            let likes = toolbar?["likeCountNotliked"] as? String
            let replies = toolbar?["replyCount"] as? String
            entities[cid] = Comment(
                id: cid,
                author: author?["displayName"] as? String ?? "",
                avatar: (author?["avatarThumbnailUrl"] as? String).flatMap(URL.init(string:)),
                text: Self.digJSON(props, "content", "content") as? String ?? "",
                published: props["publishedTime"] as? String,
                likes: (likes?.isEmpty == false && likes != "0") ? likes : nil,
                replies: (replies?.isEmpty == false && replies != "0") ? replies : nil
            )
        }

        var ordered: [Comment] = []
        var next: String?
        var countText: String?
        let endpoints = root["onResponseReceivedEndpoints"] as? [[String: Any]] ?? []
        for ep in endpoints {
            for key in ["reloadContinuationItemsCommand", "appendContinuationItemsAction"] {
                let items = Self.digJSON(ep, key, "continuationItems") as? [[String: Any]] ?? []
                for item in items {
                    if let header = item["commentsHeaderRenderer"] as? [String: Any] {
                        countText = Self.plainText(header["countText"])
                    }
                    if let thread = item["commentThreadRenderer"] as? [String: Any],
                       let cid = Self.digJSON(thread, "commentViewModel", "commentViewModel", "commentId") as? String,
                       var c = entities[cid] {
                        if let replies = thread["replies"] {
                            Self.walkJSON(replies) { k, v in
                                if c.repliesToken == nil, k == "continuationCommand", let d = v as? [String: Any] {
                                    c.repliesToken = d["token"] as? String
                                }
                            }
                        }
                        ordered.append(c)
                    }
                    // 답글 목록을 불러오면 commentViewModel이 바로 온다
                    if let cid = Self.digJSON(item, "commentViewModel", "commentId") as? String, let c = entities[cid] {
                        ordered.append(c)
                    }
                    if item["continuationItemRenderer"] != nil {
                        Self.walkJSON(item) { k, v in
                            if next == nil, k == "continuationCommand", let c = v as? [String: Any] { next = c["token"] as? String }
                        }
                    }
                }
            }
        }
        if ordered.isEmpty { ordered = Array(entities.values) }
        var createParams: String?
        Self.walkJSON(root) { k, v in
            if createParams == nil, k == "createCommentParams", let p = v as? String { createParams = p }
        }
        return CommentPage(comments: ordered, next: next, countText: countText, createParams: createParams)
    }

    /// 채널 화면: 머리말(배너·사진·이름·구독자) + 동영상 탭 첫 페이지
    func channel(_ channelID: String) async throws -> ChannelPage {
        let json = try await postPublic("browse", body: ["browseId": channelID, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        var page = ChannelPage(name: "", videos: Self.parsePage(json))
        Self.walkJSON(json) { key, value in
            guard key == "pageHeaderViewModel", page.name.isEmpty, let d = value as? [String: Any] else { return }
            page.name = Self.digJSON(d, "title", "dynamicTextViewModel", "text", "content") as? String ?? ""
            let avatars = Self.digJSON(d, "image", "decoratedAvatarViewModel", "avatar", "avatarViewModel", "image", "sources") as? [[String: Any]]
            page.avatar = (avatars?.last?["url"] as? String).flatMap(URL.init(string:))
            let banners = Self.digJSON(d, "banner", "imageBannerViewModel", "image", "sources") as? [[String: Any]]
            page.banner = (banners?.last?["url"] as? String).flatMap(URL.init(string:))
            let rows = Self.digJSON(d, "metadata", "contentMetadataViewModel", "metadataRows") as? [[String: Any]] ?? []
            for row in rows {
                for part in row["metadataParts"] as? [[String: Any]] ?? [] {
                    guard let text = Self.digJSON(part, "text", "content") as? String else { continue }
                    if text.hasPrefix("@") { page.handle = text }
                    else if text.contains("구독자") || text.lowercased().contains("subscriber") { page.subscriberText = text }
                    else if text.contains("동영상") || text.lowercased().contains("video") { page.videoCountText = text }
                }
            }
        }
        page.videos.items = page.videos.items.map { v in
            var v = v
            if v.channel.isEmpty { v.channel = page.name }
            if v.channelThumbnail == nil { v.channelThumbnail = page.avatar }
            return v
        }
        // 탭(홈·동영상·Shorts·재생목록·게시물)마다 요청 값
        Self.walkJSON(json) { key, value in
            guard key == "tabRenderer", let d = value as? [String: Any],
                  let params = Self.digJSON(d, "endpoint", "browseEndpoint", "params") as? String,
                  let url = Self.digJSON(d, "endpoint", "commandMetadata", "webCommandMetadata", "url") as? String,
                  let tab = ChannelTab.fromURL(url) else { return }
            page.tabParams[tab] = params
        }
        return page
    }

    /// 채널의 탭 하나 (홈·동영상·Shorts·재생목록·게시물)
    func channelTab(_ channelID: String, tab: ChannelTab, params: String?) async throws -> ChannelTabPage {
        let json = try await postPublic("browse", body: ["browseId": channelID, "params": params ?? tab.fallbackParams])
        return Self.parseChannelTab(json, tab)
    }

    func channelTabMore(_ token: String, tab: ChannelTab) async throws -> ChannelTabPage {
        let json = try await postPublic("browse", body: ["continuation": token])
        return Self.parseChannelTab(json, tab)
    }

    static func parseChannelTab(_ json: Any, _ tab: ChannelTab) -> ChannelTabPage {
        var page = ChannelTabPage()
        switch tab {
        case .home, .videos:
            let p = parsePage(json)
            page.videos = p.items
            page.next = tab == .videos ? p.continuation : nil
        case .shorts:
            let p = parseShortsPage(json)
            page.videos = p.items
            page.next = p.continuation
        case .playlists:
            var seen = Set<String>()
            walkJSON(json) { key, value in
                guard let d = value as? [String: Any] else { return }
                if key == "continuationCommand", page.next == nil { page.next = d["token"] as? String; return }
                if key == "lockupViewModel", let type = d["contentType"] as? String,
                   type.contains("PLAYLIST") || type.contains("PODCAST"),
                   let id = d["contentId"] as? String, seen.insert(id).inserted {
                    let title = digJSON(d, "metadata", "lockupMetadataViewModel", "title", "content") as? String ?? ""
                    var thumb: URL?
                    var count: String?
                    if let sources = digJSON(d, "contentImage", "collectionThumbnailViewModel", "primaryThumbnail",
                                             "thumbnailViewModel", "image", "sources") as? [[String: Any]] {
                        thumb = fixURL(sources.last?["url"] as? String)
                    }
                    walkJSON(d["contentImage"] ?? [String: Any]()) { k, v in
                        if thumb == nil, k == "sources", let arr = v as? [[String: Any]] { thumb = fixURL(arr.last?["url"] as? String) }
                        if count == nil, k == "thumbnailBadgeViewModel", let t = (v as? [String: Any])?["text"] as? String { count = t }
                    }
                    page.playlists.append(ChannelPlaylist(id: id, title: title, thumbnail: thumb, count: count))
                } else if key == "gridPlaylistRenderer" || key == "playlistRenderer",
                          let id = d["playlistId"] as? String, seen.insert(id).inserted {
                    let thumbs = (d["thumbnails"] as? [Any])?.first
                    page.playlists.append(ChannelPlaylist(
                        id: id, title: plainText(d["title"]) ?? "",
                        thumbnail: thumbnailURL(d["thumbnail"]) ?? thumbnailURL(thumbs),
                        count: plainText(d["videoCountShortText"]) ?? plainText(d["videoCountText"])))
                }
            }
        case .posts:
            var seen = Set<String>()
            walkJSON(json) { key, value in
                guard let d = value as? [String: Any] else { return }
                if key == "continuationCommand", page.next == nil { page.next = d["token"] as? String; return }
                guard key == "backstagePostRenderer" || key == "postRenderer",
                      let id = d["postId"] as? String, seen.insert(id).inserted else { return }
                var post = ChannelPost(id: id, text: plainText(d["contentText"]) ?? "",
                                       published: plainText(d["publishedTimeText"]),
                                       likes: plainText(d["voteCount"]))
                let att = d["backstageAttachment"]
                if let u = thumbnailURL(digJSON(att, "backstageImageRenderer", "image")) { post.images.append(u) }
                if let multi = digJSON(att, "postMultiImageRenderer", "images") as? [[String: Any]] {
                    for m in multi {
                        if let u = thumbnailURL(digJSON(m, "backstageImageRenderer", "image")) { post.images.append(u) }
                    }
                }
                if let vr = digJSON(att, "videoRenderer") as? [String: Any] {
                    post.video = parsePage(["videoRenderer": vr]).items.first
                }
                page.posts.append(post)
            }
        }
        return page
    }

    private static func fixURL(_ s: String?) -> URL? {
        guard let s else { return nil }
        return URL(string: s.hasPrefix("//") ? "https:" + s : s)
    }

    /// 채널의 「동영상」 탭 (최신순)
    func channelVideos(_ channelID: String) async throws -> [VideoItem] {
        let json = try await postPublic("browse", body: ["browseId": channelID, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        return Self.parsePage(json).items
    }

    /// 로그인한 YouTube 계정으로 댓글 쓰기
    func postComment(_ text: String, params: String) async throws {
        let json = try await postPublic("comment/create_comment", body: ["commentText": text, "createCommentParams": params])
        var failed = false
        Self.walkJSON(json) { k, v in
            if k == "status", let s = v as? String, s.contains("FAIL") { failed = true }
        }
        if failed { throw AppError.badResponse(0) }
    }

    /// 로그인한 YouTube 계정으로 구독/구독 취소
    func setSubscribed(_ channelID: String, _ on: Bool) async throws {
        _ = try await postPublic(on ? "subscription/subscribe" : "subscription/unsubscribe",
                                 body: ["channelIds": [channelID]])
    }
}
