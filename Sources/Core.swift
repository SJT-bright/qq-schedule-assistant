import Foundation
import CoreGraphics
import SQLite3
import CryptoKit

struct AppError: LocalizedError {
    let message: String
    let axErrorCode: Int32?
    var errorDescription: String? { message }
    init(_ s: String, axErrorCode: Int32? = nil) { message = s; self.axErrorCode = axErrorCode }
}

/// 恢复窗口时使用可见工作区；CGRect 可以是 Cocoa 或 AX 坐标，但双方必须同口径。
enum WindowRestorePlacement {
    static func fitted(_ window: CGRect, within screens: [CGRect]) -> CGRect? {
        func valid(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0 && rect.height > 0
        }
        guard valid(window) else { return nil }
        let usable = screens.filter(valid)
        guard !usable.isEmpty else { return nil }
        if usable.contains(where: { $0.contains(window) }) { return window }
        func area(_ screen: CGRect) -> CGFloat {
            let overlap = screen.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        func distance(_ screen: CGRect) -> CGFloat {
            let x = min(max(window.midX, screen.minX), screen.maxX)
            let y = min(max(window.midY, screen.minY), screen.maxY)
            return hypot(window.midX - x, window.midY - y)
        }
        let screen = usable.enumerated().sorted {
            let left = area($0.element), right = area($1.element)
            if left != right { return left > right }
            let ld = distance($0.element), rd = distance($1.element)
            return ld == rd ? $0.offset < $1.offset : ld < rd
        }.first!.element
        let width = min(window.width, screen.width), height = min(window.height, screen.height)
        return CGRect(x: min(max(window.minX, screen.minX), screen.maxX - width),
                      y: min(max(window.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}

/// 只重试读取，调用者每拍从当前窗口重新取控件；不重复点击、粘贴或发送。
enum QQTransitionRead {
    static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? AppError)?.axErrorCode else { return false }
        // macOS AXError: invalidUIElement / cannotComplete.
        return code == -25202 || code == -25204
    }

    @MainActor
    static func wait(message: String, seconds: Double,
                     beforeRead: () async throws -> Void,
                     pause: () async throws -> Void,
                     onTransient: () -> Void = {},
                     condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var lastReadError: Error?
        repeat {
            try Task.checkCancellation()
            try await beforeRead()
            do {
                if try condition() { return }
                lastReadError = nil
            } catch {
                guard isTransient(error) else { throw error }
                lastReadError = error
                onTransient()
            }
            guard Date() < deadline else { break }
            try await pause()
        } while Date() < deadline
        if let lastReadError { throw lastReadError }
        throw AppError(message)
    }
    @MainActor
    static func waitForStable(message: String, seconds: Double,
                              beforeRead: () async throws -> Void,
                              pause: () async throws -> Void,
                              condition: () throws -> Bool) async throws {
        var consecutive = 0
        try await wait(message: message, seconds: seconds, beforeRead: beforeRead, pause: pause,
                       onTransient: { consecutive = 0 }) {
            consecutive = try condition() ? consecutive + 1 : 0
            return consecutive >= 2
        }
    }
}
/// 身份扫描只看编辑器本身；正文/附件由独立完整读取负责，避免把重渲染的段落当成失效会话。
enum QQControlTree {
    static func prunesChildren(role: String, description: String, classes: [String]) -> Bool {
        if ["AXSheet", "AXDialog"].contains(role) { return false }
        if ["消息列表", "会话列表", "群成员列表"].contains(description) { return true }
        return role == "AXTextArea" && classes.contains("ProseMirror") && classes.contains("ExEditor-qq-msg-editor")
    }
}
enum QQDraftPreflight {
    static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" }
    }
    static func validateConstruction(text: String, expectedText: String, images: Int,
                                     confirmedImages: Int, pasteCommands: Int, toleratePending: Bool) throws {
        try validate(text: text, expectedText: expectedText, images: nil, expectedImages: nil, requireNonEmpty: false)
        let valid = toleratePending ? (images >= confirmedImages && images <= pasteCommands) : images == confirmedImages
        guard valid else { throw AppError("粘贴图片前已有图片与本次填写不符，已保留草稿，未继续粘贴或发送") }
    }
    /// 在唯一提交指令前调用；图片丢失、额外图片或正文变化都不能靠之前的成功读数放行。
    static func validate(text: String, expectedText: String, images: Int?, expectedImages: Int?, requireNonEmpty: Bool = true) throws {
        guard normalized(text) == normalized(expectedText) else {
            throw AppError("提交前 QQ 草稿正文已变化，已保留草稿，未发送")
        }
        if let expectedImages {
            guard let images, images == expectedImages else {
                throw AppError("提交前 QQ 草稿图片数与计划不符（应有 \(expectedImages) 张，读到 \(images.map(String.init) ?? "不可读")），已保留草稿，未发送")
            }
            guard !requireNonEmpty || !normalized(text).isEmpty || expectedImages > 0 else {
                throw AppError("QQ 草稿是空的，没有可发送的内容，未发送")
            }
        }
    }
}
struct ComposerNode {
    var role: String
    var value = ""
    var title = ""
    var description = ""
}
enum ComposerContent {
    static func attachmentCount(_ value: String, imageNodes: Int) -> Int {
        // QQ may expose the same picture as both an AXImage and an object placeholder.
        max(imageNodes, value.filter { $0 == "\u{fffc}" }.count)
    }
    static func imageCount(editorCount: Int, composerImagesBefore: Int, composerImagesNow: Int) -> Int {
        max(editorCount, max(0, composerImagesNow - composerImagesBefore))
    }
    static func isEmpty(_ value: String, descendants: [ComposerNode]) -> Bool {
        func blank(_ text: String) -> Bool { text.replacingOccurrences(of:"\u{200b}",with:"").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        guard blank(value) else { return false }
        return descendants.allSatisfy { node in
            ["AXGroup","AXStaticText","AXTextArea"].contains(node.role) && blank(node.value) && blank(node.title) && blank(node.description)
        }
    }
}
/// 只接收消息输入框内部的树；QQ 的内联图片是 AXGroup，而不一定是 AXImage。
/// 每个附件根只计一次，不能把同一附件的包装节点和图片子节点重复相加。
struct ComposerImageNode: Equatable {
    var role: String
    var classes: [String] = []
    var children: [ComposerImageNode] = []
}
enum ComposerImageCount {
    static let qqInlineImageClass = "editor-el--inline-block"
    static func count(_ node: ComposerImageNode) -> Int {
        if node.role == "AXToolbar" { return 0 }
        if node.role == "AXImage" { return 1 }
        if node.role == "AXGroup", node.classes.contains(qqInlineImageClass) { return 1 }
        return node.children.reduce(0) { $0 + count($1) }
    }
}
enum ComposerSession {
    /// QQ 的占位描述可能在填入正文后消失。只接受原来已绑定的同一个输入框；
    /// 陈旧描述只有在同一输入框与真实聊天结构都绑定时才可以忽略。
    /// structuredBinding 必须来自驱动验证的同源聊天容器，不等同于旧句柄仍存在。
    static func accepts(description: String, title: String, sameEditor: Bool, bindingsIntact: Bool,
                        structuredBinding: Bool = false) -> Bool {
        guard bindingsIntact, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if sameEditor && structuredBinding { return true }
        let marked = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if marked.isEmpty { return sameEditor }
        return ConversationMatch.composerBelongs(to: title, description: marked, looseContains: false)
    }
}
/// 可见聊天区域的几何边界。结构同源、候选唯一和连续稳定由驱动另外验证；
/// 几何符合只是必要条件，不能凭窗口里恰好出现同名文字建立会话绑定。
enum QQConversationGeometry {
    static func valid(window: CGRect?, pane: CGRect?, header: CGRect?, messages: CGRect?, composer: CGRect?) -> Bool {
        guard let window, let pane, let header, let messages, let composer else { return false }
        let frames = [window, pane, header, messages, composer]
        guard frames.allSatisfy({ rect in
            rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
        }) else { return false }
        // AX frame可能有亚像素舍入差。容差仅处理边缘误差，不允许侧栏或其他窗格冒充聊天节点。
        let tolerance: CGFloat = 1
        func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
            inner.minX >= outer.minX - tolerance && inner.maxX <= outer.maxX + tolerance &&
            inner.minY >= outer.minY - tolerance && inner.maxY <= outer.maxY + tolerance
        }
        func horizontallyWithinMessages(_ rect: CGRect) -> Bool {
            rect.minX >= messages.minX - tolerance && rect.maxX <= messages.maxX + tolerance
        }
        guard contains(window, pane), [header, messages, composer].allSatisfy({ contains(window, $0) && contains(pane, $0) }),
              horizontallyWithinMessages(header), horizontallyWithinMessages(composer),
              header.maxY <= messages.minY + tolerance,
              messages.maxY <= composer.minY + tolerance else { return false }
        return true
    }
}
/// QQ（Electron 布局）把输入框包在一层只有一个子节点的壳里，配图预览与输入框并不在同一父节点下：
/// 实测 AXTextArea.parent 只有它自己，预览条在再往上、与会话工具栏 AXToolbar 同级的那一层里。
/// 因此预览区只能按“祖先链里第一个带工具栏的层”来挑，并且必须排除工具栏本身，
/// 否则要么恒为 0（永远确认不了配图），要么把消息列表里的头像/表情当成附件。
enum ComposerRegion {
    static let toolbarRole = "AXToolbar"
    /// childRoles 自内向外：childRoles[0] 是输入框直接父节点的子角色列表。
    /// 返回配图预览区所在层号；找不到工具栏时回落到 0 层，保持旧版行为，不外扩到消息列表。
    static func previewLevel(childRoles: [[String]]) -> Int {
        for (level, roles) in childRoles.enumerated() where roles.contains(toolbarRole) { return level }
        return 0
    }
    /// 预览区内各分支的图片数之和；工具栏分支不计入（QQ 会话工具栏本身就有 11 个图片节点）。
    static func previewImageCount(children: [(role: String, imageCount: Int)]) -> Int {
        children.filter { $0.role != toolbarRole }.reduce(0) { $0 + max(0, $1.imageCount) }
    }
}
/// 输入区的一次结构快照：图片节点、按钮、节点总数与输入框高度。
/// 只用于“确认不了时如实交代现场”。这些数字的变化都不是图片已进草稿的证据：
/// QQ 异步重渲染会让它们自己变化，反过来图片也可能渲染成 Chromium 根本不暴露的无名节点。
struct ComposerSnapshot: Equatable {
    var images = 0
    var buttons = 0
    var nodes = 0
    var editorHeight: CGFloat = 0
    /// 输入区里出现过的 DOM 类名，只用于诊断；图片张数按输入框内的独立节点读取。
    var classTokens: [String] = []
    /// AXNumberOfCharacters 与 AXValue 原文：两者不匹配才说明框里还有非文本的内联对象。
    var characters = -1
    var text = ""
}
/// 失败现场的差值计算：只负责“如实描述”，不参与能否发送的判定。
enum ComposerDiagnostic {
    static func newClasses(before: [String], now: [String]) -> [String] {
        let old = Set(before)
        return Set(now).subtracting(old).sorted()
    }
    /// 正文已逐字核对通过，但字符数比正文长，说明输入框里还有不体现在文本里的内容（例如内嵌图片）。
    static func extraCharacters(textLength: Int, characterCount: Int) -> Int {
        guard characterCount >= 0 else { return 0 }
        return max(0, characterCount - textLength)
    }
}
/// 触发发送前的弹窗闸门。实测：在「我的手机」里粘贴图片会弹出“发送到我的手机”确认框，
/// 框内自带「发送」按钮——对着它按键会把弹窗里的东西发出去。有弹窗一律不触发发送。
enum SendGate {
    static func blockedByModal(modalPresent: Bool, sendButtonsOutsideComposer: Int) -> Bool {
        return modalPresent || sendButtonsOutsideComposer > 0
    }
    static func isSendConfirmationButton(_ label: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "发送" || text == "Send" { return true }
        for prefix in ["发送(", "Send("] where text.hasPrefix(prefix) && text.hasSuffix(")") {
            let count = text.dropFirst(prefix.count).dropLast()
            if !count.isEmpty && count.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}
/// 只有“填写草稿、绝不发送”的任务才允许在图片确认不了时继续把内容填好；
/// 自动发送任务一律停住，不能靠猜测把没核验的东西发出去。
enum DraftTolerance {
    static func toleratesUnconfirmedImage(mode: String) -> Bool { mode == "draft" }
}
/// 粘贴期间的文字一致性与弱信号诊断。字符差值或 class 集合不替代图片节点计数。
enum ComposerImageSignal {
    static let imageTokens: [String] = ["image", "img", "photo", "picture", "media", "attach"]
    static func sameVisibleText(before: String, after: String) -> Bool {
        func visible(_ text: String) -> String {
            text.filter { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" }
        }
        return visible(before) == visible(after)
    }
    /// 只认“粘贴之后新出现、且名字明确指向图片”的 class；空草稿里本来就有的
    /// q-icon / q-svg-icon / expression-panel / sticker-* / avatar 等一律不算图片证据。
    /// QQ 群聊实测的图片缩略图是 editor-el--inline-block（同帧有可见缩略图）。
    static func newImageClasses(before: [String], now: [String]) -> [String] {
        let old = Set(before)
        return Set(now).subtracting(old).filter { token in
            let lower = token.lowercased()
            return lower == "editor-el--inline-block" || imageTokens.contains { lower.contains($0) }
        }.sorted()
    }
    /// 文本一字未改（AXValue 完全相同）而字符数变多，多出来的只能是不以文本形式存在的内联对象。
    static func inlineObjectAdded(textUnchanged: Bool, charactersBefore: Int, charactersAfter: Int) -> Bool {
        guard textUnchanged, charactersBefore >= 0, charactersAfter >= 0 else { return false }
        return charactersAfter > charactersBefore
    }
}
/// 触发 QQ 发送的手段。一次任务只允许发出其中一个，且只发一次。
enum SendTrigger: Int, CaseIterable {
    case sendButton, returnKey
}
/// 发送触发判定。安全底线：能认准 QQ「发送」按钮就点按钮，认不出才按一次 Return；
/// 之后只做核验，绝不因为“草稿还在 / 250 毫秒没变化”补第二次触发——
/// 大图上传可能明显慢于任何轮询窗口，补触发会造成真实重复发送。未核验成功一律转人工核对。
enum SendAttempt {
    /// 只有按钮标题本身就是“发送”才认，避免把“发送到桌面”等同名片段或工具栏按钮误当成发送入口。
    static func isSendButtonLabel(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines) == "发送"
    }
    static func firstTrigger(buttonFound: Bool) -> SendTrigger { buttonFound ? .sendButton : .returnKey }
    /// 恒定 false：任何核验结果都不解锁第二次发送指令。微信也不补按 Command+Return。
    static let allowsSecondTrigger = false
    /// 微信只按过一次 Return，草稿却还在。不再发第二条指令。
    static let weChatDraftRemains = "已按一次 Return（回车键），草稿仍未清空。为避免重复发送，不再按第二次。请到微信查看是否已发出，切勿手动重复发送。若微信设置的是「Enter 换行」或「Cmd+Enter 发送」，请到微信设置改为「Enter 发送」——Mac 上 Enter 与 Return 是同一个键。不会自动重发"
    /// 如实交代这次实际发出过哪条发送指令，写进待核对记录里供人工判断。
    static func describe(attempted: [SendTrigger]) -> String {
        let names: [SendTrigger: String] = [.sendButton: "QQ 发送按钮", .returnKey: "Return"]
        return attempted.isEmpty ? "未触发任何发送指令" : attempted.compactMap { names[$0] }.joined(separator: "、")
    }
}

/// 走查/验收探针（约束 3）。设了 `QQ_DISPATCH_NO_SEND` 环境变量时，一切会驱动真实 QQ/微信的
/// 入口都必须先问这里并直接返回，绝不启动驱动。
/// 走查 1-09 的漏网入口是「按已核对草稿续发」——它不走 `execute`，所以绕过了最内层兜底。
/// 新增任何发送/驱动入口时，把名字加进 `drivenEntries` 并在该入口开头调用 `refusal(entry:)`。
enum DispatchProbe {
    static let environmentKey = "QQ_DISPATCH_NO_SEND"
    /// 已知会驱动真实客户端的入口清单，供逐个核对是否都加了拦截。
    static let drivenEntries: [String] = [
        "启动队列", "创建并启动", "单条立即发送", "另开只填写不发送的任务", "试跑定位",
        "打开关系收件箱聊天", "排期任务执行", "人工核对后重新发送", "按已核对草稿续发",
    ]
    static var isActive: Bool { ProcessInfo.processInfo.environment[environmentKey] != nil }
    /// 探针生效时返回拦截说明；未设变量返回 nil（正式运行零影响）。
    static func refusal(entry: String, active: Bool = isActive) -> String? {
        guard active else { return nil }
        return "探针模式：已拦截「\(entry)」；不会打开 QQ 或微信，也不会按下任何发送键"
    }
    /// 入口清单自检：重名或空名说明有人新增入口时改错了，测试会直接失败。
    static var drivenEntriesAreUnique: Bool { Set(drivenEntries).count == drivenEntries.count && drivenEntries.allSatisfy { !$0.isEmpty } }
}

/// 发送指令已经发出之后的一拍核验。标注暂时对不上只说明这一拍不能下结论；
/// 「已离开」才立刻停止。任何结论都不解锁第二次发送。
/// 发送前的标注不符不走这里，仍停在发送键之前；若草稿已写入则保留现场。
/// 仅接受消息列表的系统提示或独立失败控件，不扫描聊天正文里的关键词。
enum PostSendNotice {
    enum Kind: Equatable { case failure, ownRecall, recall }
    static func kind(label: String, systemNotice: Bool, errorControl: Bool = false) -> Kind? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if errorControl && (text == "发送失败" || text == "消息发送失败") { return .failure }
        guard systemNotice else { return nil }
        if text.contains("发送失败") || text.contains("禁言") { return .failure }
        if text.contains("你撤回了一条消息") || text.contains("你撤回了一条成员消息") ||
            (text.contains("你的消息") && text.contains("撤回")) { return .ownRecall }
        return text.contains("撤回") ? .recall : nil
    }
    /// 保留重复提示的数量：新出现的同文提示也需要核验。
    static func added(before: [String], current: [String]) -> [String] {
        var counts = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        return current.filter { label in
            if let count = counts[label], count > 0 { counts[label] = count - 1; return false }
            return true
        }
    }
}

/// 输入框标注异常时，只接受原窗口、原输入框和同一条新增本人图文消息的直接证据。
enum QQSendPhase: String, Codable {
    case unknown, pending, failed, quiet
    /// Only controls in this own message row are inspected; body strings are never status labels.
    static func read(structured: Bool, classes: [String], controlLabels: [String], busy: Bool, progress: Bool) -> Self {
        if classes.contains(where: { $0.contains("msg-fail") || $0.contains("send-fail") || $0.contains("message-fail") })
            || controlLabels.contains(where: { ["发送失败", "重新发送", "重发", "发送超时"].contains($0) }) { return .failed }
        if busy || progress || classes.contains(where: {
            ["loading", "loading-icon", "q-loading", "msg-loading", "send-loading", "msg-pending", "message-sending", "sending"].contains($0)
            || $0.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(where: {
                ["loading", "progress", "pending", "sending", "uploading"].contains($0)
            })
        }) || controlLabels.contains(where: { ["发送中", "正在发送", "上传中", "正在上传"].contains($0) }) { return .pending }
        guard structured else { return .unknown }
        if classes.contains(where: { $0.contains("send-status") || $0.contains("msg-status") }) { return .unknown }
        return .quiet
    }
}

/// Narrow, empirically checked QQ 7.0.2-53644 self-row encoding, not a server receipt.
/// The local self ID carries seconds + 200 days; never apply it to inbound rows or other versions.
enum QQMessageClock {
    static let supportedVersion = "7.0.2-53644"
    static func creation(_ id: String) -> Date? {
        guard id.count == 19, id.allSatisfy({ $0.isASCII && $0.isNumber }),
              let raw = UInt64(id), raw >> 32 > 17_280_000 else { return nil }
        return Date(timeIntervalSince1970: Double((raw >> 32) - 17_280_000))
    }
    static func matches(_ id: String, timeLabel: String?, timezoneOffset: Int?) -> Bool {
        guard let date = creation(id), let timeLabel, let timezoneOffset,
              (-14 * 3600...14 * 3600).contains(timezoneOffset), let zone = TimeZone(secondsFromGMT: timezoneOffset) else { return false }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone; format.dateFormat = "HH:mm"
        return format.string(from: date) == timeLabel
    }
    static func isFresh(_ message: OwnMessageProof, submittedAt: Date, observedAt: Date, version: String) -> Bool {
        message.phase == .quiet && belongsToSubmission(message, submittedAt: submittedAt, observedAt: observedAt, version: version)
    }
    static func belongsToSubmission(_ message: OwnMessageProof, submittedAt: Date, observedAt: Date, version: String) -> Bool {
        guard version == supportedVersion,
              let creation = creation(message.id), creation > submittedAt, creation <= observedAt else { return false }
        return matches(message.id, timeLabel: message.timeLabel, timezoneOffset: message.timezoneOffset)
    }
}

struct OwnMessageProof: Codable, Equatable {
    var id: String
    var textMatches: Bool
    var images: Int
    var phase: QQSendPhase = .unknown
    var timeLabel: String? = nil
    var timezoneOffset: Int? = nil
    static func candidate(in messages: [OwnMessageProof], beforeIDs: Set<String>, requiredImages: Int) -> String? {
        messages.first { !$0.id.isEmpty && !beforeIDs.contains($0.id) && $0.textMatches && $0.images >= requiredImages }?.id
    }
    static func acceptsStaleLabel(sameEditor: Bool, draftCleared: Bool, messageID: String?) -> Bool {
        sameEditor && draftCleared && messageID != nil
    }
}

/// 有序消息行和同一次读取中的本人消息。当前渲染的 ID 差集本身不是发送证据。
struct QQMessageSnapshot: Codable, Equatable {
    var rowIDs: [String]
    var ownMessages: [OwnMessageProof]
    /// 仅由可读的实际消息滚动条确认；缺少位置证据时必须保持 false。
    var atLatest = false
    var isTrustworthy: Bool {
        guard !rowIDs.isEmpty, rowIDs.allSatisfy({ !$0.isEmpty }),
              Set(rowIDs).count == rowIDs.count else { return false }
        let ownIDs = ownMessages.map(\.id)
        return ownIDs.allSatisfy { rowIDs.contains($0) } && Set(ownIDs).count == ownIDs.count
    }
    /// 发送前最后至多三行必须仍连续、按原顺序存在；只接受原尾行后新增的本人消息。
    /// 纯图片/文件无法凭正文或张数识别内容，暂交人工核对。
    static func candidate(baseline: QQMessageSnapshot, current: QQMessageSnapshot,
                          requiredImages: Int, hasText: Bool) -> OwnMessageProof? {
        guard baseline.atLatest, current.atLatest else { return nil }
        return appended(baseline: baseline, current: current, requiredImages: requiredImages, hasText: hasText)
            .last { $0.phase != .pending && $0.phase != .failed }
    }
    static func freshCandidate(baseline: QQMessageSnapshot, current: QQMessageSnapshot,
                               requiredImages: Int, hasText: Bool, submittedAt: Date, observedAt: Date,
                               version: String) -> OwnMessageProof? {
        let candidates = appended(baseline: baseline, current: current, requiredImages: requiredImages, hasText: hasText)
            .filter { QQMessageClock.isFresh($0, submittedAt: submittedAt, observedAt: observedAt, version: version) }
        return candidates.count == 1 ? candidates[0] : nil
    }
    static func appended(baseline: QQMessageSnapshot, current: QQMessageSnapshot,
                         requiredImages: Int, hasText: Bool) -> [OwnMessageProof] {
        guard hasText, requiredImages >= 0,
              baseline.isTrustworthy, current.isTrustworthy else { return [] }
        let anchor = Array(baseline.rowIDs.suffix(3))
        guard let anchorStart = current.rowIDs.firstIndex(of: anchor[0]),
              anchorStart + anchor.count <= current.rowIDs.count,
              Array(current.rowIDs[anchorStart..<(anchorStart + anchor.count)]) == anchor else { return [] }
        let appended = Set(current.rowIDs.dropFirst(anchorStart + anchor.count)).subtracting(baseline.rowIDs)
        let byID = Dictionary(uniqueKeysWithValues: current.ownMessages.map { ($0.id, $0) })
        return current.rowIDs.compactMap { id in
            guard appended.contains(id), let proof = byID[id], proof.textMatches,
                  proof.images == requiredImages else { return nil }
            return proof
        }
    }
}

/// 本次提交的持久化核验依据；同一消息的两次观察由驱动采集，不用描述文字替代。
struct QQVerificationEvidence: Codable, Equatable {
    var ruleVersion = 1
    var deliveryID: String
    var selectedTitle: String
    var trigger: String
    var submittedAt: Date
    var firstObservedAt: Date
    var confirmedAt: Date
    var baselineRowIDs: [String]
    var confirmedRowIDs: [String]
    var messageID: String
    var textMatches: Bool
    var images: Int
    var requiredImages: Int
    var draftCleared: Bool
    var baselineAtLatest = false
    var confirmedAtLatest = false
    var qqVersion: String? = nil
    var messageTimeLabel: String? = nil
    var messageTimezoneOffset: Int? = nil
    var confirmedPhase: QQSendPhase? = nil

    func isValid(for delivery: Delivery) -> Bool {
        let hasText = delivery.text.contains { !$0.isWhitespace && $0 != "\u{200b}" && $0 != "\u{fffc}" }
        guard [1, 2].contains(ruleVersion), deliveryID == delivery.id, hasText,
              !selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let started = delivery.started, let recordedSubmit = delivery.submittedAt,
              submittedAt >= started, abs(submittedAt.timeIntervalSince(recordedSubmit)) <= 5,
              firstObservedAt >= submittedAt, confirmedAt.timeIntervalSince(firstObservedAt) >= 0.8,
              requiredImages == delivery.assets.filter(\.isImage).count, draftCleared else { return false }
        if ruleVersion == 2 {
            let proof = OwnMessageProof(id: messageID, textMatches: textMatches, images: images,
                phase: confirmedPhase ?? .unknown, timeLabel: messageTimeLabel, timezoneOffset: messageTimezoneOffset)
            return QQMessageSnapshot.freshCandidate(
                baseline: QQMessageSnapshot(rowIDs: baselineRowIDs, ownMessages: [], atLatest: baselineAtLatest),
                current: QQMessageSnapshot(rowIDs: confirmedRowIDs, ownMessages: [proof], atLatest: confirmedAtLatest),
                requiredImages: requiredImages, hasText: hasText, submittedAt: submittedAt,
                observedAt: firstObservedAt, version: qqVersion ?? "") == proof
        }
        let proof = OwnMessageProof(id: messageID, textMatches: textMatches, images: images)
        return QQMessageSnapshot.candidate(
            baseline: QQMessageSnapshot(rowIDs: baselineRowIDs, ownMessages: [], atLatest: baselineAtLatest),
            current: QQMessageSnapshot(rowIDs: confirmedRowIDs, ownMessages: [proof], atLatest: confirmedAtLatest),
            requiredImages: requiredImages, hasText: hasText) == proof
    }
}

extension OwnMessageProof {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        textMatches = try values.decode(Bool.self, forKey: .textMatches)
        images = try values.decode(Int.self, forKey: .images)
        phase = try values.decodeIfPresent(String.self, forKey: .phase).flatMap(QQSendPhase.init(rawValue:)) ?? .unknown
        timeLabel = try values.decodeIfPresent(String.self, forKey: .timeLabel)
        timezoneOffset = try values.decodeIfPresent(Int.self, forKey: .timezoneOffset)
    }
}

extension QQMessageSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rowIDs = try values.decode([String].self, forKey: .rowIDs)
        ownMessages = try values.decode([OwnMessageProof].self, forKey: .ownMessages)
        atLatest = try values.decodeIfPresent(Bool.self, forKey: .atLatest) ?? false
    }
}

