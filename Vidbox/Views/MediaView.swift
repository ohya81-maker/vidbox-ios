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
        // 시리즈·시즌(드라마 등)은 그 자체로 재생할 수 없다 → 이어 볼 화나 첫 화를 찾아 재생
        if item.isFolder || item.Type == "Series" || item.Type == "Season" {
            Task {
                if let ep = await JellyfinAPI.episodeToPlay(for: item) { play(ep, in: [ep]) }
            }
            return
        }
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

                // 맨 위: 최근 추가된 영화·시리즈를 큰 배경 그림으로 넘겨 본다
                if !heroItems.isEmpty {
                    HeroCarousel(items: heroItems)
                }

                if !model.resume.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("이어서 보기", icon: "play.circle.fill", tint: .red)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(model.resume) { item in
                                    Button { MediaPlay.play(item, in: [item]) } label: { ResumeCard(item: item) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                ForEach(model.libraries) { lib in
                    let items = model.latest[lib.Id] ?? []
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink(value: lib) {
                                sectionHeader(lib.Name ?? "", icon: Self.icon(lib.CollectionType), tint: Self.tint(lib.CollectionType), more: true)
                            }
                            .buttonStyle(.plain)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(items) { item in
                                        if item.isFolder {
                                            NavigationLink(value: item) { PosterCard(item: item, square: lib.CollectionType == "music", large: true) }
                                                .buttonStyle(.plain)
                                        } else {
                                            Button { MediaPlay.play(item, in: [item]) } label: {
                                                PosterCard(item: item, square: lib.CollectionType == "music", large: true)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
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

    /// 영화·시리즈 보관함의 최근 항목 (배경 그림이 있는 것만, 최대 8개)
    private var heroItems: [JFItem] {
        let libs = model.libraries.filter { ["movies", "tvshows"].contains($0.CollectionType ?? "") }
        var out: [JFItem] = []
        for lib in libs { out += (model.latest[lib.Id] ?? []).filter { $0.BackdropImageTags?.isEmpty == false }.prefix(4) }
        return Array(out.prefix(8))
    }

    private func sectionHeader(_ title: String, icon: String, tint: Color, more: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if more {
                HStack(spacing: 2) {
                    Text("전체 보기").font(.subheadline)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    static func icon(_ type: String?) -> String {
        switch type {
        case "movies": return "film.fill"
        case "tvshows": return "tv.fill"
        case "music": return "music.note"
        case "homevideos": return "video.fill"
        case "boxsets": return "square.stack.fill"
        default: return "folder.fill"
        }
    }

    static func tint(_ type: String?) -> Color {
        switch type {
        case "movies": return .orange
        case "tvshows": return .blue
        case "music": return .pink
        case "homevideos": return .green
        default: return .gray
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
    /// 미디어 첫 화면용 큰 포스터 (아이패드는 더 크게)
    var large = false
    private var w: CGFloat { large ? (UIDevice.current.userInterfaceIdiom == .pad ? 160 : 128) : 112 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            JFImage(url: JellyfinSession.shared.imageURL(item, width: 400))
                .frame(width: w, height: square ? w : w * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { ProgressStrip(progress: item.progress) }
            Text(item.Name ?? "").font(.caption.weight(.medium)).lineLimit(2)
                .frame(width: w, alignment: .leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: w, alignment: .leading)
            }
        }
    }
}

/// 재생 화면 「다음에 볼 것」의 포스터 (에피소드는 시리즈 포스터 + 회차)
struct UpNextPoster: View {
    let item: VideoItem
    var body: some View {
        let raw = String(item.id.dropFirst(3))
        let jf = JellyfinCatalog.shared.item(raw)
        let s = JellyfinSession.shared
        let url: URL? = {
            if let series = jf?.SeriesId { return URL(string: "\(s.server)/Items/\(series)/Images/Primary?fillWidth=360&quality=85") }
            if let jf { return s.imageURL(jf, width: 360) }
            return URL(string: "\(s.server)/Items/\(raw)/Images/Primary?fillWidth=360&quality=85")
        }()
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { JFImage(url: url) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { ProgressStrip(progress: jf?.progress) }
            Text(jf.map { $0.SeriesId != nil ? $0.title : ($0.Name ?? "") } ?? item.title)
                .font(.caption.weight(.medium)).lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year = jf?.ProductionYear, jf?.SeriesId == nil {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 맨 위 큰 배경 그림 넘기기 (최근 추가된 영화·시리즈)
struct HeroCarousel: View {
    let items: [JFItem]
    @State private var page = 0
    var body: some View {
        let height: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 380 : 230
        TabView(selection: $page) {
            ForEach(Array(items.enumerated()), id: \.element.Id) { index, item in
                Button { MediaPlay.play(item, in: [item]) } label: {
                    ZStack(alignment: .bottomLeading) {
                        Color.black
                            .overlay { JFImage(url: JellyfinSession.shared.imageURL(item, backdrop: true, width: 1280)) }
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.SeriesName ?? item.Name ?? "")
                                .font(.title2.weight(.heavy)).foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 8) {
                                Label("재생", systemImage: "play.fill")
                                    .font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(.white, in: Capsule())
                                    .foregroundStyle(.black)
                                if let year = item.ProductionYear {
                                    Text(String(year)).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        .padding(18)
                        .padding(.bottom, 14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: height)
        .task(id: items.count) {
            // 6초마다 다음 그림으로
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard items.count > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.5)) { page = (page + 1) % items.count }
            }
        }
    }
}

/// 이어서 보기: 멈춘 장면(서버 미리보기 이미지가 있으면) 또는 에피소드 장면·배경·포스터
struct ResumeCard: View {
    let item: JFItem
    private var width: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 320 : 250 }
    var body: some View {
        let height = width * 9 / 16
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(.secondarySystemBackground)
                if let f = item.pausedFrame {
                    // 미리보기 묶음 이미지에서 멈춘 위치의 한 칸만 보여 준다
                    let cellW = max(width, height * f.aspect)
                    let cellH = cellW / f.aspect
                    AsyncImage(url: f.url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                .frame(width: cellW * CGFloat(f.cols), height: cellH * CGFloat(f.rows))
                                .offset(x: -cellW * CGFloat(f.col), y: -cellH * CGFloat(f.row))
                                .frame(width: cellW, height: cellH, alignment: .topLeading)
                                .clipped()
                        } else if phase.error != nil {
                            fallback
                        } else {
                            Color(.secondarySystemBackground)
                        }
                    }
                } else {
                    fallback
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .frame(width: width, height: height)
            .clipped()
            // 미리보기 묶음 이미지는 잘려 보여도 터치 영역이 옆 카드까지 넘친다 → 터치는 카드 크기로만
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) { ProgressStrip(progress: item.progress) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(item.SeriesName ?? item.Name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(width: width, alignment: .leading)
            Text(remaining).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var fallback: some View {
        // 에피소드는 그 회차 장면(Primary), 영화는 배경 그림, 없으면 포스터
        let s = JellyfinSession.shared
        let url = item.SeriesId != nil && item.ImageTags?["Primary"] != nil
            ? s.imageURL(item, width: 640)
            : (s.imageURL(item, backdrop: true, width: 640) ?? s.imageURL(item, width: 640))
        return JFImage(url: url)
    }

    private var remaining: String {
        let total = Double(item.RunTimeTicks ?? 0) / 10_000_000
        let left = max(0, total - item.resumeSeconds)
        let head = item.SeriesName != nil ? item.title + " · " : ""
        return left > 60 ? head + "\(Int(left / 60))분 남음" : head
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
