import AVFoundation
import UniformTypeIdentifiers
import Foundation
import SwiftUI

/// 다운로드 종류: 영상(소리 포함 mp4) / 음원만(m4a)
enum DownloadKind: String, Codable, Sendable {
    case video, audio

    var label: String { self == .video ? "영상" : "음원" }
    var fileExtension: String { self == .video ? "mp4" : "m4a" }
}

/// 다운로드한 파일 하나
struct DownloadedFile: Identifiable, Codable, Hashable {
    var id: String { "\(item.id)-\(kind.rawValue)" }
    let item: VideoItem
    let kind: DownloadKind
    let fileName: String
    let size: Int64
    let date: Date

    var url: URL { DownloadManager.folder.appendingPathComponent(fileName) }
    /// 썸네일은 숨김 파일로 (파일 앱 목록에 섞이지 않게). 예전 버전 위치도 확인
    var thumbnailURL: URL {
        let hidden = DownloadManager.folder.appendingPathComponent(".\(item.id).jpg")
        let legacy = DownloadManager.folder.appendingPathComponent(item.id + ".jpg")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : hidden
    }
}

/// 재생기(다른 스레드)가 "이 영상의 다운로드 파일이 있나"를 바로 물어볼 수 있게 하는 목록
final class DownloadIndex: @unchecked Sendable {
    static let shared = DownloadIndex()
    private let lock = NSLock()
    private var map: [String: URL] = [:]   // "<id>-video" / "<id>-audio" → 파일

    func update(_ files: [DownloadedFile]) {
        lock.lock(); defer { lock.unlock() }
        map = Dictionary(files.map { ($0.id, $0.url) }, uniquingKeysWith: { a, _ in a })
    }

    /// 오디오 모드면 음원 파일 → 영상 파일, 영상 모드면 영상 파일만
    func files(for id: String, audioOnly: Bool) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let video = map["\(id)-video"], audio = map["\(id)-audio"]
        let list = audioOnly ? [audio, video] : [video]
        return list.compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static var indexFile: URL { folder.appendingPathComponent(".index.json") }
    private static var legacyIndexFile: URL { folder.appendingPathComponent("index.json") }

    /// 사용자가 고른 기기 폴더 (예: 나의 iPhone › 다운로드). 다 받으면 여기에 바로 복사한다
    private static let exportBookmarkKey = "downloadExportFolder.v1"
    @Published private(set) var exportFolderName: String?

    @Published private(set) var files: [DownloadedFile] = []
    /// 진행 중: "<id>-<kind>" → 0...1
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        let data = (try? Data(contentsOf: Self.indexFile)) ?? (try? Data(contentsOf: Self.legacyIndexFile))
        if let data, let list = try? JSONDecoder().decode([DownloadedFile].self, from: data) {
            files = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if FileManager.default.fileExists(atPath: Self.legacyIndexFile.path) {
            save()
            try? FileManager.default.removeItem(at: Self.legacyIndexFile)
        }
        DownloadIndex.shared.update(files)
        exportFolderName = resolveExportFolder()?.lastPathComponent
    }

    func file(_ id: String, _ kind: DownloadKind) -> DownloadedFile? {
        files.first { $0.item.id == id && $0.kind == kind }
    }

    func isDownloading(_ id: String, _ kind: DownloadKind) -> Bool { progress["\(id)-\(kind.rawValue)"] != nil }

    /// 이 영상의 다운로드 진행률 (종류 상관없이 하나라도 받는 중이면)
    func anyProgress(_ id: String) -> Double? {
        progress["\(id)-video"] ?? progress["\(id)-audio"]
    }

