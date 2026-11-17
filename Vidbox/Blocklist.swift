import Foundation
import SwiftUI

// MARK: - 채널 차단
//
// 차단한 채널의 영상은 홈·검색·쇼츠·다음 영상 어디에도 나오지 않고 재생되지 않는다.
// 영상 ⋮ 메뉴에서 차단(채널 ID + 이름) 또는 보관함에서 이름(일부)으로 차단.
// 안드로이드 앱과 같은 규칙: ID가 같거나, 이름이 같거나, (이름 규칙이면) 이름에 그 글자가 들어가면 차단.

struct BlockRule: Codable, Identifiable, Hashable {
    var id: String { (channelID ?? "") + "|" + name + (keyword ? "|k" : "") }
    var channelID: String?
    var name: String
    /// true면 이름에 이 글자가 들어간 채널 모두
    var keyword: Bool
    var avatar: URL?
    var addedAt: Date = Date()
}

final class Blocklist: ObservableObject, @unchecked Sendable {
    static let shared = Blocklist()
    private let key = "blocklist.v1"
    private let lock = NSLock()
    private var _rules: [BlockRule] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([BlockRule].self, from: data) {
            _rules = list
        } else {
            // 처음 실행: 기본 차단 (안드로이드와 같음)
            _rules = [BlockRule(channelID: nil, name: "전광훈", keyword: true),
                      BlockRule(channelID: nil, name: "전한길", keyword: true)]
            save()
        }
    }

    var rules: [BlockRule] {
        lock.lock(); defer { lock.unlock() }
        return _rules
    }

    func isBlocked(channelID: String?, name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        for r in _rules {
            if let id = r.channelID, let c = channelID, !id.isEmpty, id == c { return true }
            if !n.isEmpty, !r.name.isEmpty {
                if r.keyword ? n.localizedCaseInsensitiveContains(r.name) : n == r.name { return true }
            }
        }
        return false
    }

    func isBlocked(_ item: VideoItem) -> Bool {
        if JellyfinCatalog.isJellyfin(item.id) { return false }
        return isBlocked(channelID: item.channelID, name: item.channel)
    }

    func filter(_ items: [VideoItem]) -> [VideoItem] { items.filter { !isBlocked($0) } }

    func block(channelID: String?, name: String, avatar: URL? = nil) {
        let rule = BlockRule(channelID: channelID, name: name, keyword: false, avatar: avatar)
        mutate { list in
            if !list.contains(where: { ($0.channelID != nil && $0.channelID == channelID) || (!$0.keyword && $0.name == name) }) {
                list.insert(rule, at: 0)
            }
        }
    }

    func blockKeyword(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        mutate { list in
            if !list.contains(where: { $0.keyword && $0.name == t }) {
                list.insert(BlockRule(channelID: nil, name: t, keyword: true), at: 0)
            }
        }
    }

    func unblock(_ rule: BlockRule) {
        mutate { list in list.removeAll { $0.id == rule.id } }
    }

    private func mutate(_ change: (inout [BlockRule]) -> Void) {
        lock.lock()
        change(&_rules)
        lock.unlock()
        save()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    private func save() {
        lock.lock()
        let data = try? JSONEncoder().encode(_rules)
        lock.unlock()
        if let data { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - 보관함의 「차단한 채널」 (댓글 창처럼 아래에서 올라와 바로 보인다)

struct BlockedChannelsSheet: View {
    @ObservedObject private var blocklist = Blocklist.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemove: BlockRule?
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if blocklist.rules.isEmpty {
                    Text("차단한 채널이 없어요").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(blocklist.rules) { rule in
                    HStack(spacing: 12) {
                        avatar(rule)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(rule.keyword ? "이름에 '\(rule.name)'이(가) 들어간 채널 모두" : "채널 차단")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button { pendingRemove = rule } label: {
                            Text("해제")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
            .navigationTitle("차단한 채널 \(blocklist.rules.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("채널 이름으로 차단 추가")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("닫기")
                }
            }
            .alert("차단을 해제할까요?", isPresented: Binding(
                get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }
            ), presenting: pendingRemove) { rule in
                Button("'\(rule.name)' 차단 해제", role: .destructive) {
                    withAnimation { blocklist.unblock(rule) }
                }
                Button("취소", role: .cancel) {}
            } message: { rule in
                Text(rule.keyword ? "이름에 '\(rule.name)'이(가) 들어간 채널의 영상이 다시 보이게 돼요."
                                  : "'\(rule.name)' 채널의 영상이 다시 보이게 돼요.")
            }
            .sheet(isPresented: $showAdd) { AddBlockSheet() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func avatar(_ rule: BlockRule) -> some View {
        if let url = rule.avatar {
            AvatarView(url: url, size: 36)
        } else {
            Text(String(rule.name.prefix(1)))
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
    }
}


// MARK: - 차단 추가: 채널을 검색해서 고르기 (오타 없이). 고르지 않고 입력한 글자로 막는 것도 그대로 가능

struct AddBlockSheet: View {
    @ObservedObject private var blocklist = Blocklist.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ChannelHit] = []
    @State private var searching = false
    @State private var searchedFor = ""
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("채널 이름 검색 (예: 한길뉴스)", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !trimmed.isEmpty {
                    Section {
                        if searching && hits.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if hits.isEmpty && searchedFor == trimmed {
                            Text("찾은 채널이 없어요").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(hits) { h in hitRow(h) }
                    } header: {
                        Text("검색 결과에서 고르면 그 채널만 정확히 막아요")
                    }

                    Section {
                        let already = blocklist.rules.contains { $0.keyword && $0.name == trimmed }
                        Button {
                            withAnimation { blocklist.blockKeyword(trimmed) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "textformat").frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("'\(trimmed)' 글자로 막기").font(.subheadline.weight(.semibold))
                                    Text("이름에 이 글자가 들어간 채널 모두 (실제 채널 이름이 다르면 안 막혀요)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                capsule(already ? "추가됨" : "차단", on: already)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(already)
                    } header: {
                        Text("검색 결과 없이 입력한 글자 그대로")
                    }
                }
            }
            .navigationTitle("채널 차단 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("닫기")
                }
            }
            .task(id: trimmed) { await search(trimmed) }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private func hitRow(_ h: ChannelHit) -> some View {
        let blocked = blocklist.isBlocked(channelID: h.id, name: h.name)
        return HStack(spacing: 12) {
            AvatarView(url: h.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([h.handle, h.subscribers].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                withAnimation { blocklist.block(channelID: h.id, name: h.name, avatar: h.avatar) }
            } label: {
                capsule(blocked ? "차단됨" : "차단", on: blocked)
            }
            .buttonStyle(.plain)
            .disabled(blocked)
        }
    }

    private func capsule(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(on ? Color.secondary : Color(.systemBackground))
            .background(on ? Color.primary.opacity(0.08) : Color.primary, in: Capsule())
    }

    private func search(_ q: String) async {
        guard !q.isEmpty else { hits = []; searchedFor = ""; return }
        // 입력이 멈추면 찾는다
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        searching = true
        defer { searching = false }
        let found = (try? await InnerTubeClient.shared.searchChannels(q)) ?? []
        if Task.isCancelled { return }
        hits = found
        searchedFor = q
    }
}
