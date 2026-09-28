import Foundation
import CoreGraphics
import SQLite3
import CryptoKit

struct AppError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ s: String) { message = s } }
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
    /// 输入区里出现过的 DOM 类名；粘贴后新出现的类名才是定位图片节点的唯一线索。
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
/// 图片是否进了草稿的正向信号。只接受三类语义证据，任何一类都不许靠“节点变多了”推断：
/// ①输入框子树里的 AXImage / U+FFFC 占位符；②输入区里非工具栏的 AXImage；
/// ③正文逐字未变而 AXNumberOfCharacters 变多（ProseMirror 的内联原子节点会占一个字符位），
/// 或粘贴后新出现的 class 名字本身就指向图片。
enum ComposerImageSignal {
    static let imageTokens: [String] = ["image", "img", "photo", "picture", "media", "attach"]
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
    /// 恒定 false：任何核验结果都不解锁第二次发送指令。
    static let allowsSecondTrigger = false
    /// 如实交代这次实际发出过哪条发送指令，写进待核对记录里供人工判断。
    static func describe(attempted: [SendTrigger]) -> String {
        let names: [SendTrigger: String] = [.sendButton: "QQ 发送按钮", .returnKey: "Return"]
        return attempted.isEmpty ? "未触发任何发送指令" : attempted.compactMap { names[$0] }.joined(separator: "、")
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
    static func blocker(at point: CGPoint, windows: [Window], targetPID: Int32, selfPID: Int32, selfName: String) -> String? {
        for window in windows {
            guard window.alpha > 0.01, window.layer == 0, window.bounds.width > 1, window.bounds.height > 1, window.bounds.contains(point) else { continue }
            if window.ownerPID == targetPID { return nil }
            if window.ownerPID == selfPID { return selfName }
            if window.regular || (window.bounds.width > 40 && window.bounds.height > 40) {
                return window.name.isEmpty ? "其他应用" : window.name
            }
        }
        return nil
    }
}

/// 从一条搜索结果里读出应绑定的会话名。查询词只用来在同一行里挑标题，不作为能否进入会话的门槛。
enum ConversationMatch {
    static let badges: Set<String> = ["群聊", "好友", "聊天记录", "文件", "来自", "综合", "联系人", "群成员", "发消息", "加入", "已加入", "消息列表"]
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
    static func headerMatches(candidates: [String], title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !badges.contains(title) else { return false }
        return candidates.contains { raw in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return label == title || (title.count >= 4 && label.contains(title))
        }
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
    static func composerBelongs(to title: String, description: String) -> Bool {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !t.isEmpty else { return false }
        return headerMatches(candidates: [d], title: t)
    }
}

enum SendChannel {
    static let qq = "qq"
    static let wechat = "wechat"
    static func name(_ c: String?) -> String { c ?? qq }
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
}
struct Delivery: Codable, Identifiable {
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
    var channel: String? = nil   // qq / wechat；从收件人快照继承
    var recipientID: String? = nil
    /// 一次性任务（人工补草稿）：不参与排期派发，只有人点它时才跑
    var oneOff: Bool? = nil
    /// 由哪条任务派生出来，用来挡住同一来源重复开单
    var cloneOf: String? = nil
    var isOneOff: Bool { oneOff == true }
    var canRenameRecipient: Bool { ["queued", "blocked"].contains(status) && submittedAt == nil && evidence.isEmpty }
    var canRequeue: Bool { status == "blocked" && submittedAt == nil && evidence.isEmpty }
    var attentionReason: String? {
        guard ["draft", "uncertain", "blocked", "submitted"].contains(status) else { return nil }
        let lines = detail.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A step describes where execution stopped; the next line describes why.
        let reason = lines.first(where: { !$0.hasPrefix("步骤：") }) ?? lines.first
        return reason.map { $0.hasPrefix("步骤：") ? String($0.dropFirst(3)) : $0 }
    }
    var channelName: String { SendChannel.name(channel) }
    var statusName: String { ["queued":"待执行", "running":"正在处理", "draft":"草稿待确认", "submitted":"已提交 · 待核验", "verified":"界面已核验", "uncertain":"结果待核对", "blocked":"已暂停", "cancelled":"已取消", "manual":"人工确认已发送" ][status] ?? status }
}
struct TextTemplate: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var text: String
    // 图文模板：记录与文案配套的素材；nil 表示旧模板或尚未启用配图同步（解码旧库自动为 nil）
    var assetIDs: [String]? = nil
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
    var restorePreviousApp: Bool?
    var textTemplates: [TextTemplate]?
    var preferredRecipientIDs: [String]?
    var preferredAssetIDs: [String]?
    var broadcastWorkspaces: [BroadcastWorkspace]?
    var activeWorkspaceID: String?
    // 会员体系（可选字段，旧库缺省兼容）
    var licenseProfile: MembershipProfile?
    var licenseLastValidated: Date?
    var licenseServerURL: String?
}
extension Settings {
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
            let templates = value.settings.broadcastWorkspaces?.first { $0.id == (plan.workspaceID ?? "legacy") }?.templates ?? []
            let matches = templates.filter { $0.text == plan.text }
            if matches.count == 1 { value.plans[i].textTemplateID = matches[0].id }
            else if templates.count == 1 { value.plans[i].textTemplateID = templates[0].id }
        }
        return value
    }
    static func refreshed(_ input: Archive) -> Archive {
        var value = linked(input)
        for i in value.plans.indices {
            let plan = value.plans[i]
            guard let workspace = value.settings.broadcastWorkspaces?.first(where: { $0.id == (plan.workspaceID ?? "legacy") }) else { continue }
            guard let source = workspace.templates.first(where: { $0.id == plan.textTemplateID }) else { continue }
            value.plans[i].text = source.text
            // 图文同步：模板携带配图列表时，把计划与未发送任务的附件快照一并刷新，
            // 保证「编辑草稿 → 保存并同步」后图片和文字一样跟随草稿；已尝试过的记录不动
            if let templateAssets = source.assetIDs {
                let resolved = templateAssets.compactMap { id in value.assets.first { $0.id == id } }
                value.plans[i].assetIDs = resolved.map(\.id)
                for j in value.deliveries.indices where value.deliveries[j].planID == plan.id {
                    let job = value.deliveries[j]
                    if (job.status == "queued" || job.canRequeue) && job.submittedAt == nil && job.evidence.isEmpty {
                        value.deliveries[j].assets = resolved
                    }
                }
            }
            for j in value.deliveries.indices where value.deliveries[j].planID == plan.id {
                let job = value.deliveries[j]
                if (job.status == "queued" || job.canRequeue) && job.submittedAt == nil && job.evidence.isEmpty {
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
        guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite3").path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppError("无法打开本地数据库") }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        for t in ["recipients", "assets", "plans", "deliveries", "settings"] { try exec("CREATE TABLE IF NOT EXISTS \(t) (id TEXT PRIMARY KEY, payload BLOB NOT NULL)") }
        try exec("PRAGMA user_version=1")
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError(String(cString: sqlite3_errmsg(db))) }
    }
    func load<T: Decodable>(_ table: String, as: T.Type) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK else { throw AppError("数据库读取失败") }
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard let bytes = sqlite3_column_blob(stmt, 0) else { throw AppError("数据记录为空") }
            result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: count)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw AppError("数据库读取不完整") }
        return result
    }
    func save(_ archive: Archive) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try replace("recipients", archive.recipients.map { ($0.id, try JSONEncoder().encode($0)) })
            try replace("assets", archive.assets.map { ($0.id, try JSONEncoder().encode($0)) })
            try replace("plans", archive.plans.map { ($0.id, try JSONEncoder().encode($0)) })
            try replace("deliveries", archive.deliveries.map { ($0.id, try JSONEncoder().encode($0)) })
            try replace("settings", [("main", try JSONEncoder().encode(archive.settings))])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func replace(_ table: String, _ rows: [(String, Data)]) throws {
        try exec("DELETE FROM \(table)")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO \(table)(id,payload) VALUES(?,?)", -1, &stmt, nil) == SQLITE_OK else { throw AppError("数据库写入准备失败") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (id, data) in rows {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw AppError("数据库写入失败") }
        }
    }
    func backup(to folder: URL) throws {
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
    func importAsset(_ url: URL) throws -> Asset {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw AppError("只支持文件，不支持文件夹：\(url.lastPathComponent)") }
        let hash = try Self.digest(url)
        let id = UUID().uuidString
        let relative = "assets/\(id)/\(url.lastPathComponent)"
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: target)
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
    static func expand(_ plan: Plan, recipients: [Recipient], assets: [Asset], now: Date = Date()) throws -> [Delivery] {
        guard ["draft", "automatic"].contains(plan.mode) else { throw AppError("未知发送模式") }
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
        let gaps = plan.recipientIDs.dropFirst().map { plan.recipientGaps?[$0] ?? plan.intervalMinutes }
        let minimumGap = min(plan.intervalMinutes,gaps.min() ?? plan.intervalMinutes)
        var jobs: [Delivery] = []
        var allSlots: [Date] = []
        for day in 0..<plan.days {
            let d = calendar.date(byAdding: .day, value: day, to: plan.starts)!
            let slots: [Date]
            if plan.times.isEmpty { slots = [d] }
            else { slots = try times(plan.times.joined(separator: ",")).map { s in let p = s.split(separator: ":").map { Int($0)! }; return calendar.date(bySettingHour: p[0], minute: p[1], second: 0, of: d)! } }
            allSlots.append(contentsOf:slots)
        }
        var previousEnd: Date?
        for slot in allSlots.sorted() {
                if let previousEnd, slot.timeIntervalSince(previousEnd) < Double(minimumGap * 60) - 1 { throw AppError("轮次有重叠，或下一轮离末群太近。请减少轮次、减少群数或调整间隔") }
                for (index, r) in rs.enumerated() {
                    let date = slot.addingTimeInterval(Double(offsets[index] * 60))
                    guard date >= now.addingTimeInterval(-60) else { throw AppError("计划包含已经过去的时间，请调整开始日期或时间") }
                    jobs.append(Delivery(planID: plan.id, planName: plan.name, recipient: r.name, text: plan.text, assets: selectedAssets, scheduled: date, mode: plan.mode, channel: r.channelName, recipientID: r.id))
                }
                previousEnd = slot.addingTimeInterval(Double((offsets.last ?? 0) * 60))
        }
        jobs.sort { $0.scheduled < $1.scheduled }
        return jobs
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
    /// 一次算出每条任务的最早发送时间。原排期只约束尚未开始的未来任务；
    /// 已发送后的冷却按实际提交时间和当前间隔计算，不继承旧排期的时间差。
    private static func dueDates(_ jobs: [Delivery], gap: Int, intervalByPlan: [String:Int]) -> [String:Date] {
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
        return dues
    }
    static func earliestSendDate(_ job: Delivery, jobs: [Delivery], gap: Int, intervalByPlan: [String:Int] = [:]) -> Date {
        dueDates(jobs, gap: gap, intervalByPlan: intervalByPlan)[job.id] ?? job.scheduled
    }
    static func nextCandidate(_ jobs: [Delivery], gap: Int, planID: String? = nil, intervalByPlan: [String:Int] = [:]) -> Delivery? {
        let dues = dueDates(jobs, gap: gap, intervalByPlan: intervalByPlan)
        return jobs.filter { $0.status == "queued" && !$0.isOneOff && (planID == nil || $0.planID == planID) }.min { left, right in
            let l = dues[left.id] ?? left.scheduled, r = dues[right.id] ?? right.scheduled
            if l != r { return l < r }
            if left.scheduled != right.scheduled { return left.scheduled < right.scheduled }
            return left.id < right.id
        }
    }
    static func eligible(_ jobs: [Delivery], now: Date, gap: Int, planID: String? = nil, intervalByPlan: [String:Int] = [:]) -> Delivery? {
        guard !jobs.contains(where: { ["running", "draft", "submitted", "uncertain"].contains($0.status) }),
              let next = nextCandidate(jobs, gap: gap, planID: planID, intervalByPlan: intervalByPlan),
              earliestSendDate(next, jobs: jobs, gap: gap, intervalByPlan: intervalByPlan) <= now else { return nil }
        return next
    }
    /// Explicit manual restart begins a new cadence from the click. Only queued
    /// deliveries are retimed; completed and uncertain records keep their evidence.
    /// 同一来源任务在上一张一次性草稿任务出结果之前，不允许再开第二张。
    static func hasUnresolvedClone(of sourceID: String, in jobs: [Delivery]) -> Bool {
        return jobs.contains { $0.cloneOf == sourceID && ["queued", "running", "draft", "submitted"].contains($0.status) }
    }
    static func restarted(_ jobs: [Delivery], planID: String?, now: Date, gap: Int, intervalByPlan: [String:Int]) -> [Delivery] {
        var result = jobs
        let indices = jobs.indices.filter { jobs[$0].status == "queued" && !jobs[$0].isOneOff && (planID == nil || jobs[$0].planID == planID) }
            .sorted { jobs[$0].scheduled == jobs[$1].scheduled ? jobs[$0].id < jobs[$1].id : jobs[$0].scheduled < jobs[$1].scheduled }
        var next = now
        for index in indices {
            result[index].scheduled = next
            let minutes = max(gap, intervalByPlan[jobs[index].planID] ?? gap)
            next = next.addingTimeInterval(Double(minutes * 60))
        }
        return result
    }
    static func retimed(_ jobs: [Delivery], planID: String, minutes: Int, now: Date, globalGap: Int, preserveFutureStart: Bool = true) throws -> [Delivery] {
        guard (1...1440).contains(minutes), minutes >= globalGap else { throw AppError("间隔须为1–1440分钟，且不小于全局最小间隔") }
        let indices = jobs.indices.filter { jobs[$0].planID == planID && jobs[$0].status == "queued" }.sorted { jobs[$0].scheduled < jobs[$1].scheduled }
        guard let first = indices.first else { throw AppError("当前计划没有待执行任务") }
        var result = jobs
        var next = max(now, preserveFutureStart ? jobs[first].scheduled : now, (lastSendActivity(jobs) ?? .distantPast).addingTimeInterval(Double(globalGap * 60)), (lastSendActivity(jobs.filter { $0.planID == planID }) ?? .distantPast).addingTimeInterval(Double(minutes * 60)))
        for i in indices { result[i].scheduled = next; next = next.addingTimeInterval(Double(minutes * 60)) }
        return result
    }
    static func requeued(_ jobs: [Delivery], ids: Set<String>, now: Date, gap: Int) -> [Delivery] {
        var next = max(now, (lastSendActivity(jobs) ?? .distantPast).addingTimeInterval(Double(gap * 60)))
        var result = jobs
        for i in result.indices.sorted(by: { result[$0].scheduled < result[$1].scheduled }) where ids.contains(result[i].id) && result[i].canRequeue {
            let oldReason = result[i].detail
            result[i].status = "queued"
            result[i].scheduled = next
            result[i].started = nil; result[i].finished = nil
            result[i].detail = "手动重新入队；上次暂停：" + oldReason
            next = next.addingTimeInterval(Double(max(1, gap) * 60))
        }
        return result
    }

    /// Add one delivery per new recipient to the end of this plan, retaining its message snapshot.
    static func additionalDeliveries(plan: Plan, recipients: [Recipient], jobs: [Delivery], now: Date, gap: Int) throws -> [Delivery] {
        let existing = jobs.filter { $0.planID == plan.id }
        guard let template = existing.sorted(by: { $0.scheduled < $1.scheduled }).last else { throw AppError("计划没有可沿用的发送内容，请新建计划") }
        var names = Set(existing.map { $0.channelName + "\u{0}" + $0.recipient })
        var ids = Set(plan.recipientIDs)
        var next = max(now, existing.map(\.scheduled).max() ?? now)
        let interval = Double(max(1, max(gap, plan.intervalMinutes)) * 60)
        var added: [Delivery] = []
        for recipient in recipients where !ids.contains(recipient.id) {
            let key = recipient.channelName + "\u{0}" + recipient.name
            guard names.insert(key).inserted else { continue }
            ids.insert(recipient.id)
            next = next.addingTimeInterval(interval)
            var job = template
            job.text = plan.text
            job.id = UUID().uuidString; job.recipientID = recipient.id; job.recipient = recipient.name; job.channel = recipient.channelName
            job.scheduled = next; job.status = "queued"; job.detail = "手动追加到本计划，等待执行"
            job.started = nil; job.submittedAt = nil; job.finished = nil; job.evidence = ""
            added.append(job)
        }
        return added
    }

    static func recovered(_ jobs: [Delivery]) -> [Delivery] {
        jobs.map { original in
            var job = original
            // Only the retired deadline guard is safe to recover automatically.
            // No driver ran, no draft was filled and no submission was attempted.
            if job.status == "blocked", job.started == nil, job.submittedAt == nil, job.evidence.isEmpty,
               job.detail == "已错过计划时间超过 15 分钟，不集中补发。请点击重新排期" {
                job.status = "queued"
                job.finished = nil
                job.detail = "旧版超时暂停已恢复；等待手动启动，按全局间隔执行"
            }
            if ["running", "submitted"].contains(job.status) { job.status = "uncertain"; job.detail = "上次程序在处理期间退出，请核对 QQ 后人工确认，不自动重试" }
            return job
        }
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
struct MembershipProfile: Codable, Equatable {
    var account: String
    var planLabel: String
    var paidUntil: Date?
    var daysLeft: Int?
    var source: String   // trial / paid

    init(account: String, planLabel: String, paidUntil: Date?, daysLeft: Int?, source: String) {
        self.account = account; self.planLabel = planLabel; self.paidUntil = paidUntil
        self.daysLeft = daysLeft; self.source = source
    }

    var isTrial: Bool { source == "trial" }

    private enum Schema: String, CodingKey {
        case account, source
        case planLabel = "planLabel", planLabelSnake = "plan_label"
        case paidUntil = "paidUntil", paidUntilSnake = "paid_until"
        case daysLeft = "daysLeft", daysLeftSnake = "days_left"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Schema.self)
        func text(_ key: Schema) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func int(_ key: Schema) -> Int? { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil }
        func double(_ key: Schema) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil }
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Schema.self)
        try c.encode(account, forKey: .account)
        try c.encode(planLabel, forKey: .planLabelSnake)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(paidUntil.map { Self.formatDate($0) }, forKey: .paidUntilSnake)
        try c.encodeIfPresent(daysLeft, forKey: .daysLeftSnake)
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

    static func resolve(profile: MembershipProfile?, now: Date, lastValidated: Date?, graceHours: Int = 72) -> LicenseState {
        guard let profile else { return .loggedOut }
        if let until = profile.paidUntil, until > now { return .active(profile) }
        if let last = lastValidated, now.timeIntervalSince(last) < Double(graceHours) * 3600 { return .grace(profile) }
        return .expired(profile)
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
