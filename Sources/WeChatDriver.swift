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
    /// 本条任务是否已经发出过唯一的一条发送指令；发送路径用它挡住重复触发。
    private var sendCommandIssued = false
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
    /// 按键用命名常量，与 QQDriver 同一口径（Carbon Events.h：0=A、9=V、36=Return、119=End）。
    private enum Key {
        static let selectAll: CGKeyCode = 0
        static let paste: CGKeyCode = 9
        static let returnKey: CGKeyCode = 36
        /// Cmd+End：把插入点移到正文末尾，保证粘贴是追加而不是替换选区。
        static let moveToTextEnd: CGKeyCode = 119
    }
    /// 最近一次关键读取失败的辅助功能错误码，只用于把“读不到”如实写进记录。
    private var lastAXErrorCode: Int32 = 0
    private func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, attr as CFString, &v) != .success { return nil }; return v }
    private func string(_ e: AXUIElement, _ attr: String) -> String { value(e, attr) as? String ?? "" }
    /// 关键判定用的读取：把「读不到」和「确实为空」分成两个结果（与 QQDriver 同构）。
    /// noValue / attributeUnsupported 表示这个节点本来就没有该属性，算成功读到空；
    /// 其余错误码先重读一次，仍失败就抛错中止本次操作，绝不向“没有残留/没有附件”降级。
    private func axRead(_ e: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        var v: CFTypeRef?
        let first = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if first == .success { return v }
        if first == .noValue || first == .attributeUnsupported { return nil }
        let second = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if second == .success { return v }
        if second == .noValue || second == .attributeUnsupported { return nil }
        lastAXErrorCode = second.rawValue
        throw AppError("微信控件树读取失败（辅助功能错误码 \(lastAXErrorCode)），当前界面状态无法确认，操作已停止")
    }
    private func label(_ e: AXUIElement) -> String {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] { let s = string(e, a); if !s.isEmpty { return s } }; return ""
    }
    private func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) }
    private func subrole(_ e: AXUIElement) -> String { string(e, kAXSubroleAttribute) }
    /// 子节点读取失败会抛错（与 QQDriver 同口径）：空草稿守卫与图片计数都建立在它之上。
    private func children(_ e: AXUIElement) throws -> [AXUIElement] { (try axRead(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// 只为失败现场交代结构的路子（诊断文案）：读不到就当空，不因此中断已经确定的结论。
    private func childrenOrEmpty(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func parent(of e: AXUIElement) throws -> AXUIElement? {
        guard let raw = try axRead(e, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    /// 应用窗口列表：读不到就是“不知道现在的窗口状态”，不能当成“没有窗口”。
    private func appWindows() throws -> [AXUIElement] { (try axRead(appElement(), kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    private func axTimeout(_ seconds: Double) -> String {
        "微信界面读取超过 \(Int(seconds)) 秒没有响应（辅助功能无响应或微信正在重渲染），操作已停止"
    }
    private func pauseIfAsked(at index: Int) throws {
        guard PausePoint.shouldPoll(at: index) else { return }
        CFRunLoopRunInMode(.defaultMode, 0, true)
        if cancelled || Task.isCancelled {
            throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息")
        }
    }
    /// 广度遍历。除节点上限外再加墙钟时限，与 QQDriver 的 nodes() 同一口径（2-07）。
    private func nodes(_ root: AXUIElement, limit: Int = 4500, seconds: Double = 3) throws -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(seconds)
        var queue = [root]
        var i = 0
        while i < queue.count && queue.count < limit {
            try pauseIfAsked(at: i)
            guard Date() < deadline else { throw AppError(axTimeout(seconds)) }
            let c = try children(queue[i])
            queue.append(contentsOf: c.prefix(limit - queue.count))
            i += 1
        }
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
        // 与 QQDriver 同口径：取消有两条通道（cancelled 标志与结构化取消），两条都要感知。
        try Task.checkCancellation()
        if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let front = observedFrontPID()
        // 通过/失败边界不变：仍只有实时+缓存都读到微信进程才算通过；失败时按 ForegroundAnomaly
        // 细分文案——微信被最小化（没有任何可见窗口）时不误点名排在其后的 Finder/Chrome。
        guard front == pid else { throw foregroundAnomalyError(front: front, context: "操作暂停") }
    }
    // MARK: - 前台异常文案归类（只影响失败 message；不改任何通过/失败判定，也不新增自动恢复）
    /// CGWindowList 快照 → 分类所需的最小窗口行。读不到快照时返回 nil，由调用方退回旧口径。
    private func onScreenWindowRows() -> [ForegroundAnomaly.WindowRow]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0 else { return nil }
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return ForegroundAnomaly.WindowRow(ownerPID: owner,
                                               layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                               width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                                               height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        }
    }
    private func frontAppName(front: pid_t?) -> String {
        if let front, let app = NSRunningApplication(processIdentifier: front)?.localizedName, !app.isEmpty { return app }
        return NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用"
    }
    /// 四类失败文案：微信没有可见窗口→提示点开窗口（不点名无辜应用）；读不到前台→「无法读取当前前台应用」；
    /// 前台确实是其他应用→维持「前台已切换到 X」；分类说目标在前台时按理走不到（调用方已确认失败），
    /// 沿用旧文案兜底、绝不把失败吞成通过。
    private func foregroundAnomalyError(front: pid_t?, context: String) -> AppError {
        // 读不到窗口快照时不猜“微信没有窗口”，退回旧口径，避免把真实的前台切换误写成最小化。
        let hasVisibleWindow = onScreenWindowRows().map { ForegroundAnomaly.hasVisibleWindow(targetPID: pid, rows: $0) } ?? true
        switch ForegroundAnomaly.classify(frontPID: front, targetPID: pid, targetHasVisibleWindow: hasVisibleWindow) {
        case .targetHasNoVisibleWindow:
            return AppError("微信当前没有可见窗口（可能被最小化了）。请点开微信窗口后重试")
        case .frontUnknown:
            return AppError("无法读取当前前台应用，\(context)；不是微信登录失效")
        case .targetIsFront, .otherAppFront:
            return AppError("前台已切换到 \(frontAppName(front: front))，\(context)；不是微信登录失效")
        }
    }
    /// NSWorkspace.frontmostApplication 是异步缓存。按键与点击会改变外部状态，投递前再查一次
    /// 窗口服务的实时最前普通应用窗口（与 QQDriver 同口径）；输入法面板等非普通应用不算抢前台。
    private func liveFrontmostPID() -> pid_t? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for row in rows {
            guard let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0 else { continue }
            guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { continue }
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width > 1, height > 1 else { continue }
            guard let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular else { continue }
            return owner
        }
        return nil
    }
    /// 事件投递前最后一刻的前台确认。读不到窗口信息时不额外加码，仍由 check() 的缓存判据负责。
    private func confirmFrontmostBeforeEvent() throws {
        try check()
        guard let owner = liveFrontmostPID(), owner != pid else { return }
        guard owner != ProcessInfo.processInfo.processIdentifier else { return }
        // 与 check() 同一套分类：这一帧微信若已没有可见窗口，不点名刚排上来的无辜应用。
        throw foregroundAnomalyError(front: owner, context: "事件未投递")
    }
    /// Return 这类发送指令投递后立即复核前台。检查点已把记录写成 submitted，
    /// 若最前窗口此刻属于别的应用，事件可能打在别人的默认按钮上：如实报“可能未被微信接收”。
    private func verifyEventLanded() async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
        guard let owner = liveFrontmostPID(), owner != pid,
              owner != ProcessInfo.processInfo.processIdentifier else { return }
        let name = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "其他应用"
        throw AppError("发送键已投递，但此刻最前窗口属于「\(name)」，发送指令可能未被微信接收；请到微信核对是否已发出，不会自动重发")
    }
    private func wait(_ seconds: Double = 0.45) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await recoverOwnForegroundIfNeeded()
    }
    /// 只有本程序自己占前台时才唤回微信。别的应用占前台仍立刻停止。不点击、不按键。
    private func recoverOwnForegroundIfNeeded() async throws {
        let front = observedFrontPID()
        if ForegroundRecovery.decision(frontPID: front, targetPID: pid, selfPID: ProcessInfo.processInfo.processIdentifier) == .recoverOwnApp {
            try await activateForClick()
        }
        try check()
    }
    private func observedFrontPID() -> pid_t? {
        ForegroundHandoff.observedFrontPID(live: liveFrontmostPID(), cached: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
    private func yieldOwnWindows() {
        for window in NSApp.windows where window.isVisible {
            window.level = .normal
        }
    }
    private func waitUntilTargetFront(seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
            try Task.checkCancellation()
            if observedFrontPID() == pid { return true }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        return observedFrontPID() == pid
    }
    /// 只有本程序自己在前台时才把微信唤回。用户切到其他应用仍停止。不能先调用 check()，否则唤起代码永远走不到。
    private func activateForClick() async throws {
        if cancelled { throw AppError("已停止。请检查微信中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        switch ForegroundHandoff.action(frontPID: observedFrontPID(), targetPID: pid, selfPID: selfPID) {
        case .uncoverTarget:
            yieldOwnWindows()
            try check()
            return
        case .stop:
            try check()
            return
        case .yieldToTarget:
            break
        }
        guard let target = NSRunningApplication(processIdentifier: pid) else { try check(); return }
        NSApp.yieldActivation(to: target)
        _ = target.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        if try await waitUntilTargetFront(seconds: 2) {
            yieldOwnWindows()
            try check()
            return
        }
        if let url = Self.appURL() {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            if let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) { pid = app.processIdentifier }
            _ = try await waitUntilTargetFront(seconds: 4)
        }
        yieldOwnWindows()
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
            try await recoverOwnForegroundIfNeeded()
            if try condition() { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        throw AppError(message)
    }
    private func key(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try confirmFrontmostBeforeEvent()
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
    }
    private func click(_ e: AXUIElement, physical: Bool = false) throws {
        try check()
        if !physical, AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
        guard let f = frameOf(e), f.width > 1, f.height > 1 else { throw AppError("微信控件不可点击：\(label(e))") }
        let point = CGPoint(x: f.midX, y: f.midY)
        if let blocker = coveringAppName(point) { throw AppError("「\(blocker)」的窗口挡住了微信的「\(label(e))」，未发送点击，避免误触其他应用；请把微信窗口置于最前后重试") }
        // 遮挡判定之后、事件投递之前再确认一次前台：这一帧里前台仍可能已经换人。
        try confirmFrontmostBeforeEvent()
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
        try check(); let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string); clipboardVersion = pb.changeCount; try key(Key.paste, flags: .maskCommand)
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
    private func searchField(in window: AXUIElement) throws -> AXUIElement? {
        let fields = try nodes(window).filter { isSearchField($0) }
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
    // 会话标题核验分两个口径（走查 1-05，与 QQDriver 同步）：
    // ①**宽松定位 / 连续性核对**：`headerMatches` —— 抹掉空白再比，只用于「现在还在不在这个会话」，
    //   不作为发送依据。微信的标题文本节点偶尔带换行与零宽字符，收紧这条会把正常会话判成「已离开」。
    // ②**发送前身份绑定**：`requireIdentityBound` —— 用 `ConversationMatch.identityBound` 逐字相等
    //   （只去首尾空白），与人工核对续发同一口径；「A 群」与「A群」是两个群，不能互相顶替。
    /// 聊天头部窄带里的标题候选：窗口标题（独立聊天窗口的标题就是会话名）+ 窄带内的静态文本/按钮标签。
    /// 两个口径共用这一套几何过滤，避免宽松与严格各扫一遍树却认不同的节点。
    private func headerCandidates(_ w: AXUIElement) throws -> [String] {
        var labels: [String] = []
        let windowTitle = string(w, kAXTitleAttribute)
        if !windowTitle.isEmpty { labels.append(windowTitle) }
        guard let wf = frameOf(w) else { return labels }
        let ns = try nodes(w)
        let minX = chatMinX(ns, wf)
        let band = min(100, max(56, wf.height * 0.08))
        for n in ns where role(n) == kAXStaticTextRole || role(n) == kAXButtonRole {
            let text = label(n)
            guard !text.isEmpty, let f = frameOf(n) else { continue }
            let cy = f.midY - wf.minY, cx = f.midX - wf.minX
            if cy >= 0, cy <= band, cx >= minX { labels.append(text) }
        }
        return labels
    }
    // 会话标题核验（宽松口径）：窗口标题精确相等，或聊天区顶部窄带内出现与目标一致的标题文本（几何过滤排除会话列表/搜索下拉）
    private func headerMatches(_ w: AXUIElement, _ name: String) throws -> Bool {
        let target = normalized(name)
        guard !target.isEmpty else { return false }
        // 独立聊天窗口先走这条便宜判定，别在每个轮询步骤都重扫一遍控件树。
        if normalized(string(w, kAXTitleAttribute)) == target { return true }
        return try headerCandidates(w).contains { normalized($0) == target }
    }
    /// 发送前的会话身份绑定（走查 1-05）：微信的定位与搜索结果本来就要逐字同名且唯一，
    /// 但屏幕核验用的是「抹掉所有空白」的比较，差一个空格也算另一个群时不会自己报警。
    /// 写稿之前与按发送键之前都调它：标题候选里必须有一个与任务收件群逐字相同（只去首尾空白）。
    /// 对不上就如实交代「实际进入的会话」与输入名的差异并中止；只报需关注，不取消前台/草稿/提交核验，
    /// 也不删记录、不自动重发。
    private func requireIdentityBound(_ recipient: String, draftMayExist: Bool = false) throws -> AXUIElement {
        try check()
        let window = try focusedWindow()
        let candidates = try headerCandidates(window)
        guard ConversationMatch.identityBound(candidates: candidates, title: recipient) else {
            let actual = candidates.first { normalized($0) == normalized(recipient) } ?? ""
            // `identityBound` 还会挡掉「单字名」与「和搜索分类徽标同名」（群聊、文件等）两种输入；
            // 这时逐字比对其实没有差异可报，按严格口径的要求同样是不放行，文案照实说。
            let gap = ConversationMatch.bindingDivergence(input: recipient, selectedTitle: actual)
                ?? "「\(recipient)」只有 1 个字，或与搜索分类名重名，严格绑定口径不予确认"
            throw AppError("会话身份未能通过逐字绑定核验：\(gap)。已停止；\(draftMayExist ? "草稿可能已保留，未按发送键" : "未粘贴、未发送")；不会自动重发")
        }
        return window
    }
    // 独立弹出的聊天窗口：窗口标题即会话名
    private func matchingWindow(_ name: String) -> AXUIElement? {
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { normalized(string($0, kAXTitleAttribute)) == normalized(name) }
    }
    private func mainWindow() throws -> AXUIElement {
        let windows = try appWindows()
        for w in windows { if try searchField(in: w) != nil { return w } }
        throw AppError("没有找到包含搜索框的微信主窗口。请打开微信主窗口；这不是登录权限问题")
    }
    // 搜索结果只认「整名精确相等」的静态文本：重叠节点去重，主窗口内排除聊天区正文，绝不发错人
    private func searchCandidates(_ name: String) throws -> [AXUIElement] {
        let target = normalized(name)
        guard !target.isEmpty else { return [] }
        let windows = try appWindows()
        var out: [AXUIElement] = []
        for w in windows {
            guard let wf = frameOf(w) else { continue }
            let ns = try nodes(w)
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
    private func uniqueCandidate(_ name: String) throws -> AXUIElement? {
        let c = try searchCandidates(name)
        return c.count == 1 ? c[0] : nil
    }
    // 消息输入框：优先 TextArea；个别的版本若暴露为 TextField，只认聊天区下半部分（避免误抓顶部搜索框）
    private func editor(in window: AXUIElement) throws -> AXUIElement {
        let ns = try nodes(window)
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
    private func composerIsEmpty(_ e: AXUIElement) throws -> Bool {
        return ComposerContent.isEmpty(string(e, kAXValueAttribute), descendants: (try nodes(e)).dropFirst().map { child in
            ComposerNode(role: role(child), value: string(child, kAXValueAttribute), title: string(child, kAXTitleAttribute), description: string(child, kAXDescriptionAttribute))
        })
    }
    private func imageCount(_ input: AXUIElement) throws -> Int {
        ComposerContent.attachmentCount(string(input, kAXValueAttribute), imageNodes: (try nodes(input)).filter { role($0) == kAXImageRole }.count)
    }
    /// 输入区残留图片计数：与 QQ 的“预览区口径”同构（2-06）。微信把附件预览条渲染在编辑区之外，
    /// 只查编辑器子树会把上一轮残留的图当成基线折掉，跟着本次的图一起发出去。
    /// 口径：编辑器本身 + 往上两层祖先的兄弟分支里的图片节点，尺寸不小于缩略图（排除表情/截图等
    /// 工具栏小图标），且落在窗口下半部、聊天区右半边（排除会话列表头像与消息区历史图片）。
    /// 几何或控件读不到时：strict（填写草稿前的残留闸门）按“未知”停住，不能默认它不存在；
    /// 非 strict（贴图后的计数）沿用原有宽松口径，避免把正常路径也拦死。
    private func composerRegionImages(_ window: AXUIElement, _ input: AXUIElement, strict: Bool = false) throws -> Int {
        guard let wf = frameOf(window), let band = frameOf(input) else {
            guard strict else { return 0 }   // 计数路径退回只看编辑器子树的旧口径
            throw AppError("微信输入区几何读不到，无法确认有没有残留图片，已停止：未粘贴、未发送")
        }
        let ns = try nodes(window)
        let minX = chatMinX(ns, wf)
        var scopes: [AXUIElement] = [input]
        var current = input
        for _ in 0..<2 {
            guard let next = try parent(of: current) else { break }
            scopes.append(contentsOf: try children(next))
            current = next
        }
        var images = 0
        for scope in scopes {
            for node in try nodes(scope, limit: 400) {
                guard role(node) == kAXImageRole else { continue }
                // 图片节点几何读不到：残留闸门按“未知”停住，计数路径跳过该节点。
                guard let f = frameOf(node) else {
                    if strict { throw AppError("微信输入区有图片节点几何读不到，无法确认有没有残留图片，已停止：未粘贴、未发送") }
                    continue
                }
                guard f.width >= 40, f.height >= 40 else { continue }
                guard f.midY >= max(wf.minY + wf.height * 0.5, band.minY - 260), f.midY <= wf.maxY else { continue }
                guard f.midX - wf.minX >= minX else { continue }
                images += 1
            }
        }
        return images
    }
    private func ensureEmpty(_ e: AXUIElement) throws {
        // 正文为空只是半个守卫：输入区残留图片由 ensureNoResidualImages 单独把关（与 QQ 侧对齐）。
        guard try composerIsEmpty(e) else {
            // 只报计数与字符类别：这条记录会进备份，码点能无损还原用户草稿正文（2-31）。
            let visible = normalized(string(e, kAXValueAttribute))
            let kind = visible.first.map { $0.isNumber ? "数字" : ($0.isLetter ? ($0.isASCII ? "字母" : "中日韩文字") : "标点或符号") } ?? "无"
            let structure = childrenOrEmpty(e).prefix(8).map { role($0) + ":" + String(string($0, kAXValueAttribute).count) }.joined(separator: ",")
            throw AppError("微信输入框检测到草稿或附件，已保留；请先手动处理。诊断：非空正文\(visible.count)字（首个字符类别\(kind)），children=\(structure)")
        }
    }
    /// 填写草稿前的残留图片闸门（需要窗口元素，与 ensureEmpty 一起用）。
    private func ensureNoResidualImages(_ window: AXUIElement, _ input: AXUIElement) throws {
        let residual = try composerRegionImages(window, input, strict: true)
        guard residual == 0 else {
            throw AppError("微信输入区检测到 \(residual) 张残留图片（不在输入框正文里），已保留；请先在微信里删掉后重试，否则会和本条任务的图一起发出")
        }
    }
    private func ensureConversation(_ name: String) throws -> AXUIElement {
        try check()
        let w = try focusedWindow()
        guard try headerMatches(w, name) else { throw AppError("当前会话标题与目标不一致：\(name)。已停止，不发送") }
        return w
    }
    // 尽力而为的发送后旁证：聊天区出现与文案一致的静态文本（长文案放宽为包含匹配）。
    // 只认落在聊天区下半部的行：微信把最新消息排在下方，翻到上面的历史同文消息不算本次证据。
    // 该旁证只写进核验文案，不参与能否判 verified（微信侧没有可用的本人消息独立 ID）。
    private func messageEcho(_ w: AXUIElement, _ text: String) throws -> Bool {
        let target = normalized(text)
        guard !target.isEmpty, let wf = frameOf(w) else { return false }
        let ns = try nodes(w)
        let minX = chatMinX(ns, wf)
        return ns.contains { n in
            guard role(n) == kAXStaticTextRole, let f = frameOf(n), f.midX - wf.minX >= minX else { return false }
            guard f.midY >= wf.minY + wf.height * 0.5 else { return false }
            let line = normalized(label(n))
            return line == target || (target.count >= 16 && line.contains(target))
        }
    }

    // MARK: - 会话定位
    private func locate(_ recipient: String) async throws -> AXUIElement {
        onStep("定位会话：\(recipient)")
        if let w = try? focusedWindow(), try headerMatches(w, recipient) {
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
        if try searchField(in: window) == nil {
            let main = try mainWindow()
            onStep("从独立聊天窗口回到微信主窗口")
            _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
            try await until("微信主窗口未获得焦点，未输入搜索内容", seconds: 3) { CFEqual(try self.focusedWindow(), main) }
            window = try focusedWindow()
        }
        return try await searchAndEnter(recipient, in: window)
    }
    private func searchAndEnter(_ recipient: String, in initial: AXUIElement) async throws -> AXUIElement {
        guard let search = try searchField(in: initial) else {
            throw AppError("微信控件树已加载，但未识别到搜索框（\(try nodes(initial).count) 个控件）。请关闭微信弹窗或回到主窗口；这不是登录权限问题")
        }
        onStep("聚焦搜索框：\(recipient)")
        try await focus(search)
        // 写入群名：优先 AX 设值；失败或未生效则全选后剪贴板粘贴
        let set = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, recipient as CFString)
        if set != .success || normalized(string(search, kAXValueAttribute)) != normalized(recipient) {
            try key(Key.selectAll, flags: .maskCommand)
            try paste(recipient)
        }
        try await until("搜索文字未写入微信搜索框，未点击任何结果", seconds: 3) {
            guard let f = try self.searchField(in: try self.focusedWindow()) else { return false }
            return self.normalized(self.string(f, kAXValueAttribute)) == self.normalized(recipient)
        }
        onStep("等待「\(recipient)」的完整搜索结果")
        try await until("未出现完整名称的搜索结果：\(recipient)。未发送、未继续", seconds: 8) {
            try !self.searchCandidates(recipient).isEmpty
        }
        guard let only = try uniqueCandidate(recipient) else {
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
            if clicks < 3, let only = try uniqueCandidate(name) {
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
        let previousPID = pid
        pid = app.processIdentifier
        defer { pid = previousPID }   // 点一下诊断不该改变发送目标进程（2-28）
        AXUIElementSetMessagingTimeout(appElement(), 2)
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        let summaries = windows.map { window -> String in
            let controls = (try? nodes(window)) ?? []
            let found = controls.contains { isSearchField($0) }
            return "窗口：\(label(window))；可读取控件：\(controls.count)；搜索框：\(found ? "已找到" : "未找到")"
        }
        return "辅助功能权限：已授权\n微信进程：\(app.processIdentifier)\n窗口数：\(windows.count)\n" + summaries.joined(separator: "\n") + "\n控件数为 0 通常表示微信未登录或主窗口未打开。检查不会点击、不会按键、不会发送消息，也不读取密码。"
    }
    func openWeChat() async throws {
        if let refusal = DispatchProbe.refusal(entry: "打开微信") { throw AppError(refusal) }
        cancelled = false
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        onStep("正在打开微信")
        guard let url = Self.appURL() else { throw AppError("未找到已安装的微信。请把微信安装到 /Applications 并登录后重试") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        // Launch Services 会激活已运行的微信；单独 activate() 在新版 macOS 上可能被拒绝
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        pid = app.processIdentifier
        app.unhide()
        try Task.checkCancellation()
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let restored = await ChatWindowPresentation.setMinimized(false, app: app)
        guard restored.complete else { throw AppError("微信窗口未能自动展开，请手动展开后再试；未发送") }
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
            return try self.nodes(window).contains { self.role($0) == kAXTextFieldRole || self.role($0) == kAXTextAreaRole }
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
    /// 输入区图片计数的统一口径：编辑器子树与输入区预览条取较大者（与 QQDriver 的 draftImageCount 同构）。
    private func measuredImageCount(_ window: AXUIElement, _ input: AXUIElement) throws -> Int {
        max(try imageCount(input), try composerRegionImages(window, input))
    }
    /// 贴图轮询里只允许“输入框定位类”的瞬时失败重试；前台切换、会话不符、控件树读不到
    /// 一律立刻终止（2-18：安全网不该靠循环体外侧的 wait 兜着）。
    private func recoverablePollError(_ message: String) -> Bool {
        message.hasPrefix("未能唯一定位微信消息输入框")
    }
    private func attachImages(_ delivery: Delivery, root: URL, recipient: String) async throws -> Bool {
        var confirmed = true
        for asset in delivery.assets {
            onStep(AttachWait.preparing(name: asset.name))
            // 与 QQ 同一口径：解码挪出主线程（2-19 (a)），失败在这一步就抛出，剪贴板与输入框都还没碰过。
            let tiff = try await ImageAttachment.tiffPayload(at: root.appendingPathComponent(asset.relativePath))
            let w = try ensureConversation(recipient)
            let input = try editor(in: w)
            let baseline = try measuredImageCount(w, input)
            try await focus(input)
            try key(Key.moveToTextEnd, flags: .maskCommand)
            let pb = NSPasteboard.general; pb.clearContents(); pb.setData(tiff, forType: .tiff); clipboardVersion = pb.changeCount
            try key(Key.paste, flags: .maskCommand)
            let started = Date()
            // 与 QQ 一致：等待预算按实际粘贴载荷（重编码后的 TIFF 字节数）放大，大图不再必然走降级（2-18/2-15）。
            let budget = AttachWait.budget(bytes: Int64(tiff.count))
            let rounds = max(20, Int(budget / 0.3))
            var reported = ""
            var reached = false
            for _ in 0..<rounds {
                let line = AttachWait.line(name: asset.name, elapsed: Date().timeIntervalSince(started), budget: budget)
                if line != reported { reported = line; onStep(line) }
                try await wait(0.3)
                do {
                    let cw = try ensureConversation(recipient)
                    let ce = try editor(in: cw)
                    if try measuredImageCount(cw, ce) > baseline { reached = true; break }
                } catch let error as AppError {
                    guard !PausePoint.isStop(error.localizedDescription), recoverablePollError(error.localizedDescription) else { throw error }
                    continue
                }
            }
            if !reached {
                // AX 读不到图片计数时不硬报错，降级为发送后人工确认
                confirmed = false
                onStep("无法通过辅助功能确认图片「\(asset.name)」已进入草稿，将继续填稿；发送结果需人工确认")
            }
        }
        return confirmed
    }
    private func awaitDraftCleared(recipient: String) async throws -> Bool {
        for _ in 0..<9 {
            try await wait(0.65)
            if let w = try? ensureConversation(recipient), let e = try? editor(in: w), try composerIsEmpty(e) { return true }
        }
        return false
    }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; submitted = false; sendCommandIssued = false
        guard ["draft", "automatic"].contains(delivery.mode) else { throw AppError("未知发送模式，未执行") }
        guard delivery.assets.allSatisfy(\.isImage) else { throw AppError("微信驱动暂只支持图片素材；普通文件请在 QQ 渠道发送或手动添加，未执行") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        guard !delivery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !delivery.assets.isEmpty else { throw AppError("文案和附件不能都为空，未执行") }
        for a in delivery.assets {
            let u = root.appendingPathComponent(a.relativePath)
            guard a.relativePath.hasPrefix("assets/"), u.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/assets/"), FileManager.default.fileExists(atPath: u.path), try Database.digest(u) == a.sha256 else { throw AppError("素材缺失、路径无效或已改变：\(a.name)") }
            // 与 QQ 侧 (QQDriver.run 前置校验) 完全同一口径：只有图片资产才做解码校验，
            // 普通文件不能在这里被当成「读不到的图片」误报（2-19 (b)）。
            // 打开微信之前只按文件头把关；真正写进剪贴板的那一次解码在 attachImages 里，失败同样不粘贴。
            if a.isImage { try ImageAttachment.validateReadable(at: u) }
        }
        try await openWeChat()
        captureClipboard(); defer { restoreClipboard() }
        var w = try await locate(delivery.recipient)
        // 写稿前的身份绑定（走查 1-05）：定位与连续性核对允许空白差异，逐字绑定不允许。
        w = try requireIdentityBound(delivery.recipient)
        // 空草稿 + 输入区残留图片两道闸门，与 QQ 侧口径对齐（2-06）：
        // 残留图若被当成基线折掉，就会和本条任务的图一起发出去。
        let openingEditor = try editor(in: w)
        try ensureEmpty(openingEditor)
        if !delivery.assets.isEmpty { try ensureNoResidualImages(w, openingEditor) }
        var imagesConfirmed = delivery.assets.isEmpty
        if !delivery.assets.isEmpty { imagesConfirmed = try await attachImages(delivery, root: root, recipient: delivery.recipient) }
        w = try ensureConversation(delivery.recipient)
        let input = try editor(in: w)
        try await focus(input); try key(Key.moveToTextEnd, flags: .maskCommand)
        if !delivery.text.isEmpty { try paste((delivery.assets.isEmpty ? "" : "\n") + delivery.text); try await wait(0.5) }
        w = try ensureConversation(delivery.recipient)
        guard normalized(string(try editor(in: w), kAXValueAttribute)) == normalized(delivery.text) else { throw AppError("草稿文字与计划不一致。请检查微信草稿，未发送") }
        if !delivery.assets.isEmpty {
            let counted = try measuredImageCount(w, try editor(in: w))
            let expected = delivery.assets.count
            if counted == expected { imagesConfirmed = true }
            else if counted > 0 { throw AppError("草稿图片数量与计划不一致（应为 \(expected) 张，读到 \(counted) 张），未发送") }
            else if !DraftTolerance.toleratesUnconfirmedImage(mode: delivery.mode) {
                // 自动模式与 QQ 同一口径：读不到图片计数就不发送。宁可停在发送前让人核对，
                // 也不把「程序自始至终没验证过存在」的图片发进群（走查 2026-10-06 对齐 QQ 1479-1488）。
                throw AppError("无法通过辅助功能确认草稿中有计划的 \(expected) 张图片（图片计数读数为 0），已保留图文，未发送。请到微信目视核对图片是否已进入输入框，再决定重试或人工发送")
            }
            // counted == 0 且草稿模式：保持降级——草稿不会自动发出，人工确认提示在下方 draft 返回里
        }
        if delivery.mode == "draft" {
            var detail = "已填入正确会话和附件。请在微信手动发送，然后在记录中确认；队列已暂停"
            if !imagesConfirmed { detail += "。注意：图片未能通过辅助功能核验，请先人工确认图片已在输入框中" }
            return ("draft", detail)
        }
        onStep("收件人和草稿已核对，准备提交")
        // 按发送键前再走一次同一套严格绑定（走查 1-05）：填稿期间会话可能被手动切换，或标题被微信
        // 渲染成只差空白的另一个群；这一条不过就停在这里，不写检查点、不按 Return。
        _ = try requireIdentityBound(delivery.recipient, draftMayExist: true)
        try beforeSubmit() // 发送前唯一检查点；此处抛错 = 前置失败（未发送）
        submitted = true
        do {
            try await recoverOwnForegroundIfNeeded()
            _ = try ensureConversation(delivery.recipient)
            guard let focused = focusedElement(), CFEqual(focused, try editor(in: focusedWindow())) else {
                return ("uncertain", "发送前输入焦点改变，未按下发送键。请检查微信草稿；为安全起见本次记为待核对，不自动重发")
            }
            // sendCommandIssued 挡住任何第二条发送指令路径（与 QQDriver 同一不变量）。
            guard !sendCommandIssued else { throw AppError("这条任务已经发出过一条发送指令，拒绝再次触发；请核对微信") }
            sendCommandIssued = true
            try key(Key.returnKey)
            onStep("已按 Return，等待微信发送")
            // Return 走的是全局事件通道：投递后立刻复核前台，被别的应用抢走时如实写成“可能未被微信接收”。
            try await verifyEventLanded()
            _ = try await awaitDraftCleared(recipient: delivery.recipient)
            let fw: AXUIElement
            let fe: AXUIElement
            do {
                fw = try ensureConversation(delivery.recipient)
                fe = try editor(in: fw)
            } catch let error as AppError where PausePoint.isStop(error.localizedDescription) {
                throw error
            } catch {
                return ("uncertain", "发送指令已发出，但无法确认会话状态。请到微信人工核对是否已发出；不会自动重发")
            }
            if try composerIsEmpty(fe) {
                if !imagesConfirmed {
                    return ("uncertain", "草稿已清空，但图片未能通过辅助功能核验，无法确认图片是否已发出。请到微信人工核对；不会自动重发。若微信设置为 Enter 换行 / Cmd+Enter 发送，请到微信设置确认")
                }
                let echo = delivery.text.isEmpty ? true : try messageEcho(fw, delivery.text)
                let pictures = delivery.assets.isEmpty ? "" : "；\(delivery.assets.count) 张图按输入区计数核对通过"
                return ("verified", "\(Date().formatted()) · 会话标题匹配；草稿已清空\(pictures)" + (echo ? "；消息区下部已看到本次发送内容" : "；消息区内容未能读取，以草稿清空与会话标题核验") + "。仅为客户端可见核验，不是服务器送达回执")
            }
            return ("uncertain", SendAttempt.weChatDraftRemains)
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