extension QQVerificationEvidence {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ruleVersion = try values.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1
        deliveryID = try values.decode(String.self, forKey: .deliveryID)
        selectedTitle = try values.decode(String.self, forKey: .selectedTitle)
        trigger = try values.decode(String.self, forKey: .trigger)
        submittedAt = try values.decode(Date.self, forKey: .submittedAt)
        firstObservedAt = try values.decode(Date.self, forKey: .firstObservedAt)
        confirmedAt = try values.decode(Date.self, forKey: .confirmedAt)
        baselineRowIDs = try values.decode([String].self, forKey: .baselineRowIDs)
        confirmedRowIDs = try values.decode([String].self, forKey: .confirmedRowIDs)
        messageID = try values.decode(String.self, forKey: .messageID)
        textMatches = try values.decode(Bool.self, forKey: .textMatches)
        images = try values.decode(Int.self, forKey: .images)
        requiredImages = try values.decode(Int.self, forKey: .requiredImages)
        draftCleared = try values.decode(Bool.self, forKey: .draftCleared)
        baselineAtLatest = try values.decodeIfPresent(Bool.self, forKey: .baselineAtLatest) ?? false
        confirmedAtLatest = try values.decodeIfPresent(Bool.self, forKey: .confirmedAtLatest) ?? false
        qqVersion = try values.decodeIfPresent(String.self, forKey: .qqVersion)
        messageTimeLabel = try values.decodeIfPresent(String.self, forKey: .messageTimeLabel)
        messageTimezoneOffset = try values.decodeIfPresent(Int.self, forKey: .messageTimezoneOffset)
        confirmedPhase = try values.decodeIfPresent(String.self, forKey: .confirmedPhase).map { QQSendPhase(rawValue: $0) ?? .unknown }
    }
}

enum QQVerificationReview {
    /// 旧版只保存结论文字，无法重建消息 ID / 尾锚；保留原凭据并等待人工复核，绝不重发。
    static func recovered(_ jobs: [Delivery]) -> [Delivery] {
        jobs.map { job in
            guard job.channelName == SendChannel.qq, job.status == "verified",
                  job.qqVerification?.isValid(for: job) != true else { return job }
            var pending = job
            pending.status = "uncertain"
            pending.detail = SendChannel.keptRecord(note: "旧版核验凭据不足：没有可复查的本次消息 ID 与发送前尾锚，已撤销自动完成状态；请到 QQ 人工核对，不会自动重发", previous: job.detail)
            return pending
        }
    }
}

enum PostSendWatch {
    enum Reaction: Equatable {
        case abort
        case inconclusive(label: String?)
    }
    enum Sample: Equatable {
        case leftSession
        case labelMismatch(String)
        case unreadable
        case bound(draftCleared: Bool, textAppeared: Bool, imagesAppeared: Bool)
    }
    enum Verdict: Equatable {
        case abort
        case readyToVerify
        case keepWatching
    }

    /// 只重试两种可恢复的输入框读数；暂停、锁屏、前台变化及未知异常必须立即停止。
    static func reaction(toEditorError message: String) -> Reaction {
        if message.hasPrefix("输入框当前标注为「"), message.contains("与已选中的「"), message.hasSuffix("不一致") {
            return .inconclusive(label: observedLabel(in: message))
        }
        if message == "未能唯一定位 QQ 消息输入框，请关闭其他弹窗" {
            return .inconclusive(label: nil)
        }
        return .abort
    }