    func start(_ item: VideoItem, kind: DownloadKind) {
        let key = "\(item.id)-\(kind.rawValue)"
        guard tasks[key] == nil, file(item.id, kind) == nil else { return }
        progress[key] = 0
        lastError = nil
        tasks[key] = Task { [weak self] in
            var background: UIBackgroundTaskIdentifier = .invalid
            background = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(background) }
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                let saved = try await Self.download(item, kind: kind) { value in
                    Task { @MainActor in self?.progress[key] = value }
                }
                guard let self else { return }
                self.files.removeAll { $0.id == saved.id }
                self.files.insert(saved, at: 0)
                self.save()
                self.copyToExportFolder(saved)
            } catch {
                if !(error is CancellationError) {
                    self?.lastError = "다운로드하지 못했습니다: \(item.title)"
                }
            }
            self?.progress[key] = nil
            self?.tasks[key] = nil
        }
    }

    func cancel(_ id: String, _ kind: DownloadKind) {
        let key = "\(id)-\(kind.rawValue)"
        tasks[key]?.cancel()
    }

    func delete(_ file: DownloadedFile) {
        try? FileManager.default.removeItem(at: file.url)
        files.removeAll { $0.id == file.id }
        if !files.contains(where: { $0.item.id == file.item.id }) {
            try? FileManager.default.removeItem(at: file.thumbnailURL)
        }
        save()
    }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    // MARK: - 기기 폴더로 바로 저장

    func setExportFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            lastError = "이 폴더에는 저장할 수 없습니다."
            return
        }
        UserDefaults.standard.set(bookmark, forKey: Self.exportBookmarkKey)
        exportFolderName = url.lastPathComponent
    }

    func clearExportFolder() {
        UserDefaults.standard.removeObject(forKey: Self.exportBookmarkKey)
        exportFolderName = nil
    }

    private func resolveExportFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.exportBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.exportBookmarkKey)
        }
        return url
    }

    /// 다 받은 파일을 고른 기기 폴더에 복사 (같은 이름이 있으면 덮어쓴다)
    func copyToExportFolder(_ file: DownloadedFile) {
        guard let folder = resolveExportFolder() else { return }
        let source = file.url
        Task.detached(priority: .utility) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let target = folder.appendingPathComponent(source.lastPathComponent)
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { url in
                do {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: source, to: url)
                } catch { copyError = error }
            }
            if coordinatorError != nil || copyError != nil {
                await MainActor.run {
                    DownloadManager.shared.lastError = "기기 폴더에 저장하지 못했습니다. 폴더를 다시 지정해 주세요."
                }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(files) { try? data.write(to: Self.indexFile, options: .atomic) }
        DownloadIndex.shared.update(files)
    }

    // MARK: - 실제 다운로드

    private nonisolated static func download(_ item: VideoItem, kind: DownloadKind,
                                             progress: @escaping @Sendable (Double) -> Void) async throws -> DownloadedFile {
        let sources = try await StreamResolver.shared.downloadSources(id: item.id)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 파일 앱에서 알아볼 수 있게 제목으로 저장 (같은 제목이 이미 있으면 영상 ID를 덧붙임)
        let fileName = await uniqueFileName(for: item, kind: kind)
        let output = folder.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: output)

        switch kind {
        case .audio:
            let source = tmp.appendingPathComponent("a.mp4")
            if let audio = sources.audio, sources.muxed == nil {
                try await fetch(audio.url, length: audio.contentLength, to: source) { progress($0 * 0.95) }
            } else if let muxed = sources.muxed {
                try await fetch(muxed, length: nil, to: source) { progress($0 * 0.95) }
            } else { throw AppError.noPlayableStream }
            // m4a로 다시 저장 (재생 시간 정보가 바르게 기록되도록)
            try await export(AVURLAsset(url: source), preset: AVAssetExportPresetAppleM4A, to: output, type: .m4a)

        case .video:
            if let video = sources.video, let audio = sources.audio, sources.muxed == nil {
                let v = tmp.appendingPathComponent("v.mp4"), a = tmp.appendingPathComponent("a.mp4")
                let total = Double((video.contentLength ?? 0) + (audio.contentLength ?? 0))
                let vShare = total > 0 ? Double(video.contentLength ?? 0) / total : 0.8
                try await fetch(video.url, length: video.contentLength, to: v) { progress($0 * vShare * 0.95) }
                try await fetch(audio.url, length: audio.contentLength, to: a) { progress((vShare + $0 * (1 - vShare)) * 0.95) }
                // 영상 + 소리 합치기 (다시 인코딩하지 않음)
                let composition = try await combine(video: AVURLAsset(url: v), audio: AVURLAsset(url: a))
                try await export(composition, preset: AVAssetExportPresetPassthrough, to: output, type: .mp4)
            } else if let muxed = sources.muxed {
                try await fetch(muxed, length: nil, to: output) { progress($0) }
            } else { throw AppError.noPlayableStream }
        }
        progress(1)

        // 썸네일도 같이 보관 (인터넷 없이 목록에 보이도록)
        let thumb = folder.appendingPathComponent(".\(item.id).jpg")
        if !FileManager.default.fileExists(atPath: thumb.path),
           let (data, _) = try? await URLSession.shared.data(from: item.bestThumbnail) {
            try? data.write(to: thumb)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadedFile(item: item, kind: kind, fileName: fileName, size: size, date: Date())
    }

    private static func uniqueFileName(for item: VideoItem, kind: DownloadKind) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var title = item.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix(".") { title.removeFirst() }
        if title.count > 80 { title = String(title.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if title.isEmpty { title = item.id }
        let taken = Set(shared.files.filter { !($0.item.id == item.id && $0.kind == kind) }.map(\.fileName))
        let plain = "\(title).\(kind.fileExtension)"
        return taken.contains(plain) ? "\(title) [\(item.id)].\(kind.fileExtension)" : plain
    }

    /// YouTube는 한 번에 큰 파일을 주면 느려지므로 10MB씩 나눠 받는다
    private nonisolated static func fetch(_ url: URL, length: Int?, to file: URL,
                                          progress: @escaping @Sendable (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = 10 * 1024 * 1024
        var offset = 0
        var total = length
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            request.setValue(StreamResolver.iosUserAgent, forHTTPHeaderField: "User-Agent")
            var attempt = 0
            var result: (Data, URLResponse)?
            while result == nil {
                do { result = try await URLSession.shared.data(for: request) } catch {
                    attempt += 1
                    if attempt >= 3 || error is CancellationError { throw error }
                }
            }
            let (data, response) = result!
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw AppError.noPlayableStream
            }
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/") {
                total = Int(range[range.index(after: slash)...])
            }
            try handle.write(contentsOf: data)
            offset += data.count
            if let total, total > 0 { progress(min(1, Double(offset) / Double(total))) }
            // 전체를 다 받았거나(200), 마지막 조각이면 끝
            if http.statusCode == 200 || data.count < chunk || (total.map { offset >= $0 } ?? false) { break }
        }
    }

    private nonisolated static func combine(video: AVURLAsset, audio: AVURLAsset) async throws -> AVMutableComposition {
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audio.loadTracks(withMediaType: .audio).first
        else { throw AppError.noPlayableStream }
        let duration = CMTimeMinimum(try await video.load(.duration), try await audio.load(.duration))
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: audioTrack, at: .zero)
        return composition
    }

    private nonisolated static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw AppError.noPlayableStream }
        try await session.export(to: url, as: type)
    }
}

