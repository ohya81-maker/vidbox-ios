import SwiftUI

struct SearchView: View {
    @StateObject private var results = FeedViewModel()
    @StateObject private var trending = FeedViewModel()
    @State private var text = ""
    @State private var submitted = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    private let categories: [(title: String, icon: String, query: String, colors: [Color])] = [
        ("음악", "music.note", "인기 음악", [.pink, .purple]),
        ("게임", "gamecontroller.fill", "게임 영상", [.indigo, .blue]),
        ("뉴스", "newspaper.fill", "오늘 뉴스", [.blue, .cyan]),
        ("스포츠", "figure.run", "스포츠 하이라이트", [.green, .teal]),
        ("영화·드라마", "film.fill", "영화 드라마 리뷰", [.orange, .red]),
        ("요리", "fork.knife", "요리 레시피", [.yellow, .orange]),
        ("여행", "airplane", "여행 브이로그", [.teal, .mint]),
        ("코미디", "face.smiling.inverse", "웃긴 영상", [.purple, .pink]),
        ("과학·기술", "cpu", "IT 테크 리뷰", [.gray, .blue]),
        ("ASMR", "ear.fill", "ASMR", [.brown, .orange]),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: text) {
                guard focused, !text.isEmpty else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                suggestions = await InnerTubeClient.shared.suggestions(for: text)
            }
        }
    }

    // MARK: 검색창 (화면 폭 가득, 유리 캡슐)

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("동영상, 채널, 음악 검색", text: $text)
                    .font(.body)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { submit(text) }
                if !text.isEmpty {
                    Button {
                        text = ""
                        submitted = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .glass(Capsule(), interactive: true)

            if focused {
                Button("취소") {
                    focused = false
                    if submitted.isEmpty { text = "" } else { text = submitted }
                }
                .foregroundStyle(.primary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: focused)
    }

    // MARK: 본문

    @ViewBuilder
    private var content: some View {
        if focused && !text.isEmpty {
            suggestionList
        } else if !submitted.isEmpty {
            ScrollView {
                FeedList(model: results)
            }
            .scrollDismissesKeyboard(.immediately)
            .hidesTabBarOnScroll()
        } else {
            explore
        }
    }

    private var suggestionList: some View {
        List {
            ForEach(suggestions, id: \.self) { s in
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(s).lineLimit(1)
                    Spacer()
                    Button {
                        text = s + " "
                    } label: {
                        Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    text = s
                    submit(s)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private var explore: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("최근 검색").font(.title3.weight(.bold))
                            Spacer()
                            Button("지우기") { recentRaw = "" }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recent, id: \.self) { q in
                                    recentChip(q)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("탐색").font(.title3.weight(.bold))
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(categories.indices, id: \.self) { i in
                            let c = categories[i]
                            categoryCard(c.title, icon: c.icon, colors: c.colors) {
                                text = c.query
                                submit(c.query)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("지금 인기 있는 동영상").font(.title3.weight(.bold))
                        .padding(.horizontal, 16)
                    FeedList(model: trending, limit: 12)
                }
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .hidesTabBarOnScroll()
        .task { if !trending.hasLoaded { await trending.load("인기 급상승 동영상") } }
    }

    private func recentChip(_ q: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(q).font(.subheadline).lineLimit(1)
            Button {
                recentRaw = recent.filter { $0 != q }.joined(separator: "\n")
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            text = q
            submit(q)
        }
    }

    private func categoryCard(_ title: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors.map { $0.opacity(0.85) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        submitted = q
        recentRaw = ([q] + recent.filter { $0 != q }).prefix(15).joined(separator: "\n")
        Task { await results.load(q) }
    }
}