    static func observedLabel(in message: String) -> String? {
        guard message.contains("输入框当前标注为") else { return nil }
        guard let open = message.range(of: "「"),
              let close = message.range(of: "」", range: open.upperBound..<message.endIndex) else { return nil }
        let label = String(message[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    static func sample(forEditorError message: String) -> Sample {
        switch reaction(toEditorError: message) {
        case .abort:
            return .leftSession
        case .inconclusive(let label):
            if let label { return .labelMismatch(label) }
            return .unreadable
        }
    }

    /// 按时间顺序看每一拍。会话一旦离开，后面即使出现「草稿已空且消息新增」也不再采纳。
    static func verdict(_ samples: [Sample]) -> Verdict {
        for sample in samples {
            switch sample {
            case .leftSession:
                return .abort
            case .labelMismatch, .unreadable:
                continue
            case .bound(let draftCleared, let textAppeared, let imagesAppeared):
                if draftCleared && textAppeared && imagesAppeared { return .readyToVerify }
            }
        }
        return .keepWatching
    }

    static func unresolvedDetail(trigger: String, selectedTitle: String, observedLabel: String?, manual: Bool = false) -> String {
        var text = manual
            ? "已按人工核对发出一次发送指令（\(trigger)），但无法确认图文完整进入消息列表。为避免重复发送不再按第二次，请到 QQ 查看；不会自动重发"
            : "已发出一次发送指令（\(trigger)），但无法确认图文/文件完整进入消息列表。为避免重复发送，本次不再按第二次。请到 QQ 查看；若 QQ 把发送快捷键设为 Command+Return，请在 QQ 设置里改为 Enter 发送或手动点发送按钮。不会自动重发"
        if let observedLabel, !observedLabel.isEmpty {
            text += "。核验时输入框曾标注为「\(observedLabel)」，与已选中的「\(selectedTitle)」不一致"
        }
        return text
    }

    static func preSendMismatchDetail(marked: String, selected: String, draftMayExist: Bool = false) -> String {
        let name = marked.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? "未命名会话" : name
        let result = draftMayExist ? "草稿可能已保留，未按发送键" : "未粘贴、未发送"
        return "QQ 输入框当前标注为「\(shown)」，与刚选中的「\(selected)」不一致（可能还在切换会话），已停止：\(result)"
    }
}
/// 点击点上谁会接到鼠标。窗口按从前到后排列；非零层级和全透明层不能把后面的真实窗口放行。
enum ClickCover {
    struct Window: Equatable {
        var ownerPID: Int32
        var layer: Int
        var alpha: Double
        var bounds: CGRect
        var regular: Bool
        var name: String
    }
    /// 判定口径（走查 1-19 修正）：
    /// ①全透明层与退化尺寸不算遮挡；②负层级（桌面、背衬、Dock 的壁纸层）永远接不到这个点，也不算遮挡；
    /// ③其余窗口按从前到后第一个盖住落点的人来定：目标应用自己接到点击就放行，
    ///   本程序或第三方应用（常规窗口，或尺寸足够大的浮窗）挡住就如实报出，不再因为「层级非零」直接跳过。
    /// 注意：这会影响真实点击，部署后需用「试跑定位」复核一次（见修复说明 fixes-B-core.md）。
    static func blocker(at point: CGPoint, windows: [Window], targetPID: Int32, selfPID: Int32, selfName: String) -> String? {
        for window in windows {
            guard window.alpha > 0.01, window.bounds.width > 1, window.bounds.height > 1, window.bounds.contains(point) else { continue }
            guard window.layer >= 0 else { continue }
            if window.ownerPID == targetPID { return nil }
            if window.ownerPID == selfPID { return selfName }
            if window.regular || (window.bounds.width > 40 && window.bounds.height > 40) {
                return window.name.isEmpty ? "其他应用" : window.name
            }
        }
        return nil
    }
}

/// 图片确认轮询时如何对待当前前台。只允许本进程自己占着前台时把目标应用唤回；
/// 第三方应用或读不到前台都立刻停止，不能替用户把焦点抢回来。判定只用进程号，不看应用显示名。
enum ForegroundRecovery {
    enum Decision: Equatable {
        case targetIsFront
        case recoverOwnApp
        case stop
    }
    static func decision(frontPID: Int32?, targetPID: Int32, selfPID: Int32) -> Decision {
        guard let frontPID else { return .stop }
        if frontPID == targetPID { return .targetIsFront }
        if frontPID == selfPID { return .recoverOwnApp }
        return .stop
    }
}

/// 把前台交回 QQ/微信时窗口该怎么动。`NSWindow.orderBack` 不论本程序是不是前台，都会把
/// 自己的窗口沉到同一层级的最底：夹在中间的 Chrome、Finder 会盖住 QQ，搜索下拉随即收起，
/// 之后的物理点击落到别人窗口上。现场 blocked 记录就是这一步把前台切到了 Google Chrome。
enum ForegroundHandoff {
    /// 浮动通知和 Dock 的合成窗口不是键盘前台；只用普通应用窗口确定顺序。
    /// 浮窗是否遮住点击位置由点击点的独立校验处理。
    static func firstNormalWindowPID(rows: [ForegroundAnomaly.WindowRow], regularPIDs: Set<Int32>) -> Int32? {
        rows.first { $0.layer == 0 && $0.width > 1 && $0.height > 1 && regularPIDs.contains($0.ownerPID) }?.ownerPID
    }
    enum Action: Equatable {
        case uncoverTarget
        case yieldToTarget
        case stop
    }
    static func action(frontPID: Int32?, targetPID: Int32, selfPID: Int32) -> Action {
        switch ForegroundRecovery.decision(frontPID: frontPID, targetPID: targetPID, selfPID: selfPID) {
        case .targetIsFront: return .uncoverTarget
        case .recoverOwnApp: return .yieldToTarget
        case .stop: return .stop
        }
    }
    /// 任何状态下都不允许 orderBack。把 QQ 送到前面只走 yieldActivation + activate。
    static func mayOrderBackOwnWindows(_ action: Action) -> Bool {
        switch action {
        case .uncoverTarget, .yieldToTarget, .stop: return false
        }
    }
    /// 实时窗口列表优先；读不到再退回 NSWorkspace 的异步缓存。
    static func observedFrontPID(live: Int32?, cached: Int32?) -> Int32? {
        live ?? cached
    }
}

/// 前台异常细分（只用于失败文案归类，不改 check() 的通过/失败边界）。
/// 背景：目标应用窗口全部最小化/关闭时，实时窗口列表会把排在其后的应用（Finder/Chrome）
/// 读成“最前”，旧文案因此点名无辜应用（现场 blocked 记录里就有「前台已切换到 Google Chrome」）。
/// 实际那是目标自己没有可见窗口——文案必须分开。四类：
/// ①目标在前台；②目标进程在跑但没有任何可见普通窗口；③前台确实是其他应用；④读不到前台。
enum ForegroundAnomaly {
    /// CGWindowList 一行的最小摘要，足够判断“是不是目标的普通可见窗口”。
    struct WindowRow: Equatable {
        var ownerPID: Int32
        var layer: Int
        var width: CGFloat
        var height: CGFloat
    }
    enum Classification: Equatable {
        case targetIsFront
        case targetHasNoVisibleWindow
        case otherAppFront
        case frontUnknown
    }
    /// 目标应用有没有普通层（layer 0）、非退化尺寸的可见窗口。
    /// 与 liveFrontmostPID / ClickCover 同口径：宽高 > 1 才算；状态项、菜单条、Dock 等非 0 层不算。
    static func hasVisibleWindow(targetPID: Int32, rows: [WindowRow]) -> Bool {
        rows.contains { $0.ownerPID == targetPID && $0.layer == 0 && $0.width > 1 && $0.height > 1 }
    }
    /// 纯分类。通过/失败边界不变：仍只有 frontPID == targetPID 才算通过（targetIsFront，
    /// 调用方不会以此生成失败文案）。目标自己没有可见窗口时优先归为 targetHasNoVisibleWindow——
    /// 此时“最前是别的应用”只是窗口列表的读数副作用，不是真正的抢前台。
    static func classify(frontPID: Int32?, targetPID: Int32, targetHasVisibleWindow: Bool) -> Classification {
        guard let frontPID else { return .frontUnknown }
        if frontPID == targetPID { return .targetIsFront }
        if !targetHasVisibleWindow { return .targetHasNoVisibleWindow }
        return .otherAppFront
    }
}

/// QQ NT 本地搜索下拉不再用 AXMenuItem，群聊结果是带文本的 Group/Row/Button。
enum QQSearchLayout {
    struct Sibling: Equatable {
        var role: String
        var name: String
        var hasNestedRow: Bool
        var hasText: Bool
        var height: CGFloat = 0
    }
    static let nextCategoryNames: Set<String> = ["好友", "聊天记录", "文件", "联系人", "综合", "群成员", "搜索综合结果"]
    static let rowRoles: Set<String> = ["AXMenuItem", "AXRow", "AXCell", "AXButton", "AXGroup", "AXListItem", "AXLink"]
    static let chromeNames: Set<String> = ["清空", "搜索", "关闭"]
    /// 会话行大约 48–64pt；整片下拉容器会到几百 pt，点它的中心会落到后面的分类上。
    static let compactRowMaxHeight: CGFloat = 96
    static let compactRowMinHeight: CGFloat = 18
    /// 即使 AX 设值已经等于查询词，也必须再 Cmd+A 粘贴：QQ NT 不消费 AXValue 变化，页面不会检索。
    static var alwaysCommitSearchWithKeystrokes: Bool { true }
    /// 展开搜索框可能只改变宽度。只接受同一窗口顶部、同一左上位置的窄文本框。
    static func matchesAnchor(_ frame: CGRect, anchor: CGRect, window: CGRect?) -> Bool {
        guard let window, frame.width >= 24, frame.height >= 12, frame.height <= 48,
              window.insetBy(dx: -2, dy: -2).contains(frame),
              frame.midY - window.minY <= max(96, window.height * 0.22) else { return false }
        return abs(frame.minX - anchor.minX) < 8 && abs(frame.minY - anchor.minY) < 8 &&
            abs(frame.height - anchor.height) < 8
    }
    static func isNextCategory(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return nextCategoryNames.contains(trimmed) || ConversationMatch.badges.contains(trimmed)
    }
    static func isCompactResultHeight(_ height: CGFloat) -> Bool {
        height >= compactRowMinHeight && height <= compactRowMaxHeight
    }
    /// 一串候选高度里优先点真正的结果行，而不是包住整片下拉的大 Group。
    static func preferredClickIndex(heights: [CGFloat]) -> Int? {
        if let i = heights.firstIndex(where: isCompactResultHeight) { return i }
        return heights.isEmpty ? nil : 0
    }
    /// 群聊分类标题之后、下一分类之前，第一条可点开的结果行。
    static func firstOpenableIndex(afterGroupHeading siblings: [Sibling]) -> Int? {
        for (i, node) in siblings.enumerated() {
            let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if node.role == "AXStaticText" && isNextCategory(name) { return nil }
            if node.role == "AXStaticText" { continue }
            guard rowRoles.contains(node.role) else { continue }
            if chromeNames.contains(name) { continue }
            if ConversationMatch.badges.contains(name) { continue }
            if node.role == "AXGroup" && name.isEmpty && !node.hasNestedRow && !node.hasText { continue }
            return i
        }
        return nil
    }
}

/// 进度块该用哪一种外观。待核对会呼吸提示；已暂停是安静的暂停色，不假装正在发送，也不挡启动。
enum ProgressTone: Equatable {
    case pending, sending, done, review, paused, cancelled
    static func tone(for status: String) -> ProgressTone {
        switch status {
        case "queued": return .pending
        case "running": return .sending
        case "verified", "manual": return .done
        case "draft", "uncertain", "submitted": return .review
        case "blocked": return .paused
        case "cancelled": return .cancelled
        default: return .pending
        }
    }
}

/// 待核对和已拦截保留在日志中，独立于后续待执行任务的启动。
enum QueueStartGate {
    static let reviewStatuses: Set<String> = ["draft", "uncertain", "submitted"]
    static let blockingStatuses: Set<String> = []
    static func reviewCount(_ statuses: [String]) -> Int {
        statuses.filter { reviewStatuses.contains($0) }.count
    }
    /// 兼容现有统计调用；这个数字只表示待核对条数，不再阻止启动。
    static func blockingCount(_ statuses: [String]) -> Int {
        reviewCount(statuses)
    }
    static func pausedCount(_ statuses: [String]) -> Int {
        statuses.filter { $0 == "blocked" }.count
    }
    /// 已暂停里「不能直接重新入队」的条数口径：带提交记录或发送凭据的失败记录必须先去核对。
    /// 与 `Delivery.canRequeue` 一致，避免这里说「可重试」、`Delivery.listGuidance` 说「不能重试」（走查 1-26）。
    static func nonRetriablePaused(_ statuses: [String], _ attempted: [Bool]) -> Int {
        guard statuses.count == attempted.count else { return 0 }
        return zip(statuses, attempted).filter { $0.0 == "blocked" && $0.1 }.count
    }
    static func pausedNote(statuses: [String], nonRetriableCount: Int = 0) -> String? {
        let count = pausedCount(statuses)
        guard count > 0 else { return nil }
        guard nonRetriableCount > 0 else { return "有 \(count) 条已拦截，可在发送记录重试" }
        let retriable = max(0, count - nonRetriableCount)
        if retriable == 0 { return "有 \(count) 条已拦截，都需先到发送记录核对实际结果，不能直接重试" }
        return "有 \(count) 条已拦截（其中 \(nonRetriableCount) 条需先到发送记录核对实际结果），其余可在发送记录重试"
    }
    /// 进度条上的短标签。只描述结果，不阻止继续发送其他群。
    static func attentionLabel(statuses: [String]) -> String? {
        let review = blockingCount(statuses)
        let paused = pausedCount(statuses)
        switch (review > 0, paused > 0) {
        case (false, false): return nil
        case (true, false): return "\(review) 群待核对"
        case (false, true): return "\(paused) 群已拦截"
        case (true, true): return "\(review) 群待核对 · \(paused) 群已拦截"
        }
    }
    static func overflowTitle(hiddenStatuses: [String]) -> String {
        var parts = ["还有 \(hiddenStatuses.count) 群"]
        let review = blockingCount(hiddenStatuses)
        let paused = pausedCount(hiddenStatuses)
        if review > 0 { parts.append("\(review) 群待核对") }
        if paused > 0 { parts.append("\(paused) 群已拦截") }
        return parts.joined(separator: " · ")
    }
    static func refusal(statuses: [String]) -> String? {
        nil
    }
    /// 有待核对记录时，仍然可以启动尚未提交的待执行任务。
    static func menuTitle(statuses: [String]) -> String {
        "启动队列"
    }
    static func replacesStart(statuses: [String], running: Bool) -> Bool {
        false
    }
    struct EmptySchedule: Equatable {
        var title: String
        var message: String
        var needsReview: Bool
    }
    /// 本计划没有下一条待执行时的说明，核对日志可稍后处理。
    static func emptySchedule(statuses: [String]) -> EmptySchedule {
        let review = blockingCount(statuses)
        let paused = pausedCount(statuses)
        if review > 0 {
            return EmptySchedule(title: "当前没有待执行排期", message: "有 \(review) 条结果留在发送记录，可稍后核对；这些记录不会自动重发。", needsReview: true)
        }
        if paused > 0 {
            return EmptySchedule(title: "当前没有待执行排期", message: "有 \(paused) 条已拦截。确认没发出、草稿已处理后可以重新入队。", needsReview: false)
        }
        return EmptySchedule(title: "当前没有待执行排期", message: "可添加群到本计划，或到新建发送编排下一次。", needsReview: false)
    }
    static func createdStep(count: Int, statuses: [String]) -> String {
        return "已创建 \(count) 条任务；点击启动队列执行"
    }
}

/// 菜单栏条带的「下一群倒计时」文本（MenuBarExtra label，单色 template 渲染，状态靠文字不靠颜色）。
/// 对标 MeetingBar/Itsycal：一小时内紧凑分钟、一天内小时+分钟、跨天退回绝对时刻（明天/M/d），
/// 绝不显示「7200m」这类无感知数字。返回 nil 表示不加文本（只留图标）。
enum MenuBarTitle {
    static func text(now: Date, next: Date?, calendar: Calendar) -> String? {
        guard let next else { return nil }
        let interval = next.timeIntervalSince(now)
        // 已到点（含轻微负间隔，等 tick 接手）统一「即将发送」，避免 0m 抖动。
        if interval < 60 { return "即将发送" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        if interval < 86_400 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        let clock = Self.clock(next, calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        if calendar.isDate(tomorrow, inSameDayAs: next) { return "明天" + clock }
        let parts = calendar.dateComponents([.month, .day], from: next)
        return "\(parts.month!)/\(parts.day!) \(clock)"
    }
    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// 菜单栏「打开窗口」会不会把本程序强行带到 QQ 前面。
/// 队列在跑或正忙时，用户多半是想看进度；这时只开窗口，不抢前台。
/// 长树读取每跨过这么多节点就让出一次主线程，暂停按钮才能在读完之前生效。
enum PausePoint {
    static let nodeStride = 25
    static func shouldPoll(at index: Int) -> Bool { index > 0 && index.isMultiple(of: nodeStride) }
    /// 用户点的暂停。会话标题里的「已停止，不发送」不是这个。
    static func isStop(_ message: String) -> Bool { message.hasPrefix("已停止") }
}

/// 发送进行中，主窗口可能被交回 QQ 或微信后面。暂停必须在不依赖主窗口焦点时也能点到。
enum PauseControl {
    static func available(busy: Bool, running: Bool) -> Bool { busy || running }
    static func menuHint(busy: Bool, running: Bool, appName: String = "QQ") -> String? {
        guard available(busy: busy, running: running) else { return nil }
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? "QQ" : name
        return "要停下请点这里的「暂停全部」，或按 ⌘.。主窗口可能在\(shown)后面。"
    }
}

enum MainWindowOpen {
    static func activatesOverTarget(busy: Bool, running: Bool) -> Bool { !busy && !running }
    static func title(busy: Bool, running: Bool) -> String {
        activatesOverTarget(busy: busy, running: running) ? "打开 QQ排程助手" : "打开窗口（不抢前台）"
    }
}

/// 新建页底栏第二行。队列是否在跑只看 running，与侧栏同一口径。
/// busy 只表示有一条前台操作占着（试跑、定位聊天、单条发送、补草稿、续发），队列可以仍是暂停。
/// 仅保存随 busy 关闭，预览不随 busy 关闭；这句只描述，不改变那两个按钮的门禁。
/// running 且 busy 同时为真时只承诺预览；running 且不忙时仍写可预览或仅保存。
enum ComposeFooterStatus {
    static func line(busy: Bool, running: Bool) -> String {
        if running && busy { return "队列运行中 · 当前操作进行中 · 可预览" }
        if running { return "其他队列运行中 · 可以保存、预览或启动新的独立队列" }
        if busy { return "队列已暂停 · 当前操作进行中 · 可预览" }
        return "草稿已保存 · 可以预览或启动"
    }
}

/// 图片粘贴后的等待说明。只告诉用户还在确认草稿，不表示图片已进输入框，也不允许发送。
enum AttachWait {
    static func budget(bytes: Int64) -> Double {
        min(24, 8 + Double(max(0, bytes)) / 1_048_576 * 2)
    }
    static func preparing(name: String) -> String {
        "正在准备「\(name)」，尚未粘贴，也尚未发送"
    }
    static func line(name: String, elapsed: TimeInterval, budget: TimeInterval) -> String {
        let limit = max(1, Int(budget.rounded(.up)))
        let shown = min(max(0, Int(elapsed.rounded(.down))), limit)
        return "已等待 \(shown)/\(limit) 秒，尚未发送。正在确认「\(name)」是否进入草稿"
    }
}

/// 会话名的两种用途必须分开（走查 1-05 / 主题 A）：
/// ①**宽松定位**：按输入名搜索、直接取第一条群聊结果（AGENTS.md 2026-09-26 用户明确要求），
///   这一步不做精确匹配，也不检查唯一性 —— `resultTitle`、以及 `headerMatches(looseContains: true)` 的默认口径。
/// ②**发送前的身份绑定**：必须与人工续发同一口径逐字相同 —— `identityBound`、`exactly`。
/// QQ 按项目规定绑定刚选择的第一条群聊结果，后续 identityBound 比对的是实际会话名。
/// bindingDivergence 仍供需要按输入名称精确确认的渠道使用，不作为 QQ 自动发送的闸门。
enum ConversationMatch {
    static let badges: Set<String> = ["群聊", "好友", "聊天记录", "文件", "来自", "综合", "联系人", "群成员", "发消息", "加入", "已加入", "消息列表"]
    /// 宽松定位专用：从一条搜索结果里挑出应绑定的会话名。查询词只用来在同一行里挑标题，不作为能否进入会话的门槛。
    static func resultTitle(texts: [String], query: String = "") -> String {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let useful = trimmed.filter { !badges.contains($0) }
        let pool = useful.isEmpty ? trimmed : useful
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if let exact = pool.first(where: { $0 == query }) { return exact }
            let containing = pool.filter { $0.contains(query) }
            if let best = containing.min(by: { $0.count < $1.count }) { return best }
        }
        return pool.max { $0.count < $1.count } ?? ""
    }
    /// 屏幕连续性核对（默认宽松）：标题栏候选与「刚绑定的会话名」比对，容忍 QQ 加上的装饰前后缀。
    /// `looseContains: false` 走严格相等，即 `identityBound` 的口径，供发送前身份绑定使用；
    /// 保持既有调用点签名兼容（默认值 = 原有行为），收紧由调用点在绑定环节显式传 false 或直接改用 `identityBound`。
    static func headerMatches(candidates: [String], title: String, looseContains: Bool = true) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !badges.contains(title) else { return false }
        return candidates.contains { raw in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if looseContains { return label == title || (title.count >= 4 && label.contains(title)) }
            return label == title
        }
    }
    /// 发送前的会话身份绑定（严格）：候选标题必须与绑定名逐字相同，不接受包含或前缀式的含混匹配。
    /// 与人工续发的 `exactly` 同口径，两条路径不再各判各的。
    static func identityBound(candidates: [String], title: String) -> Bool {
        headerMatches(candidates: candidates, title: title, looseContains: false)
    }
    /// 人工续发用的逐字比对：去首尾空白后必须完全相同，不做包含或前缀式的含混匹配。
    static func exactly(_ left: String, _ right: String) -> Bool {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && !b.isEmpty && a == b
    }
    /// 输入框的 AXDescription 是 QQ 自己标注的“当前会话名”。切换会话时它会滞后于标题栏——
    /// 实测出现过标题已是目标群、唯一的 AXTextArea 仍写着另一个群名。粘贴与发送前必须再对一次，
    /// 读不到或名字不同都算不匹配（交给上层短暂重试后中止），不能只信标题。
    /// 默认宽松只为容忍 QQ 给标注加的装饰前后缀；同一会话的**身份**判定请用 `identityBound`。
    static func composerBelongs(to title: String, description: String, looseContains: Bool = true) -> Bool {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !t.isEmpty else { return false }
        return headerMatches(candidates: [d], title: t, looseContains: looseContains)
    }
    /// 不可自洽判据：把「用户输入名」与「实际进入并绑定的会话标题」逐字比对。
    /// 返回 nil = 两者相同，可以按原计划继续；返回说明 = 实际进入的是另一个会话，
    /// 上层必须把该记录转成待人工核对（保留前台/草稿/提交核验，不静默判成功）。
    /// 搜索阶段仍按 AGENTS.md 的宽松规则执行，这里只如实交代差异。
    static func bindingDivergence(input: String, selectedTitle: String) -> String? {
        let wanted = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let bound = selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        guard !bound.isEmpty else { return "未能读取实际进入的会话标题，无法确认绑定的会话" }
        if wanted == bound { return nil }
        if bound.count >= 4 && bound.contains(wanted) {
            let extra = bound.replacingOccurrences(of: wanted, with: "")
            return "实际进入会话为「\(bound)」，与输入名「\(wanted)」不同（多出「\(extra)」，疑似同名系列群）"
        }
        if wanted.contains(bound) {
            return "实际进入会话为「\(bound)」，比输入名「\(wanted)」更短，不是同一个会话"
        }
        return "实际进入会话为「\(bound)」，与输入名「\(wanted)」不同"
    }
}

/// 总览大标题。有下一条待执行时写群名；没有待执行但仍有待核对时，不要写成什么都没有。
/// 「为什么停住」一行。原因放在群名前面，避免长群名把真正的问题挤出两行。
enum StoppedReasonLine {
    static func text(title: String, detail: String?, reason: String?) -> String {
        let why = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !why.isEmpty { return "\(why)（\(title)）" }
        if !state.isEmpty { return "\(title)：\(state)" }
        return title
    }
}

enum HomeBanner {
    static func title(nextRecipient: String?, reviewCount: Int) -> String {
        if let nextRecipient {
            let name = nextRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return "下一群 · \(name)" }
        }
        return "当前没有待执行任务"
    }
    /// 记录核对与新计划相互独立，历史记录不会成为启动前提。
    static func idleSubtitle(reviewCount: Int) -> String {
        reviewCount > 0
            ? "待核对结果保留在发送记录，可稍后处理；可继续编排新的发送。"
            : "到「新建发送」里编排一次发送，或从素材库开始。"
    }
    static func showsHeroCompose(reviewCount: Int) -> Bool { true }
    /// 队列入口只取待执行口径，历史待核对留在发送记录。
    static func showsQueueLink(queuedCount: Int, reviewCount: Int) -> Bool {
        queuedCount > 0
    }
    static func firstShortcutTitle(reviewCount: Int) -> String {
        "新建发送"
    }
    static func firstShortcutGoesToHistory(reviewCount: Int) -> Bool { false }
    static func pageTitle(hasNext: Bool, reviewCount: Int) -> String {
        "今天要发什么？"
    }
    static func pageSubtitle(hasNext: Bool, reviewCount: Int) -> String {
        "一屏看清排期、进度和下一次发送。"
    }
    struct HeaderAction: Equatable {
        var title: String
        var symbol: String
        var goesToHistory: Bool
    }
    /// 页头主按钮始终允许编排新任务，历史待核对不替换此入口。
    static func headerAction(route: String, reviewCount: Int) -> HeaderAction? {
        if route == "compose" { return nil }
        return HeaderAction(title: "新建发送", symbol: "plus", goesToHistory: false)
    }
    struct UpcomingEmpty: Equatable {
        var title: String
        var message: String
        var needsReview: Bool
    }
    /// 「接下来」没有待执行时的说明，不把待核对当成下一条发送。
    static func upcomingEmpty(statuses: [String]) -> UpcomingEmpty {
        if QueueStartGate.blockingCount(statuses) > 0 || QueueStartGate.pausedCount(statuses) > 0 {
            let schedule = QueueStartGate.emptySchedule(statuses: statuses)
            return UpcomingEmpty(title: schedule.title, message: schedule.message, needsReview: schedule.needsReview)
        }
        return UpcomingEmpty(title: "队列是空的", message: "在「新建发送」中选择素材和收件人，预览后创建计划。", needsReview: false)
    }
}

/// 列表上的原因摘要。按窄列大约每行 24 字、最多 4 行截断，并标明后面还有。
enum ListPreview {
    static let maxLines = 4
    static let charactersPerLine = 24
    static var maxCharacters: Int { maxLines * charactersPerLine }
    struct Result: Equatable {
        var text: String
        var clipped: Bool
    }
    static func clip(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return Result(text: trimmed, clipped: false) }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return Result(text: String(trimmed[..<end]) + "…", clipped: true)
    }
    static func moreNote(opensReview: Bool) -> String {
        opensReview ? "后面还有，点「去核对」看全文。" : "后面还有，点「详情」看全文。"
    }
}

enum SendChannel {
    static let qq = "qq"
    static let wechat = "wechat"
    /// 记录页让人去哪个应用里核对。旧数据没有渠道时按 QQ。
    static func displayName(_ channel: String) -> String { channel == wechat ? "微信" : "QQ" }
    /// 空名单或两种渠道都有时写「QQ 或微信」，避免还没选群就只提 QQ。
    static func appPhrase(_ channels: [String]) -> String {
        let names = Set(channels.map { displayName($0) })
        if names.contains("微信") && names.contains("QQ") || names.isEmpty { return "QQ 或微信" }
        if names.contains("微信") { return "微信" }
        return "QQ"
    }
    static func loginReminder(channels: [String]) -> String {
        "资料保存在此 Mac\n软件需保持运行，\(appPhrase(channels))需登录并解锁"
    }
    static func sendForegroundNote(channels: [String], automatic: Bool) -> String {
        let apps = appPhrase(channels)
        if automatic { return "自动发送时短暂使用\(apps)前台，成功后尽量切回原应用。" }
        return "仅填草稿不会按发送键。填写时仍会短暂打开\(apps)。"
    }
    static func reviewPrompt(channel: String) -> String {
        "先在\(displayName(channel))查看实际消息。确认未发出、草稿已清空后选择“发送”；无需再发则选“不发送”。"
    }
    static func confirmResendPrompt(channel: String) -> String {
        "确认已在\(displayName(channel))核对这条没有成功发出，并已清空输入框草稿？将按原群、正文和附件立即重新发送一次，保留原记录。"
    }
    static func keptRecord(note: String, previous: String) -> String {
        let prior = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if prior.isEmpty || prior == note || prior.hasPrefix(note) { return note }
        return note + "\n原先记录：\n" + prior
    }
    static func markedSentDetail(channel: String, previous: String = "") -> String {
        keptRecord(note: "用户在\(displayName(channel))核对后标记已发送", previous: previous)
    }
    static func cancelledDetail(previous: String, note: String = "用户取消，未继续发送") -> String {
        keptRecord(note: note, previous: previous)
    }
    static func confirmSentPrompt(channel: String) -> String {
        "确认已经在\(displayName(channel))里看到这条消息？此操作只改本地记录，不会再发送。"
    }
    /// 崩溃恢复与重新排期都不能抹掉上一次卡在哪一步（走查 1-08，AGENTS.md 第 9 行）。
    /// `previous` 带默认值，既有调用点无需改动即可编译；App 侧把 `job.detail` 传进来即变成追加。
    static func crashRecoveryDetail(channel: String, previous: String = "") -> String {
        keptRecord(note: "上次程序在处理期间退出，请到\(displayName(channel))核对后人工确认，不自动重试", previous: previous)
    }
    static func rescheduleDetail(channel: String, previous: String = "") -> String {
        keptRecord(note: "人工重新排期；请确保上次未发且\(displayName(channel))草稿已处理", previous: previous)
    }
    /// 自动路径实际进入的会话与输入名不同时的记录（走查 1-05）。
    /// 这条只交代差异并要求人工核对，不取消前台、草稿或提交核验，也不删记录。
    static func bindingDivergenceNote(_ divergence: String) -> String {
        "搜索按规则打开了第一条结果，但实际进入的会话与目标群名不同：\(divergence)。已停止，不发送；不会自动重发"
    }
    static func bindingDivergenceDetail(channel: String, divergence: String, previous: String = "") -> String {
        keptRecord(note: bindingDivergenceNote(divergence), previous: previous)
    }
    static func saveFailure(channel: String, reason: String) -> String {
        "状态保存失败：\(reason)。请到\(displayName(channel))核对，不要重发"
    }
    static let scheduleBehaviorNote = "所有计划共用间隔，逐个处理。运行排期期间阻止空闲系统休眠，不绕过锁屏、合盖或手动睡眠。错过时间的任务按发送间隔顺延，不集中连发。发送时自动唤起 QQ 或微信；被切换到其他窗口、已有草稿或结果不确定时暂停。退出程序不再调度；重新打开默认暂停，需要手动启动。"
    /// 设置页两张检查卡各自的初始说明。不能共用一句，否则微信卡会先写成去检查 QQ。
    static let qqStatusPlaceholder = "先检查 QQ 与辅助功能权限。"
    static let wechatStatusPlaceholder = "先检查微信与辅助功能权限。"
    /// 添加名单时跟着当前渠道走。QQ 打开第一条群聊结果；微信必须唯一匹配，不能写成和 QQ 一样。
    static func addNamesHint(channel: String) -> String {
        if channel == wechat {
            return "一行一个群聊名称。微信要能唯一匹配这个名字；同名时会停住，不选择任何会话，也不发送。"
        }
        return "一行一个群聊名称。QQ 按输入名称搜索，直接打开第一条群聊结果。"
    }
    /// 微信只按一次 Return。这句放在设置里，避免等到草稿没清空才第一次告诉用户。
    static let weChatEnterNote = "自动发送只按一次回车键——Mac 上 Return 与 Enter 是同一个键。若微信设置为「Enter 换行」或「Cmd+Enter 发送」，请先到微信设置改成按回车直接发送；否则消息不会发出，只会停在待核对，不会再按第二次。"
    /// 新建发送在选中群之后就写明搜索规则。执行方式藏在折叠区，不能等到失败记录里才说。
    static func composeCaution(channels: [String], automatic: Bool) -> String? {
        let selected = Set(channels.map { name($0) })
        var lines: [String] = []
        if selected.contains(wechat) {
            lines.append(automatic
                ? "微信要能唯一匹配群名；同名时会停住，不选择任何会话，也不发送。"
                : "微信要能唯一匹配群名；同名时会停住，不会填写草稿，也不会发送。")
            if automatic { lines.append(weChatEnterNote) }
        }
        if selected.contains(qq) {
            lines.append("QQ 按输入名称搜索，直接打开第一条群聊结果。")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
    static let restoreBehaviorNote = "只在对应的 QQ 或微信仍为前台、且发送已核对时切回。如果你已切换窗口，则不抢回焦点。掉线后仍需手动登录，软件不保存登录凭据。"
    /// 队列页底部说明。没有任务时仍按 QQ；两种渠道都有时写在一起。
    static func clientVerificationNote(channels: [String]) -> String {
        let names = Set(channels.map { displayName($0) })
        let apps: String
        if names.contains("微信") && names.contains("QQ") { apps = "QQ或微信" }
        else if names.contains("微信") { apps = "微信" }
        else { apps = "QQ" }
        return "核验指\(apps)客户端可见结果，不是服务器送达回执。"
    }
    static func name(_ c: String?) -> String { c ?? qq }
}

/// 核验成功后是否把焦点还给发送前的应用。只在目标 QQ 或微信仍在最前时切回。
enum FocusRestore {
    static let schedulerBundleID = "local.felix.qqdispatch"
    static let qqBundleID = "com.tencent.qq"
    static let weChatBundleID = "com.tencent.xinWeChat"
    static func targetBundleID(channel: String) -> String {
        channel == SendChannel.wechat ? weChatBundleID : qqBundleID
    }
    static func shouldRestore(verified: Bool, enabled: Bool, cancelled: Bool, locked: Bool, frontBundleID: String?, previousBundleID: String?, targetBundleID: String) -> Bool {
        guard verified, enabled, !cancelled, !locked else { return false }
        guard let frontBundleID, frontBundleID == targetBundleID else { return false }
        guard let previousBundleID, !previousBundleID.isEmpty, previousBundleID != targetBundleID else { return false }
        return true
    }
}

struct Recipient: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var note = ""
    var enabled = true
    var channel: String? = nil   // qq / wechat；旧数据无此字段默认 QQ
    var channelName: String { SendChannel.name(channel) }
}
struct Asset: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var relativePath: String
    var sha256: String
    var bytes: Int64
    var isImage: Bool
    var imported = Date()
}
struct Plan: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var text: String
    var assetIDs: [String]
    var recipientIDs: [String]
    var starts: Date
    var days: Int
    var times: [String]
    var intervalMinutes: Int
    var mode: String // draft or automatic
    var recipientGaps: [String:Int]? // minutes before this recipient; first recipient starts the round
    var created = Date()
    var workspaceID: String?
    var textTemplateID: String?
    /// 每隔 N 天自动接续下一轮；nil = 不循环（开循环时为 1...30）
    var recurringEveryDays: Int?
    /// 整体改期相对原轮次时刻的平移量；旧库缺省 nil，保留旧排期语义。
    var scheduleOffsetSeconds: TimeInterval? = nil
    /// 取消后整队重开的当前批次；旧库 nil 对应原始批次，历史不混入新队列。
    var dispatchBatchID: String? = nil
    var queueCancelledAt: Date? = nil
    /// 最近一次启动所选的条数；nil 表示不限条数。运行中的额度仅在内存中，重开应用不续发。
    var sendLimit: Int? = nil
}
/// Equatable 供 Database 的 deliveries 差量持久化做逐字段快照比对。
/// 全部存储属性均可比较（嵌套的 [Asset] 中 Asset 本身已是 Hashable），采用合成实现。
struct Delivery: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var planID: String
    var planName: String
    var recipient: String
    var text: String
    var assets: [Asset]
    var scheduled: Date
    var mode: String
    var status = "queued"
    var detail = "等待执行"
    var started: Date?
    var submittedAt: Date?
    var finished: Date?
    var evidence = ""
    /// nil 表示旧记录没有本次提交的结构核验依据；兼容旧库，不改历史状态。
    var qqVerification: QQVerificationEvidence? = nil
    var channel: String? = nil   // qq / wechat；从收件人快照继承
    var recipientID: String? = nil
    /// 一次性任务（人工补草稿或核对后重发）：不参与排期派发，只有人点它时才跑。
    var oneOff: Bool? = nil
    /// 由哪条任务派生出来，用来挡住同一来源重复开单
    var cloneOf: String? = nil
    /// 属于第几轮循环；nil = 计划创建时生成的原始任务
    var cycleTag: Int? = nil
    /// 用户清空发送记录仅隐藏历史行；执行状态与提交凭据保留，旧库缺省为 nil。
    var historyClearedAt: Date? = nil
    /// 这条任务的 scheduled 已应用的计划偏移；历史旧库 nil 视作零。
    var scheduleOffsetSeconds: TimeInterval? = nil
    var dispatchBatchID: String? = nil
    var isOneOff: Bool { oneOff == true }
    var canSendImmediately: Bool {
        status == "queued" && started == nil && submittedAt == nil && evidence.isEmpty && qqVerification == nil
    }
    var canRenameRecipient: Bool { !isOneOff && ["queued", "blocked"].contains(status) && submittedAt == nil && evidence.isEmpty }
    var canRequeue: Bool { !isOneOff && status == "blocked" && submittedAt == nil && evidence.isEmpty }
    /// 重新排期会回到待执行。已经提交过的记录不能靠它再发一次。
    var canReschedule: Bool { !isOneOff && ["queued", "blocked"].contains(status) && submittedAt == nil && evidence.isEmpty }
    /// 单任务推迟 N 分钟：只对还没进发送流程的待执行任务开放（与 canReschedule 的 queued 子集同口径）。
    var canPostpone: Bool { !isOneOff && status == "queued" && submittedAt == nil && evidence.isEmpty }
    /// 重新发送必须另建尝试；这个入口不把已提交过的原记录改回 queued。
    var canResendAfterReview: Bool {
        ["draft", "uncertain", "submitted", "blocked"].contains(status)
            || (status == "queued" && (submittedAt != nil || !evidence.isEmpty))
    }
    var attentionReason: String? {
        guard ["draft", "uncertain", "blocked", "submitted"].contains(status) else { return nil }
        let lines = detail.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A step describes where execution stopped; the next line describes why.
        let reason = lines.first(where: { !$0.hasPrefix("步骤：") }) ?? lines.first
        return reason.map { $0.hasPrefix("步骤：") ? String($0.dropFirst(3)) : $0 }
    }
    var channelName: String { SendChannel.name(channel) }
    /// 列表上的下一步。待核对须由用户确认未发出后另建重发尝试。
    var listGuidance: String? {
        let app = SendChannel.displayName(channelName)
        switch status {
        case "draft", "uncertain", "submitted":
            return "点「去核对」，到\(app)查看实际消息；确认未发出并清空草稿后，可重新发送。"
        case "blocked":
            return "点“去核对”，到\(app)查看后选择“发送”或“不发送”；不自动重试。"
        case "queued":
            if submittedAt != nil || !evidence.isEmpty {
                return "这条已有提交记录，不会自动再发。点「去核对」，到\(app)查看。"
            }
            return nil
        default:
            return nil
        }
    }
    // 状态词保留证据来源；人工标记不能显示为程序已经自动发送并核验。
    // draft 统一叫「未发送」（列表此前写未发送、详情写草稿，一词两名）；「草稿」只保留给发送模式（草稿模式）。
    var statusName: String { ["queued":"待执行", "running":"发送中", "draft":"未发送", "submitted":"待核对", "verified":"界面已核验", "uncertain":"待核对", "blocked":"已拦截", "cancelled":"已取消", "manual":"人工标记已发" ][status] ?? status }
}

