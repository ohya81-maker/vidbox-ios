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

// MARK: - 보관함의 「차단한 채널」 (기본 접힘)

struct BlockedChannelsSection: View {
    @ObservedObject private var blocklist = Blocklist.shared
    @State private var expanded = false
    @State private var pendingRemove: BlockRule?
    @State private var showAdd = false
    @State private var newKeyword = ""

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
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
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                Button { newKeyword = ""; showAdd = true } label: {
                    Label("채널 이름으로 차단 추가", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .tint(.red)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("차단한 채널").font(.body.weight(.semibold))
                        Text("\(blocklist.rules.count)개 · 어디에도 나오지 않고 재생되지 않아요")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.secondary)
        }
        .confirmationDialog("차단을 해제할까요?", isPresented: Binding(
            get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }
        ), titleVisibility: .visible, presenting: pendingRemove) { rule in
            Button("'\(rule.name)' 차단 해제", role: .destructive) {
                withAnimation { blocklist.unblock(rule) }
            }
            Button("취소", role: .cancel) {}
        } message: { rule in
            Text(rule.keyword ? "이름에 '\(rule.name)'이(가) 들어간 채널의 영상이 다시 보이게 돼요."
                              : "'\(rule.name)' 채널의 영상이 다시 보이게 돼요.")
        }
        .alert("채널 이름으로 차단", isPresented: $showAdd) {
            TextField("채널 이름(일부)", text: $newKeyword)
            Button("차단") { withAnimation { blocklist.blockKeyword(newKeyword) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이름에 이 글자가 들어간 채널을 모두 막아요.")
        }
    }

    @ViewBuilder
    private func avatar(_ rule: BlockRule) -> some View {
        if let url = rule.avatar {
            AvatarView(url: url, size: 36)
        } else {
            Text(String(rule.name.prefix(1)))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.gray.gradient, in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "nosign")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.red)
                        .background(Circle().fill(Color(.systemBackground)).padding(-1))
                }
        }
    }
}
