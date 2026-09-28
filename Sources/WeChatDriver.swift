import AppKit
import ApplicationServices
import Foundation

// 微信（macOS 4.x）自动发送驱动，安全架构与 QQDriver 完全同构：
// - 辅助功能权限检查（AXIsProcessTrusted）与锁屏检查（CGSessionCopyCurrentDictionary）
// - check()：每步操作前校验「未被取消 + 未锁屏 + 微信仍是前台应用」
// - 剪贴板备份与恢复（captureClipboard / restoreClipboard + changeCount 版本校验）
// - 输入统一走剪贴板粘贴（写 .string / .tiff 后 Cmd+V，key 9 + .maskCommand）
// - 发送前 beforeSubmit() 唯一检查点；检查点通过后的中断一律返回 uncertain，绝不误标 blocked
// - 发送后核验：编辑器草稿清空 + 会话标题唯一匹配；无法确认时返回 uncertain，绝不盲目重发
// 微信 4.x 控件树与 QQ 不同，这里全部防御式探测（角色 + 关键字 + 几何位置），不照抄 QQ 的节点名称。
@MainActor
final class WeChatDriver {
    var cancelled = false
    var onStep: (String) -> Void = { _ in }
    var beforeSubmit: () throws -> Void = {}
    private var pid: pid_t = 0
    private var clipboard: [[NSPasteboard.PasteboardType: Data]] = []
    private var clipboardVersion: Int?
    private var submitted = false
    private static let bundleID = "com.tencent.xinWeChat"

