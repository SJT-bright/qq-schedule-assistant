import SwiftUI
import AppKit

// 离屏渲染工具：把 RootView 的每个页面渲染成 PNG，用于在没有屏幕录制权限时做 UI 验收。
// 只在 -D RENDER_HARNESS 下编译，不进入正式 App。

@main
@MainActor
struct RenderHarness {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/qqsched-renders"
        let root = URL(fileURLWithPath: outDir).appendingPathComponent("data")
        try? FileManager.default.removeItem(at: root)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir), withIntermediateDirectories: true)

        let store = try! Store(root: root)
        precondition(store.recipients.isEmpty && store.assets.isEmpty && store.settings.savedText.isEmpty,
                     "首次启动必须为空白资料，不能带入历史测试群和素材")

        store.recipients = (1...6).map { Recipient(name: "示例 QQ 群 \($0)", enabled: true, channel: SendChannel.qq) }
        store.settings.savedText = "本次活动通知：欢迎查看今日安排。"
        store.settings.textTemplates = [TextTemplate(text: store.settings.savedText)]
        store.settings.broadcastWorkspaces = nil
        store.settings.prepareWorkspaces(recipientIDs: store.recipients.map(\.id))

        // 追加多渠道示例：两个微信群（一个停用）和一个停用的 QQ 群，让「群与联系人」呈现 QQ / 微信双渠道效果
        store.recipients.append(contentsOf: [
            Recipient(name: "CUPK 微信新生交流群", note: "微信示例群", enabled: true, channel: SendChannel.wechat),
            Recipient(name: "微信二手交易互助群", note: "微信示例群 · 默认停用", enabled: false, channel: SendChannel.wechat),
            Recipient(name: "CUPK 考研交流群（已停用）", note: "QQ 示例群 · 默认停用", enabled: false, channel: SendChannel.qq)
        ])

        // 生成示例图片素材，让素材库与配图区有真实内容
        let samples: [(String, [NSColor], String)] = [
            ("新生群海报.png", [NSColor(calibratedRed: 0.25, green: 0.32, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.96, alpha: 1)], "AIGC 交流群"),
            ("课程表小程序.png", [NSColor(calibratedRed: 0.06, green: 0.66, blue: 0.85, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.60, alpha: 1)], "课表小程序"),
            ("食堂评分.png", [NSColor(calibratedRed: 0.98, green: 0.60, blue: 0.15, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.45, alpha: 1)], "食堂评分"),
            // 复现用户反馈：超长 UUID 文件名把素材卡撑出网格列宽，导致相邻卡片重叠、整卡左移被裁切
            ("e77cafe4ed3-dfc3-4578-9010-8f6d8c86673a.png", [NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1), NSColor(calibratedRed: 0.35, green: 0.38, blue: 0.48, alpha: 1)], "Make imagination tangible"),
            ("二手交易群封面图长标题版本.png", [NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.45, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.62, blue: 0.20, alpha: 1)], "CUPK 二手市集"),
        ]
        var sampleURLs: [URL] = []
        for (name, colors, caption) in samples {
            let url = root.appendingPathComponent(name)
            try? samplePNG(to: url, size: NSSize(width: 720, height: 460), colors: colors, caption: caption)
            sampleURLs.append(url)
        }
        let imported = store.importFiles(sampleURLs)

        // 一份进行中的图文计划
        // 会员演示态：已登录年卡。必须先于 addPlan 设置：会员门禁只挡新计划，
        // 顺序反了示例计划会被挡掉，渲染出来的队列 / 记录页就是空的。
        // RENDER_HARNESS 下 Store 不执行 restoreSession
        let demoProfile = MembershipProfile(account:"demo@local", planLabel:"年卡",
                                            paidUntil: Calendar.current.date(byAdding:.day, value:365, to:Date()),
                                            daysLeft: 365, source:"paid")
        store.settings.licenseProfile = demoProfile
        store.settings.licenseLastValidated = Date()
        store.licenseState = .active(demoProfile)

        let enabled = store.recipients.filter(\.enabled)
        let plan = Plan(name: "克拉玛依新生群 · 图文推广",
                        text: starterText,
                        assetIDs: Array(imported.prefix(2)),
                        recipientIDs: enabled.map(\.id),
                        starts: Date().addingTimeInterval(920),
                        days: 1, times: [], intervalMinutes: 30, mode: "automatic", recipientGaps: nil)
        do { try store.addPlan(plan) } catch { print("RENDER-HARNESS addPlan 失败：\(error)") }

        // 进度视图必须覆盖完整计划：前几群排在昨天，后续群排在今天。
        // 旧的“从今天零点起”过滤会把已完成块漏掉并使进度条归零。
        for index in store.deliveries.indices.prefix(5) {
            store.deliveries[index].scheduled = Date().addingTimeInterval(-86_400 + Double(index * 1_800))
        }

        // 造出几种历史状态，让「发送记录」有内容
        let ids = store.deliveries.map(\.id)
        if ids.count >= 5 {
            store.mutate(ids[0], status: "verified", detail: "QQ 标题准确匹配；消息列表出现新增文案与图片")
            store.mutate(ids[1], status: "verified", detail: "QQ 标题准确匹配；编辑框已清空")
            store.mutate(ids[2], status: "manual", detail: "用户在 QQ 核对后标记已发送")
            store.mutate(ids[3], status: "uncertain", detail: "上次程序在处理期间退出，请核对 QQ 后人工确认，不自动重试")
            store.mutate(ids[4], status: "cancelled", detail: "用户取消，未发送")
            // blocked 样例：验证行内「重新入队」按钮与群名、状态徽章不互相遮挡
            if ids.count >= 6 {
                store.mutate(ids[5], status: "blocked", detail: "步骤：搜索：示例 QQ 群，将进入第一条结果\n前台已切换到其他应用，操作暂停")
            }
        }
        store.running = true
        store.step = "全部待执行任务已启动，等待到时执行"
        try? store.persist()

        let routes: [(String, String)] = [
            ("home", "总览"), ("compose", "新建发送"), ("assets", "素材库"),
            ("recipients", "群与联系人"), ("queue", "发送队列"), ("history", "发送记录"),
            ("member", "会员中心"), ("settings", "设置与备份")
        ]
        let size = CGSize(width: 1280, height: 880)

        for (route, name) in routes {
            store.route = route
            render(AnyView(RootView().environmentObject(store)
                .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
                .tint(.indigo)),
                   to: "\(outDir)/\(route).png", size: size, dark: false)
            print("rendered \(name) -> \(route).png")
        }
        // 「群与联系人」再渲一张微信渠道的发送顺序，验收 QQ / 微信两套隔离排序
        store.route = "recipients"
        store.orderChannel = SendChannel.wechat
        render(AnyView(RootView().environmentObject(store)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .tint(.indigo)),
               to: "\(outDir)/recipients-wechat.png", size: size, dark: false)
        print("rendered 群与联系人 (微信渠道) -> recipients-wechat.png")
        store.orderChannel = SendChannel.qq
        // 设置页比较长，再额外渲一张更高的全图用来验收底部
        store.route = "settings"
        let tall = CGSize(width: 1280, height: 1500)
        render(AnyView(RootView().environmentObject(store)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .tint(.indigo)),
               to: "\(outDir)/settings-tall.png", size: tall, dark: false)
        print("rendered settings (tall)")
        // 深色外观抽查两页
        for route in ["home", "queue"] {
            store.route = route
            render(AnyView(RootView().environmentObject(store)
                .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
                .tint(.indigo)),
                   to: "\(outDir)/\(route)-dark.png", size: size, dark: true)
            print("rendered \(route) dark")
        }
        // 素材库最窄窗口回归：网格卡片不得越出列宽/左右边距（用户反馈的卡片重叠场景）
        store.route = "assets"
        render(AnyView(RootView().environmentObject(store)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .tint(.indigo)),
               to: "\(outDir)/assets-narrow.png", size: CGSize(width: 1080, height: 760), dark: true)
        print("rendered assets narrow dark")
        render(AnyView(ShortcutHelpView()), to: "\(outDir)/shortcuts.png", size: CGSize(width: 600, height: 700), dark: false)
        print("rendered shortcuts")
        // 登录页：另建一个未登录的临时 Store（独立数据目录，不与演示态共享）
        let loginRoot = URL(fileURLWithPath: outDir).appendingPathComponent("data-login")
        try? FileManager.default.removeItem(at: loginRoot)
        try? FileManager.default.createDirectory(at: loginRoot, withIntermediateDirectories: true)
        let loginStore = try! Store(root: loginRoot)
        loginStore.licenseState = .loggedOut
        render(AnyView(RootView().environmentObject(loginStore)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .tint(.indigo)),
               to: "\(outDir)/login.png", size: size, dark: false)
        print("rendered 登录页 -> login.png")
        try? FileManager.default.removeItem(at: loginRoot)
        print("DONE \(outDir)")
        exit(0)
    }

    static func samplePNG(to url: URL, size: NSSize, colors: [NSColor], caption: String) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(colors: colors)?.draw(in: rect, angle: -45)
        for i in 0..<6 {
            NSColor.white.withAlphaComponent(0.10).setFill()
            let r = CGFloat(60 + i * 26)
            NSBezierPath(ovalIn: NSRect(x: size.width - r - CGFloat(i * 26), y: CGFloat(i * 30) - 40, width: r, height: r)).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        caption.draw(at: NSPoint(x: 34, y: size.height / 2 - 20), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) { try data.write(to: url) }
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
        // 离屏没有屏幕刷新驱动，动画帧率很低：多跑几轮 run loop 强制出帧，
        // 否则截图会落在页面渐入动画的中途（整页半透明）。
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