/// 人工明确核对后的单条重发。原记录和旧凭据不动，新尝试使用全新 UUID。
enum ReviewedResend {
    static func existingAttempt(sourceID: String, jobs: [Delivery]) -> Delivery? {
        jobs.filter { $0.cloneOf == sourceID && $0.isOneOff && $0.mode == "automatic" && $0.status != "cancelled" }
            .max { $0.scheduled < $1.scheduled }
    }

    static func attempt(from source: Delivery, jobs: [Delivery], at date: Date) throws -> Delivery {
        guard source.canResendAfterReview else { throw AppError("这条记录的状态已变化，请重新打开详情核对") }
        guard !source.recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.text.isEmpty || !source.assets.isEmpty else { throw AppError("这条任务缺少收件群或发送内容") }
        guard existingAttempt(sourceID: source.id, jobs: jobs) == nil,
              !Scheduling.hasUnresolvedClone(of: source.id, in: jobs) else {
            throw AppError("这条已建立新的尝试，请先查看并核对那条记录，不会重复建立")
        }
        return Delivery(planID: source.planID, planName: source.planName, recipient: source.recipient,
                        text: source.text, assets: source.assets, scheduled: date, mode: "automatic",
                        detail: "用户已在\(SendChannel.displayName(source.channelName))核对未成功发出、草稿已清空；单条重新发送 · 来源 \(source.id)",
                        channel: source.channel, recipientID: source.recipientID, oneOff: true, cloneOf: source.id)
    }
}

/// 队列批次与历史分离。取消后重开发的是最后一轮的完整快照，包含已发、失败和取消项；
/// 自动循环的更早轮次、一条记录的人工重发不扩充整队模板，避免每次重开翻倍。
enum QueueBatch {
    static func contains(_ job: Delivery, in plan: Plan) -> Bool {
        job.planID == plan.id && job.dispatchBatchID == plan.dispatchBatchID
    }

    static func jobs(in plan: Plan, from jobs: [Delivery]) -> [Delivery] {
        jobs.filter { contains($0, in: plan) }
    }

    static func canDispatch(_ job: Delivery) -> Bool {
        job.canSendImmediately && !job.isOneOff
    }

    static func replay(_ plan: Plan, jobs: [Delivery], at now: Date, gap: Int, jitter: Bool) throws -> (Plan, [Delivery]) {
        let regular = self.jobs(in: plan, from: jobs).filter { !$0.isOneOff }
        guard Set(regular.map(\.id)).count == regular.count else { throw AppError("任务编号重复，未建立新一轮") }
        let latestRound = regular.map { $0.cycleTag ?? 0 }.max() ?? 0
        let template = regular.enumerated().filter {
            ($0.element.cycleTag ?? 0) == latestRound
                && ($0.element.recipientID.map { plan.recipientIDs.contains($0) } ?? true)
        }.sorted {
            $0.element.scheduled == $1.element.scheduled ? $0.offset < $1.offset : $0.element.scheduled < $1.element.scheduled
        }.map(\.element)
        guard !template.isEmpty, template.count <= 10000 else { throw AppError("这条队列没有可重新发送的群，或超过 10000 条上限") }
        guard gap >= 0, plan.intervalMinutes >= 0, now.timeIntervalSinceReferenceDate.isFinite else {
            throw AppError("发送时间或间隔无效，未建立新一轮")
        }
        guard template.allSatisfy({ !$0.recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!$0.text.isEmpty || !$0.assets.isEmpty) }) else {
            throw AppError("队列有记录缺少群名或图文，未建立新一轮")
        }
        var updated = plan
        let batch = UUID().uuidString
        updated.dispatchBatchID = batch; updated.queueCancelledAt = nil
        updated.starts = now; updated.scheduleOffsetSeconds = nil
        let copies = template.enumerated().map { position, source -> Delivery in
            Delivery(planID: plan.id, planName: source.planName, recipient: source.recipient,
                     text: source.text, assets: source.assets,
                     scheduled: now.addingTimeInterval(Double(position)), mode: source.mode,
                     detail: "用户取消后重开整条队列；新一轮发送 · 来源 \(source.id)",
                     channel: source.channel, recipientID: source.recipientID, dispatchBatchID: batch)
        }
        let spaced = Scheduling.restarted(copies, planID: plan.id, now: now, gap: gap,
                                          intervalByPlan: [plan.id: Scheduling.paceMinutes(plan)],
                                          compressFuture: true, jitter: jitter)
        return (updated, spaced)
    }
}
struct TextTemplate: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var text: String
    // 图文模板：记录与文案配套的素材；nil 表示旧模板或尚未启用配图同步（解码旧库自动为 nil）
    var assetIDs: [String]? = nil
    /// 独立队列的专属副本；旧模板 nil 保留旧版的显式共享关系。
    var ownerPlanID: String? = nil
    var title: String { text.components(separatedBy:.newlines).first ?? "" }
}
struct BroadcastDraft: Codable, Equatable {
    var text = ""
    var name = "新一轮图文发送"
    var recipientIDs: [String] = []
    var assetIDs: [String] = []
    var starts = Date().addingTimeInterval(300)
    var days = 1
    var interval = 30
    var times = "09:00,14:00,19:00"
    var multiRound = false
    var mode = "automatic"
    var customGaps = false
    var recipientGaps: [String:Int] = [:]
    var selectedTemplateID: String?
}
struct BroadcastWorkspace: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var draft = BroadcastDraft()
    var templates: [TextTemplate] = []
    var stagingText = ""
    var stagingFiles: [String] = []
}
struct Settings: Codable {
    var globalGapMinutes = 30
    var savedText = ""
    var returnToSchedulerAfterSend: Bool?
    var restorePreviousApp: Bool?
    /// 用户要求的专用成功音与成功后收窗；nil 默认开启，旧资料不需迁移。
    var successSoundEnabled: Bool?
    var minimizeAfterSuccess: Bool?
    /// 发送未确认 / 被拦截时发系统通知；nil = 开启（旧库解码自动 nil，保持向后兼容）。
    var notifyOnOutcome: Bool? = nil
    /// 走查 2026-10-06：游客模式记住选择——重启不再回登录页。登录/过期时置回 false。
    var guestMode: Bool? = nil
    /// 错峰抖动：重启/新排时给后续任务的间隔加 0~+20% 向上随机偏移，打散等差间隔的风控特征。
    /// nil = 关闭（旧库兼容；安全特性由用户主动开启）。
    var staggerJitter: Bool? = nil
    /// 发送前预告：下一条任务进入「发送时刻前 N 分钟」时通知一次，提醒保持 QQ 可用。
    /// nil = 默认 10 分钟（旧库解码兼容）；0 = 关闭。
    var upcomingLeadMinutes: Int? = nil
    var textTemplates: [TextTemplate]?
    var preferredRecipientIDs: [String]?
    var preferredAssetIDs: [String]?
    var broadcastWorkspaces: [BroadcastWorkspace]?
    var activeWorkspaceID: String?
    // 会员体系（可选字段，旧库缺省兼容）
    var licenseProfile: MembershipProfile?
    var licenseLastValidated: Date?
    /// 走查 3-15：上次成功联系服务器时服务端报的当前时间（单调时间锚，只允许变大，写入见
    /// `advanceLicenseServerTime` / `recordLicenseValidation`）。宽限期的经过时间以它为基准；
    /// 本机时钟早于它即说明被拨回，判定时以它为下限（见 `resolvedLicenseState`），
    /// 使"把系统时间调回去"不再能续命。旧库缺省为 nil，行为与今天一致。
    var licenseLastServerTime: Date?
    var licenseServerURL: String?
}
extension Settings {
    /// 走查 3-15：把服务端报出的当前时间并入单调时间锚。**只允许变大**：
    /// 锚点回退等于给"把系统时间拨回去"的人开门。脏时间（纪元 0 及以前）与老服务端的缺省
    /// 一律忽略，锚点保持原值，判定行为与今天一致。
    mutating func advanceLicenseServerTime(to reported: Date?) {
        guard let reported, reported.timeIntervalSince1970 > 0 else { return }
        licenseLastServerTime = max(licenseLastServerTime ?? reported, reported)
    }

    /// 走查 3-15：一次服务器应答落地后更新会员时基（宽限计时点 + 单调锚点）。
    /// - `validated == true`（服务器确认仍在期）：宽限计时点刷新为 `max(本机时钟, 服务端 server_time)`，
    ///   即以服务端时间为准；本机时钟只有在早于到期日时才可能推进锚点（调用点已保证
    ///   `paidUntil > max(本机时钟, 锚点)`），所以锚点不会越过该账号自己的到期日，
    ///   即使时钟被临时调快也不会把正常会员锁死。
    /// - `validated == false`（服务器答过期 / 本次不算有效验证）：宽限计时点清空，
    ///   锚点只采信服务端时间，**不采信本机时钟**，避免过期档案靠拨时钟复活。
    mutating func recordLicenseValidation(validated: Bool, serverTime: Date?, localNow: Date) {
        guard validated else {
            advanceLicenseServerTime(to: serverTime)
            licenseLastValidated = nil
            return
        }
        let stamp = LicenseState.timeFloor(now: localNow, lastServerTime: serverTime)
        advanceLicenseServerTime(to: stamp)
        licenseLastValidated = stamp
    }

    /// 走查 3-15：App 侧离线判定的统一入口——把单调锚点带进 `LicenseState.resolve` 作时基下限。
    /// 调用点不要再各自用 `Date()` 直接推算，否则拨慢本机时钟仍可绕过。
    func resolvedLicenseState(now: Date = Date()) -> LicenseState {
        LicenseState.resolve(profile: licenseProfile, now: now, lastValidated: licenseLastValidated,
                             lastServerTime: licenseLastServerTime)
    }

    mutating func prepareWorkspaces(recipientIDs: [String]) {
        guard broadcastWorkspaces?.isEmpty != false else { return }
        var legacy = BroadcastWorkspace(id: "legacy", name: "默认群发")
        legacy.templates = textTemplates ?? []
        legacy.draft.text = savedText
        legacy.draft.recipientIDs = preferredRecipientIDs ?? recipientIDs
        legacy.draft.assetIDs = preferredAssetIDs ?? []
        legacy.draft.interval = globalGapMinutes
        legacy.draft.selectedTemplateID = legacy.templates.first(where: { $0.text == savedText })?.id
        var promotion = BroadcastWorkspace(name: "推广")
        var notice = BroadcastWorkspace(name: "通知")
        promotion.draft.interval = globalGapMinutes; notice.draft.interval = globalGapMinutes
        broadcastWorkspaces = [legacy, promotion, notice]; activeWorkspaceID = legacy.id
    }
    mutating func switchWorkspace(_ id: String) throws {
        if id == activeWorkspaceID { return }
        guard let target = broadcastWorkspaces?.first(where: { $0.id == id }) else { throw AppError("群发空间不存在") }
        if let current = broadcastWorkspaces?.firstIndex(where: { $0.id == activeWorkspaceID }) {
            broadcastWorkspaces?[current].templates = textTemplates ?? []
        }
        activeWorkspaceID = id
        textTemplates = target.templates; savedText = target.draft.text
        preferredRecipientIDs = target.draft.recipientIDs; preferredAssetIDs = target.draft.assetIDs
    }
}
struct Archive: Codable { var version = 1; var recipients: [Recipient]; var assets: [Asset]; var plans: [Plan]; var deliveries: [Delivery]; var settings: Settings }

enum LiveMessage {
    /// Legacy plans can only be linked within their original workspace.
    static func linked(_ input: Archive) -> Archive {
        var value = input
        for i in value.plans.indices where value.plans[i].textTemplateID == nil {
            let plan = value.plans[i]
            let templates = (value.settings.broadcastWorkspaces?.first { $0.id == (plan.workspaceID ?? "legacy") }?.templates ?? [])
                .filter { $0.ownerPlanID == nil || $0.ownerPlanID == plan.id }
            let matches = templates.filter { $0.text == plan.text }
            if matches.count == 1 { value.plans[i].textTemplateID = matches[0].id }
            else if templates.count == 1 { value.plans[i].textTemplateID = templates[0].id }
        }
        return value
    }
    static func refreshed(_ input: Archive, refreshReplaySnapshots: Bool = true) -> Archive {
        var value = linked(input)
        for i in value.plans.indices {
            let plan = value.plans[i]
            if !refreshReplaySnapshots && plan.dispatchBatchID != nil { continue }
            guard let workspace = value.settings.broadcastWorkspaces?.first(where: { $0.id == (plan.workspaceID ?? "legacy") }) else { continue }
            guard let source = workspace.templates.first(where: { $0.id == plan.textTemplateID }) else { continue }
            value.plans[i].text = source.text
            // 图文同步：模板携带配图列表时，把计划与未发送任务的附件快照一并刷新，
            // 保证「编辑草稿 → 保存并同步」后图片和文字一样跟随草稿；已尝试过的记录不动
            if let templateAssets = source.assetIDs {
                let resolved = templateAssets.compactMap { id in value.assets.first { $0.id == id } }
                value.plans[i].assetIDs = resolved.map(\.id)
                for j in value.deliveries.indices where QueueBatch.contains(value.deliveries[j], in: plan) {
                    let job = value.deliveries[j]
                    if !job.isOneOff && job.started == nil && (job.status == "queued" || job.canRequeue) && job.submittedAt == nil && job.evidence.isEmpty {
                        value.deliveries[j].assets = resolved
                    }
                }
            }
            for j in value.deliveries.indices where QueueBatch.contains(value.deliveries[j], in: plan) {
                let job = value.deliveries[j]
                if !job.isOneOff && job.started == nil && (job.status == "queued" || job.canRequeue) && job.submittedAt == nil && job.evidence.isEmpty {
                    value.deliveries[j].text = source.text
                }
            }
        }
        return value
    }
}

