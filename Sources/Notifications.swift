import UserNotifications
import AppKit
import ApplicationServices

/// 本版本只在页面内提示发送结果。清理旧版遗留的本软件预告，不申请通知权限。
@MainActor enum QuietDispatchNotifications {
    static func clearPreviousNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// 专用上扬音型，独立于点击 Tink / Bottle 和系统通知声。
enum DispatchSuccessChime {
    static let sampleRate = 44_100
    static let duration = 1.12
    static let wav: Data = {
        let count = Int(Double(sampleRate) * duration)
        let notes: [(start: Double, length: Double, hz: Double)] = [
            (0, 0.18, 659.255), (0.20, 0.18, 880), (0.40, 0.18, 1174.659),
            (0.64, 0.46, 1318.510), (0.64, 0.46, 1760)
        ]
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var sample = 0.0
            for note in notes {
                let local = t - note.start
                guard local >= 0, local < note.length else { continue }
                let envelope = min(1, local / 0.012) * pow(1 - local / note.length, 1.5)
                sample += 0.18 * envelope * (sin(2 * .pi * note.hz * local) + 0.12 * sin(4 * .pi * note.hz * local))
            }
            appendLE(Int16(max(-1, min(1, sample)) * Double(Int16.max)), to: &pcm)
        }
        var output = Data("RIFF".utf8)
        appendLE(UInt32(36 + pcm.count), to: &output)
        output.append(Data("WAVEfmt ".utf8)); appendLE(UInt32(16), to: &output)
        appendLE(UInt16(1), to: &output); appendLE(UInt16(1), to: &output)
        appendLE(UInt32(sampleRate), to: &output); appendLE(UInt32(sampleRate * 2), to: &output)
        appendLE(UInt16(2), to: &output); appendLE(UInt16(16), to: &output)
        output.append(Data("data".utf8)); appendLE(UInt32(pcm.count), to: &output); output.append(pcm)
        return output
    }()
    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

@MainActor protocol SendPresentationEffects: AnyObject {
    func showScheduler()
    func playSuccessSound() -> Bool
    func minimizeWindows(channel: String) async -> String?
    func mayMinimizeAfterFailure(channel: String) -> Bool
}

extension SendPresentationEffects {
    func mayMinimizeAfterFailure(channel: String) -> Bool { false }
}

/// 渲染 / 隔离 Store 检查默认只走空实现，不播放音效，不触碰正式窗口。
@MainActor final class SilentSendPresentation: SendPresentationEffects {
    static let shared = SilentSendPresentation()
    func showScheduler() {}
    func playSuccessSound() -> Bool { true }
    func minimizeWindows(channel: String) async -> String? { nil }
}

@MainActor final class SystemSendPresentation: SendPresentationEffects {
    static let shared = SystemSendPresentation()
    private var sound: NSSound?

    func mayMinimizeAfterFailure(channel: String) -> Bool {
        guard !QQDriver.locked, let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return front == Bundle.main.bundleIdentifier || front == FocusRestore.targetBundleID(channel: channel)
    }

    func showScheduler() {
        NSApp.unhideWithoutActivation()
        for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
        let visible = NSScreen.screens.map(\.visibleFrame)
        for window in NSApp.windows where window.canBecomeMain && window.styleMask.contains(.titled) && !window.styleMask.contains(.fullScreen) {
            if let fitted = WindowRestorePlacement.fitted(window.frame, within: visible), fitted != window.frame {
                window.setFrame(fitted, display: true)
            }
        }
        NSApp.windows.first(where: { $0.title == "QQ排程助手" && $0.canBecomeMain })?.orderFront(nil)
    }

    func playSuccessSound() -> Bool {
        if sound == nil { sound = NSSound(data: DispatchSuccessChime.wav) }
        guard let sound else { return false }
        sound.volume = 0.75
        // 各群提交有分钟级间隔；显式试听与成功音重叠时重播完整专用音型。
        if sound.isPlaying { sound.stop() }
        return sound.play()
    }

    func minimizeWindows(channel: String) async -> String? {
        guard !Task.isCancelled, !QQDriver.locked else { return "窗口收起已停止" }
        let bundle = channel == SendChannel.wechat ? FocusRestore.weChatBundleID : FocusRestore.qqBundleID
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        var issues: [String] = []
        if targets.isEmpty { issues.append("未找到\(SendChannel.displayName(channel))窗口") }
        for target in targets {
            let report = await ChatWindowPresentation.setMinimized(true, app: target)
            if !report.complete { issues.append("部分\(SendChannel.displayName(channel))窗口未能收起") }
        }
        guard !Task.isCancelled else { return "窗口收起已停止" }
        if !(await minimizeSchedulerWindows()) { issues.append("部分排程助手窗口未能收起") }
        return issues.isEmpty ? nil : Array(Set(issues)).sorted().joined(separator: "；")
    }

    /// 只操作当前进程的 NSWindow；隔离原生窗口检查也复用此实现。
    func minimizeSchedulerWindows() async -> Bool {
        let own = NSApp.windows.filter {
            ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.miniaturizable) && $0.parent == nil
        }
        for window in own where !window.isMiniaturized { window.miniaturize(nil) }
        for _ in 0..<12 {
            if own.allSatisfy(\.isMiniaturized) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return own.allSatisfy(\.isMiniaturized)
    }
}
