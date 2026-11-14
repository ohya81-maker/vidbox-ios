import SwiftUI

/// YouTube Kids 스타일 화면: 어린이용 API(youtubekids.com)의 콘텐츠만 보여준다.
struct KidsView: View {
    typealias Age = InnerTubeClient.KidsAge

    private struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        let color: Color
        let params: String?
    }

    private let categories: [Category] = [
        Category(id: "rec", title: "추천", icon: "star.fill", color: .orange, params: nil),
        Category(id: "show", title: "프로그램", icon: "tv.fill", color: .pink, params: "kgQCCAI="),
        Category(id: "music", title: "음악", icon: "music.note", color: .purple, params: "kgQCCAM="),
        Category(id: "learn", title: "학습", icon: "lightbulb.fill", color: .green, params: "kgQCCAQ="),
        Category(id: "explore", title: "탐험", icon: "globe.asia.australia.fill", color: .blue, params: "kgQCCAU="),
    ]

    @EnvironmentObject private var player: PlayerManager
    @AppStorage("kidsAge") private var ageRaw = Age.younger.rawValue
    @State private var selected = "rec"
    @State private var items: [VideoItem] = []
    @State private var isLoading = false
    @State private var failed = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var age: Age { Age(rawValue: ageRaw) ?? .younger }
    private var current: Category { categories.first { $0.id == selected } ?? categories[0] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if searching { searchField }
                    categoryBar
                    grid
                }
                .padding(.bottom, 20)
            }
            .hidesTabBarOnScroll()
            .scrollDismissesKeyboard(.immediately)
            .background(
                LinearGradient(colors: [current.color.opacity(0.18), Color(.systemBackground)],
                               startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
                .animation(.easeInOut, value: selected)
            )
            .toolbar(.hidden, for: .navigationBar)
            .task(id: "\(selected)-\(ageRaw)") { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: 헤더 — 알록달록 로고 + 검색 + 나이 선택

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array("KIDS".enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .foregroundStyle([Color.red, .orange, .green, .blue][index])
                }
            }
            .font(.system(size: 30, weight: .black, design: .rounded))
            .rotationEffect(.degrees(-3))
            Text("KTUBE")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.spring) { searching.toggle() }
                searchFocused = searching
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue, in: Circle())
            }
            Menu {
                Picker("나이", selection: $ageRaw) {
                    ForEach(Age.allCases) { a in
                        Text("\(a.emoji) \(a.label)").tag(a.rawValue)
                    }
                }
            } label: {
                Text(age.emoji)
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
                    .background(Color.yellow.opacity(0.9), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("무엇을 볼까요?", text: $query)
                .font(.system(.title3, design: .rounded))
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { Task { await load() } }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .overlay(Capsule().stroke(Color.blue.opacity(0.5), lineWidth: 2))
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 카테고리 — 크고 동그란 색깔 버튼

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(categories) { c in
                    let isOn = c.id == selected && !(searching && !query.isEmpty)
                    Button {
                        query = ""
                        withAnimation(.spring) { selected = c.id }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: c.icon)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(c.color.gradient, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: isOn ? 4 : 0))
                                .shadow(color: c.color.opacity(isOn ? 0.5 : 0.2), radius: isOn ? 8 : 3, y: 3)
                                .scaleEffect(isOn ? 1.08 : 1)
                            Text(c.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(isOn ? c.color : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: 큰 썸네일 격자

    private var grid: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, 60)
            } else if failed && items.isEmpty {
                VStack(spacing: 12) {
                    Text("🙈").font(.system(size: 60))
                    Text("영상을 불러오지 못했어요").font(.system(.headline, design: .rounded))
                    Button("다시 해볼까요?") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(items) { item in
                        Button {
                            // 다음 영상도 어린이 목록 안에서만 이어지도록 목록을 재생목록으로 넘긴다
                            player.play(item, queue: items, audio: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ThumbnailView(url: item.bestThumbnail, duration: item.duration, cornerRadius: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(current.color.opacity(0.35), lineWidth: 3))
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .onAppear { Task { await StreamResolver.shared.prefetch([item.id]) } }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        isLoading = true
        failed = false
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            if searching && !q.isEmpty {
                items = try await InnerTubeClient.shared.kidsSearch(q, age: age)
            } else {
                items = try await InnerTubeClient.shared.kidsHome(params: current.params, age: age)
            }
        } catch {
            failed = true
        }
        isLoading = false
    }
}
