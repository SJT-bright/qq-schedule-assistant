import SwiftUI
import AppKit
import Darwin

@main
@MainActor
struct RelationshipInboxRender {
    static func main() throws {
        let fm = FileManager.default
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-render-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let bridge = root.appendingPathComponent("bridge")
        try fm.createDirectory(at: bridge, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)
        setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)
        let source = RelationshipSnapshot(schemaVersion: 1, sourceApp: "relationship-echo", sourceInstanceId: "render-source", revision: 1, updatedAt: "2026-09-26T05:00:00.000Z", mode: "manual-chat-only", contacts: [
            RelationshipContact(contactId: "teacher", name: "马广平（政治老师）", userNote: "高中政治老师 · 每年中秋问候", tags: [.init(id: "teacher", name: "老师"), .init(id: "festival", name: "节日维系")], cadenceMode: "festival", message: "马老师中秋节快乐！祝您身体健康，阖家幸福。", groupName: "老师", festival: "中秋节"),
            RelationshipContact(contactId: "friend", name: "林晨", userNote: "大学同学，最近在准备毕业作品", tags: [.init(id: "friend", name: "朋友")], cadenceMode: "both", message: "林晨，中秋节快乐！最近毕业作品准备得怎么样？", groupName: "同学", festival: "中秋节")
        ])
        try RelationshipInboxFiles.write(JSONEncoder().encode(source), directory: bridge, name: RelationshipBridgeLocation.filename)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = try Store(root: root)
        store.guestMode = true
        _ = store.handleRelationshipURL(URL(string: "qqdispatch://relationship-maintenance")!)
        let view = RootView().environmentObject(store).environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!).tint(.indigo)
        let hosting = NSHostingView(rootView: view)
        let size = CGSize(width: 1280, height: 980)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting; window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)); hosting.layoutSubtreeIfNeeded() }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RelationshipInboxError("离屏画布创建失败") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RelationshipInboxError("PNG 生成失败") }
        try png.write(to: output)
        window.orderOut(nil)
        print("Rendered isolated SwiftUI inbox to \(output.path); no chat driver calls; not a real WeChat acceptance.")
    }
}
