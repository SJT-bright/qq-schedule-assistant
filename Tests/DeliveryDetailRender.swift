import SwiftUI
import AppKit

// 离屏渲染 DeliveryDetailSheet 的三种典型状态，用于验收详情页的分区式布局。
// 只在 -D RENDER_HARNESS 下编译，不进入正式 App。
@main
@MainActor
struct DeliveryDetailRender {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/qqsched-detail"
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("data")
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir), withIntermediateDirectories: true)

        let store = try! Store(root: root)
        let poster = root.appendingPathComponent("c11c2f53-7729-4ce2-acb6-de7f77b88d40.png")
        samplePNG(to: poster)
        let imported = store.importFiles([poster])

        store.recipients = [
            Recipient(name: "CUPK-二手交易群（四）", enabled: true, channel: SendChannel.qq),
            Recipient(name: "CUPK-2025 级新生总群", enabled: true, channel: SendChannel.qq),
            Recipient(name: "CUPK 微信新生交流群", enabled: true, channel: SendChannel.wechat)
        ]
        store.settings.savedText = "毕业季二手书、宿舍好物低价出，坐标昌平。当天可自提，价格私聊，长期有效。"
        store.settings.textTemplates = [TextTemplate(text: store.settings.savedText)]
        store.settings.prepareWorkspaces(recipientIDs: store.recipients.map(\.id))
        let profile = MembershipProfile(account: "demo@local", planLabel: "年卡",
                                        paidUntil: Calendar.current.date(byAdding: .day, value: 365, to: Date()),
                                        daysLeft: 365, source: "paid")
        store.settings.licenseProfile = profile
        store.settings.licenseLastValidated = Date()
        store.licenseState = .active(profile)

        let plan = Plan(name: "二手市集推广", text: store.settings.savedText, assetIDs: imported,
                        recipientIDs: store.recipients.map(\.id), starts: Date().addingTimeInterval(920),
                        days: 1, times: [], intervalMinutes: 30, mode: "automatic", recipientGaps: nil)
        do { try store.addPlan(plan) } catch { print("RENDER-DETAIL addPlan 失败：\(error)") }
        precondition(store.deliveries.count >= 3, "三种状态各需一条任务")

        // 复现用户截图：已暂停、带配图、可重新入队
        store.mutate(store.deliveries[0].id, status: "blocked", detail: """
        手动重新入队；上次暂停：步骤：正在准备「c11c2f53-7729-4ce2-acb6-de7f77b88d40.png」，尚未粘贴，也尚未发送
        前台已切换到 Electron，操作暂停；不是 QQ 登录失效
        """)
        // 待执行：应出现「现在自动发送此条」与「取消此条」
        store.deliveries[1].detail = "等待执行，计划于今天 15:20 发送。上一群完成后按 30 分钟间隔顺延。"
        // QQ 结果待核对：人工重发、取消和标记已发送均可见。
        store.deliveries[2].channel = SendChannel.qq
        store.mutate(store.deliveries[2].id, status: "uncertain", detail: """
        步骤：已按 Return 提交，未能读取 QQ 消息列表确认新增气泡
        前台已切回排程助手；请核对 QQ 后人工确认，不自动重试
        """)
        try? store.persist()

        if CommandLine.arguments.contains("--interactive") {
            let job = store.deliveries[2]
            let view = DeliveryDetailSheet(original: job)
                .background(Color(nsColor: .windowBackgroundColor)).environmentObject(store)
                .environment(\.timeZone, Scheduling.calendar.timeZone).tint(.indigo)
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 720, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "QQ重发隔离验收（不会发送）"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view); window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); app.run(); exit(0)
        }

        let cases: [(Int, String)] = [(0, "blocked"), (1, "queued"), (2, "uncertain")]
        for (index, name) in cases {
            let job = store.deliveries[index]
            // 系统 sheet 自带窗口材质，离屏 NSHostingView 没有：补一层自适应底色，
            // 否则深色下白字叠在查看器的白底上，看着像整页失配。
            func sheet(_ job: Delivery) -> AnyView {
                AnyView(DeliveryDetailSheet(original: job)
                    .frame(width: 720, height: 600)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environmentObject(store)
                    .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
                    .tint(.indigo))
            }
            render(sheet(job), to: "\(outDir)/detail-\(name).png", size: CGSize(width: 720, height: 600), dark: false)
            render(sheet(job), to: "\(outDir)/detail-\(name)-dark.png", size: CGSize(width: 720, height: 600), dark: true)
            print("rendered detail-\(name)")
        }
        print("DONE \(outDir)")
        exit(0)
    }

    static func samplePNG(to url: URL) {
        let size = NSSize(width: 720, height: 460)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.20, alpha: 1),
                            NSColor(calibratedRed: 0.42, green: 0.24, blue: 0.78, alpha: 1)])?.draw(in: rect, angle: -45)
        ("毕业季 · 二手市集" as NSString).draw(at: NSPoint(x: 40, y: size.height / 2 - 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    static func render(_ view: AnyView, to path: String, size: CGSize, dark: Bool) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            hosting.layoutSubtreeIfNeeded()
        }
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        window.orderOut(nil)
    }
}