// MARK: - 다운로드 목록 화면

struct DownloadsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var player: PlayerManager
    @State private var filter: DownloadKind?
    @State private var pickFolder = false
    @State private var pendingDelete: IndexSet?

    private var shown: [DownloadedFile] {
        downloads.files.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        List {
            Section {
                Picker("종류", selection: $filter) {
                    Text("전체").tag(DownloadKind?.none)
                    Text("영상").tag(DownloadKind?.some(.video))
                    Text("음원").tag(DownloadKind?.some(.audio))
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }
            Section {
                // 다 받은 파일을 기기 폴더(예: 나의 iPhone › 다운로드)에 바로 복사
                Button {
                    pickFolder = true
                } label: {
                    HStack {
                        Label("기기 저장 폴더", systemImage: "folder")
                        Spacer()
                        Text(downloads.exportFolderName ?? "지정 안 함")
                            .foregroundStyle(.secondary)
                    }
                }
                if downloads.exportFolderName != nil {
                    Button("저장 폴더 해제", role: .destructive) { downloads.clearExportFolder() }
                        .font(.footnote)
                }
                Text(downloads.exportFolderName == nil
                     ? "폴더를 지정하면 다운로드가 끝날 때마다 그 폴더에 바로 저장됩니다. 지정하지 않아도 파일 앱 › 나의 iPhone › K-TUBE › Downloads 에서 볼 수 있어요."
                     : "다운로드가 끝나면 「\(downloads.exportFolderName ?? "")」 폴더에 바로 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = downloads.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            // 받는 중인 항목
            ForEach(downloads.progress.keys.sorted(), id: \.self) { key in
                HStack {
                    ProgressView(value: downloads.progress[key] ?? 0)
                    Text("\(Int((downloads.progress[key] ?? 0) * 100))%").font(.caption).monospacedDigit()
                }
            }
            if shown.isEmpty {
                Text("다운로드한 항목이 없습니다.\n재생 화면의 「다운로드」로 영상이나 음원을 저장하면 인터넷 없이 볼 수 있어요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { file in
                row(file)
            }
            .onDelete { pendingDelete = $0 }
        }
        .listStyle(.plain)
        .deleteConfirmation("다운로드한 파일을 삭제할까요?",
                            message: "기기에서 지워져요. 다시 보려면 인터넷으로 재생하거나 다시 받아야 해요.",
                            pending: $pendingDelete) { offsets in
            let list = shown
            for i in offsets where i < list.count { downloads.delete(list[i]) }
        }
        .navigationTitle("오프라인 저장")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 파일 앱에서 다운로드 폴더 열기
                Button {
                    if let url = URL(string: "shareddocuments://" + DownloadManager.folder.path) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "folder")
                }
            }
        }
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                downloads.setExportFolder(url)
                // 이미 받은 파일도 그 폴더로 복사
                for file in downloads.files { downloads.copyToExportFolder(file) }
            }
        }
    }

    private func row(_ file: DownloadedFile) -> some View {
        HStack(spacing: 12) {
            Button {
                let same = shown.filter { $0.kind == file.kind }.map(\.item)
                player.play(file.item, queue: same, audio: file.kind == .audio)
            } label: {
                HStack(spacing: 12) {
                    thumbnail(file)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(file.kind.label)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(file.kind == .video ? Color.red.opacity(0.15) : Color.purple.opacity(0.15), in: Capsule())
                            Text([file.item.channel, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 파일 앱 / 사진 앱 등으로 내보내기
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private func thumbnail(_ file: DownloadedFile) -> some View {
        let size = file.kind == .video ? CGSize(width: 112, height: 63) : CGSize(width: 63, height: 63)
        return Group {
            if let image = UIImage(contentsOfFile: file.thumbnailURL.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: file.item.bestThumbnail) { $0.resizable().scaledToFill() } placeholder: {
                    Color(.secondarySystemBackground)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if file.kind == .audio {
                Image(systemName: "music.note")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(3)
            }
        }
    }
}

/// 재생 화면의 「다운로드」 버튼 모양 — 진행률/완료 표시
struct DownloadPillLabel: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let id: String
    var dark = false
    var font: Font? = nil
    var iconSize: CGFloat = 15
    var showIcon = true

    var body: some View {
        let done = downloads.file(id, .video) != nil || downloads.file(id, .audio) != nil
        let textFont = font ?? (dark ? .subheadline.weight(.semibold) : .footnote.weight(.medium))
        HStack(spacing: iconSize < 15 ? 4 : 7) {
            if let p = downloads.anyProgress(id) {
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text("\(Int(p * 100))%").font(textFont).monospacedDigit()
            } else {
                if showIcon {
                    Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: iconSize, weight: .semibold))
                }
                Text(done ? "저장됨" : "다운로드").font(textFont)
            }
        }
    }
}
