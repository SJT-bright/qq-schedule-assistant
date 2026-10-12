import AppKit
import ApplicationServices

struct ChatWindowTransition {
    var total = 0
    var changed = 0
    var failed = 0
    var complete: Bool { total > 0 && failed == 0 }
}

/// 只改指定聊天进程自己的普通窗口；不关闭窗口、不退出客户端、不按发送键。
@MainActor enum ChatWindowPresentation {
    static var visibleAXFrames: [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map {
            CGRect(x: $0.visibleFrame.minX, y: primary.frame.maxY - $0.visibleFrame.maxY,
                   width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
    }
    static func setMinimized(_ minimized: Bool, app: NSRunningApplication) async -> ChatWindowTransition {
        // Launch Services 完成回调和窗口 AX 句柄就绪之间可能有延迟。
        // 每拍重取窗口，不让一次过时句柄或异步动画直接成为“无法展开”。
        let deadline = Date().addingTimeInterval(4)
        var report = await transition(minimized, app: app)
        while !report.complete, !Task.isCancelled, !app.isTerminated, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            report = await transition(minimized, app: app)
        }
        return report
    }

    private static func transition(_ minimized: Bool, app: NSRunningApplication) async -> ChatWindowTransition {
        var report = ChatWindowTransition()
        guard !app.isTerminated else { report.failed = 1; return report }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 1)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { report.failed = 1; return report }
        for window in windows {
            var role: CFTypeRef?, subrole: CFTypeRef?, state: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole else { continue }
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            // 系统浮层 / 弹出菜单没有最小化能力，不把它们当作聊天窗口。
            if let subrole = subrole as? String, subrole != kAXStandardWindowSubrole { continue }
            report.total += 1
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == app.processIdentifier,
                  AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &state) == .success,
                  let current = state as? Bool else { report.failed += 1; continue }
            if current != minimized {
            guard !Task.isCancelled, !app.isTerminated,
                  AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                               minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success else {
                report.failed += 1; continue
            }
            var confirmed = false
            for _ in 0..<12 {
                state = nil
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &state) == .success,
                   state as? Bool == minimized { confirmed = true; break }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if confirmed { report.changed += 1 } else { report.failed += 1 }
            }
            if !minimized, !Task.isCancelled, !restoreVisibleBounds(window) { report.failed += 1 }
        }
        return report
    }

    private static func restoreVisibleBounds(_ window: AXUIElement) -> Bool {
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           fullScreen as? Bool == true { return true }
        func frame() -> CGRect? {
            var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let p = rawPosition, let s = rawSize,
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var position = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: position, size: size)
        }
        guard let before = frame() else { return false }
        let visible = visibleAXFrames
        guard let fitted = WindowRestorePlacement.fitted(before, within: visible) else { return false }
        if fitted == before { return true }
        var position = fitted.origin, size = fitted.size
        guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { return false }
        if fitted.size != before.size,
           AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) != .success { return false }
        if fitted.origin != before.origin,
           AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) != .success { return false }
        guard let after = frame() else { return false }
        // 容许窗口边框取整；未知、拒绝移动或仍不可见的窗口不会被宣称恢复成功。
        return visible.contains { $0.insetBy(dx: -2, dy: -2).contains(after) }
    }
}

@MainActor
protocol ChatDriver: AnyObject {
    var cancelled: Bool { get set }
    var beforeSubmit: () throws -> Void { get set }
    var verificationEvidence: QQVerificationEvidence? { get }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String)
}

extension ChatDriver {
    var verificationEvidence: QQVerificationEvidence? { nil }
}

extension QQDriver: ChatDriver {}
extension WeChatDriver: ChatDriver {}