final class Database {
    let root: URL
    private var db: OpaquePointer?
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try open()
    }
    /// 建立连接并完成 PRAGMA / 建表。首次打开与故障自愈的重连共用这一条路径，
    /// 保证重连后的连接参数（WAL、synchronous、busy_timeout、建表）与首次打开完全一致。
    private func open() throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(root.appendingPathComponent("library.sqlite3").path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        if opened != SQLITE_OK {
            // 打开失败也要收回可能已被赋值的句柄，否则每次失败都漏一个连接（走查补充说明）
            if handle != nil { sqlite3_close(handle); handle = nil }
            throw AppError("无法打开本地数据库")
        }
        db = handle
        do {
            sqlite3_busy_timeout(db, 5000)
            // journal_size_limit：WAL 检查点后把 -wal 文件截回 16MB 上限，防止高频整库重写把日志无限撑大
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA journal_size_limit=16777216;")
            for t in ["recipients", "assets", "plans", "deliveries", "settings"] { try exec("CREATE TABLE IF NOT EXISTS \(t) (id TEXT PRIMARY KEY, payload BLOB NOT NULL)") }
            // 坏行隔离区：无法解码的原始行按 (来源表, 行 id) 逐字保留在这里，任何落盘都不销毁用户数据（走查 1-07）
            try exec("CREATE TABLE IF NOT EXISTS quarantine_rows (source TEXT NOT NULL, id TEXT NOT NULL, payload BLOB, reason TEXT NOT NULL, noted_at REAL NOT NULL, PRIMARY KEY (source, id))")
            try exec("PRAGMA user_version=1")
        } catch { sqlite3_close_v2(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    /// 连接级故障自愈：close（v2 允许延迟释放）→ 按首次打开的同一配置重建 → 重置差量基线。
    /// SQLite 在一次 I/O 故障（SQLITE_IOERR 等）之后旧连接可能持续报错，只有重开才能恢复；
    /// 重连后没有差量基线，下一次 save 自然走全量路径，与「首次保存」语义完全一致。
    private func reconnect() throws {
        if let old = db { sqlite3_close_v2(old); db = nil }
        try open()
        lastDeliveriesByID = nil
        reloadQuarantineIndex()
    }
    /// 从磁盘 quarantine_rows 重建内存坏行索引。首次打开不走这里（load 时自然补齐）；
    /// 重连后必须走：内存索引里的坏行是之后全量重写时唯一被保留的数据来源（走查 1-07 的承诺不因重连而失效）。
    private func reloadQuarantineIndex() {
        quarantined.removeAll()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source, id, payload FROM quarantine_rows", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let id = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            // updateValue 而非下标赋值：下标赋 nil 是「删除键」，会把 NULL payload 的坏行从索引里挤掉
            quarantined[source, default: [:]].updateValue(sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 2))) }, forKey: id)
        }
    }
    /// 最近一次 SQLite 调用失败的原始返回码；nil 表示失败发生在进入 SQLite 之前（Swift 侧逻辑错误）。
    private(set) var lastFailureRC: Int32?
    /// 故障自愈记录：累计重连次数与最近一次原因。自愈成功不打扰用户、不停止队列；
    /// 这里只是留痕，供排查与设置页展示。
    private(set) var recoveryCount = 0
    private(set) var lastRecovery: (reason: String, at: Date)?
    /// 只有 SQLite 层报过「重连可能自愈」的错误码才值得重试：I/O 故障、锁竞争、只读回滚、
    /// 磁盘满、打不开文件，以及 WAL 索引不一致引起的假性 CORRUPT（重开连接即可重建）。
    /// 主键冲突这类约束错误和纯逻辑错误重试只会得到同样结果，直接上抛。
    private var lastFailureRecoverable: Bool {
        guard let rc = lastFailureRC else { return false }
        switch rc & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_READONLY, SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_FULL, SQLITE_CANTOPEN: return true
        default: return false
        }
    }
    /// 自愈判定与执行合一：错误可恢复则重连并记一笔恢复事件，返回是否值得重试。
    /// 重连本身失败时抛出重连错误——那比原始错误更能说明当前的真实状况。
    private func attemptRecovery(after error: Error) throws -> Bool {
        guard lastFailureRecoverable else { return false }
        try reconnect()
        recoveryCount += 1
        lastRecovery = (reason: String(describing: error), at: Date())
        return true
    }
    /// 连接缺失（上一次重连失败后留下的 nil）时先重建，保证一次重连失败不会永久失去自愈能力。
    /// 重建失败如实上抛；连接健在时是 no-op。
    private func ensureConnection() throws {
        guard db == nil else { return }
        try reconnect()
    }
    /// 仅测试使用：返回非 nil 时按该返回码当作 SQLite exec 失败处理（模拟磁盘 I/O 等连接级故障），
    /// 按 SQL 区分可精确命中 BEGIN/COMMIT。生产代码从不设置；自愈分类、真实重连与重试路径都按真实失败走。
    var testExecFault: ((_ sql: String) -> Int32?)?
    private func exec(_ sql: String) throws {
        if let injected = testExecFault?(sql) {
            lastFailureRC = injected
            throw AppError("注入的连接级测试故障（rc=\(injected)）")
        }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError(String(cString: sqlite3_errmsg(db))) }
    }
    /// 只读 PRAGMA 查询（单整数结果），供测试与部署核对连接设置（如 journal_size_limit）。
    func pragmaValue(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_count(stmt) > 0 else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    /// 本次 load 跳过的无法解码行数（每次调用 load 时重置）。
    /// 坏行只跳过、不删除、不改写磁盘：读取时发现坏行会**额外**在 quarantine_rows 里留一份逐字副本，
    /// 之后即便某次全量重写把原行挤掉，原始 payload 仍可从隔离区取回核对（走查 1-07，AGENTS.md 第 9/兼容旧库要求）。
    private(set) var lastSkippedRows = 0
    /// 本次连接发现并隔离的坏行：来源表 → 行 id → 原始 payload（nil 表示磁盘上本来就没有内容）。
    private(set) var quarantined: [String: [String: Data?]] = [:]
    /// 本次连接是否读到过无法解码的行。App 侧启动提示以此为准（有坏行就先引导整库备份）。
    var hasUndecodableRows: Bool { !quarantined.isEmpty }
    /// 从隔离区取回某张表保留下来的坏行：逐字 payload、原因与发现时间。
    /// 数据表里的原行可能已被某次全量重写挤掉，这里才是「绝不静默销毁用户数据」的落点（走查 1-07）。
    func quarantinedRows(for table: String) -> [(id: String, payload: Data?, reason: String, notedAt: Date)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload, reason, noted_at FROM quarantine_rows WHERE source=? ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, table, -1, transient) == SQLITE_OK else { return [] }
        var result: [(id: String, payload: Data?, reason: String, notedAt: Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let size = Int(sqlite3_column_bytes(stmt, 1))
            let payload = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: size) }
            let reason = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let notedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            result.append((id: id, payload: payload, reason: reason, notedAt: notedAt))
        }
        return result
    }
    /// 隔离区累计条数（跨连接、跨重启都算，供设置页展示）。
    func quarantineCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM quarantine_rows", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_count(stmt) > 0 else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    /// 只在整库被外部替换（例如恢复备份后重开连接）时调用：清空本连接记录的坏行内存索引。
    /// 隔离表本身不动，历史坏行仍可查回。
    func resetQuarantineIndex() { quarantined.removeAll() }
    /// 对外入口：load 带连接级自愈（启动读取是单次路径，重试一次即可，失败仍由调用方决定退出语义）。
    func load<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        do { return try performLoad(table, as: T.self) }
        catch { guard try attemptRecovery(after: error) else { throw error }; return try performLoad(table, as: T.self) }
    }
    private func performLoad<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        try ensureConnection()
        lastFailureRC = nil
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT id, payload FROM \(table) ORDER BY rowid", -1, &stmt, nil)
        guard prepared == SQLITE_OK else { lastFailureRC = prepared; throw AppError("数据库读取失败") }
        defer { sqlite3_finalize(stmt) }
        // 一个 decoder 复用于全表，避免每行 new 一个 JSONDecoder
        let decoder = JSONDecoder()
        var result: [T] = []
        var skipped = 0
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let rowID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_bytes(stmt, 1))
            let raw = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: count) }
            // 单行解码失败只跳过该行（空 blob 同样计为坏行），不再让整表抛错、启动退出
            if let raw, let decoded = try? decoder.decode(T.self, from: raw) {
                result.append(decoded)
            } else {
                skipped += 1
                quarantine(source: table, id: rowID, payload: raw, reason: "无法解码为 \(String(describing: T.self))")
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { lastFailureRC = rc; throw AppError("数据库读取不完整") }
        lastSkippedRows = skipped
        return result
    }
    /// 坏行入隔离区：内存索引 + 磁盘逐字副本。写隔离区失败不能反过来打断读取，因此这里吞掉错误，
    /// 但仍把坏行记进 `quarantined`／`lastSkippedRows`，让上层至少知道有行没读出来。
    private func quarantine(source: String, id: String, payload: Data?, reason: String) {
        let key = id.isEmpty ? "row:\(Date().timeIntervalSince1970)" : id
        quarantined[source, default: [:]][key] = payload
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO quarantine_rows(source,id,payload,reason,noted_at) VALUES(?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        guard sqlite3_bind_text(stmt, 1, source, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, key, -1, transient) == SQLITE_OK else { return }
        if let payload {
            guard payload.withUnsafeBytes({ sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(payload.count), transient) }) == SQLITE_OK else { return }
        } else if sqlite3_bind_null(stmt, 3) != SQLITE_OK { return }
        guard sqlite3_bind_text(stmt, 4, reason, -1, transient) == SQLITE_OK,
              sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { return }
    }
    /// deliveries 差量写入的基线：上次成功 save 提交时的 deliveries 快照（按 id 索引）。
    /// nil 表示尚无基线（新连接首次保存），此时 deliveries 走原全量路径建立基线。
    /// 差量机制失效条件：任何绕过 save(archive:) 的直接写库（外部进程、手写 SQL）
    /// 都会让基线与磁盘失真——新增此类路径时必须把基线重置为 nil。
    /// 当前 Sources 内没有绕过 save 的写库路径：备份走 sqlite3 在线备份 API（对主库只读），
    /// 恢复备份走 db.save(backup:)（等价全量 upsert），均不破坏基线。
    private var lastDeliveriesByID: [String: Delivery]?
    /// 对外入口：save 带连接级自愈。第一次失败且属于可恢复类（I/O/锁/满盘等）时重连重试一次，
    /// 成功则对上层完全透明——不报错、不停车；自愈后仍失败才把错误交给调用方（App 侧照旧停止全部队列）。
    func save(_ archive: Archive) throws {
        do { try performSave(archive) }
        catch { guard try attemptRecovery(after: error) else { throw error }; try performSave(archive) }
    }
    private func performSave(_ archive: Archive) throws {
        try ensureConnection()
        lastFailureRC = nil
        // 一个 encoder 复用于全部表，避免每行 new 一个 JSONEncoder；默认编码策略与旧行为一致
        let encoder = JSONEncoder()
        try exec("BEGIN IMMEDIATE")
        do {
            try replace("recipients", archive.recipients.map { ($0.id, try encoder.encode($0)) })
            try replace("assets", archive.assets.map { ($0.id, try encoder.encode($0)) })
            try replace("plans", archive.plans.map { ($0.id, try encoder.encode($0)) })
            try syncDeliveries(archive.deliveries, encoder: encoder)
            try replace("settings", [("main", try encoder.encode(archive.settings))])
            try exec("COMMIT")
            // 事务成功提交后才更新基线；中途失败走 ROLLBACK，磁盘保持上次成功内容，
            // 基线也保持旧值，与调用方"内存回滚后磁盘不变"的语义一致。
            lastDeliveriesByID = Dictionary(archive.deliveries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch { try? exec("ROLLBACK"); throw error }
    }
    /// deliveries 表差量写入：有基线时只落盘「新增/内容变化」与「消失」的行，
    /// 未变化的行不再 DELETE+INSERT，rowid 保持稳定；与四表同一事务提交。
    private func syncDeliveries(_ deliveries: [Delivery], encoder: JSONEncoder) throws {
        guard let baseline = lastDeliveriesByID else {
            // 无基线（首次保存或基线已重置）：走原全量路径
            try replace("deliveries", try deliveries.map { ($0.id, try encoder.encode($0)) })
            return
        }
        let next = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 与旧全量路径一致：重复主键报错回滚，不静默去重
        guard next.count == deliveries.count else { throw AppError("数据库写入失败") }
        // upsert 集合：基线没有（新增）或与基线不等（变化）的行；按入参数组顺序落盘，rowid 顺序可预期
        var changed: [(String, Data)] = []
        for job in deliveries where baseline[job.id] != job {
            changed.append((job.id, try encoder.encode(job)))
        }
        // delete 集合：基线里有而新数据没有的 id
        let removed = baseline.keys.filter { next[$0] == nil }.sorted()
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if !removed.isEmpty {
            var stmt: OpaquePointer?
            var rc = sqlite3_prepare_v2(db, "DELETE FROM deliveries WHERE id=?", -1, &stmt, nil)
            guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入准备失败") }
            defer { sqlite3_finalize(stmt) }
            for id in removed {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                rc = sqlite3_bind_text(stmt, 1, id, -1, transient)
                guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入失败") }
                rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else { lastFailureRC = rc; throw AppError("数据库写入失败") }
            }
        }
        if !changed.isEmpty {
            var stmt: OpaquePointer?
            var rc = sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO deliveries(id,payload) VALUES(?,?)", -1, &stmt, nil)
            guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入准备失败") }
            defer { sqlite3_finalize(stmt) }
            for (id, data) in changed {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                rc = sqlite3_bind_text(stmt, 1, id, -1, transient)
                guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入失败") }
                rc = data.withUnsafeBytes({ sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) })
                guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入失败") }
                rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else { lastFailureRC = rc; throw AppError("数据库写入失败") }
            }
        }
    }
    /// 全量重写一张表。写回前先取回本次连接 load 时判定为坏行的原始内容，一起写回原表：
    /// 「只跳过、不删除、不改写磁盘」的承诺因此在落盘之后依然成立，另有一份隔离副本可查（走查 1-07）。
    /// 用户真的删掉的正常记录不在保留之列——保留名单只来自解码失败的那几行。
    private func replace(_ table: String, _ rows: [(String, Data)]) throws {
        let taken = Set(rows.map(\.0))
        let preserved: [(String, Data)] = (quarantined[table] ?? [:])
            .compactMap { entry -> (String, Data)? in
                guard let payload = entry.value, !taken.contains(entry.key) else { return nil }
                return (entry.key, payload)
            }.sorted { $0.0 < $1.0 }
        try exec("DELETE FROM \(table)")
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, "INSERT INTO \(table)(id,payload) VALUES(?,?)", -1, &stmt, nil)
        guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入准备失败") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (id, data) in rows + preserved {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            rc = sqlite3_bind_text(stmt, 1, id, -1, transient)
            guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入失败") }
            rc = data.withUnsafeBytes({ sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) })
            guard rc == SQLITE_OK else { lastFailureRC = rc; throw AppError("数据库写入失败") }
            rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { lastFailureRC = rc; throw AppError("数据库写入失败") }
        }
    }
    func backup(to folder: URL) throws {
        try ensureConnection()   // 上一次重连失败可能留下空连接；备份前先重建
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var output: OpaquePointer?
        guard sqlite3_open(folder.appendingPathComponent("library.sqlite3").path, &output) == SQLITE_OK else { throw AppError("备份数据库无法创建") }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", db, "main") else { throw AppError("无法开始数据库备份") }
        let rc = sqlite3_backup_step(backup, -1)
        let end = sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE && end == SQLITE_OK else { throw AppError("数据库备份未完成") }
        try FileManager.default.copyItem(at: root.appendingPathComponent("assets"), to: folder.appendingPathComponent("assets"))
    }
    func url(for asset: Asset) -> URL { root.appendingPathComponent(asset.relativePath) }
    /// 导入素材。`precomputedDigest` 供调用方复用已经算好的 sha256（`importFiles` 去重时算过一次），
    /// 避免同一份文件被整文件哈希两遍（走查 1-22）；不传则内部自己算，既有调用点行为不变。
    /// 复制失败时把已经建好的目录清掉，不留孤儿素材目录（走查 1-22 的另一半在 App 侧的回滚里）。
    func importAsset(_ url: URL, precomputedDigest: String? = nil) throws -> Asset {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw AppError("只支持文件，不支持文件夹：\(url.lastPathComponent)") }
        let hash = try precomputedDigest ?? Self.digest(url)
        let id = UUID().uuidString
        let relative = "assets/\(id)/\(url.lastPathComponent)"
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: url, to: target) }
        catch { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()); throw error }
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
        return Asset(id: id, name: url.lastPathComponent, relativePath: relative, sha256: hash, bytes: Int64(info.fileSize ?? 0), isImage: imageExtensions.contains(url.pathExtension.lowercased()))
    }
    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum Scheduling {
    /// Stable queue order: preserve the saved plan order when two jobs share a timestamp.
    /// UUIDs are identity keys, not a meaningful recipient ordering rule.
    static func ordered(_ jobs: [Delivery]) -> [Delivery] {
        jobs.enumerated().sorted { lhs, rhs in
            if lhs.element.scheduled != rhs.element.scheduled {
                return lhs.element.scheduled < rhs.element.scheduled
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m) 分钟" : m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分钟"
    }
    static func offsets(_ plan: Plan) throws -> [Int] {
        var total = 0, result: [Int] = []
        for (index,id) in plan.recipientIDs.enumerated() {
            if index > 0 {
                let gap = plan.recipientGaps?[id] ?? plan.intervalMinutes
                guard (1...1440).contains(gap) else { throw AppError("每个群的间隔须为 1–1440 分钟") }
                total += gap
            }
            result.append(total)
        }
        return result
    }
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
    static func times(_ input: String) throws -> [String] {
        let parts = input.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, parts.count <= 24 else { throw AppError("请输入 1 至 24 个时间，例如 09:00,14:00,19:00") }
        for s in parts {
            let p = s.split(separator: ":")
            guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { throw AppError("时间格式必须为 HH:mm：\(s)") }
        }
        guard Set(parts).count == parts.count else { throw AppError("轮次时间不能重复") }
        return parts.sorted()
    }
    /// 新建多轮计划的第一轮精确对齐用户选择的 starts，其余预设轮次整体平移。
    /// 无预设轮次本来就从 starts 开始，偏移为零。
    static func initialScheduleOffset(starts: Date, times presets: [String]) throws -> TimeInterval {
        guard starts.timeIntervalSinceReferenceDate.isFinite else { throw AppError("开始日期无效") }
        guard !presets.isEmpty else { return 0 }
        let parsed = try times(presets.joined(separator: ","))
        let parts = parsed[0].split(separator: ":").compactMap { Int($0) }
        guard let first = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: starts) else {
            throw AppError("无法解析开始日期与轮次时间")
        }
        let offset = starts.timeIntervalSince(first)
        guard offset.isFinite else { throw AppError("开始日期无效") }
        return offset
    }
    static func expand(_ plan: Plan, recipients: [Recipient], assets: [Asset], now: Date = Date(), jitter: Bool = false) throws -> [Delivery] {
        guard ["draft", "automatic"].contains(plan.mode) else { throw AppError("未知发送模式") }
        let scheduleOffset = plan.scheduleOffsetSeconds ?? 0
        guard plan.starts.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
              scheduleOffset.isFinite else { throw AppError("开始日期或排期偏移无效") }
        guard (1...30).contains(plan.days), (1...1440).contains(plan.intervalMinutes) else { throw AppError("天数须为 1–30，间隔须为 1–1440 分钟") }
        guard !plan.recipientIDs.isEmpty else { throw AppError("请至少选择一个收件人") }
        guard !plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !plan.assetIDs.isEmpty else { throw AppError("文案和附件不能都为空") }
        guard plan.text.count <= 5000 else { throw AppError("单条文案请控制在 5000 字以内") }
        let rs = try plan.recipientIDs.map { id -> Recipient in guard let r = recipients.first(where: { $0.id == id }), r.enabled else { throw AppError("收件人不存在或已停用") }; return r }
        guard rs.count * plan.days * max(1,plan.times.count) <= 10000 else { throw AppError("本计划超过 10000 条任务，请减少天数、轮次或群数") }
        guard Set(rs.map(\.name)).count == rs.count else { throw AppError("收件人重复") }
        let selectedAssets = try plan.assetIDs.map { id -> Asset in guard let a = assets.first(where: { $0.id == id }) else { throw AppError("附件不存在") }; return a }
        if plan.mode == "draft" && selectedAssets.contains(where: { !$0.isImage }) { throw AppError("QQ 选择普通文件后可能立即上传。普通文件请选自动发送模式；草稿模式只支持文字和图片") }
        let offsets = try offsets(plan)
        // 错峰抖动：每个后续任务相对前一任务的间隔换成抖动后的间隔，等差排时（30:00→31:00→32:00）
        // 被打散成不规则间距。首群（offsets[0] 恒为 0，即用户选定的开始时刻）不抖。
        // 种子 = 计划 id + 收件人序号（stableSeed，跨进程稳定）：同一计划每次新排结果确定，不同计划互不相同。
        // 抖动后的末群时刻同步参与下方轮次间隔校验，保证轮与轮之间的真实冷却不被抖动缩短。
        var scheduledOffsets = offsets
        if jitter {
            for index in offsets.indices.dropFirst() {
                let base = offsets[index] - offsets[index - 1]
                scheduledOffsets[index] = scheduledOffsets[index - 1] + jittered(minutes: base, seed: stableSeed(plan.id + "#offset#\(index)"))
            }
        }
        let gaps = plan.recipientIDs.dropFirst().map { plan.recipientGaps?[$0] ?? plan.intervalMinutes }
        let minimumGap = min(plan.intervalMinutes,gaps.min() ?? plan.intervalMinutes)
        var jobs: [Delivery] = []
        var allSlots: [Date] = []
        for day in 0..<plan.days {
            guard let d = calendar.date(byAdding: .day, value: day, to: plan.starts) else { throw AppError("开始日期超出支持范围") }
            let slots: [Date]
            if plan.times.isEmpty { slots = [d] }
            else {
                slots = try times(plan.times.joined(separator: ",")).map { s in
                    let p = s.split(separator: ":").compactMap { Int($0) }
                    guard let date = calendar.date(bySettingHour: p[0], minute: p[1], second: 0, of: d) else { throw AppError("轮次日期超出支持范围") }
                    return date
                }
            }
            for slot in slots {
                let shifted = slot.addingTimeInterval(scheduleOffset)
                guard shifted.timeIntervalSinceReferenceDate.isFinite else { throw AppError("排期偏移超出支持范围") }
                allSlots.append(shifted)
            }
        }
        var previousEnd: Date?
        for slot in allSlots.sorted() {
                if let previousEnd, slot.timeIntervalSince(previousEnd) < Double(minimumGap * 60) - 1 { throw AppError("轮次有重叠，或下一轮离末群太近。请减少轮次、减少群数或调整间隔") }
                for (index, r) in rs.enumerated() {
                    let date = slot.addingTimeInterval(Double(scheduledOffsets[index] * 60))
                    guard date.timeIntervalSinceReferenceDate.isFinite else { throw AppError("任务日期无效") }
                    guard date >= now.addingTimeInterval(-60) else { throw AppError("计划包含已经过去的时间，请调整开始日期或时间") }
                    jobs.append(Delivery(planID: plan.id, planName: plan.name, recipient: r.name, text: plan.text, assets: selectedAssets, scheduled: date, mode: plan.mode, channel: r.channelName, recipientID: r.id, scheduleOffsetSeconds: plan.scheduleOffsetSeconds))
                }
                previousEnd = slot.addingTimeInterval(Double((scheduledOffsets.last ?? 0) * 60))
        }
        return ordered(jobs)
    }
    static func lastSendActivity(_ jobs: [Delivery]) -> Date? {
        jobs.compactMap { job -> Date? in
            if let submitted = job.submittedAt { return submitted }
            // A blocked or cancelled attempt that never reached the submit checkpoint did not send.
            switch job.status {
            case "blocked", "cancelled", "queued": return nil
            case "verified", "manual": return job.finished ?? job.started
            default: return job.started
            }
        }.max()
    }
    /// 计划实际发送之间至少隔开的分钟数。逐群间隔可以更长，由计划时间差另外保住。
    static func paceMinutes(_ plan: Plan) -> Int {
        let custom = (plan.recipientGaps ?? [:]).values.filter { (1...1440).contains($0) }
        let floor = custom.min().map { min($0, plan.intervalMinutes) } ?? plan.intervalMinutes
        return min(max(floor, 1), 1440)
    }
    /// dueDates 的内容指纹缓存（最多保留 4 项，超出淘汰最旧）。
    /// 指纹必须覆盖 dueDates 的全部输入：gap、intervalByPlan，以及每条任务的
    /// id、planID、status、scheduled、started、submittedAt、finished、evidence、isOneOff
    /// （这些决定筛选、基准日期、lastSendActivity 与分组）。
    /// 输入集超出此列表会使缓存失真——给 dueDates 新增依赖字段时必须同步加进指纹。
    /// 线程安全性：当前所有调用都在主线程/测试单线程；非主线程调用前需加锁。
    private static var dueDatesMemo: [(key: Int, value: [String: Date])] = []
    /// 逐字段 hashValue 组合成一个指纹：字段之间用 ^ 搭配 &* 质数打散规律性；
    /// 任务之间只用 ^（顺序无关，分组排序本身也不依赖数组顺序）。
    private static func dueDatesFingerprint(_ jobs: [Delivery], gap: Int, intervalByPlan: [String:Int]) -> Int {
        let prime: Int = Int(bitPattern: 0x9e3779b97f4a7c15)
        func mix(_ seed: Int, _ value: Int) -> Int { (seed ^ value) &* prime }
        // 可选日期：nil 用独立常量表示，与任何真实日期的哈希区分开
        func date(_ d: Date?) -> Int { d.map { $0.timeIntervalSince1970.bitPattern.hashValue } ?? 0x5bf03635 }
        var seed = mix(gap.hashValue, 0x27d4eb2f165667c5)
        // 相同映射的指纹与 Dictionary 的随机迭代顺序无关。
        seed = mix(seed, intervalByPlan.reduce(0) { $0 ^ mix($1.key.hashValue, $1.value.hashValue) })
        for job in jobs {
            var h = job.id.hashValue
            h = mix(h, job.planID.hashValue)
            h = mix(h, job.status.hashValue)
            h = mix(h, job.scheduled.timeIntervalSince1970.bitPattern.hashValue)
            h = mix(h, date(job.started))
            h = mix(h, date(job.submittedAt))
            h = mix(h, date(job.finished))
            h = mix(h, job.evidence.hashValue)
            h = mix(h, job.isOneOff.hashValue)
            seed = seed ^ h
        }
        return seed
    }
    /// 一次算出每条任务的最早发送时间。原排期只约束尚未开始的未来任务；
    /// 已发送后的冷却按实际提交时间和当前间隔计算，不继承旧排期的时间差。
    static func dueDates(_ jobs: [Delivery], gap: Int, intervalByPlan: [String:Int]) -> [String:Date] {
        let key = dueDatesFingerprint(jobs, gap: gap, intervalByPlan: intervalByPlan)
        if let hit = dueDatesMemo.first(where: { $0.key == key }) { return hit.value }
        let globalLast = lastSendActivity(jobs)
        let gapSeconds = Double(gap * 60)
        var groups: [String:[Delivery]] = [:]
        for job in jobs { groups[job.planID, default: []].append(job) }
        var dues: [String:Date] = [:]
        for group in groups.values {
            let ordered = group.sorted { lhs, rhs in
                if lhs.scheduled != rhs.scheduled { return lhs.scheduled < rhs.scheduled }
                return lhs.id < rhs.id
            }
            let planAnchor = lastSendActivity(ordered)
            let pace = intervalByPlan[ordered[0].planID].map { Double($0 * 60) }
            for job in ordered {
                var date = job.scheduled
                if let globalLast { date = max(date, globalLast.addingTimeInterval(gapSeconds)) }
                if let pace, let planAnchor { date = max(date, planAnchor.addingTimeInterval(pace)) }
                dues[job.id] = date
            }
        }
        if dueDatesMemo.count >= 4 { dueDatesMemo.removeFirst() }
        dueDatesMemo.append((key: key, value: dues))
        return dues
    }
    static func earliestSendDate(_ job: Delivery, jobs: [Delivery], gap: Int, intervalByPlan: [String:Int] = [:]) -> Date {
        dueDates(jobs, gap: gap, intervalByPlan: intervalByPlan)[job.id] ?? job.scheduled
    }
    static func nextCandidate(_ jobs: [Delivery], gap: Int, planID: String? = nil, allowedPlanIDs: Set<String>? = nil, intervalByPlan: [String:Int] = [:]) -> Delivery? {
        let dues = dueDates(jobs, gap: gap, intervalByPlan: intervalByPlan)
        return jobs.enumerated().filter { _, job in
            job.status == "queued" && !job.isOneOff && job.submittedAt == nil && job.evidence.isEmpty &&
                (planID == nil || job.planID == planID) && (allowedPlanIDs.map { $0.contains(job.planID) } ?? true)
        }.min { left, right in
            let leftJob = left.element, rightJob = right.element
            let l = dues[leftJob.id] ?? leftJob.scheduled, r = dues[rightJob.id] ?? rightJob.scheduled
            if l != r { return l < r }
            if leftJob.scheduled != rightJob.scheduled { return leftJob.scheduled < rightJob.scheduled }
            return left.offset < right.offset
        }?.element
    }
    static func eligible(_ jobs: [Delivery], now: Date, gap: Int, planID: String? = nil, intervalByPlan: [String:Int] = [:]) -> Delivery? {
        // 只防止并发前台操作；失败/待核对记录保留，但不阻止下一条干净的 queued。
        guard !jobs.contains(where: { $0.status == "running" }),
              let next = nextCandidate(jobs, gap: gap, planID: planID, intervalByPlan: intervalByPlan),
              earliestSendDate(next, jobs: jobs, gap: gap, intervalByPlan: intervalByPlan) <= now else { return nil }
        return next
    }
    /// 一次性补草稿的开单闸门：同一来源任务在上一张草稿出结果之前，不允许再开第二张。
    /// （原注释里描述「手动重启从点击时刻起另起节奏」的那段已随走查 1-01 的修复改写，见 `restarted`。）
    static func hasUnresolvedClone(of sourceID: String, in jobs: [Delivery]) -> Bool {
        return jobs.contains { $0.cloneOf == sourceID && ["queued", "running", "draft", "submitted", "blocked", "uncertain"].contains($0.status) }
    }
    /// 手动启动队列。走查 1-01 修正后的口径：默认只把**已经落后于当下（含冷却已到）**的待执行任务
    /// 拉到此刻按间隔依次补发，未来任务保持原计划时刻 —— 轮次（每天几轮）与天数结构不再被抹平，
    /// 30 天计划不会因为在下午点了「启动队列」而在凌晨连续补发。
    /// 与 `requeued` 早就在用的「只顺延、不提前」口径统一。已发过、有凭据或一次性的记录一律不动。
    /// `compressFuture: true` 保留旧的「从点击起连续重排」语义，只允许由显式确认的入口使用。
    /// `jitter: true`（错峰抖动）时后续任务的间隔带 0~+20%（至少 +1 分钟）向上随机偏移；序列首条的时刻
    /// 只由当下与它自己的原排期/冷却决定，天然不抖。默认 false，既有调用点行为不变。
    /// 错峰抖动：给间隔加向上 0~+offset 分钟的确定性随机偏移（offset = max(1, minutes / 5)，即最多 +20%、
    /// 至少 +1 分钟），打散「同 IP 同内容等差间隔」的典型风控特征。只在新排/重启生成 scheduled 日期时用，
    /// 不影响已发出的记录。纯函数：同一 seed 结果确定（测试可复现），不同 seed 一般产生不同偏移，
    /// 不碰全局随机状态。返回值落在 [max(5, minutes), minutes + offset]——只上浮、不下调：
    /// 运行期冷却（eligible/dueDates）按未抖动的原始间隔钳底，负向偏移会被钳回原值，预览时间就会
    /// 与实际执行不符；单向抖动让写入值与可执行值一致。下限 5 分钟，更短的间隔必触发风控。
    static func jittered(minutes: Int, seed: Int) -> Int {
        let offset = max(1, minutes / 5)
        let low = max(5, minutes)
        let high = max(low, minutes + offset)
        guard high > low else { return low }
        // 简单 LCG（Knuth MMIX 常数）：种子先推进两轮再取高位，避免小整数种子在低位留下规律；
        // 全程无符号运算取模，杜绝负数取模的符号陷阱，也保证上下界两端都可能取到。
        var state = UInt64(truncatingIfNeeded: seed)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let span = UInt64(high - low + 1)
        return low + Int(truncatingIfNeeded: (state >> 16) % span)
    }
    /// 错峰抖动的稳定种子：FNV-1a 逐字节哈希。不能用 `String.hashValue`——
    /// Swift 的哈希种子每次进程启动都不同，重启后同一任务的抖动值会漂移，测试也无法跨进程复现。
    static func stableSeed(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: hash)
    }

    static func restarted(_ jobs: [Delivery], planID: String?, now: Date, gap: Int, intervalByPlan: [String:Int], compressFuture: Bool = false, jitter: Bool = false) -> [Delivery] {
        var result = jobs
        let dues = dueDates(jobs, gap: gap, intervalByPlan: intervalByPlan)
        let indices = jobs.indices.filter {
            jobs[$0].status == "queued" && !jobs[$0].isOneOff && jobs[$0].submittedAt == nil && jobs[$0].evidence.isEmpty &&
                (planID == nil || jobs[$0].planID == planID)
        }.sorted { left, right in
            let lhs = jobs[left], rhs = jobs[right]
            let l = dues[lhs.id] ?? lhs.scheduled, r = dues[rhs.id] ?? rhs.scheduled
            if l != r { return l < r }
            if lhs.scheduled != rhs.scheduled { return lhs.scheduled < rhs.scheduled }
            return left < right
        }
        var next = now
        for index in indices {
            // earliest = 原排期与各类冷却下限里的较晚者；落后的任务 earliest < now，会被链条抬到 now 之后。
            let earliest = dues[jobs[index].id] ?? jobs[index].scheduled
            let target = compressFuture ? next : max(earliest, next)
            result[index].scheduled = target
            let baseMinutes = max(gap, intervalByPlan[jobs[index].planID] ?? gap)
            // 抖动只作用于间隔（即后续任务的位置）；本条 target 与 step 无关。种子取任务 id 经
            // stableSeed 跨进程稳定：同一条任务重启多少次抖动值一致，不同任务之间互不相同。
            let minutes = jitter ? jittered(minutes: baseMinutes, seed: stableSeed(jobs[index].id)) : baseMinutes
            next = target.addingTimeInterval(Double(minutes * 60))
        }
        return result
    }
    /// 计划每一轮的起点，与 `expand` 同一套生成规则（按 Calendar 逐日步进，times 为空时用 plan.starts 本身）。
    /// 覆盖范围放宽到给定时刻之外，循环轮次（recur 生成的更晚任务）也能落回对应的轮。
    private static func slotStarts(plan: Plan, through last: Date) -> [Date] {
        let offset = plan.scheduleOffsetSeconds ?? 0
        guard offset.isFinite, plan.starts.timeIntervalSinceReferenceDate.isFinite,
              last.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let parsed = (try? times(plan.times.joined(separator: ","))) ?? plan.times.sorted()
        let anchor = calendar.startOfDay(for: plan.starts)
        // through 已含平移；先撤销偏移再求天数，负向跨零点不会漏掉原始后续轮次。
        let unshiftedLast = last.addingTimeInterval(-offset)
        guard unshiftedLast.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let horizon = calendar.startOfDay(for: max(unshiftedLast, plan.starts))
        let spanned = (calendar.dateComponents([.day], from: anchor, to: horizon).day ?? 0) + 1
        let dayCount = min(max(max(spanned, plan.days), 1), 400)
        var slots: [Date] = []
        for day in 0..<dayCount {
            guard let base = calendar.date(byAdding: .day, value: day, to: plan.starts) else { continue }
            if parsed.isEmpty { slots.append(base.addingTimeInterval(offset)); continue }
            for slot in parsed {
                let parts = slot.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                if let start = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: base) { slots.append(start.addingTimeInterval(offset)) }
            }
        }
        return slots.sorted()
    }
    /// 待执行序列按轮分桶。给了计划就按 `expand` 的轮次时刻精确归桶；没有计划对象时（既有调用点）
    /// 从排期本身推断：跨零点，或相邻空档明显大于本序列的最小轮内间隔，即视为新的一轮。
    /// 推断不出真实轮界时只会多分桶（结果更接近“原样保留”），不会把不同天的任务并成一桶。
    private static func roundBuckets(_ jobs: [Delivery], indices: [Int], plan: Plan?) -> [(start: Date, members: [Int])] {
        let sorted = indices.sorted { lhs, rhs in
            if jobs[lhs].scheduled != jobs[rhs].scheduled { return jobs[lhs].scheduled < jobs[rhs].scheduled }
            return lhs < rhs
        }
        guard let first = sorted.first else { return [] }
        var buckets: [(start: Date, members: [Int])] = []
        if let plan {
            let slots = slotStarts(plan: plan, through: jobs[sorted.last!].scheduled)
            for index in sorted {
                let at = jobs[index].scheduled
                let start = slots.last(where: { $0 <= at.addingTimeInterval(1) }) ?? at
                if var tail = buckets.last, tail.start == start {
                    tail.members.append(index); buckets[buckets.count - 1] = tail
                } else { buckets.append((start: start, members: [index])) }
            }
            return buckets
        }
        var smallest = Double.infinity
        for step in 1..<sorted.count {
            let gap = jobs[sorted[step]].scheduled.timeIntervalSince(jobs[sorted[step - 1]].scheduled)
            if gap > 1 { smallest = min(smallest, gap) }
        }
        buckets.append((start: jobs[first].scheduled, members: [first]))
        for step in 1..<sorted.count {
            let at = jobs[sorted[step]].scheduled, previous = jobs[sorted[step - 1]].scheduled
            let newRound = calendar.startOfDay(for: at) != calendar.startOfDay(for: previous) ||
                (smallest.isFinite && at.timeIntervalSince(previous) > smallest + 1)
            if newRound { buckets.append((start: at, members: [sorted[step]])) }
            else { buckets[buckets.count - 1].members.append(sorted[step]) }
        }
        return buckets
    }
    /// 应用新间隔。走查 1-02 修正后的口径：轮内按新间隔（或该群自己的逐群间隔）重算先后距离，
    /// 轮次起点与天数分布保持原样，只顺延、不拉近 —— 不再把「6 群 × 3 轮 × 5 天」压成一条连续流。
    /// `preserveFutureStart == false` 仍是显式的「整串拉到当下连续重排」，供已开始单轮的计划缩短间隔用。
    /// 既有调用点不传 `plan` 时按上面的推断分桶，行为同样不再破坏天数结构；能拿到计划对象时请传入。
    static func retimed(_ jobs: [Delivery], planID: String, minutes: Int, now: Date, globalGap: Int,
                        preserveFutureStart: Bool = true, plan: Plan? = nil) throws -> [Delivery] {
        guard (1...1440).contains(minutes), minutes >= globalGap else { throw AppError("间隔须为1–1440分钟，且不小于全局最小间隔") }
        let indices = jobs.indices.filter {
            jobs[$0].planID == planID && jobs[$0].status == "queued" && !jobs[$0].isOneOff &&
                jobs[$0].submittedAt == nil && jobs[$0].evidence.isEmpty
        }.sorted { jobs[$0].scheduled < jobs[$1].scheduled }
        guard let first = indices.first else { throw AppError("当前计划没有待执行任务") }
        var result = jobs
        let globalCooldown = (lastSendActivity(jobs) ?? .distantPast).addingTimeInterval(Double(globalGap * 60))
        let planCooldown = (lastSendActivity(jobs.filter { $0.planID == planID }) ?? .distantPast).addingTimeInterval(Double(minutes * 60))
        var floorTime = max(now, preserveFutureStart ? jobs[first].scheduled : now, globalCooldown, planCooldown)
        guard preserveFutureStart else {
            var next = floorTime
            for i in indices { result[i].scheduled = next; next = next.addingTimeInterval(Double(minutes * 60)) }
            return result
        }
        for bucket in roundBuckets(jobs, indices: indices, plan: plan) {
            // 桶起点 = 原轮次时刻，只被冷却/上一轮的尾巴往后推，绝不往当下拉近
            var at = max(bucket.start, floorTime)
            for (position, index) in bucket.members.enumerated() {
                if position > 0 {
                    let custom = jobs[index].recipientID.flatMap { plan?.recipientGaps?[$0] }
                    let gap = min(max(custom ?? minutes, 1), 1440)
                    at = max(at.addingTimeInterval(Double(gap * 60)), floorTime)
                }
                result[index].scheduled = at
                floorTime = max(floorTime, at.addingTimeInterval(Double(minutes * 60)))
            }
        }
        return result
    }
    /// 手动重新入队不做队尾追加：受影响计划把待执行序列（现有 queued 与本次
    /// 重新入队）按原排程顺序从安全基准时刻重排，暂停任务不越过原本排在它
    /// 后面的任务；原待执行任务只顺延、不提前，未来排程不被拉近。不可重试
    /// 的记录与其他计划一律不动。
    static func requeued(_ jobs: [Delivery], ids: Set<String>, now: Date, gap: Int, intervalByPlan: [String:Int] = [:]) -> [Delivery] {
        var result = jobs
        // 只有真正会重新入队的任务才牵动所属计划；不可重试的记录保持原样。
        let affectedPlans = Set(jobs.filter { ids.contains($0.id) && $0.canRequeue }.map(\.planID))
        let globalCooldown = (lastSendActivity(jobs) ?? .distantPast).addingTimeInterval(Double(gap * 60))
        for planID in affectedPlans {
            let interval = max(gap, intervalByPlan[planID] ?? gap)
            let planCooldown = (lastSendActivity(jobs.filter { $0.planID == planID }) ?? .distantPast).addingTimeInterval(Double(interval * 60))
            var next = max(now, globalCooldown, planCooldown)
            // 待执行序列沿用 restarted 的筛选口径，再加上本次重新入队的任务。
            let sequence = jobs.indices.filter { i in
                jobs[i].planID == planID &&
                    ((jobs[i].status == "queued" && !jobs[i].isOneOff && jobs[i].submittedAt == nil && jobs[i].evidence.isEmpty) ||
                        (ids.contains(jobs[i].id) && jobs[i].canRequeue))
            }.sorted {
                if jobs[$0].scheduled != jobs[$1].scheduled { return jobs[$0].scheduled < jobs[$1].scheduled }
                return $0 < $1
            }
            for i in sequence {
                if ids.contains(jobs[i].id) && jobs[i].canRequeue {
                    result[i].status = "queued"
                    result[i].historyClearedAt = nil
                    result[i].started = nil; result[i].finished = nil
                    result[i].detail = "手动重新入队；上次暂停：" + jobs[i].detail
                    result[i].scheduled = next
                } else {
                    result[i].scheduled = max(jobs[i].scheduled, next)
                }
                next = result[i].scheduled.addingTimeInterval(Double(interval * 60))
            }
        }
        return result
    }

    /// 一轮是否收尾：存在非一次性任务，且这些任务全部处于终态（verified/manual/cancelled）；
    /// 只要非一次性任务里还有 queued/running/draft/submitted/blocked/uncertain 任何一种，就还没收尾。
    /// 一次性补草稿（oneOff）不是轮次成员：卡住的一次性任务不阻塞循环收尾。
    static func cycleComplete(_ jobs: [Delivery]) -> Bool {
        let regular = jobs.filter { !$0.isOneOff }
        return !regular.isEmpty && regular.allSatisfy { ["verified", "manual", "cancelled"].contains($0.status) }
    }

    /// 按「天」平移一个墙钟时刻：走 `Scheduling.calendar`，不用固定 86400 秒（走查 1-12）。
    /// 北京时间本身没有夏令时，但用户把 Mac 时区改掉时，定长秒数会让每一轮漂离设定的几点几分。
    static func shifted(_ date: Date, byDays days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86400)
    }

    /// 生成下一轮循环任务。jobs 必须是该计划的全部任务。
    /// 返回 nil：计划未开循环（recurringEveryDays == nil）或本轮未收尾；
    /// 返回 []：本轮收尾但没有可复制的任务（全被取消，或收件人已全部移出名单）；
    /// throws AppError：加上新一轮会超过单计划 10000 条未取消任务上限；
    ///                 或 `recurringEveryDays` 不在 1...365（旧库/手工改库/恢复备份都可能带进 0 或负值，
    ///                 与刚发完同刻的重复任务会在启动时把整批群连发一遍，走查 1-10）。
    /// 模板规则：取「最后一轮」的全部任务——有轮次标记时取 cycleTag 最大的一轮，
    /// 否则取原始轮（全部任务）；模板排除一次性任务、已取消任务，以及已从计划
    /// 名单移除的收件人。多场/多天计划的每一场逐条复制，不按收件人塌缩成一条。
    /// 时间规则：新任务时间 = 模板任务时间 + recurringEveryDays 天（逐条保留原时刻与相互间隔）；
    /// 若最早一条早于 max(now, lastSendActivity(全部 jobs) + gap 分钟)，整组按整天
    /// 统一平移直到不早于该下限（保持各任务时刻与间隔）。intervalByPlan 给出该计划更长的
    /// 间隔时，以它作为冷却下限（不传即按 gap）。
    /// 新任务：全新 id、status 默认 queued、cycleTag = 上一轮最大 cycleTag（nil 视为 0）+ 1、
    /// detail = "循环第 N 轮；自动接续上一轮"、started/submittedAt/finished/evidence 全空、
    /// oneOff/cloneOf 置空；内容快照（text/assets/mode/channel/recipientID）沿用模板任务。
    static func recur(_ plan: Plan, jobs: [Delivery], now: Date, gap: Int, intervalByPlan: [String:Int] = [:]) throws -> [Delivery]? {
        guard let everyDays = plan.recurringEveryDays else { return nil }
        guard everyDays >= 1, everyDays <= 365 else { throw AppError("循环间隔无效（\(everyDays) 天），已停止接续下一轮，请到计划里重新设置") }
        let offset = plan.scheduleOffsetSeconds ?? 0
        guard offset.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { throw AppError("循环排期日期或偏移无效") }
        guard cycleComplete(jobs) else { return nil }
        // 模板 = 最后一轮的全部任务：有轮次标记取 cycleTag 最大的一轮，否则原始轮全量。
        let maxTag = jobs.compactMap { $0.cycleTag }.max()
        let lastRound = maxTag.map { tag in jobs.filter { $0.cycleTag == tag } } ?? jobs
        // 一次性补草稿与已取消任务不是轮次成员；已移出名单的收件人不再续发。
        let template = lastRound.filter {
            !$0.isOneOff && $0.status != "cancelled" && $0.recipientID.map { plan.recipientIDs.contains($0) } == true
        }
        guard !template.isEmpty else { return [] }
        let tag = (maxTag ?? 0) + 1
        guard jobs.filter({ $0.status != "cancelled" }).count + template.count <= 10000 else { throw AppError("加上循环第 \(tag) 轮会超过单计划 10000 条未取消任务上限，请关闭循环或减少群数") }
        var drafted = try template.map { job -> Delivery in
            let appliedOffset = job.scheduleOffsetSeconds ?? 0
            guard appliedOffset.isFinite, job.scheduled.timeIntervalSinceReferenceDate.isFinite else { throw AppError("原任务排期日期或偏移无效，未生成下一轮") }
            let aligned = job.scheduled.addingTimeInterval(offset - appliedOffset)
            guard aligned.timeIntervalSinceReferenceDate.isFinite else { throw AppError("循环排期偏移超出支持范围") }
            var copy = job
            copy.scheduled = shifted(aligned, byDays: everyDays)
            guard copy.scheduled.timeIntervalSinceReferenceDate.isFinite else { throw AppError("循环任务日期无效") }
            copy.scheduleOffsetSeconds = plan.scheduleOffsetSeconds
            return copy
        }
        let cooldown = max(gap, intervalByPlan[plan.id] ?? gap)
        let lower = max(now, (lastSendActivity(jobs) ?? .distantPast).addingTimeInterval(Double(cooldown * 60)))
        if let earliest = drafted.map(\.scheduled).min(), earliest < lower {
            // 只按整天整组统一平移，各任务时刻与相互间隔保持不变
            let wholeDays = (calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: calendar.startOfDay(for: lower)).day ?? 0) + 1
            var shiftDays = max(1, wholeDays)
            // 原时刻的时分晚于下限的时分时还要再补一天（最多补两次，避免定长秒数的夏令时漂移）
            for _ in 0..<2 where shifted(earliest, byDays: shiftDays) < lower { shiftDays += 1 }
            for i in drafted.indices { drafted[i].scheduled = shifted(drafted[i].scheduled, byDays: shiftDays) }
        }
        let created = drafted.map { template -> Delivery in
            var job = template
            job.id = UUID().uuidString; job.status = "queued"; job.cycleTag = tag
            job.detail = "循环第 \(tag) 轮；自动接续上一轮"
            job.started = nil; job.submittedAt = nil; job.finished = nil; job.evidence = ""
            job.qqVerification = nil; job.historyClearedAt = nil
            job.oneOff = nil; job.cloneOf = nil
            return job
        }
        return ordered(created)
    }

    /// 向本计划追加群聊（走查 1-06 修正）。
    /// ①模板只从「内容模板」里取：排除一次性补草稿和正在处理的记录，优先与计划同发送模式的那批；
    /// ②新任务无条件清洗 oneOff / cloneOf / mode，不再把队尾偶然记录的属性继承进来
    ///   （继承 oneOff 会让 `nextCandidate` 永远跳过它 = 该群静默不发送；继承被改过的 mode 会让草稿计划偷偷自动发）；
    /// ③cycleTag 归到当前最新一轮，让新群继续参与循环，而不是被留在循环之外；
    /// ④传 `assets` 时按计划的配图列表取快照，与界面「沿用本计划的图文」一致；不传保持旧行为（沿用模板快照）。
    /// Add one delivery per new recipient to the end of this plan, retaining its message snapshot.
    static func additionalDeliveries(plan: Plan, recipients: [Recipient], jobs: [Delivery], now: Date, gap: Int, assets: [Asset] = []) throws -> [Delivery] {
        guard (plan.scheduleOffsetSeconds ?? 0).isFinite, now.timeIntervalSinceReferenceDate.isFinite else { throw AppError("追加任务日期或排期偏移无效") }
        let existing = jobs.filter { QueueBatch.contains($0, in: plan) }
        let reusable = existing.filter { !$0.isOneOff && $0.status != "running" }
        let candidates = reusable.filter { $0.mode == plan.mode }
        let pool = candidates.isEmpty ? reusable : candidates
        guard let template = pool.sorted(by: { $0.scheduled < $1.scheduled }).last else {
            throw AppError(existing.isEmpty ? "计划没有可沿用的发送内容，请新建计划" : "计划里只有一次性或正在处理的任务，无法沿用图文，请新建计划")
        }
        var names = Set(existing.map { $0.channelName + "\u{0}" + $0.recipient })
        var ids = Set(plan.recipientIDs)
        var next = max(now, existing.map(\.scheduled).max() ?? now)
        let interval = Double(max(1, max(gap, plan.intervalMinutes)) * 60)
        let latestCycle = existing.compactMap { $0.cycleTag }.max()
        let snapshot = assets.isEmpty ? template.assets : plan.assetIDs.compactMap { id in assets.first { $0.id == id } }
        var added: [Delivery] = []
        for recipient in recipients where !ids.contains(recipient.id) {
            let key = recipient.channelName + "\u{0}" + recipient.name
            guard names.insert(key).inserted else { continue }
            ids.insert(recipient.id)
            next = next.addingTimeInterval(interval)
            var job = template
            job.text = plan.text
            job.assets = snapshot
            job.id = UUID().uuidString; job.recipientID = recipient.id; job.recipient = recipient.name; job.channel = recipient.channelName
            job.scheduled = next; job.status = "queued"; job.detail = "手动追加到本计划，等待执行"
            job.started = nil; job.submittedAt = nil; job.finished = nil; job.evidence = ""
            job.qqVerification = nil; job.historyClearedAt = nil; job.scheduleOffsetSeconds = plan.scheduleOffsetSeconds
            job.oneOff = nil; job.cloneOf = nil; job.cycleTag = latestCycle; job.mode = plan.mode
            job.dispatchBatchID = plan.dispatchBatchID
            added.append(job)
        }
        return added
    }

    /// 重启后的记录恢复（AGENTS.md 第 9 行的判定保持原样，只改「不得改写」这一半，走查 1-08）：
    /// 旧版超时记录仅在没有 started、没有 submittedAt、没有 evidence 且原因正是那条已废弃文案时才回到待执行；
    /// 已经尝试过的记录保留供用户核对，恢复说明一律**追加**在原记录后面，不覆盖上一次卡在哪一步。
    static func recovered(_ jobs: [Delivery]) -> [Delivery] {
        jobs.map { original in
            var job = original
            // Only the retired deadline guard is safe to recover automatically.
            // No driver ran, no draft was filled and no submission was attempted.
            if job.status == "blocked", job.started == nil, job.submittedAt == nil, job.evidence.isEmpty,
               job.detail == "已错过计划时间超过 15 分钟，不集中补发。请点击重新排期" {
                job.status = "queued"
                job.finished = nil
                job.detail = SendChannel.keptRecord(note: "旧版超时暂停已恢复；等待手动启动，按全局间隔执行", previous: job.detail)
            }
            if ["running", "submitted"].contains(job.status) {
                job.status = "uncertain"
                job.detail = SendChannel.crashRecoveryDetail(channel: job.channelName, previous: job.detail)
            }
            return job
        }
    }
}

