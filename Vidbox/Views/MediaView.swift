import SwiftUI

// MARK: - 「미디어」 탭: 내 Jellyfin 서버

@MainActor
final class MediaModel: ObservableObject {
    @Published var loggedIn = JellyfinSession.shared.isLoggedIn
    @Published var resume: [JFItem] = []
    @Published var libraries: [JFItem] = []
    @Published var latest: [String: [JFItem]] = [:]
    @Published var loading = false
    @Published var error: String?

    func refresh() async {
        guard JellyfinSession.shared.isLoggedIn else { loggedIn = false; return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let r = JellyfinAPI.resume()
            async let l = JellyfinAPI.libraries()
            let (resumeList, libs) = try await (r, l)
            resume = resumeList
            libraries = libs
            await withTaskGroup(of: (String, [JFItem]).self) { group in
                for lib in libs {
                    group.addTask { (lib.Id, (try? await JellyfinAPI.latest(in: lib.Id)) ?? []) }
                }
                for await (id, items) in group { latest[id] = items }
            }
        } catch JellyfinError.badLogin {
            logout()
            error = "로그인이 만료됐어요. 다시 로그인해 주세요."
        } catch {
            self.error = "서버에 연결하지 못했어요.\n\(error.localizedDescription)"
        }
    }

    /// 빌드에 들어 있는 기본 계정으로 자동 로그인 (GitHub Secrets → 앱 Info.plist)
    func autoLogin() async -> Bool {
        guard !JellyfinSession.shared.isLoggedIn, !triedAuto,
              let user = Bundle.main.object(forInfoDictionaryKey: "JFAutoUser") as? String, !user.isEmpty,
              let pass = Bundle.main.object(forInfoDictionaryKey: "JFAutoPass") as? String
        else { return false }
        triedAuto = true
        loading = true
        defer { loading = false }
        do {
            try await JellyfinAPI.login(server: JellyfinSession.shared.server, user: user, password: pass)
            loggedIn = true
            await refresh()
            return true
        } catch {
            return false
        }
    }
    private var triedAuto = false

    func logout() {
        JellyfinSession.shared.clear()
        loggedIn = false
        resume = []; libraries = []; latest = [:]
    }
}

/// 항목을 눌렀을 때: 폴더면 안으로, 영상·음악이면 재생 (같은 목록의 다음 항목들을 「다음 영상」으로)
@MainActor
enum MediaPlay {
    static func play(_ item: JFItem, in list: [JFItem]) {
        let player = PlayerManager.shared
        let playable = list.filter { !$0.isFolder }
        let index = playable.firstIndex(where: { $0.Id == item.Id }) ?? 0
        let after = Array(playable.dropFirst(index + 1)).map(\.videoItem)
        if item.isAudio {
            player.play(item.videoItem, queue: playable.map(\.videoItem), audio: true)
        } else {
            let start = item.resumeSeconds > 30 && (item.progress ?? 0) < 0.95 ? item.resumeSeconds : 0
            player.play(item.videoItem, audio: false, startAt: start, upNextList: after)
        }
    }
}

