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
}

struct CommentPage {
    var comments: [Comment]
    var next: String?
    var countText: String?
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
                       let c = entities[cid] {
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
        return CommentPage(comments: ordered, next: next, countText: countText)
    }

    /// 채널의 「동영상」 탭 (최신순)
    func channelVideos(_ channelID: String) async throws -> [VideoItem] {
        let json = try await postPublic("browse", body: ["browseId": channelID, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        return Self.parsePage(json).items
    }

    /// 로그인한 YouTube 계정으로 구독/구독 취소
    func setSubscribed(_ channelID: String, _ on: Bool) async throws {
        _ = try await postPublic(on ? "subscription/subscribe" : "subscription/unsubscribe",
                                 body: ["channelIds": [channelID]])
    }
}