/// 发送前预告的决策纯函数：下一条任务进入「发送时刻前 leadMinutes」窗口时给出预告内容。
/// 「下一条」口径与 Scheduling.nextCandidate/dueDates 完全一致（排除 isOneOff/submittedAt/evidence，
/// 时刻锚 due 而非 scheduled——due 可能被冷却顺延）。
/// 正在执行一条前台操作时不预告；待核对记录不阻止后续任务与预告。
/// 去重由调用方持有 (announcedID, announcedDue)：id 相同且 due 未变才算已预告；
/// 撤销恢复/改期会让 due 变化 → 自然再次预告；任务消失 → 记录自然失效。
enum UpcomingAnnouncement {
    struct Plan: Equatable {
        let jobID: String
        let due: Date
        let timeText: String
        let planName: String
        let recipient: String
        let minutes: Int
    }
    static func evaluate(deliveries: [Delivery], now: Date, gap: Int, intervalByPlan: [String: Int],
                         leadMinutes: Int, calendar: Calendar,
                         announcedID: String?, announcedDue: Date?,
                         planScope: String? = nil) -> Plan? {
        guard leadMinutes > 0 else { return nil }
        guard !deliveries.contains(where: { $0.status == "running" }) else { return nil }
        // 作用域与 tick 同参（运行中只看当前计划）：作用域外的任务不会被发送，预告它就是误导。
        guard let next = Scheduling.nextCandidate(deliveries, gap: gap, planID: planScope, intervalByPlan: intervalByPlan) else { return nil }
        let due = Scheduling.earliestSendDate(next, jobs: deliveries, gap: gap, intervalByPlan: intervalByPlan)
        let lead = due.timeIntervalSince(now)
        // 30 秒内就不预告了：马上要发的东西预告反而添乱
        guard lead > 30, lead <= Double(leadMinutes) * 60 else { return nil }
        if announcedID == next.id, announcedDue == due { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: due)
        let timeText = String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return Plan(jobID: next.id, due: due, timeText: timeText, planName: next.planName,
                    recipient: next.recipient, minutes: max(1, Int(lead / 60)))
    }
}