@MainActor
final class QQDriver {
    var cancelled = false
    var onStep: (String) -> Void = { _ in }
    var beforeSubmit: () throws -> Void = {}
    private(set) var verificationEvidence: QQVerificationEvidence?
    private var pid: pid_t = 0
    private var clipboard: [[NSPasteboard.PasteboardType: Data]] = []
    private var clipboardVersion: Int?
    private var submitted = false
    /// 本条任务是否已经发出过唯一的一条发送指令；fireSend 用它挡住任何第二条触发路径。
    private var sendCommandIssued = false
    private var actualTriggerAt: Date?
    private var composerImageBaseline = 0
    /// 本次运行里已经用正向信号确认过的图片张数（与本次粘贴因果绑定的草稿区计数增量）
    private var confirmedImages = 0
    private var imagePasteCommands = 0
    /// 只拿到内联对象/新 class 弱信号的张数：只用于交代现场，不参与能否发送的判定。
    private var weakImageSignals = 0
    /// 只在草稿模式（不发送）下出现：图已粘进去但辅助功能取不到正向信号，需要人目视核对
    private var imageLeftUnconfirmed = false
    private var selectedHeader: AXUIElement?
    private var selectedTitle = ""
    private var selectedMessageList: AXUIElement?
    private var selectedWindow: AXUIElement?
    private var selectedComposer: AXUIElement?
    private var selectedPane: AXUIElement?
    private var composerStructureStable = false
    /// 最后的提交读取不能在中途泵主线程点击事件，否则刚确认的图片可能被排队点击删除。
    /// 仅覆盖有时限的只读预检；进入前后照常处理暂停，预检后直接写检查点和唯一发送指令。
    private var finalSubmitRead = false
    /// 非提交临界区的长树读取按单调时钟让出；慢节点不能攒够 25 个才处理暂停。
    /// 单次 AX IPC 仍受原 2 秒超时限制，这个预算只缩短节点之间的点击等待。
    private var lastReadYieldUptime: TimeInterval = 0
    private static let readYieldInterval: TimeInterval = 0.04
    private struct ConversationRegion {
        let pane: AXUIElement
        let header: AXUIElement
        let title: String
        let messages: AXUIElement
        let composer: AXUIElement
        func sameHandles(as other: ConversationRegion) -> Bool {
            title == other.title && CFEqual(pane, other.pane) && CFEqual(header, other.header)
                && CFEqual(messages, other.messages) && CFEqual(composer, other.composer)
        }
    }
    /// 发送后核验期的句柄重绑预算：只在 confirmAfterTrigger 每轮开头置为 2，
    /// 其余阶段（搜索、写稿、发送前的所有 ensureRecipient 调用点）保持 0，
    /// 即维持原来「句柄失配立即报已离开」的旧行为，发送前各检查点不受影响。
    private var rebindBudget = 0
    private var accessibilityStatus: AXError = .success
    static var trusted: Bool { AXIsProcessTrusted() }
    static var locked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSessionOnConsoleKey"] as? Bool == false
    }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    /// 按键用命名常量，避免“119 到底是 Cmd+End 还是打错的 Cmd+A”只能靠猜（Carbon Events.h：0=A、5=G、9=V、36=Return、119=End）。
    private enum Key {
        static let selectAll: CGKeyCode = 0
        static let goToFolder: CGKeyCode = 5
        static let paste: CGKeyCode = 9
        static let deleteBackward: CGKeyCode = 51
        static let returnKey: CGKeyCode = 36
        /// Cmd+End：把插入点移到正文末尾，保证粘贴是追加而不是替换选区。
        static let moveToTextEnd: CGKeyCode = 119
    }
    private func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, attr as CFString, &v) != .success { return nil }; return v }
    private func string(_ e: AXUIElement, _ attr: String) -> String { value(e, attr) as? String ?? "" }
    /// 最近一次关键读取失败的辅助功能错误码，只用于把“读不到”如实写进记录。
    private var lastAXErrorCode: Int32 = 0
    /// 关键判定用的读取：把「读不到」和「确实为空」分成两个结果。
    /// kAXErrorNoValue / attributeUnsupported 表示这个节点本来就没有该属性（叶子节点），算成功读到空；
    /// cannotComplete、apiDisabled、illegalArgument 等一律先重读一次，仍失败就抛错中止本次操作，
    /// 绝不把“读不到”当成“没有残留草稿”“没有弹窗”继续放行。
    private func axRead(_ e: AXUIElement, _ attr: String) throws -> CFTypeRef? {
        var v: CFTypeRef?
        let first = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if first == .success { return v }
        if first == .noValue || first == .attributeUnsupported { return nil }
        if first == .invalidUIElement {
            lastAXErrorCode = first.rawValue
            throw AppError("QQ 控件树读取失败（辅助功能错误码 \(lastAXErrorCode)），当前界面状态无法确认，操作已停止", axErrorCode: lastAXErrorCode)
        }
        // QQ 重渲染会把手里的元素句柄换掉；同一属性立刻重读一次才算数。
        let second = AXUIElementCopyAttributeValue(e, attr as CFString, &v)
        if second == .success { return v }
        if second == .noValue || second == .attributeUnsupported { return nil }
        lastAXErrorCode = second.rawValue
        throw AppError("QQ 控件树读取失败（辅助功能错误码 \(lastAXErrorCode)），当前界面状态无法确认，操作已停止", axErrorCode: lastAXErrorCode)
    }
    private func label(_ e: AXUIElement) -> String {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] { let s = string(e, a); if !s.isEmpty { return s } }; return ""
    }
    private func hasName(_ e: AXUIElement, _ name: String) -> Bool {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute].contains { string(e,$0) == name }
    }
    private func enableContentTree() {
        // Electron's documented opt-in for third-party assistive applications.
        accessibilityStatus = AXUIElementSetAttributeValue(appElement(), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(appElement(), 2)
    }
    private func until(_ message: String, seconds: Double = 6, onTransient: () -> Void = {}, _ condition: () throws -> Bool) async throws {
        try await QQTransitionRead.wait(message: message, seconds: seconds,
            beforeRead: { try await self.recoverOwnForegroundIfNeeded() },
            pause: { try await self.wait(0.15) }, onTransient: onTransient, condition: condition)
    }
    private func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) }
    private func frameOf(_ e: AXUIElement) -> CGRect? {
        guard let pv = value(e, kAXPositionAttribute), let sv = value(e, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(unsafeBitCast(pv, to: AXValue.self), .cgPoint, &p)
        AXValueGetValue(unsafeBitCast(sv, to: AXValue.self), .cgSize, &s)
        guard s.width >= 0, s.height >= 0 else { return nil }
        return CGRect(origin: p, size: s)
    }
    /// 子节点读取失败会抛错：空草稿守卫、弹窗闸门、输入框定位都建立在它之上，
    /// 返回空数组等于替 QQ 的无响应回答“这里什么都没有”。
    private func children(_ e: AXUIElement) throws -> [AXUIElement] { (try axRead(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// 只为失败现场交代结构的路子（诊断文案）：读不到就当空，不因此中断已经确定的结论。
    private func childrenOrEmpty(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func parent(of e: AXUIElement) throws -> AXUIElement? {
        guard let raw = try axRead(e, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    /// 应用窗口列表：读不到就是“不知道有没有弹窗”，不能当成“没有弹窗”。
    private func appWindows() throws -> [AXUIElement] { (try axRead(appElement(), kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    private func axTimeout(_ seconds: Double) -> String {
        "QQ 界面读取超过 \(Int(seconds)) 秒没有响应（辅助功能无响应或 QQ 正在重渲染），操作已停止"
    }
    private func pauseIfAsked(at index: Int) throws {
        // 每个读取边界先查取消；最终提交读取仍不处理界面事件。
        if cancelled || Task.isCancelled {
            throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息")
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard PausePoint.shouldPoll(at: index) || now - lastReadYieldUptime >= Self.readYieldInterval else { return }
        // 只处理已经排队的点击，不等待新事件。暂停会在这里变成 cancelled。
        if !finalSubmitRead {
            lastReadYieldUptime = now
            CFRunLoopRunInMode(.defaultMode, 0, true)
        }
        if cancelled || Task.isCancelled {
            throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息")
        }
    }
    /// 广度遍历。除节点上限外再加墙钟时限，与 firstNode/findRow 同一口径：
    /// 单次属性读取最多阻塞 2 秒，没有时限的话 4500 个节点能把主线程卡住几十秒。
    private func nodes(_ root: AXUIElement, limit: Int = 4500, seconds: Double = 3, controlsOnly: Bool = false, requireComplete: Bool = false, pruneEditor: Bool = true) throws -> [AXUIElement] {
        let deadline = Date().addingTimeInterval(seconds)
        var queue = [root]
        var i = 0
        while i < queue.count && (queue.count < limit || requireComplete) {
            try pauseIfAsked(at: i)
            guard Date() < deadline else { throw AppError(axTimeout(seconds)) }
            // 定位搜索框/输入框/头部时无需读不断刷新的聊天内容、会话摘要与成员名单。
            // 保留列表节点本身供绑定，只有控件扫描跳过子树；草稿/消息核验仍完整读取。
            let marker: String
            if controlsOnly {
                marker = requireComplete ? ((try axRead(queue[i], kAXDescriptionAttribute) as? String) ?? "") : label(queue[i])
            } else { marker = "" }
            if controlsOnly {
                let controlRole = (try axRead(queue[i], kAXRoleAttribute) as? String) ?? ""
                let classes = controlRole == kAXTextAreaRole ? ((try axRead(queue[i], "AXDOMClassList") as? [String]) ?? []) : []
                let subrole = (try axRead(queue[i], kAXSubroleAttribute) as? String) ?? ""
                if !["AXSheet", "AXDialog"].contains(subrole), (pruneEditor || controlRole != kAXTextAreaRole),
                   QQControlTree.prunesChildren(role: controlRole, description: marker, classes: classes) {
                    i += 1
                    continue
                }
            }
            let c = try children(queue[i])
            if requireComplete, c.count > limit - queue.count {
                throw AppError("QQ 控件树超过读取上限，不能确认输入框和标题唯一，未操作")
            }
            queue.append(contentsOf: c.prefix(limit - queue.count))
            i += 1
        }
        return queue
    }
    private func controlNodes(_ window: AXUIElement, limit: Int = 4500) throws -> [AXUIElement] {
        try nodes(window, limit: limit, controlsOnly: true)
    }
    /// Stop as soon as a control is found instead of collecting the whole QQ tree.
    private func firstNode(_ root: AXUIElement, matching: (AXUIElement) -> Bool) throws -> AXUIElement? {
        var stack = [(root, 0)]
        var count = 0
        let deadline = Date().addingTimeInterval(1)
        while let (element, depth) = stack.popLast() {
            try pauseIfAsked(at: count)
            guard count < 900, Date() < deadline, !cancelled, !Task.isCancelled else { return nil }
            count += 1
            if matching(element) { return element }
            if depth < 40 { stack.append(contentsOf: try children(element).reversed().map { ($0, depth + 1) }) }
        }
        return nil
    }
    private func orderedNodes(_ root: AXUIElement, seconds: Double = 3) throws -> [AXUIElement] {
        var output: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(seconds)
        func visit(_ element: AXUIElement, _ depth: Int) throws {
            guard depth < 50, output.count < 4500 else { return }
            try pauseIfAsked(at: output.count)
            guard Date() < deadline else { throw AppError(axTimeout(seconds)) }
            output.append(element)
            for child in try children(element) { try visit(child, depth + 1) }
        }
        try visit(root, 0)
        return output
    }
    /// 证据读取不能返回截断树，也不能把 AX 错误解释成空内容。
    private func evidenceNodes(_ root: AXUIElement) throws -> [AXUIElement] {
        var output: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(3)
        func visit(_ element: AXUIElement, depth: Int) throws {
            guard depth < 50, output.count < 4500, Date() < deadline else {
                throw AppError("QQ 核验节点未完整读取，不能确认发送成功")
            }
            try pauseIfAsked(at: output.count)
            output.append(element)
            for child in try children(element) { try visit(child, depth: depth + 1) }
        }
        try visit(root, depth: 0)
        return output
    }
    private func evidenceString(_ element: AXUIElement, _ attribute: String) throws -> String {
        let text = (try axRead(element, attribute) as? String) ?? ""
        if attribute == kAXRoleAttribute, text.isEmpty {
            throw AppError("QQ 核验节点角色不可读，不能确认内容是否完整")
        }
        return text
    }
    private func evidenceClasses(_ element: AXUIElement) throws -> [String] {
        if let classes = try axRead(element, "AXDOMClassList") as? [String] { return classes }
        if try evidenceString(element, kAXRoleAttribute) == kAXGroupRole {
            throw AppError("QQ 消息容器属性不可读，不能将其从核验基线中略过")
        }
        return []
    }
    private func evidenceLabel(_ element: AXUIElement) throws -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            let text = try evidenceString(element, attribute)
            if !text.isEmpty { return text }
        }
        return ""
    }
    private struct SearchResult {
        let action: AXUIElement
        let title: String
        let canOpen: Bool
        /// 这一行自己的文本，用作“结果列表是否随本次查询刷新”的指纹。
        let rowTexts: [String]
    }
    private func staticTexts(in element: AXUIElement) throws -> [String] {
        try orderedNodes(element).filter { role($0) == kAXStaticTextRole }.map { label($0) }.filter { !$0.isEmpty }
    }
    private func selectedGroupFilter(in elements: [AXUIElement]) -> Bool {
        guard let group = elements.first(where: { role($0) == kAXRadioButtonRole && hasName($0, "群聊") }) else { return false }
        if value(group, kAXSelectedAttribute) as? Bool == true { return true }
        if let number = value(group, kAXValueAttribute) as? NSNumber { return number.intValue == 1 }
        return string(group, kAXValueAttribute) == "1"
    }
    private func firstSearchResult(_ window: AXUIElement, query: String) throws -> SearchResult? {
        if hasName(window, "综合搜索") {
            let ordered = try orderedNodes(window)
            // The all-results view can put contacts before groups. Only the selected
            // group category makes its first action the first group result.
            guard selectedGroupFilter(in: ordered) else { return nil }
            // The first result row can contain many highlighted text fragments.
            // Locate the row by its action, never by counting matching text nodes.
            guard let action = ordered.first(where: {
                role($0) == kAXButtonRole && ["发消息", "加入", "已加入"].contains(label($0))
                    && frameOf($0).map { $0.width > 1 && $0.height > 1 } == true
            }) else { return nil }
            var parent = action
            for _ in 0..<6 {
                guard let next = try self.parent(of: parent) else { break }
                parent = next
                let texts = try staticTexts(in: parent)
                let title = ConversationMatch.resultTitle(texts: texts, query: query)
                if !title.isEmpty { return SearchResult(action: action, title: title, canOpen: hasName(action, "发消息"), rowTexts: texts) }
            }
            return nil
        }
        // Current QQ exposes “群聊” as a sibling heading, not inside AXMenuItem.
        // NT 下拉的结果行是带文本的 Group/Row/Button；旧版仍是 AXMenuItem。
        // Walk only the search branch, stop at the next category, and never select
        // the “搜索综合结果” entry. Avoid traversing the message/session lists.
        var visited = 0
        let deadline = Date().addingTimeInterval(1)
        func isLegacyMenuRow(_ element: AXUIElement) -> Bool {
            role(element) == kAXMenuItemRole
        }
        func isCompactResultRow(_ element: AXUIElement) -> Bool {
            let r = role(element)
            guard QQSearchLayout.rowRoles.contains(r) else { return false }
            let name = label(element)
            if QQSearchLayout.chromeNames.contains(name) { return false }
            if QQSearchLayout.isNextCategory(name) { return false }
            if ConversationMatch.badges.contains(name) { return false }
            guard let frame = frameOf(element), QQSearchLayout.isCompactResultHeight(frame.height), frame.width > 24 else { return false }
            if !name.isEmpty { return true }
            return !((try? staticTexts(in: element)) ?? []).isEmpty
        }
        func snapshot(of sibling: AXUIElement) -> QQSearchLayout.Sibling {
            QQSearchLayout.Sibling(
                role: role(sibling),
                name: label(sibling),
                hasNestedRow: (try? firstNode(sibling, matching: { isLegacyMenuRow($0) || isCompactResultRow($0) })) != nil,
                hasText: !((try? staticTexts(in: sibling)) ?? []).isEmpty,
                height: frameOf(sibling)?.height ?? 0
            )
        }
        func resultRow(from sibling: AXUIElement) throws -> AXUIElement? {
            guard QQSearchLayout.firstOpenableIndex(afterGroupHeading: [snapshot(of: sibling)]) == 0 else { return nil }
            if isLegacyMenuRow(sibling) { return sibling }
            if let nested = try firstNode(sibling, matching: { isLegacyMenuRow($0) }) { return nested }
            if isCompactResultRow(sibling) { return sibling }
            if let nested = try firstNode(sibling, matching: { isCompactResultRow($0) }) { return nested }
            return sibling
        }
        func findRow(_ element: AXUIElement, depth: Int = 0) throws -> AXUIElement? {
            guard depth < 40, visited < 900, Date() < deadline,
                  !cancelled, !Task.isCancelled else { return nil }
            visited += 1
            if hasName(element, "会话列表") || hasName(element, "消息列表") { return nil }
            let items = try children(element)
            if let heading = items.firstIndex(where: { role($0) == kAXStaticTextRole && hasName($0, "群聊") }) {
                let after = Array(items.dropFirst(heading + 1))
                let snapshots = after.map { snapshot(of: $0) }
                if let index = QQSearchLayout.firstOpenableIndex(afterGroupHeading: snapshots),
                   let row = try resultRow(from: after[index]) {
                    return row
                }
            }
            // Support older QQ builds with the category badge inside the row.
            if role(element) == kAXMenuItemRole,
               try firstNode(element, matching: { self.hasName($0, "群聊") }) != nil { return element }
            for child in items { if let row = try findRow(child, depth: depth + 1) { return row } }
            return nil
        }
        guard let row = try findRow(window) else { return nil }
        let texts = try staticTexts(in: row)
        let picked = ConversationMatch.resultTitle(texts: texts, query: query)
        let title = picked.isEmpty || ConversationMatch.badges.contains(picked) ? label(row) : picked
        guard !title.isEmpty else { return nil }
        // 下拉行里如果已经渲染出动作按钮，就必须见到「发消息」：只有「加入」的行是未加入的群，
        // 不能无条件当成可打开会话（AGENTS：不能自动加入群聊）。老版本下拉行里没有按钮节点，
        // 保持原来的“可直接点击”口径。
        let rowButtons = try orderedNodes(row).filter { role($0) == kAXButtonRole }.map { label($0) }.filter { !$0.isEmpty }
        let hasSendEntry = rowButtons.contains("发消息")
        let otherActions = rowButtons.filter { !["发消息", "加入", "已加入"].contains($0) && !ConversationMatch.badges.contains($0) }
        let canOpen = hasSendEntry || otherActions.isEmpty
        return SearchResult(action: row, title: title, canOpen: canOpen, rowTexts: texts)
    }
    /// 只从 QQ 当前 aio 聊天区域解析身份，不取侧栏、成员昵称、窗口汇总名或编辑器占位描述。
    /// 类名是完整匹配；未知布局保持不可定位。祖先、唯一性、可见性和几何均须同时成立。
    private func conversationRegion(_ window: AXUIElement) throws -> ConversationRegion {
        let all = try nodes(window, controlsOnly: true, requireComplete: true)
        func classes(_ element: AXUIElement) throws -> [String] {
            (try axRead(element, "AXDOMClassList") as? [String]) ?? []
        }
        func ancestor(_ element: AXUIElement, containing token: String) throws -> AXUIElement? {
            var current = element
            for _ in 0..<12 {
                guard let next = try parent(of: current) else { return nil }
                if try classes(next).contains(token) { return next }
                if CFEqual(next, window) { return nil }
                current = next
            }
            return nil
        }
        func visible(_ element: AXUIElement) throws -> Bool {
            var current = element
            var seen: [AXUIElement] = []
            for _ in 0..<50 {
                guard !seen.contains(where: { CFEqual($0, current) }) else { return false }
                seen.append(current)
                if try axRead(current, "AXHidden") as? Bool == true { return false }
                if try axRead(current, kAXEnabledAttribute) as? Bool == false { return false }
                if CFEqual(current, window) { return true }
                guard let next = try parent(of: current) else { return false }
                current = next
            }
            return false
        }
        // 扫描唯一的真实消息编辑器，隐藏分支不参加；普通文本框或其它 AXTextArea 不当作 QQ 输入区。
        let controls = try all.map { node in
            (node: node, role: (try axRead(node, kAXRoleAttribute) as? String) ?? "", classes: try classes(node))
        }
        var inputs: [AXUIElement] = []
        for item in controls where item.role == kAXTextAreaRole {
            let node = item.node, tokens = item.classes
            if tokens.contains("ProseMirror"), tokens.contains("ExEditor-qq-msg-editor"), try visible(node) { inputs.append(node) }
        }
        guard inputs.count == 1, let input = inputs.first,
              let inputArea = try ancestor(input, containing: "chat-input-area"),
              let pane = try ancestor(input, containing: "aio") else {
            throw AppError("未能唯一定位 QQ 消息输入框，请关闭其他弹窗")
        }
        guard (try ancestor(inputArea, containing: "aio")).map({ CFEqual($0, pane) }) == true else {
            throw AppError("QQ 输入区不属于当前聊天容器，未操作")
        }
        var headers: [AXUIElement] = [], lists: [AXUIElement] = []
        for item in controls {
            let node = item.node, tokens = item.classes
            if item.role == kAXButtonRole, tokens.contains("chat-header__contact-name"), try visible(node),
               let headerArea = try ancestor(node, containing: "chat-header"),
               let owner = try ancestor(headerArea, containing: "aio"), CFEqual(owner, pane) { headers.append(node) }
            if tokens.contains("chat-msg-area__vlist"),
               (try axRead(node, kAXDescriptionAttribute) as? String) == "消息列表", try visible(node),
               let messageArea = try ancestor(node, containing: "chat-msg-area"),
               let owner = try ancestor(messageArea, containing: "aio"), CFEqual(owner, pane) { lists.append(node) }
        }
        guard headers.count == 1, lists.count == 1, let header = headers.first, let messages = lists.first else {
            throw AppError("QQ 顶部会话标题和消息列表未能唯一绑定到当前聊天区，未操作")
        }
        // 标题按钮的 description 是顶部实际群名，不是下面输入框的陈旧占位名称。
        let title = ((try axRead(header, kAXDescriptionAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, QQConversationGeometry.valid(window: frameOf(window), pane: frameOf(pane),
            header: frameOf(header), messages: frameOf(messages), composer: frameOf(input)) else {
            throw AppError("QQ 聊天标题、消息区与输入框的可见位置不一致，未操作")
        }
        return ConversationRegion(pane: pane, header: header, title: title, messages: messages, composer: input)
    }
    private func headerCandidates(_ window: AXUIElement) throws -> [String] {
        do { return [try conversationRegion(window).title] }
        catch { try reraiseIfUnreadable(error); return [] }
    }
    /// “这一拍还没就绪”和“辅助功能读不到”必须分开：后者要继续往上抛，不能被 try? 压成 false。
    /// 否则 bindOpenedConversation 会把读不到当成“结果还没打开”，进而触发 openResult 的第二次物理点击。
    private func reraiseIfUnreadable(_ error: Error) throws {
        if let ax = error as? AppError, ax.message.hasPrefix("QQ 控件树") || ax.message.hasPrefix("QQ 界面读取") { throw ax }
    }
    private func conversationReady(_ window: AXUIElement, title: String) throws -> Bool {
        guard !hasName(window, "综合搜索") else { return false }
        // 输入框与消息列表暂时定位不到属于切换会话中的正常现象，仍算“未就绪”；读取失败才算异常。
        let region: ConversationRegion
        do { region = try conversationRegion(window) }
        catch { try reraiseIfUnreadable(error); return false }
        return ConversationMatch.headerMatches(candidates: [region.title], title: title)
    }
    private func rememberConversation(_ window: AXUIElement, title: String) throws {
        let region = try conversationRegion(window)
        guard ConversationMatch.headerMatches(candidates: [region.title], title: title) else {
            throw AppError("QQ 顶部会话尚未切换到刚选中的第一条结果，未操作")
        }
        rememberRegion(region, in: window)
    }
    private func rememberRegion(_ region: ConversationRegion, in window: AXUIElement) {
        selectedTitle = region.title
        selectedHeader = region.header
        selectedMessageList = region.messages
        selectedPane = region.pane
        selectedWindow = window
    }
    private func bindOpenedConversation(_ result: SearchResult, seconds: Double = 8) async throws -> AXUIElement {
        let timeoutMessage = "第一条结果尚未打开为聊天会话，未发送"
        var sawConversation = false
        var lastMarked = ""
        var stableReads = 0
        var stableWindow: AXUIElement?
        var stableRegion: ConversationRegion?
        composerStructureStable = false
        do {
            try await until(timeoutMessage, seconds: seconds, onTransient: {
                stableReads = 0
                stableWindow = nil
                stableRegion = nil
            }) {
            guard !result.title.isEmpty else { return false }
            guard let focused = try self.focusedWindowIfAvailable() else { stableReads = 0; return false }
            if try self.conversationReady(focused, title: result.title) {
                let region = try self.conversationRegion(focused)
                guard ConversationMatch.headerMatches(candidates: [region.title], title: result.title) else { stableReads = 0; return false }
                self.rememberRegion(region, in: focused)
                sawConversation = true
                lastMarked = (try self.axRead(region.composer, kAXDescriptionAttribute) as? String) ?? ""
                stableReads = stableWindow.map { CFEqual($0, focused) } == true
                    && stableRegion.map { $0.sameHandles(as: region) } == true ? stableReads + 1 : 1
                stableWindow = focused
                stableRegion = region
                if stableReads >= 2 { self.selectedComposer = region.composer; self.composerStructureStable = true }
                return stableReads >= 2
            }
            stableReads = 0
            // A separate chat window can open behind the search popup. Raise it only while search is still in front.
            let searching = try self.controlNodes(focused)
            guard self.hasName(focused, "综合搜索") || searching.contains(where: { self.role($0) == kAXTextFieldRole && self.hasName($0, "搜索") }),
                  let opened = try self.appWindows().first(where: { !CFEqual($0, focused) && (try? self.conversationReady($0, title: result.title)) == true }) else { return false }
            _ = AXUIElementPerformAction(opened, kAXRaiseAction as CFString)
            return false
            }
        } catch let error as AppError {
            if error.message == timeoutMessage && sawConversation {
                throw AppError("QQ 会话和输入框未连续稳定，已停止：未粘贴、未发送")
            }
            throw error
        }
        onStep("已进入第一条结果：\(selectedTitle)")
        if !lastMarked.isEmpty, !ConversationMatch.exactly(lastMarked, selectedTitle) {
            onStep("QQ 输入框描述为「\(lastMarked)」；已按顶部实际群名「\(selectedTitle)」与同一聊天区域连续绑定")
        }
        return try focusedWindow()
    }
    private func appElement() -> AXUIElement { AXUIElementCreateApplication(pid) }
    private func focusedWindowIfAvailable() throws -> AXUIElement? {
        guard let v = try axRead(appElement(), kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func focusedWindow() throws -> AXUIElement {
        guard let window = try focusedWindowIfAvailable() else { throw AppError("没有找到 QQ 活动窗口，请打开 QQ 主窗口") }
        return window
    }
    private func focusedElement() -> AXUIElement? {
        guard let v = value(appElement(), kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        // 实时窗口列表优先：NSWorkspace 缓存滞后时会误报本程序仍在前台，或漏掉已经盖上来的 Chrome。
        // 通过/失败边界不变：仍只有实时+缓存都读到 QQ 进程才算通过；失败时按 ForegroundAnomaly
        // 细分文案——QQ 被最小化（没有任何可见窗口）时不误点名排在其后的 Finder/Chrome。
        let front = observedFrontPID()
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
    /// 四类失败文案：QQ 没有可见窗口→提示点开窗口（不点名无辜应用）；读不到前台→「无法读取当前前台应用」；
    /// 前台确实是其他应用→维持「前台已切换到 X」；分类说目标在前台时按理走不到（调用方已确认失败），
    /// 沿用旧文案兜底、绝不把失败吞成通过。
    private func foregroundAnomalyError(front: pid_t?, context: String) -> AppError {
        // 读不到窗口快照时不猜“QQ 没有窗口”，退回旧口径，避免把真实的前台切换误写成最小化。
        let hasVisibleWindow = onScreenWindowRows().map { ForegroundAnomaly.hasVisibleWindow(targetPID: pid, rows: $0) } ?? true
        switch ForegroundAnomaly.classify(frontPID: front, targetPID: pid, targetHasVisibleWindow: hasVisibleWindow) {
        case .targetHasNoVisibleWindow:
            return AppError("QQ 当前没有可见窗口（可能被最小化了）。请点开 QQ 窗口后重试")
        case .frontUnknown:
            return AppError("无法读取当前前台应用，\(context)；不是 QQ 登录失效")
        case .targetIsFront, .otherAppFront:
            return AppError("前台已切换到 \(frontAppName(front: front))，\(context)；不是 QQ 登录失效")
        }
    }
    /// NSWorkspace.frontmostApplication 是异步缓存。按键与点击会改变外部状态，投递前再查一次
    /// 窗口服务的实时最前普通应用窗口（从前到后第一个 .regular 应用的可见窗口）。
    /// 输入法面板、系统浮层等非普通应用不算“抢前台”，避免把正常路径也拦死。
    private func liveFrontmostPID() -> pid_t? {
        // 系统当前接收键盘事件的应用比窗口矩形/层级更直接；QQ 置顶窗、
        // ZCode 通知或 Dock 合成层都不应改变这个归属。
        var focusedApp: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let focusedApp, CFGetTypeID(focusedApp) == AXUIElementGetTypeID() {
            var owner: pid_t = 0
            if AXUIElementGetPid(unsafeBitCast(focusedApp, to: AXUIElement.self), &owner) == .success, owner > 0 { return owner }
        }
        guard let rows = onScreenWindowRows() else { return nil }
        let regularPIDs = Set(rows.compactMap { row -> Int32? in
            NSRunningApplication(processIdentifier: row.ownerPID)?.activationPolicy == .regular ? row.ownerPID : nil
        })
        return ForegroundHandoff.firstNormalWindowPID(rows: rows, regularPIDs: regularPIDs)
    }
    /// 事件投递前最后一刻的前台确认。读不到窗口信息时不额外加码，仍由 check() 的缓存判据负责。
    private func confirmFrontmostBeforeEvent() throws {
        try check()
        guard let owner = liveFrontmostPID(), owner != pid else { return }
        // 本程序自己的窗口压在上面时交给覆盖判定（click）与后续核验处理，不在此处误报。
        guard owner != ProcessInfo.processInfo.processIdentifier else { return }
        // 与 check() 同一套分类：这一帧 QQ 若已没有可见窗口，不点名刚排上来的无辜应用。
        throw foregroundAnomalyError(front: owner, context: "事件未投递")
    }
    private func wait(_ seconds: Double = 0.45) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        // 等待期间点程序坞会把本程序带到前面。只在这种时候把 QQ 唤回；别的应用占前台仍立刻停。
        try await recoverOwnForegroundIfNeeded()
    }
    private func observedFrontPID() -> pid_t? {
        ForegroundHandoff.observedFrontPID(live: liveFrontmostPID(), cached: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
    private func yieldOwnWindows() {
        // 只把浮动窗降回普通层。orderBack 会把本程序沉到同层最底，夹在中间的 Chrome
        // 会盖住 QQ，搜索下拉收起，后续点击落到别人窗口上。
        for window in NSApp.windows where window.isVisible {
            window.level = .normal
        }
    }
    private func waitUntilTargetFront(seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
            try Task.checkCancellation()
            if observedFrontPID() == pid { return true }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        return observedFrontPID() == pid
    }
    private func activateForClick() async throws {
        try Task.checkCancellation()
        if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
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
        // macOS 14+ 必须先交出激活权，再从本程序激活 QQ；activateIgnoringOtherApps 已是空操作。
        NSApp.yieldActivation(to: target)
        _ = target.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        if try await waitUntilTargetFront(seconds: 2) {
            yieldOwnWindows()
            try check()
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.qq") {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            if let qq = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) { pid = qq.processIdentifier }
            _ = try await waitUntilTargetFront(seconds: 4)
        }
        yieldOwnWindows()
        try check()
    }
    /// 只有本 App 自己占前台时才唤回 QQ。Chrome、ChatGPT 或其他应用占前台仍立刻停止。
    /// 不点击、不按键。图片轮询、普通等待和按下 Return 之前都会走这里。
    private func recoverOwnForegroundIfNeeded() async throws {
        let front = observedFrontPID()
        if ForegroundRecovery.decision(frontPID: front, targetPID: pid, selfPID: ProcessInfo.processInfo.processIdentifier) == .recoverOwnApp {
            try await activateForClick()
        }
        try check()
    }
    private func pauseAttachPoll(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await recoverOwnForegroundIfNeeded()
    }
    private func coveringAppName(_ point: CGPoint) -> String? {
        // 系统合成窗（Dock、通知中心等）的矩形可能包含透明、不可点击的区域。
        // 先问辅助功能“此点实际命中哪个应用”，避免把透明矩形当成真实遮挡。
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success, let hit {
            var owner: pid_t = 0
            if AXUIElementGetPid(hit, &owner) == .success, owner > 0 {
                if owner == pid { return nil }
                if owner == ProcessInfo.processInfo.processIdentifier { return "QQ排程助手" }
                return NSRunningApplication(processIdentifier: owner)?.localizedName ?? "其他应用"
            }
        }
        // 命中读取不可用时保留原有遮挡检查，不靠未知状态放行。
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
    private func click(_ e: AXUIElement, physical: Bool = false) throws {
        try check()
        guard let frame = frameOf(e), frame.width > 1, frame.height > 1 else { throw AppError(frameOf(e) == nil ? "QQ 控件不可点击：\(label(e))" : "目标控件当前不可见") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard ChatWindowPresentation.visibleAXFrames.contains(where: { $0.contains(point) }) else {
            throw AppError("QQ 控件位于屏幕可见区域之外，已停止；未点击、未发送")
        }
        if !physical, AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
        if let blocker = coveringAppName(point) { throw AppError("「\(blocker)」的窗口挡住了 QQ 的「\(label(e))」，未发送点击，避免误触其他应用；请把 QQ 窗口置于最前后重试") }
        // 遮挡判定之后、事件投递之前再确认一次前台：这一帧里前台仍可能已经换人。
        try confirmFrontmostBeforeEvent()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw AppError("无法生成点击事件，未点击") }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    private func key(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try confirmFrontmostBeforeEvent()
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
    }
    /// Return 这类发送指令投递后立即复核前台。检查点已把记录写成 submitted，
    /// 若最前窗口此刻已属于别的应用，事件可能打在别人的默认按钮上：如实报“可能未被 QQ 接收”，
    /// 由调用方停在待核对，绝不补第二次发送。
    private func verifyEventLanded() async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
        guard let owner = liveFrontmostPID(), owner != pid,
              owner != ProcessInfo.processInfo.processIdentifier else { return }
        let name = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "其他应用"
        throw AppError("发送键已投递，但此刻最前窗口属于「\(name)」，发送指令可能未被 QQ 接收；请到 QQ 核对是否已发出，不会自动重发")
    }
    private func captureClipboard() {
        clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in var result: [NSPasteboard.PasteboardType: Data] = [:]; for t in item.types { if let d = item.data(forType: t) { result[t] = d } }; return result }
    }
    private func restoreClipboard() {
        let pb = NSPasteboard.general
        guard let clipboardVersion, pb.changeCount == clipboardVersion else { return }
        pb.clearContents()
        let items = clipboard.map { saved -> NSPasteboardItem in let item = NSPasteboardItem(); for (t,d) in saved { item.setData(d, forType: t) }; return item }
        if !items.isEmpty { pb.writeObjects(items) }
    }
    private func paste(_ text: String) throws {
        try check(); let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string); clipboardVersion = pb.changeCount; try key(Key.paste, flags: .maskCommand)
    }
    private func focus(_ element: AXUIElement) async throws {
        try await activateForClick()
        _ = AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue)
        if let focused = focusedElement(), CFEqual(focused,element) { return }
        try await activateForClick()
        try click(element)
        try await until("输入框未获得焦点，未输入内容",seconds:2) { if let focused = self.focusedElement() { return CFEqual(focused,element) }; return false }
    }
    private func editor(in window: AXUIElement) throws -> AXUIElement {
        try conversationRegion(window).composer
    }
    /// 每次重新解析当前 aio 区域，确认实际群名与四个句柄仍是最初绑定的那一组。
    /// 侧栏同名文字、旧隐藏区域或别的输入框都不能替代它们。
    private func handlesStillBound(_ window: AXUIElement, region resolved: ConversationRegion? = nil) throws -> Bool {
        guard let header = selectedHeader, let list = selectedMessageList,
              let pane = selectedPane, let originalWindow = selectedWindow,
              CFEqual(window, originalWindow) else { return false }
        let region: ConversationRegion
        do { region = try resolved ?? conversationRegion(window) }
        catch { try reraiseIfUnreadable(error); return false }
        guard ConversationMatch.exactly(region.title, selectedTitle), CFEqual(region.header, header),
              CFEqual(region.messages, list), CFEqual(region.pane, pane) else { return false }
        return selectedComposer.map { CFEqual($0, region.composer) } ?? true
    }
    /// 只在提交后的核验阶段允许有预算的重绑。两次结构解析须同一标题与同一组句柄，
    /// 不修改已经绑定的实际会话名，不投递任何新发送指令。
    @discardableResult
    private func rebindSelectedConversation() -> Bool {
        guard submitted, sendCommandIssued, rebindBudget > 0 else { return false }
        rebindBudget -= 1
        guard let window = try? focusedWindow(), !hasName(window, "综合搜索"),
              let first = try? conversationRegion(window), ConversationMatch.exactly(first.title, selectedTitle),
              let second = try? conversationRegion(window), first.sameHandles(as: second) else { return false }
        rememberRegion(second, in: window)
        selectedComposer = second.composer
        composerStructureStable = true
        return true
    }
    private func boundRegion(_ name: String) throws -> (window: AXUIElement, region: ConversationRegion) {
        try check()
        let window = try focusedWindow()
        let region = try conversationRegion(window)
        if try handlesStillBound(window, region: region) { return (window, region) }
        // 句柄失配先重解析重绑，重绑后按同一套三重比对复核（读取失败照旧向上抛）；
        // 重绑失败、预算耗尽或复核仍对不上，才维持「已离开」的原安全语义。
        if rebindSelectedConversation() {
            let rebound = try focusedWindow()
            let region = try conversationRegion(rebound)
            if try handlesStillBound(rebound, region: region) { return (rebound, region) }
        }
        throw AppError("已离开刚选中的第一条会话「\(selectedTitle)」，操作暂停")
    }
    private func ensureRecipient(_ name: String) throws -> AXUIElement { try boundRegion(name).window }
    /// 每次读输入框都确认实际顶部会话、同一聊天容器和原输入框仍绑定；
    /// 占位描述可能陈旧，不能用它把正确的当前聊天区误判成左侧联系人。
    /// 抛错信息不含“已离开”。图片轮询和发送后核验都把这一拍当成还不能下结论；
    /// 真正离开刚选中的会话才立刻停止。发送前的绑定失败不走这里。
    private func boundEditor(_ recipient: String) throws -> AXUIElement {
        // 一个完整快照同时完成唯一性、几何、顶部身份与原句柄核对，避免每拍重复遍历三次窗口。
        let (_, region) = try boundRegion(recipient)
        let editor = region.composer
        let marked = (try axRead(editor, kAXDescriptionAttribute) as? String) ?? ""
        guard ComposerSession.accepts(description: marked, title: selectedTitle,
                                      sameEditor: selectedComposer.map { CFEqual($0, editor) } == true,
                                      bindingsIntact: true, structuredBinding: composerStructureStable) else {
            throw AppError("输入框当前标注为「\(marked.isEmpty ? "未标注会话" : marked)」，与已选中的「\(selectedTitle)」不一致")
        }
        return editor
    }
    private func composerMatchesSelected(_ input: AXUIElement, in window: AXUIElement) throws -> Bool {
        let region = try conversationRegion(window)
        guard CFEqual(input, region.composer) else { return false }
        let marked = (try axRead(input, kAXDescriptionAttribute) as? String) ?? ""
        return ComposerSession.accepts(description: marked, title: selectedTitle,
                                       sameEditor: selectedComposer.map { CFEqual($0, input) } == true,
                                       bindingsIntact: try handlesStillBound(window, region: region), structuredBinding: composerStructureStable)
    }
    /// 粘贴与发送前连续核对实际标题和同一聊天区域的完整结构。
    /// 输入框、消息区或容器变化时停止，绝不根据占位名称重新选择会话。
    private func requireComposerBound(_ name: String, seconds: Double = 3, draftMayExist: Bool = false) async throws -> AXUIElement {
        var lastName = ""
        var stableReads = 0
        var stableInput: AXUIElement?
        var unreadable = false
        var ready: AXUIElement?
        let timeout = "QQ 输入框切换等待超时"
        do {
            try await until(timeout, seconds: seconds, onTransient: {
                stableReads = 0; stableInput = nil; unreadable = true
            }) {
                do {
                    let input = try self.boundEditor(name)
                    unreadable = false
                    lastName = self.string(input, kAXDescriptionAttribute)
                    stableReads = stableInput.map { CFEqual($0, input) } == true ? stableReads + 1 : 1
                    stableInput = input
                    if stableReads >= 2 { ready = input; return true }
                } catch let error as AppError {
                    guard error.message == "未能唯一定位 QQ 消息输入框，请关闭其他弹窗" else { throw error }
                    unreadable = true; stableReads = 0; stableInput = nil
                }
                return false
            }
        } catch let error as AppError {
            guard error.message == timeout else { throw error }
            if unreadable { throw AppError("QQ 输入框暂不可读，已停止；\(draftMayExist ? "草稿可能已保留，未按发送键" : "未粘贴、未发送")") }
            if ConversationMatch.composerBelongs(to: selectedTitle, description: lastName) {
                throw AppError("QQ 输入框未连续稳定，已停止；\(draftMayExist ? "草稿可能已保留，未按发送键" : "未粘贴、未发送")")
            }
            throw AppError(PostSendWatch.preSendMismatchDetail(marked: lastName, selected: selectedTitle, draftMayExist: draftMayExist))
        }
        guard let ready else { throw AppError(timeout) }
        selectedComposer = ready
        return ready
    }
    /// 搜索名只用于选择第一条结果；写稿/提交前逐字核对顶部实际名和同区域输入框。
    private func requireIdentityBound(_ recipient: String, composer: AXUIElement, draftMayExist: Bool = false) throws {
        guard CFEqual(try boundEditor(recipient), composer) else {
            throw AppError("顶部实际群名或同区域输入框已变化，无法确认仍绑在刚选中的会话，已停止：\(draftMayExist ? "草稿可能已保留，未按发送键" : "未粘贴、未发送")")
        }
    }
    private func composerIsEmpty(_ e: AXUIElement) throws -> Bool {
        // QQ exposes blank paragraph/static-text nodes even when its editor is visibly empty.
        // Do not discard object-replacement characters: these can represent an attachment.
        guard let body = try axRead(e, kAXValueAttribute) as? String else {
            throw AppError("QQ 草稿正文不可读，不能将其视为空草稿")
        }
        return try ComposerContent.isEmpty(body, descendants: evidenceNodes(e).dropFirst().map { child in
            try ComposerNode(role: evidenceString(child, kAXRoleAttribute), value: evidenceString(child, kAXValueAttribute),
                             title: evidenceString(child, kAXTitleAttribute), description: evidenceString(child, kAXDescriptionAttribute))
        })
    }
    private func imageCount(_ input: AXUIElement) throws -> Int {
        ComposerContent.attachmentCount((try axRead(input, kAXValueAttribute) as? String) ?? "",
                                       imageNodes: ComposerImageCount.count(try composerImageTree(input)))
    }
    /// 图片语义仅在已绑定输入框内部读取，不在窗口/工具栏/class 集合中猜测。
    /// 无法完整读取就抛错，不将被截断的树作为准确张数。
    private func composerImageTree(_ input: AXUIElement) throws -> ComposerImageNode {
        let deadline = Date().addingTimeInterval(3)
        var visited = 0
        func read(_ element: AXUIElement, depth: Int) throws -> ComposerImageNode {
            try pauseIfAsked(at: visited)
            guard visited < 400, depth < 40, Date() < deadline else {
                throw AppError("QQ 草稿图片节点未完整读取，未发送")
            }
            visited += 1
            let role = (try axRead(element, kAXRoleAttribute) as? String) ?? ""
            let classes = (try axRead(element, "AXDOMClassList") as? [String]) ?? []
            var node = ComposerImageNode(role: role, classes: classes)
            // 已识别的附件根是一个计数单位，后代不再重复计数。
            if role == kAXImageRole || role == kAXToolbarRole ||
                (role == kAXGroupRole && classes.contains(ComposerImageCount.qqInlineImageClass)) { return node }
            node.children = try children(element).map { try read($0, depth: depth + 1) }
            return node
        }
        return try read(input, depth: 0)
    }
    /// 输入框祖先链自内向外的每层子节点（最多 4 层：够到配图预览条，也不会走进消息列表）。
    /// 读不到父节点或子节点一律抛错：拿不到祖先层不等于预览区是空的，
    /// 那样会把上一次残留的配图当成“没有残留”放过去（2-03）。
    private func ancestorChildLevels(_ input: AXUIElement, depth: Int = 4) throws -> [[AXUIElement]] {
        var levels: [[AXUIElement]] = []
        var current = input
        for _ in 0..<depth {
            guard let parent = try self.parent(of: current) else { break }
            let branches = try children(parent)
            if branches.isEmpty { break }
            levels.append(branches)
            current = parent
        }
        return levels
    }
    /// 配图预览区所在层：QQ 实测输入框父节点只有输入框自己，预览条与「会话」工具栏同级，
    /// 所以要按“祖先链里第一个带工具栏的层”来找，工具栏分支（chat-func-bar，自带 11 个图标）不计入。
    private func previewBranches(_ input: AXUIElement) throws -> [AXUIElement] {
        let levels = try ancestorChildLevels(input)
        let roles = try levels.map { try $0.map { try evidenceString($0, kAXRoleAttribute) } }
        guard !roles.flatMap({ $0 }).contains(""),
              let level = roles.firstIndex(where: { $0.contains(ComposerRegion.toolbarRole) }) else {
            throw AppError("QQ 草稿预览区未能完整定位，不能将附件视为空")
        }
        return levels[level].enumerated().filter { roles[level][$0.offset] != ComposerRegion.toolbarRole }.map(\.element)
    }
    private func domClasses(_ e: AXUIElement) -> [String] { value(e, "AXDOMClassList") as? [String] ?? [] }
    /// 输入区结构快照：图片节点、按钮、节点总数、输入框高度与出现过的 DOM 类名。
    /// 只用于“确认不了时如实交代现场”。这些数字的变化都不是图片已进草稿的证据：
    /// QQ 异步重渲染会让它们自己变化，反过来图片也可能渲染成 Chromium 根本不暴露的无名节点。
    private func composerSnapshot(_ input: AXUIElement) throws -> ComposerSnapshot {
        let branches = try previewBranches(input)
        let perBranch = try branches.map { branch -> (role: String, imageCount: Int) in
            (role(branch), try nodes(branch, limit: 400).filter { role($0) == kAXImageRole }.count)
        }
        let flat = try branches.flatMap { try nodes($0, limit: 400) }
        let editorNodes = try nodes(input, limit: 400)
        return ComposerSnapshot(images: ComposerRegion.previewImageCount(children: perBranch),
                                buttons: flat.filter { role($0) == kAXButtonRole }.count,
                                nodes: flat.count,
                                editorHeight: frameOf(input)?.height ?? 0,
                                classTokens: Array(Set((editorNodes + flat).flatMap { domClasses($0) })).sorted(),
                                characters: (value(input, "AXNumberOfCharacters") as? Int) ?? -1,
                                text: string(input, kAXValueAttribute))
    }
    private func previewRegionImageCount(_ input: AXUIElement) throws -> Int {
        let regions = try previewBranches(input).map { branch -> (role: String, imageCount: Int) in
            let images = try evidenceNodes(branch).filter { try evidenceString($0, kAXRoleAttribute) == kAXImageRole }.count
            return (try evidenceString(branch, kAXRoleAttribute), images)
        }
        return ComposerRegion.previewImageCount(children: regions)
    }
    private func submittedDraftIsEmpty(_ input: AXUIElement) throws -> Bool {
        try composerIsEmpty(input) && previewRegionImageCount(input) == 0 && !modalInWay(of: input)
    }
    private func draftImageCount(_ input: AXUIElement) throws -> Int {
        ComposerContent.imageCount(editorCount: try imageCount(input), composerImagesBefore: composerImageBaseline,
                                   composerImagesNow: try previewRegionImageCount(input))
    }
    /// 诊断入口：只读指定群的现有草稿，不激活窗口、不写入、不提交、不访问排程库。
    /// 与自动填写、人工续发共用同一个图片计数器，便于在真实 QQ 上核对实现。
    func inspectDraftImages(_ conversation: String, expectedText: String? = nil) throws -> [String: Any] {
        guard Self.trusted else { throw AppError("辅助功能未授权，无法读取草稿") }
        guard let qq = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else {
            throw AppError("QQ 未运行")
        }
        pid = qq.processIdentifier
        AXUIElementSetMessagingTimeout(appElement(), 2)
        var matches: [AXUIElement] = []
        for window in try appWindows() {
            let region: ConversationRegion
            do { region = try conversationRegion(window) }
            catch { try reraiseIfUnreadable(error); continue }
            if ConversationMatch.identityBound(candidates: [region.title], title: conversation) { matches.append(region.composer) }
        }
        guard matches.count == 1, let input = matches.first else { throw AppError("未唯一找到指定群草稿，未操作 QQ") }
        let tree = try composerImageTree(input)
        let snapshot = try composerSnapshot(input)
        var report: [String: Any] = ["conversation": conversation, "readOnly": true,
                "editorSemanticImages": ComposerImageCount.count(tree),
                "draftImages": try draftImageCount(input), "legacyAXImages": snapshot.images,
                "textLength": snapshot.text.count, "characters": snapshot.characters,
                "composerDescription": (try axRead(input, kAXDescriptionAttribute) as? String) ?? "",
                "inlineClassPresent": snapshot.classTokens.contains(ComposerImageCount.qqInlineImageClass)]
        if let expectedText { report["textMatchesPlan"] = normalized(try draftText(input)) == normalized(expectedText) }
        return report
    }
    /// 只读验证生产定位器：不激活 QQ、不聚焦、不填写或发送，不访问排程库。
    /// 两次完整结构解析和正式绑定守卫均须通过，输出不含草稿/聊天正文。
    func inspectConversationBinding(_ conversation: String) throws -> [String: Any] {
        guard Self.trusted else { throw AppError("辅助功能未授权，无法读取会话") }
        guard let qq = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else { throw AppError("QQ 未运行") }
        pid = qq.processIdentifier
        AXUIElementSetMessagingTimeout(appElement(), 2)
        var found: [(AXUIElement, ConversationRegion)] = []
        for window in try appWindows() {
            do {
                let region = try conversationRegion(window)
                if ConversationMatch.exactly(region.title, conversation) { found.append((window, region)) }
            } catch { try reraiseIfUnreadable(error) }
        }
        guard found.count == 1, let (window, first) = found.first else { throw AppError("未唯一找到顶部实际群名，未操作 QQ") }
        let second = try conversationRegion(window)
        guard first.sameHandles(as: second) else { throw AppError("会话结构读取期间变化，未操作 QQ") }
        rememberRegion(second, in: window)
        selectedComposer = second.composer
        composerStructureStable = true
        let accepted = try composerMatchesSelected(second.composer, in: window)
        let marked = (try axRead(second.composer, kAXDescriptionAttribute) as? String) ?? ""
        func frame(_ element: AXUIElement) -> [String: CGFloat] {
            guard let f = frameOf(element) else { return [:] }
            return ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height]
        }
        return ["readOnly": true, "actualTitle": second.title, "composerDescription": marked,
                "descriptionDiffers": !marked.isEmpty && !ConversationMatch.exactly(marked, second.title),
                "sameHandlesAcrossReads": true, "bindingsIntact": try handlesStillBound(window),
                "composerAccepted": accepted, "pane": frame(second.pane), "header": frame(second.header),
                "messages": frame(second.messages), "composer": frame(second.composer),
                "draftTextLength": ((try axRead(second.composer, kAXValueAttribute) as? String) ?? "").count,
                "draftImages": try draftImageCount(second.composer)]
    }
    /// 弱信号：正文逐字未变，同时出现名字指向图片的新 class，或字符数正好多出这一张图占的 1 个内联字符位。
    /// 口径必须对齐：sameVisibleText 去空白、AXNumberOfCharacters 含空白，光靠 QQ 补换行也能让
    /// “可见正文不变而字符数变多”成立，所以这里额外要求增量恰为 1；它仍只作现场记录，
    /// 绝不替代草稿区图片计数成为自动发送的依据（2-02）。
    private func weakImageSignal(before: ComposerSnapshot, now: ComposerSnapshot) -> Bool {
        guard ComposerImageSignal.sameVisibleText(before: before.text, after: now.text) else { return false }
        let classes = ComposerImageSignal.newImageClasses(before: before.classTokens, now: now.classTokens)
        let delta = before.characters >= 0 && now.characters >= 0 ? now.characters - before.characters : -1
        let inline = ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: before.characters,
                                                           charactersAfter: now.characters) && delta == 1
        return !classes.isEmpty || inline
    }
    /// 确认不了时把看到的结构如实写进记录，下一轮排查不用再靠猜。只做交代，不当确认依据。
    private func composerDiagnostic(_ input: AXUIElement, before: ComposerSnapshot? = nil, plannedText: String = "") throws -> String {
        let snapshot = try composerSnapshot(input)
        let classes = domClasses(input).joined(separator: "|")
        let characters = (value(input, "AXNumberOfCharacters") as? Int) ?? -1
        let branches = try previewBranches(input).prefix(6)
            .map { role($0) + ":" + (domClasses($0).first ?? "-") }.joined(separator: ",")
        var extra = ""
        if let before {
            let added = ComposerDiagnostic.newClasses(before: before.classTokens, now: snapshot.classTokens)
            extra = "，粘贴前图片\(before.images)/节点\(before.nodes)"
            if !added.isEmpty { extra += "，新增class=\(added.prefix(12))" }
        }
        let spare = plannedText.isEmpty ? "" : "，正文\(plannedText.count)字/字符数\(characters)/多出\(ComposerDiagnostic.extraCharacters(textLength: plannedText.count, characterCount: characters))"
        return "结构诊断：输入框class=\(String(classes.prefix(60)))，输入框图片\(try imageCount(input))/AX预览图片\(snapshot.images)/按钮\(snapshot.buttons)/节点\(snapshot.nodes)，高\(Int(snapshot.editorHeight))\(spare)\(extra)，分支[\(String(branches.prefix(150)))]"
    }
    /// QQ 的“发送到我的手机”一类确认框自带「发送」按钮；有这种弹窗时绝不触发发送。
    /// 结论走 SendGate.blockedByModal（与 CoreTests 同一口径），遍历中途读不到控件一律抛错：
    /// “扫不到弹窗”不等于“没有弹窗”。
    private func modalInWay(of composer: AXUIElement) throws -> Bool {
        let current = try focusedWindow()
        let windows = try appWindows()
        // A different ordinary chat window may have its own Send button. It is not
        // a confirmation dialog for the focused conversation.
        func attachedToCurrent(_ window: AXUIElement) throws -> Bool {
            if CFEqual(window, current) { return true }
            if try axRead(window, kAXFocusedAttribute) as? Bool == true { return true }
            var parent = window
            for _ in 0..<4 {
                guard let next = try self.parent(of: parent) else { break }
                parent = next
                if CFEqual(parent, current) { return true }
            }
            return false
        }
        var modalPresent = false
        for window in windows where !modalPresent {
            guard [try evidenceString(window, kAXRoleAttribute), try evidenceString(window, kAXSubroleAttribute)]
                .contains(where: { ["AXSheet", "AXDialog"].contains($0) }) else { continue }
            modalPresent = try attachedToCurrent(window)
        }
        let mine = try sendButton(in: composer)
        var sendButtonsOutsideComposer = 0
        // 确认弹窗不会从历史消息/成员正文里定位；编辑器后代及其余分支仍完整读取。
        for node in try nodes(current, controlsOnly: true, requireComplete: true, pruneEditor: false) {
            if [try evidenceString(node, kAXRoleAttribute), try evidenceString(node, kAXSubroleAttribute)]
                .contains(where: { ["AXSheet", "AXDialog"].contains($0) }) { modalPresent = true; break }
            guard try evidenceString(node, kAXRoleAttribute) == kAXButtonRole, try SendGate.isSendConfirmationButton(evidenceLabel(node)) else { continue }
            if let mine, CFEqual(mine, node) { continue }
            sendButtonsOutsideComposer += 1   // 当前会话输入区之外还有「发送」：不能把确认键当成发送入口
        }
        return SendGate.blockedByModal(modalPresent: modalPresent, sendButtonsOutsideComposer: sendButtonsOutsideComposer)
    }
    /// QQ may activate its main window when reopened while the populated group draft
    /// remains in a separate chat-pool window. Find that exact draft before any send.
    private func existingDraftWindow(for delivery: Delivery) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(6)
        while true {
            try check()
            let windows = try appWindows()
            var matches: [AXUIElement] = []
            for window in windows {
                guard ConversationMatch.identityBound(candidates: try headerCandidates(window), title: delivery.recipient),
                      (try? chatList(window)) != nil,
                      let input = try? editor(in: window),
                      normalized(string(input, kAXValueAttribute)) == normalized(delivery.text) else { continue }
                matches.append(window)
            }
            guard matches.count <= 1 else { throw AppError("QQ 有多个相同的目标草稿窗口，未发送") }
            if let target = matches.first {
                if let focused = try? focusedWindow(), !CFEqual(focused, target) {
                    _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
                    try await wait(0.2)
                }
                if let focused = try? focusedWindow(), CFEqual(focused, target) { return target }
            }
            guard Date() < deadline else { break }
            enableContentTree()
            try await wait(0.25)
        }
        throw AppError("QQ 未能切到含有这条完整草稿的目标会话窗口，未发送")
    }
    /// 只在输入区那一层里找发送按钮，避免把消息列表或群公告里的同名节点当成发送入口。
    private func sendButton(in composer: AXUIElement) throws -> AXUIElement? {
        for branch in try previewBranches(composer) {
            if let found = try firstNode(branch, matching: { element in
                role(element) == kAXButtonRole && SendAttempt.isSendButtonLabel(label(element))
                    && value(element, kAXEnabledAttribute) as? Bool != false && frameOf(element) != nil
            }) { return found }
        }
        return nil
    }
    /// 发出本任务唯一的一条发送指令：认得准 QQ「发送」按钮就点按钮，认不出才按一次 Return。
    /// 这里不存在“没发出去就再按一次”的分支；核验与人工核对在调用方完成。
    private func checkpointBeforeSend() throws {
        try beforeSubmit()
        submitted = true
        actualTriggerAt = Date()
    }
    private func verifyDraftBeforeSubmit(_ delivery: Delivery, composer: AXUIElement) throws -> AXUIElement? {
        finalSubmitRead = true
        defer { finalSubmitRead = false }
        try requireIdentityBound(delivery.recipient, composer: composer, draftMayExist: true)
        guard let focused = focusedElement(), CFEqual(focused, composer) else {
            throw AppError("提交前 QQ 输入焦点已变化，已保留草稿，未发送")
        }
        if try modalInWay(of: composer) { throw AppError("提交前 QQ 出现附件弹窗，已保留草稿，未发送") }
        let send = try sendButton(in: composer)
        // 身份、弹窗和按钮扫描完成之后才读最终图文；后面不再处理排队的界面事件。
        let text = try draftText(composer)
        let allImages = delivery.assets.allSatisfy(\.isImage)
        let images = allImages ? try draftImageCount(composer) : nil
        try QQDraftPreflight.validate(text: text, expectedText: delivery.text, images: images,
                                     expectedImages: allImages ? delivery.assets.count : nil)
        // QQ 仍可能自行重渲染，正文和图片必须再次读到同一份内容。
        try QQDraftPreflight.validate(text: try draftText(composer), expectedText: delivery.text, images: images,
                                     expectedImages: allImages ? delivery.assets.count : nil)
        let lastImages = allImages ? try draftImageCount(composer) : nil
        try QQDraftPreflight.validate(text: try draftText(composer), expectedText: delivery.text, images: lastImages,
                                     expectedImages: allImages ? delivery.assets.count : nil)
        guard let focused = focusedElement(), CFEqual(focused, composer) else {
            throw AppError("提交前 QQ 输入焦点已变化，已保留草稿，未发送")
        }
        try check()
        return send
    }
    private func fireSend(delivery: Delivery, composer: AXUIElement) async throws -> SendTrigger {
        let recipient = delivery.recipient
        // sendCommandIssued 是本类内唯一的“已经下过发送指令”不变量：任何第二条发送路径先被这里挡住。
        guard !sendCommandIssued else { throw AppError("这条任务已经发出过一条发送指令，拒绝再次触发；请核对 QQ") }
        var readyEditor: AXUIElement?
        var readyButton: AXUIElement?
        let finalDeadline = Date().addingTimeInterval(3)
        // 所有 await 都在检查点之前；读数暂失效仅重新核对，粘贴/提交均不会重放。
        while true {
            try await until("QQ 提交前界面尚未稳定，已保留草稿，未发送", seconds: max(0, finalDeadline.timeIntervalSinceNow)) {
                let current = try self.boundEditor(recipient)
                guard CFEqual(current, composer), let focused = self.focusedElement(), CFEqual(focused, current) else {
                    throw AppError("提交前 QQ 输入框或焦点已变化，已保留草稿，未发送")
                }
                if try self.modalInWay(of: current) { throw AppError("QQ 在发送前弹出附件确认窗口，未按发送键；请核对草稿") }
                readyButton = try self.verifyDraftBeforeSubmit(delivery, composer: current)
                readyEditor = current
                return true
            }
            guard let readyEditor else { throw AppError("QQ 提交前草稿不可读，未发送") }
            // await 返回的调度边界也可能让界面变化；最后一次核验必须在调用方同步完成。
            try pauseIfAsked(at: PausePoint.nodeStride)
            do {
                readyButton = try verifyDraftBeforeSubmit(delivery, composer: readyEditor)
                break
            } catch {
                guard QQTransitionRead.isTransient(error), Date() < finalDeadline else { throw error }
            }
        }
        switch SendAttempt.firstTrigger(buttonFound: readyButton != nil) {
        case .sendButton:
            guard let button = readyButton else { throw AppError("QQ 发送按钮在按下前消失，未发送") }
            try checkpointBeforeSend()
            sendCommandIssued = true
            try click(button)
            onStep("已点击 QQ 发送按钮，等待 QQ 发出")
            return .sendButton
        case .returnKey:
            try checkpointBeforeSend()
            sendCommandIssued = true
            try key(Key.returnKey)
            onStep("已按 Return，等待 QQ 发送")
            try await verifyEventLanded()
            return .returnKey
        }
    }

    /// 把“粘贴后固定睡 0.5 秒再核对”换成轮询：正文到位就立刻返回，最多等 seconds 秒。
    /// 超时不再当成“返回成功”（旧版返回 window 会让新调用点忘记硬核对）：核对收进函数内，
    /// 判定条件与原来的逐字比较完全一致。
    private func confirmDraftText(_ recipient: String, _ text: String, seconds: Double = 2, failure: String) async throws {
        var editorIssue: String?
        do {
            try await until(failure, seconds: seconds) {
                do {
                    let input = try self.boundEditor(recipient)
                    editorIssue = nil
                    return self.normalized(try self.draftText(input)) == self.normalized(text)
                } catch let error as AppError {
                    if QQTransitionRead.isTransient(error) { throw error }
                    guard PostSendWatch.reaction(toEditorError: error.message) != .abort else { throw error }
                    editorIssue = error.message
                    return false
                }
            }
        } catch let error as AppError {
            if error.message == failure {
                if let editorIssue {
                    let marked = PostSendWatch.observedLabel(in: editorIssue)
                    if let marked {
                        throw AppError(PostSendWatch.preSendMismatchDetail(marked: marked, selected: selectedTitle, draftMayExist: true))
                    }
                    throw AppError("QQ 输入框在核对草稿时暂不可读，草稿可能已保留，未按发送键")
                }
            }
            throw error
        }
    }
    private func draftText(_ input: AXUIElement) throws -> String {
        guard let text = try axRead(input, kAXValueAttribute) as? String else {
            throw AppError("QQ 草稿正文不可读，已保留草稿，未发送")
        }
        return text
    }
    private func ensureEmpty(_ e: AXUIElement) throws {
        // 空草稿守卫必须用与配图确认同一套预览区口径：残留图片若被当成基线折掉，
        // 就会和本次计划的图一起发出去。工具栏图标不计入，实测空草稿该区域为 0。
        guard try composerIsEmpty(e), try previewRegionImageCount(e) == 0 else {
            // 只报计数与字符类别：这条记录会进备份，码点能无损还原用户草稿正文。
            let text = string(e, kAXValueAttribute)
            let visible = normalized(text)
            let kind = visible.first.map { character -> String in
                if character.isNumber { return "数字" }
                if character.isLetter { return character.isASCII ? "字母" : "中日韩文字" }
                if character.isPunctuation { return "标点" }
                return "符号"
            } ?? "无"
            let structure = childrenOrEmpty(e).prefix(8).map { role($0) + ":" + String(string($0,kAXValueAttribute).count) }.joined(separator:",")
            throw AppError("QQ 输入框检测到草稿或附件，已保留；请先手动处理。诊断：非空正文\(visible.count)字（首个字符类别\(kind)）/字符数\((value(e, "AXNumberOfCharacters") as? Int) ?? -1)，children=\(structure)")
        }
    }
    private func chatList(_ w: AXUIElement) throws -> AXUIElement {
        try conversationRegion(w).messages
    }
    private func postSendNotices(_ window: AXUIElement) throws -> [String] {
        let all = try evidenceNodes(try chatList(window))
        var notices: [String] = []
        for element in all {
            if try evidenceClasses(element).contains("gray-tip-content") {
                // QQ 会把“你”和“撤回了一条消息”拆成不同文字节点，按系统提示整行读取。
                let text = try evidenceNodes(element).filter { try [kAXStaticTextRole, "AXLink"].contains(evidenceString($0, kAXRoleAttribute)) }
                    .map { try evidenceLabel($0).trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
                if PostSendNotice.kind(label: text, systemNotice: true) != nil { notices.append("notice:" + text) }
                continue
            }
            guard try [kAXStaticTextRole, kAXImageRole, kAXButtonRole].contains(evidenceString(element, kAXRoleAttribute)) else { continue }
            var current = element
            var insideNotice = false
            var errorControl = try [kAXImageRole, kAXButtonRole].contains(evidenceString(element, kAXRoleAttribute))
            for _ in 0..<5 {
                if try evidenceClasses(current).contains(where: { $0.contains("msg-fail") || $0.contains("send-fail") || $0.contains("message-fail") }) { errorControl = true }
                if try evidenceClasses(current).contains(where: { $0.hasPrefix("gray-tip") }) { insideNotice = true; break }
                guard let next = try self.parent(of: current) else { break }
                current = next
            }
            let text = try evidenceLabel(element)
            if !insideNotice, PostSendNotice.kind(label: text, systemNotice: false, errorControl: errorControl) != nil { notices.append("control:" + text) }
        }
        return notices
    }
    private func noticeKind(_ notice: String) -> PostSendNotice.Kind? {
        PostSendNotice.kind(label: String(notice.dropFirst(notice.hasPrefix("notice:") ? 7 : 8)), systemNotice: notice.hasPrefix("notice:"), errorControl: notice.hasPrefix("control:"))
    }
    private func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" } }
    /// 只接受系统辅助功能提供的滚动位置；缺少该属性不猜测“当前列表末尾就是最新”。
    private func timelineIsAtLatest(_ list: AXUIElement) throws -> Bool {
        var current = list
        for _ in 0..<4 {
            if try evidenceString(current, kAXRoleAttribute) == kAXScrollAreaRole,
               let raw = try axRead(current, kAXVerticalScrollBarAttribute),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let bar = unsafeBitCast(raw, to: AXUIElement.self)
                guard try evidenceString(bar, kAXRoleAttribute) == kAXScrollBarRole,
                      try evidenceString(bar, kAXOrientationAttribute) == "AXVerticalOrientation",
                      let position = try axRead(bar, kAXValueAttribute) as? NSNumber,
                      let maximum = try axRead(bar, kAXMaxValueAttribute) as? NSNumber,
                      let minimum = try axRead(bar, kAXMinValueAttribute) as? NSNumber else { return false }
                let value = position.doubleValue, maxValue = maximum.doubleValue, minValue = minimum.doubleValue
                guard value.isFinite, maxValue.isFinite, minValue.isFinite, maxValue >= minValue else { return false }
                return abs(value - maxValue) <= 0.000001 * max(1, maxValue - minValue)
            }
            guard let next = try parent(of: current) else { break }
            current = next
        }
        return false
    }
    /// 完整时间线行及本人消息的只读快照；属性读取失败、截断或缺 ID 均拒绝基线。
    private func messageSnapshot(_ window: AXUIElement, text: String, deadline: Date? = nil) throws -> (snapshot: QQMessageSnapshot, texts: [String: [String]]) {
        let readDeadline = deadline ?? Date().addingTimeInterval(8)
        var readCount = 0
        func checkRead() throws {
            guard Date() < readDeadline else { throw AppError("QQ 消息核验读取超时，未把不完整结果当作成功") }
            readCount += 1
            try pauseIfAsked(at: readCount)
        }
        let target = normalized(text)
        var rows: [String] = []
        var own: [OwnMessageProof] = []
        var texts: [String: [String]] = [:]
        let list = try chatList(window)
        let atLatest = try timelineIsAtLatest(list)
        for element in try evidenceNodes(list) {
            try checkRead()
            let classes = try evidenceClasses(element)
            if classes.contains("ml-item") {
                let id = try evidenceString(element, "AXDOMIdentifier")
                guard !id.isEmpty else { throw AppError("QQ 消息行缺少稳定 ID，不能确认本次新增消息") }
                rows.append(id)
            }
            guard classes.contains("message-container--self") else { continue }
            var ancestor = element
            var id = ""
            var row: AXUIElement?
            for _ in 0..<4 {
                try checkRead()
                if try evidenceClasses(ancestor).contains("ml-item") {
                    id = try evidenceString(ancestor, "AXDOMIdentifier"); row = ancestor; break
                }
                guard let next = try parent(of: ancestor) else { break }
                ancestor = next
            }
            guard !id.isEmpty, let row else { throw AppError("QQ 本人消息缺少所属行 ID，不能核验") }
            var values: [String] = []
            var images = 0
            for child in try evidenceNodes(element) {
                try checkRead()
                let value = try evidenceString(child, kAXValueAttribute)
                let title = try evidenceString(child, kAXTitleAttribute)
                let description = try evidenceString(child, kAXDescriptionAttribute)
                values.append(contentsOf: [value, title, description].filter { !$0.isEmpty })
                if try evidenceString(child, kAXRoleAttribute) == kAXImageRole,
                   try evidenceClasses(child).contains("pic-element") { images += 1 }
            }
            let rowNodes = try evidenceNodes(row)
            var rowClasses: [String] = [], controls: [String] = [], timeLabels: [String] = []
            var busy = false, progress = false
            for node in rowNodes {
                try checkRead()
                let tokens = try evidenceClasses(node)
                rowClasses.append(contentsOf: tokens)
                let role = try evidenceString(node, kAXRoleAttribute)
                busy = (try axRead(node, "AXElementBusy") as? Bool == true) || busy
                progress = role == kAXProgressIndicatorRole || progress
                // The timestamp lives outside the body in this row's dedicated wrapper.
                if tokens.contains("message__timestamp") {
                    for child in try evidenceNodes(node) where try evidenceString(child, kAXRoleAttribute) == kAXStaticTextRole {
                        try checkRead()
                        let label = try evidenceString(child, kAXValueAttribute)
                        if label.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil { timeLabels.append(label) }
                    }
                }
                if role == kAXButtonRole || role == kAXImageRole || role == kAXProgressIndicatorRole {
                    controls.append(contentsOf: [try evidenceString(node, kAXTitleAttribute), try evidenceString(node, kAXDescriptionAttribute)])
                }
            }
            let phase = QQSendPhase.read(structured: rowClasses.contains("message-content") && rowClasses.contains("message-content__wrapper"),
                classes: rowClasses, controlLabels: controls, busy: busy, progress: progress)
            own.append(OwnMessageProof(id: id, textMatches: !target.isEmpty && values.contains { normalized($0) == target }, images: images,
                phase: phase, timeLabel: timeLabels.count == 1 ? timeLabels[0] : nil,
                timezoneOffset: TimeZone.current.secondsFromGMT(for: Date())))
            texts[id] = values
        }
        let stillLatest = try timelineIsAtLatest(list)
        try checkRead()
        let snapshot = QQMessageSnapshot(rowIDs: rows, ownMessages: own, atLatest: atLatest && stillLatest)
        guard snapshot.isTrustworthy else { throw AppError("QQ 消息基线不完整或 ID 重复，不能确认本次新增消息") }
        return (snapshot, texts)
    }
    private func qqVersion() -> String {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return "" }
        return version + "-" + build
    }
    /// Diagnostic only: inspect one explicitly selected conversation's message rows without events.
    func inspectPostSend(_ conversation: String, expectedText: String, submittedAt: Date) throws -> [String: Any] {
        _ = try inspectConversationBinding(conversation)
        guard let window = selectedWindow else { throw AppError("未绑定会话") }
        let sample = try messageSnapshot(window, text: expectedText)
        let own = sample.snapshot.ownMessages.filter(\.textMatches).map { proof -> [String: Any] in
            ["messageID": proof.id, "images": proof.images, "phase": proof.phase.rawValue,
             "timeLabel": proof.timeLabel ?? "", "creationSeconds": QQMessageClock.creation(proof.id)?.timeIntervalSince1970 ?? 0,
             "freshForSubmission": QQMessageClock.isFresh(proof, submittedAt: submittedAt, observedAt: Date(), version: qqVersion())]
        }
        return ["readOnly": true, "conversation": selectedTitle, "qqVersion": qqVersion(), "atLatest": sample.snapshot.atLatest,
                "rowIDs": sample.snapshot.rowIDs, "matchingOwnMessages": own]
    }
    /// 发出指令前必须连续读取同一尾部，不能把加载一半的旧消息当成发送基线。
    private func stableMessageBaseline(_ recipient: String, text: String) async throws -> QQMessageSnapshot {
        var previous: QQMessageSnapshot?
        var ready: QQMessageSnapshot?
        try await until("QQ 消息列表尚未稳定，已保留草稿，未发送", seconds: 3, onTransient: { previous = nil }) {
            let current = try messageSnapshot(ensureRecipient(recipient), text: text).snapshot
            if previous == current { ready = current; return true }
            previous = current
            return false
        }
        guard let ready else { throw AppError("QQ 消息基线尚未完整读取，未发送") }
        return ready
    }
    private func signature(_ w: AXUIElement, text: String) throws -> (matches: Int, images: Int) {
        let ns = try nodes(try chatList(w))
        let target = normalized(text)
        return (target.isEmpty ? 0 : ns.filter { normalized(string($0, kAXValueAttribute)) == target || normalized(string($0, kAXTitleAttribute)) == target }.count,
                ns.filter { role($0) == kAXImageRole }.count)
    }
    private func attach(_ asset: Asset, url: URL, recipient: String, plannedText: String? = nil, tolerateUnconfirmedImage: Bool = false) async throws {
        onStep(asset.isImage ? AttachWait.preparing(name: asset.name) : "正在加入附件：\(asset.name)")
        if asset.isImage {
            // Put actual image data on the clipboard, not a filename that QQ could upload immediately.
            // TIFF + PNG 双格式：部分 QQ 构建不吃裸 TIFF，只写单一格式会让 Cmd+V 静默无效
            // 全尺寸解码与重编码挪到后台队列（2-19 (a)）：这里抛错就停在这一步，剪贴板与草稿都还没动过。
            let payload = try await ImageAttachment.clipboardPayload(at: url)
            try check()
            let tiff = payload.tiff, png = payload.png
            let input = try await requireComposerBound(recipient, draftMayExist: true)
            try await focus(input)
            try key(Key.moveToTextEnd, flags: .maskCommand)
            // 聚焦只执行一次；临时控件失效只重新读取，不重复粘贴正文或图片。
            var count = 0
            var before = ComposerSnapshot()
            try await until("QQ 草稿图片区尚未就绪，图片未粘贴", seconds: 3) {
                let current = try self.boundEditor(recipient)
                if try self.modalInWay(of: current) { throw AppError("QQ 出现附件弹窗，图片未粘贴，未发送") }
                guard let focused = self.focusedElement(), CFEqual(focused, current) else {
                    throw AppError("粘贴图片前 QQ 输入焦点已变化，图片未粘贴，未发送")
                }
                count = try self.draftImageCount(current)
                before = try self.composerSnapshot(current)
                before.text = try self.draftText(current)
                if let plannedText {
                    try QQDraftPreflight.validateConstruction(text: before.text, expectedText: plannedText, images: count,
                        confirmedImages: self.confirmedImages, pasteCommands: self.imagePasteCommands,
                        toleratePending: tolerateUnconfirmedImage && self.imageLeftUnconfirmed)
                }
                return true
            }
            // 等待预算按真正交给 QQ 的载荷算：QQ 收到的是全尺寸重编码 TIFF，不是磁盘上的原文件，
            // 用 asset.bytes 会系统性低估（3MB JPG ≈ 48MB TIFF），大图必然超时（2-15）。
            let seconds = AttachWait.budget(bytes: Int64(tiff.count))
            func pasteAndConfirm() async throws {
                let pb = NSPasteboard.general; pb.clearContents()
                guard pb.setData(tiff,forType:.tiff), pb.setData(png,forType:.png) else {
                    clipboardVersion = pb.changeCount
                    throw AppError("图片写入剪贴板失败，图片未粘贴，未发送")
                }
                clipboardVersion = pb.changeCount
                try key(Key.paste, flags: .maskCommand)
                self.imagePasteCommands += 1
                let started = Date()
                var reported = ""
                try await QQTransitionRead.waitForStable(message: "图片未进入草稿：\(asset.name)，没有继续发送", seconds: seconds,
                    beforeRead: { try await self.recoverOwnForegroundIfNeeded() },
                    pause: { try await self.pauseAttachPoll(0.2) }) {
                    let line = AttachWait.line(name: asset.name, elapsed: Date().timeIntervalSince(started), budget: seconds)
                    if line != reported { reported = line; onStep(line) }
                    do {
                        let current = try self.boundEditor(recipient)
                        if try self.modalInWay(of: current) { throw AppError("QQ 出现附件确认窗口，未发送；请保留草稿手动处理") }
                        // 一次粘贴后只读完整图数和正文；连续两拍满足才通过，失效或缺图清掉前一拍。
                        return try self.draftImageCount(current) == count + 1
                            && ComposerImageSignal.sameVisibleText(before: before.text, after: self.draftText(current))
                    } catch let error as AppError {
                        if QQTransitionRead.isTransient(error) { throw error }
                        guard PostSendWatch.reaction(toEditorError: error.message) != .abort else { throw error }
                        return false
                    }
                }
                self.confirmedImages += 1
                self.onStep("图片已进入 QQ 草稿并连续核对：\(asset.name)")
            }
            do { try await pasteAndConfirm() }
            catch let error as AppError {
                guard error.localizedDescription.hasPrefix("图片未进入草稿") else { throw error }
                // A second paste can create two copies of a picture that AX did not expose.
                // 不用超时后的单帧读数或弱信号放行：完整计数须在上面的两帧检查通过。
                if let current = try? boundEditor(recipient), try modalInWay(of: current) {
                    throw AppError("QQ 弹出了附件确认窗口，图片不算进入当前群草稿；未发送")
                }
                // 草稿模式不会发送任何消息：图片确认不了也照样填好，但必须如实写在结果里，交人目视核对
                if tolerateUnconfirmedImage { imageLeftUnconfirmed = true; return }
                // 只认正向图片信号（输入框内 AXImage / U+FFFC / 输入区里非工具栏的图片节点）。
                // 节点数、按钮数、输入框高度变多都不能算图片已进草稿：QQ 异步重渲染会造成这些变化，
                // 反过来图片也可能渲染成 Chromium 不暴露的无名 div。确认不了就停，交人工核对。
                if let current = try? boundEditor(recipient) {
                    throw AppError("无法确认图片是否进入 QQ 草稿：\(asset.name)。文字和现有草稿已保留，未重复粘贴图片；请在 QQ 核对后手动处理。\(try composerDiagnostic(current, before: before))")
                }
                throw AppError("无法确认图片是否进入 QQ 草稿：\(asset.name)。文字和现有草稿已保留，未重复粘贴图片；请在 QQ 核对后手动处理")
            }
            return
        }
        let w = try ensureRecipient(recipient)
        let buttonName = asset.isImage ? "图片" : "文件"
        guard let button = try nodes(w).first(where: { role($0) == kAXButtonRole && label($0) == buttonName }) else { throw AppError("找不到 QQ \(buttonName)按钮") }
        try click(button); try await wait(0.7)
        let openWindow = try focusedWindow()
        guard try nodes(openWindow).contains(where: { string($0, kAXIdentifierAttribute) == "open-panel" || (role($0) == kAXButtonRole && label($0) == "打开") }) else { throw AppError("QQ 未显示标准文件选择窗口，请手动处理当前弹窗") }
        try key(Key.goToFolder, flags: [.maskCommand, .maskShift]); try await wait()
        let pathNodes = try nodes(try focusedWindow())
        guard let pathField = pathNodes.first(where: { string($0, kAXIdentifierAttribute) == "PathTextField" }) else { throw AppError("无法定位文件路径输入框") }
        guard AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, url.path as CFString) == .success else { throw AppError("文件路径填写失败") }
        try await wait()
        guard string(pathField, kAXValueAttribute) == url.path else { throw AppError("文件路径核对失败") }
        try key(Key.returnKey); try await wait(0.6)
        let fileNodes = try nodes(try focusedWindow())
        let selected = fileNodes.contains { e in (value(e, kAXSelectedAttribute) as? Bool == true) && label(e) == asset.name }
        let preview = fileNodes.contains { label($0).contains(asset.name) && (label($0).contains("预览") || string($0, kAXIdentifierAttribute).contains("Image Preview")) }
        guard selected || preview else { throw AppError("文件选择未通过核对：\(asset.name)，未打开错误文件") }
        guard let open = fileNodes.first(where: { role($0) == kAXButtonRole && label($0) == "打开" && value($0, kAXEnabledAttribute) as? Bool != false }) else { throw AppError("文件选择器打开按钮不可用") }
        // Selecting a regular file can itself send in some QQ versions. Persist uncertainty first.
        if !asset.isImage { try beforeSubmit(); submitted = true }
        try click(open); try await wait(0.8)
        _ = try ensureRecipient(recipient)
        // QQ may expose attachments as unlabeled children; never assume opening the panel submitted a file.
        let composer = try editor(in: focusedWindow())
        let draftHasNodes = !(try children(composer)).isEmpty
        guard draftHasNodes || !normalized(string(composer,kAXValueAttribute)).isEmpty else { throw AppError("附件未出现在草稿中，或 QQ 使用了额外确认窗口。请检查，未继续发送") }
    }
    /// 人工在 QQ 界面上核对过“就是这条草稿”之后的续发：不搜索、不清空、不再粘贴任何内容，
    /// 只做归属与正文的逐字核验、图片计数核对、弹窗闸门、持久化检查点，然后发出唯一一条发送指令。
    /// 计划里的图片是否真在框里，这里也用与自动发送同一套计数口径核对一遍（2-09）。
    func sendExistingDraft(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        verificationEvidence = nil
        cancelled = false; submitted = false; sendCommandIssued = false; actualTriggerAt = nil; confirmedImages = 0; imagePasteCommands = 0; weakImageSignals = 0
        selectedComposer = nil; selectedPane = nil; composerStructureStable = false; composerImageBaseline = 0; rebindBudget = 0
        guard delivery.mode == "automatic" else { throw AppError("只有自动发送任务可以按已核对草稿续发") }
        guard !delivery.text.isEmpty || !delivery.assets.isEmpty else { throw AppError("这条任务没有内容") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请解锁后继续") }
        try await openQQ()
        let window = try await existingDraftWindow(for: delivery)
        // 对已存在的草稿建立两拍绑定：精确标题、同一窗口/消息列表、唯一同一输入框、完整计划正文。
        // 使用实际顶部群名和同源聊天区域，不使用 QQ 陈旧的编辑器占位名称建立新锚点。
        try rememberConversation(window, title: delivery.recipient)
        guard ConversationMatch.exactly(selectedTitle, delivery.recipient) else { throw AppError("草稿会话标题与任务不一致，未发送") }
        var stableInput: AXUIElement?
        var stableReads = 0
        try await until("现有草稿未连续稳定绑定，未发送", seconds: 3, onTransient: {
            stableInput = nil; stableReads = 0
        }) {
            let currentWindow = try self.ensureRecipient(delivery.recipient)
            let input = try self.editor(in: currentWindow)
            guard self.normalized((try self.axRead(input, kAXValueAttribute) as? String) ?? "") == self.normalized(delivery.text) else {
                throw AppError("现有草稿正文发生变化，未发送")
            }
            stableReads = stableInput.map { CFEqual($0, input) } == true ? stableReads + 1 : 1
            stableInput = input
            return stableReads >= 2
        }
        guard let composer = stableInput else { throw AppError("现有草稿输入框不可读，未发送") }
        selectedComposer = composer
        composerStructureStable = true
        // 归属核验：顶部实际群名逐字对应任务，唯一原输入框仍在同一可见聊天区。
        let marked = string(composer, kAXDescriptionAttribute)
        guard try composerMatchesSelected(composer, in: window) else {
            throw AppError("当前输入框属于「\(marked.isEmpty ? "未标注会话" : marked)」，不是任务收件群「\(delivery.recipient)」，未发送")
        }
        guard ConversationMatch.headerMatches(candidates: try headerCandidates(window), title: delivery.recipient) else {
            throw AppError("标题栏读不到「\(delivery.recipient)」，可能不是同一个会话窗口，未发送")
        }
        // 正文核验：草稿必须就是计划里的那段文字，一字不差（忽略换行与零宽字符）
        let draft = string(composer, kAXValueAttribute)
        // 空草稿守卫只看文字会把“只发图片”的任务（正文留空，见使用说明）误判为空的；
        // 图片信号为 0 才算真的没内容。
        let draftImages = max(try imageCount(composer), try previewRegionImageCount(composer))
        guard !normalized(draft).isEmpty || draftImages > 0 else { throw AppError("QQ 草稿是空的，没有可发送的内容，未发送") }
        guard normalized(draft) == normalized(delivery.text) else {
            throw AppError("QQ 草稿正文与这条任务的计划文字不一致，未发送。\(try composerDiagnostic(composer, plannedText: delivery.text))")
        }
        // 计划里带图片的任务：续发前按同一条计数口径核对一次，缺图就停。
        // 事后核验无法撤回，只标 uncertain 等于把缺图的消息发出去了（2-09）。
        let plannedImages = delivery.assets.filter(\.isImage).count
        if plannedImages > 0, draftImages != plannedImages {
            throw AppError("草稿图片数量与这条任务计划的 \(plannedImages) 张不一致（当前 \(draftImages) 张），已停止：未按发送键。\(try composerDiagnostic(composer, plannedText: delivery.text))")
        }
        // 弹窗闸门：确认框自带「发送」时绝不按键
        if try modalInWay(of: composer) {
            throw AppError("QQ 出现了带「发送」按钮的确认弹窗，未按键；请先手动关闭该弹窗")
        }
        // 绑定这个实际会话，后续核验沿用同一套前台/会话/消息列表检查
        try rememberConversation(window, title: delivery.recipient)
        selectedHeader = selectedHeader ?? window
        let baseline = try signature(window, text: delivery.text)
        let beforeLabels = try postSendNotices(window)
        let beforeMessages = try await stableMessageBaseline(delivery.recipient, text: delivery.text)
        onStep("草稿已按人工核对确认，准备提交：\(delivery.recipient)")
        try await focus(composer)
        guard let f = focusedElement(), CFEqual(f, try editor(in: focusedWindow())),
              try composerMatchesSelected(f, in: focusedWindow()) else {
            throw AppError("发送前输入焦点或所属会话变化，已停止")
        }
        guard let focused = focusedElement(), CFEqual(focused, try editor(in: focusedWindow())),
              try composerMatchesSelected(focused, in: focusedWindow()) else {
            throw AppError("发送前输入框归属再次变化，未按下任何发送键；请核对 QQ 草稿，不会自动重发")
        }
        let submittedList = selectedMessageList
        let attempted: [SendTrigger] = [try await fireSend(delivery: delivery, composer: focused)]
        guard let submittedClock = actualTriggerAt else { throw AppError("缺少实际发送检查点") }
        return try await confirmAfterTrigger(delivery: delivery, submittedClock: submittedClock, submittedList: submittedList, beforeMessages: beforeMessages, baseline: baseline, beforeLabels: beforeLabels, submittedEditor: f, trigger: SendAttempt.describe(attempted: attempted), manual: true) {
            "\(Date().formatted()) · 人工核对草稿后续发：会话「\(delivery.recipient)」逐字一致；草稿已清空；消息列表最末新增一条本人消息，正文逐字一致、图片张数达标。仅为客户端可见核验，不是服务器送达回执"
        }
    }

    /// 只读检查：不点击、不按键、不发送。会按 Electron 的文档化开关请求 QQ 暴露完整控件树，
    /// 可能让 QQ 短时占 CPU。诊断结束后把 pid 恢复原值，不让点一下诊断改变发送目标进程。
    func diagnostic() -> String {
        guard Self.trusted else { return "辅助功能权限：未授权。请在设置中允许本软件控制 QQ。" }
        guard !Self.locked else { return "Mac 已锁屏" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else { return "QQ 未运行，请手动打开并登录" }
        let previousPID = pid
        pid = app.processIdentifier
        defer { pid = previousPID }
        enableContentTree()
        let root = appElement()
        let windows = value(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let summaries = windows.map { window -> String in
            let controls = (try? nodes(window)) ?? []
            let found = controls.contains { role($0) == kAXTextFieldRole && hasName($0,"搜索") }
            let position: String
            do {
                position = try timelineIsAtLatest(chatList(window))
                    ? "已取得最新消息位置依据"
                    : "没有可读的最新消息位置依据；发送结果需人工核对，不能自动标为完成"
            } catch {
                position = "无法完整读取消息核验依据；不会据此自动标为完成"
            }
            return "窗口：\(label(window))；可读取控件：\(controls.count)；搜索框：\(found ? "已找到" : "未找到")；\(position)"
        }
        return "辅助功能权限：已授权\nQQ 进程：\(app.processIdentifier)\n完整控件树请求：\(accessibilityStatus.rawValue)\n窗口数：\(windows.count)\n" + summaries.joined(separator:"\n") + "\n0 表示控件树请求成功；非 0 不等于未登录。检查不会点击、不会按键、不会发送消息，也不读取密码；会请求 QQ 暴露完整控件树，可能短时占用 CPU。"
    }
    func openQQ() async throws {
        if let refusal = DispatchProbe.refusal(entry: "打开 QQ") { throw AppError(refusal) }
        cancelled = false
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        onStep("正在打开 QQ")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.tencent.qq") else { throw AppError("未找到已安装的 QQ") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        // Launch Services handles an already-running background QQ too. activate() alone can be declined on modern macOS.
        let qq = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
        pid = qq.processIdentifier
        qq.unhide()
        try Task.checkCancellation()
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let restored = await ChatWindowPresentation.setMinimized(false, app: qq)
        guard restored.complete else { throw AppError("QQ 窗口未能自动展开，请手动展开后再试；未发送") }
        // Launch Services 回调不等于激活和窗口出现已完成。只等待初次交接，
        // 只展开 QQ 自身窗口；后续阶段照常立即阻止前台被切走。
        let activationDeadline = Date().addingTimeInterval(5)
        while observedFrontPID() != pid && observedFrontPID() != ProcessInfo.processInfo.processIdentifier && Date() < activationDeadline {
            try Task.checkCancellation()
            if cancelled { throw AppError("已停止") }
            if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await activateForClick()
        enableContentTree()
        onStep("等待 QQ 完整控件树")
        try await until("QQ 进程存在，但界面控件尚未就绪；请打开主窗口。无需再次登录",seconds:8) {
            guard let window = try self.focusedWindowIfAvailable() else { return false }
            return try self.firstNode(window, matching: { self.role($0) == kAXTextFieldRole || self.role($0) == kAXTextAreaRole }) != nil
        }
    }
    /// 结果行是否回显了本次查询词（QQ 会把命中片段渲染成独立文本节点）。
    /// 只作为“结果列表已随本次查询刷新”的正向信号，不做结果唯一性与精确匹配校验
    /// （AGENTS 2026-09-26 的规则不变：按名称搜索、直接进第一条群聊结果）。
    private func resultRowEchoes(_ texts: [String], query: String) -> Bool {
        let q = normalized(query)
        guard q.count >= 2 else { return false }
        return texts.contains { normalized($0).contains(q) }
    }
    private func searchFirst(_ query: String) async throws -> SearchResult {
        var window = try focusedWindow()
        var searchAnchorWindow: AXUIElement?
        var searchAnchorFrame: CGRect?
        func nearWindowTop(_ e: AXUIElement, in w: AXUIElement) -> Bool {
            guard let f = frameOf(e), let wf = frameOf(w) else { return false }
            return f.midY - wf.minY <= max(96, wf.height * 0.22)
        }
        /// 搜索框要按元素自身辨认（角色 + 自己的标题/占位符）：窗口叫“综合搜索”不代表
        /// 窗口里每个文本框都是搜索框，把群名写进别的输入框会在别人的会话里留下草稿（2-12）。
        /// 只有综合搜索窗里匿名搜索框才允许用“窗口顶部窄带”兜底，多个候选取最靠上最靠左。
        func searchField(_ w: AXUIElement) throws -> AXUIElement? {
            let controls = try controlNodes(w, limit: 2500)
            let fields = controls.filter { role($0) == kAXTextFieldRole || string($0, kAXSubroleAttribute) == "AXSearchField" }
            let own = fields.filter { e in
                nearWindowTop(e, in: w) &&
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].contains { string(e, $0).contains("搜索") }
            }
            var candidates = own.isEmpty && hasName(w, "综合搜索") ? fields.filter { nearWindowTop($0, in: w) } : own
            // QQ NT 聚焦后会隐藏占位文字。只在已确认搜索框的同一窗口、同一位置
            // 重取这个匿名文本框，不把任意文本框或聊天输入区当成搜索框。
            if candidates.isEmpty, let anchorWindow = searchAnchorWindow, CFEqual(anchorWindow, w), let anchor = searchAnchorFrame {
                candidates = fields.filter { field in
                    guard nearWindowTop(field, in: w), let frame = frameOf(field) else { return false }
                    return QQSearchLayout.matchesAnchor(frame, anchor: anchor, window: frameOf(w))
                }
            }
            // 首次进入时搜索可能已经处于匿名/非空状态。现场的主窗口只有一个
            // 顶部搜索文本框；同时要求主窗口身份和会话列表，排除登录页及独立群聊窗。
            if candidates.isEmpty, hasName(w, "QQ"), controls.contains(where: { hasName($0, "会话列表") }) {
                let topFields = fields.filter { nearWindowTop($0, in: w) }
                if topFields.count == 1 { candidates = topFields }
            }
            return candidates.min { a, b in
                guard let fa = frameOf(a), let fb = frameOf(b) else { return frameOf(a) != nil }
                if abs(fa.minY - fb.minY) > 4 { return fa.minY < fb.minY }
                return fa.minX < fb.minX
            }
        }
        // 独立聊天窗也暴露“搜索”，但展开时会改变窗口/输入框结构。
        // 优先使用有明确 QQ 身份的主窗口；保留已经打开的综合搜索窗口。
        if !hasName(window, "综合搜索"),
           let main = try appWindows().first(where: {
               self.string($0, kAXTitleAttribute) == "QQ" && (try? searchField($0)) != nil
           }) { window = main }
        var detected = try searchField(window)
        if detected == nil {
            let windows = try appWindows()
            guard let main = windows.first(where: { (try? searchField($0)) != nil }) else { throw AppError("未找到 QQ 搜索框，请打开 QQ 主窗口") }
            _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
            try await until("QQ 搜索窗口未获得焦点") { CFEqual(try self.focusedWindow(), main) }
            window = main
            detected = try searchField(window)
        }
        guard var search = detected else { throw AppError("QQ 搜索框不可用") }
        searchAnchorWindow = window
        searchAnchorFrame = frameOf(search)
        func requireSearchWindow() throws {
            guard CFEqual(try self.focusedWindow(), window) else {
                throw AppError("QQ 搜索窗口已切换，未输入内容；请保持 QQ 搜索窗口在前台")
            }
        }
        // 清空/提交查询会重建搜索框；每次读取都从当前窗口重新取得句柄。
        func currentSearch() async throws -> AXUIElement {
            var found: AXUIElement?
            try await until("QQ 搜索框暂未就绪，未输入内容", seconds: 3) {
                try requireSearchWindow()
                found = try searchField(window)
                return found != nil
            }
            guard let found else { throw AppError("QQ 搜索框不可用") }
            return found
        }
        func focusSearch() async throws -> AXUIElement {
            try await self.activateForClick()
            guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
                throw AppError("QQ 搜索窗口无法置前，未输入内容")
            }
            try await until("QQ 搜索窗口未获得焦点") { CFEqual(try self.focusedWindow(), window) }
            let candidate = try await currentSearch()
            guard let frame = self.frameOf(candidate) else { throw AppError("QQ 搜索框位置不可读，未输入内容") }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            guard ChatWindowPresentation.visibleAXFrames.contains(where: { $0.contains(point) }) else {
                throw AppError("QQ 搜索框位于屏幕之外，未输入内容")
            }
            // AXFocused=true 不会移动鼠标；留在绿色窗口按钮上的鼠标会再次唤起
            // 系统排列菜单。先移入搜索框让悬停菜单收起，再重新读取并实际点击。
            try self.confirmFrontmostBeforeEvent()
            guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                     mouseCursorPosition: point, mouseButton: .left) else {
                throw AppError("无法定位 QQ 搜索框，未输入内容")
            }
            move.post(tap: .cghidEventTap)
            try await self.wait(0.35)
            let fresh = try await currentSearch()
            guard let currentFrame = self.frameOf(fresh) else { throw AppError("QQ 搜索框位置不可读，未输入内容") }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                Float(currentFrame.midX), Float(currentFrame.midY), &hit) == .success, let hit else {
                throw AppError("QQ 搜索框落点不可核实，未点击、未输入内容")
            }
            var currentHit = hit
            var hitsSearch = CFEqual(currentHit, fresh)
            for _ in 0..<5 where !hitsSearch {
                guard let next = try self.parent(of: currentHit) else { break }
                currentHit = next
                hitsSearch = CFEqual(currentHit, fresh)
            }
            guard hitsSearch else {
                throw AppError("QQ 搜索框被其他窗口或菜单遮挡，未点击、未输入内容")
            }
            try self.click(fresh, physical: true)
            var focusedSearch: AXUIElement?
            try await until("QQ 搜索框未获得键盘焦点，未输入内容", seconds: 3) {
                try requireSearchWindow()
                guard let current = try searchField(window), let focused = self.focusedElement(),
                      CFEqual(current, focused) else { return false }
                focusedSearch = current
                return true
            }
            guard let focusedSearch else { throw AppError("QQ 搜索框不可用") }
            return focusedSearch
        }
        onStep("搜索：\(query)，将进入第一条群聊结果")
        search = try await focusSearch()
        var previousQuery = ""
        // 清空之前先记一次结果区指纹：那时展示的必然是上一次查询的列表（如果还在）。
        // 清空搜索框并不保证 QQ 会把旧结果撤下，所以这个快照才是“有没有刷新”的对照基准。
        var stale: SearchResult?
        try await until("QQ 原搜索结果暂不可读", seconds: 3) {
            let currentWindow = try self.focusedWindow()
            try requireSearchWindow()
            guard let currentSearch = try searchField(currentWindow) else { return false }
            previousQuery = (try self.axRead(currentSearch, kAXValueAttribute) as? String) ?? ""
            stale = try self.firstSearchResult(try self.focusedWindow(), query: query)
            return true
        }
        // 清空也必须是页面实际消费的输入事件。AXSetValue 只改显示值，
        // 还可能先销毁「清空」按钮，导致旧结果既没撤下又留下失效句柄。
        search = try await focusSearch()
        try key(Key.selectAll, flags: .maskCommand)
        try key(Key.deleteBackward)
        try await wait(0.2)
        search = try await currentSearch()
        var clearedResults = false
        try await until("QQ 清空后界面暂不可读", seconds: 3) {
            clearedResults = try self.firstSearchResult(try self.focusedWindow(), query: query) == nil
            return true
        }
        // 直接用真实按键提交查询，避免 AXValue 显示已写入但页面未开始检索。
        if QQSearchLayout.alwaysCommitSearchWithKeystrokes {
            search = try await focusSearch()
            try key(Key.selectAll, flags: .maskCommand)
            try paste(query)
        }
        try await until("搜索文字未写入，未点击结果") {
            guard let currentWindow = try self.focusedWindowIfAvailable(), let current = try searchField(currentWindow) else { return false }
            return try self.axRead(current, kAXValueAttribute) as? String == query
        }
        window = try focusedWindow()
        onStep("已输入「\(query)」，等待群聊结果并点击第一条")
        if hasName(window, "综合搜索"), let groups = try controlNodes(window).first(where: { role($0) == kAXRadioButtonRole && hasName($0, "群聊") }) {
            try click(groups)
        }
        if hasName(window, "综合搜索"), let button = try controlNodes(window).first(where: { role($0) == kAXButtonRole && hasName($0, "搜索") }) {
            try click(button)
        }
        try await wait(0.35)
        // QQ may create the comprehensive-search window only after the query is
        // submitted. Apply the group filter to that window too, before reading rows.
        let resultWindow = try focusedWindow()
        if hasName(resultWindow, "综合搜索"),
           !selectedGroupFilter(in: try orderedNodes(resultWindow)) {
            guard let groups = try controlNodes(resultWindow).first(where: { role($0) == kAXRadioButtonRole && hasName($0, "群聊") }) else {
                throw AppError("综合搜索找不到群聊分类，未选择任何结果")
            }
            try click(groups)
        }
        // 结果列表必须给出“随本次查询刷新”的正向信号，三者之一：行内回显了本次查询词、
        // 首行指纹相对写词前发生变化、写词前结果区本来没有可解析的列表（现在出现的就是本次刷出来的）。
        // 都没有就一直等到超时并中止，绝不直接点第一条（2-01 的竞态窗口）。
        var found: SearchResult?
        let refreshTimeout = "QQ 群聊结果等待超时"
        do {
            try await until(refreshTimeout, seconds: 8, onTransient: { found = nil }) {
                guard let current = try self.firstSearchResult(try self.focusedWindow(), query: query) else { return false }
                found = current
                // 相同查询返回相同首条结果是正常结果，不能强求标题/指纹变化。
                // 查询值已通过新句柄逐字回读；不同查询仍需要原有结果刷新证据。
                return self.resultRowEchoes(current.rowTexts, query: query) || self.normalized(previousQuery) == self.normalized(query) || clearedResults || stale == nil ||
                    current.title != stale?.title || current.rowTexts != stale?.rowTexts
            }
        } catch let error as AppError {
            guard error.message == refreshTimeout else { throw error }
            throw AppError(found == nil ? "没有可打开的群聊搜索结果：\(query)，未点击任何结果"
                : "搜索结果列表未随本次查询「\(query)」刷新（首行仍是上一次查询的结果），未点击任何结果；请在 QQ 里关闭搜索窗后重试")
        }
        guard let result = found else { throw AppError("搜索结果已变化，请重试") }
        guard result.canOpen else { throw AppError("第一条结果没有“发消息”入口，未自动加群，也未选择后面的结果") }
        return result
    }
    private func canRetryOpen(_ error: Error) -> Bool {
        let message = (error as? AppError)?.message ?? error.localizedDescription
        return message.contains("尚未打开") || message.contains("QQ排程助手")
    }
    private func openResult(_ result: SearchResult, query: String) async throws -> AXUIElement {
        try await activateForClick()
        // 综合搜索的「发消息」可走 AXPress；本地下拉的 MenuItem/Group 需要落点点击才会进会话。
        try click(result.action, physical: role(result.action) != kAXButtonRole)
        do { return try await bindOpenedConversation(result, seconds: 5) }
        catch {
            // Only click again while the search UI is still up. A slow-opening chat must not receive a second click.
            guard canRetryOpen(error), let window = try? focusedWindow() else { throw error }
            let searchNodes = try controlNodes(window)
            let stillSearching = hasName(window, "综合搜索") || searchNodes.contains(where: { role($0) == kAXTextFieldRole && hasName($0, "搜索") })
            // 重读的结果必须还是同一行（标题一致）才允许第二次点击：列表可能已经重排，
            // 点下去会进一个与本次查询无关的会话（2-14）。
            guard stillSearching, let fresh = try firstSearchResult(window, query: query), fresh.canOpen,
                  fresh.title == result.title else { throw error }
            try await activateForClick()
            try click(fresh.action, physical: role(fresh.action) != kAXButtonRole)
            return try await bindOpenedConversation(fresh, seconds: 6)
        }
    }
    private func locate(_ recipient: String) async throws -> AXUIElement {
        selectedHeader = nil; selectedMessageList = nil; selectedWindow = nil; selectedTitle = ""
        selectedComposer = nil; selectedPane = nil; composerStructureStable = false; rebindBudget = 0
        let result = try await searchFirst(recipient)
        onStep("点击第一条搜索结果：\(result.title)")
        // QQ local AXMenuItem accepts AXPress but may only dismiss the search popup.
        // A pointer click on this freshly resolved result performs the real navigation.
        // Keep conversation/editor verification below: dispatching a click is not success.
        let window = try await openResult(result, query: recipient)
        // 绑定的是“第一条结果”本身（AGENTS 规则），这里只把配置名与实际会话名的差异说出来，
        // 让事后翻记录的人一眼看出图文进的是哪一个会话。
        if !ConversationMatch.exactly(selectedTitle, recipient) {
            onStep("实际进入的会话为「\(selectedTitle)」，与配置里填的「\(recipient)」不完全一致")
        }
        return window
    }
    func probe(_ recipient: String) async throws -> String {
        guard Self.trusted else { throw AppError("请先在系统设置中授予 QQ排程助手辅助功能权限，再试跑") }
        guard !recipient.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError("请先填写群名") }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        _ = try await locate(recipient)
        _ = try await requireComposerBound(recipient)
        return "试跑通过：已打开 QQ、按搜索词「\(recipient)」进入第一条结果「\(selectedTitle)」，找到消息输入框。未填写草稿、未发送消息。"
    }
    // MARK: - 群名单导入（只读）

    /// 从 QQ 主窗口的会话列表读取当前可见的会话名称（只读，不点击、不发消息）。
    /// 只录取会话名称本身：按会话行取第一个像名称的文本，自动过滤时间、未读数与消息摘要。
    /// 返回去重后的名称数组；读不到会话列表时抛错并给出人工路径。
    func readSessionList() async throws -> [String] {
        cancelled = false
        guard Self.trusted else { throw AppError("请先授予辅助功能权限，再从 QQ 读取群列表") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请解锁后继续") }
        try await openQQ()
        onStep("正在读取 QQ 会话列表（只读）")
        var names: Set<String> = []
        var ignored = 0
        // 会话列表懒渲染，同一屏连读三帧（不滚动、不点击）：读到的是当前可见的那一屏。
        for _ in 0..<3 {
            let window = try focusedWindow()
            guard let list = try controlNodes(window).first(where: { hasName($0, "会话列表") }) else {
                throw AppError("未找到 QQ 会话列表。请回到 QQ 主窗口（不是单独聊天窗口）后重试")
            }
            let rows = try children(list)
            if rows.isEmpty {
                // 层级与预期不同：退回整表扫描，仅靠过滤器排除非名称文本
                for node in try nodes(list) where role(node) == kAXStaticTextRole {
                    for candidate in [string(node, kAXValueAttribute), string(node, kAXTitleAttribute)]
                    where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isGroupNameCandidate(candidate) { names.insert(candidate.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        else { ignored += 1 }
                    }
                }
            } else {
                // 每行第一个像名称的静态文本是会话名；同行的其余文本是时间/未读数/摘要，全部丢弃
                for row in rows {
                    for node in try orderedNodes(row) where role(node) == kAXStaticTextRole {
                        let texts = [string(node, kAXValueAttribute), string(node, kAXTitleAttribute)]
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if let name = texts.first(where: isGroupNameCandidate) {
                            names.insert(name)
                            ignored += texts.filter { $0 != name && !isGroupNameCandidate($0) }.count
                            break
                        }
                        ignored += texts.count
                    }
                }
            }
            try await wait(0.4)
        }
        let sorted = names.sorted()
        // 被丢弃的候选不再静默吞掉：把数量报给用户，缺群时知道是过滤器挡的还是 QQ 里真没有（2-20）。
        onStep("读到 \(sorted.count) 个会话名；另有 \(ignored) 段文本按时间/未读数/消息摘要忽略。需要更多群请滚动会话列表后重读")
        guard !sorted.isEmpty else { throw AppError("会话列表是空的或未能读取到群名。请先在 QQ 里打开几个会话，或手动输入群名") }
        return sorted
    }

    /// 会话行里哪些文本才算群名：排除时间、未读数、消息摘要等。
    /// 群名本身可以带冒号（“通知：本周值班”），所以不按“含冒号”一票否决，改由时钟/日期正则排除（2-20）。
    /// 群名常用全角【】开头，因此只按半角括号排除。
    private func isGroupNameCandidate(_ s: String) -> Bool {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 40,
              !text.allSatisfy({ $0.isNumber }) else { return false }
        // [图片]/[文件] 等消息摘要、@全体成员、99+ 未读数
        if text.hasPrefix("[") || text.hasSuffix("]") || text.hasPrefix("@") { return false }
        if text.hasSuffix("+"), text.dropLast().allSatisfy({ $0.isNumber }) { return false }
        // 相对时间、时钟、日期与星期，如 06/21、09:12、2022-12-10、3分钟前、星期三
        let patterns = ["^\\d{1,2}/\\d{1,2}$", "^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}$", "\\d+ *(分钟|小时|天)前$",
                        "^(上午|下午|晚上)?\\d{1,2}[:：]\\d{2}(:\\d{2})?$",
                        "^\\d{1,2}月\\d{1,2}日$", "^(星期|周)[一二三四五六日天]$"]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return false }
        return !["昨天", "今天", "刚刚", "系统消息", "草稿", "输入中…", "输入中...", "置顶", "免打扰",
                 "QQ红包", "QQ空间", "QQ邮箱"].contains(text)
    }

    /// 只检查第一条结果是否可打开；不填写草稿、不提交消息。
    func verifySearchable(_ name: String) async throws {
        guard Self.trusted else { throw AppError("请先授予辅助功能权限") }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        _ = try await searchFirst(name)
    }

    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; submitted = false; sendCommandIssued = false; actualTriggerAt = nil
        selectedComposer = nil; selectedPane = nil; composerStructureStable = false; rebindBudget = 0
        verificationEvidence = nil
        confirmedImages = 0; imagePasteCommands = 0; weakImageSignals = 0; imageLeftUnconfirmed = false
        guard ["draft", "automatic"].contains(delivery.mode) else { throw AppError("未知发送模式，未执行") }
        if delivery.mode == "draft" && delivery.assets.contains(where: { !$0.isImage }) { throw AppError("普通文件可能在选择后直接发送，不在草稿模式执行") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        for a in delivery.assets {
            let u = root.appendingPathComponent(a.relativePath)
            guard a.relativePath.hasPrefix("assets/"), u.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/assets/"), FileManager.default.fileExists(atPath:u.path), try Database.digest(u) == a.sha256 else { throw AppError("素材缺失、路径无效或已改变：\(a.name)") }
            // 打开 QQ 之前先按文件头把关：读不到、多帧、像素超限都在这里停住，转「需关注」。
            // 不做全解码（2-19 (b)）：真正要写进剪贴板的那一次解码在 attach 里，失败同样不会粘贴。
            // 普通文件不在这里管，由各自的选择窗口流程负责。
            if a.isImage { try ImageAttachment.validateReadable(at:u) }
        }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        _ = try await locate(delivery.recipient)
        let compose = try await requireComposerBound(delivery.recipient)
        // 写稿前逐字核对刚绑定的实际顶部会话与同区域输入框，搜索名只用于选第一条结果。
        try requireIdentityBound(delivery.recipient, composer: compose)
        try ensureEmpty(compose)
        composerImageBaseline = try previewRegionImageCount(compose)
        let allImages = delivery.assets.allSatisfy(\.isImage)
        if allImages {
            // Keep the proven text path first. QQ may show pasted pictures beside the
            // editor without exposing them as AXImage children of the text area.
            try await focus(compose); try key(Key.moveToTextEnd, flags: .maskCommand)
            if !delivery.text.isEmpty {
                onStep("正在填写正文；尚未开始粘贴图片")
                try paste(delivery.text)
            }
            try await confirmDraftText(delivery.recipient, delivery.text, failure: "文字未完整进入 QQ 草稿，未粘贴图片或发送")
            onStep("正文已核对；准备粘贴计划图片")
        }
        for asset in delivery.assets { try await attach(asset, url:root.appendingPathComponent(asset.relativePath), recipient:delivery.recipient, plannedText: allImages ? delivery.text : nil, tolerateUnconfirmedImage: DraftTolerance.toleratesUnconfirmedImage(mode: delivery.mode)) }
        let input = try await requireComposerBound(delivery.recipient, draftMayExist: true)
        if !allImages {
            try await focus(input); try key(Key.moveToTextEnd, flags: .maskCommand)
            if !delivery.text.isEmpty { try paste("\n" + delivery.text) }
        }
        try await confirmDraftText(delivery.recipient, delivery.text, failure: "草稿文字与计划不一致。请检查 QQ 草稿，未发送")
        if allImages {
            let expected = delivery.assets.count
            let finalEditor = try boundEditor(delivery.recipient)
            if try modalInWay(of: finalEditor) {
                throw AppError("QQ 弹出了附件确认窗口，图片不算进入当前群草稿；未发送")
            }
            // 与逐张粘贴共用计数：输入框内 AXImage / QQ 内联图片节点 / U+FFFC、预览区增量。
            // confirmedImages 不再参与兜底：内联对象/class 弱信号能被与本会话无关的渲染变化凑出来，
            // 拿它顶替计数就会“缺图照发且判 verified”（2-02）。
            if try draftImageCount(finalEditor) != expected {
                // 草稿模式不会发出任何消息：填好内容并如实标注“图片未确认”，交人目视核对；
                // 自动发送模式照旧停住，绝不带着没核验的图片往下走。
                if DraftTolerance.toleratesUnconfirmedImage(mode: delivery.mode) {
                    imageLeftUnconfirmed = true
                } else {
                    let weak = weakImageSignals > 0 ? "，另有 \(weakImageSignals) 次内联对象/class 弱信号（不足以作为发送依据）" : ""
                    throw AppError("无法确认草稿中有计划的 \(expected) 张图片（按草稿计数已确认 \(confirmedImages) 张），已保留图文，未发送。\(try composerDiagnostic(finalEditor, plannedText: delivery.text))\(weak)")
                }
            }
        }
        if delivery.mode == "draft" {
            let caution = imageLeftUnconfirmed ? "。注意：图片未能通过辅助功能确认，请在 QQ 里目视核对草稿后再手动发送" : ""
            return ("draft", "已填入正确会话和附件。请在 QQ 手动发送，然后在记录中确认；队列已暂停\(caution)")
        }
        onStep("收件人和草稿已核对，准备提交")
        let submitEditor = try await requireComposerBound(delivery.recipient, draftMayExist: true)
        // 按发送键前再走一次同一套严格绑定（走查 1-05）：填稿期间标题栏可能被 QQ 重渲染成别的写法，
        // 或被人手动切到同名系列群；这一条不过就停在这里，草稿保持原样。
        try requireIdentityBound(delivery.recipient, composer: submitEditor, draftMayExist: true)
        // 实测在「我的手机」里粘贴图片会弹出“发送到我的手机”确认框，框内自带「发送」按钮：
        // 这种弹窗存在时绝不按键，否则一次 Return 会把弹窗里的内容真的发出去。
        if try modalInWay(of: submitEditor) {
            throw AppError("QQ 出现了带「发送」按钮的确认弹窗（例如“发送到我的手机”），已停止且未按键；请在 QQ 手动关闭该弹窗后重试")
        }
        try await focus(submitEditor)
        guard let f = focusedElement(), CFEqual(f, try editor(in:focusedWindow())) else { throw AppError("发送前输入焦点改变，已停止") }
        // Use QQ's current send shortcut only after checking title and exact draft again.
        _ = try ensureRecipient(delivery.recipient)
        guard let focused = focusedElement(), CFEqual(focused, try editor(in:focusedWindow())),
              try composerMatchesSelected(focused, in: focusedWindow()) else {
            throw AppError("发送前输入框所属会话再次变化，未按下任何发送键；请核对 QQ 草稿，不会自动重发")
        }
        // 只发一条发送指令：能认准 QQ「发送」按钮就点按钮，认不出才按一次 Return。
        let beforeSendWindow = try ensureRecipient(delivery.recipient)
        let baseline = try signature(beforeSendWindow, text: delivery.text)
        let beforeLabels = try postSendNotices(beforeSendWindow)
        let beforeMessages = try await stableMessageBaseline(delivery.recipient, text: delivery.text)
        let submittedList = selectedMessageList
        let attempted: [SendTrigger] = [try await fireSend(delivery: delivery, composer: focused)]
        guard let submittedClock = actualTriggerAt else { throw AppError("缺少实际发送检查点") }
        let trigger = SendAttempt.describe(attempted: attempted)
        // 发送指令已发出之后的核验抛错不能把现场冲掉：AX 读失败、暂停/取消等只说明「核不下去」，
        // 不说明「没发出去」。与微信路径同一道兜底——落为 uncertain 并保留 curated 指引文案，
        // 避免用户误判未发出而手动补发（真实重复）。用户主动停止仍原样上抛。
        do {
            return try await confirmAfterTrigger(delivery: delivery, submittedClock: submittedClock, submittedList: submittedList, beforeMessages: beforeMessages, baseline: baseline, beforeLabels: beforeLabels, submittedEditor: focused, trigger: trigger, manual: false) {
                let other = ConversationMatch.exactly(selectedTitle, delivery.recipient) ? "" : "（配置名「\(delivery.recipient)」）"
                return "\(Date().formatted()) · 第一条结果「\(selectedTitle)」\(other)会话保持一致；草稿清空；消息列表最末新增一条本人消息，正文逐字一致、图片张数达标。仅为客户端可见核验，不是服务器送达回执"
            }
        } catch let error as AppError where PausePoint.isStop(error.localizedDescription) {
            throw error
        } catch {
            return ("uncertain", PostSendWatch.unresolvedDetail(trigger: trigger, selectedTitle: selectedTitle, observedLabel: nil, manual: false)
                + "。核验中途停止（\(error.localizedDescription)），请到 QQ 人工核对是否已发出；不会自动重发")
        }
    }

    /// 唯一发送指令之后，只接受完整空草稿和稳定尾锚之后同一条新增本人消息。
    /// 历史加载、列表重绑、缺 ID、纯附件无正文或图片仍留草稿时都保持待核对。
    private func confirmAfterTrigger(delivery: Delivery, submittedClock: Date, submittedList: AXUIElement?, beforeMessages: QQMessageSnapshot, baseline: (matches: Int, images: Int), beforeLabels: [String], submittedEditor: AXUIElement, trigger: String, manual: Bool, verifiedDetail: () -> String) async throws -> (String, String) {
        defer { rebindBudget = 0 }
        let deadline = Date().addingTimeInterval(60)
        let recipient = delivery.recipient, text = delivery.text, assets = delivery.assets
        var firstObservedAt: Date?
        var confirmedRows: [String] = []
        var confirmedAtLatest = false
        var observedLabel: String?
        var observedRecall: String?
        var provenMessageID: String?
        var lastSignature: (matches: Int, images: Int)?
        var confirmedOwn: OwnMessageProof?
        var proofVersion = 1
        let version = qqVersion()
        var observedNewMessage = false
        var observedCandidate = false
        var lastStage = ""
        func stage(_ text: String) {
            if text != lastStage { lastStage = text; onStep(text) }
        }
        let plannedImages = assets.filter(\.isImage).count
        let fileNames = assets.filter { !$0.isImage }.map { normalized($0.name) }
        /// 新增本人消息证据；普通文件任务额外要求同一条气泡里出现文件名文本，
        /// 读不到就仍算证据不足（宁可待核对，也不把“结构上不可能核验”写成永不合格 2-21）。
        func proof(_ window: AXUIElement) throws -> String? {
            // 整树重绑会改变渲染集合；不能用新的树证明旧树之后发生了发送。
            guard let submittedList, CFEqual(try chatList(window), submittedList) else { return nil }
            let current = try messageSnapshot(window, text: text, deadline: deadline)
            let appended = QQMessageSnapshot.appended(baseline: beforeMessages, current: current.snapshot,
                requiredImages: plannedImages, hasText: !normalized(text).isEmpty)
            observedCandidate = observedCandidate || !appended.isEmpty
            let belongs = appended.filter {
                (beforeMessages.atLatest && current.snapshot.atLatest)
                || QQMessageClock.belongsToSubmission($0, submittedAt: submittedClock, observedAt: Date(), version: version)
            }
            if belongs.count == 1 { observedNewMessage = true }
            guard belongs.count <= 1 else {
                stage("出现多个同文本人消息候选，无法唯一核对本次提交")
                return nil
            }
            if belongs.contains(where: { $0.phase == .failed }) {
                throw AppError("本次新增本人图文出现发送失败控件，结果保留日志，不自动重发")
            }
            if belongs.contains(where: { $0.phase == .pending }) {
                stage("本次图文已进入 QQ 消息列表，正在等待发送进度结束")
                return nil
            }
            let legacy = QQMessageSnapshot.candidate(baseline: beforeMessages, current: current.snapshot,
                requiredImages: plannedImages, hasText: !normalized(text).isEmpty)
            let fresh = QQMessageSnapshot.freshCandidate(baseline: beforeMessages, current: current.snapshot,
                requiredImages: plannedImages, hasText: !normalized(text).isEmpty,
                submittedAt: submittedClock, observedAt: Date(), version: version)
            guard let found = legacy ?? fresh, found.phase == .quiet else {
                stage(observedNewMessage ? "本次图文已出现，正在核对消息标识与发送状态" : "发送指令已发出，正在等待本次本人图文出现")
                return nil
            }
            proofVersion = legacy == nil ? 2 : 1
            confirmedOwn = found
            let id = found.id
            confirmedRows = current.snapshot.rowIDs
            confirmedAtLatest = current.snapshot.atLatest
            if !fileNames.isEmpty {
                let lines = (current.texts[id] ?? []).map { normalized($0) }
                guard fileNames.allSatisfy({ name in lines.contains { $0.contains(name) } }) else { return nil }
            }
            return id
        }
        func readSample(_ window: AXUIElement) throws -> PostSendWatch.Sample {
            let currentEditor: AXUIElement
            do {
                currentEditor = try boundEditor(recipient)
            } catch let error as AppError {
                switch PostSendWatch.reaction(toEditorError: error.localizedDescription) {
                case .abort: throw error
                case .inconclusive(let label):
                    if let label { observedLabel = label }
                    // 标题、消息列表、前台和窗口已由 ensureRecipient 绑定；标注异常时
                    // 还必须是原输入框，且同一条新增本人消息的正文与图片完整。
                    let id = try proof(window)
                    if label != nil, id != nil {
                        let editor = try self.editor(in: window)
                        let cleared = try submittedDraftIsEmpty(editor)
                        if OwnMessageProof.acceptsStaleLabel(sameEditor: CFEqual(editor, submittedEditor), draftCleared: cleared, messageID: id),
                           provenMessageID == nil || provenMessageID == id {
                            provenMessageID = id
                            return .bound(draftCleared: true, textAppeared: true, imagesAppeared: true)
                        }
                    }
                    return PostSendWatch.sample(forEditorError: error.localizedDescription)
                }
            }
            guard let id = try proof(window) else {
                if lastSignature == nil { lastSignature = try? signature(window, text: text) }
                return .unreadable
            }
            if let provenMessageID { guard provenMessageID == id else { return .unreadable } }
            provenMessageID = id
            return .bound(
                draftCleared: try submittedDraftIsEmpty(currentEditor),
                textAppeared: true,
                imagesAppeared: true)
        }
        var round = 0
        while Date() < deadline {
            // 每轮核验给 2 次句柄重绑预算（本轮开头的 ensureRecipient 与稳定等待后的 finalWindow
            // 各可用一次）；AX 持续抖动时预算很快耗尽，超限即回到原「已离开」语义，不会死循环。
            rebindBudget = 2
            try await wait(round == 0 ? 0.05 : 0.3)
            round += 1
            do {
                let w = try ensureRecipient(recipient)
                let newNotices = PostSendNotice.added(before: beforeLabels, current: try postSendNotices(w))
                if let failure = newNotices.first(where: { noticeKind($0) == .failure || noticeKind($0) == .ownRecall }) {
                    return ("uncertain", "发送后检测到提示「\(failure)」，请人工核对。不自动重发")
                }
                if let recall = newNotices.first(where: { noticeKind($0) == .recall }) { observedRecall = recall }
                let sample = try readSample(w)
                guard PostSendWatch.verdict([sample]) == .readyToVerify else { firstObservedAt = nil; continue }
                if firstObservedAt == nil { firstObservedAt = Date() }
                stage("本次本人图文已匹配，正在稳定核对发送状态")
                try await wait(1.2)
                let finalWindow = try ensureRecipient(recipient)
                let finalNotices = PostSendNotice.added(before: beforeLabels, current: try postSendNotices(finalWindow))
                if let failure = finalNotices.first(where: { noticeKind($0) == .failure || noticeKind($0) == .ownRecall }) {
                    return ("uncertain", "发送后检测到提示「\(failure)」，请人工核对。不自动重发")
                }
                // 其他成员的撤回提示不直接判失败；本次图文必须在稳定等待后仍有新增证据。
                if let recall = finalNotices.first(where: { noticeKind($0) == .recall }) { observedRecall = recall }
                // 稳定等待后重新确认同一会话、空草稿及新增图文；不沿用一秒前的成功读数。
                guard PostSendWatch.verdict([try readSample(finalWindow)]) == .readyToVerify else { firstObservedAt = nil; continue }
                guard let messageID = provenMessageID, let firstObservedAt else { continue }
                verificationEvidence = QQVerificationEvidence(deliveryID: delivery.id, selectedTitle: selectedTitle,
                    trigger: trigger, submittedAt: submittedClock, firstObservedAt: firstObservedAt, confirmedAt: Date(),
                    baselineRowIDs: beforeMessages.rowIDs, confirmedRowIDs: confirmedRows, messageID: messageID,
                    textMatches: true, images: plannedImages, requiredImages: plannedImages, draftCleared: true,
                    baselineAtLatest: beforeMessages.atLatest, confirmedAtLatest: confirmedAtLatest)
                if proofVersion == 2 {
                    verificationEvidence?.ruleVersion = 2
                    verificationEvidence?.qqVersion = version
                    verificationEvidence?.messageTimeLabel = confirmedOwn?.timeLabel
                    verificationEvidence?.messageTimezoneOffset = confirmedOwn?.timezoneOffset
                    verificationEvidence?.confirmedPhase = confirmedOwn?.phase
                }
                return ("verified", verifiedDetail() + "。消息 ID：" + messageID + "; 核验规则：QQ-v\(proofVersion)；发送前尾锚：" + (beforeMessages.rowIDs.last ?? ""))
            } catch {
                // Only typed transient reads are retried. Stop, focus, identity and unknown errors still abort.
                guard QQTransitionRead.isTransient(error) else { throw error }
                firstObservedAt = nil
                stage("QQ 正在刷新消息控件，继续核对同一次提交，不重复发送")
            }
        }
        if let recall = observedRecall {
            return ("uncertain", "消息列表出现提示「\(recall)」，且未能稳定核验本次新增图文，请人工核对。不自动重发")
        }
        var note = ""
        if !beforeMessages.atLatest {
            note = "。未取得最新滚动位置或本次消息时间的完整依据，不把历史加载当成本次发送"
        }
        if let last = lastSignature {
            note += "。诊断：列表内同文节点 \(baseline.matches)→\(last.matches)、图片节点 \(baseline.images)→\(last.images)（全列表计数不作为核验依据）"
        }
        if observedNewMessage {
            return ("uncertain", "本次图文已进入 QQ 消息列表，但在 60 秒内未取得稳定发送状态与本次消息时间的完整核验依据。已保留结果日志，队列继续其余任务；不会再次发送" + note)
        }
        if observedCandidate {
            return ("uncertain", "QQ 中发现同文图文候选，但不能证明属于本次提交。已保留结果日志，队列继续其余任务；不会再次发送" + note)
        }
        return ("uncertain", PostSendWatch.unresolvedDetail(trigger: trigger, selectedTitle: selectedTitle, observedLabel: observedLabel, manual: manual) + note)
    }
}
