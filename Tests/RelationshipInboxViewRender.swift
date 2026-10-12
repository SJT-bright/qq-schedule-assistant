import SwiftUI
import AppKit
import Darwin

// UX-20260928-QC-V isolated visual audit of the「来自关系回响」card.
// Synthetic rosters, temp roots, injected fake navigator: no chat driver is ever constructed
// for a call path, no real WeChat, no QQ, no production data. Offline rendering only.
@MainActor
final class QVFakeNavigator: RelationshipChatNavigator {
    var opened: [String] = []
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        opened.append(fullDisplayName)
        return "QC-V fake opened: \(fullDisplayName)"
    }
}

func qvContact(_ id: String, _ name: String, note: String, tags: [(String, String)], message: String = "", festival: String = "") -> RelationshipContact {
    RelationshipContact(contactId: id, name: name, userNote: note, tags: tags.map { RelationshipTag(id: $0.0, name: $0.1) },
                        cadenceMode: message.isEmpty ? "periodic" : "festival", message: message, groupName: tags.first?.1 ?? "", festival: festival)
}

@main
@MainActor
struct RelationshipInboxViewRender {
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL \(label)"); exit(1) }
        print("PASS \(label)")
    }

    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw RelationshipInboxError("usage: relationship-inbox-view-render <output-directory>") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let base = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-qv-render-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }

        let people: [RelationshipContact] = [
            qvContact("p1", "马广平（政治老师）", note: "高中政治老师 · 每年中秋问候", tags: [("teacher", "老师"), ("festival", "节日维系")], message: "马老师中秋节快乐！祝您身体健康，阖家幸福。", festival: "中秋节"),
            qvContact("p2", "陈静", note: "大学同学 · 在上海工作", tags: [("friend", "朋友")]),
            qvContact("p3", "李文", note: "", tags: [("teacher", "老师")]),
            qvContact("p4", "赵一鸣", note: "书友会认识，喜欢历史", tags: [("book", "书友")], message: "赵一鸣，周末读书会见！", festival: "周末问候"),
            qvContact("p5", "王思远", note: "前同事 · 现在深圳", tags: [("friend", "朋友"), ("work", "前同事")]),
            qvContact("p6", "刘畅", note: "健身房伙伴", tags: [("sport", "运动")]),
            qvContact("p7", "孙晓", note: "邻居 · 帮忙收过快递", tags: [("life", "生活")]),
            qvContact("p8", "周婷", note: "家长群认识的妈妈", tags: [("family", "家长")], message: "周婷您好，孩子们最近升学准备顺利吗？", festival: "开学季"),
            qvContact("p9", "吴迪", note: "球友", tags: [("sport", "运动")]),
            qvContact("p10", "郑楠", note: "", tags: [("work", "前同事")]),
            qvContact("p11", "冯锐", note: "摄影师 · 拍过团队照", tags: [("friend", "朋友")]),
            qvContact("p12", "何雨", note: "读书会发起人", tags: [("book", "书友")]),
            // Two different tag ids sharing one label: the filter menu shows them identically.
            qvContact("p13", "许静", note: "同标签不同 ID 的样例", tags: [("class-a", "同学")]),
            qvContact("p14", "崔明", note: "", tags: [("class-b", "同学")]),
        ]

        func scenario(_ name: String, contacts: [RelationshipContact]?, corrupt: Bool, revision: Int64 = 3,
                      alias: (String, String)? = nil, height: CGFloat = 1800, appearance: NSAppearance.Name = .aqua,
                      demoSearch: String? = nil, demoTag: String? = nil, demoEditingAliasFor: String? = nil) throws {
            let root = base.appendingPathComponent("root-\(name)")
            let bridge = base.appendingPathComponent("bridge-\(name)")
            for url in [root, bridge] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)
            setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)
            if contacts != nil || corrupt {
                if corrupt {
                    try Data("{broken".utf8).write(to: bridge.appendingPathComponent(RelationshipBridgeLocation.filename))
                } else if let contacts {
                    let snapshot = RelationshipSnapshot(schemaVersion: 1, sourceApp: "relationship-echo", sourceInstanceId: "qv-render", revision: revision,
                                                        updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 3600)), mode: "manual-chat-only", contacts: contacts)
                    try RelationshipInboxFiles.write(JSONEncoder().encode(snapshot), directory: bridge, name: RelationshipBridgeLocation.filename)
                }
            }
            let store = try Store(root: root, relationshipNavigator: QVFakeNavigator())
            store.guestMode = true
            store.wechatPermission = true
            _ = store.handleRelationshipURL(URL(string: "qqdispatch://relationship-maintenance")!)
            if let alias { try store.relationshipInbox.saveAlias(alias.1, contactID: alias.0) }

            let card = RelationshipInboxView(inbox: store.relationshipInbox, demoSearch: demoSearch ?? "", demoTag: demoTag ?? "",
                                             demoEditingAliasFor: demoEditingAliasFor)
            let hosting = NSHostingView(rootView: card.environmentObject(store).tint(.indigo))
            let size = CGSize(width: 1180, height: height)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFrontRegardless()
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)); hosting.layoutSubtreeIfNeeded() }
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RelationshipInboxError("离屏画布创建失败") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw RelationshipInboxError("PNG 生成失败") }
            try png.write(to: output.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
            print("rendered \(name): contacts=\(store.relationshipInbox.contacts.count) stale=\(store.relationshipInbox.isStale) fitting=\(Int(hosting.fittingSize.height))pt status=\(store.relationshipInbox.status)")
        }

        // 首次使用者：桥目录里什么都还没有
        try scenario("after-first-run", contacts: nil, corrupt: false)
        // 同步失败：桥文件损坏且无缓存
        try scenario("after-stale-corrupt", contacts: nil, corrupt: true)
        // 普通使用者：14 人名单，含同标签名不同 ID，定位名称默认折叠
        try scenario("after-populated", contacts: people, corrupt: false, alias: ("p1", "马老师"))
        try scenario("after-populated-dark", contacts: people, corrupt: false, alias: ("p1", "马老师"), appearance: .darkAqua)
        // 深度使用者：筛选命中零条时的一键清除
        try scenario("after-no-match", contacts: people, corrupt: false, demoSearch: "不存在的人")
        // 深度使用者：按显示名筛选，两个同名不同 ID 的「同学」并成一条
        try scenario("after-tag-filtered", contacts: people, corrupt: false, demoTag: "同学")
        // 展开的定位名称输入框与保存回执
        try scenario("after-alias-editing", contacts: people, corrupt: false, alias: ("p1", "马老师"), demoEditingAliasFor: "p1")
        print("QC-V renders are offline previews of synthetic data, not real WeChat acceptance.")
    }
}