/// 单任务「推迟 N 分钟」：目标时刻 = 原排期 + N，且绝不早于「现在 + 10 秒」托底
/// （推迟一条已过期任务时，+N 仍可能落在过去——运行期会把过期任务立即发送，「推迟」就静默变成了「马上发」）。
/// 运行期 due = max(scheduled, 冷却下限) 只会往下钳更晚的方向，推迟操作绝不会被反向提前。
enum Postpone {
    static func target(scheduled: Date, minutes: Int, now: Date) -> Date {
        let shifted = scheduled.addingTimeInterval(Double(minutes) * 60)
        return max(shifted, now.addingTimeInterval(10))
    }
}

/// 批量取消的撤销窗：从快照里挑出可原样恢复的记录。
/// 恢复条件：id 仍存在、状态仍是 cancelled、没有产生新的提交痕迹（submittedAt 为空且无 evidence）。
/// 已被改期/重试/核对过的部分不恢复，交由 UI 播报「无法恢复」的数量——绝不覆盖后续发生的变化。
enum RecordUndo {
    static func restorable(snapshot: [Delivery], current: [Delivery]) -> [Delivery] {
        snapshot.filter { original in
            guard let now = current.first(where: { $0.id == original.id }) else { return false }
            return now.status == "cancelled" && now.submittedAt == nil && now.evidence.isEmpty
        }
    }
}

/// 新排期开始时清理上一排期记录。红线：uncertain/submitted（可能已真实发出、待人工核对）
/// 只有用户在 UI 明确确认后才可清除；running 永远不可清除（活跃操作）。
/// 为什么是纯函数：清除是不可逆的破坏性操作，把“删什么”的决策从“真的删”里拆出来，
/// 决策本身就能单独测试与复核；Store 只按 Outcome.kept 落盘。
enum RecordPurge {
    struct Outcome: Equatable {
        let kept: [Delivery]              // 清理后的完整数组（含新计划自己的全部记录）
        let purged: Int                   // 移除总数
        let purgedPendingReview: Int      // 移除中的 uncertain/submitted 条数
    }
    static func plan(all: [Delivery], keepingPlanID: String, includePendingReview: Bool, now: Date) -> Outcome {
        var kept: [Delivery] = []
        var purged = 0
        var purgedPendingReview = 0
        for job in all {
            // 新计划自己的记录一律保留：这是本轮的活跃数据，任何状态下都不属于“上一排期沉淀”。
            if job.planID == keepingPlanID {
                kept.append(job)
                continue
            }
            // running 是正在处理的活跃操作：无论属于哪个旧排期、用户确认到什么程度都不许清，
            // 否则会把一条可能正在发送中的任务从队列里凭空抹掉。
            // draft 与 running 同等保留：草稿窗口可能还在 QQ 里等确认，清掉记录后应用不再追踪。
            if job.status == "running" || job.status == "draft" {
                kept.append(job)
                continue
            }
            // uncertain/submitted 可能已经真实发出，清除等于销毁待人工核对的证据：
            // 仅当用户在 UI 明确勾选“连待核对一起清”时才允许，且单独计数供确认弹窗展示。
            if ["uncertain", "submitted"].contains(job.status) {
                guard includePendingReview else {
                    kept.append(job)
                    continue
                }
                purged += 1
                purgedPendingReview += 1
                continue
            }
            // blocked 且已尝试（started/evidence 非空）的记录可能已真实发出但未核验，
            // 清理时与 uncertain/submitted 同等对待（仅用户明确确认后才移除）。
            if job.status == "blocked", job.started != nil || !job.evidence.isEmpty {
                guard includePendingReview else {
                    kept.append(job)
                    continue
                }
                purged += 1
                purgedPendingReview += 1
                continue
            }
            // 兜底前的最后一道证据防线：cancelled/queued 等沉淀状态也可能带着提交或执行痕迹
            // （例如用户从待核对手动取消的记录，Core 侧 lastSendActivity 特意把它算进冷却）。
            // 它们与 uncertain/submitted 一样可能对应一次真实发送，静默清除等于销毁对账凭证：
            // 走同一道确认制，单独计数。
            if job.submittedAt != nil || !job.evidence.isEmpty {
                guard includePendingReview else {
                    kept.append(job)
                    continue
                }
                purged += 1
                purgedPendingReview += 1
                continue
            }
            // 其余状态（verified/manual/cancelled/draft/queued 等无痕迹记录）属于上一排期沉淀，
            // 只要 planID 不同即可安全移除。now 当前不参与判定，保留参数以稳定调用方签名。
            purged += 1
        }
        return Outcome(kept: kept, purged: purged, purgedPendingReview: purgedPendingReview)
    }
}

/// 今日发送战报：三色仪表盘（绿=已发送 / 黄=待核对 / 红=已拦截 / 灰=待执行）的数据层。
/// 口径：sent 只算今天完成核验的（finished 落在今天，缺失时回退 started）；其余三类是
/// 「当前仍处于该状态」的存量——待核对/已拦截不分天（没处理完就一直要显示），待执行是即将发生的。
enum DailySendReport {
    struct PlanLine: Equatable {
        let planName: String
        let sent: Int
        let pendingReview: Int   // uncertain + submitted
        let blocked: Int
        let queued: Int
    }
    struct Outcome: Equatable {
        let sent: Int
        let pendingReview: Int
        let blocked: Int
        let queued: Int
        let lines: [PlanLine]          // 按记录数降序，只含有非零计数的计划
        var hasContent: Bool { sent > 0 || pendingReview > 0 || blocked > 0 || queued > 0 }
    }
    /// 纯函数：只聚合传入的记录，不碰持久化。状态缺失时间戳的已核验记录既不算发送也不落入其他三类。
    static func today(deliveries: [Delivery], planNames: [String: String], now: Date, calendar: Calendar) -> Outcome {
        struct Tally {
            var sent = 0, pendingReview = 0, blocked = 0, queued = 0
            var total: Int { sent + pendingReview + blocked + queued }
            mutating func merge(_ other: Tally) {
                sent += other.sent; pendingReview += other.pendingReview; blocked += other.blocked; queued += other.queued
            }
        }
        var overall = Tally()
        var byPlan: [String: Tally] = [:]
        // 计划名快照：Delivery 自带创建时的 planName；计划被删后仍能显示真实名称而不是「已删计划」。
        var nameSnapshots: [String: String] = [:]
        for job in deliveries {
            if nameSnapshots[job.planID]?.isEmpty ?? true, !job.planName.isEmpty { nameSnapshots[job.planID] = job.planName }
            var bucket = Tally()
            switch job.status {
            case "verified", "manual":
                // 发送只看今天完成核验的时刻：优先 finished，缺失时回退 started；两者都没有则不按今天计。
                guard let stamp = job.finished ?? job.started, calendar.isDate(stamp, inSameDayAs: now) else { continue }
                bucket.sent = 1
            case "uncertain", "submitted":
                bucket.pendingReview = 1   // 存量：不按日期过滤，处理完之前一直要显示
            case "blocked":
                bucket.blocked = 1
            case "queued":
                // queued + submittedAt 是「永远不会执行的待执行」（listGuidance 已指引去核对）：
                // 战报归入待核对，避免「待执行」虚高（审计 2026-10-06）。
                if job.submittedAt != nil { bucket.pendingReview = 1 } else { bucket.queued = 1 }
            default:
                continue   // running/draft/cancelled 等其余状态不属于仪表盘四类
            }
            overall.merge(bucket)
            byPlan[job.planID, default: Tally()].merge(bucket)
        }
        let lines: [PlanLine] = byPlan
            .filter { $0.value.total > 0 }
            .map { (planID: String, tally: Tally) -> PlanLine in
                let snapshot = nameSnapshots[planID].flatMap { $0.isEmpty ? nil : $0 }
                let name = planNames[planID] ?? snapshot ?? "（已删计划）"
                return PlanLine(planName: name, sent: tally.sent, pendingReview: tally.pendingReview, blocked: tally.blocked, queued: tally.queued)
            }
        func grandTotal(_ line: PlanLine) -> Int { line.sent + line.pendingReview + line.blocked + line.queued }
        let sorted = lines.sorted { lhs, rhs in
            // 总数降序；同分时按名称稳定排序，避免相同计数的计划行顺序抖动
            let l = grandTotal(lhs), r = grandTotal(rhs)
            return l != r ? l > r : lhs.planName < rhs.planName
        }
        return Outcome(sent: overall.sent, pendingReview: overall.pendingReview, blocked: overall.blocked, queued: overall.queued, lines: sorted)
    }
}