    static var trusted: Bool { AXIsProcessTrusted() }
    static var locked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSessionOnConsoleKey"] as? Bool == false
    }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    private static func appURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let fallbacks = ["/Applications/WeChat.app", NSString("~/Applications/WeChat.app").expandingTildeInPath]
        return fallbacks.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - AX 基础工具（与 QQDriver 同款实现）
    private func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, attr as CFString, &v) != .success { return nil }; return v }
    private func string(_ e: AXUIElement, _ attr: String) -> String { value(e, attr) as? String ?? "" }
    private func label(_ e: AXUIElement) -> String {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] { let s = string(e, a); if !s.isEmpty { return s } }; return ""
    }
    private func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) }
    private func subrole(_ e: AXUIElement) -> String { string(e, kAXSubroleAttribute) }
    private func children(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func nodes(_ root: AXUIElement, limit: Int = 4500) -> [AXUIElement] {
        var queue = [root]; var i = 0
        while i < queue.count && queue.count < limit { let c = children(queue[i]); queue.append(contentsOf: c.prefix(limit - queue.count)); i += 1 }
        return queue
    }
    private func appElement() -> AXUIElement { AXUIElementCreateApplication(pid) }
    private func frameOf(_ e: AXUIElement) -> CGRect? {
        guard let pv = value(e, kAXPositionAttribute), let sv = value(e, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(unsafeBitCast(pv, to: AXValue.self), .cgPoint, &p)
        AXValueGetValue(unsafeBitCast(sv, to: AXValue.self), .cgSize, &s)
        guard s.width >= 0, s.height >= 0 else { return nil }
        return CGRect(origin: p, size: s)
    }
    private func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" } }
    private func check() throws {
        if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw AppError("前台已切换到 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用")，操作暂停；不是微信登录失效") }
    }
    private func wait(_ seconds: Double = 0.45) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); try check() }
    private func yieldOwnWindows() {
        for window in NSApp.windows where window.isVisible {
            window.level = .normal
            window.orderBack(nil)
        }
    }
    /// 只有本程序自己在前台时才把微信唤回。用户切到其他应用仍停止。不能先调用 check()，否则唤起代码永远走不到。
    private func activateForClick() async throws {
        if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == pid { yieldOwnWindows(); try check(); return }
        guard front == ProcessInfo.processInfo.processIdentifier else { try check(); return }
        yieldOwnWindows()
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        var deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
            if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, let url = Self.appURL() {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            if let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) { pid = app.processIdentifier }
            deadline = Date().addingTimeInterval(4)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
                if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        try check()
    }
    private func coveringAppName(_ point: CGPoint) -> String? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let windows: [ClickCover.Window] = rows.compactMap { row in
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            let origin = CGPoint(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0, y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0)
            let size = CGSize(width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0, height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
            let app = NSRunningApplication(processIdentifier: owner)
            let name = app?.localizedName ?? (row[kCGWindowOwnerName as String] as? String ?? "")
            return ClickCover.Window(ownerPID: owner, layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1, bounds: CGRect(origin: origin, size: size), regular: app?.activationPolicy == .regular, name: name)
        }
        return ClickCover.blocker(at: point, windows: windows, targetPID: pid, selfPID: ProcessInfo.processInfo.processIdentifier, selfName: "QQ排程助手")
    }
    private func until(_ message: String, seconds: Double = 6, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            try check()
            if try condition() { return }
            try await wait(0.15)
        } while Date() < deadline
        throw AppError(message)
    }
    private func key(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try check()
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
    }
    private func click(_ e: AXUIElement, physical: Bool = false) throws {
        try check()
        if !physical, AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
        guard let f = frameOf(e), f.width > 1, f.height > 1 else { throw AppError("微信控件不可点击：\(label(e))") }
        let point = CGPoint(x: f.midX, y: f.midY)
        if let blocker = coveringAppName(point) { throw AppError("「\(blocker)」的窗口挡住了微信的「\(label(e))」，未发送点击，避免误触其他应用；请把微信窗口置于最前后重试") }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw AppError("无法生成点击事件，未点击") }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    private func captureClipboard() {
        clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in var result: [NSPasteboard.PasteboardType: Data] = [:]; for t in item.types { if let d = item.data(forType: t) { result[t] = d } }; return result }
    }
    private func restoreClipboard() {
        let pb = NSPasteboard.general
        guard let clipboardVersion, pb.changeCount == clipboardVersion else { return }
        pb.clearContents()
        let items = clipboard.map { saved -> NSPasteboardItem in let item = NSPasteboardItem(); for (t, d) in saved { item.setData(d, forType: t) }; return item }
        if !items.isEmpty { pb.writeObjects(items) }
    }
    private func paste(_ text: String) throws {
        try check(); let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string); clipboardVersion = pb.changeCount; try key(9, flags: .maskCommand)
    }
    private func focusedWindow() throws -> AXUIElement {
        guard let v = value(appElement(), kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { throw AppError("没有找到微信活动窗口，请打开微信主窗口") }
        return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func focusedElement() -> AXUIElement? {
        guard let v = value(appElement(), kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func focus(_ element: AXUIElement) async throws {
        try await activateForClick()
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let focused = focusedElement(), CFEqual(focused, element) { return }
        try await activateForClick()
        try click(element, physical: true)
        try await until("输入框未获得焦点，未输入内容", seconds: 2) { if let focused = self.focusedElement() { return CFEqual(focused, element) }; return false }
    }

    // MARK: - 微信控件探测（防御式，不依赖 QQ 的节点名称）
    // 搜索框：TextField 角色（或 subrole AXSearchField），title/描述/值/占位符含「搜索」或 Search
    private func isSearchField(_ e: AXUIElement) -> Bool {
        guard role(e) == kAXTextFieldRole || subrole(e) == "AXSearchField" else { return false }
        let parts = [string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute), string(e, kAXValueAttribute), string(e, kAXPlaceholderValueAttribute)]
        return parts.contains { $0.range(of: "搜索") != nil || $0.range(of: "Search", options: .caseInsensitive) != nil }
    }
    private func searchField(in window: AXUIElement) -> AXUIElement? {
        let fields = nodes(window).filter { isSearchField($0) }
        guard fields.count > 1 else { return fields.first }
        // 多个候选时取最靠顶部、最靠左的（全局搜索固定在左侧列表面板顶部）
        let ranked = fields.compactMap { e -> (AXUIElement, CGRect)? in frameOf(e).map { (e, $0) } }
        return ranked.min { a, b in
            if abs(a.1.minY - b.1.minY) > 4 { return a.1.minY < b.1.minY }
            return a.1.minX < b.1.minX
        }?.0
    }
    // 聊天区左边界：优先用搜索框右缘推算，避免把会话列表/搜索下拉当成聊天区
    private func chatMinX(_ ns: [AXUIElement], _ wf: CGRect) -> CGFloat {
        if let sf = ns.first(where: { isSearchField($0) }), let sff = frameOf(sf) { return max(wf.width * 0.3, sff.maxX - wf.minX + 24) }
        return wf.width * 0.3
    }
    // 会话标题核验：窗口标题精确相等，或聊天区顶部窄带内出现与目标完全一致的标题文本（几何过滤排除会话列表/搜索下拉）
    private func headerMatches(_ w: AXUIElement, _ name: String) -> Bool {
        let target = normalized(name)
        guard !target.isEmpty else { return false }
        if normalized(string(w, kAXTitleAttribute)) == target { return true }
        guard let wf = frameOf(w) else { return false }
        let ns = nodes(w)
        let minX = chatMinX(ns, wf)
        let band = min(100, max(56, wf.height * 0.08))
        for n in ns where role(n) == kAXStaticTextRole || role(n) == kAXButtonRole {
            guard normalized(label(n)) == target, let f = frameOf(n) else { continue }
            let cy = f.midY - wf.minY, cx = f.midX - wf.minX
            if cy >= 0, cy <= band, cx >= minX { return true }
        }
        return false
    }
    // 独立弹出的聊天窗口：窗口标题即会话名
    private func matchingWindow(_ name: String) -> AXUIElement? {
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { normalized(string($0, kAXTitleAttribute)) == normalized(name) }
    }
    private func mainWindow() throws -> AXUIElement {
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let w = windows.first(where: { searchField(in: $0) != nil }) { return w }
        throw AppError("没有找到包含搜索框的微信主窗口。请打开微信主窗口；这不是登录权限问题")
    }
    // 搜索结果只认「整名精确相等」的静态文本：重叠节点去重，主窗口内排除聊天区正文，绝不发错人
    private func searchCandidates(_ name: String) -> [AXUIElement] {
        let target = normalized(name)
        guard !target.isEmpty else { return [] }
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        var out: [AXUIElement] = []
        for w in windows {
            guard let wf = frameOf(w) else { continue }
            let ns = nodes(w)
            let sf = ns.first(where: { isSearchField($0) })
            var frames: [CGRect] = []
            for n in ns where role(n) == kAXStaticTextRole {
                guard normalized(label(n)) == target, let f = frameOf(n) else { continue }
                if frames.contains(where: { $0.intersects(f) }) { continue }
                if let sf = sf, let sff = frameOf(sf), f.midX - wf.minX > sff.maxX - wf.minX + 40 { continue }
                frames.append(f); out.append(n)
            }
        }
        return out
    }
    private func uniqueCandidate(_ name: String) -> AXUIElement? {
        let c = searchCandidates(name)
        return c.count == 1 ? c[0] : nil
    }
    // 消息输入框：优先 TextArea；个别的版本若暴露为 TextField，只认聊天区下半部分（避免误抓顶部搜索框）
    private func editor(in window: AXUIElement) throws -> AXUIElement {
        let ns = nodes(window)
        var pool = ns.filter { role($0) == kAXTextAreaRole }
        if pool.isEmpty, let wf = frameOf(window) {
            pool = ns.filter { e in
                guard role(e) == kAXTextFieldRole, let f = frameOf(e) else { return false }
                return f.midY - wf.minY > wf.height * 0.55 && f.midX - wf.minX >= chatMinX(ns, wf)
            }
        }
        if pool.count > 1, let wf = frameOf(window) {
            let ranked = pool.compactMap { e -> (AXUIElement, CGRect)? in frameOf(e).map { (e, $0) } }
                .filter { $0.1.midX - wf.minX >= chatMinX(ns, wf) }
            if let best = ranked.max(by: { $0.1.midY < $1.1.midY }) { return best.0 }
        }
        guard pool.count == 1 else { throw AppError("未能唯一定位微信消息输入框，请关闭微信的其他弹窗后重试") }
        return pool[0]
    }

    // MARK: - 草稿与核验
    private func composerIsEmpty(_ e: AXUIElement) -> Bool {
        return ComposerContent.isEmpty(string(e, kAXValueAttribute), descendants: nodes(e).dropFirst().map { child in
            ComposerNode(role: role(child), value: string(child, kAXValueAttribute), title: string(child, kAXTitleAttribute), description: string(child, kAXDescriptionAttribute))
        })
    }
    private func imageCount(_ input: AXUIElement) -> Int {
        ComposerContent.attachmentCount(string(input, kAXValueAttribute), imageNodes: nodes(input).filter { role($0) == kAXImageRole }.count)
    }
    private func ensureEmpty(_ e: AXUIElement) throws {
        guard composerIsEmpty(e) else {
            let codes = string(e, kAXValueAttribute).unicodeScalars.prefix(12).map { String($0.value, radix: 16) }.joined(separator: ",")
            let structure = children(e).prefix(8).map { role($0) + ":" + String(string($0, kAXValueAttribute).count) }.joined(separator: ",")
            throw AppError("微信输入框检测到草稿或附件，已保留；请先手动处理。诊断：value=\(codes)，children=\(structure)")
        }
    }
    private func ensureConversation(_ name: String) throws -> AXUIElement {
        try check()
        let w = try focusedWindow()
        guard headerMatches(w, name) else { throw AppError("当前会话标题与目标不一致：\(name)。已停止，不发送") }
        return w
    }
    // 尽力而为的发送后旁证：聊天区出现与文案一致的静态文本（长文案放宽为包含匹配）
    private func messageEcho(_ w: AXUIElement, _ text: String) -> Bool {
        let target = normalized(text)
        guard !target.isEmpty, let wf = frameOf(w) else { return false }
        let ns = nodes(w)
        let minX = chatMinX(ns, wf)
        return ns.contains { n in
            guard role(n) == kAXStaticTextRole, let f = frameOf(n), f.midX - wf.minX >= minX else { return false }
            let line = normalized(label(n))
            return line == target || (target.count >= 16 && line.contains(target))
        }
    }

    // MARK: - 会话定位
    private func locate(_ recipient: String) async throws -> AXUIElement {
        onStep("定位会话：\(recipient)")
        if let w = try? focusedWindow(), headerMatches(w, recipient) {
            onStep("已在目标会话，无需搜索")
            return try ensureConversation(recipient)
        }
        if let existing = matchingWindow(recipient) {
            onStep("切换到已打开的聊天窗口：\(recipient)")
            _ = AXUIElementPerformAction(existing, kAXRaiseAction as CFString)
            try await until("聊天窗口未获得焦点：\(recipient)", seconds: 3) { CFEqual(try self.focusedWindow(), existing) }
            return try await enterConversation(recipient)
        }
        var window = try focusedWindow()
        if searchField(in: window) == nil {
            let main = try mainWindow()
            onStep("从独立聊天窗口回到微信主窗口")
            _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
            try await until("微信主窗口未获得焦点，未输入搜索内容", seconds: 3) { CFEqual(try self.focusedWindow(), main) }
            window = try focusedWindow()
        }
        return try await searchAndEnter(recipient, in: window)
    }
    private func searchAndEnter(_ recipient: String, in initial: AXUIElement) async throws -> AXUIElement {
        guard let search = searchField(in: initial) else {
            throw AppError("微信控件树已加载，但未识别到搜索框（\(nodes(initial).count) 个控件）。请关闭微信弹窗或回到主窗口；这不是登录权限问题")
        }
        onStep("聚焦搜索框：\(recipient)")
        try await focus(search)
        // 写入群名：优先 AX 设值；失败或未生效则全选后剪贴板粘贴
        let set = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, recipient as CFString)
        if set != .success || normalized(string(search, kAXValueAttribute)) != normalized(recipient) {
            try key(0, flags: .maskCommand)
            try paste(recipient)
        }
        try await until("搜索文字未写入微信搜索框，未点击任何结果", seconds: 3) {
            guard let f = self.searchField(in: try self.focusedWindow()) else { return false }
            return self.normalized(self.string(f, kAXValueAttribute)) == self.normalized(recipient)
        }
        onStep("等待「\(recipient)」的完整搜索结果")
        try await until("未出现完整名称的搜索结果：\(recipient)。未发送、未继续", seconds: 8) {
            !self.searchCandidates(recipient).isEmpty
        }
        guard let only = uniqueCandidate(recipient) else {
            throw AppError("搜索结果无法唯一匹配「\(recipient)」（可能存在同名联系人或群聊）。已停止，未选择任何会话、未发送。请手动进入该会话，或修改群名后重试")
        }
        onStep("找到唯一匹配，正在进入会话：\(recipient)")
        try await activateForClick()
        try click(only)
        return try await enterConversation(recipient)
    }
    private func enterConversation(_ name: String) async throws -> AXUIElement {
        var clicks = 0
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try check()
            if (try? ensureConversation(name)) != nil { return try ensureConversation(name) }
            if clicks < 3, let only = uniqueCandidate(name) {
                clicks += 1
                try await activateForClick()
                // AXPress can report success without opening the chat, so retries use a real pointer click.
                do { try click(only, physical: true) } catch {
                    let message = (error as? AppError)?.message ?? error.localizedDescription
                    if message.contains("挡住") || message.contains("前台已切换") || message.contains("锁屏") || message.contains("已停止") || message.contains("无法生成点击") { throw error }
                }
            } else if let existing = matchingWindow(name) {
                _ = AXUIElementPerformAction(existing, kAXRaiseAction as CFString)
            }
            try await wait(0.15)
        }
        throw AppError("尚未进入准确会话：\(name)。未发送消息")
    }

    // MARK: - 公开接口
    func diagnostic() -> String {
        guard Self.trusted else { return "辅助功能权限：未授权。请在设置中允许本软件控制微信。" }
        guard !Self.locked else { return "Mac 已锁屏" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return "微信未运行，请手动打开并登录" }
        pid = app.processIdentifier
        AXUIElementSetMessagingTimeout(appElement(), 2)
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        let summaries = windows.map { window -> String in
            let controls = nodes(window)
            let found = controls.contains { isSearchField($0) }
            return "窗口：\(label(window))；可读取控件：\(controls.count)；搜索框：\(found ? "已找到" : "未找到")"
        }
        return "辅助功能权限：已授权\n微信进程：\(pid)\n窗口数：\(windows.count)\n" + summaries.joined(separator: "\n") + "\n控件数为 0 通常表示微信未登录或主窗口未打开。检查为只读操作，不会发送消息，也不读取密码。"
    }
    func openWeChat() async throws {
        cancelled = false
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        onStep("正在打开微信")
        guard let url = Self.appURL() else { throw AppError("未找到已安装的微信。请把微信安装到 /Applications 并登录后重试") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        // Launch Services 会激活已运行的微信；单独 activate() 在新版 macOS 上可能被拒绝
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        pid = app.processIdentifier
        app.unhide()
        let deadline = Date().addingTimeInterval(5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
            try Task.checkCancellation()
            if cancelled { throw AppError("已停止") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check()
        AXUIElementSetMessagingTimeout(appElement(), 2)
        onStep("等待微信控件树就绪")
        try await until("微信进程已启动，但界面控件尚未就绪；若显示登录二维码请先扫码登录，并保持微信主窗口打开", seconds: 10) {
            guard let window = try? self.focusedWindow() else { return false }
            return self.nodes(window).contains { self.role($0) == kAXTextFieldRole || self.role($0) == kAXTextAreaRole }
        }
    }
    func probe(_ recipient: String) async throws -> String {
        guard Self.trusted else { throw AppError("请先在系统设置中授予 QQ排程助手辅助功能权限，再试跑") }
        guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("请先填写群名") }
        try await openWeChat()
        captureClipboard(); defer { restoreClipboard() }
        let window = try await locate(recipient)
        _ = try editor(in: window)
        return "试跑通过：已打开微信、准确定位「\(recipient)」，找到消息输入框。未填写草稿、未发送消息。"
    }

    // MARK: - 填稿与发送
    private func attachImages(_ delivery: Delivery, root: URL, recipient: String) async throws -> Bool {
        var confirmed = true
        for asset in delivery.assets {
            onStep("正在加入附件：\(asset.name)")
            let tiff = try ImageAttachment.tiff(at: root.appendingPathComponent(asset.relativePath))
            let w = try ensureConversation(recipient)
            let input = try editor(in: w)
            let baseline = imageCount(input)
            try await focus(input)
            try key(119, flags: .maskCommand)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setData(tiff, forType: .tiff); clipboardVersion = pb.changeCount
            try key(9, flags: .maskCommand)
            var reached = false
            for _ in 0..<20 {
                try await wait(0.3)
                if let cw = try? ensureConversation(recipient), let ce = try? editor(in: cw), imageCount(ce) > baseline { reached = true; break }
            }
            if !reached {
                // AX 读不到图片计数时不硬报错，降级为发送后人工确认
                confirmed = false
                onStep("无法通过辅助功能确认图片「\(asset.name)」已进入草稿，将继续填稿；发送结果需人工确认")
            }
        }
        return confirmed
    }
    private func awaitDraftCleared(recipient: String) async -> Bool {
        for _ in 0..<9 {
            try? await wait(0.65)
            if let w = try? ensureConversation(recipient), let e = try? editor(in: w), composerIsEmpty(e) { return true }
        }
        return false
    }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; submitted = false
        guard ["draft", "automatic"].contains(delivery.mode) else { throw AppError("未知发送模式，未执行") }
        guard delivery.assets.allSatisfy(\.isImage) else { throw AppError("微信驱动暂只支持图片素材；普通文件请在 QQ 渠道发送或手动添加，未执行") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        guard !delivery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !delivery.assets.isEmpty else { throw AppError("文案和附件不能都为空，未执行") }
        for a in delivery.assets {
            let u = root.appendingPathComponent(a.relativePath)
            guard a.relativePath.hasPrefix("assets/"), u.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/assets/"), FileManager.default.fileExists(atPath: u.path), try Database.digest(u) == a.sha256 else { throw AppError("素材缺失、路径无效或已改变：\(a.name)") }
            _ = try ImageAttachment.tiff(at: u)
        }
        try await openWeChat()
        captureClipboard(); defer { restoreClipboard() }
        var w = try await locate(delivery.recipient)
        try ensureEmpty(try editor(in: w))
        var imagesConfirmed = delivery.assets.isEmpty
        if !delivery.assets.isEmpty { imagesConfirmed = try await attachImages(delivery, root: root, recipient: delivery.recipient) }
        w = try ensureConversation(delivery.recipient)
        let input = try editor(in: w)
        try await focus(input); try key(119, flags: .maskCommand)
        if !delivery.text.isEmpty { try paste((delivery.assets.isEmpty ? "" : "\n") + delivery.text); try await wait(0.5) }
        w = try ensureConversation(delivery.recipient)
        guard normalized(string(try editor(in: w), kAXValueAttribute)) == normalized(delivery.text) else { throw AppError("草稿文字与计划不一致。请检查微信草稿，未发送") }
        if !delivery.assets.isEmpty {
            let counted = imageCount(try editor(in: w))
            let expected = delivery.assets.count
            if counted == expected { imagesConfirmed = true }
            else if counted > 0 { throw AppError("草稿图片数量与计划不一致（应为 \(expected) 张，读到 \(counted) 张），未发送") }
            // counted == 0：辅助功能读不到图片计数，保持降级，不硬报错
        }
        if delivery.mode == "draft" {
            var detail = "已填入正确会话和附件。请在微信手动发送，然后在记录中确认；队列已暂停"
            if !imagesConfirmed { detail += "。注意：图片未能通过辅助功能核验，请先人工确认图片已在输入框中" }
            return ("draft", detail)
        }
        onStep("收件人和草稿已核对，准备提交")
        try beforeSubmit() // 发送前唯一检查点；此处抛错 = 前置失败（未发送）
        submitted = true
        do {
            _ = try ensureConversation(delivery.recipient)
            guard let focused = focusedElement(), CFEqual(focused, try editor(in: focusedWindow())) else {
                return ("uncertain", "发送前输入焦点改变，未按下发送键。请检查微信草稿；为安全起见本次记为待核对，不自动重发")
            }
            try key(36)
            onStep("已按 Return，等待微信发送")
            if !(await awaitDraftCleared(recipient: delivery.recipient)) {
                onStep("Return 后草稿未清空，改用 Command+Return 重试")
                _ = try ensureConversation(delivery.recipient)
                try key(36, flags: .maskCommand)
                _ = await awaitDraftCleared(recipient: delivery.recipient)
            }
            guard let fw = try? ensureConversation(delivery.recipient), let fe = try? editor(in: fw) else {
                return ("uncertain", "发送指令已发出，但无法确认会话状态。请到微信人工核对是否已发出；不会自动重发")
            }
            if composerIsEmpty(fe) {
                if !imagesConfirmed {
                    return ("uncertain", "草稿已清空，但图片未能通过辅助功能核验，无法确认图片是否已发出。请到微信人工核对；不会自动重发。若微信设置为 Enter 换行 / Cmd+Enter 发送，请到微信设置确认")
                }
                let echo = delivery.text.isEmpty || messageEcho(fw, delivery.text)
                return ("verified", "\(Date().formatted()) · 会话标题匹配；草稿已清空" + (echo ? "；消息区已看到发送内容" : "；消息区内容未能读取，以草稿清空与会话标题核验") + "。仅为客户端可见核验，不是服务器送达回执")
            }
            return ("uncertain", "已尝试 Return 与 Command+Return，草稿仍未清空。请到微信查看是否已发出，切勿手动重复发送；不会自动重发。若微信设置为 Enter 换行 / Cmd+Enter 发送，请到微信设置确认")
        } catch {
            return ("uncertain", "发送流程已触发但中途停止（\(error.localizedDescription)）。请到微信人工核对是否已发出；不会自动重发")
        }
    }
}

// Narrow manual-inbox adapter. probe only locates and inspects the editor; existing drafts are allowed.
extension WeChatDriver: RelationshipChatNavigator {
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        _ = try await probe(fullDisplayName)
        return "已打开「\(fullDisplayName)」的同名微信会话；请核对联系人后手动发送。未填写草稿，未记录维系完成。"
    }
}
