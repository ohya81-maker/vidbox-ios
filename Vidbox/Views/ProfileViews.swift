import SwiftUI
import UIKit

// MARK: - 보관함(프로필) 화면들
//
// 홈의 NavigationStack 경로(path)에 값으로 쌓는다 → 뒤로 가기가 한 단계씩 정확히(보관함으로) 돌아온다.

enum ProfileRoute: Hashable {
    case library, history, youtubeHistory, liked, comments, saved
}

extension View {
    func profileDestinations() -> some View {
        navigationDestination(for: ProfileRoute.self) { route in
            switch route {
            case .library: LibraryView()
            case .history: HistoryScreen()
            case .youtubeHistory: BrowseFeedScreen(title: "YouTube 시청 기록", browseID: "FEhistory")
            case .liked: LikedScreen()
            case .comments: MyCommentsScreen()
            case .saved: SavedScreen()
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
        confirmationDialog(title, isPresented: Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } }
        ), titleVisibility: .visible) {
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
    @State private var showLogin = false
    @State private var confirmLogout = false
    @State private var confirmClearHistory = false
    @State private var showBlocked = false

    private var folderCount: Int { library.playlists.filter { $0.isMusic != true }.count + 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if update.available { updateBanner }

                accountCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    tile(.history, "시청 기록", "clock.arrow.circlepath",
                         library.history.isEmpty ? "비어 있음" : "\(library.history.count)개")
                    tile(.liked, "좋아요", "hand.thumbsup",
                         account.isLoggedIn ? "YouTube 계정" : "로그인 필요")
                    tile(.comments, "댓글", "text.bubble",
                         comments.items.isEmpty ? "비어 있음" : "\(comments.items.count)개")
                    tile(.saved, "저장", "bookmark", "폴더 \(folderCount)개")
                }

                if !library.history.isEmpty { recentRow }

                sectionTitle("재생 설정")
                Toggle(isOn: $player.miniPlayerEnabled) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.bottomhalf.inset.filled")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("화면 내려도 계속 재생").font(.body.weight(.medium))
                            Text("끄면 재생 화면을 내릴 때 재생을 멈춰요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .padding(16)
                .profileGlass()

                sectionTitle("차단")
                Button { showBlocked = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("차단한 채널").font(.body.weight(.medium))
                            Text("\(blocklist.rules.count)개 · 어디에도 나오지 않고 재생되지 않아요")
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
                    .padding(16)
                    .contentShape(Rectangle())
                    .profileGlass()
                }
                .buttonStyle(.plain)

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
        .confirmationDialog("로그아웃할까요?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { account.logout() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("YouTube 계정의 구독·추천·시청 기록을 더 이상 가져오지 않아요. 다시 로그인하면 돌아와요.")
        }
        .confirmationDialog("시청 기록을 모두 지울까요?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
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

    private func tile(_ route: ProfileRoute, _ title: String, _ icon: String, _ detail: String) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .profileGlass(cornerRadius: 20)
        }
        .buttonStyle(.plain)
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
                    Button("모두 지우기") { confirmClear = true }
                }
            }
        }
        .deleteConfirmation("시청 기록에서 지울까요?", message: "선택한 영상이 이 기기의 시청 기록에서 지워져요.",
                            pending: $pending) { library.removeHistory(at: $0) }
        .confirmationDialog("시청 기록을 모두 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
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
            BrowseFeedScreen(title: "좋아요 표시한 동영상", browseID: "VLLL")
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

struct SavedScreen: View {
    var body: some View {
        ScrollView {
            SavedFoldersList()
                .padding(.top, 4)
        }
        .navigationTitle("저장")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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

    var available: Bool { Self.currentBuild > 0 && latestBuild > Self.currentBuild }

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
