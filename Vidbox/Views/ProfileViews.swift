import SwiftUI
import UIKit

// MARK: - 보관함(프로필) 화면들
//
// 홈의 NavigationStack 경로(path)에 값으로 쌓는다 → 뒤로 가기가 한 단계씩 정확히(보관함으로) 돌아온다.

enum ProfileRoute: Hashable, Identifiable {
    var id: Self { self }
    case library, history, youtubeHistory, liked, comments, saved, subscriptions
}

extension View {
    func profileDestinations() -> some View {
        navigationDestination(for: ProfileRoute.self) { route in
            switch route {
            case .library: LibraryView()
            case .history: HistoryScreen()
            case .youtubeHistory: BrowseFeedScreen(title: "YouTube 시청 기록", browseID: "FEhistory", empty: "YouTube 계정의 시청 기록이 없어요.")
            case .liked: LikedScreen()
            case .comments: MyCommentsScreen()
            case .saved: SavedScreen()
            case .subscriptions: SubscriptionsScreen()
            }
        }
    }

    /// 보관함의 납작한 유리 카드 (하단 탭바처럼)
    func profileGlass(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.primary.opacity(0.035), in: shape)
            .glass(shape)
    }

    /// 밀어서 지우기 등: 바로 지우지 않고 한 번 더 묻는다
    func deleteConfirmation(_ title: String, message: String, button: String = "삭제",
                            pending: Binding<IndexSet?>, perform: @escaping (IndexSet) -> Void) -> some View {
        alert(title, isPresented: Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }
        )) {
            Button(button, role: .destructive) {
                if let offsets = pending.wrappedValue { withAnimation { perform(offsets) } }
                pending.wrappedValue = nil
            }
            Button("취소", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text(message)
        }
    }
}

