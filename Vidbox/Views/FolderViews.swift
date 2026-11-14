import SwiftUI

// MARK: - 폴더에 저장 (기존 폴더 선택 / 새 폴더 만들기)

struct SaveToFolderSheet: View {
    let item: VideoItem
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNewFolder = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ThumbnailView(url: item.bestThumbnail, cornerRadius: 6)
                            .frame(width: 80)
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                    }
                }

                Section {
                    Button { showNewFolder = true } label: {
                        Label("새 폴더 만들기", systemImage: "folder.badge.plus")
                    }
                }

                Section("저장할 폴더 (여러 개 선택 가능)") {
                    folderRow(name: LibraryStore.watchLaterName, icon: "clock", count: library.saved.count,
                              checked: library.isSaved(item)) {
                        library.toggleSaved(item)
                    }
                    ForEach(library.playlists) { folder in
                        folderRow(name: folder.name, icon: "folder", count: folder.items.count,
                                  checked: library.contains(item, in: folder.id)) {
                            library.toggle(item, in: folder.id)
                        }
                    }
                }
            }
            .navigationTitle("저장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .alert("새 폴더", isPresented: $showNewFolder) {
                TextField("폴더 이름", text: $newName)
                Button("만들고 저장") {
                    let id = library.createPlaylist(newName)
                    library.toggle(item, in: id)
                    newName = ""
                }
                Button("취소", role: .cancel) { newName = "" }
            } message: {
                Text("새 폴더를 만들고 이 항목을 넣습니다.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func folderRow(name: String, icon: String, count: Int, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 28)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    Text("\(count)개").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 홈 「저장됨」 칩: 폴더 목록

/// 기본 폴더(나중에 볼 동영상) 또는 사용자 폴더
enum FolderRef: Hashable {
    case watchLater
    case playlist(UUID)
}

struct SavedFoldersList: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showNewFolder = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("저장한 리스트").font(.title3.weight(.bold))
                Spacer()
                Button { showNewFolder = true } label: {
                    Label("새 폴더", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            folderLink(.watchLater, name: LibraryStore.watchLaterName, items: library.saved, icon: "clock")
            ForEach(library.playlists) { folder in
                folderLink(.playlist(folder.id), name: folder.name, items: folder.items, icon: "folder")
            }

            if library.playlists.isEmpty {
                Text("음악이나 영상의 저장(⊕) 버튼으로 폴더를 만들어 담을 수 있어요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .padding(.bottom, 20)
        .alert("새 폴더", isPresented: $showNewFolder) {
            TextField("폴더 이름", text: $newName)
            Button("만들기") { library.createPlaylist(newName); newName = "" }
            Button("취소", role: .cancel) { newName = "" }
        }
    }

    private func folderLink(_ ref: FolderRef, name: String, items: [VideoItem], icon: String) -> some View {
        NavigationLink(value: ref) {
            HStack(spacing: 14) {
                FolderCover(items: items, icon: icon)
                    .frame(width: 112, height: 63)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(items.isEmpty ? "비어 있음" : "\(items.count)개 · \(items.first?.title ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 폴더 표지: 첫 영상 썸네일 위에 개수 표시 (YouTube 재생목록 모양)
struct FolderCover: View {
    let items: [VideoItem]
    let icon: String

    var body: some View {
        ZStack(alignment: .trailing) {
            if let first = items.first {
                AsyncImage(url: first.bestThumbnail) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color(.secondarySystemBackground) }
            } else {
                Color(.secondarySystemBackground)
                    .overlay(Image(systemName: icon).font(.title2).foregroundStyle(.secondary))
            }
            if !items.isEmpty {
                VStack(spacing: 2) {
                    Text("\(items.count)").font(.subheadline.weight(.bold))
                    Image(systemName: "list.bullet").font(.caption)
                }
                .foregroundStyle(.white)
                .frame(maxHeight: .infinity)
                .frame(width: 40)
                .background(.black.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 폴더 안

struct FolderDetailView: View {
    let ref: FolderRef
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var name: String {
        switch ref {
        case .watchLater: return LibraryStore.watchLaterName
        case .playlist(let id): return library.playlist(id)?.name ?? ""
        }
    }

    private var items: [VideoItem] {
        switch ref {
        case .watchLater: return library.saved
        case .playlist(let id): return library.playlist(id)?.items ?? []
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    FolderCover(items: items, icon: "folder")
                        .aspectRatio(16 / 9, contentMode: .fit)
                    Text(name).font(.title2.weight(.bold))
                    Text("\(items.count)개").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        actionButton("재생", icon: "play.fill", filled: true) {
                            if let first = items.first { player.play(first, queue: items, audio: false) }
                        }
                        actionButton("음악으로 듣기", icon: "headphones", filled: false) {
                            if let first = items.first { player.play(first, queue: items, audio: true) }
                        }
                        actionButton("셔플", icon: "shuffle", filled: false) {
                            if let first = items.randomElement() {
                                player.play(first, queue: items, audio: true)
                                if !player.shuffle { player.toggleShuffle() }
                            }
                        }
                    }
                    .disabled(items.isEmpty)
                }
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(items) { item in
                    VideoRow(item: item, queue: items)
                }
                .onDelete { offsets in
                    switch ref {
                    case .watchLater: library.removeSaved(at: offsets)
                    case .playlist(let id): library.removeItems(at: offsets, from: id)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if case .playlist = ref {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = name; showRename = true } label: { Label("이름 바꾸기", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("폴더 삭제", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .alert("이름 바꾸기", isPresented: $showRename) {
            TextField("폴더 이름", text: $newName)
            Button("저장") { if case .playlist(let id) = ref { library.rename(id, to: newName) } }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("'\(name)' 폴더를 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if case .playlist(let id) = ref { library.deletePlaylist(id) }
                dismiss()
            }
        } message: {
            Text("폴더 안의 영상 목록도 함께 지워집니다.")
        }
    }

    private func actionButton(_ title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(filled ? Color(.systemBackground) : .primary)
                .background(filled ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