struct MediaView: View {
    @StateObject private var model = MediaModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.loggedIn {
                    home
                } else if model.loading {
                    ProgressView("내 미디어에 연결하는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    JellyfinLoginView { model.loggedIn = true; Task { await model.refresh() } }
                }
            }
            .task { _ = await model.autoLogin() }
            .navigationDestination(for: JFItem.self) { item in
                JellyfinFolderView(folder: item)
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("내 미디어").font(.title2.weight(.bold))
                    Spacer()
                    Menu {
                        if let name = JellyfinSession.shared.userName { Text("\(name) · \(JellyfinSession.shared.server)") }
                        Button("새로고침") { Task { await model.refresh() } }
                        Button("로그아웃", role: .destructive) { model.logout() }
                    } label: {
                        Image(systemName: "person.crop.circle").font(.system(size: 24))
                    }
                    .tint(.primary)
                }
                .padding(.horizontal, 16)

                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }

                if !model.resume.isEmpty {
                    section("이어서 보기") {
                        ForEach(model.resume) { item in
                            Button { MediaPlay.play(item, in: [item]) } label: {
                                WideCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                ForEach(model.libraries) { lib in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(value: lib) {
                            HStack(spacing: 4) {
                                Text(lib.Name ?? "").font(.headline)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                let items = model.latest[lib.Id] ?? []
                                ForEach(items) { item in
                                    if item.isFolder {
                                        NavigationLink(value: item) { PosterCard(item: item, square: lib.CollectionType == "music") }
                                            .buttonStyle(.plain)
                                    } else {
                                        Button { MediaPlay.play(item, in: [item]) } label: {
                                            PosterCard(item: item, square: lib.CollectionType == "music")
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                if model.loading && model.libraries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await Task { await model.refresh() }.value }
        .task { if model.libraries.isEmpty { await model.refresh() } }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content() }
                    .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - 로그인

struct JellyfinLoginView: View {
    var onDone: () -> Void
    @State private var server = JellyfinSession.shared.server
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "play.tv.fill").font(.system(size: 34)).foregroundStyle(.tint)
                    Text("내 미디어 서버(Jellyfin)").font(.title3.weight(.bold))
                    Text("집 서버의 영화·드라마·음악을 K-TUBE 플레이어로 봐요. 한 번만 로그인하면 돼요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("서버") {
                TextField("서버 주소", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("계정") {
                TextField("사용자 이름", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("비밀번호", text: $password)
                    .textContentType(.password)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button {
                    Task { await login() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("로그인").bold() }
                        Spacer()
                    }
                }
                .disabled(busy || user.isEmpty || server.isEmpty)
            }
        }
        .navigationTitle("미디어")
    }

    private func login() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await JellyfinAPI.login(server: server, user: user, password: password)
            password = ""
            onDone()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "서버에 연결하지 못했어요. 주소를 확인해 주세요."
        }
    }
}

// MARK: - 폴더(라이브러리·시리즈·시즌·앨범) 안

struct JellyfinFolderView: View {
    let folder: JFItem
    @State private var items: [JFItem] = []
    @State private var loading = false
    @State private var done = false

    private var isList: Bool {
        // 에피소드·노래는 줄 목록, 나머지는 포스터 격자
        items.contains { $0.Type == "Episode" || $0.isAudio }
    }

    var body: some View {
        ScrollView {
            if isList {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        Button { MediaPlay.play(item, in: items) } label: { EpisodeRow(item: item) }
                            .buttonStyle(.plain)
                            .onAppear { if item.Id == items.last?.Id { Task { await load() } } }
                    }
                }
                .padding(16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 18) {
                    ForEach(items) { item in
                        Group {
                            if item.isFolder {
                                NavigationLink(value: item) { PosterCard(item: item, square: folder.CollectionType == "music") }
                            } else {
                                Button { MediaPlay.play(item, in: items) } label: {
                                    PosterCard(item: item, square: folder.CollectionType == "music")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear { if item.Id == items.last?.Id { Task { await load() } } }
                    }
                }
                .padding(16)
            }
            if loading { ProgressView().padding() }
        }
        .navigationTitle(folder.Name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        let page = (try? await JellyfinAPI.children(of: folder.Id, start: items.count)) ?? []
        if page.count < 60 { done = true }
        items.append(contentsOf: page.filter { p in !items.contains { $0.Id == p.Id } })
    }
}

// MARK: - 카드

private struct JFImage: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Color(.tertiarySystemFill).overlay(Image(systemName: "film").foregroundStyle(.secondary)) }
        }
    }
}

struct PosterCard: View {
    let item: JFItem
    var square = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            JFImage(url: JellyfinSession.shared.imageURL(item, width: 360))
                .frame(width: 112, height: square ? 112 : 168)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { ProgressStrip(progress: item.progress) }
            Text(item.Name ?? "").font(.caption.weight(.medium)).lineLimit(2)
                .frame(width: 112, alignment: .leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 112, alignment: .leading)
            }
        }
    }
}

struct WideCard: View {
    let item: JFItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            JFImage(url: JellyfinSession.shared.imageURL(item, backdrop: true, width: 640))
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { ProgressStrip(progress: item.progress) }
            Text(item.SeriesName ?? item.Name ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                .frame(width: 240, alignment: .leading)
            if item.SeriesName != nil {
                Text(item.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 240, alignment: .leading)
            }
        }
    }
}

struct EpisodeRow: View {
    let item: JFItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            JFImage(url: JellyfinSession.shared.imageURL(item, width: 360))
                .frame(width: item.isAudio ? 54 : 140, height: item.isAudio ? 54 : 79)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) { ProgressStrip(progress: item.progress) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let d = item.durationText {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
                if !item.isAudio, let o = item.Overview, !o.isEmpty {
                    Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct ProgressStrip: View {
    let progress: Double?
    var body: some View {
        if let p = progress {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.35))
                    Rectangle().fill(Color.red).frame(width: g.size.width * p)
                }
            }
            .frame(height: 3)
        }
    }
}