// MARK: - 보관함

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var comments = CommentLog.shared
    @ObservedObject private var blocklist = Blocklist.shared
    @ObservedObject private var update = AppUpdate.shared
    @ObservedObject private var subs = SubscriptionStore.shared
    @State private var showLogin = false
    @State private var confirmLogout = false
    @State private var confirmClearHistory = false
    @State private var showBlocked = false
    @State private var sheet: ProfileRoute?

    private var folderCount: Int { library.playlists.filter { $0.isMusic != true }.count + 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if update.available { updateBanner }

                accountCard

                VStack(spacing: 0) {
                    menuRow("시청 기록", "clock.arrow.circlepath",
                            library.history.isEmpty ? "비어 있음" : "\(library.history.count)개") { sheet = .history }
                    rowDivider
                    menuRow("좋아요", "hand.thumbsup",
                            account.isLoggedIn ? "YouTube 계정에서 좋아요 표시한 동영상" : "로그인하면 볼 수 있어요") { sheet = .liked }
                    rowDivider
                    menuRow("댓글", "text.bubble",
                            comments.items.isEmpty ? "이 앱에서 쓴 댓글" : "\(comments.items.count)개") { sheet = .comments }
                    rowDivider
                    menuRow("저장", "bookmark", "＋저장 폴더 \(folderCount)개 · 다운로드 \(DownloadManager.shared.files.count)개") { sheet = .saved }
                    rowDivider
                    menuRow("구독 채널", "person.2",
                            subs.channels.isEmpty ? (account.isLoggedIn ? "YouTube 계정 구독" : "비어 있음") : "\(subs.channels.count)개") { sheet = .subscriptions }
                }
                .profileGlass()

                if !library.history.isEmpty { recentRow }

                sectionTitle("재생 설정")
                VStack(alignment: .leading, spacing: 0) {
                    Text("화면 내려도 계속 재생 · 끄면 재생 화면을 내릴 때 멈춰요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    settingToggle("영상", "play.rectangle", $player.miniPlayerEnabled)
                    Divider().padding(.leading, 52)
                    settingToggle("음악", "music.note", $player.miniPlayerMusic)
                }
                .profileGlass()

                sectionTitle("차단")
                menuRow("차단한 채널", "hand.raised",
                        "\(blocklist.rules.count)개 · 어디에도 나오지 않고 재생되지 않아요") { showBlocked = true }
                    .profileGlass()

                Text("K-TUBE \(AppUpdate.currentVersion) (\(AppUpdate.currentBuild))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .hidesTabBarOnScroll()
        .navigationTitle("보관함")
        .toolbar(.visible, for: .navigationBar)
        .task {
            // 보관함에서 「오디오 전용 기본」 설정을 뺐으므로, 켜져 있던 것은 끈다
            if player.audioOnlyPreference { player.audioOnlyPreference = false }
            await update.check(force: true)
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showBlocked) { BlockedChannelsSheet() }
        .sheet(item: $sheet) { ProfileSheet(route: $0) }
        .alert("로그아웃할까요?", isPresented: $confirmLogout) {
            Button("로그아웃", role: .destructive) { account.logout() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("YouTube 계정의 구독·추천·시청 기록을 더 이상 가져오지 않아요. 다시 로그인하면 돌아와요.")
        }
        .alert("시청 기록을 모두 지울까요?", isPresented: $confirmClearHistory) {
            Button("모두 지우기", role: .destructive) { withAnimation { library.clearHistory() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 기기에 남은 시청 기록 \(library.history.count)개가 지워지고 되돌릴 수 없어요.")
        }
    }

    private var updateBanner: some View {
        Button { update.openTestFlight() } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("새 버전 \(update.latestVersion ?? "")이 나왔어요").font(.subheadline.weight(.semibold))
                    Text("눌러서 TestFlight에서 업데이트 (나온 직후엔 몇 분 걸릴 수 있어요)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(14)
            .contentShape(Rectangle())
            .profileGlass()
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    /// 차단한 채널과 같은 메뉴 줄: 아이콘 · 제목/설명 · ›
    private func menuRow(_ title: String, _ icon: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingToggle(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                Text(title).font(.body.weight(.medium))
            }
        }
        .tint(.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("최근 본 동영상")
                Spacer()
                Button("모두 지우기") { confirmClearHistory = true }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(library.history.prefix(20)) { item in
                        Button { player.play(item) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ThumbnailView(url: item.bestThumbnail, duration: item.duration, cornerRadius: 12)
                                    .frame(width: 156)
                                Text(item.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2, reservesSpace: true)
                                    .frame(width: 156, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var accountCard: some View {
        if account.isLoggedIn {
            HStack(spacing: 14) {
                AvatarView(url: account.avatar, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name ?? "YouTube 계정").font(.headline).lineLimit(1)
                    if let handle = account.handle {
                        Text(handle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button { confirmLogout = true } label: {
                    Text("로그아웃")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .profileGlass()
        } else {
            Button { showLogin = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 44, weight: .light))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("YouTube 계정으로 로그인").font(.headline)
                        Text("내 시청 기록·구독·좋아요를 그대로 가져와요")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(16)
                .contentShape(Rectangle())
                .profileGlass()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 시청 기록

struct HistoryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var account: AccountStore
    @State private var pending: IndexSet?
    @State private var confirmClear = false

    var body: some View {
        List {
            if account.isLoggedIn {
                NavigationLink(value: ProfileRoute.youtubeHistory) {
                    Label("YouTube 계정 시청 기록", systemImage: "person.crop.circle")
                }
            }
            Section {
                if library.history.isEmpty {
                    Text("시청 기록이 없어요").foregroundStyle(.secondary)
                }
                ForEach(library.history) { item in
                    VideoRow(item: item)
                }
                .onDelete { pending = $0 }
            } header: {
                Text("이 기기에서 본 동영상")
            }
        }
        .listStyle(.plain)
        .navigationTitle("시청 기록")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !library.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { confirmClear = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("모두 지우기")
                }
            }
        }
        .deleteConfirmation("시청 기록에서 지울까요?", message: "선택한 영상이 이 기기의 시청 기록에서 지워져요.",
                            pending: $pending) { library.removeHistory(at: $0) }
        .alert("시청 기록을 모두 지울까요?", isPresented: $confirmClear) {
            Button("모두 지우기", role: .destructive) { withAnimation { library.clearHistory() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 기기에 남은 시청 기록 \(library.history.count)개가 지워지고 되돌릴 수 없어요.")
        }
    }
}

// MARK: - 좋아요

struct LikedScreen: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false

    var body: some View {
        if account.isLoggedIn {
            BrowseFeedScreen(title: "좋아요 표시한 동영상", browseID: "VLLL",
                             empty: "좋아요 표시한 동영상이 없어요.\nYouTube에서 👍를 누른 동영상이 여기에 모여요.")
        } else {
            VStack(spacing: 16) {
                Image(systemName: "hand.thumbsup")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("YouTube 계정으로 로그인하면\n좋아요 표시한 동영상을 볼 수 있어요")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button { showLogin = true } label: {
                    Text("로그인")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color(.systemBackground))
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("좋아요")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $showLogin) { LoginView() }
        }
    }
}

// MARK: - 내 댓글 (이 앱에서 쓴 댓글)

struct MyComment: Identifiable, Codable, Hashable {
    var id = UUID()
    var video: VideoItem
    var text: String
    var date = Date()
}

@MainActor
final class CommentLog: ObservableObject {
    static let shared = CommentLog()
    @Published private(set) var items: [MyComment] = []
    private let key = "myComments.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MyComment].self, from: data) {
            items = list
        }
    }

    func add(_ video: VideoItem, _ text: String) {
        items.insert(MyComment(video: video, text: text), at: 0)
        if items.count > 500 { items.removeLast(items.count - 500) }
        save()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct MyCommentsScreen: View {
    @ObservedObject private var log = CommentLog.shared
    @EnvironmentObject private var player: PlayerManager
    @State private var pending: IndexSet?

    var body: some View {
        List {
            if log.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("아직 쓴 댓글이 없어요").font(.subheadline.weight(.semibold))
                    Text("재생 화면의 댓글 창에서 쓴 댓글이 여기에 모여요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            ForEach(log.items) { c in
                Button { player.play(c.video) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ThumbnailView(url: c.video.bestThumbnail, cornerRadius: 10)
                            .frame(width: 128)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.text).font(.subheadline).lineLimit(3)
                            Text(c.video.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(c.date.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { pending = $0 }
        }
        .listStyle(.plain)
        .navigationTitle("댓글")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .deleteConfirmation("댓글 기록을 지울까요?",
                            message: "이 목록에서만 지워져요. YouTube에 올린 댓글은 그대로 남아 있어요.",
                            pending: $pending) { log.remove(at: $0) }
    }
}

// MARK: - 저장 (폴더 목록)

enum SavedKind: Hashable { case folders, downloads }

struct SavedScreen: View {
    var initial: SavedKind = .folders
    @State private var kind: SavedKind?
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var downloads = DownloadManager.shared

    private var current: SavedKind { kind ?? initial }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                segment(.folders, "＋저장", "bookmark", "\(library.playlists.filter { $0.isMusic != true }.count + 1)")
                segment(.downloads, "다운로드", "arrow.down.circle", "\(downloads.files.count)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Text(current == .folders
                 ? "＋저장 버튼으로 폴더에 담은 영상이에요. 볼 때 인터넷이 필요해요."
                 : "기기에 받은 파일이에요. 인터넷 없이 재생돼요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            if current == .folders {
                ScrollView {
                    SavedFoldersList()
                        .padding(.top, 4)
                }
            } else {
                DownloadsView(embedded: true)
            }
        }
        .navigationTitle("저장")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func segment(_ k: SavedKind, _ title: String, _ icon: String, _ count: String) -> some View {
        let on = current == k
        return Button { withAnimation(.easeInOut(duration: 0.15)) { kind = k } } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                Text(count).foregroundStyle(on ? Color(.systemBackground).opacity(0.7) : Color.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(on ? Color(.systemBackground) : Color.primary)
            .background(on ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 새 버전 알림 (NAS의 apps.json과 비교)

@MainActor
final class AppUpdate: ObservableObject {
    static let shared = AppUpdate()
    static let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    @Published private(set) var latestVersion: String?
    @Published private(set) var latestBuild = 0
    private var lastCheck = Date.distantPast

    /// 버전 문자열(1.17.0)로 비교한다 — TestFlight 빌드 번호와 설치 페이지 IPA의 빌드 번호는 서로 달라 비교할 수 없다
    var available: Bool {
        guard let latest = latestVersion, Self.currentVersion != "?" else { return false }
        return latest.compare(Self.currentVersion, options: .numeric) == .orderedDescending
    }

    func check(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCheck) > 600 else { return }
        lastCheck = Date()
        guard let url = URL(string: "https://mistylake.synology.me/ktube/apps.json?t=\(Int(Date().timeIntervalSince1970))"),
              let result = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let latest = (apps.first?["versions"] as? [[String: Any]])?.first,
              let build = Int(latest["buildVersion"] as? String ?? "") else { return }
        latestBuild = build
        latestVersion = latest["version"] as? String
    }

    /// TestFlight 앱을 연다 (그 안에서 「업데이트」)
    func openTestFlight() {
        if let url = URL(string: "itms-beta://") { UIApplication.shared.open(url) }
    }
}


// MARK: - 구독 채널 목록

struct SubscriptionsScreen: View {
    @ObservedObject private var store = SubscriptionStore.shared
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerManager
    @State private var remote: [SubscribedChannel] = []
    @State private var loading = false
    @State private var pendingRemove: SubscribedChannel?

    /// 이 기기 구독 + (로그인했으면) YouTube 계정 구독, 겹치는 건 한 번만
    private var channels: [SubscribedChannel] {
        var seen = Set<String>()
        return (store.channels + remote).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        List {
            if channels.isEmpty && !loading {
                VStack(alignment: .leading, spacing: 6) {
                    Text("구독한 채널이 없어요").font(.subheadline.weight(.semibold))
                    Text("영상 아래나 채널 화면의 「구독」을 누르면 여기에 모여요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            ForEach(channels) { ch in
                HStack(spacing: 12) {
                    NavigationLink(value: ChannelRoute(id: ch.id, name: ch.name, avatar: ch.avatar)) {
                        HStack(spacing: 12) {
                            AvatarView(url: ch.avatar, size: 40)
                            Text(ch.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                    }
                    Button { pendingRemove = ch } label: {
                        Text("구독중")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if loading && channels.isEmpty { ProgressView() } }
        .navigationTitle("구독 채널")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await loadRemote() }
        .refreshable { await loadRemote() }
        .alert("구독을 취소할까요?", isPresented: Binding(
            get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }
        ), presenting: pendingRemove) { ch in
            Button("'\(ch.name)' 구독 취소", role: .destructive) {
                withAnimation {
                    player.setSubscribed(ch, false)
                    remote.removeAll { $0.id == ch.id }
                }
            }
            Button("취소", role: .cancel) {}
        } message: { ch in
            Text(account.isLoggedIn ? "'\(ch.name)' 채널의 구독이 YouTube 계정에서도 취소돼요."
                                    : "'\(ch.name)' 채널의 새 영상이 구독 목록에 더 이상 나오지 않아요.")
        }
    }

    /// 로그인했으면 YouTube 계정의 구독 채널 목록(FEchannels)도 가져온다
    private func loadRemote() async {
        guard account.isLoggedIn else { return }
        loading = true
        defer { loading = false }
        guard let json = try? await InnerTubeClient.shared.postPublic("browse", body: ["browseId": "FEchannels"]) else { return }
        var list: [SubscribedChannel] = []
        var seen = Set<String>()
        InnerTubeClient.walkJSON(json) { key, value in
            guard key == "channelRenderer", let d = value as? [String: Any],
                  let id = d["channelId"] as? String, seen.insert(id).inserted else { return }
            let name = InnerTubeClient.plainText(d["title"]) ?? ""
            list.append(SubscribedChannel(id: id, name: name, avatar: Self.avatarURL(d["thumbnail"])))
        }
        remote = list
    }

    private static func avatarURL(_ node: Any?) -> URL? {
        guard var url = InnerTubeClient.thumbnailURL(node) else { return nil }
        // 「//yt3...」처럼 앞부분이 빠진 주소 보정
        if url.scheme == nil, let fixed = URL(string: "https:" + url.absoluteString) { url = fixed }
        return url
    }
}


// MARK: - 보관함 메뉴를 누르면 아래에서 올라오는 창 (차단한 채널과 같은 동작)

struct ProfileSheet: View {
    let route: ProfileRoute
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("닫기")
                    }
                }
                .navigationDestination(for: FolderRef.self) { ref in FolderDetailView(ref: ref) }
                .profileDestinations()
                .channelDestination()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 영상을 누르면 창을 닫고 재생 화면으로
        .onChange(of: player.current?.id) { _, _ in
            // 창이 떠 있는 동안에는 재생 화면(전체 화면)이 못 뜰 수 있다 → 창을 닫고 다시 띄운다
            dismiss()
            player.reopenPlayer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .library: LibraryView()
        case .history: HistoryScreen()
        case .youtubeHistory: BrowseFeedScreen(title: "YouTube 시청 기록", browseID: "FEhistory", empty: "YouTube 계정의 시청 기록이 없어요.")
        case .liked: LikedScreen()
        case .comments: MyCommentsScreen()
        case .saved: SavedScreen()
        case .subscriptions: SubscriptionsScreen()
        }
    }
}
