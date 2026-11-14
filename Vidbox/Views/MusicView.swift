import SwiftUI

struct MusicSection: Identifiable {
    let id: String
    let title: String
    let query: String
    var items: [VideoItem] = []
}

@MainActor
final class MusicViewModel: ObservableObject {
    @Published var sections: [MusicSection] = [
        MusicSection(id: "quick", title: "빠른 선곡", query: "요즘 인기 노래"),
        MusicSection(id: "chart", title: "인기 차트", query: "멜론 차트 인기곡"),
        MusicSection(id: "kpop", title: "K-POP 최신곡", query: "케이팝 최신곡"),
        MusicSection(id: "ballad", title: "감성 발라드", query: "발라드 명곡"),
        MusicSection(id: "hiphop", title: "힙합 · R&B", query: "국내 힙합 알앤비"),
        MusicSection(id: "pop", title: "해외 팝", query: "pop hits"),
        MusicSection(id: "indie", title: "인디 · 어쿠스틱", query: "인디 어쿠스틱"),
    ]
    @Published private(set) var moodSection: MusicSection?
    @Published private(set) var isLoadingMood = false
    private var loaded = false

    func loadAll() async {
        guard !loaded else { return }
        loaded = true
        await withTaskGroup(of: (String, [VideoItem]).self) { group in
            for section in sections {
                let id = section.id, query = section.query
                group.addTask { (id, await InnerTubeClient.shared.musicSongs(query)) }
            }
            for await (id, items) in group {
                if let index = sections.firstIndex(where: { $0.id == id }) {
                    sections[index].items = items
                }
            }
        }
    }

    func reload() async {
        loaded = false
        await loadAll()
    }

    func selectMood(_ mood: String?) async {
        guard let mood else { moodSection = nil; return }
        isLoadingMood = true
        let items = await InnerTubeClient.shared.musicSongs(mood + " 플레이리스트 노래")
        moodSection = MusicSection(id: "mood", title: mood, query: mood, items: items)
        isLoadingMood = false
    }
}

struct MusicView: View {
    @StateObject private var model = MusicViewModel()
    @EnvironmentObject private var player: PlayerManager
    @State private var selectedMood: String?

    private let moods = ["운동", "휴식", "집중", "출퇴근", "신나는", "잠잘 때", "드라이브", "카페", "비 오는 날", "슬픔"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    moodBar

                    if model.isLoadingMood {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let mood = model.moodSection {
                        quickPicks(mood)
                    }

                    if let quick = model.sections.first {
                        quickPicks(quick)
                    }
                    ForEach(model.sections.dropFirst()) { section in
                        shelf(section)
                    }
                }
                .padding(.vertical, 8)
            }
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(
                                LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: Circle()
                            )
                        Text("Music").font(.system(size: 20, weight: .bold)).tracking(-0.5)
                    }
                    .fixedSize()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadAll() }
        }
    }

    private var moodBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(moods, id: \.self) { mood in
                    ChipButton(title: mood, isOn: selectedMood == mood) {
                        selectedMood = selectedMood == mood ? nil : mood
                        Task { await model.selectMood(selectedMood) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 빠른 선곡 — 4줄씩 가로로 넘기는 목록

    private func quickPicks(_ section: MusicSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(section)
            if section.items.isEmpty {
                placeholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 4), spacing: 16) {
                        ForEach(section.items) { song in
                            songRow(song, queue: section.items)
                                .frame(width: 300)
                        }
                    }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    private func songRow(_ song: VideoItem, queue: [VideoItem]) -> some View {
        Button {
            player.play(song, queue: queue, audio: true, expand: false)
        } label: {
            HStack(spacing: 12) {
                artwork(song, size: 52, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text([song.channel, song.duration].compactMap { s in
                        guard let s, !s.isEmpty else { return nil }
                        return s
                    }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.current?.id == song.id {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 가로 선반 — 정사각형 앨범 카드

    private func shelf(_ section: MusicSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(section)
            if section.items.isEmpty {
                placeholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(section.items) { song in
                            Button {
                                player.play(song, queue: section.items, audio: true, expand: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    artwork(song, size: 150, radius: 10)
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(song.channel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func header(_ section: MusicSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title).font(.title2.weight(.bold))
            Spacer()
            if let first = section.items.first {
                Button {
                    player.play(first, queue: section.items, audio: true, expand: false)
                } label: {
                    Label("모두 재생", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func artwork(_ song: VideoItem, size: CGFloat, radius: CGFloat) -> some View {
        AsyncImage(url: song.bestThumbnail) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(.secondarySystemBackground)
                .overlay(Image(systemName: "music.note").foregroundStyle(.tertiary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var placeholder: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(height: 80)
    }
}
