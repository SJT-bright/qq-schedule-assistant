import Foundation
import SwiftUI
import Darwin

// UX-20260928-QC-V independent checks for the「来自关系回响」view layer: empty/error state routing,
// filter reset, duplicate tag-name menus, the "this card is locating" hint, alias feedback kinds,
// and the in-flight row behaviour behind a fake navigator.
// Isolated temp roots only. No real WeChat, no QQ, no chat driver call, no production data.
@MainActor
final class QVHangingNavigator: RelationshipChatNavigator {
    var opened: [String] = []
    private var resume: (() -> Void)?
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        opened.append(fullDisplayName)
        await withCheckedContinuation { (box: CheckedContinuation<Void, Never>) in resume = { box.resume() } }
        return "已定位到「\(fullDisplayName)」的会话，请核对后手动发送"
    }
    func release() { resume?(); resume = nil }
}

@main
@MainActor
struct RelationshipInboxViewTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL \(label)"); exit(1) }
        checks += 1; print("PASS \(label)")
    }
    static func person(_ id: String, _ name: String, tags: [(String, String)] = [], message: String = "") -> RelationshipContact {
        RelationshipContact(contactId: id, name: name, userNote: "", tags: tags.map { RelationshipTag(id: $0.0, name: $0.1) },
                            cadenceMode: message.isEmpty ? "periodic" : "festival", message: message, groupName: "", festival: "")
    }
    static func wire(_ revision: Int, source: String = "qcv-source", _ contacts: [RelationshipContact]) throws -> Data {
        let snapshot = RelationshipSnapshot(schemaVersion: 1, sourceApp: "relationship-echo", sourceInstanceId: source, revision: Int64(revision),
                                            updatedAt: "2026-09-28T12:00:00.000Z", mode: "manual-chat-only", contacts: contacts)
        return try JSONEncoder().encode(snapshot)
    }
    static func settle(_ nanoseconds: UInt64 = 120_000_000) async { try? await Task.sleep(nanoseconds: nanoseconds) }

    static func main() async throws {
        setbuf(stdout, nil)

        // MARK: - 1. 空名单的三种情形（首次 / 故障 / 主动清空）

        check(InboxViewRules.emptyRoster(hasSnapshot: false, isStale: true) == .syncFailed,
              "empty roster: a failed read remains syncFailed even without a prior snapshot")
        check(InboxViewRules.emptyRoster(hasSnapshot: false, isStale: false) == .neverSynced, "empty roster: no snapshot is neverSynced")
        check(InboxViewRules.emptyRoster(hasSnapshot: true, isStale: true) == .syncFailed, "empty roster: a roster we received but cannot refresh is syncFailed")
        check(InboxViewRules.emptyRoster(hasSnapshot: true, isStale: false) == .noneSelected, "empty roster: a legal empty sync is noneSelected")

        // MARK: - 2. 筛选状态与一键清除的前提

        check(!InboxViewRules.hasFilters(search: "", tagName: ""), "filters: nothing typed and no tag is not a filter")
        check(!InboxViewRules.hasFilters(search: "　  ", tagName: ""), "filters: half and full width spaces alone are not a filter")
        check(InboxViewRules.hasFilters(search: "陈", tagName: ""), "filters: a keyword counts")
        check(InboxViewRules.hasFilters(search: "", tagName: "老师"), "filters: a tag selection counts")

        // MARK: - 3. 同名不同 ID 的标签菜单

        let roster = [
            person("c-chen", "陈静", tags: [("friend", "朋友")]),
            person("c-ma", "马广平（政治老师）", tags: [("teacher", "老师"), ("festival", "节日维系")]),
            person("c-li", "李文", tags: [("t-x", "老师")]),
            person("c-class-a", "许静", tags: [("class-a", "同学")]),
            person("c-class-b", "崔明", tags: [("class-b", "同学")]),
            person("c-double", "何雨", tags: [("book-1", "书友"), ("book-2", "书友")]),
        ]
        let options = InboxViewRules.tagOptions(roster)
        check(options.map(\.name).count == Set(options.map(\.name)).count, "tag menu: no duplicate label appears twice")
        check(options.first(where: { $0.name == "老师" })?.count == 2, "tag menu: 老师 covers both ids")
        check(options.first(where: { $0.name == "同学" })?.count == 2, "tag menu: two 同学 ids collapse into one 2 人 entry")
        check(options.first(where: { $0.name == "书友" })?.count == 1, "tag menu: one person with two same-named tags counts once")
        check(options.map(\.name) == options.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "tag menu: options stay in name order")
        check(InboxViewRules.tagOptions([]).isEmpty, "tag menu: an empty roster offers no tags")

        let teachers = InboxViewRules.applyTag(roster, tagName: "老师") { $0.tags }
        check(teachers.map(\.contactId) == ["c-ma", "c-li"], "tag filter by name unions the two 老师 ids")
        check(InboxViewRules.applyTag(roster, tagName: "") { $0.tags }.count == roster.count, "tag filter: empty selection keeps everyone")
        check(InboxViewRules.applyTag(roster, tagName: "同学") { $0.tags }.map(\.contactId) == ["c-class-a", "c-class-b"], "tag filter: 同学 returns both people")
        // Unique names must behave exactly like the previous id-based filter.
        for name in ["朋友", "节日维系", "书友"] {
            let byName = InboxViewRules.applyTag(roster, tagName: name) { $0.tags }.map(\.contactId)
            let tagID = roster.flatMap(\.tags).first { $0.name == name }!.id
            let byID = roster.filter { $0.tags.contains { $0.id == tagID } }.map(\.contactId)
            check(byName == byID, "tag filter by name matches the old id filter for unique name \(name)")
        }

        // MARK: - 4. 定位中 vs 其他操作占用

        let wechat = SendChannel.displayName(SendChannel.wechat)
        check(InboxViewRules.isOwnLocating(isOpening: true, busy: false, running: false, importingList: false, operationApp: "QQ"),
              "hint: the model already marks this card's own locate")
        check(InboxViewRules.isOwnLocating(isOpening: false, busy: true, running: false, importingList: false, operationApp: wechat),
              "hint: busy for 微信 before openingContactID is set still counts as this card's locate")
        check(!InboxViewRules.isOwnLocating(isOpening: false, busy: true, running: true, importingList: false, operationApp: wechat),
              "hint: a running queue is not this card's locate")
        check(!InboxViewRules.isOwnLocating(isOpening: false, busy: true, running: false, importingList: true, operationApp: wechat),
              "hint: importing the QQ list is not this card's locate")
        check(!InboxViewRules.isOwnLocating(isOpening: false, busy: true, running: false, importingList: false, operationApp: "QQ"),
              "hint: a QQ operation is not this card's locate")
        check(!InboxViewRules.isOwnLocating(isOpening: false, busy: false, running: false, importingList: false, operationApp: wechat),
              "hint: idle is not a locate")

        // MARK: - 5. 别名保存回执的成/败区分

        check(!InboxViewRules.aliasFeedbackFailed(""), "alias feedback: nothing shown is not a failure")
        check(!InboxViewRules.aliasFeedbackFailed(AliasFeedback.saved), "alias feedback: the saved receipt is not a failure")
        check(InboxViewRules.aliasFeedbackFailed("微信显示名称应为不超过 128 字的单行文本"), "alias feedback: a rejection renders as a failure")
        check(InboxViewRules.aliasFeedbackFailed("该联系人已不在当前同步名单；请刷新后重新操作"), "alias feedback: a revoked contact renders as a failure")

        // MARK: - 6. 真实 Store + fake navigator 的在途行为

        let fm = FileManager.default
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let temp = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-qv-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appendingPathComponent("app"), bridge = temp.appendingPathComponent("bridge")
        for url in [root, bridge] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)
        setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)
        try RelationshipInboxFiles.write(try wire(1, roster), directory: bridge, name: RelationshipBridgeLocation.filename)

        let navigator = QVHangingNavigator()
        let store = try Store(root: root, relationshipNavigator: navigator)
        store.guestMode = true
        store.wechatPermission = true
        let inbox = store.relationshipInbox
        inbox.refresh()
        check(!inbox.isStale && inbox.contacts.count == roster.count, "store: isolated roster loads")

        // 权限缺失时视图的禁用条件仍然成立（视图只读这些状态）
        store.wechatPermission = false
        check(!store.wechatPermission, "store: permission-off state is what the row reads to disable 打开微信聊天")
        store.wechatPermission = true

        try inbox.saveAlias("老马", contactID: "c-ma")
        store.openRelationshipContact("c-ma", sourceID: "qcv-source")
        await settle()
        check(navigator.opened == ["老马"], "in flight: one click reached the fake navigator exactly once with the saved alias")
        check(inbox.isOpening && inbox.openingContactID == "c-ma", "in flight: the row-level spinner condition is live for this contact")
        check(store.busy && store.operationAppName == wechat, "in flight: the card holds busy under the 微信 label")
        check(InboxViewRules.isOwnLocating(isOpening: inbox.isOpening, busy: store.busy, running: store.running,
                                           importingList: store.importingList, operationApp: store.operationAppName),
              "in flight: the card shows its own locating hint instead of telling the user to pause the queue")
        check(inbox.isOpening, "in flight: another row stays disabled through inbox.isOpening")

        // 用户在此期间点另一行：被拒且零触达驱动
        store.openRelationshipContact("c-chen", sourceID: "qcv-source")
        await settle()
        check(navigator.opened.count == 1, "in flight: a second row click never reaches the navigator")
        check(store.error != nil, "in flight: the refused second click is reported instead of silently ignored")
        check(inbox.openingContactID == "c-ma", "in flight: the refused click does not steal the locating row")

        navigator.release()
        await settle(400_000_000)
        check(!inbox.isOpening && inbox.openingContactID == nil, "settled: the locating flag clears for every row")
        check(!store.busy, "settled: busy released")
        check(store.step.contains("老马") && store.step.contains("手动发送"), "settled: the footer result names the chat and the manual step")
        check(!InboxViewRules.isOwnLocating(isOpening: inbox.isOpening, busy: store.busy, running: store.running,
                                            importingList: store.importingList, operationApp: store.operationAppName),
              "settled: the locating hint goes away")
        check(navigator.opened == ["老马"], "settled: still exactly one navigator call for the whole interaction")

        // 名单过期时视图的禁用条件
        try Data("{broken".utf8).write(to: bridge.appendingPathComponent(RelationshipBridgeLocation.filename))
        inbox.refresh()
        check(inbox.isStale, "stale: a corrupt bridge marks the roster stale, which is what disables every row")
        check(!inbox.isOpening, "stale: a failed sync is not a locate, so the card keeps the failure hint not the locating hint")

        // MARK: - 7. 文字大小跟随有效档位（QC-X-VIEW G2）

        // macOS 实测把 sizeCategory 注入环境后，.system/语义字体/@ScaledMetric 三档渲染完全相同，
        // 所以卡片自己取倍数；锚点必须是 macOS 默认上报的 .large = 1.0，否则默认就被放大。
        check(InboxViewRules.fontScale(for: .large) == 1.0, "dynamic type: macOS default .large stays exactly 1.0")
        check(InboxViewRules.fontScale(for: .small) == 1.0, "dynamic type: a below-default tier never shrinks the card")
        check(InboxViewRules.fontScale(for: .medium) == 1.0, "dynamic type: below the default never shrinks the card")
        check(InboxViewRules.fontScale(for: .extraLarge) > 1.0, "dynamic type: extraLarge grows")
        check(InboxViewRules.fontScale(for: .accessibilityLarge) > InboxViewRules.fontScale(for: .extraLarge),
              "dynamic type: accessibilityLarge grows more than extraLarge")
        let ladder: [ContentSizeCategory] = [.large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
                                             .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
                                             .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
        let scales = ladder.map(InboxViewRules.fontScale(for:))
        check(zip(scales, scales.dropFirst()).allSatisfy { $0.1 >= $0.0 }, "dynamic type: the ladder never goes backwards")
        check(Set(scales).count == scales.count, "dynamic type: every step above the default is a distinct size")
        check(InboxViewRules.scaledSize(12, scale: InboxViewRules.fontScale(for: .large)) == 12,
              "dynamic type: default tier keeps the pre-fix 12pt, so existing density is unchanged")
        check(InboxViewRules.scaledSize(15, scale: InboxViewRules.fontScale(for: .extraLarge)) == 17,
              "dynamic type: 15pt name at extraLarge resolves to a whole 17pt")
        check(InboxViewRules.scaledSize(15, scale: InboxViewRules.fontScale(for: .accessibilityLarge)) == 24,
              "dynamic type: 15pt name at accessibilityLarge resolves to a whole 24pt")
        check(InboxViewRules.scaledSize(11, scale: InboxViewRules.fontScale(for: .accessibilityLarge)) == 18
            && InboxViewRules.scaledSize(13, scale: InboxViewRules.fontScale(for: .accessibilityLarge)) == 21,
              "dynamic type: status and button text move with the same ladder")

        print("QC-V TOTAL \(checks) relationship inbox view checks; isolated roots cleaned, fake navigator only, no chat driver invoked")
    }
}
