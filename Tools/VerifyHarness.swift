import SwiftUI
import AppKit

// 临时验收 harness：单独渲染新组件 + 像素分析（不进入正式 App，验收后删除）
@main
@MainActor
struct VerifyHarness {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/qq-verify"
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir), withIntermediateDirectories: true)

        // 受控状态：2 done / 1 active / 2 pending / 1 failed
        let segments = [
            ProgressSegment(id: "1", title: "新生交流群", state: .done, detail: "界面已核验"),
            ProgressSegment(id: "2", title: "25级新生群", state: .done, detail: "界面已核验"),
            ProgressSegment(id: "3", title: "自由交易群", state: .active, detail: "正在处理"),
            ProgressSegment(id: "4", title: "二手市场五", state: .pending, detail: "待执行"),
            ProgressSegment(id: "5", title: "二手市场三", state: .pending, detail: "待执行"),
            ProgressSegment(id: "6", title: "二手交易二", state: .failed, detail: "结果待核对")
        ]
        render(AnyView(DispatchProgress3D(segments: segments, doneCount: 2, totalCount: 6)
            .padding(24).frame(width: 860, height: 240)),
               to: "\(outDir)/progress3d.png", size: CGSize(width: 900, height: 260))
        print("rendered progress3d")

        render(AnyView(DispatchProgress3DCompact(segments: segments, doneCount: 2, totalCount: 6)
            .padding(20).frame(width: 500, height: 90)),
               to: "\(outDir)/progress3d-compact.png", size: CGSize(width: 540, height: 130), dark: true)
        print("rendered progress3d-compact")

        // 一体化发送框（空态）
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("data")
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let store = try? Store(root: root) {
            render(AnyView(UnifiedComposerView { _ in true }.environmentObject(store)
                .padding(24).frame(width: 820, height: 420)),
                   to: "\(outDir)/unified.png", size: CGSize(width: 860, height: 460))
            print("rendered unified")
            try? FileManager.default.removeItem(at: root)
        }
        exit(0)
    }

    static func render(_ view: AnyView, to path: String, size: CGSize, dark: Bool = false) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.setFrameSize(size)
        for _ in 0..<40 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.close()
    }
}
