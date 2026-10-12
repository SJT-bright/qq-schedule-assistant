import SwiftUI
import AppKit

@MainActor final class PresentationDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var verificationEvidence: QQVerificationEvidence?
    var calls: [String] = []
    var behavior: (Delivery) async throws -> (String, String) = { _ in ("blocked", "隔离前置检查") }
    func run(_ job: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; verificationEvidence = nil; calls.append(job.id)
        try Task.checkCancellation()
        return try await behavior(job)
    }
}

@MainActor final class PresentationSpy: SendPresentationEffects {
    var events: [String] = []
    var soundWorks = true
    var windowIssue: String?
    var onSound: () -> Void = {}
    var onMinimize: () -> Void = {}
    func showScheduler() { events.append("show") }
    func playSuccessSound() -> Bool { events.append("sound"); onSound(); return soundWorks }
    func minimizeWindows(channel: String) async -> String? {
        events.append("minimize-\(channel)"); onMinimize()
        try? await Task.sleep(nanoseconds: 30_000_000)
        return windowIssue
    }
}

@main @MainActor struct SendPresentationStoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError("FAIL: \(name)") }
        passed += 1; print("PASS: \(name)"); fflush(stdout)
    }
    static func idle(_ store: Store) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!store.busy, "隔离反馈阶段已结束")
    }
    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-send-presentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root), fake = PresentationDriver(), spy = PresentationSpy()
        let recipient = Recipient(id: "sound-test-recipient", name: "隔离成功反馈群")
        let plan = Plan(id: "sound-test-plan", name: "隔离成功反馈", text: "隔离图文", assetIDs: [],
                        recipientIDs: [recipient.id], starts: Date(), days: 1, times: [], intervalMinutes: 15, mode: "automatic")
        let first = Delivery(id: "sound-first", planID: plan.id, planName: plan.name, recipient: recipient.name,
                             text: "隔离消息，不向 QQ 投递", assets: [], scheduled: Date().addingTimeInterval(3600), mode: "automatic")
        var second = first; second.id = "sound-second"; second.scheduled = Date().addingTimeInterval(7200)
        func disk(_ id: String) -> Delivery? { try? store.db.load("deliveries", as: Delivery.self).first { $0.id == id } }
        func proof(_ id: String) -> QQVerificationEvidence {
            let job = store.deliveries.first { $0.id == id }!, submit = job.submittedAt!
            return QQVerificationEvidence(deliveryID: id, selectedTitle: recipient.name, trigger: "隔离检查点",
                submittedAt: submit, firstObservedAt: submit.addingTimeInterval(1), confirmedAt: submit.addingTimeInterval(2),
                baselineRowIDs: ["a", "b", "tail"], confirmedRowIDs: ["a", "b", "tail", "new-self"],
                messageID: "new-self", textMatches: true, images: 0, requiredImages: 0, draftCleared: true,
                baselineAtLatest: true, confirmedAtLatest: true)
        }
        func prepare(_ records: [Delivery] = []) async throws {
            store.stop(); try await idle(store)
            store.recipients = [recipient]; store.assets = []; store.plans = [plan]
            store.deliveries = records.isEmpty ? [first, second] : records
            store.settings.globalGapMinutes = 15; store.settings.staggerJitter = false
            store.settings.successSoundEnabled = nil; store.settings.minimizeAfterSuccess = nil
            store.settings.restorePreviousApp = false; store.settings.returnToSchedulerAfterSend = false
            store.settings.notifyOnOutcome = false; store.guestMode = true
            store.isolatedDispatchDriver = fake; store.isolatedPresentationEffects = spy; store.error = nil
            fake.calls = []; fake.cancelled = false; fake.verificationEvidence = nil
            spy.events = []; spy.soundWorks = true; spy.windowIssue = nil; spy.onSound = {}; spy.onMinimize = {}
            fake.behavior = { job in try fake.beforeSubmit(); fake.verificationEvidence = proof(job.id); return ("verified", "隔离新消息核验通过") }
            try store.persist()
        }

        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{\"globalGapMinutes\":15,\"savedText\":\"\"}".utf8))
        try check(legacy.successSoundEnabled == nil && legacy.minimizeAfterSuccess == nil,
                  "旧库兼容，成功音与自动收窗的缺省设置开启且不用改写旧资料")
        let wav = DispatchSuccessChime.wav
        try check(String(data: wav.prefix(4), encoding: .ascii) == "RIFF"
                    && String(data: wav[8..<16], encoding: .ascii) == "WAVEfmt "
                    && String(data: wav[36..<40], encoding: .ascii) == "data"
                    && wav.count == 44 + Int(DispatchSuccessChime.duration * Double(DispatchSuccessChime.sampleRate)) * 2,
                  "专用上扬音为独立完整 PCM WAV，时长与数据大小一致")
        try check(NSSound(data: wav) != nil, "AppKit 可解码专用成功音；检查不播放声音")
        if let flag = CommandLine.arguments.firstIndex(of: "--export-chime"), flag + 1 < CommandLine.arguments.count {
            try wav.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }

        try await prepare()
        var soundSawCommitted = false, minimizeSawCommittedAndBusy = false
        spy.onSound = { soundSawCommitted = disk(first.id)?.status == "verified" }
        spy.onMinimize = { minimizeSawCommittedAndBusy = store.busy && disk(first.id)?.qqVerification?.isValid(for: disk(first.id)!) == true }
        store.start(planID: plan.id, expectedDeliveryID: first.id)
        try check(store.busy && spy.events == ["show"], "开始发送先展开本软件，尚未核验不能播放成功音或收窗")
        try await idle(store)
        try check(spy.events == ["show", "sound", "minimize-qq"] && soundSawCommitted && minimizeSawCommittedAndBusy,
                  "新凭据核验成功且落盘后响专用音，再串行收窗，期间驱动仍占 busy")
        store.tick()
        try check(store.runningPlanIDs == [plan.id] && fake.calls == [first.id] && disk(first.id)?.status == "verified"
                    && store.earliestSendDate(store.deliveries[1]) >= disk(first.id)!.submittedAt!.addingTimeInterval(900),
                  "收窗不暂停队列、不重复发送，下一群按本次提交后的15分钟等待")
        store.stop(); store.start(planID: plan.id, expectedDeliveryID: second.id)
        try await idle(store)
        try check(fake.calls == [first.id, second.id]
                    && spy.events == ["show", "sound", "minimize-qq", "show", "sound", "minimize-qq"],
                  "下一次处理重新展开，再次成功后只响一次并收窗")

        for outcome in ["blocked", "uncertain", "draft", "verified-without-proof", "verified-wrong-proof"] {
            try await prepare()
            fake.behavior = { job in
                if outcome != "blocked" && outcome != "draft" { try fake.beforeSubmit() }
                if outcome == "verified-wrong-proof" { var bad = proof(job.id); bad.deliveryID = "old-attempt"; fake.verificationEvidence = bad }
                return (outcome.hasPrefix("verified-") ? "verified" : outcome, "隔离结果 \(outcome)")
            }
            store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
            try check(spy.events == ["show"] && disk(first.id)?.status != "verified",
                      "\(outcome)不冒充成功，不响成功音、不最小化窗口")
        }
        for submitted in [false, true] {
            try await prepare()
            fake.behavior = { _ in if submitted { try fake.beforeSubmit() }; throw AppError("隔离前台中断") }
            store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
            try check(spy.events == ["show"] && disk(first.id)?.status == (submitted ? "uncertain" : "blocked"),
                      "提交\(submitted ? "后" : "前")异常保留窗口与日志，不响成功音")
        }

        try await prepare()
        fake.behavior = { job in
            try fake.beforeSubmit(); fake.verificationEvidence = proof(job.id)
            store.recipients.append(recipient)
            return ("verified", "隔离结果事务失败")
        }
        store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
        try check(!store.running && spy.events == ["show"] && disk(first.id)?.status == "submitted",
                  "成功结果保存失败不响音、不收窗，停止队列并保留已落盘提交")

        try await prepare()
        store.recipients.append(recipient)
        store.start(planID: plan.id, expectedDeliveryID: first.id)
        try check(!store.busy && !store.running && fake.calls.isEmpty && spy.events.isEmpty,
                  "处理前保存失败连展开阶段都不执行")

        try await prepare()
        fake.behavior = { job in
            try fake.beforeSubmit(); fake.verificationEvidence = proof(job.id); store.stop()
            return ("verified", "隔离：完成时用户已暂停")
        }
        store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
        try check(!store.running && spy.events == ["show"], "用户暂停优先，不再响音或收起正在核对的窗口")

        for options in [(false, true), (true, false), (false, false)] {
            try await prepare()
            store.settings.successSoundEnabled = options.0; store.settings.minimizeAfterSuccess = options.1
            store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
            let expected = (options.1 ? ["show"] : []) + (options.0 ? ["sound"] : []) + (options.1 ? ["minimize-qq"] : [])
            try check(spy.events == expected && disk(first.id)?.status == "verified", "成功音与收窗开关独立生效 \(options)")
        }

        try await prepare()
        spy.windowIssue = "隔离：部分 QQ 窗口未能收起"
        store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
        try check(spy.events == ["show", "sound", "minimize-qq"] && disk(first.id)?.status == "verified"
                    && store.step.contains("部分 QQ 窗口") && fake.calls.count == 1,
                  "收窗失败如实说明，已核验的发送保持成功，不补发消息")
        try await prepare()
        spy.soundWorks = false
        store.start(planID: plan.id, expectedDeliveryID: first.id); try await idle(store)
        try check(store.step.contains("成功提示音未能播放") && disk(first.id)?.status == "verified"
                    && spy.events == ["show", "sound", "minimize-qq"], "音频设备失败不阻止收窗，也不重发消息")

        // 在隔离进程自己的真实 NSWindow 上验证与正式 App 相同的最小化 / 展开实现。
        store.stop()
        let windows = (0..<2).map { i -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 180),
                styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
            window.title = i == 0 ? "QQ排程助手" : "隔离第二窗口"
            window.isReleasedWhenClosed = false; window.orderFront(nil)
            return window
        }
        let minimized = await SystemSendPresentation.shared.minimizeSchedulerWindows()
        try check(minimized && windows.allSatisfy(\.isMiniaturized), "原生两个软件窗口均实际最小化，不退出进程")
        SystemSendPresentation.shared.showScheduler()
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(windows.allSatisfy { !$0.isMiniaturized && $0.isVisible }, "下一次展开实际恢复全部原生软件窗口")
        if let screen = NSScreen.screens.first {
            windows[0].setFrameOrigin(NSPoint(x: screen.frame.maxX + 3000, y: screen.frame.maxY + 3000))
            SystemSendPresentation.shared.showScheduler()
            try check(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(windows[0].frame) },
                      "软件窗口遗留在屏幕之外时，展开实际恢复到可见工作区")
        }
        for window in windows { window.close() }
        print("Send Presentation Store: \(passed) checks passed; isolated data and drivers, no real QQ / WeChat sends")
    }
}
