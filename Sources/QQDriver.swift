import AppKit
import ApplicationServices

@MainActor
protocol ChatDriver: AnyObject {
    var cancelled: Bool { get set }
    var beforeSubmit: () throws -> Void { get set }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String)
}

extension QQDriver: ChatDriver {}
extension WeChatDriver: ChatDriver {}

@MainActor
final class QQDriver {
    var cancelled = false
    var onStep: (String) -> Void = { _ in }
    var beforeSubmit: () throws -> Void = {}
    private var pid: pid_t = 0
    private var clipboard: [[NSPasteboard.PasteboardType: Data]] = []
    private var clipboardVersion: Int?
    private var submitted = false
    private var composerImageBaseline = 0
    /// 本次运行里已经用正向信号确认过的图片张数（图片节点 / 内联对象 / 图片专属 class）
    private var confirmedImages = 0
    /// 只在草稿模式（不发送）下出现：图已粘进去但辅助功能取不到正向信号，需要人目视核对
    private var imageLeftUnconfirmed = false
    private var selectedHeader: AXUIElement?
    private var selectedTitle = ""
    private var selectedMessageList: AXUIElement?
    private var selectedWindow: AXUIElement?
    private var accessibilityStatus: AXError = .success
    static var trusted: Bool { AXIsProcessTrusted() }
    static var locked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSessionOnConsoleKey"] as? Bool == false
    }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    private func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(e, attr as CFString, &v) != .success { return nil }; return v }
    private func string(_ e: AXUIElement, _ attr: String) -> String { value(e, attr) as? String ?? "" }
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
    private func until(_ message: String, seconds: Double = 6, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            try check()
            if try condition() { return }
            try await wait(0.15)
        } while Date() < deadline
        throw AppError(message)
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
    private func children(_ e: AXUIElement) -> [AXUIElement] { value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func nodes(_ root: AXUIElement, limit: Int = 4500) -> [AXUIElement] {
        var queue = [root]; var i = 0
        while i < queue.count && queue.count < limit { let c = children(queue[i]); queue.append(contentsOf: c.prefix(limit - queue.count)); i += 1 }
        return queue
    }
    /// Stop as soon as a control is found instead of collecting the whole QQ tree.
    private func firstNode(_ root: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [(root, 0)]
        var count = 0
        let deadline = Date().addingTimeInterval(1)
        while let (element, depth) = stack.popLast() {
            guard count < 900, Date() < deadline, !cancelled, !Task.isCancelled else { return nil }
            count += 1
            if matching(element) { return element }
            if depth < 40 { stack.append(contentsOf: children(element).reversed().map { ($0, depth + 1) }) }
        }
        return nil
    }
    private func orderedNodes(_ root: AXUIElement) -> [AXUIElement] {
        var output: [AXUIElement] = []
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard depth < 50, output.count < 4500 else { return }
            output.append(element)
            for child in children(element) { visit(child,depth+1) }
        }
        visit(root,0); return output
    }
    private struct SearchResult {
        let action: AXUIElement
        let title: String
        let canOpen: Bool
    }
    private func staticTexts(in element: AXUIElement) -> [String] {
        orderedNodes(element).filter { role($0) == kAXStaticTextRole }.map { label($0) }.filter { !$0.isEmpty }
    }
    private func firstSearchResult(_ window: AXUIElement, query: String) -> SearchResult? {
        if hasName(window, "综合搜索") {
            let ordered = orderedNodes(window)
            // The first result row can contain many highlighted text fragments.
            // Locate the row by its action, never by counting matching text nodes.
            guard let action = ordered.first(where: {
                role($0) == kAXButtonRole && ["发消息", "加入", "已加入"].contains(label($0))
            }) else { return nil }
            var parent = action
            for _ in 0..<6 {
                guard let raw = value(parent, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
                parent = unsafeBitCast(raw, to: AXUIElement.self)
                let title = ConversationMatch.resultTitle(texts: staticTexts(in: parent), query: query)
                if !title.isEmpty { return SearchResult(action: action, title: title, canOpen: hasName(action, "发消息")) }
            }
            return nil
        }
        // Current QQ exposes “群聊” as a sibling heading, not inside AXMenuItem.
        // Walk only the search branch, stop at the next category, and never select
        // the “搜索综合结果” entry. Avoid traversing the message/session lists.
        var visited = 0
        let deadline = Date().addingTimeInterval(1)
        func findRow(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 40, visited < 900, Date() < deadline,
                  !cancelled, !Task.isCancelled else { return nil }
            visited += 1
            if hasName(element, "会话列表") || hasName(element, "消息列表") { return nil }
            let items = children(element)
            if let heading = items.firstIndex(where: { role($0) == kAXStaticTextRole && hasName($0, "群聊") }) {
                for sibling in items.dropFirst(heading + 1) {
                    if role(sibling) == kAXStaticTextRole { break }
                    if let row = firstNode(sibling, matching: { self.role($0) == kAXMenuItemRole }) { return row }
                }
            }
            // Support older QQ builds with the category badge inside the row.
            if role(element) == kAXMenuItemRole,
               firstNode(element, matching: { self.hasName($0, "群聊") }) != nil { return element }
            for child in items { if let row = findRow(child, depth: depth + 1) { return row } }
            return nil
        }
        guard let row = findRow(window) else { return nil }
        let picked = ConversationMatch.resultTitle(texts: staticTexts(in: row), query: query)
        let title = picked.isEmpty || ConversationMatch.badges.contains(picked) ? label(row) : picked
        guard !title.isEmpty else { return nil }
        return SearchResult(action: row, title: title, canOpen: true)
    }
    private func headerCandidates(_ window: AXUIElement) -> [String] {
        var labels: [String] = []
        let title = string(window, kAXTitleAttribute)
        if !title.isEmpty { labels.append(title) }
        let topLimit = frameOf(window).map { $0.minY + min(160, max(80, $0.height * 0.2)) }
        for node in nodes(window) where role(node) == kAXButtonRole || role(node) == kAXStaticTextRole {
            let text = label(node)
            guard !text.isEmpty else { continue }
            if let topLimit, let frame = frameOf(node), frame.midY > topLimit { continue }
            if topLimit == nil, role(node) != kAXButtonRole { continue }
            labels.append(text)
        }
        return labels
    }
    private func conversationReady(_ window: AXUIElement, title: String) -> Bool {
        guard !hasName(window, "综合搜索"), (try? editor(in: window)) != nil, (try? chatList(window)) != nil else { return false }
        return ConversationMatch.headerMatches(candidates: headerCandidates(window), title: title)
    }
    private func rememberConversation(_ window: AXUIElement, title: String) {
        let labels = headerCandidates(window)
        let matched = labels.filter { ConversationMatch.headerMatches(candidates: [$0], title: title) }
        let tight = matched.filter { $0.count <= title.count + 24 }
        selectedTitle = (tight.isEmpty ? matched : tight).max { $0.count < $1.count } ?? title
        selectedHeader = nodes(window).first { element in
            let text = label(element)
            return (role(element) == kAXButtonRole || role(element) == kAXStaticTextRole) && text == selectedTitle
        } ?? (label(window) == selectedTitle ? window : nil)
        selectedMessageList = try? chatList(window)
        selectedWindow = window
    }
    private func bindOpenedConversation(_ result: SearchResult, seconds: Double = 8) async throws -> AXUIElement {
        try await until("第一条结果尚未打开为聊天会话，未发送", seconds: seconds) {
            guard !result.title.isEmpty else { return false }
            if let focused = try? self.focusedWindow(), self.conversationReady(focused, title: result.title) {
                self.rememberConversation(focused, title: result.title)
                return self.selectedHeader != nil && self.selectedMessageList != nil
            }
            // A separate chat window can open behind the search popup. Raise it only while search is still in front.
            guard let focused = try? self.focusedWindow(),
                  self.hasName(focused, "综合搜索") || self.nodes(focused).contains(where: { self.role($0) == kAXTextFieldRole && self.hasName($0, "搜索") }),
                  let windows = self.value(self.appElement(), kAXWindowsAttribute) as? [AXUIElement],
                  let opened = windows.first(where: { !CFEqual($0, focused) && self.conversationReady($0, title: result.title) }) else { return false }
            _ = AXUIElementPerformAction(opened, kAXRaiseAction as CFString)
            return false
        }
        onStep("已进入第一条结果：\(selectedTitle)")
        return try focusedWindow()
    }
    private func appElement() -> AXUIElement { AXUIElementCreateApplication(pid) }
    private func focusedWindow() throws -> AXUIElement {
        guard let v = value(appElement(), kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { throw AppError("没有找到 QQ 活动窗口，请打开 QQ 主窗口") }
        return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func focusedElement() -> AXUIElement? {
        guard let v = value(appElement(), kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return unsafeBitCast(v, to: AXUIElement.self)
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw AppError("前台已切换到 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "其他应用")，操作暂停；不是 QQ 登录失效") }
    }
    private func wait(_ seconds: Double = 0.45) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); try check() }
    // A physical click goes to whatever window sits at the point. check() cannot run first:
    // it throws while this app is frontmost, which made the activation below unreachable.
    // Only recover when this app itself is in front. A switch to any other app still stops.
    private func yieldOwnWindows() {
        for window in NSApp.windows where window.isVisible {
            window.level = .normal
            window.orderBack(nil)
        }
    }
    private func activateForClick() async throws {
        try Task.checkCancellation()
        if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
        if Self.locked { throw AppError("Mac 已锁屏，请解锁后继续") }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == pid { yieldOwnWindows(); try check(); return }
        guard front == ProcessInfo.processInfo.processIdentifier else { try check(); return }
        yieldOwnWindows()
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        var deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
            if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds:120_000_000)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.tencent.qq") {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            if let qq = try? await NSWorkspace.shared.openApplication(at:url,configuration:configuration) { pid = qq.processIdentifier }
            deadline = Date().addingTimeInterval(4)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
                if cancelled { throw AppError("已停止。请检查 QQ 中是否留有草稿或已提交的消息") }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds:120_000_000)
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
    private func click(_ e: AXUIElement, physical: Bool = false) throws {
        try check()
        if !physical, AXUIElementPerformAction(e, kAXPressAction as CFString) == .success { return }
        guard let frame = frameOf(e), frame.width > 1, frame.height > 1 else { throw AppError(frameOf(e) == nil ? "QQ 控件不可点击：\(label(e))" : "目标控件当前不可见") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        if let blocker = coveringAppName(point) { throw AppError("「\(blocker)」的窗口挡住了 QQ 的「\(label(e))」，未发送点击，避免误触其他应用；请把 QQ 窗口置于最前后重试") }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw AppError("无法生成点击事件，未点击") }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    private func key(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
        try check()
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down); event?.flags = flags; event?.post(tap: .cghidEventTap) }
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
        try check(); let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string); clipboardVersion = pb.changeCount; try key(9, flags: .maskCommand)
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
        let found = nodes(window).filter { role($0) == kAXTextAreaRole }
        guard found.count == 1 else { throw AppError("未能唯一定位 QQ 消息输入框，请关闭其他弹窗") }; return found[0]
    }
    private func ensureRecipient(_ name: String) throws -> AXUIElement {
        try check()
        let window = try focusedWindow()
        guard let header = selectedHeader, let list = selectedMessageList, let originalWindow = selectedWindow,
              CFEqual(window, originalWindow), label(header) == selectedTitle,
              nodes(window).contains(where: { CFEqual($0, header) }),
              CFEqual(try chatList(window), list) else {
            throw AppError("已离开刚选中的第一条会话「\(selectedTitle)」，操作暂停")
        }
        return window
    }
    /// 任何一次“读输入框”都必须同时确认它属于刚选中的会话：切换瞬间标题栏可能已经对了，
    /// 而唯一的 AXTextArea 仍标注着别的群，那时读到的 class/字符变化与本会话无关。
    /// 抛错信息不含“已离开”，所以轮询里按瞬时滞后继续重试，超时后只会停在“确认不了”，不会误发。
    private func boundEditor(_ recipient: String) throws -> AXUIElement {
        let window = try ensureRecipient(recipient)
        let editor = try self.editor(in: window)
        let marked = string(editor, kAXDescriptionAttribute)
        guard ConversationMatch.composerBelongs(to: selectedTitle, description: marked) else {
            throw AppError("输入框当前标注为「\(marked.isEmpty ? "未标注会话" : marked)」，与已选中的「\(selectedTitle)」不一致")
        }
        return editor
    }
    /// 标题栏对上还不够：切换会话时输入框的 AXDescription 可能仍写着上一个会话。
    /// 粘贴与发送前都调用它，对不上先短暂重试，仍对不上就停，绝不把内容写进别的会话。
    private func requireComposerBound(_ name: String, seconds: Double = 2) async throws -> AXUIElement {
        var lastName = ""
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let window = try ensureRecipient(name)
            let editor = try self.editor(in: window)
            lastName = string(editor, kAXDescriptionAttribute)
            if ConversationMatch.composerBelongs(to: selectedTitle, description: lastName) { return editor }
            guard Date() < deadline else { break }
            try await wait(0.3)
        }
        throw AppError("QQ 输入框当前标注为「\(lastName.isEmpty ? "未命名会话" : lastName)」，与刚选中的「\(selectedTitle)」不一致（可能还在切换会话），已停止：未粘贴、未发送")
    }
    private func composerIsEmpty(_ e: AXUIElement) -> Bool {
        // QQ exposes blank paragraph/static-text nodes even when its editor is visibly empty.
        // Do not discard object-replacement characters: these can represent an attachment.
        return ComposerContent.isEmpty(string(e,kAXValueAttribute),descendants:nodes(e).dropFirst().map { child in
            ComposerNode(role:role(child),value:string(child,kAXValueAttribute),title:string(child,kAXTitleAttribute),description:string(child,kAXDescriptionAttribute))
        })
    }
    private func imageCount(_ input: AXUIElement) -> Int {
        ComposerContent.attachmentCount(string(input,kAXValueAttribute),imageNodes:nodes(input).filter { role($0) == kAXImageRole }.count)
    }
    /// 输入框祖先链自内向外的每层子节点（最多 4 层：够到配图预览条，也不会走进消息列表）。
    private func ancestorChildLevels(_ input: AXUIElement, depth: Int = 4) -> [[AXUIElement]] {
        var levels: [[AXUIElement]] = []
        var current = input
        for _ in 0..<depth {
            guard let raw = value(current, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let parent = unsafeBitCast(raw, to: AXUIElement.self)
            let branches = children(parent)
            if branches.isEmpty { break }
            levels.append(branches)
            current = parent
        }
        return levels
    }
    /// 配图预览区所在层：QQ 实测输入框父节点只有输入框自己，预览条与「会话」工具栏同级，
    /// 所以要按“祖先链里第一个带工具栏的层”来找，工具栏分支（chat-func-bar，自带 11 个图标）不计入。
    private func previewBranches(_ input: AXUIElement) -> [AXUIElement] {
        let levels = ancestorChildLevels(input)
        guard !levels.isEmpty else { return [input] }
        let level = min(ComposerRegion.previewLevel(childRoles: levels.map { $0.map(role) }), levels.count - 1)
        return levels[level].filter { role($0) != ComposerRegion.toolbarRole }
    }
    private func domClasses(_ e: AXUIElement) -> [String] { value(e, "AXDOMClassList") as? [String] ?? [] }
    /// 输入区结构快照：图片节点、按钮、节点总数、输入框高度与出现过的 DOM 类名。
    private func composerSnapshot(_ input: AXUIElement) -> ComposerSnapshot {
        let branches = previewBranches(input)
        let flat = branches.flatMap { nodes($0, limit: 400) }
        let editorNodes = nodes(input, limit: 400)
        return ComposerSnapshot(images: flat.filter { role($0) == kAXImageRole }.count,
                                buttons: flat.filter { role($0) == kAXButtonRole }.count,
                                nodes: flat.count,
                                editorHeight: frameOf(input)?.height ?? 0,
                                classTokens: Array(Set((editorNodes + flat).flatMap { domClasses($0) })).sorted(),
                                characters: (value(input, "AXNumberOfCharacters") as? Int) ?? -1,
                                text: string(input, kAXValueAttribute))
    }
    private func previewRegionImageCount(_ input: AXUIElement) -> Int { composerSnapshot(input).images }
    private func draftImageCount(_ input: AXUIElement) -> Int {
        ComposerContent.imageCount(editorCount: imageCount(input), composerImagesBefore: composerImageBaseline,
                                   composerImagesNow: previewRegionImageCount(input))
    }
    /// 确认不了时把看到的结构如实写进记录，下一轮排查不用再靠猜。只做交代，不当确认依据。
    private func composerDiagnostic(_ input: AXUIElement, before: ComposerSnapshot? = nil, plannedText: String = "") -> String {
        let snapshot = composerSnapshot(input)
        let classes = domClasses(input).joined(separator: "|")
        let characters = (value(input, "AXNumberOfCharacters") as? Int) ?? -1
        let branches = previewBranches(input).prefix(6)
            .map { role($0) + ":" + (domClasses($0).first ?? "-") }.joined(separator: ",")
        var extra = ""
        if let before {
            let added = ComposerDiagnostic.newClasses(before: before.classTokens, now: snapshot.classTokens)
            extra = "，粘贴前图片\(before.images)/节点\(before.nodes)"
            if !added.isEmpty { extra += "，新增class=\(added.prefix(12))" }
        }
        let spare = plannedText.isEmpty ? "" : "，正文\(plannedText.count)字/字符数\(characters)/多出\(ComposerDiagnostic.extraCharacters(textLength: plannedText.count, characterCount: characters))"
        return "结构诊断：输入框class=\(String(classes.prefix(60)))，图片\(snapshot.images)/按钮\(snapshot.buttons)/节点\(snapshot.nodes)，高\(Int(snapshot.editorHeight))\(spare)\(extra)，分支[\(String(branches.prefix(150)))]"
    }
    /// QQ 的“发送到我的手机”一类确认框自带「发送」按钮；有这种弹窗时绝不触发发送。
    private func modalInWay(of composer: AXUIElement) -> Bool {
        let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.contains(where: { ["AXSheet", "AXDialog"].contains(string($0, kAXSubroleAttribute)) }) { return true }
        let mine = sendButton(in: composer)
        for w in windows {
            for node in nodes(w, limit: 2500) where role(node) == kAXButtonRole {
                let text = label(node)
                guard SendGate.isSendConfirmationButton(text) else { continue }
                if let mine, CFEqual(mine, node) { continue }
                return true   // 输入区之外还有一个「发送」：那是对话框的确认键，不能按键
            }
        }
        return false
    }
    /// QQ may activate its main window when reopened while the populated group draft
    /// remains in a separate chat-pool window. Find that exact draft before any send.
    private func existingDraftWindow(for delivery: Delivery) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(6)
        while true {
            try check()
            let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
            let matches = windows.filter { window in
                guard ConversationMatch.headerMatches(candidates: headerCandidates(window), title: delivery.recipient),
                      (try? chatList(window)) != nil,
                      let input = try? editor(in: window),
                      ConversationMatch.exactly(string(input, kAXDescriptionAttribute), delivery.recipient) else { return false }
                return normalized(string(input, kAXValueAttribute)) == normalized(delivery.text)
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
    private func sendButton(in composer: AXUIElement) -> AXUIElement? {
        for branch in previewBranches(composer) {
            if let found = firstNode(branch, matching: { element in
                role(element) == kAXButtonRole && SendAttempt.isSendButtonLabel(label(element))
                    && value(element, kAXEnabledAttribute) as? Bool != false && frameOf(element) != nil
            }) { return found }
        }
        return nil
    }
    /// 发出本任务唯一的一条发送指令：认得准 QQ「发送」按钮就点按钮，认不出才按一次 Return。
    /// 这里不存在“没发出去就再按一次”的分支；核验与人工核对在调用方完成。
    private func fireSend(recipient: String, composer: AXUIElement) async throws -> SendTrigger {
        let button = sendButton(in: composer)
        switch SendAttempt.firstTrigger(buttonFound: button != nil) {
        case .sendButton:
            guard let button else { throw AppError("QQ 发送按钮在按下前消失，未发送") }
            _ = try ensureRecipient(recipient)
            try await activateForClick()
            try click(button)
            onStep("已点击 QQ 发送按钮，等待 QQ 发出")
            return .sendButton
        case .returnKey:
            try key(36)
            onStep("已按 Return，等待 QQ 发送")
            return .returnKey
        }
    }
    /// 把“粘贴后固定睡 0.5 秒再核对”换成轮询：正文到位就立刻往下走，最多等 seconds 秒。
    /// 只缩短等待，判定条件与原来的硬核对完全一致。
    private func awaitDraftText(_ recipient: String, _ text: String, seconds: Double = 2) async throws -> AXUIElement {
        var window = try ensureRecipient(recipient)
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            try check()
            guard normalized(string(try boundEditor(recipient), kAXValueAttribute)) == normalized(text) else {
                if Date() >= deadline { return window }
                try await Task.sleep(nanoseconds: 120_000_000)
                window = try ensureRecipient(recipient)
                continue
            }
            return window
        }
    }
    private func ensureEmpty(_ e: AXUIElement) throws {
        // 空草稿守卫必须用与配图确认同一套预览区口径：残留图片若被当成基线折掉，
        // 就会和本次计划的图一起发出去。工具栏图标不计入，实测空草稿该区域为 0。
        guard composerIsEmpty(e), previewRegionImageCount(e) == 0 else {
            let codes = string(e,kAXValueAttribute).unicodeScalars.prefix(12).map { String($0.value,radix:16) }.joined(separator:",")
            let structure = children(e).prefix(8).map { role($0) + ":" + String(string($0,kAXValueAttribute).count) }.joined(separator:",")
            throw AppError("QQ 输入框检测到草稿或附件，已保留；请先手动处理。诊断：value=\(codes)，children=\(structure)")
        }
    }
    private func chatList(_ w: AXUIElement) throws -> AXUIElement {
        guard let list = nodes(w).first(where: { label($0) == "消息列表" }) else { throw AppError("无法读取 QQ 消息列表，不能核验发送结果") }; return list
    }
    private func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" } }
    private func signature(_ w: AXUIElement, text: String) throws -> (matches: Int, images: Int) {
        let ns = nodes(try chatList(w))
        let target = normalized(text)
        return (target.isEmpty ? 0 : ns.filter { normalized(string($0, kAXValueAttribute)) == target || normalized(string($0, kAXTitleAttribute)) == target }.count,
                ns.filter { role($0) == kAXImageRole }.count)
    }
    private func attach(_ asset: Asset, url: URL, recipient: String, tolerateUnconfirmedImage: Bool = false) async throws {
        onStep("正在加入附件：\(asset.name)")
        let w = try ensureRecipient(recipient)
        if asset.isImage {
            // Put actual image data on the clipboard, not a filename that QQ could upload immediately.
            // TIFF + PNG 双格式：部分 QQ 构建不吃裸 TIFF，只写单一格式会让 Cmd+V 静默无效
            let tiff = try ImageAttachment.tiff(at:url)
            let png = NSBitmapImageRep(data: tiff)?.representation(using:.png,properties:[:])
            let input = try await requireComposerBound(recipient)
            let count = draftImageCount(input)
            try await focus(input)
            try key(119,flags:.maskCommand)
            // 正文在这之前已逐字核对完毕；粘贴前拍一次结构快照，只用于失败时如实交代现场
            let before = composerSnapshot(input)
            // 大图在 QQ 里粘贴/压缩可能明显慢于固定 6 秒：等待时长随体积放大（8MB ≈ 24 秒封顶）
            let seconds = min(24, 8 + Double(asset.bytes) / 1_048_576 * 2)
            func pasteAndConfirm() async throws {
                let pb = NSPasteboard.general; pb.clearContents()
                pb.setData(tiff,forType:.tiff)
                if let png { pb.setData(png,forType:.png) }
                clipboardVersion = pb.changeCount
                try key(9,flags:.maskCommand)
                let deadline = Date().addingTimeInterval(seconds)
                while true {
                    try check()
                    do {
                        let current = try self.boundEditor(recipient)
                        // QQ 可能把同一张图短暂渲染成两个节点，用 >= 容忍计数波动
                        if self.draftImageCount(current) >= count + 1 { return }
                        // 弹窗（例如“发送到我的手机”）同样会改 class 与节点数，
                        // 绝不能把它当成本会话的图片信号；这里只跳过本轮判定，超时判断照常执行。
                        if !self.modalInWay(of: current) {
                            let now = self.composerSnapshot(current)
                            let classes = ComposerImageSignal.newImageClasses(before: before.classTokens, now: now.classTokens)
                            let inline = ComposerImageSignal.inlineObjectAdded(textUnchanged: now.text == before.text,
                                                                              charactersBefore: before.characters,
                                                                              charactersAfter: now.characters)
                            if !classes.isEmpty || inline {
                                // 再读一次：瞬时值不算，正文必须仍然一字未改，且仍然没有弹窗
                                try await self.wait(0.4)
                                if let again = try? self.boundEditor(recipient), !self.modalInWay(of: again) {
                                    let stable = self.composerSnapshot(again)
                                    let stillClasses = ComposerImageSignal.newImageClasses(before: before.classTokens, now: stable.classTokens)
                                    let stillInline = ComposerImageSignal.inlineObjectAdded(textUnchanged: stable.text == before.text,
                                                                                            charactersBefore: before.characters,
                                                                                            charactersAfter: stable.characters)
                                    if stable.text == before.text, !stillClasses.isEmpty || stillInline {
                                        self.confirmedImages += 1
                                        self.onStep("已按内联对象信号确认图片进入草稿：\(asset.name)")
                                        return
                                    }
                                }
                            }
                        }
                    } catch let error as AppError {
                        // 图片上传中 QQ 会重渲染输入框，AX 瞬时定位失败只继续轮询；会话丢失才终止
                        if error.localizedDescription.contains("已离开") { throw error }
                    }
                    if Date() >= deadline { throw AppError("图片未进入草稿：\(asset.name)，没有继续发送") }
                    try await self.wait(0.15)
                }
            }
            do { try await pasteAndConfirm() }
            catch let error as AppError {
                guard error.localizedDescription.hasPrefix("图片未进入草稿") else { throw error }
                // A second paste can create two copies of a picture that AX did not expose.
                if let current = try? boundEditor(recipient), draftImageCount(current) >= count + 1 { return }
                if let current = try? boundEditor(recipient), !modalInWay(of: current) {
                    let late = composerSnapshot(current)
                    let inline = ComposerImageSignal.inlineObjectAdded(textUnchanged: late.text == before.text,
                                                                       charactersBefore: before.characters,
                                                                       charactersAfter: late.characters)
                    if !ComposerImageSignal.newImageClasses(before: before.classTokens, now: late.classTokens).isEmpty || inline {
                        confirmedImages += 1
                        onStep("已按内联对象信号确认图片进入草稿：\(asset.name)")
                        return
                    }
                }
                // 草稿模式不会发送任何消息：图片确认不了也照样填好，但必须如实写在结果里，交人目视核对
                if tolerateUnconfirmedImage { imageLeftUnconfirmed = true; return }
                // 只认正向图片信号（输入框内 AXImage / U+FFFC / 输入区里非工具栏的图片节点）。
                // 节点数、按钮数、输入框高度变多都不能算图片已进草稿：QQ 异步重渲染会造成这些变化，
                // 反过来图片也可能渲染成 Chromium 不暴露的无名 div。确认不了就停，交人工核对。
                if let current = try? boundEditor(recipient) {
                    throw AppError("无法确认图片是否进入 QQ 草稿：\(asset.name)。文字和现有草稿已保留，未重复粘贴图片；请在 QQ 核对后手动处理。\(composerDiagnostic(current, before: before))")
                }
                throw AppError("无法确认图片是否进入 QQ 草稿：\(asset.name)。文字和现有草稿已保留，未重复粘贴图片；请在 QQ 核对后手动处理")
            }
            return
        }
        let buttonName = asset.isImage ? "图片" : "文件"
        guard let button = nodes(w).first(where: { role($0) == kAXButtonRole && label($0) == buttonName }) else { throw AppError("找不到 QQ \(buttonName)按钮") }
        try click(button); try await wait(0.7)
        let openWindow = try focusedWindow()
        guard nodes(openWindow).contains(where: { string($0, kAXIdentifierAttribute) == "open-panel" || (role($0) == kAXButtonRole && label($0) == "打开") }) else { throw AppError("QQ 未显示标准文件选择窗口，请手动处理当前弹窗") }
        try key(5, flags: [.maskCommand, .maskShift]); try await wait()
        let pathNodes = nodes(try focusedWindow())
        guard let pathField = pathNodes.first(where: { string($0, kAXIdentifierAttribute) == "PathTextField" }) else { throw AppError("无法定位文件路径输入框") }
        guard AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, url.path as CFString) == .success else { throw AppError("文件路径填写失败") }
        try await wait()
        guard string(pathField, kAXValueAttribute) == url.path else { throw AppError("文件路径核对失败") }
        try key(36); try await wait(0.6)
        let fileNodes = nodes(try focusedWindow())
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
        guard !children(composer).isEmpty || !normalized(string(composer,kAXValueAttribute)).isEmpty else { throw AppError("附件未出现在草稿中，或 QQ 使用了额外确认窗口。请检查，未继续发送") }
    }
    /// 人工在 QQ 界面上核对过“就是这条草稿”之后的续发：不搜索、不清空、不再粘贴任何内容，
    /// 只做归属与正文的逐字核验、弹窗闸门、持久化检查点，然后发出唯一一条发送指令。
    /// 与自动发送的区别只在于“图片确实在框里”由人当场确认，其余安全网一条不少。
    func sendExistingDraft(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; submitted = false; confirmedImages = 0
        guard delivery.mode == "automatic" else { throw AppError("只有自动发送任务可以按已核对草稿续发") }
        guard !delivery.text.isEmpty || !delivery.assets.isEmpty else { throw AppError("这条任务没有内容") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请解锁后继续") }
        try await openQQ()
        let window = try await existingDraftWindow(for: delivery)
        let composer = try editor(in: window)
        // 归属核验：输入框标注必须与任务收件群逐字相同，标题栏也必须对得上；不做含混匹配
        let marked = string(composer, kAXDescriptionAttribute)
        guard ConversationMatch.exactly(marked, delivery.recipient) else {
            throw AppError("当前输入框属于「\(marked.isEmpty ? "未标注会话" : marked)」，不是任务收件群「\(delivery.recipient)」，未发送")
        }
        guard ConversationMatch.headerMatches(candidates: headerCandidates(window), title: delivery.recipient) else {
            throw AppError("标题栏读不到「\(delivery.recipient)」，可能不是同一个会话窗口，未发送")
        }
        // 正文核验：草稿必须就是计划里的那段文字，一字不差（忽略换行与零宽字符）
        let draft = string(composer, kAXValueAttribute)
        guard !normalized(draft).isEmpty else { throw AppError("QQ 草稿是空的，没有可发送的内容，未发送") }
        guard normalized(draft) == normalized(delivery.text) else {
            throw AppError("QQ 草稿正文与这条任务的计划文字不一致，未发送。\(composerDiagnostic(composer, plannedText: delivery.text))")
        }
        // 弹窗闸门：确认框自带「发送」时绝不按键
        if modalInWay(of: composer) {
            throw AppError("QQ 出现了带「发送」按钮的确认弹窗，未按键；请先手动关闭该弹窗")
        }
        // 绑定这个实际会话，后续核验沿用同一套前台/会话/消息列表检查
        rememberConversation(window, title: delivery.recipient)
        selectedHeader = selectedHeader ?? window
        let baseline = try signature(window, text: delivery.text)
        let beforeLabels = nodes(try chatList(window)).map { label($0) }
        onStep("草稿已按人工核对确认，准备提交：\(delivery.recipient)")
        try await focus(composer)
        guard let f = focusedElement(), CFEqual(f, try editor(in: focusedWindow())),
              ConversationMatch.exactly(string(f, kAXDescriptionAttribute), delivery.recipient) else {
            throw AppError("发送前输入焦点或所属会话变化，已停止")
        }
        try beforeSubmit() // 与自动发送同一个持久化检查点
        submitted = true
        guard let focused = focusedElement(), CFEqual(focused, try editor(in: focusedWindow())),
              ConversationMatch.exactly(string(focused, kAXDescriptionAttribute), delivery.recipient) else {
            throw AppError("发送前输入框归属再次变化，未按下任何发送键；请核对 QQ 草稿，不会自动重发")
        }
        let attempted: [SendTrigger] = [try await fireSend(recipient: delivery.recipient, composer: focused)]
        var w = window
        for round in 0..<12 {
            try await wait(round == 0 ? 0.25 : 0.65)
            w = try ensureRecipient(delivery.recipient)
            let currentLabels = nodes(try chatList(w)).map { label($0) }
            if currentLabels.contains(where: { !beforeLabels.contains($0) && ($0.contains("撤回") || $0.contains("发送失败") || $0.contains("禁言")) }) {
                return ("uncertain", "发送后出现撤回、禁言或失败信息，请人工核对。不自动重发")
            }
            let current = try signature(w, text: delivery.text)
            let currentEditor = try editor(in: w)
            let empty = composerIsEmpty(currentEditor)
            let textMatch = delivery.text.isEmpty || current.matches > baseline.matches
            let imagesMatch = delivery.assets.isEmpty || (delivery.assets.allSatisfy(\.isImage) && current.images >= baseline.images + delivery.assets.count)
            if empty && textMatch && imagesMatch {
                try await wait(1.0)
                let finalLabels = nodes(try chatList(ensureRecipient(delivery.recipient))).map { label($0) }
                if finalLabels.contains(where: { !beforeLabels.contains($0) && ($0.contains("撤回") || $0.contains("发送失败")) }) {
                    return ("uncertain", "消息出现撤回或失败，请人工核对")
                }
                return ("verified", "\(Date().formatted()) · 人工核对草稿后续发：会话「\(delivery.recipient)」逐字一致；草稿已清空；消息列表新增匹配内容。仅为客户端可见核验，不是服务器送达回执")
            }
        }
        return ("uncertain", "已按人工核对发出一次发送指令（\(SendAttempt.describe(attempted: attempted))），但无法确认图文完整进入消息列表。为避免重复发送不再按第二次，请到 QQ 查看；不会自动重发")
    }

    func diagnostic() -> String {
        guard Self.trusted else { return "辅助功能权限：未授权。请在设置中允许本软件控制 QQ。" }
        guard !Self.locked else { return "Mac 已锁屏" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else { return "QQ 未运行，请手动打开并登录" }
        pid = app.processIdentifier
        enableContentTree()
        let root = appElement()
        let windows = value(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
        let summaries = windows.map { window -> String in
            let controls = nodes(window)
            let found = controls.contains { role($0) == kAXTextFieldRole && hasName($0,"搜索") }
            return "窗口：\(label(window))；可读取控件：\(controls.count)；搜索框：\(found ? "已找到" : "未找到")"
        }
        return "辅助功能权限：已授权\nQQ 进程：\(pid)\n完整控件树请求：\(accessibilityStatus.rawValue)\n窗口数：\(windows.count)\n" + summaries.joined(separator:"\n") + "\n0 表示控件树请求成功；非 0 不等于未登录。检查不会发送消息，也不读取密码。"
    }
    func openQQ() async throws {
        cancelled = false
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        onStep("正在打开 QQ")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.tencent.qq") else { throw AppError("未找到已安装的 QQ") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        // Launch Services handles an already-running background QQ too. activate() alone can be declined on modern macOS.
        let qq = try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
        pid = qq.processIdentifier
        qq.unhide()
        let deadline = Date().addingTimeInterval(5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
            try Task.checkCancellation()
            if cancelled { throw AppError("已停止") }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        try check()
        enableContentTree()
        onStep("等待 QQ 完整控件树")
        try await until("QQ 进程存在，但界面控件尚未就绪；请打开主窗口。无需再次登录",seconds:8) {
            guard let window = try? self.focusedWindow() else { return false }
            return self.firstNode(window, matching: { self.role($0) == kAXTextFieldRole || self.role($0) == kAXTextAreaRole }) != nil
        }
    }
    private func searchFirst(_ query: String) async throws -> SearchResult {
        var window = try focusedWindow()
        func searchField(_ w: AXUIElement) -> AXUIElement? {
            firstNode(w, matching: { role($0) == kAXTextFieldRole && (hasName($0, "搜索") || hasName(w, "综合搜索")) })
        }
        if searchField(window) == nil {
            let windows = value(appElement(), kAXWindowsAttribute) as? [AXUIElement] ?? []
            guard let main = windows.first(where: { searchField($0) != nil }) else { throw AppError("未找到 QQ 搜索框，请打开 QQ 主窗口") }
            _ = AXUIElementPerformAction(main, kAXRaiseAction as CFString)
            try await until("QQ 搜索窗口未获得焦点") { CFEqual(try self.focusedWindow(), main) }
            window = main
        }
        guard let search = searchField(window) else { throw AppError("QQ 搜索框不可用") }
        onStep("搜索：\(query)，将进入第一条结果")
        try await focus(search)
        // Clear old results before applying a new query.
        _ = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, "" as CFString)
        try await wait(0.2)
        let set = AXUIElementSetAttributeValue(search, kAXValueAttribute as CFString, query as CFString)
        if set != .success || string(search, kAXValueAttribute) != query {
            try key(0, flags: .maskCommand); try paste(query)
        }
        try await until("搜索文字未写入，未点击结果") { self.string(search, kAXValueAttribute) == query }
        if hasName(window, "综合搜索"), let groups = nodes(window).first(where: { role($0) == kAXRadioButtonRole && hasName($0, "群聊") }) {
            try click(groups)
        }
        if hasName(window, "综合搜索"), let button = nodes(window).first(where: { role($0) == kAXButtonRole && hasName($0, "搜索") }) {
            try click(button)
        }
        try await wait(0.35)
        var found: SearchResult?
        try await until("没有可打开的搜索结果：\(query)", seconds: 8) {
            found = self.firstSearchResult(try self.focusedWindow(), query: query)
            return found != nil
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
        try click(result.action, physical: true)
        do { return try await bindOpenedConversation(result, seconds: 5) }
        catch {
            // Only click again while the search UI is still up. A slow-opening chat must not receive a second click.
            guard canRetryOpen(error), let window = try? focusedWindow(),
                  hasName(window, "综合搜索") || nodes(window).contains(where: { role($0) == kAXTextFieldRole && hasName($0, "搜索") }),
                  let fresh = firstSearchResult(window, query: query), fresh.canOpen else { throw error }
            try await activateForClick()
            try click(fresh.action, physical: true)
            return try await bindOpenedConversation(SearchResult(action: fresh.action, title: result.title.isEmpty ? fresh.title : result.title, canOpen: true), seconds: 6)
        }
    }
    private func locate(_ recipient: String) async throws -> AXUIElement {
        selectedHeader = nil; selectedMessageList = nil; selectedWindow = nil; selectedTitle = ""
        let result = try await searchFirst(recipient)
        onStep("点击第一条搜索结果：\(result.title)")
        // QQ local AXMenuItem accepts AXPress but may only dismiss the search popup.
        // A pointer click on this freshly resolved result performs the real navigation.
        // Keep conversation/editor verification below: dispatching a click is not success.
        return try await openResult(result, query: recipient)
    }
    func probe(_ recipient: String) async throws -> String {
        guard Self.trusted else { throw AppError("请先在系统设置中授予 QQ排程助手辅助功能权限，再试跑") }
        guard !recipient.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError("请先填写群名") }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        let window = try await locate(recipient)
        _ = try editor(in:window)
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
        // 会话列表会随滚动变化；读取多帧提高覆盖
        for _ in 0..<3 {
            let window = try focusedWindow()
            guard let list = nodes(window).first(where: { hasName($0, "会话列表") }) else {
                throw AppError("未找到 QQ 会话列表。请回到 QQ 主窗口（不是单独聊天窗口）后重试")
            }
            let rows = children(list)
            if rows.isEmpty {
                // 层级与预期不同：退回整表扫描，仅靠过滤器排除非名称文本
                for node in nodes(list) where role(node) == kAXStaticTextRole {
                    for candidate in [string(node, kAXValueAttribute), string(node, kAXTitleAttribute)] where isGroupNameCandidate(candidate) {
                        names.insert(candidate.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } else {
                // 每行第一个像名称的静态文本是会话名；同行的其余文本是时间/未读数/摘要，全部丢弃
                for row in rows {
                    for node in orderedNodes(row) where role(node) == kAXStaticTextRole {
                        if let name = [string(node, kAXValueAttribute), string(node, kAXTitleAttribute)].first(where: isGroupNameCandidate) {
                            names.insert(name.trimmingCharacters(in: .whitespacesAndNewlines))
                            break
                        }
                    }
                }
            }
            try await wait(0.4)
        }
        let sorted = names.sorted()
        guard !sorted.isEmpty else { throw AppError("会话列表是空的或未能读取到群名。请先在 QQ 里打开几个会话，或手动输入群名") }
        return sorted
    }

    /// 会话行里哪些文本才算群名：排除时间、未读数、消息摘要等。群名常用全角【】开头，因此只按半角括号排除。
    private func isGroupNameCandidate(_ s: String) -> Bool {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 40,
              !text.contains(":"), !text.contains("："),
              !text.allSatisfy({ $0.isNumber }) else { return false }
        // [图片]/[文件] 等消息摘要、@全体成员、99+ 未读数
        if text.hasPrefix("[") || text.hasSuffix("]") || text.hasPrefix("@") { return false }
        if text.hasSuffix("+"), text.dropLast().allSatisfy({ $0.isNumber }) { return false }
        // 相对时间与日期，如 06/21、2022-12-10、3分钟前；以及系统词
        let patterns = ["^\\d{1,2}/\\d{1,2}$", "^\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}$", "\\d+ *(分钟|小时|天)前$"]
        if patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return false }
        return !["昨天", "今天", "刚刚", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "星期天",
                 "QQ红包", "QQ空间", "QQ邮箱", "系统消息", "草稿", "输入中…", "输入中..."].contains(text)
    }

    /// 只检查第一条结果是否可打开；不填写草稿、不提交消息。
    func verifySearchable(_ name: String) async throws {
        guard Self.trusted else { throw AppError("请先授予辅助功能权限") }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        _ = try await searchFirst(name)
    }

    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; submitted = false; confirmedImages = 0; imageLeftUnconfirmed = false
        guard ["draft", "automatic"].contains(delivery.mode) else { throw AppError("未知发送模式，未执行") }
        if delivery.mode == "draft" && delivery.assets.contains(where: { !$0.isImage }) { throw AppError("普通文件可能在选择后直接发送，不在草稿模式执行") }
        guard Self.trusted else { throw AppError("请先授予 QQ排程助手辅助功能权限") }
        guard !Self.locked else { throw AppError("Mac 已锁屏，请手动解锁") }
        for a in delivery.assets {
            let u = root.appendingPathComponent(a.relativePath)
            guard a.relativePath.hasPrefix("assets/"), u.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/assets/"), FileManager.default.fileExists(atPath:u.path), try Database.digest(u) == a.sha256 else { throw AppError("素材缺失、路径无效或已改变：\(a.name)") }
            if a.isImage { _ = try ImageAttachment.tiff(at:u) }
        }
        try await openQQ()
        captureClipboard(); defer { restoreClipboard() }
        var w = try await locate(delivery.recipient)
        let compose = try await requireComposerBound(delivery.recipient); try ensureEmpty(compose)
        composerImageBaseline = previewRegionImageCount(compose)
        let baseline = try signature(w, text: delivery.text)
        let beforeLabels = nodes(try chatList(w)).map{ label($0) }
        let allImages = delivery.assets.allSatisfy(\.isImage)
        if allImages {
            // Keep the proven text path first. QQ may show pasted pictures beside the
            // editor without exposing them as AXImage children of the text area.
            try await focus(compose); try key(119, flags: .maskCommand)
            if !delivery.text.isEmpty { try paste(delivery.text) }
            w = try await awaitDraftText(delivery.recipient, delivery.text)
            guard normalized(string(try boundEditor(delivery.recipient),kAXValueAttribute)) == normalized(delivery.text) else { throw AppError("文字未完整进入 QQ 草稿，未粘贴图片或发送") }
        }
        for asset in delivery.assets { try await attach(asset, url:root.appendingPathComponent(asset.relativePath), recipient:delivery.recipient, tolerateUnconfirmedImage: DraftTolerance.toleratesUnconfirmedImage(mode: delivery.mode)) }
        w = try ensureRecipient(delivery.recipient)
        let input = try await requireComposerBound(delivery.recipient)
        if !allImages {
            try await focus(input); try key(119, flags: .maskCommand)
            if !delivery.text.isEmpty { try paste("\n" + delivery.text) }
        }
        w = try await awaitDraftText(delivery.recipient, delivery.text)
        guard normalized(string(try boundEditor(delivery.recipient),kAXValueAttribute)) == normalized(delivery.text) else { throw AppError("草稿文字与计划不一致。请检查 QQ 草稿，未发送") }
        if allImages {
            let expected = delivery.assets.count
            let finalEditor = try boundEditor(delivery.recipient)
            if max(draftImageCount(finalEditor), confirmedImages) < expected {
                // 草稿模式不会发出任何消息：填好内容并如实标注“图片未确认”，交人目视核对；
                // 自动发送模式照旧停住，绝不带着没核验的图片往下走。
                if DraftTolerance.toleratesUnconfirmedImage(mode: delivery.mode) {
                    imageLeftUnconfirmed = true
                } else {
                    throw AppError("无法确认草稿中有计划的 \(expected) 张图片，已保留图文，未发送。\(composerDiagnostic(finalEditor, plannedText: delivery.text))")
                }
            }
        }
        if delivery.mode == "draft" {
            let caution = imageLeftUnconfirmed ? "。注意：图片未能通过辅助功能确认，请在 QQ 里目视核对草稿后再手动发送" : ""
            return ("draft", "已填入正确会话和附件。请在 QQ 手动发送，然后在记录中确认；队列已暂停\(caution)")
        }
        onStep("收件人和草稿已核对，准备提交")
        let submitEditor = try await requireComposerBound(delivery.recipient)
        // 实测在「我的手机」里粘贴图片会弹出“发送到我的手机”确认框，框内自带「发送」按钮：
        // 这种弹窗存在时绝不按键，否则一次 Return 会把弹窗里的内容真的发出去。
        if modalInWay(of: submitEditor) {
            throw AppError("QQ 出现了带「发送」按钮的确认弹窗（例如“发送到我的手机”），已停止且未按键；请在 QQ 手动关闭该弹窗后重试")
        }
        try await focus(submitEditor)
        guard let f = focusedElement(), CFEqual(f, try editor(in:focusedWindow())) else { throw AppError("发送前输入焦点改变，已停止") }
        try beforeSubmit() // durable checkpoint before any final send event
        submitted = true
        // Use QQ's current send shortcut only after checking title and exact draft again.
        _ = try ensureRecipient(delivery.recipient)
        guard let focused = focusedElement(), CFEqual(focused, try editor(in:focusedWindow())),
              ConversationMatch.composerBelongs(to: selectedTitle, description: string(focused, kAXDescriptionAttribute)) else {
            throw AppError("发送前输入框所属会话再次变化，未按下任何发送键；请核对 QQ 草稿，不会自动重发")
        }
        // 只发一条发送指令：能认准 QQ「发送」按钮就点按钮，认不出才按一次 Return。
        let attempted: [SendTrigger] = [try await fireSend(recipient: delivery.recipient, composer: focused)]
        for round in 0..<12 {
            try await wait(round == 0 ? 0.25 : 0.65)
            w = try ensureRecipient(delivery.recipient)
            let currentLabels = nodes(try chatList(w)).map{ label($0) }
            if currentLabels.contains(where: { !beforeLabels.contains($0) && ($0.contains("撤回") || $0.contains("发送失败") || $0.contains("禁言")) }) { return ("uncertain", "发送后出现撤回、禁言或失败信息，请人工核对。不自动重发") }
            let current = try signature(w,text:delivery.text)
            let currentEditor = try boundEditor(delivery.recipient)
            let empty = composerIsEmpty(currentEditor)
            let textMatch = delivery.text.isEmpty || current.matches > baseline.matches
            let imagesMatch = delivery.assets.isEmpty || (delivery.assets.allSatisfy(\.isImage) && current.images >= baseline.images + delivery.assets.count)
            if empty && textMatch && imagesMatch {
                try await wait(1.0)
                let finalLabels = nodes(try chatList(ensureRecipient(delivery.recipient))).map{ label($0) }
                if finalLabels.contains(where: { !beforeLabels.contains($0) && ($0.contains("撤回") || $0.contains("发送失败")) }) { return ("uncertain", "消息出现撤回或失败，请人工核对") }
                return ("verified", "\(Date().formatted()) · 第一条结果「\(selectedTitle)」会话保持一致；草稿清空；消息列表新增匹配内容。仅为客户端可见核验，不是服务器送达回执")
            }
            // 到这里只做核验，不再补第二次发送指令：草稿仍在不能证明 QQ 没提交，
            // 8MB 大图上传可能慢于任何轮询窗口，补触发会真的发出两条重复消息。
        }
        return ("uncertain", "已发出一次发送指令（\(SendAttempt.describe(attempted: attempted))），但无法确认图文/文件完整进入消息列表。为避免重复发送，本次不再按第二次。请到 QQ 查看；若 QQ 把发送快捷键设为 Command+Return，请在 QQ 设置里改为 Enter 发送或手动点发送按钮。不会自动重发")
    }
}