/// 自然语言时间快速输入：「明天 9 点」「后天 15:30」「下周三下午三点」直接变开始时间。
/// 只解析「一个时间点」；解析不出或表达的是过去时刻时按规则滚动，绝不静默丢弃输入。
enum NaturalTime {
    /// 解析成功返回调整后的开始时间；返回 nil 表示看不懂（调用方显示降级提示，不动表单）。
    /// 为什么是纯函数：NSDataDetector 的相对表达（明天/下午3点）以「真实当前时刻」为参照，
    /// 结果会随运行时刻漂移（测试也会跟着真实日期失效）。这里先把文本里的相对日期词
    /// （中文常用集 + 英文 today/tonight/tomorrow）与「月-日」按传入 now 归一成绝对
    /// 「YYYY年M月D日」；纯时刻输入则丢弃 detector 依赖真实时钟的日期选择、用传入 now 重建。
    /// 相同输入（文本、now、calendar）因此得到相同输出，不随运行日期漂移。
    /// 时区说明：NSDataDetector 按系统时区返回 Date（绝对时间戳），后续 calendar 操作
    /// （取时分、滚动到明天）已用传入的 calendar（Asia/Shanghai），口径自动对齐。
    static func parse(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let prepared = anchorRelativeDays(text, now: now, calendar: calendar)
        guard let match = detector.firstMatch(in: prepared.text, range: NSRange(location: 0, length: (prepared.text as NSString).length)) else { return nil }
        guard let date = match.date else { return nil }
        // 只取第一个时间点：detector 返回带 duration 的区间时 match.date 本就是起点，直接沿用。
        if prepared.anchored, date > now { return date }
        if !prepared.anchored {
            // 纯时刻（「下午3点」「15:30」）：detector 的日期选择以真实时钟为准（还没到给今天、
            // 已过给明天），随运行时刻漂移；丢弃其日期，按传入 now 的当天重建，已过再走下方滚动。
            var todayComps = calendar.dateComponents([.year, .month, .day], from: now)
            todayComps.hour = calendar.component(.hour, from: date)
            todayComps.minute = calendar.component(.minute, from: date)
            todayComps.second = 0
            if let candidate = calendar.date(from: todayComps), candidate > now { return candidate }
        }
        // 过去时刻滚动：保留时与分，日期推进到明天（now+1 天组合）；极端情况仍是过去再加 1 天，绝不返回过去。
        guard let tomorrowBase = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        var tomorrowComps = calendar.dateComponents([.year, .month, .day], from: tomorrowBase)
        tomorrowComps.hour = calendar.component(.hour, from: date)
        tomorrowComps.minute = calendar.component(.minute, from: date)
        tomorrowComps.second = 0
        guard let tomorrow = calendar.date(from: tomorrowComps) else { return nil }
        if tomorrow > now { return tomorrow }
        return calendar.date(byAdding: .day, value: 1, to: tomorrow)
    }

    /// 把文本里的相对日期词（中文常用集 + 英文 today/tonight/tomorrow）与「月-日」（不带年份）
    /// 替换成绝对「YYYY年M月D日」。返回替换后的文本与是否发生过替换；替换一律以传入 now 为基准。
    /// 「下周X」定义为下一个自然周里的星期 X（8–14 天后）；「月-日」早于当天时取明年。
    private static func anchorRelativeDays(_ text: String, now: Date, calendar: Calendar) -> (text: String, anchored: Bool) {
        let full = text as NSString
        func absoluteDay(_ offset: Int) -> String {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return "" }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            return "\(c.year!)年\(c.month!)月\(c.day!)日"
        }
        var replacements: [(range: NSRange, text: String)] = []
        // ① 相对日词：同一正则一次扫描；长词在前，避免「大前天」被「前天」「昨天」拆开替换。
        let dayPattern = "大前天|大后天|前天|昨天|今天|明天|后天|下周[一二三四五六日天]|\\b(?:today|tonight|tomorrow)\\b"
        let weekdayOf: [String: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        if let regex = try? NSRegularExpression(pattern: dayPattern, options: .caseInsensitive) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: full.length)) {
                let word = full.substring(with: m.range).lowercased()
                let replacement: String
                if word.hasPrefix("下周"), let target = weekdayOf[String(word.suffix(1))] {
                    // 严格下周：先推 7 天，再走到目标星期；0 步进（同星期）补 7 天，落在 8–14 天后。
                    let delta = (target - calendar.component(.weekday, from: now) + 7) % 7
                    guard let day = calendar.date(byAdding: .day, value: 7 + (delta == 0 ? 7 : delta), to: now) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day], from: day)
                    replacement = "\(c.year!)年\(c.month!)月\(c.day!)日"
                } else {
                    let offset: Int
                    switch word {
                    case "大前天": offset = -3
                    case "前天": offset = -2
                    case "昨天": offset = -1
                    case "今天", "today", "tonight": offset = 0
                    case "明天", "tomorrow": offset = 1
                    case "后天": offset = 2
                    case "大后天": offset = 3
                    default: continue
                    }
                    replacement = absoluteDay(offset)
                }
                replacements.append((m.range, replacement))
            }
        }
        // ② 「M月D日」「M-D」「M/D」（不带年份；前面不得是数字或日期分隔符，排除 2026-10-06 这种已带年份的写法）。
        let monthDayPattern = "(?<![\\d./-])(\\d{1,2})月(\\d{1,2})[日号]|(?<![\\d./-])(\\d{1,2})[-/.](\\d{1,2})(?![\\d日号])"
        if let regex = try? NSRegularExpression(pattern: monthDayPattern) {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: full.length)) {
                func group(_ i: Int) -> Int { m.range(at: i).location == NSNotFound ? -1 : (Int(full.substring(with: m.range(at: i))) ?? -1) }
                let month = group(1) != -1 ? group(1) : group(3)
                let day = group(2) != -1 ? group(2) : group(4)
                guard (1...12).contains(month), (1...31).contains(day) else { continue }
                let thisYear = calendar.component(.year, from: now)
                var comps = DateComponents()
                comps.year = thisYear; comps.month = month; comps.day = day
                guard let candidate = calendar.date(from: comps) else { continue }
                let resolvedYear = calendar.startOfDay(for: candidate) >= calendar.startOfDay(for: now) ? thisYear : thisYear + 1
                replacements.append((m.range, "\(resolvedYear)年\(month)月\(day)日"))
            }
        }
        guard !replacements.isEmpty else { return (text, false) }
        // 两轮扫描命中的文本区域互不重叠（中文词/英文词 vs 数字日期）；从后往前替换，前段位置不受影响。
        var result = text
        for (range, replacement) in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return (result, true)
    }
}

/// 发送顺序的纯函数操作；QQ 与微信是两套隔离的排序体系，移动只影响同渠道成员的相对位置。
enum RecipientRename {
    static func resolve(_ job: Delivery, recipients: [Recipient]) throws -> String {
        if let id = job.recipientID {
            guard recipients.contains(where: { $0.id == id && $0.channelName == job.channelName }) else { throw AppError("对应群聊已从名单移除，请先恢复名单") }
            return id
        }
        let matches = recipients.filter { $0.name == job.recipient && $0.channelName == job.channelName }
        guard matches.count == 1 else { throw AppError("无法唯一关联群聊名单，请先在名单中检查该群") }
        return matches[0].id
    }

    static func renamed(_ archive: Archive, id: String, name: String) throws -> Archive {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && !name.contains("\n") && !name.contains("\r") else { throw AppError("请输入单行、非空的群名") }
        guard let index = archive.recipients.firstIndex(where: { $0.id == id }) else { throw AppError("群聊已从名单移除") }
        let old = archive.recipients[index]
        guard !archive.recipients.contains(where: { $0.id != id && $0.channelName == old.channelName && $0.name == name }) else { throw AppError("该渠道已有同名群聊，请换一个名称") }
        var result = archive
        for i in result.deliveries.indices {
            let job = result.deliveries[i]
            guard job.channelName == old.channelName else { continue }
            let linked = job.recipientID == id || (job.recipientID == nil && job.recipient == old.name && archive.recipients.filter { $0.name == old.name && $0.channelName == old.channelName }.count == 1)
            guard linked else { continue }
            guard !["running", "draft", "submitted", "uncertain"].contains(job.status) else { throw AppError("该群有正在处理或待核对的任务，请处理后再修改群名") }
            if job.canRenameRecipient {
                result.deliveries[i].recipientID = id
                result.deliveries[i].recipient = name
            }
        }
        result.recipients[index].name = name
        return result
    }
}

enum RecipientList {
    static func filtered(_ recipients: [Recipient], channel: String) -> [Recipient] {
        recipients.filter { $0.channelName == channel }
    }
    /// 在同一渠道的子序列内移动一位；其他渠道成员的相对位置保持不变
    static func moved(_ recipients: [Recipient], id: String, offset: Int) -> [Recipient] {
        guard offset != 0, let index = recipients.firstIndex(where: { $0.id == id }) else { return recipients }
        let peers = recipients.indices.filter { recipients[$0].channelName == recipients[index].channelName }
        guard let pos = peers.firstIndex(of: index), peers.indices.contains(pos + offset) else { return recipients }
        var result = recipients
        result.swapAt(peers[pos], peers[pos + offset])
        return result
    }
}

// MARK: - 会员纯逻辑（与 License.swift 的网络/钥匙串分层；CoreTests 只编译本文件）

/// 售卖套餐。服务端返回 snake_case，解码时做兼容（key 兼容集中在此处）。
struct PlanInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let days: Int
    let priceFen: Int
    let tagline: String

    init(id: String, name: String, days: Int, priceFen: Int, tagline: String) {
        self.id = id; self.name = name; self.days = days; self.priceFen = priceFen; self.tagline = tagline
    }

    var priceDisplay: String { priceFen % 100 == 0 ? "¥\(priceFen / 100)" : String(format: "¥%.2f", Double(priceFen) / 100) }

    private enum Schema: String, CodingKey {
        case id, name, days, tagline
        case priceFen = "priceFen", priceFenSnake = "price_fen"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Schema.self)
        func text(_ key: Schema) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func int(_ key: Schema) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil }
        id = text(.id) ?? UUID().uuidString
        name = text(.name) ?? ""
        tagline = text(.tagline) ?? ""
        days = int(.days) ?? 30
        priceFen = int(.priceFenSnake) ?? int(.priceFen) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Schema.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(days, forKey: .days)
        try c.encode(priceFen, forKey: .priceFenSnake)
        try c.encode(tagline, forKey: .tagline)
    }
}

/// 服务端不可达时的内置兜底套餐
enum PlanCatalog {
    static let fallback: [PlanInfo] = [
        PlanInfo(id: "monthly",   name: "月卡", days: 30,  priceFen: 990,  tagline: "当前优惠价 · 30 天会员"),
        PlanInfo(id: "quarterly", name: "季卡", days: 90,  priceFen: 2690,  tagline: "季度批量，折合每月更省"),
        PlanInfo(id: "yearly",    name: "年卡", days: 365, priceFen: 9900, tagline: "全年省心，长期首选"),
    ]
}

/// 会员档案。服务端字段是 snake_case、日期是 ISO8601；本地 Settings 存取也走同一套编解码。
///
/// 走查 3-15 新增的服务端权威字段（`expired` / `active` / `membership_state` / `server_time` /
/// `paid_until_utc_iso`，见 `Server/server.py` 的 `_profile`）全部按**可选**解码：
/// 尚未升级的老服务端不给这些键时解出 nil，判定逻辑退回今天的历史口径，绝不因缺字段而解码失败或误判过期。
struct MembershipProfile: Codable, Equatable {
    var account: String
    var planLabel: String
    var paidUntil: Date?
    var daysLeft: Int?
    var source: String   // trial / paid
    /// 服务端明确回答"已过期"。nil = 老服务端未回答（此时只能用本地时钟推算）
    var expired: Bool?
    /// 与 `expired` 互斥的服务端口径：`paid_until > server_time`
    var active: Bool?
    /// 字符串口径 `active` / `expired`，仅在两个布尔都缺失时作兜底
    var membershipState: String?
    /// 服务端当前时刻（epoch 秒）。授权判定的时基锚点：本机时钟不得早于它（见 `LicenseState.resolve`）
    var serverTime: Date?
    /// UTC ISO8601 展示串，仅供人工核对，不参与任何判定（不受部署机时区影响）
    var paidUntilUtcIso: String?

    init(account: String, planLabel: String, paidUntil: Date?, daysLeft: Int?, source: String,
         expired: Bool? = nil, active: Bool? = nil, membershipState: String? = nil,
         serverTime: Date? = nil, paidUntilUtcIso: String? = nil) {
        self.account = account; self.planLabel = planLabel; self.paidUntil = paidUntil
        self.daysLeft = daysLeft; self.source = source
        self.expired = expired; self.active = active; self.membershipState = membershipState
        self.serverTime = serverTime; self.paidUntilUtcIso = paidUntilUtcIso
    }

    var isTrial: Bool { source == "trial" }

    /// 服务端是否**明确回答过**已过期（走查 3-15）。三个口径按权威度依次采信：
    /// `expired` → `active` 取反 → `membership_state`；老服务端三者都不给时返回 false，
    /// 判定退回本地 `paidUntil` 推算，绝不因缺字段而判为过期（向后兼容）。
    var serverSaysExpired: Bool {
        if let expired { return expired }
        if let active { return !active }
        if let state = membershipState { return state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "expired" }
        return false
    }

    private enum Schema: String, CodingKey {
        case account, source, expired, active
        case planLabel = "planLabel", planLabelSnake = "plan_label"
        case paidUntil = "paidUntil", paidUntilSnake = "paid_until"
        case daysLeft = "daysLeft", daysLeftSnake = "days_left"
        case membershipState = "membershipState", membershipStateSnake = "membership_state"
        case serverTime = "serverTime", serverTimeSnake = "server_time"
        case paidUntilUtcIso = "paidUntilUtcIso", paidUntilUtcIsoSnake = "paid_until_utc_iso"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Schema.self)
        func text(_ key: Schema) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func int(_ key: Schema) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil }
        func double(_ key: Schema) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil }
        func bool(_ key: Schema) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }
        // 服务端给 epoch 秒、本地落盘给 ISO 串：两种写法都吃，坏类型一律当"未提供"（不因脏字段解码失败）
        func date(_ snake: Schema, _ camel: Schema) -> Date? {
            if let raw = text(snake) ?? text(camel), let parsed = Self.parseDate(raw) { return parsed }
            if let n = double(snake) ?? double(camel), n > 0 { return Date(timeIntervalSince1970: n) }
            return nil
        }
        account = text(.account) ?? ""
        planLabel = text(.planLabelSnake) ?? text(.planLabel) ?? ""
        source = text(.source) ?? ""
        if let raw = text(.paidUntilSnake) ?? text(.paidUntil) { paidUntil = Self.parseDate(raw) }
        else if let n = double(.paidUntilSnake) ?? double(.paidUntil), n > 0 {
            // 服务端 paid_until 是 Unix 秒；0 表示未开通。本地 Settings 落盘走上面的 ISO 字符串
            paidUntil = Date(timeIntervalSince1970: n)
        }
        else { paidUntil = nil }
        daysLeft = int(.daysLeftSnake) ?? int(.daysLeft)
        if daysLeft == nil, let s = text(.daysLeftSnake) ?? text(.daysLeft) { daysLeft = Int(s) }
        // ---- 本轮新增（服务端 `_profile` 只增字段，老服务端缺省时全部为 nil） ----
        expired = bool(.expired)
        active = bool(.active)
        membershipState = text(.membershipStateSnake) ?? text(.membershipState)
        serverTime = date(.serverTimeSnake, .serverTime)
        paidUntilUtcIso = text(.paidUntilUtcIsoSnake) ?? text(.paidUntilUtcIso)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Schema.self)
        try c.encode(account, forKey: .account)
        try c.encode(planLabel, forKey: .planLabelSnake)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(paidUntil.map { Self.formatDate($0) }, forKey: .paidUntilSnake)
        try c.encodeIfPresent(daysLeft, forKey: .daysLeftSnake)
        // 权威结论与时基锚点随档案一起落盘，重启后离线判定仍能识破"把时钟拨回去"
        try c.encodeIfPresent(expired, forKey: .expired)
        try c.encodeIfPresent(active, forKey: .active)
        try c.encodeIfPresent(membershipState, forKey: .membershipStateSnake)
        try c.encodeIfPresent(serverTime.map { Self.formatDate($0) }, forKey: .serverTimeSnake)
        try c.encodeIfPresent(paidUntilUtcIso, forKey: .paidUntilUtcIsoSnake)
    }

    static func formatDate(_ date: Date) -> String { iso.string(from: date) }
    static func parseDate(_ raw: String) -> Date? {
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        return iso.date(from: normalized) ?? isoFraction.date(from: normalized)
    }
    private static let iso = ISO8601DateFormatter()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

/// 续期计算：从 max(now, 当前到期日) 起加天数
enum MembershipMath {
    static func extend(from current: Date?, now: Date, days: Int) -> Date {
        max(now, current ?? .distantPast).addingTimeInterval(Double(days) * 86400)
    }
}

/// 会员四态；resolve 是离线判定的唯一入口
enum LicenseState: Equatable {
    case loggedOut
    case active(MembershipProfile)
    case grace(MembershipProfile)              // 已到期但仍在服务器校验宽限期（72h）
    case expired(MembershipProfile?)           // 过期且宽限期已过

    static func resolve(profile: MembershipProfile?, now: Date, lastValidated: Date?, graceHours: Int = 72,
                        lastServerTime: Date? = nil) -> LicenseState {
        guard let profile else { return .loggedOut }
        // 走查 3-15：宽限期只覆盖「联系不上服务器」的离线容错。服务器明确回答已过期时直接落 expired，
        // 不再看 lastValidated——否则每次联网成功都把宽限起点充满，过期账号靠每 72 小时联一次网永久放行。
        if profile.serverSaysExpired { return .expired(profile) }
        // 走查 3-15：时基不信任本机时钟。本机时钟早于上次服务端时间即说明被拨回，以锚点为下限，
        // 使 `paidUntil > now` 不能靠拨时钟成立，宽限期的经过时间也不能被倒推成 0。
        let floor = timeFloor(now: now, lastServerTime: lastServerTime)
        if let until = profile.paidUntil, until > floor { return .active(profile) }
        if let last = lastValidated, floor.timeIntervalSince(last) < Double(graceHours) * 3600 { return .grace(profile) }
        return .expired(profile)
    }

    /// 走查 3-15：判定用的「当前时间下限」= 本机时钟与单调服务端锚点取较大者。
    /// 锚点缺省（老服务端从未给过 `server_time`、旧库未升级）时等于 `now`，判定与今天逐字一致。
    static func timeFloor(now: Date, lastServerTime: Date?) -> Date {
        guard let anchor = lastServerTime, anchor.timeIntervalSince1970 > 0 else { return now }
        return max(now, anchor)
    }

    /// 服务器这次是否**确认这个人仍然有效**（走查 3-15；自 `Sources/App.swift` 的补丁扩展迁入 Core，
    /// 与 `resolve` 同一处判定口径，可被 `Tests/CoreTests.swift` 离线覆盖）。
    ///
    /// `/api/me` 对已过期账号同样返回 200 + 完整档案（`Server/server.py` 的 `_profile`：
    /// `expired = not (paid_until > server_time)`，状态码不变以兼容旧客户端），所以「请求成功」
    /// 不能当成「校验通过」。调用点据此决定是否刷新宽限计时点：
    /// 1. 服务端**明确回答过期**（`expired` / `active` / `membership_state` 任一说过期）→ 一律 false，
    ///    不看本机时钟，也不做本地推算；
    /// 2. 老服务端从未回答（三个字段都缺省）→ 退回本地推算，但时基取 `max(now, lastServerTime)`，
    ///    本机时钟被拨回时 `paidUntil > now` 不再能单独成立。
    ///
    /// 两个方向不对称：本机时钟**提前**可能把仍在期的档案判为未通过（偏安全，与今天一致）；
    /// 本机时钟**落后**不再能把过期档案算成通过——这正是本轮闭合的缺口。
    static func serverConfirmedValid(_ profile: MembershipProfile?, now: Date = Date(), lastServerTime: Date? = nil) -> Bool {
        guard let profile, let until = profile.paidUntil else { return false }
        if profile.serverSaysExpired { return false }
        return until > timeFloor(now: now, lastServerTime: lastServerTime)
    }

    var profile: MembershipProfile? {
        switch self {
        case .loggedOut: return nil
        case .active(let p), .grace(let p): return p
        case .expired(let p): return p
        }
    }

    var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }
}
