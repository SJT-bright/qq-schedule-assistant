import SwiftUI
import AppKit
import Darwin

// UX-20260928-C isolated visual preview of the「来自关系回响」card with the improved status line,
// name-sorted rows and alias search data. Synthetic roster only; no chat driver call and no real
// WeChat. This is an offline rendering, not a real-WeChat acceptance.
@main
@MainActor
struct RelationshipInboxRenderUX {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            throw RelationshipInboxError("usage: relationship-inbox-render-ux <output-directory>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-ux-render-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let bridge = root.appendingPathComponent("bridge")
        try fm.createDirectory(at: bridge, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)
        setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)

        func person(_ id: String, _ name: String, note: String, tags: [(String, String)], message: String = "", festival: String = "") -> RelationshipContact {
            RelationshipContact(contactId: id, name: name, userNote: note, tags: tags.map { RelationshipTag(id: $0.0, name: $0.1) }, cadenceMode: message.isEmpty ? "periodic" : "festival", message: message, groupName: tags.first?.1 ?? "", festival: festival)
        }
        var roster = [
            person("p1", "马广平（政治老师）", note: "高中政治老师 · 每年中秋问候", tags: [("teacher", "老师"), ("festival", "节日维系")], message: "马老师中秋节快乐！祝您身体健康，阖家幸福。", festival: "中秋节"),
            person("p2", "陈静", note: "大学同学 · 在上海工作", tags: [("friend", "朋友")]),
            person("p3", "李文", note: "", tags: [("teacher", "老师")]),
            person("p4", "赵一鸣", note: "书友会认识，喜欢历史", tags: [("book", "书友")], message: "赵一鸣，周末读书会见！", festival: "周末问候"),
            person("p5", "王思远", note: "前同事 · 现在深圳", tags: [("friend", "朋友"), ("work", "前同事")]),
            person("p6", "刘畅", note: "健身房伙伴", tags: [("sport", "运动")]),
            person("p7", "孙晓", note: "邻居 · 帮忙收过快递", tags: [("life", "生活")]),
            person("p8", "周婷", note: "家长群认识的妈妈", tags: [("family", "家长")], message: "周婷您好，孩子们最近升学准备顺利吗？", festival: "开学季"),
            person("p9", "吴迪", note: "球友", tags: [("sport", "运动")]),
            person("p10", "郑楠", note: "", tags: [("work", "前同事")]),
            person("p11", "冯锐", note: "摄影师 · 拍过团队照", tags: [("friend", "朋友")]),
            person("p12", "何雨", note: "读书会发起人", tags: [("book", "书友")])
        ]
        // Present the wire order scrambled on purpose: the card should display name order.
        roster.reverse()
        let snapshot = RelationshipSnapshot(schemaVersion: 1, sourceApp: "relationship-echo", sourceInstanceId: "ux-render-source", revision: 3, updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 3600)), mode: "manual-chat-only", contacts: roster)
        try RelationshipInboxFiles.write(JSONEncoder().encode(snapshot), directory: bridge, name: RelationshipBridgeLocation.filename)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = try Store(root: root)
        store.guestMode = true
        store.wechatPermission = true
        _ = store.handleRelationshipURL(URL(string: "qqdispatch://relationship-maintenance")!)
        try store.relationshipInbox.saveAlias("马老师", contactID: "p1")

        func render(_ appearance: NSAppearance.Name, _ file: String) throws {
            let view = RelationshipInboxView(inbox: store.relationshipInbox)
                .environmentObject(store)
                .tint(.indigo)
            let size = CGSize(width: 1280, height: 1800)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting; window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)); hosting.layoutSubtreeIfNeeded() }
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RelationshipInboxError("离屏画布创建失败") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw RelationshipInboxError("PNG 生成失败") }
            try png.write(to: output.appendingPathComponent(file))
            window.orderOut(nil)
        }
        try render(.aqua, "inbox-ux-preview-light.png")
        try render(.darkAqua, "inbox-ux-preview-dark.png")
        print("Rendered isolated「来自关系回响」UX previews to \(output.path); synthetic roster, fake state only; not a real WeChat acceptance.")
    }
}
