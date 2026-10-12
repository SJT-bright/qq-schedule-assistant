import Foundation
import SQLite3

@main
struct CoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws { guard condition else { throw AppError("FAIL: \(name)") }; passed += 1; print("PASS: \(name)") }
    static func rejects(_ name: String, _ body: () throws -> Void) throws { do { try body() } catch { passed += 1; print("PASS: \(name)"); return }; throw AppError("FAIL: \(name) unexpectedly succeeded") }
    /// 用独立 sqlite3 连接读 deliveries 表的 id → rowid 映射，用于验证差量写入不再整表 DELETE+INSERT。
    static func deliveryRowids(at root: URL) throws -> [String: Int64] {
        var raw: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("library.sqlite3").path, &raw) == SQLITE_OK else { throw AppError("测试无法打开数据库") }
        sqlite3_busy_timeout(raw, 5000)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, "SELECT id, rowid FROM deliveries", -1, &stmt, nil) == SQLITE_OK else { throw AppError("测试无法查询 rowid") }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[String(cString: sqlite3_column_text(stmt, 0))] = sqlite3_column_int64(stmt, 1)
        }
        return result
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qqdispatch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try check(PostSendNotice.kind(label: "撤回了一条成员消息", systemNotice: true) == .recall, "管理员撤回成员消息仅作为待观察提示")
        try check(PostSendNotice.kind(label: "你撤回了一条消息", systemNotice: true) == .ownRecall, "本人撤回必须暂停")
        try check(PostSendNotice.kind(label: "你的消息被管理员撤回", systemNotice: true) == .ownRecall, "本人的消息被撤回必须暂停")
        try check(PostSendNotice.kind(label: "讨论撤回、禁言和发送失败的处理", systemNotice: false) == nil, "聊天正文的关键词不得当作系统错误")
        try check(PostSendNotice.kind(label: "你已被禁言", systemNotice: true) == .failure, "系统禁言必须暂停")
        try check(PostSendNotice.kind(label: "发送失败", systemNotice: false, errorControl: true) == .failure, "独立发送失败控件仍阻止成功")
        try check(PostSendNotice.kind(label: "发送失败", systemNotice: false) == nil, "普通消息即使只有发送失败四字也不当作错误控件")
        try check(PostSendNotice.added(before: ["撤回"], current: ["撤回", "撤回"]) == ["撤回"], "相同文字的新提示不被历史提示遮蔽")
        try check(PostSendNotice.added(before: ["撤回", "撤回"], current: ["撤回"]).isEmpty, "旧提示减少不算新增异常")
        let ownSentProof = OwnMessageProof(id: "new", textMatches: true, images: 1)
        try check(OwnMessageProof.candidate(in: [ownSentProof], beforeIDs: [], requiredImages: 1) == "new", "新增本人消息必须同条正文和图片齐全")
        try check(OwnMessageProof.candidate(in: [ownSentProof], beforeIDs: ["new"], requiredImages: 1) == nil, "历史本人图文不能核验本次发送")
        try check(OwnMessageProof.candidate(in: [OwnMessageProof(id: "new", textMatches: false, images: 1)], beforeIDs: [], requiredImages: 1) == nil, "正文不同不能用本人图片判成功")
        try check(OwnMessageProof.candidate(in: [OwnMessageProof(id: "new", textMatches: true, images: 0)], beforeIDs: [], requiredImages: 1) == nil, "本人正文缺图不能判成功")
        try check(OwnMessageProof.candidate(in: [OwnMessageProof(id: "", textMatches: true, images: 1)], beforeIDs: [], requiredImages: 1) == nil, "没有稳定消息ID时不接受替代证据")
        try check(OwnMessageProof.acceptsStaleLabel(sameEditor: true, draftCleared: true, messageID: "new"), "原输入框清空且新增本人图文齐全才接受旧标注")
        try check(!OwnMessageProof.acceptsStaleLabel(sameEditor: false, draftCleared: true, messageID: "new"), "不同输入框仍不得借新消息判成功")
        try check(!OwnMessageProof.acceptsStaleLabel(sameEditor: true, draftCleared: false, messageID: "new"), "草稿尚在不能借新消息判成功")
        try check(!OwnMessageProof.acceptsStaleLabel(sameEditor: true, draftCleared: true, messageID: nil), "没有新增本人消息不能忽略标注错误")
        do {
            func own(_ id: String, matches: Bool = true, images: Int = 1) -> OwnMessageProof {
                OwnMessageProof(id: id, textMatches: matches, images: images)
            }
            let before = QQMessageSnapshot(rowIDs: ["old", "a", "b", "tail"], ownMessages: [own("old")], atLatest: true)
            func candidate(_ rows: [String], _ messages: [OwnMessageProof], requiredImages: Int = 1, hasText: Bool = true) -> OwnMessageProof? {
                QQMessageSnapshot.candidate(baseline: before, current: QQMessageSnapshot(rowIDs: rows, ownMessages: messages, atLatest: true), requiredImages: requiredImages, hasText: hasText)
            }
            try check(candidate(["old", "a", "b", "tail", "sent"], [own("old"), own("sent")]) == own("sent"), "保留连续旧尾锚且尾后新增本人图文才允许核验")
            try check(candidate(["history", "old", "a", "b", "tail"], [own("history")]) == nil, "历史同文图片插在旧尾锚前不能当新增发送")
            try check(candidate(["old", "a", "b", "tail"], [own("old")]) == nil, "已存在同文本人消息不得作为本次发送")
            try check(candidate(["a", "b", "tail", "old"], [own("old")]) == nil, "基线既有ID即使移到尾后也不能作为本次发送")
            try check(candidate(["a", "tail", "sent"], [own("sent")]) == nil, "虚拟列表丢失尾锚行不能自动核验")
            try check(candidate(["b", "a", "tail", "sent"], [own("sent")]) == nil, "尾锚顺序改变不能自动核验")
            try check(candidate(["a", "history", "b", "tail", "sent"], [own("sent")]) == nil, "旧尾锚之间插入新行不能证明消息连续性")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent")]) == own("sent"), "基线早期历史可被虚拟化但最后三行锚必须保留")
            try check(candidate(["a", "b", "tail", "inbound"], []) == nil, "尾后新增其他成员消息不能证明本人发送")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent", matches: false)]) == nil, "新增本人正文不符不能核验")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent", images: 0)]) == nil, "新增本人缺图不能核验")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent", images: 2)]) == nil, "新增本人多图也不能冒充完整计划")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent")], hasText: false) == nil, "空正文纯图片任务没有内容指纹不能自动核验")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent", images: 0)], requiredImages: 0) == own("sent", images: 0), "有正文的纯文字新增消息可核验")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent")], requiredImages: -1) == nil, "非法计划图片数不能核验")
            try check(candidate(["a", "b", "tail", ""], [own("")]) == nil, "当前消息行空ID不能形成可信快照")
            try check(candidate(["a", "b", "tail", "sent", "sent"], [own("sent")]) == nil, "当前消息行重复ID不能形成可信快照")
            try check(candidate(["a", "b", "tail", "sent"], [own("sent"), own("sent")]) == nil, "重复本人ID不能形成可信快照")
            try check(candidate(["a", "b", "tail", "sent"], [own("missing")]) == nil, "本人消息不属于当前行集合不能形成可信快照")
            try check(!QQMessageSnapshot(rowIDs: [], ownMessages: []).isTrustworthy, "发送前空消息列表不能作为可信基线")
            try check(!QQMessageSnapshot(rowIDs: ["", "tail"], ownMessages: []).isTrustworthy, "发送前任意空行ID拒绝基线")
            try check(!QQMessageSnapshot(rowIDs: ["tail", "tail"], ownMessages: []).isTrustworthy, "发送前重复行ID拒绝基线")
            let shortBefore = QQMessageSnapshot(rowIDs: ["tail"], ownMessages: [], atLatest: true)
            try check(QQMessageSnapshot.candidate(baseline: shortBefore, current: QQMessageSnapshot(rowIDs: ["tail", "sent"], ownMessages: [own("sent")], atLatest: true), requiredImages: 1, hasText: true) == own("sent"), "只有一行的完整基线仍需保留该尾锚")
            try check(candidate(["a", "b", "tail", "sent1", "sent2"], [own("sent2"), own("sent1")]) == own("sent2"), "候选按消息行顺序而非本人数组顺序选择最新消息")
            var unknownPosition = before; unknownPosition.atLatest = false
            let liveCurrent = QQMessageSnapshot(rowIDs: ["old", "a", "b", "tail", "sent"], ownMessages: [own("sent")], atLatest: true)
            try check(QQMessageSnapshot.candidate(baseline: unknownPosition, current: liveCurrent, requiredImages: 1, hasText: true) == nil, "发送前不能证明位于最新消息时拒绝自动核验")
            var unknownCurrent = liveCurrent; unknownCurrent.atLatest = false
            try check(QQMessageSnapshot.candidate(baseline: before, current: unknownCurrent, requiredImages: 1, hasText: true) == nil, "发送后不能证明位于最新消息时拒绝自动核验")
            let loadedHistory = QQMessageSnapshot(rowIDs: ["old", "a", "b", "tail", "later-history"], ownMessages: [own("later-history")])
            try check(QQMessageSnapshot.candidate(baseline: unknownPosition, current: loadedHistory, requiredImages: 1, hasText: true) == nil, "历史向后加载保留尾锚也不能在无最新位置证据时冒充发送")
            let decodedUnknown = try JSONDecoder().decode(QQMessageSnapshot.self, from: Data("{\"rowIDs\":[\"tail\"],\"ownMessages\":[]}".utf8))
            try check(!decodedUnknown.atLatest, "旧快照缺最新位置字段安全回落为未知")

            let submit = Date(timeIntervalSince1970: 1800000000)
            let image = Asset(id: "proof-image", name: "图.png", relativePath: "assets/proof-image/图.png", sha256: "digest", bytes: 1, isImage: true)
            var delivery = Delivery(id: "proof-delivery", planID: "proof-plan", planName: "核验", recipient: "实际第一条群", text: "本次正文", assets: [image], scheduled: submit, mode: "automatic")
            delivery.started = submit.addingTimeInterval(-1); delivery.submittedAt = submit
            let evidence = QQVerificationEvidence(deliveryID: delivery.id, selectedTitle: "实际第一条群", trigger: "Return", submittedAt: submit, firstObservedAt: submit.addingTimeInterval(0.3), confirmedAt: submit.addingTimeInterval(1.3), baselineRowIDs: before.rowIDs, confirmedRowIDs: ["old", "a", "b", "tail", "sent"], messageID: "sent", textMatches: true, images: 1, requiredImages: 1, draftCleared: true, baselineAtLatest: true, confirmedAtLatest: true)
            try check(evidence.isValid(for: delivery), "结构与本次提交时间一致的完整核验依据可通过")
            func invalid(_ name: String, _ mutate: (inout QQVerificationEvidence) -> Void) throws {
                var changed = evidence; mutate(&changed)
                try check(!changed.isValid(for: delivery), name)
            }
            try invalid("图片仍在草稿中不能把任务核验成功") { $0.draftCleared = false }
            try invalid("其他任务核验依据不能用于本任务") { $0.deliveryID = "other-delivery" }
            try invalid("未知核验规则版本不自动成功") { $0.ruleVersion = 3 }
            try invalid("没有实际发送触发方式不能核验") { $0.trigger = " " }
            try invalid("没有实际绑定会话不能核验") { $0.selectedTitle = " " }
            try invalid("核验提交时间早于本次开始不能成功") { $0.submittedAt = submit.addingTimeInterval(-2) }
            try invalid("旧attempt的提交时间不能用于新attempt") { $0.submittedAt = submit.addingTimeInterval(6) }
            try invalid("消息首次出现早于本次提交不能成功") { $0.firstObservedAt = submit.addingTimeInterval(-0.1) }
            try invalid("两次观察不足0.8秒不能作为稳定核验") { $0.confirmedAt = evidence.firstObservedAt.addingTimeInterval(0.79) }
            try invalid("证据内图片数不符计划不能成功") { $0.images = 2 }
            try invalid("伪造计划图片数不能绕过任务附件核对") { $0.requiredImages = 2; $0.images = 2 }
            try invalid("持久化证据里正文未匹配不能成功") { $0.textMatches = false }
            try invalid("持久化证据里历史消息ID不能成功") { $0.messageID = "old" }
            try invalid("持久化证据里尾锚丢失不能成功") { $0.confirmedRowIDs = ["sent"] }
            try invalid("持久化证据缺发送前最新位置依据不能成功") { $0.baselineAtLatest = false }
            try invalid("持久化证据缺确认时最新位置依据不能成功") { $0.confirmedAtLatest = false }
            var noSubmit = delivery; noSubmit.submittedAt = nil
            try check(!evidence.isValid(for: noSubmit), "没有本次提交记录不能使用核验依据")
            var noStart = delivery; noStart.started = nil
            try check(!evidence.isValid(for: noStart), "没有本次开始记录不能使用核验依据")
            var newAttempt = delivery; newAttempt.started = submit.addingTimeInterval(10); newAttempt.submittedAt = submit.addingTimeInterval(11)
            try check(!evidence.isValid(for: newAttempt), "同任务旧attempt证据不得用于新attempt")
            var emptyText = delivery; emptyText.text = " \n\u{200b}\u{fffc}"
            try check(!evidence.isValid(for: emptyText), "不可见正文不能绕过纯图片人工核对")
            delivery.qqVerification = evidence
            let encoded = try JSONEncoder().encode(delivery)
            let decoded = try JSONDecoder().decode(Delivery.self, from: encoded)
            try check(decoded.qqVerification == evidence && decoded.qqVerification?.isValid(for: decoded) == true, "结构核验依据随任务持久化往返保持")
            var oldEvidenceJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as! [String: Any]
            oldEvidenceJSON.removeValue(forKey: "baselineAtLatest"); oldEvidenceJSON.removeValue(forKey: "confirmedAtLatest")
            let oldEvidence = try JSONDecoder().decode(QQVerificationEvidence.self, from: JSONSerialization.data(withJSONObject: oldEvidenceJSON))
            try check(!oldEvidence.baselineAtLatest && !oldEvidence.confirmedAtLatest && !oldEvidence.isValid(for: delivery), "旧结构核验缺位置字段可读取但不能自动通过")
        }
        do {
            let submitted = Date(timeIntervalSince1970: 1791534187.818116)
            let observed = Date(timeIntervalSince1970: 1791534191)
            let id = "7768797790718044784"
            let message = OwnMessageProof(id: id, textMatches: true, images: 1, phase: .quiet, timeLabel: "16:23", timezoneOffset: 28800)
            let before = QQMessageSnapshot(rowIDs: ["a", "b", "tail"], ownMessages: [])
            let current = QQMessageSnapshot(rowIDs: ["a", "b", "tail", id], ownMessages: [message])
            func fresh(_ proof: OwnMessageProof = message, _ version: String = QQMessageClock.supportedVersion,
                       submit: Date = submitted, observe: Date = observed) -> OwnMessageProof? {
                var snapshot = current; snapshot.ownMessages = [proof]
                return QQMessageSnapshot.freshCandidate(baseline: before, current: snapshot, requiredImages: 1,
                    hasText: true, submittedAt: submit, observedAt: observe, version: version)
            }
            try check(QQMessageClock.creation(id) == Date(timeIntervalSince1970: 1791534190), "现场本人ID创建秒数与16:23时间节点交叉匹配")
            try check(fresh() == message, "缺滚动条时本次创建的单一本人图文与行内时间形成兼容凭据")
            for phase in [QQSendPhase.pending, .failed, .unknown] {
                var p = message; p.phase = phase
                try check(fresh(p) == nil, "\(phase.rawValue)发送状态不允许完成")
            }
            var missingTime = message; missingTime.timeLabel = nil
            try check(fresh(missingTime) == nil, "缺专用行内时间标签不得搜索正文替代")
            var wrongTime = message; wrongTime.timeLabel = "16:22"
            try check(fresh(wrongTime) == nil, "行内时刻与消息ID解码不一致拒绝")
            var missingZone = message; missingZone.timezoneOffset = nil
            try check(fresh(missingZone) == nil, "缺观察时区不得生成兼容凭据")
            for offset in [Int.min, Int.max, -50401, 50401] {
                var malformed = message; malformed.timezoneOffset = offset
                try check(fresh(malformed) == nil, "异常时区极值拒绝且不崩溃：\(offset)")
            }
            let unknownPhaseJSON = Data("{\"id\":\"x\",\"textMatches\":true,\"images\":1,\"phase\":\"future-phase\"}".utf8)
            let unknownPhase = try JSONDecoder().decode(OwnMessageProof.self, from: unknownPhaseJSON)
            try check(unknownPhase.phase == .unknown, "未知状态保留原任务数据并回落unknown，不能丢记录")
            try check(fresh(message, "7.0.3-53644") == nil && fresh(message, "7.0.2-53645") == nil, "未知QQ版本及build不套用实证时间规则")
            try check(fresh(submit: Date(timeIntervalSince1970: 1791534190)) == nil, "同秒消息不能凭秒级时间推断在提交之后创建")
            try check(fresh(observe: Date(timeIntervalSince1970: 1791534189)) == nil, "异常未来创建秒数不能通过")
            var old = message; old.id = String((UInt64(1791534190 - 86400 + 17280000) << 32) | 1)
            var oldCurrent = current; oldCurrent.rowIDs[3] = old.id; oldCurrent.ownMessages = [old]
            try check(QQMessageSnapshot.freshCandidate(baseline: before, current: oldCurrent, requiredImages: 1, hasText: true,
                submittedAt: submitted, observedAt: observed, version: QQMessageClock.supportedVersion) == nil,
                "昨天同HH:mm同图文向后加载也不能冒充本次发送")
            var inbound = message; inbound.id = "7694581013887734274"
            try check(!QQMessageClock.isFresh(inbound, submittedAt: submitted, observedAt: observed, version: QQMessageClock.supportedVersion), "收到他人的ID不被本人的200天格式误认为当前发送")
            for id in ["", "123", "+7768797790718044784", "776879779071804478４", "999999999999999999999", "abcdefghijklmnopqrs"] {
                try check(QQMessageClock.creation(id) == nil, "非法ID拒绝解码：\(id)")
            }
            let secondID = String((UInt64(1791534190 + 17280000) << 32) | 2)
            var duplicate = message; duplicate.id = secondID
            var ambiguous = current; ambiguous.rowIDs.append(secondID); ambiguous.ownMessages.append(duplicate)
            try check(QQMessageSnapshot.freshCandidate(baseline: before, current: ambiguous, requiredImages: 1, hasText: true,
                submittedAt: submitted, observedAt: observed, version: QQMessageClock.supportedVersion) == nil,
                "同一提交时间窗口两个同文本人候选拒绝歧义")
            var missingAnchor = current; missingAnchor.rowIDs.removeFirst()
            try check(QQMessageSnapshot.freshCandidate(baseline: before, current: missingAnchor, requiredImages: 1, hasText: true,
                submittedAt: submitted, observedAt: observed, version: QQMessageClock.supportedVersion) == nil,
                "创建时间正证据仍不能跳过连续旧尾锚")
            for p in [OwnMessageProof(id: id, textMatches: false, images: 1, phase: .quiet, timeLabel: "16:23", timezoneOffset: 28800),
                      OwnMessageProof(id: id, textMatches: true, images: 0, phase: .quiet, timeLabel: "16:23", timezoneOffset: 28800)] {
                try check(fresh(p) == nil, "时间新也必须本人正文和计划图片齐全")
            }
            try check(QQSendPhase.read(structured: true, classes: [], controlLabels: [], busy: true, progress: false) == .pending, "消息行busy正在发送不得完成")
            try check(QQSendPhase.read(structured: true, classes: [], controlLabels: [], busy: false, progress: true) == .pending, "消息行进度控件正在发送不得完成")
            try check(QQSendPhase.read(structured: true, classes: ["q-loading"], controlLabels: [], busy: false, progress: false) == .pending, "转圈类正在发送不得完成")
            for token in ["image-upload-progress", "media-loading", "send-status--pending", "msg_uploading"] {
                try check(QQSendPhase.read(structured: true, classes: [token], controlLabels: [], busy: false, progress: false) == .pending,
                    "未知进度类保守等待：\(token)")
            }
            try check(QQSendPhase.read(structured: true, classes: ["msg-fail"], controlLabels: [], busy: true, progress: true) == .failed, "发送失败优先于仍存在的进度")
            try check(QQSendPhase.read(structured: true, classes: [], controlLabels: ["发送失败"], busy: false, progress: false) == .failed, "该本人行失败控件不能完成")
            try check(QQSendPhase.read(structured: true, classes: ["msg-status-new"], controlLabels: [], busy: false, progress: false) == .unknown, "未知状态控件不猜测成功")
            try check(QQSendPhase.read(structured: false, classes: [], controlLabels: [], busy: false, progress: false) == .unknown, "不完整消息结构不把没有转圈解释为成功")
            let asset = Asset(id: "postsend-image", name: "图.png", relativePath: "assets/postsend-image/图.png", sha256: "digest", bytes: 1, isImage: true)
            var job = Delivery(id: "postsend", planID: "plan", planName: "核验", recipient: "群", text: "本次正文", assets: [asset], scheduled: submitted, mode: "automatic")
            job.started = submitted.addingTimeInterval(-5); job.submittedAt = submitted
            var evidence = QQVerificationEvidence(ruleVersion: 2, deliveryID: job.id, selectedTitle: "群", trigger: "Return", submittedAt: submitted,
                firstObservedAt: observed, confirmedAt: observed.addingTimeInterval(1.2), baselineRowIDs: before.rowIDs,
                confirmedRowIDs: current.rowIDs, messageID: id, textMatches: true, images: 1, requiredImages: 1, draftCleared: true,
                qqVersion: QQMessageClock.supportedVersion, messageTimeLabel: "16:23", messageTimezoneOffset: 28800, confirmedPhase: .quiet)
            try check(evidence.isValid(for: job), "QQ-v2缺滚动条的完整凭据可持久化重验")
            let decoded = try JSONDecoder().decode(QQVerificationEvidence.self, from: JSONEncoder().encode(evidence))
            try check(decoded == evidence && decoded.isValid(for: job), "QQ-v2往返保持本次ID时间和原观察时区")
            evidence.messageID = old.id; evidence.confirmedRowIDs[3] = old.id
            try check(!evidence.isValid(for: job), "持久化凭据重新从ID检查时刻，篡改为历史ID不得通过")
            var unknownEvidenceJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
            unknownEvidenceJSON["confirmedPhase"] = "future-phase"
            let unknownEvidence = try JSONDecoder().decode(QQVerificationEvidence.self, from: JSONSerialization.data(withJSONObject: unknownEvidenceJSON))
            try check(unknownEvidence.confirmedPhase == .unknown && !unknownEvidence.isValid(for: job), "未知持久化phase不损失任务且拒绝自动完成")
            var missing = decoded; missing.messageTimezoneOffset = nil
            try check(!missing.isValid(for: job), "旧数据缺v2必须字段能读但不能自动完成")
        }
        try check(FocusRestore.shouldRestore(verified: true, enabled: true, cancelled: false, locked: false, frontBundleID: FocusRestore.qqBundleID, previousBundleID: FocusRestore.schedulerBundleID, targetBundleID: FocusRestore.qqBundleID), "QQ发送核验成功可自动返回排程助手")
        let now = Date(timeIntervalSince1970:1800000000)
        let recipients = (1...8).map{ Recipient(name:"测试群\($0)") }
        let plan = Plan(name:"测试",text:"测试文字",assetIDs:[],recipientIDs:recipients.map(\.id),starts:now.addingTimeInterval(60),days:1,times:[],intervalMinutes:30,mode:"draft")
        let jobs = try Scheduling.expand(plan,recipients:recipients,assets:[],now:now)
        try check(jobs.count == 8,"八群生成八条任务")
        try check(jobs[7].scheduled.timeIntervalSince(jobs[0].scheduled) == 3.5*3600,"每半小时错峰，末群为首群后3.5小时")
        try check(jobs.map(\.recipient) == recipients.map(\.name),"保留名单顺序")
        var renameArchive = Archive(recipients: recipients, assets: [], plans: [plan], deliveries: jobs, settings: Settings(savedText: ""))
        renameArchive.deliveries[0].recipientID = nil // Existing databases have name snapshots only.
        var historical = jobs[0]; historical.id = "history"; historical.status = "verified"; historical.evidence = "receipt"
        renameArchive.deliveries.append(historical)
        var otherChannel = jobs[0]; otherChannel.id = "wechat"; otherChannel.channel = SendChannel.wechat; otherChannel.recipientID = nil
        renameArchive.deliveries.append(otherChannel)
        let resolved = try RecipientRename.resolve(renameArchive.deliveries[0], recipients: recipients)
        let renamed = try RecipientRename.renamed(renameArchive, id: resolved, name: "  正确群名  ")
        try check(renamed.recipients[0].name == "正确群名" && renamed.deliveries[0].recipient == "正确群名", "队列改名同步名单并兼容旧任务")
        try check(renamed.deliveries[0].recipientID == recipients[0].id, "旧任务改名建立稳定关联")
        let renamedAgain = try RecipientRename.renamed(renamed, id: recipients[0].id, name: "再次改名")
        try check(renamedAgain.deliveries[0].recipient == "再次改名", "名单再次改名同步关联任务")
        try check(renamed.deliveries[8].recipient == historical.recipient && renamed.deliveries[8].evidence == "receipt" && renamed.deliveries[9].recipient == otherChannel.recipient, "改名保留历史凭据且不串渠道")
        try check(renamed.deliveries[0].scheduled == jobs[0].scheduled && renamed.deliveries[0].text == jobs[0].text && renamed.deliveries[0].status == jobs[0].status, "改名不改变排期正文与状态")
        try rejects("拒绝空白群名") { _ = try RecipientRename.renamed(renameArchive, id: resolved, name: " ") }
        try rejects("拒绝同渠道重名") { _ = try RecipientRename.renamed(renameArchive, id: resolved, name: recipients[1].name) }
        for status in ["running", "draft", "submitted", "uncertain"] {
            var pending = renameArchive; pending.deliveries[0].status = status
            try rejects("\(status) 任务禁止修改关联群名") { _ = try RecipientRename.renamed(pending, id: resolved, name: "新名") }
        }
        let renameDB = try Database(root: root.appendingPathComponent("rename"))
        try renameDB.save(renamedAgain)
        try check(try renameDB.load("deliveries", as: Delivery.self)[0].recipient == "再次改名" && renameDB.load("recipients", as: Recipient.self)[0].name == "再次改名", "改名同步持久化可重载")
        var sixPlan = plan; sixPlan.recipientIDs = Array(recipients.prefix(6).map(\.id)); sixPlan.mode = "automatic"
        var six = try Scheduling.expand(sixPlan,recipients:recipients,assets:[],now:now)
        try check(six.count == 6 && six[5].scheduled.timeIntervalSince(six[0].scheduled) == 150 * 60,"六群30分钟排期，末群为150分钟后")
        var varied = sixPlan; varied.recipientGaps = [recipients[1].id:60,recipients[3].id:45]
        try check(try Scheduling.offsets(varied) == [0,60,90,135,165,195],"逐群间隔按累计时间生成")
        let variedJobs = try Scheduling.expand(varied,recipients:recipients,assets:[],now:now)
        try check(variedJobs.last!.scheduled.timeIntervalSince(variedJobs.first!.scheduled) == 195*60,"逐群排期总跨度195分钟")
        var fewer = varied; fewer.recipientIDs.remove(at:1)
        try check(try Scheduling.offsets(fewer) == [0,30,75,105,135],"取消群后重新计算跨度，不保留移除群的延迟")
        try rejects("非法逐群间隔拒绝") { var bad = varied; bad.recipientGaps = [recipients[1].id:0]; _ = try Scheduling.offsets(bad) }
        var fullDay = sixPlan; fullDay.starts = Scheduling.calendar.startOfDay(for:now).addingTimeInterval(86400); fullDay.times = stride(from:0,to:24,by:3).map { String(format:"%02d:00",$0) }; fullDay.days = 2
        let fullDayJobs = try Scheduling.expand(fullDay,recipients:recipients,assets:[],now:now)
        try check(fullDayJobs.count == 96,"六群全天八轮两天自动生成96条")
        try check(fullDayJobs.last!.scheduled.timeIntervalSince(fullDayJobs.first!.scheduled) == 47.5*3600,"跨日总跨度47.5小时")
        try rejects("增加群导致全天轮次重叠时拒绝") { var crowded = fullDay; crowded.recipientIDs = recipients.map(\.id); _ = try Scheduling.expand(crowded,recipients:recipients,assets:[],now:now) }
        try check(try Scheduling.times((0..<24).map { String(format:"%02d:00",$0) }.joined(separator:",")).count == 24,"支持24个自定义整点轮次")
        try check(Scheduling.duration(150) == "2 小时 30 分钟" && Scheduling.duration(180) == "3 小时","跨度显示小时与分钟")
        let legacyData = try JSONEncoder().encode(sixPlan)
        try check(try JSONDecoder().decode(Plan.self,from:legacyData).recipientGaps == nil,"旧计划无需逐群字段即可读取")
        let legacySettings = Data("{\"globalGapMinutes\":30,\"savedText\":\"旧文案\"}".utf8)
        try check(try JSONDecoder().decode(Settings.self,from:legacySettings).restorePreviousApp == nil,"旧设置兼容恢复窗口可选字段")
        try check(try JSONDecoder().decode(Settings.self,from:legacySettings).notifyOnOutcome == nil,"旧设置无通知字段解码为 nil 保持开启")
        do {
            var muted = Settings(savedText: "")
            muted.notifyOnOutcome = false
            let roundtrip = try JSONDecoder().decode(Settings.self,from:JSONEncoder().encode(muted))
            try check(roundtrip.notifyOnOutcome == false,"通知开关关闭后编解码保真")
        }
        try check(Settings().notifyOnOutcome == nil,"通知开关默认初始化为 nil")
        let firstTime = six[0].scheduled
        for i in 0..<6 {
            let time = firstTime.addingTimeInterval(Double(i * 1800))
            try check(Scheduling.eligible(six,now:time,gap:30,planID:sixPlan.id)?.id == six[i].id,"六群自动推进第\(i+1)条，无需确认")
            six[i].status = "verified"; six[i].submittedAt = time
        }
        try check(Scheduling.eligible(six,now:firstTime.addingTimeInterval(20000),gap:30,planID:sixPlan.id) == nil,"本计划完成后不重发")
        var foreign = jobs[0]; foreign.planID = "another-plan"; foreign.scheduled = now
        try check(Scheduling.eligible([foreign] + jobs,now:now.addingTimeInterval(61),gap:30,planID:plan.id)?.id == jobs[0].id,"只启动所选计划，不启动其他排期")
        foreign.status = "verified"; foreign.submittedAt = now
        try check(Scheduling.eligible([foreign] + jobs,now:now.addingTimeInterval(61),gap:30,planID:plan.id) == nil,"分计划启动仍遵守其他计划发送冷却")
        var daily = plan; daily.starts = Scheduling.calendar.startOfDay(for:now).addingTimeInterval(86400); daily.days = 2; daily.times = ["09:00","14:00","19:00"]
        let dailyJobs = try Scheduling.expand(daily,recipients:recipients,assets:[],now:now)
        try check(dailyJobs.count == 48,"两天三轮八群=48条")
        try check(Scheduling.calendar.component(.hour,from:dailyJobs[0].scheduled) == 9,"排程采用北京时间")
        try rejects("重叠轮次拒绝") { var p = daily; p.times = ["09:00","10:00"]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("重复轮次拒绝") { _ = try Scheduling.times("09:00,09:00") }
        try rejects("错误时间拒绝") { _ = try Scheduling.times("24:60") }
        try rejects("空时间拒绝") { _ = try Scheduling.times("") }
        try rejects("过去日期不集中补发") { var p = plan; p.starts = now.addingTimeInterval(-1000); _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("空收件人拒绝") { var p = plan; p.recipientIDs=[]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("空内容拒绝") { var p=plan;p.text=" "; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("不存在附件拒绝") { var p=plan;p.assetIDs=["missing"]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("停用收件人拒绝") { var rs=recipients;rs[0].enabled=false;_ = try Scheduling.expand(plan,recipients:rs,assets:[],now:now) }
        try check(Scheduling.eligible(jobs,now:now,gap:30) == nil,"未到时不发送")
        try check(Scheduling.eligible(jobs,now:now.addingTimeInterval(61),gap:30)?.id == jobs[0].id,"到时只选首条")
        var active=jobs;active[0].status="verified";active[0].started=now
        try check(Scheduling.eligible(active,now:now.addingTimeInterval(100),gap:30) == nil,"全局间隔有效")
        var failed = active; failed[0].status = "blocked"
        try check(Scheduling.lastSendActivity(failed) == nil,"提交前控件失败不占用发送冷却")
        failed[0].submittedAt = now
        try check(Scheduling.lastSendActivity(failed) == now,"存在提交检查点时保留冷却")
        failed[0].status = "cancelled"
        try check(Scheduling.lastSendActivity(failed) == now,"取消任务不能清除已提交冷却")
        for status in ["running","draft","submitted","uncertain"] {
            var list = jobs; list[0].status = status
            let candidate = Scheduling.eligible(list, now: now.addingTimeInterval(10000), gap: 30)
            try check(status == "running" ? candidate == nil : candidate?.id == jobs[1].id,
                      status == "running" ? "正在处理时不并发发送" : "\(status) 保留原记录并选择下一条，不自动重试")
        }
        active[0].status="cancelled";active[0].started=nil
        try check(Scheduling.eligible(active,now:now.addingTimeInterval(5000),gap:30)?.id == jobs[1].id,"取消任务不会重发")
        for status in ["running", "submitted"] {
            var list = jobs; list[0].status = status
            let recovered = Scheduling.recovered(list)
            try check(recovered[0].status == "uncertain", "崩溃恢复 \(status) 转待核对")
            try check(Scheduling.eligible(recovered, now: now.addingTimeInterval(10000), gap: 30)?.id == jobs[1].id,
                      "重开后跳过上次\(status)记录，不重发而继续下一群")
        }
        do {
            // 待核对与后续排期独立，仍严格保留提交冷却和不重复发送的边界。
            var current = Array(jobs.prefix(3))
            for index in current.indices {
                current[index].id = "continue-\(index)"
                current[index].scheduled = now.addingTimeInterval(Double(-3600 + index * 60))
                current[index].status = "queued"
                current[index].started = nil; current[index].submittedAt = nil; current[index].evidence = ""
            }
            var history = current[0]
            history.id = "historical-review"; history.planID = "old-plan"; history.status = "uncertain"
            history.started = now.addingTimeInterval(-86401); history.submittedAt = now.addingTimeInterval(-86400)
            history.evidence = "历史提交凭据"
            let mixed = [history] + current
            try check(Scheduling.eligible(mixed, now: now, gap: 30, planID: plan.id)?.id == current[0].id,
                      "其他计划旧待核对不阻止当前计划的第一条待执行")
            try check(mixed[0].status == "uncertain" && mixed[0].evidence == "历史提交凭据",
                      "选择下一群不覆盖历史待核对状态和日志凭据")
            current[0].status = "uncertain"; current[0].submittedAt = now; current[0].evidence = "本次提交尚未核验"
            try check(Scheduling.nextCandidate(current, gap: 30, planID: plan.id)?.id == current[1].id,
                      "当前群结果待核对时跳过原群，下一候选为后续待执行")
            try check(Scheduling.eligible(current, now: now.addingTimeInterval(1799), gap: 30, planID: plan.id) == nil,
                      "跳过需核对群仍保留已经提交后的30分钟冷却")
            try check(Scheduling.eligible(current, now: now.addingTimeInterval(1800), gap: 30, planID: plan.id)?.id == current[1].id,
                      "提交冷却到期后继续下一群，不重发需核对群")
            current[0].status = "queued"
            try check(Scheduling.eligible(current, now: now.addingTimeInterval(1800), gap: 30, planID: plan.id)?.id == current[1].id,
                      "状态异常回到queued但已有提交检查点的群也不会重发")
            current[0].submittedAt = nil
            try check(Scheduling.eligible(current, now: now, gap: 30, planID: plan.id)?.id == current[1].id,
                      "queued仅有凭据仍跳过，不因移除待核对启动闸重发")
            history.submittedAt = now.addingTimeInterval(-60)
            let nextPlan = [history, current[1]]
            let paces = [history.planID: 60, plan.id: 15]
            try check(Scheduling.eligible(nextPlan, now: now.addingTimeInterval(239), gap: 5, planID: plan.id, intervalByPlan: paces) == nil,
                      "其他计划待核对的最近提交仍约束下一计划的全局冷却")
            try check(Scheduling.eligible(nextPlan, now: now.addingTimeInterval(240), gap: 5, planID: plan.id, intervalByPlan: paces)?.id == current[1].id,
                      "跨计划全局冷却到期可发送，不继承旧计划60分钟间隔")
        }
        var wechatCrash = jobs; wechatCrash[0].status = "running"; wechatCrash[0].channel = SendChannel.wechat
        wechatCrash[0].detail = "步骤：已按 Return，等待 QQ 发送\n核验超时，草稿仍在"
        try check(Scheduling.recovered(wechatCrash)[0].detail == SendChannel.crashRecoveryDetail(channel: SendChannel.wechat, previous: wechatCrash[0].detail), "微信任务崩溃恢复的说明指向微信")
        try check(Scheduling.recovered(wechatCrash)[0].detail.contains("核验超时，草稿仍在"), "崩溃恢复把新说明追加在原记录后，不覆盖上次卡在哪一步（走查 1-08）")
        try check(Scheduling.recovered(wechatCrash)[0].detail.contains("上次程序在处理期间退出"), "崩溃恢复仍写清代查原因，不只留下旧文案")
        try check(Scheduling.recovered(Scheduling.recovered(wechatCrash))[0].detail == Scheduling.recovered(wechatCrash)[0].detail, "重复启动不会反复堆叠崩溃恢复说明")
        try rejects("未知模式拒绝") { var p=plan;p.mode="invalid"; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try check(ComposerContent.isEmpty("\n",descendants:[]),"QQ 空换行属于空草稿")
        try check(ComposerContent.isEmpty("\u{200b}\n",descendants:[ComposerNode(role:"AXGroup"),ComposerNode(role:"AXStaticText",value:"\n")]),"空白段落节点不误判草稿")
        try check(!ComposerContent.isEmpty("正文",descendants:[]),"已有文字必须保留")
        try check(!ComposerContent.isEmpty("\u{fffc}",descendants:[]),"附件占位符不能当成空内容")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXImage")]),"图片节点不能当成空内容")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXGroup",description:"附件.pdf")]),"带文件描述的节点必须保留")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXUnknown")]),"未知节点不默认为空草稿")
        try check(ComposerContent.attachmentCount("正文",imageNodes:0) == 0,"纯文字不计为图片")
        try check(ComposerContent.attachmentCount("\u{fffc}\n正文",imageNodes:1) == 1,"图片节点与占位符不重复计数")
        try check(ComposerContent.attachmentCount("\u{fffc}\u{fffc}\n正文",imageNodes:0) == 2,"QQ 只暴露占位符时仍可识别多图")
        try check(ComposerContent.attachmentCount("正文",imageNodes:2) == 2,"QQ 只暴露图片节点时仍可识别多图")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 8, composerImagesNow: 9) == 1,"图片作为输入框同级预览时也能确认进入草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 8, composerImagesNow: 8) == 0,"工具栏已有图标不能误认为新配图")
        // QQ 实测布局：AXTextArea 的父节点只有输入框自己，配图预览条在带「会话」工具栏的那一层
        try check(ComposerRegion.previewLevel(childRoles: [["AXTextArea"],["AXGroup"],["AXGroup","AXGroup","AXToolbar","AXGroup","AXGroup"]]) == 2,"配图预览区取带工具栏的那一层，不是输入框父节点")
        try check(ComposerRegion.previewLevel(childRoles: [["AXTextArea"],["AXGroup"]]) == 0,"认不出工具栏时回落到输入框父节点，不外扩到消息列表")
        try check(ComposerRegion.previewLevel(childRoles: []) == 0,"读不到祖先链时不误报预览区")
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",0),("AXToolbar",11),("AXGroup",1)]) == 1,"工具栏 11 个图标不计入配图")
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",2),("AXToolbar",11)]) == 2,"预览条里的两张图都计入")
        try check(ComposerRegion.previewImageCount(children: []) == 0,"空预览区计 0")
        // 空草稿守卫与配图确认必须同一口径，否则残留图片会被折进基线、跟计划图片一起发出去
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",1),("AXToolbar",11),("AXGroup",0)]) == 1,"预览区里的残留图片要在填写草稿前就被拒绝")
        try check(ComposerRegion.previewImageCount(children: [("AXToolbar",11)]) == 0,"只有工具栏图标时仍算空草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 1, composerImagesNow: 2) == 1,"残留图片一旦被当基线，差值就只看得见本次新粘贴的那张")
        // 结构快照只用于失败时交代现场：节点/按钮/高度变化一律不构成图片证据
        let plainDraft = ComposerSnapshot(images: 0, buttons: 2, nodes: 10, editorHeight: 167)
        let churnedDraft = ComposerSnapshot(images: 0, buttons: 5, nodes: 40, editorHeight: 400)
        try check(plainDraft != churnedDraft,"QQ 异步重渲染确实会让结构数字自己变化")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: plainDraft.images, composerImagesNow: churnedDraft.images) == 0,"结构数字涨了但图片数为 0，仍不得确认图片进草稿")
        try check(ComposerContent.attachmentCount("正文没有占位符", imageNodes: 0) == 0,"没有 AXImage 也没有 U+FFFC 时不得凭空计为图片")
        // 失败现场只如实描述：新增 class 与字符数差值都不参与“能不能发”的判定
        try check(ComposerDiagnostic.newClasses(before: ["ProseMirror","is-empty"], now: ["ProseMirror","image-wrap","q-icon"]) == ["image-wrap","q-icon"],"blocked 记录里列出粘贴后新增的 DOM class")
        try check(ComposerDiagnostic.newClasses(before: ["a","b"], now: ["a","b"]).isEmpty,"没有新增 class 时如实写空，不编造线索")
        try check(ComposerDiagnostic.extraCharacters(textLength: 18, characterCount: 19) == 1,"字符数比正文多 1 时如实报告多出 1")
        try check(ComposerDiagnostic.extraCharacters(textLength: 18, characterCount: 18) == 0,"正文与字符数一致时不算多出内容")
        try check(ComposerDiagnostic.extraCharacters(textLength: 10, characterCount: -1) == 0,"读不到字符数时不编造差值")
        try check(SendGate.blockedByModal(modalPresent: true, sendButtonsOutsideComposer: 0),"有模态容器时绝不触发发送")
        try check(SendGate.blockedByModal(modalPresent: false, sendButtonsOutsideComposer: 1),"输入区之外出现「发送」按钮（如“发送到我的手机”确认框）时不触发发送")
        try check(!SendGate.blockedByModal(modalPresent: false, sendButtonsOutsideComposer: 0),"没有弹窗时才允许发出唯一一条发送指令")
        try check(SendGate.isSendConfirmationButton("发送(1)") && SendGate.isSendConfirmationButton("Send(2)"),"带数量的弹窗发送按钮也必须拦截")
        try check(!SendGate.isSendConfirmationButton("发送到桌面"),"其他带发送字样的工具按钮不能误判为弹窗确认")
        try check(ComposerImageSignal.newImageClasses(before: ["ProseMirror"], now: ["ProseMirror", "editor-el--inline-block"]) == ["editor-el--inline-block"],"实测 QQ 群聊图片缩略图的内联 class 可确认入草稿")
        try check(ComposerImageSignal.sameVisibleText(before: "正文", after: "正文\n\u{200b}\u{fffc}\n"),"图片粘贴导致的换行、零宽字符和附件占位符不阻挡发送")
        try check(!ComposerImageSignal.sameVisibleText(before: "正文", after: "正文改\n\u{200b}"),"正文改变时不能将图片信号当作发送许可")
        try check(ComposerImageSignal.newImageClasses(before: ["ProseMirror","q-icon","is-empty"], now: ["ProseMirror","q-icon","msg-image"]) == ["msg-image"],"粘贴后新出现的图片专属 class 才算图片证据")
        try check(ComposerImageSignal.newImageClasses(before: [], now: ["q-svg-icon","expression-panel","sticker-wrapper","avatar"]).isEmpty,"工具栏、表情面板、头像这些本来就有的 class 不算图片证据")
        try check(ComposerImageSignal.newImageClasses(before: ["a"], now: ["a"]).isEmpty,"class 没有新增时不编造图片证据")
        try check(ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: 469, charactersAfter: 470),"正文一字未改而字符数多 1，算内联对象出现")
        let inlineImage = ComposerImageNode(role: "AXGroup", classes: ["editor-el--inline-block"])
        let qqImageDraft = ComposerImageNode(role: "AXTextArea", classes: ["ProseMirror"], children: [
            ComposerImageNode(role: "AXGroup", children: [ComposerImageNode(role: "AXStaticText")]), inlineImage
        ])
        try check(ComposerImageCount.count(qqImageDraft) == 1, "QQ 内联缩略图未暴露 AXImage 或占位符也按实际节点计 1 张")
        try check(ComposerImageCount.count(.init(role: "AXTextArea", children: [inlineImage, inlineImage])) == 2,
                  "两张同 class 图片按节点数量计 2，不按去重后的 class 集合计 1")
        try check(ComposerImageCount.count(.init(role: "AXGroup", classes: ["editor-el--inline-block"], children: [
            .init(role: "AXImage"), inlineImage
        ])) == 1, "同一附件包装和图片后代只计一次")
        try check(ComposerImageCount.count(.init(role: "AXTextArea", children: [.init(role: "AXImage"), inlineImage])) == 2,
                  "普通 AXImage 与另一张 QQ 内联图片均计入")
        try check(ComposerImageCount.count(.init(role: "AXToolbar", children: [.init(role: "AXImage"), inlineImage])) == 0,
                  "工具栏分支不会充当草稿图片")
        try check(ComposerImageCount.count(.init(role: "AXTextArea", children: [
            .init(role: "AXGroup", classes: ["image-upload-progress", "media-loading", "attach-panel"])
        ])) == 0, "宽泛 image/media/attach class 不足以充当一张图片")
        try check(ComposerImageCount.count(.init(role: "AXTextArea", children: [
            .init(role: "AXStaticText"), .init(role: "AXGroup", classes: ["ProseMirror-trailingBreak"])
        ])) == 0, "换行和普通节点变化不能增加图片计数")
        try check(ComposerContent.attachmentCount("正文\u{fffc}", imageNodes: ComposerImageCount.count(qqImageDraft)) == 1,
                  "同一内联图片和占位符仍计一张")
        try check(ComposerImageCount.count(.init(role: "AXGroup", classes: ["editor-el--inline-block-loading"])) == 0,
                  "图片节点 class 必须完整匹配，前缀或相似名称不放行")
        try check(ComposerSession.accepts(description: "", title: "目标群", sameEditor: true, bindingsIntact: true),
                  "QQ 填入正文后描述消失，原输入框及三重会话绑定完好时仍可核对")
        try check(!ComposerSession.accepts(description: "", title: "目标群", sameEditor: false, bindingsIntact: true),
                  "无描述的新输入框不能冒充之前已确认的输入框")
        try check(!ComposerSession.accepts(description: "其他群", title: "目标群", sameEditor: true, bindingsIntact: true),
                  "同一输入框明确标注其他会话仍停止")
        try check(!ComposerSession.accepts(description: "", title: "目标群", sameEditor: true, bindingsIntact: false),
                  "窗口、头部或消息列表解绑时不允许无描述输入框通过")
        try check(ComposerSession.accepts(description: "目标群", title: "目标群", sameEditor: false, bindingsIntact: true),
                  "新输入框有完整目标标注且会话绑定完好时允许稳定重取")
        try check(ComposerSession.accepts(description: "LemonR®🍋", title: "CUPK-2025级交流群", sameEditor: true,
                                         bindingsIntact: true, structuredBinding: true),
                  "同一输入框和真实聊天结构绑定时可接受陈旧Lemon描述")
        try check(!ComposerSession.accepts(description: "LemonR®🍋", title: "CUPK-2025级交流群", sameEditor: true,
                                          bindingsIntact: true),
                  "未提供结构证据时陈旧Lemon描述仍按严格默认拒绝")
        try check(!ComposerSession.accepts(description: "LemonR®🍋", title: "CUPK-2025级交流群", sameEditor: false,
                                          bindingsIntact: true, structuredBinding: true),
                  "输入框换节点后不能仅靠聊天结构忽略不符描述")
        try check(!ComposerSession.accepts(description: "LemonR®🍋", title: "CUPK-2025级交流群", sameEditor: true,
                                          bindingsIntact: false, structuredBinding: true),
                  "会话句柄解绑后即使结构标志为真仍拒绝")
        try check(!ComposerSession.accepts(description: "LemonR®🍋", title: "  ", sameEditor: true,
                                          bindingsIntact: true, structuredBinding: true),
                  "结构证据不能替代实际绑定的非空群名")
        do {
            // 同源和唯一性由驱动验证；几何只保证候选确实在当前可见聊天区域。
            let frames: [CGRect?] = [
                CGRect(x: 0, y: 0, width: 1200, height: 900),
                CGRect(x: 360, y: 40, width: 700, height: 820),
                CGRect(x: 380, y: 55, width: 300, height: 40),
                CGRect(x: 370, y: 115, width: 680, height: 610),
                CGRect(x: 380, y: 760, width: 660, height: 60)
            ]
            func geometry(_ values: [CGRect?]) -> Bool {
                QQConversationGeometry.valid(window: values[0], pane: values[1], header: values[2],
                                             messages: values[3], composer: values[4])
            }
            func replacing(_ index: Int, with rect: CGRect?) -> [CGRect?] {
                var changed = frames; changed[index] = rect; return changed
            }
            try check(QQConversationGeometry.valid(
                window: CGRect(x: 354, y: 186, width: 970, height: 640),
                pane: CGRect(x: 608, y: 226, width: 712, height: 596),
                header: CGRect(x: 624, y: 243, width: 214, height: 22),
                messages: CGRect(x: 608, y: 278, width: 532, height: 337),
                composer: CGRect(x: 608, y: 655, width: 532, height: 167)),
                "实测QQ aio聊天容器、contact-name、chat-msg-area和chat-input-area几何可绑定")
            try check(geometry(frames), "右侧同一聊天区域内标题、消息列表、编辑器按上下顺序可见")
            try check(geometry(replacing(4, with: CGRect(x: 380, y: 760, width: 660, height: 1))),
                      "空编辑器的1pt高度不被误判为不可见")
            try check(geometry(replacing(4, with: CGRect(x: 380, y: 800, width: 660, height: 50))),
                      "消息列表与输入框之间允许工具栏间隔")
            try check(geometry(frames.map { $0?.offsetBy(dx: -1400, dy: -100) }),
                      "负坐标显示器只要节点在同一可见窗口内也可绑定")
            try check(!geometry(replacing(2, with: CGRect(x: 80, y: 55, width: 200, height: 40))),
                      "窗口左侧联系人或同名会话行不得充当右侧聊天标题")
            try check(!geometry(replacing(1, with: CGRect(x: 80, y: 40, width: 250, height: 820))),
                      "来自其他窗格的pane不能与右侧消息和输入框绑定")
            try check(!geometry(replacing(2, with: CGRect(x: 361, y: 55, width: 8, height: 40))),
                      "标题即使在pane内也必须位于消息横向范围")
            try check(!geometry(replacing(4, with: CGRect(x: 365, y: 760, width: 690, height: 60))),
                      "输入框即使在pane内也必须与消息区域横向对齐")
            try check(!geometry(replacing(2, with: CGRect(x: 380, y: 150, width: 300, height: 40))),
                      "消息区内的同名消息文字不得当成上方标题")
            try check(!geometry(replacing(4, with: CGRect(x: 380, y: 90, width: 660, height: 20))),
                      "消息列表上方的其他文本框不得当成底部编辑器")
            try check(!geometry(replacing(4, with: CGRect(x: 380, y: 860, width: 660, height: 60))),
                      "窗口外或pane外输入框不可用于发送绑定")
            try check(!geometry(replacing(1, with: CGRect(x: 360, y: 40, width: 900, height: 820))),
                      "pane本身超出可见窗口时不能作为聊天区域证据")
            try check(!geometry(replacing(4, with: CGRect(x: 380, y: 760, width: 0, height: 60))),
                      "零宽输入框不可作为可见绑定证据")
            try check(!geometry(replacing(4, with: CGRect(x: 380, y: 760, width: 660, height: -1))),
                      "负高度输入框不能通过CGRect标准化伪装成可见")
            try check(!geometry(replacing(3, with: CGRect(x: CGFloat.nan, y: 115, width: 680, height: 610))),
                      "消息区域NaN坐标不得用于归属判断")
            try check(!geometry(replacing(2, with: CGRect(x: 380, y: 55, width: 300, height: CGFloat.infinity))),
                      "标题无穷尺寸不得用于归属判断")
            for index in frames.indices {
                try check(!geometry(replacing(index, with: nil)), "第\(index)个绑定frame缺失时不猜测可见结构")
            }
        }
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: false, charactersBefore: 469, charactersAfter: 500),"正文变了就不算：多出来的可能是文字")
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: 469, charactersAfter: 469),"字符数没变说明没有新的内联对象")
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: -1, charactersAfter: 470),"读不到字符数时不做推断")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 0, composerImagesNow: 1) == 1,"新布局下粘贴一张图即可确认进入草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 0, composerImagesNow: 3) == 3,"新布局下粘贴三张图按张数确认")
        try check(SendAttempt.isSendButtonLabel("发送"),"标题为「发送」的按钮可作为发送入口")
        try check(SendAttempt.isSendButtonLabel(" 发送 "),"发送按钮标题允许首尾空白")
        try check(!SendAttempt.isSendButtonLabel("发送到桌面"),"相邻字样不误认为发送按钮")
        try check(!SendAttempt.isSendButtonLabel("表情"),"工具栏按钮不当作发送按钮")
        try check(SendTrigger.allCases.count == 2,"只有发送按钮与 Return 两种触发手段，没有补发档位")
        try check(SendAttempt.firstTrigger(buttonFound: true) == .sendButton,"能认准按钮时优先点发送按钮")
        try check(SendAttempt.firstTrigger(buttonFound: false) == .returnKey,"认不出按钮时只按一次 Return")
        try check(!SendAttempt.allowsSecondTrigger,"任何核验结果都不解锁第二次发送指令，避免重复发送")
        try check(SendAttempt.weChatDraftRemains.contains("一次 Return") && SendAttempt.weChatDraftRemains.contains("不再按第二次") && !SendAttempt.weChatDraftRemains.contains("已尝试 Return 与 Command+Return"), "微信草稿未清空时只记录一次 Return，不宣称补按过 Command+Return")
        try check(SendAttempt.describe(attempted: [.sendButton]) == "QQ 发送按钮","待核对记录如实交代发出过的唯一发送指令")
        try check(SendAttempt.describe(attempted: []) == "未触发任何发送指令","未触发时不谎称已发送")
        // 约束 3 / 走查 1-09：探针判定放在 Core，入口清单含此前漏网的「按已核对草稿续发」
        try check(DispatchProbe.refusal(entry: "按已核对草稿续发", active: false) == nil, "没设探针变量时不拦截，正式运行零影响")
        let probeRefusal = DispatchProbe.refusal(entry: "按已核对草稿续发", active: true)
        try check(probeRefusal?.contains("已拦截「按已核对草稿续发」") == true && probeRefusal?.contains("不会按下任何发送键") == true, "探针生效时给出明确拦截说明（走查 1-09）")
        try check(DispatchProbe.drivenEntries.contains("按已核对草稿续发"), "驱动入口清单收进唯一漏网入口")
        try check(Set(DispatchProbe.drivenEntries).count == DispatchProbe.drivenEntries.count && !DispatchProbe.drivenEntries.contains(where: { $0.isEmpty }), "入口清单不重名也不留空名")
        let source = root.appendingPathComponent("图片 空格 测试.png")
        try Data("file fixture".utf8).write(to:source)
        let sourceDigest = try Database.digest(source)
        let digestDB = try Database(root: root.appendingPathComponent("digestless"))
        let reusedAsset = try digestDB.importAsset(source, precomputedDigest: sourceDigest)
        try check(reusedAsset.sha256 == sourceDigest, "导入素材可复用已经算好的哈希，不再整文件哈希第二遍（走查 1-22）")
        let freshAsset = try digestDB.importAsset(source)
        try check(freshAsset.sha256 == sourceDigest && freshAsset.id != reusedAsset.id, "不传预算哈希时内部自算，既有调用点行为不变")
        let dataRoot=root.appendingPathComponent("library")
        let templates = [TextTemplate(text:"第一条标题\n" + String(repeating:"长文案内容。",count:80)),TextTemplate(text:"第二条标题\n第二条正文")]
        try check(templates[0].title == "第一条标题","长文案标题只取第一行")
        try check(templates[0].id != templates[1].id,"每个备选文案独立标识")
        var asset: Asset!
        do {
            let db=try Database(root:dataRoot);asset=try db.importAsset(source)
            var imagePlan = plan; imagePlan.assetIDs = [asset.id]
            let imageJobs = try Scheduling.expand(imagePlan,recipients:recipients,assets:[asset],now:now)
            try check(imageJobs.allSatisfy { $0.assets == [asset] && $0.text == plan.text },"每个群任务包含同一图文快照")
            imagePlan.text = ""
            try check(try Scheduling.expand(imagePlan,recipients:recipients,assets:[asset],now:now).count == 8,"支持纯图片计划")
            try check(FileManager.default.fileExists(atPath:db.url(for:asset).path),"附件复制进持久资料库")
            try check(try Database.digest(source) == asset.sha256,"SHA256 校验")
            try FileManager.default.removeItem(at:source)
            try check(try Database.digest(db.url(for:asset)) == asset.sha256,"原文件删除后素材仍完整")
            var withFile=jobs;withFile[0].assets=[asset]
            var settings = Settings(); settings.textTemplates = templates
            let archive=Archive(recipients:recipients,assets:[asset],plans:[plan],deliveries:withFile,settings:settings)
            try db.save(archive)
            var invalid=archive;invalid.recipients.append(recipients[0])
            try rejects("事务写入失败回滚") { try db.save(invalid) }
            try check(try db.load("recipients",as:Recipient.self).count == 8,"失败后原数据保持完整")
            try check(try db.load("deliveries",as:Delivery.self).count == 8,"发送记录持久化")
            try db.backup(to:root.appendingPathComponent("backup"))
        }
        let reopened=try Database(root:dataRoot)
        try check(try reopened.load("settings",as:Settings.self).first?.textTemplates == templates,"重开数据库保留多条完整长文案")
        try check(try reopened.load("recipients",as:Recipient.self).map(\.name) == recipients.map(\.name),"数据库重开保留顺序")
        try check(try reopened.load("deliveries",as:Delivery.self)[0].assets[0].sha256 == asset.sha256,"任务保存附件快照")
        let backup=try Database(root:root.appendingPathComponent("backup"))
        try check(try backup.load("settings",as:Settings.self).first?.textTemplates == templates,"数据库备份包含全部备选文案")
        try check(try backup.load("plans",as:Plan.self).count == 1,"在线SQLite备份可打开")
        try check(try Database.digest(backup.url(for:asset)) == asset.sha256,"备份包含素材")
        // 性能与健壮性加固：WAL 限额 + 行级容错
        do {
            let toleranceRoot = root.appendingPathComponent("tolerance")
            let toleranceDB = try Database(root: toleranceRoot)
            try check(toleranceDB.pragmaValue("PRAGMA journal_size_limit") == 16777216, "打开连接即设置 journal_size_limit 为 16MB")
            try toleranceDB.save(Archive(recipients: recipients, assets: [], plans: [plan], deliveries: jobs, settings: Settings(savedText: "")))
            // 用独立 sqlite3 连接直接往 recipients 混入一行非法 payload（坏 JSON 字节）
            var raw: OpaquePointer?
            guard sqlite3_open(toleranceRoot.appendingPathComponent("library.sqlite3").path, &raw) == SQLITE_OK else { throw AppError("测试无法打开数据库") }
            sqlite3_busy_timeout(raw, 5000)
            defer { sqlite3_close(raw) }
            guard sqlite3_exec(raw, "INSERT INTO recipients(id,payload) VALUES('corrupt-row',X'BADF00D0')", nil, nil, nil) == SQLITE_OK else { throw AppError("测试无法混入坏行") }
            let loadedRecipients = try toleranceDB.load("recipients", as: Recipient.self)
            try check(toleranceDB.lastSkippedRows == 1, "坏行计入跳过数且 load 不抛错")
            try check(loadedRecipients.count == recipients.count && loadedRecipients == recipients, "坏行跳过后其余行全部读出且数据完整、顺序不变")
            var kept = false
            var countStmt: OpaquePointer?
            if sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM recipients WHERE id='corrupt-row'", -1, &countStmt, nil) == SQLITE_OK {
                if sqlite3_step(countStmt) == SQLITE_ROW { kept = sqlite3_column_int(countStmt, 0) == 1 }
            }
            sqlite3_finalize(countStmt)
            try check(kept, "坏行原样保留在磁盘上，load 不删除不改写")
            // 走查 1-07：坏行额外进隔离区，任何一次全量落盘都不会让它无声消失
            try check(toleranceDB.hasUndecodableRows, "发现坏行后连接内标记为有不可解码数据")
            try check(toleranceDB.quarantinedRows(for: "recipients").map(\.id) == ["corrupt-row"], "隔离区按来源表与行 id 记账")
            try check(toleranceDB.quarantinedRows(for: "recipients").first?.payload == Data([0xBA, 0xDF, 0x00, 0xD0]), "隔离区逐字保留坏行的原始 payload")
            try check(toleranceDB.quarantineCount() == 1, "隔离表落盘一条坏行副本")
            // 之后任意一次整库落盘：坏行仍在原表，内容没被销毁
            let keepArchive = Archive(recipients: recipients, assets: [], plans: [plan], deliveries: jobs, settings: Settings(savedText: ""))
            try toleranceDB.save(keepArchive)
            var keptAfterSave = false
            var afterStmt: OpaquePointer?
            if sqlite3_prepare_v2(raw, "SELECT payload FROM recipients WHERE id='corrupt-row'", -1, &afterStmt, nil) == SQLITE_OK {
                if sqlite3_step(afterStmt) == SQLITE_ROW {
                    let size = Int(sqlite3_column_bytes(afterStmt, 0))
                    if let bytes = sqlite3_column_blob(afterStmt, 0) { keptAfterSave = Data(bytes: bytes, count: size) == Data([0xBA, 0xDF, 0x00, 0xD0]) }
                }
            }
            sqlite3_finalize(afterStmt)
            try check(keptAfterSave, "全量重写把坏行原样写回原表，落盘后内容逐字不变（走查 1-07）")
            try check(toleranceDB.quarantineCount() == 1, "落盘不会把隔离区里的坏行副本一起清掉")
            let afterReopen = try Database(root: toleranceRoot)
            let reloaded = try afterReopen.load("recipients", as: Recipient.self)
            try check(reloaded.count == recipients.count && afterReopen.lastSkippedRows == 1, "重开数据库后正常行完整、坏行仍被跳过而不是消失")
            try check(afterReopen.quarantinedRows(for: "recipients").first?.payload == Data([0xBA, 0xDF, 0x00, 0xD0]), "重开后隔离记录仍可读出")
            try check(afterReopen.quarantinedRows(for: "recipients").first?.reason.contains("Recipient") == true, "隔离记录写明无法解码成的类型")
            // 差量写入路径（deliveries）同样保行：先建立基线，再混入坏行、再落盘
            guard sqlite3_exec(raw, "INSERT INTO deliveries(id,payload) VALUES('corrupt-delivery',X'FF00')", nil, nil, nil) == SQLITE_OK else { throw AppError("测试无法混入坏任务行") }
            let mixedLoad = try Database(root: toleranceRoot)
            _ = try mixedLoad.load("deliveries", as: Delivery.self)
            try check(mixedLoad.lastSkippedRows == 1, "坏任务行计入跳过数")
            try mixedLoad.save(keepArchive)
            try mixedLoad.save(keepArchive)
            var deliveryKept = false
            var deliveryStmt: OpaquePointer?
            if sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM deliveries WHERE id='corrupt-delivery'", -1, &deliveryStmt, nil) == SQLITE_OK {
                if sqlite3_step(deliveryStmt) == SQLITE_ROW { deliveryKept = sqlite3_column_int(deliveryStmt, 0) == 1 }
            }
            sqlite3_finalize(deliveryStmt)
            try check(deliveryKept, "坏任务行在首次全量与后续差量落盘后都留在表里")
            try check(mixedLoad.quarantinedRows(for: "deliveries").map(\.id) == ["corrupt-delivery"], "坏任务行同时留有隔离副本")
            // 正常删除的行不会被隔离区“复活”：隔离区只存 load 时发现解码失败的那几行
            var shrunk = keepArchive; shrunk.recipients = Array(recipients.dropFirst())
            try toleranceDB.save(shrunk)
            let remainingNames = try toleranceDB.load("recipients", as: Recipient.self).map(\.name)
            try check(remainingNames.count == recipients.count - 1 && !remainingNames.contains(recipients[0].name), "用户真删的名单条目照常删除，隔离区不把它请回来")
            // settings 的单行坏 payload 同样进隔离区，不静默销毁
            guard sqlite3_exec(raw, "INSERT INTO settings(id,payload) VALUES('corrupt-settings',X'7B226E6F7065223A')", nil, nil, nil) == SQLITE_OK else { throw AppError("测试无法混入坏设置行") }
            let settingsDB = try Database(root: toleranceRoot)
            _ = try settingsDB.load("settings", as: Settings.self)
            try check(settingsDB.lastSkippedRows == 1 && settingsDB.quarantinedRows(for: "settings").map(\.id) == ["corrupt-settings"], "坏设置行同样计入跳过并隔离")
            // 再次 load 仍跳过同一行：读取路径只写隔离表，不改动数据表内容
            _ = try settingsDB.load("settings", as: Settings.self)
            try check(settingsDB.lastSkippedRows == 1, "重复读取同一坏行结果一致（隔离写入幂等）")
            try check(settingsDB.quarantineCount() == 3 && settingsDB.load("settings", as: Settings.self).count == 1, "隔离表累计三条（名单/任务/设置）而数据表仍只有一行有效设置")
            settingsDB.resetQuarantineIndex()
            try check(!settingsDB.hasUndecodableRows, "整库替换后可重置本连接的坏行索引")
            try check(settingsDB.quarantineCount() == 3, "重置内存索引不销毁隔离区历史")
        }
        // 连接级故障自愈（2026-10-11）：磁盘 I/O 等瞬时故障后旧连接可能持续报错，
        // 而保存失败会停止全部队列并反复弹错。自愈重连后重试成功时必须对上层完全透明。
        do {
            let healRoot = root.appendingPathComponent("heal")
            let healDB = try Database(root: healRoot)
            let healArchive = Archive(recipients: recipients, assets: [], plans: [plan], deliveries: jobs, settings: Settings(savedText: ""))
            try healDB.save(healArchive)
            try check(healDB.lastFailureRC == nil, "成功保存不留下失败码")
            // 1) BEGIN 阶段注入一次 I/O 错误 → 自愈重连 → 重试成功，对上层透明
            var ioFailedOnce = false
            healDB.testExecFault = { sql in
                guard sql.hasPrefix("BEGIN"), !ioFailedOnce else { return nil }
                ioFailedOnce = true
                return SQLITE_IOERR
            }
            try healDB.save(healArchive)
            try check(healDB.recoveryCount == 1 && healDB.lastRecovery != nil, "可恢复错误触发一次自愈重连并留痕")
            healDB.testExecFault = nil
            try check(try healDB.load("recipients", as: Recipient.self) == recipients, "自愈后重试成功，数据完整落盘")
            // 2) 重连后差量基线已重置：改动一条任务能正确落盘
            var touched = healArchive
            touched.deliveries[0].text = "自愈后的新正文"
            try healDB.save(touched)
            try check(try healDB.load("deliveries", as: Delivery.self).first { $0.id == touched.deliveries[0].id }?.text == "自愈后的新正文", "重连重建基线后后续写入仍正确")
            // 3) 约束类错误不在可恢复之列：不重连、不重试
            healDB.testExecFault = { $0.hasPrefix("BEGIN") ? SQLITE_CONSTRAINT : nil }
            try rejects("约束类错误不触发自愈重连") { try healDB.save(touched) }
            try check(healDB.recoveryCount == 1, "约束类错误不增加自愈计数")
            healDB.testExecFault = nil
            try check(try healDB.load("deliveries", as: Delivery.self).first { $0.id == touched.deliveries[0].id }?.text == "自愈后的新正文", "未重试的失败没有破坏磁盘数据")
            // 4) 重连也失败（每条 exec 都失败）时如实上抛，且下一次调用仍能重建连接恢复写入
            healDB.testExecFault = { _ in SQLITE_IOERR }
            try rejects("重连失败时如实上抛") { try healDB.save(touched) }
            try check(healDB.recoveryCount == 1, "重连本身失败不计入自愈成功")
            healDB.testExecFault = nil
            try healDB.save(touched)
            try check(try healDB.load("deliveries", as: Delivery.self).first { $0.id == touched.deliveries[0].id }?.text == "自愈后的新正文", "重连失败后下一次调用重建连接并恢复写入")
            // 5) 重连后的全量重写仍保留隔离区坏行（走查 1-07 的承诺跨重连成立）
            var rawHandle: OpaquePointer?
            guard sqlite3_open(healRoot.appendingPathComponent("library.sqlite3").path, &rawHandle) == SQLITE_OK else { throw AppError("测试无法打开数据库") }
            sqlite3_busy_timeout(rawHandle, 5000)
            defer { sqlite3_close(rawHandle) }
            guard sqlite3_exec(rawHandle, "INSERT INTO recipients(id,payload) VALUES('heal-corrupt-row',X'BADF00D0')", nil, nil, nil) == SQLITE_OK else { throw AppError("测试无法混入坏行") }
            _ = try healDB.load("recipients", as: Recipient.self)
            try check(healDB.hasUndecodableRows, "自愈连接同样把坏行记进内存索引")
            var secondIOFailed = false
            healDB.testExecFault = { sql in
                guard sql.hasPrefix("BEGIN"), !secondIOFailed else { return nil }
                secondIOFailed = true
                return SQLITE_IOERR
            }
            try healDB.save(touched)
            try check(healDB.recoveryCount == 2, "第二次可恢复错误再次自愈")
            healDB.testExecFault = nil
            var stillThere = false
            var probe: OpaquePointer?
            if sqlite3_prepare_v2(rawHandle, "SELECT COUNT(*) FROM recipients WHERE id='heal-corrupt-row'", -1, &probe, nil) == SQLITE_OK {
                if sqlite3_step(probe) == SQLITE_ROW { stillThere = sqlite3_column_int(probe, 0) == 1 }
            }
            sqlite3_finalize(probe)
            try check(stillThere, "重连后的全量重写仍把隔离区坏行原样写回（走查 1-07 跨重连成立）")
        }
        // 渠道字段（QQ / 微信双通道）
        let legacyRecipientJSON = Data("{\"id\":\"x\",\"name\":\"旧群\",\"note\":\"\",\"enabled\":true}".utf8)
        try check(try JSONDecoder().decode(Recipient.self,from:legacyRecipientJSON).channelName == "qq","旧名单无渠道字段默认 QQ")
        var wxRecipients = recipients
        wxRecipients[0].channel = SendChannel.wechat
        var mixed = sixPlan; mixed.recipientIDs = [wxRecipients[0].id, wxRecipients[1].id]
        let mixedJobs = try Scheduling.expand(mixed,recipients:wxRecipients,assets:[],now:now)
        try check(mixedJobs[0].channelName == "wechat" && mixedJobs[1].channelName == "qq","任务继承收件人渠道")
        try check(SendChannel.qq == "qq" && SendChannel.wechat == "wechat","渠道常量")
        // Regression: retire only the legacy pre-execution deadline failure.
        var expired = jobs[0]
        expired.status = "blocked"
        expired.detail = "已错过计划时间超过 15 分钟，不集中补发。请点击重新排期"
        expired.finished = now
        expired.scheduled = now.addingTimeInterval(-86400)
        let recoveredExpired = Scheduling.recovered([expired])[0]
        try check(recoveredExpired.status == "queued" && recoveredExpired.finished == nil, "旧版超时任务恢复待执行")
        try check(recoveredExpired.scheduled == expired.scheduled && recoveredExpired.text == expired.text && recoveredExpired.id == expired.id, "恢复保持排期顺序和消息快照")
        try check(Scheduling.eligible([recoveredExpired], now: now, gap: 30)?.id == expired.id, "过期一天的任务仍可调度，不逐条冻结")
        var attempted = expired; attempted.started = now
        try check(Scheduling.recovered([attempted])[0].status == "blocked", "实际执行过的任务不自动恢复")
        var submittedExpired = expired; submittedExpired.submittedAt = now
        try check(Scheduling.recovered([submittedExpired])[0].status == "blocked", "有提交时间的任务不自动恢复")
        var focused = expired; focused.detail = "步骤：直接聚焦搜索框：测试群\n前台已切换到其他应用，操作暂停"
        try check(Scheduling.recovered([focused])[0].status == "blocked", "前台中断不自动恢复")
        try check(focused.attentionReason == "前台已切换到其他应用，操作暂停", "原因展示实际错误而非执行步骤")
        var labelMismatch = expired
        labelMismatch.status = "uncertain"
        labelMismatch.detail = "步骤：已按 Return，等待 QQ 发送\n输入框当前标注为「2025资源勘查工程专业群」，与已选中的「中国石油大学克拉玛依校区2026级新生交流群」不一致"
        try check(labelMismatch.attentionReason == "输入框当前标注为「2025资源勘查工程专业群」，与已选中的「中国石油大学克拉玛依校区2026级新生交流群」不一致", "列表显示输入框标注不一致，不先显示步骤行")
        let shownReason = ListPreview.clip(labelMismatch.attentionReason ?? "")
        try check(!shownReason.clipped && shownReason.text == labelMismatch.attentionReason, "这条标注不一致的原因在列表里完整显示")
        let limit = ListPreview.maxLines * ListPreview.charactersPerLine
        let longReason = String(repeating: "图", count: limit + 1)
        let clipped = ListPreview.clip(longReason)
        try check(limit == 96 && clipped.clipped && clipped.text == String(repeating: "图", count: limit) + "…", "窄列上超长原因按四行截断并留下省略号")
        try check(ListPreview.moreNote(opensReview: true) == "后面还有，点「去核对」看全文。", "待核对的超长原因指向去核对")
        try check(ListPreview.moreNote(opensReview: false) == "后面还有，点「详情」看全文。", "其他超长记录指向详情")
        try check(labelMismatch.listGuidance == "点「去核对」，到QQ查看实际消息；确认未发出并清空草稿后，可重新发送。", "结果待核对告诉人去 QQ 查看，人工核对未发出后可重新发送")
        labelMismatch.channel = SendChannel.wechat
        try check(labelMismatch.listGuidance == "点「去核对」，到微信查看实际消息；确认未发出并清空草稿后，可重新发送。", "微信待核对告诉人去微信查看")
        var held = expired
        held.status = "blocked"
        try check(held.listGuidance == "点“去核对”，到QQ查看后选择“发送”或“不发送”；不自动重试。" && held.canResendAfterReview, "未提交的故障同样进入两选项核对页")
        held.submittedAt = Date()
        try check(held.listGuidance == "点“去核对”，到QQ查看后选择“发送”或“不发送”；不自动重试。" && held.canResendAfterReview, "已提交的故障只接受核对后的新尝试，不自动重试")
        held.status = "queued"
        held.submittedAt = nil
        try check(held.listGuidance == nil, "待执行不额外写核对提示")
        try check(Scheduling.recovered([recoveredExpired])[0].detail == recoveredExpired.detail, "超时恢复可重复启动且不重复修改")
        var lastSent = jobs[1]; lastSent.status = "verified"; lastSent.submittedAt = now.addingTimeInterval(-60)
        try check(Scheduling.eligible([lastSent, recoveredExpired], now: now, gap: 30) == nil, "恢复过期任务仍遵守全局冷却")
        try check(Scheduling.eligible([lastSent, recoveredExpired], now: now.addingTimeInterval(1740), gap: 30)?.id == expired.id, "冷却结束后恢复任务可执行")
        var paused = jobs[0]; paused.status = "blocked"; paused.started = now; paused.detail = "前台切换"
        let retried = Scheduling.requeued([paused], ids: [paused.id], now: now, gap: 30)[0]
        try check(retried.status == "queued" && retried.started == nil && retried.id == paused.id, "点击暂停重入队，不创建重复任务")
        try check(retried.text == paused.text && retried.recipient == paused.recipient, "重入队保持收件人和内容")
        var risky = paused; risky.submittedAt = now
        try check(Scheduling.requeued([risky], ids: [risky.id], now: now, gap: 30)[0].status == "blocked", "有提交记录的暂停任务不直接重试")
        try check(!risky.canReschedule, "已经提交过的已暂停不能重新排期")
        try check(paused.canReschedule, "没提交过的已暂停可以重新排期")
        var queuedSent = paused
        queuedSent.status = "queued"
        queuedSent.submittedAt = now
        try check(!queuedSent.canReschedule && Scheduling.eligible([queuedSent], now: now.addingTimeInterval(10000), gap: 30) == nil, "带着提交记录回到待执行也不会再自动发送")
        try check(queuedSent.listGuidance == "这条已有提交记录，不会自动再发。点「去核对」，到QQ查看。", "这种待执行记录提示不会自动再发")
        var unsure = paused; unsure.status = "uncertain"
        try check(Scheduling.requeued([unsure], ids: [unsure.id], now: now, gap: 30)[0].status == "uncertain", "结果待核对任务不直接重试")
        let repeated = Scheduling.requeued([retried], ids: [retried.id], now: now.addingTimeInterval(60), gap: 30)[0]
        try check(repeated.scheduled == retried.scheduled, "重复点击不重复改动已入队任务")
        var addPlan = sixPlan; addPlan.recipientIDs = Array(recipients.prefix(6).map(\.id))
        let extra = try Scheduling.additionalDeliveries(plan: addPlan, recipients: recipients, jobs: six, now: now, gap: 30)
        try check(extra.count == 2, "六群计划从八群名单只追加两群")
        try check(extra[0].scheduled > six.last!.scheduled && extra[1].scheduled.timeIntervalSince(extra[0].scheduled) >= 1800, "扩充排在队尾且保留发送间隔")
        try check(extra.allSatisfy { $0.text == six.last!.text && $0.assets == six.last!.assets && $0.status == "queued" && $0.started == nil && $0.submittedAt == nil }, "追加沿用图文且不继承执行状态")
        try check(try Scheduling.additionalDeliveries(plan: addPlan, recipients: recipients, jobs: six + extra, now: now, gap: 30).isEmpty, "扩充相同群不重复创建任务")
        // 走查 1-06：队尾若是一次性补草稿或被改成自动发送的记录，追加的新任务不能继承这些属性
        var cloneTail = six.last!
        cloneTail.id = "clone-tail"; cloneTail.oneOff = true; cloneTail.cloneOf = six[0].id; cloneTail.mode = "draft"; cloneTail.cycleTag = 4
        var polluted = six; polluted[polluted.count - 1] = cloneTail
        let skipOneOff = try Scheduling.additionalDeliveries(plan: addPlan, recipients: [recipients[6]], jobs: polluted, now: now, gap: 30)
        try check(skipOneOff.count == 1 && skipOneOff[0].oneOff == nil && skipOneOff[0].cloneOf == nil, "追加的新任务不继承队尾一次性草稿标记，不会被排期永久跳过")
        try check(skipOneOff[0].mode == addPlan.mode && skipOneOff[0].cycleTag == 4, "新任务回到计划自身的发送模式，并归入当前最新一轮继续参与循环")
        try check(skipOneOff[0].text == addPlan.text, "新任务用计划正文而不是队尾快照")
        // 队尾被「现在自动发送此条」改成 automatic 时，草稿计划追加出来的任务不能变成自动发送
        var autoTail = six.last!; autoTail.mode = "automatic"; autoTail.status = "verified"; autoTail.submittedAt = now; autoTail.evidence = "已核验"
        var draftPlan = addPlan; draftPlan.mode = "draft"
        let keptDraft = try Scheduling.additionalDeliveries(plan: draftPlan, recipients: [recipients[6]], jobs: six + [autoTail], now: now, gap: 30)
        try check(keptDraft.count == 1 && keptDraft[0].mode == "draft", "草稿计划追加的新任务仍只填草稿，不继承队尾的自动发送模式")
        // 配图按计划取快照（传入素材库时）
        let planAsset = Asset(id: "plan-asset", name: "海报.png", relativePath: "assets/plan-asset/海报.png", sha256: "p", bytes: 3, isImage: true)
        let staleAsset = Asset(id: "stale-asset", name: "旧图.png", relativePath: "assets/stale-asset/旧图.png", sha256: "s", bytes: 1, isImage: true)
        var withAssets = addPlan; withAssets.assetIDs = [planAsset.id]
        var tailWithOld = six; tailWithOld[tailWithOld.count - 1].assets = [staleAsset]
        let synced = try Scheduling.additionalDeliveries(plan: withAssets, recipients: [recipients[6]], jobs: tailWithOld, now: now, gap: 30, assets: [planAsset, staleAsset])
        try check(synced.first?.assets == [planAsset], "传入素材库时新任务按计划配图取快照，与界面「沿用本计划的图文」一致")
        let legacySnapshot = try Scheduling.additionalDeliveries(plan: withAssets, recipients: [recipients[6]], jobs: tailWithOld, now: now, gap: 30)
        try check(legacySnapshot.first?.assets == [staleAsset], "未传素材库时保持旧的队尾快照口径，既有调用点不受影响")
        // 只有一次性补草稿的计划：明确拒绝而不是悄悄沿用草稿单
        var onlyOneOffPlan = addPlan; onlyOneOffPlan.recipientIDs = [recipients[0].id]
        try rejects("队尾只剩一次性任务时拒绝沿用模板") { _ = try Scheduling.additionalDeliveries(plan: onlyOneOffPlan, recipients: [recipients[1]], jobs: [cloneTail], now: now, gap: 30) }
        // 发送顺序：QQ 与微信两套隔离排序
        var channelMix = recipients
        channelMix[0].channel = SendChannel.wechat
        channelMix[2].channel = SendChannel.wechat
        let qqMovedDown = RecipientList.moved(channelMix, id: channelMix[1].id, offset: 1)
        try check(qqMovedDown.map(\.name) == ["测试群1","测试群4","测试群3","测试群2","测试群5","测试群6","测试群7","测试群8"],"同渠道下移只与相邻同渠道成员交换")
        try check(RecipientList.filtered(qqMovedDown, channel: SendChannel.qq).map(\.name) == ["测试群4","测试群2","测试群5","测试群6","测试群7","测试群8"],"QQ 子序列按移动后排序")
        try check(RecipientList.filtered(qqMovedDown, channel: SendChannel.wechat).map(\.name) == ["测试群1","测试群3"],"移动 QQ 成员不影响微信顺序")
        let wxMovedUp = RecipientList.moved(channelMix, id: channelMix[2].id, offset: -1)
        try check(RecipientList.filtered(wxMovedUp, channel: SendChannel.wechat).map(\.name) == ["测试群3","测试群1"],"微信子序列内上移")
        try check(RecipientList.filtered(wxMovedUp, channel: SendChannel.qq).map(\.name) == ["测试群2","测试群4","测试群5","测试群6","测试群7","测试群8"],"移动微信成员不影响 QQ 顺序")
        try check(RecipientList.moved(channelMix, id: channelMix[0].id, offset: -1) == channelMix,"渠道首行上移返回原数组")
        try check(RecipientList.moved(channelMix, id: channelMix[7].id, offset: 1) == channelMix,"渠道末行下移返回原数组")
        try check(RecipientList.moved(channelMix, id: "不存在的 id", offset: 1) == channelMix,"未知 id 返回原数组")
        try check(RecipientList.moved(channelMix, id: channelMix[1].id, offset: 0) == channelMix,"offset 为 0 返回原数组")
        try check(RecipientList.filtered([Recipient(name:"旧群"), channelMix[0]], channel: SendChannel.qq).map(\.name) == ["旧群"],"channel 为 nil 的旧数据按 QQ 归类")
        // 会员纯逻辑：LicenseState 四态边界
        try check(LicenseState.resolve(profile:nil,now:now,lastValidated:nil) == .loggedOut,"无档案即未登录")
        let member = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(3600),daysLeft:1,source:"paid")
        try check(LicenseState.resolve(profile:member,now:now,lastValidated:nil) == .active(member),"到期前为 active，与校验时间无关")
        try check(LicenseState.resolve(profile:member,now:member.paidUntil!,lastValidated:member.paidUntil!) == .grace(member),"到期时刻（不晚于 now）且刚校验过进入宽限")
        let overdue = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(-3600),daysLeft:0,source:"paid")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:now.addingTimeInterval(-71*3600)) == .grace(overdue),"过期但 72 小时内校验过为 grace")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:now.addingTimeInterval(-73*3600)) == .expired(overdue),"超过 72 小时未校验为 expired")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:nil) == .expired(overdue),"过期且从无校验时间为 expired")
        try check(LicenseState.resolve(profile:MembershipProfile(account:"a",planLabel:"试用",paidUntil:nil,daysLeft:nil,source:"trial"),now:now,lastValidated:nil).isExpired,"无到期日的档案按过期判定")
        // 走查 3-15（阻断项闭合）：服务端权威结论优先于本机推算，宽限期只覆盖「联系不上服务器」
        let authority = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(86400),daysLeft:1,source:"paid",expired:true)
        try check(LicenseState.resolve(profile:authority,now:now,lastValidated:now) == .expired(authority),"服务端答过期时即使本地未到期、且刚校验过也判 expired")
        try check(!LicenseState.serverConfirmedValid(authority,now:now),"服务端答过期即不算一次有效验证，宽限计时点不刷新")
        let activeFalse = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(86400),daysLeft:1,source:"paid",active:false)
        try check(LicenseState.resolve(profile:activeFalse,now:now,lastValidated:now).isExpired,"active=false 与 expired=true 同口径")
        let stateString = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:nil,daysLeft:nil,source:"paid",membershipState:"Expired")
        try check(stateString.serverSaysExpired,"membership_state 字符串口径大小写不敏感")
        try check(!member.serverSaysExpired,"老服务端三字段全缺省时不擅自判过期（向后兼容）")
        try check(LicenseState.resolve(profile:member,now:now,lastValidated:nil) == .active(member),"三字段缺省时仍按本地 paidUntil 推算，与今天一致")
        // 走查 3-15：单调时间锚——把系统时钟拨回去不再能续命
        let anchor = now.addingTimeInterval(2*3600)
        let rolledBack = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(1*3600),daysLeft:1,source:"paid")
        try check(LicenseState.timeFloor(now:now,lastServerTime:nil) == now,"无锚点时时基就是本机时钟（旧库缺省行为不变）")
        try check(LicenseState.timeFloor(now:now,lastServerTime:anchor) == anchor,"本机时钟早于锚点时以锚点为下限")
        try check(LicenseState.timeFloor(now:anchor,lastServerTime:now) == anchor,"本机时钟晚于锚点时仍以本机时钟为准（正常前进不受影响）")
        try check(LicenseState.timeFloor(now:now,lastServerTime:Date(timeIntervalSince1970:0)) == now,"纪元 0 的脏锚点被忽略")
        try check(LicenseState.resolve(profile:rolledBack,now:now,lastValidated:nil,lastServerTime:anchor) != .active(rolledBack),"时钟拨回到锚点之前时不得判为 active")
        try check(LicenseState.resolve(profile:rolledBack,now:now,lastValidated:nil,lastServerTime:nil) == .active(rolledBack),"同样输入不给锚点仍是 active（对照：起作用的是锚点）")
        try check(LicenseState.resolve(profile:rolledBack,now:now,lastValidated:now,lastServerTime:anchor) == .grace(rolledBack),"拨回时钟后仍保留离线宽限，不误伤正常会员")
        try check(!LicenseState.serverConfirmedValid(rolledBack,now:now,lastServerTime:anchor),"时钟被拨回时本次不算有效验证，计时点不会被充满")
        try check(LicenseState.serverConfirmedValid(rolledBack,now:now,lastServerTime:nil),"无锚点时保持旧的本地推算口径（老库不误伤）")
        let overdueCopy = overdue
        try check(LicenseState.resolve(profile:overdueCopy,now:now.addingTimeInterval(-3*3600),lastValidated:now) == .active(overdueCopy),"复现旧缺陷：不带锚点时把时钟拨回 3 小时即可从 expired 变回 active")
        try check(LicenseState.resolve(profile:overdueCopy,now:now.addingTimeInterval(-3*3600),lastValidated:now,lastServerTime:now) != .active(overdueCopy),"闭合后：同一拨回操作因锚点下限而拿不到 active")
        // 走查 3-15：Settings 侧计时点与锚点的写入语义
        var anchorSettings = Settings(); anchorSettings.licenseProfile = overdue
        anchorSettings.recordLicenseValidation(validated:false,serverTime:anchor,localNow:now)
        try check(anchorSettings.licenseLastValidated == nil,"服务端答过期时清空宽限计时点")
        try check(anchorSettings.licenseLastServerTime == anchor,"无效验证仍把服务端时间并入单调锚点")
        anchorSettings.recordLicenseValidation(validated:false,serverTime:now.addingTimeInterval(-3600),localNow:now)
        try check(anchorSettings.licenseLastServerTime == anchor,"更早的服务端时间不让锚点回退（单调）")
        anchorSettings.recordLicenseValidation(validated:false,serverTime:Date(timeIntervalSince1970:0),localNow:now)
        try check(anchorSettings.licenseLastServerTime == anchor,"脏服务端时间（纪元 0）被忽略")
        var stampSettings = Settings()
        stampSettings.recordLicenseValidation(validated:true,serverTime:nil,localNow:now)
        try check(stampSettings.licenseLastValidated == now,"老服务端不给 server_time 时计时点退回本机时钟")
        stampSettings.recordLicenseValidation(validated:true,serverTime:anchor,localNow:now)
        try check(stampSettings.licenseLastValidated == anchor,"计时点以服务端时间为基准，本机时钟倒退无法把它前移")
        try check(stampSettings.resolvedLicenseState() == .loggedOut,"无档案时统一入口返回 loggedOut")
        var attackSettings = Settings(); attackSettings.licenseProfile = overdue; attackSettings.licenseLastValidated = now; attackSettings.licenseLastServerTime = now
        try check(attackSettings.resolvedLicenseState(now:now.addingTimeInterval(-3*3600)) != .active(overdue),"统一入口带锚点：拨回时钟后过期档案拿不到 active")
        // 走查 3-15：新字段解码、脏类型与落盘往返
        let srvNow = 1_800_000_000.0
        let authProfile = try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u6\",\"paid_until\":\(Int(srvNow)+86400),\"server_time\":\(Int(srvNow)),\"expired\":false,\"active\":true,\"membership_state\":\"active\"}".utf8))
        try check(authProfile.serverTime != nil && abs(authProfile.serverTime!.timeIntervalSince1970 - srvNow) < 1,"server_time 按 Unix 秒解出")
        try check(authProfile.expired == false && !authProfile.serverSaysExpired,"expired=false 被正确识别为未过期")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u7\",\"paid_until\":\(Int(srvNow)+86400),\"expired\":true}".utf8)).serverSaysExpired,"本地未到期但服务端答 expired=true 时以服务端为准")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u8\",\"server_time\":\"2026-10-01T08:09:10Z\"}".utf8)).serverTime != nil,"server_time 也吃 ISO8601 串")
        let dirtyProfile = try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u9\",\"expired\":\"yes\",\"server_time\":\"not-a-date\"}".utf8))
        try check(dirtyProfile.expired == nil && dirtyProfile.serverTime == nil && !dirtyProfile.serverSaysExpired,"脏类型字段当未提供，不解码失败也不误判过期")
        var authSettings = Settings(); authSettings.licenseProfile = authProfile; authSettings.licenseLastServerTime = Date(timeIntervalSince1970:srvNow)
        let revivedAuth = try JSONDecoder().decode(Settings.self,from:JSONEncoder().encode(authSettings))
        try check(revivedAuth.licenseProfile?.expired == false && revivedAuth.licenseLastServerTime == authSettings.licenseLastServerTime,"权威结论与时间锚随设置落盘，重启后离线判定仍能识破拨时钟")
        // 会员纯逻辑：MembershipMath.extend
        let futureDue = now.addingTimeInterval(5*86400)
        try check(MembershipMath.extend(from:futureDue,now:now,days:30) == futureDue.addingTimeInterval(30*86400),"未到期续费从到期日顺延 30 天")
        let pastDue = now.addingTimeInterval(-3*86400)
        try check(MembershipMath.extend(from:pastDue,now:now,days:90) == now.addingTimeInterval(90*86400),"已过期续费从当前时间起算 90 天")
        try check(MembershipMath.extend(from:nil,now:now,days:365) == now.addingTimeInterval(365*86400),"无到期日从当前时间起算 365 天")
        // 会员纯逻辑：内置兜底套餐
        try check(PlanCatalog.fallback.count == 3,"兜底套餐共三档")
        try check(PlanCatalog.fallback[0].priceFen == 990 && PlanCatalog.fallback[0].days == 30,"月卡 990 分 / 30 天")
        try check(PlanCatalog.fallback[1].priceFen == 2690 && PlanCatalog.fallback[1].days == 90,"季卡 2690 分 / 90 天")
        try check(PlanCatalog.fallback[2].priceFen == 9900 && PlanCatalog.fallback[2].days == 365,"年卡 9900 分 / 365 天")
        try check(PlanCatalog.fallback.map(\.priceDisplay) == ["¥9.90","¥26.90","¥99"],"会员优惠价显示")
        // 会员档案：snake_case / camelCase 双兼容 + ISO8601
        let snakeJSON = Data("{\"account\":\"u1\",\"plan_label\":\"月卡\",\"paid_until\":\"2026-10-01T08:09:10Z\",\"days_left\":6,\"source\":\"trial\"}".utf8)
        let snakeProfile = try JSONDecoder().decode(MembershipProfile.self,from:snakeJSON)
        try check(snakeProfile.account == "u1" && snakeProfile.planLabel == "月卡" && snakeProfile.source == "trial","会员档案兼容 snake_case 字段")
        try check(snakeProfile.daysLeft == 6 && snakeProfile.paidUntil != nil,"days_left 与 ISO8601 paid_until 解析")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u2\",\"planLabel\":\"年卡\",\"source\":\"paid\"}".utf8)).planLabel == "年卡","会员档案兼容 camelCase 字段")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u3\",\"plan_label\":\"月卡\",\"paid_until\":\"2026-10-01T08:09:10.500Z\"}".utf8)).paidUntil != nil,"带小数秒的 ISO8601 也能解析")
        // 服务端 paid_until 是 Unix 秒数值（0=未开通），必须按 1970 纪元解析
        let unixFixed = 1798458000.0   // 2026-10-01 前后的 Unix 秒
        let unixProfile = try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u4\",\"paid_until\":\(Int(unixFixed)),\"source\":\"paid\"}".utf8))
        try check(unixProfile.paidUntil != nil && abs(unixProfile.paidUntil!.timeIntervalSince1970 - unixFixed) < 1,"服务端 Unix 秒 paid_until 按 1970 纪元解析")
        try check(abs(unixProfile.paidUntil!.timeIntervalSince(Date(timeIntervalSince1970: unixFixed))) < 1,"Unix 秒解析不偏移 31 年")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u5\",\"paid_until\":0}".utf8)).paidUntil == nil,"paid_until=0 视为未开通")
        var memberSettings = Settings(); memberSettings.licenseProfile = member
        try check(try JSONDecoder().decode(Settings.self,from:JSONEncoder().encode(memberSettings)).licenseProfile == member,"会员档案经设置存取保持一致")
        let legacyMemberSettings = try JSONDecoder().decode(Settings.self,from:legacySettings)
        try check(legacyMemberSettings.licenseProfile == nil && legacyMemberSettings.licenseServerURL == nil,"旧设置缺省会员字段可读")
        try check(legacyMemberSettings.licenseLastServerTime == nil,"旧设置无时间锚键时缺省 nil（兼容不报错）")
        var scoped = Settings(savedText: "旧文案")
        scoped.textTemplates = [TextTemplate(text: "旧文案")]
        scoped.preferredRecipientIDs = ["g1", "g2"]
        scoped.preferredAssetIDs = ["a1"]
        scoped.prepareWorkspaces(recipientIDs: ["g1", "g2", "g3"])
        try check(scoped.broadcastWorkspaces?.count == 3, "旧数据迁移为默认、推广、通知三个空间")
        try check(scoped.broadcastWorkspaces?.first?.draft.recipientIDs == ["g1", "g2"], "迁移保留旧选群，不自动全选")
        let promotionID = scoped.broadcastWorkspaces![1].id
        let noticeID = scoped.broadcastWorkspaces![2].id
        try scoped.switchWorkspace(promotionID)
        try check(scoped.savedText.isEmpty && scoped.preferredRecipientIDs == [] && scoped.preferredAssetIDs == [], "推广空间不会继承默认空间内容和群")
        scoped.textTemplates = [TextTemplate(text: "推广文案")]
        scoped.broadcastWorkspaces![1].draft.text = "推广文案"
        scoped.broadcastWorkspaces![1].draft.recipientIDs = ["g3"]
        scoped.broadcastWorkspaces![1].draft.assetIDs = ["a2"]
        try scoped.switchWorkspace(noticeID)
        try check(scoped.textTemplates == [] && scoped.preferredRecipientIDs == [], "通知空间不读取推广文案与群")
        try scoped.switchWorkspace(promotionID)
        try check(scoped.savedText == "推广文案" && scoped.preferredRecipientIDs == ["g3"] && scoped.preferredAssetIDs == ["a2"], "切回推广恢复独立图文和群选择")
        scoped.textTemplates![0].text = "尚未切换的修改"
        try scoped.switchWorkspace(promotionID)
        try check(scoped.textTemplates![0].text == "尚未切换的修改", "重复点击当前空间不会覆盖文案修改")
        let restoredSpaces = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(scoped))
        try check(restoredSpaces.activeWorkspaceID == promotionID && restoredSpaces.broadcastWorkspaces![1].draft.recipientIDs == ["g3"], "重启解码保留活动空间和独立草稿")
        try scoped.switchWorkspace("legacy")
        try check(scoped.savedText == "旧文案" && scoped.preferredRecipientIDs == ["g1", "g2"], "切回默认空间保留原内容")
        let ids = scoped.broadcastWorkspaces!.map(\.id)
        scoped.prepareWorkspaces(recipientIDs: [])
        try check(scoped.broadcastWorkspaces!.map(\.id) == ids, "迁移幂等，不重复生成空间")
        try rejects("不存在的空间不可切换") { try scoped.switchWorkspace("missing") }
        var taggedPlan = plan; taggedPlan.workspaceID = promotionID
        let restoredPlan = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(taggedPlan))
        try check(restoredPlan.workspaceID == promotionID, "发送计划持久保存来源空间")
        try check(plan.workspaceID == nil, "旧计划无空间字段时仍兼容")
        let retimed = try Scheduling.retimed(jobs, planID: plan.id, minutes: 10, now: now, globalGap: 5)
        try check(retimed[0].scheduled == jobs[0].scheduled && retimed[1].scheduled.timeIntervalSince(retimed[0].scheduled) == 600, "修改间隔保留未来首条并按10分钟重排")
        var protectedJobs = jobs; protectedJobs[0].status = "verified"; protectedJobs[0].submittedAt = now
        protectedJobs[1].status = "blocked"
        let protectedRetime = try Scheduling.retimed(protectedJobs, planID: plan.id, minutes: 60, now: now, globalGap: 5)
        try check(protectedRetime[0].scheduled == jobs[0].scheduled && protectedRetime[1].status == "blocked", "调整间隔不重发已发任务或恢复暂停任务")
        try check(protectedRetime[2].scheduled >= now.addingTimeInterval(3600), "同计划上次发送后等待新间隔")
        try rejects("拒绝零分钟") { _ = try Scheduling.retimed(jobs, planID: plan.id, minutes: 0, now: now, globalGap: 1) }
        try rejects("低于全局间隔须先调整全局") { _ = try Scheduling.retimed(jobs, planID: plan.id, minutes: 5, now: now, globalGap: 30) }
        // 走查 1-02：改间隔只重算「轮内」的先后距离，轮次边界与天数分布保持原样
        let retimeNoon = Scheduling.calendar.startOfDay(for: dailyJobs[0].scheduled).addingTimeInterval(12 * 3600)
        let restructured = try Scheduling.retimed(dailyJobs, planID: daily.id, minutes: 15, now: retimeNoon, globalGap: 5, plan: daily)
        try check(restructured.count == dailyJobs.count && restructured.map(\.id) == dailyJobs.map(\.id), "改间隔不增删任务，也不打乱数组顺序")
        try check(restructured[0].scheduled == retimeNoon, "已经落后的 09:00 轮从当下起按新 15 分钟重排")
        try check(restructured[1].scheduled.timeIntervalSince(restructured[0].scheduled) == 900, "轮内群间距改成新的 15 分钟")
        let round2Start = restructured.first { $0.scheduled == Scheduling.calendar.startOfDay(for: dailyJobs[0].scheduled).addingTimeInterval(14 * 3600) }
        try check(round2Start != nil, "当天 14:00 那轮仍从 14:00 开始，轮次边界没有被抹掉（走查 1-02）")
        try check(Set(restructured.map { Scheduling.calendar.startOfDay(for: $0.scheduled) }).count == 2, "重排后仍只占两天，天数分布不变")
        try check(Set(restructured.filter { Scheduling.calendar.isDate($0.scheduled, inSameDayAs: dailyJobs[0].scheduled) }.map { Scheduling.calendar.component(.hour, from: $0.scheduled) }).isSubset(of: [12, 13, 14, 15, 16, 19, 20, 21, 22, 23]), "第一天的任务只落在被顺延的时段与原有轮次里")
        try check(restructured.filter({ Scheduling.calendar.component(.hour, from: $0.scheduled) < 6 }).isEmpty, "改间隔不会把任务推进凌晨（走查 1-02）")
        let inferred = try Scheduling.retimed(dailyJobs, planID: daily.id, minutes: 15, now: retimeNoon, globalGap: 5)
        try check(inferred.map(\.scheduled) == restructured.map(\.scheduled), "拿不到计划对象时按排期推断轮次，结果与按计划重排一致")
        let flattenedRetime = try Scheduling.retimed(dailyJobs, planID: daily.id, minutes: 15, now: retimeNoon, globalGap: 5, preserveFutureStart: false)
        try check(flattenedRetime[24].scheduled < Scheduling.calendar.startOfDay(for: dailyJobs[24].scheduled), "显式 preserveFutureStart=false 才把第二天的任务拖到前一天，这是需要确认的旧口径")
        var gapPlan = daily; gapPlan.recipientGaps = [recipients[1].id: 60, recipients[3].id: 45]
        let gapJobs = try Scheduling.expand(gapPlan, recipients: recipients, assets: [], now: now)
        let gapRetime = try Scheduling.retimed(gapJobs, planID: gapPlan.id, minutes: 10, now: now, globalGap: 5, plan: gapPlan)
        try check(gapRetime[1].scheduled.timeIntervalSince(gapRetime[0].scheduled) == 3600, "逐群设过 60 分钟的群仍按自己的间隔排队")
        try check(gapRetime[2].scheduled.timeIntervalSince(gapRetime[1].scheduled) == 600, "没设逐群间隔的群按新的统一间隔")
        try check(gapRetime.filter { $0.scheduled == Scheduling.calendar.startOfDay(for: gapJobs[0].scheduled).addingTimeInterval(14 * 3600) }.count == 1, "逐群间隔重排后第二轮依旧从 14:00 起，轮次边界不丢")
        var late = jobs; late[0].status = "verified"; late[0].submittedAt = now; late[1].scheduled = now
        try check(Scheduling.eligible(late, now: now.addingTimeInterval(600), gap: 5, intervalByPlan: [plan.id:60]) == nil, "逾期补发仍遵守所设60分钟计划间隔")
        var sourceSettings = Settings(savedText: "旧正文")
        sourceSettings.prepareWorkspaces(recipientIDs: [])
        let liveSource = TextTemplate(text: "旧正文")
        sourceSettings.broadcastWorkspaces?[0].templates = [liveSource]
        var sourcePlan = plan; sourcePlan.workspaceID = "legacy"
        var sourceArchive = Archive(recipients: recipients, assets: [], plans: [sourcePlan], deliveries: jobs, settings: sourceSettings)
        sourceArchive = LiveMessage.linked(sourceArchive)
        try check(sourceArchive.plans[0].textTemplateID == liveSource.id, "旧版单文案计划建立稳定来源")
        sourceArchive.settings.broadcastWorkspaces?[0].templates[0].text = "新正文\n完整链接 https://example.com"
        for (index, status) in ["queued", "blocked", "running", "draft", "submitted", "uncertain", "verified", "manual"].enumerated() { sourceArchive.deliveries[index].status = status }
        let live = LiveMessage.refreshed(sourceArchive)
        try check(live.deliveries[0].text == live.plans[0].text && live.deliveries[1].text == live.plans[0].text, "保存同步待发及可重试任务")
        try check(Array(live.deliveries.dropFirst(2)).allSatisfy { $0.text == plan.text }, "保留正在处理待核对与已发正文")
        try check(live.deliveries.map(\.scheduled) == jobs.map(\.scheduled), "正文更新不更改排期")
        var otherSpace = sourceArchive; otherSpace.plans[0].workspaceID = "unrelated"
        try check(LiveMessage.refreshed(otherSpace).deliveries[0].text == plan.text, "来源同步不跨空间")
        var evidenced = sourceArchive; evidenced.deliveries[0].submittedAt = now; evidenced.deliveries[1].evidence = "receipt"
        try check(LiveMessage.refreshed(evidenced).deliveries[0].text == plan.text && LiveMessage.refreshed(evidenced).deliveries[1].text == plan.text, "已有提交凭据不得覆盖正文")
        var extendPlan = live.plans[0]; extendPlan.recipientIDs = Array(recipients.prefix(7).map(\.id))
        let appended = try Scheduling.additionalDeliveries(plan: extendPlan, recipients: [recipients[7]], jobs: Array(live.deliveries.prefix(7)), now: now, gap: 30)
        try check(appended.first?.text == live.plans[0].text, "新增群从最新计划读取正文而非历史队尾")
        let sourceDB = try Database(root: root.appendingPathComponent("source")); try sourceDB.save(live)
        try check(try sourceDB.load("plans", as: Plan.self)[0].textTemplateID == liveSource.id && sourceDB.load("deliveries", as: Delivery.self)[0].text == live.plans[0].text, "来源与新正文重启后仍保留")
        // 图文模板同步：保存并同步后，草稿配图刷新计划与未发送任务的附件快照
        do {
            let assetA = Asset(id:"asset-a", name:"旧图.png", relativePath:"assets/a/旧图.png", sha256:"a", bytes:1, isImage:true)
            let assetB = Asset(id:"asset-b", name:"新图.png", relativePath:"assets/b/新图.png", sha256:"b", bytes:2, isImage:true)
            var workspace = BroadcastWorkspace(id:"legacy", name:"默认群发")
            workspace.templates = [TextTemplate(text:"测试文字", assetIDs:[assetB.id])]
            var syncDraft = BroadcastDraft(); syncDraft.assetIDs = [assetB.id]
            workspace.draft = syncDraft
            var syncSettings = Settings(savedText: ""); syncSettings.broadcastWorkspaces = [workspace]
            let template = workspace.templates[0]
            var syncPlan = plan; syncPlan.workspaceID = "legacy"; syncPlan.textTemplateID = template.id; syncPlan.assetIDs = [assetA.id]
            var syncJobs = jobs
            syncJobs[0].assets = [assetA]
            var submitted = jobs[1]; submitted.status = "uncertain"; submitted.submittedAt = now; submitted.evidence = "已提交待核对"; submitted.assets = [assetA]
            var archived = jobs[2]; archived.status = "verified"; archived.assets = [assetA]
            syncJobs[1] = submitted; syncJobs[2] = archived
            let input = Archive(recipients:recipients, assets:[assetA, assetB], plans:[syncPlan], deliveries:syncJobs, settings:syncSettings)
            let refreshedArchive = LiveMessage.refreshed(input)
            try check(refreshedArchive.plans[0].assetIDs == [assetB.id], "图文同步刷新计划配图列表")
            try check(refreshedArchive.deliveries[0].assets == [assetB], "图文同步替换未发送任务附件快照")
            try check(refreshedArchive.deliveries[1].assets == [assetA], "已提交待核对任务的附件不被同步改写")
            try check(refreshedArchive.deliveries[2].assets == [assetA] && refreshedArchive.deliveries[2].status == "verified", "已核验历史任务保持原快照")
            var legacyWorkspace = BroadcastWorkspace(id:"legacy", name:"默认群发")
            legacyWorkspace.templates = [TextTemplate(text:"测试文字")]
            var legacySettings = Settings(savedText: ""); legacySettings.broadcastWorkspaces = [legacyWorkspace]
            let legacyInput = Archive(recipients:recipients, assets:[assetA], plans:[syncPlan], deliveries:syncJobs, settings:legacySettings)
            let legacyRefreshed = LiveMessage.refreshed(legacyInput)
            try check(legacyRefreshed.plans[0].assetIDs == [assetA.id] && legacyRefreshed.deliveries[0].assets == [assetA], "旧模板不启用配图同步时保持原快照")
        }
        do {
        // Display and dispatch share one exact cooldown calculation.
        var cooling = jobs
        cooling[0].status = "verified"; cooling[0].submittedAt = now.addingTimeInterval(7.535)
        cooling[1].scheduled = now
        let effective = Scheduling.earliestSendDate(cooling[1], jobs: cooling, gap: 30, intervalByPlan: [plan.id:30])
        try check(abs(effective.timeIntervalSince(now) - 1807.535) < 0.00001, "最早发送按实际提交时间加间隔，不显示过期排期")
        try check(Scheduling.eligible(cooling, now: effective.addingTimeInterval(-0.001), gap: 30, intervalByPlan: [plan.id:30]) == nil, "间隔截止前一毫秒不发送")
        try check(Scheduling.eligible(cooling, now: effective, gap: 30, intervalByPlan: [plan.id:30])?.id == cooling[1].id, "间隔到期即选中下一条")
        try check(Scheduling.nextCandidate(cooling, gap: 30, intervalByPlan: [plan.id:30])?.id == cooling[1].id, "界面下一群与调度候选一致")
        var independent = cooling[1]; independent.id = "other-plan-job"; independent.planID = "other-plan"
        let mixed = cooling + [independent]
        try check(Scheduling.nextCandidate(mixed, gap: 5, intervalByPlan: [plan.id:60])?.id == independent.id, "全局运行时其他已可发送计划不被更长计划冷却挡住")
        try check(Scheduling.nextCandidate(mixed, gap: 5, planID: plan.id, intervalByPlan: [plan.id:60])?.id == cooling[1].id, "指定计划不会跨计划发送")
        for state in ["running", "draft", "submitted", "uncertain"] {
            var held = cooling; held[0].status = state
            let candidate = Scheduling.eligible(held, now: effective, gap: 30)
            try check(state == "running" ? candidate == nil : candidate?.id == cooling[1].id,
                      state == "running" ? "有效时间到期仍不并发前台操作" : "冷却到期后跳过\(state)且不重发原记录")
        }
        var editable = cooling; editable[1].scheduled = now.addingTimeInterval(3600)
        let shortened = try Scheduling.retimed(editable, planID: plan.id, minutes: 5, now: now.addingTimeInterval(60), globalGap: 5, preserveFutureStart: false)
        let firstShort = shortened.filter { $0.status == "queued" }.min { $0.scheduled < $1.scheduled }!
        try check(abs(firstShort.scheduled.timeIntervalSince(now) - 307.535) < 0.00001, "已开始单轮缩短间隔按实际发送重新计算首条")
        try check(shortened[0].submittedAt == editable[0].submittedAt && shortened[0].scheduled == editable[0].scheduled, "热改间隔保留已发记录")
        let untouchedStart = try Scheduling.retimed(jobs, planID: plan.id, minutes: 5, now: now, globalGap: 5)
        try check(untouchedStart[0].scheduled == jobs[0].scheduled, "未开始计划仍保留未来首条")
        }
        var paced = plan; paced.recipientGaps = [recipients[1].id: 60]
        try check(Scheduling.paceMinutes(paced) == 30 && Scheduling.paceMinutes(plan) == 30, "计划底线取统一间隔，更长的逐群间隔另外保住")
        var lateFirst = jobs[0]
        lateFirst.scheduled = now; lateFirst.status = "verified"; lateFirst.submittedAt = now.addingTimeInterval(50 * 60)
        var lateSecond = jobs[1]
        lateSecond.scheduled = now.addingTimeInterval(60 * 60)
        let lateDue = Scheduling.earliestSendDate(lateSecond, jobs: [lateFirst, lateSecond], gap: 30, intervalByPlan: [plan.id: Scheduling.paceMinutes(paced)])
        try check(abs(lateDue.timeIntervalSince(now) - 80 * 60) < 0.001, "迟到后从实际发送起按当前30分钟间隔计时")
        try check(Scheduling.eligible([lateFirst, lateSecond], now: lateDue.addingTimeInterval(-0.001), gap: 30, intervalByPlan: [plan.id: 30]) == nil, "当前间隔到期前不提前发送")
        try check(Scheduling.eligible([lateFirst, lateSecond], now: lateDue, gap: 30, intervalByPlan: [plan.id: 30])?.id == lateSecond.id, "逐群间隔到点后才选中下一条")
        try check(Scheduling.nextCandidate([lateFirst, lateSecond], gap: 30, intervalByPlan: [plan.id: 30])?.id == lateSecond.id, "下一群与最早发送时间使用同一计算")
        var resumeJobs = [lateFirst, lateSecond]
        var third = lateSecond; third.id = "resume-third"; third.scheduled = now.addingTimeInterval(120 * 60)
        resumeJobs.append(third)
        let restart = now.addingTimeInterval(55 * 60)
        let restarted = Scheduling.restarted(resumeJobs, planID: plan.id, now: restart, gap: 5, intervalByPlan: [plan.id: 5])
        try check(restarted[0].submittedAt == lateFirst.submittedAt && restarted[0].scheduled == lateFirst.scheduled, "重新开始不修改已发记录")
        // 走查 1-01：默认口径只补发已经落后的任务，未来任务保持原计划时刻（旧口径见 compressFuture 对照）
        try check(restarted[1].scheduled == lateSecond.scheduled && restarted[2].scheduled == third.scheduled, "重新开始不拉近仍在未来的排期，保留原跨度（走查 1-01）")
        let compressedRestart = Scheduling.restarted(resumeJobs, planID: plan.id, now: restart, gap: 5, intervalByPlan: [plan.id: 5], compressFuture: true)
        try check(compressedRestart[1].scheduled == restart && compressedRestart[2].scheduled == restart.addingTimeInterval(300), "显式 compressFuture 才保留旧的连续重排口径")
        // 走查 1-01 主场景：一天三轮，只有已落后的轮次被拉到当下按间隔补发，后面的轮次与第二天原样保留
        var roundPlan = plan
        roundPlan.recipientIDs = [recipients[0].id]
        roundPlan.times = ["09:00", "14:00", "19:00"]
        roundPlan.days = 2
        roundPlan.starts = Scheduling.calendar.startOfDay(for: now).addingTimeInterval(86400)
        let roundJobs = try Scheduling.expand(roundPlan, recipients: recipients, assets: [], now: now)
        try check(roundJobs.count == 6 && roundJobs.map { Scheduling.calendar.component(.hour, from: $0.scheduled) } == [9, 14, 19, 9, 14, 19], "单群两天三轮生成六个轮次时刻")
        let midday = Scheduling.calendar.startOfDay(for: roundJobs[0].scheduled).addingTimeInterval(15 * 3600)
        let resumed = Scheduling.restarted(roundJobs, planID: roundPlan.id, now: midday, gap: 30, intervalByPlan: [roundPlan.id: 30])
        try check(resumed[0].scheduled == midday && resumed[1].scheduled == midday.addingTimeInterval(1800), "09:00 与 14:00 两轮已落后，启动时按 30 分钟间隔依次补发")
        try check(resumed[2].scheduled == roundJobs[2].scheduled, "当天 19:00 那轮仍在 19:00，不被压缩到补发序列后面")
        try check(Array(resumed.dropFirst(3)).map(\.scheduled) == Array(roundJobs.dropFirst(3)).map(\.scheduled), "第二天整轮排期一字未改（走查 1-01）")
        try check(resumed.allSatisfy { $0.scheduled >= midday }, "重排后不存在比当下更早的排期")
        var monthly = roundPlan; monthly.times = ["09:00"]; monthly.days = 30
        monthly.starts = Scheduling.calendar.startOfDay(for: now).addingTimeInterval(86400)
        let thirtyDays = try Scheduling.expand(monthly, recipients: recipients, assets: [], now: now)
        try check(thirtyDays.count == 30, "30 天每天一轮共 30 条待执行")
        let nightNow = Scheduling.calendar.startOfDay(for: thirtyDays[0].scheduled).addingTimeInterval(23 * 3600)
        let keptCadence = Scheduling.restarted(thirtyDays, planID: nil, now: nightNow, gap: 30, intervalByPlan: [:])
        try check(keptCadence.filter({ Scheduling.calendar.isDate($0.scheduled, inSameDayAs: thirtyDays[0].scheduled) }).count == 1, "30 天计划启动后每天仍只有一条任务")
        try check(keptCadence.dropFirst().allSatisfy { Scheduling.calendar.component(.hour, from: $0.scheduled) == 9 }, "其余 29 天的 09:00 时刻保持不变，不会凌晨连续补发（走查 1-01）")
        let flattened = Scheduling.restarted(thirtyDays, planID: nil, now: nightNow, gap: 30, intervalByPlan: [:], compressFuture: true)
        try check(flattened[1].scheduled.timeIntervalSince(flattened[0].scheduled) == 1800 && Scheduling.calendar.component(.hour, from: flattened[5].scheduled) != 9, "旧的压缩口径才会把 30 天压成当晚连续补发，只能显式选用")
        var tiedFirst = jobs[0]; tiedFirst.id = "z-first-in-plan"; tiedFirst.scheduled = now
        var tiedSecond = jobs[1]; tiedSecond.id = "a-second-in-plan"; tiedSecond.scheduled = now
        let tied = [tiedFirst, tiedSecond]
        try check(Scheduling.nextCandidate(tied, gap: 5)?.id == tiedFirst.id, "同一时刻的下一群沿用计划保存顺序，不按随机 UUID 排序")
        let tiedRestarted = Scheduling.restarted(tied, planID: plan.id, now: now, gap: 5, intervalByPlan: [plan.id: 5])
        try check(tiedRestarted[0].scheduled == now && tiedRestarted[1].scheduled == now.addingTimeInterval(300), "立即开始遇到同时间任务时保持群聊原始顺序")
        try check(Scheduling.ordered(tied).map(\.recipient) == [tiedFirst.recipient, tiedSecond.recipient], "队列展示顺序与启动次序对同时间群聊保持一致")
        var attemptedQueued = tiedFirst
        attemptedQueued.submittedAt = now
        attemptedQueued.scheduled = now.addingTimeInterval(-3600)
        try check(Scheduling.nextCandidate([attemptedQueued, tiedSecond], gap: 0)?.id == tiedSecond.id, "立即开始不选已有提交记录的待执行任务")
        let skippedRestart = Scheduling.restarted([attemptedQueued, tiedSecond], planID: plan.id, now: now, gap: 5, intervalByPlan: [plan.id: 5])
        try check(skippedRestart[0].scheduled == attemptedQueued.scheduled, "重新开始不改写已有提交记录的排期")
        try check(skippedRestart[1].scheduled == now.addingTimeInterval(300), "重新开始把下一条排到已提交时刻加间隔之后，不贴脸连发（走查 1-01）")
        let skippedRetime = try Scheduling.retimed([attemptedQueued, tiedSecond], planID: plan.id, minutes: 5, now: now, globalGap: 5, preserveFutureStart: false)
        try check(skippedRetime[0].scheduled == attemptedQueued.scheduled, "点击启动时若顺带应用间隔，也不改写已有提交记录的排期")
        var evidenceQueued = tiedFirst
        evidenceQueued.evidence = "已有发送证据"
        try check(Scheduling.nextCandidate([evidenceQueued, tiedSecond], gap: 0)?.id == tiedSecond.id, "已有发送凭据即使状态异常回到待执行也不自动重发")
        var delayedByPlan = tiedFirst
        delayedByPlan.id = "earlier-on-clock"
        delayedByPlan.scheduled = now.addingTimeInterval(-120)
        var dueSooner = tiedSecond
        dueSooner.id = "earlier-in-queue"
        dueSooner.planID = "other-plan"
        dueSooner.scheduled = now.addingTimeInterval(300)
        var recentInPlan = jobs[2]
        recentInPlan.status = "verified"
        recentInPlan.finished = now
        let mixedPlans = [delayedByPlan, dueSooner, recentInPlan]
        let mixedPaces = [plan.id: 30, "other-plan": 5]
        try check(Scheduling.nextCandidate(mixedPlans, gap: 0, intervalByPlan: mixedPaces)?.id == dueSooner.id, "跨计划时预览按实际可执行时间选群")
        try check(Scheduling.nextCandidate(mixedPlans, gap: 0, allowedPlanIDs: [plan.id], intervalByPlan: mixedPaces)?.id == delayedByPlan.id, "空间范围内的默认计划只从本空间选下一群")
        let restartedMixed = Scheduling.restarted(mixedPlans, planID: nil, now: now, gap: 0, intervalByPlan: mixedPaces)
        // 走查 1-01：启动只把排期往后推到自己「真正能发」的时刻，不压成从点击起连续的队列
        try check(restartedMixed[1].scheduled == dueSooner.scheduled, "另一计划的首群保持自身排期，不被拉到点击时刻（走查 1-01）")
        try check(restartedMixed[0].scheduled == Scheduling.earliestSendDate(delayedByPlan, jobs: mixedPlans, gap: 0, intervalByPlan: mixedPaces), "落后任务按本计划 30 分钟冷却顺延，而不是按全局间隔连排")
        try check(Scheduling.nextCandidate(restartedMixed, gap: 0, intervalByPlan: mixedPaces)?.id == dueSooner.id, "重排后预览选出的首群不变，启动校验仍对得上")
        let compressedMixed = Scheduling.restarted(mixedPlans, planID: nil, now: now, gap: 0, intervalByPlan: mixedPaces, compressFuture: true)
        try check(compressedMixed[1].scheduled == now && compressedMixed[0].scheduled == now.addingTimeInterval(300), "显式压缩口径下仍先重排预览显示的群")
        var firstNow = resumeJobs
        firstNow[1].status = "verified"; firstNow[1].submittedAt = restart.addingTimeInterval(8)
        firstNow[2].scheduled = restart.addingTimeInterval(100)   // 旧排期排在「提交+间隔」之前
        let nextDue = Scheduling.earliestSendDate(firstNow[2], jobs: firstNow, gap: 5, intervalByPlan: [plan.id: 5])
        try check(nextDue == restart.addingTimeInterval(308), "首群实际提交后再计5分钟，不叠加旧排期")
        var manualSend = jobs[0]
        manualSend.status = "manual"; manualSend.started = nil; manualSend.submittedAt = nil; manualSend.finished = now
        try check(Scheduling.lastSendActivity([manualSend]) == now, "人工确认已发送占用冷却")
        var cancelledEarly = jobs[0]
        cancelledEarly.status = "cancelled"; cancelledEarly.started = now; cancelledEarly.submittedAt = nil
        try check(Scheduling.lastSendActivity([cancelledEarly]) == nil, "取消尚未提交的任务不占用冷却")
        let point = CGPoint(x: 10, y: 10)
        let area = CGRect(x: 0, y: 0, width: 80, height: 80)
        let target = ClickCover.Window(ownerPID: 1, layer: 0, alpha: 1, bounds: area, regular: true, name: "QQ")
        let own = ClickCover.Window(ownerPID: 2, layer: 0, alpha: 1, bounds: area, regular: true, name: "QQ排程助手")
        let overlay = ClickCover.Window(ownerPID: 3, layer: 0, alpha: 1, bounds: area, regular: false, name: "辅助浮层")
        let menu = ClickCover.Window(ownerPID: 4, layer: 25, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 80, height: 24), regular: false, name: "菜单栏")
        let invisible = ClickCover.Window(ownerPID: 2, layer: 0, alpha: 0, bounds: area, regular: true, name: "QQ排程助手")
        let tip = ClickCover.Window(ownerPID: 5, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 20, height: 20), regular: false, name: "提示")
        try check(ClickCover.blocker(at: point, windows: [target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "目标窗口在最前时允许点击")
        try check(ClickCover.blocker(at: point, windows: [own, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "QQ排程助手", "自己的窗口挡住目标时拒绝点击")
        try check(ClickCover.blocker(at: point, windows: [overlay, own], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "辅助浮层", "浮层不能把点击放行到后面的窗口")
        try check(ClickCover.blocker(at: point, windows: [menu, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "菜单栏层级不挡住目标窗口")
        try check(ClickCover.blocker(at: point, windows: [invisible, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "全透明窗口不挡住目标")
        try check(ClickCover.blocker(at: point, windows: [tip, own], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "QQ排程助手", "小提示层后面的本程序窗口仍然拒绝点击")
        // 走查 1-19：非零层级的浮窗不能把点击放行到后面的窗口；负层级（桌面/背衬）仍不算遮挡
        let panel = ClickCover.Window(ownerPID: 6, layer: 8, alpha: 1, bounds: area, regular: true, name: "截图面板")
        try check(ClickCover.blocker(at: point, windows: [panel, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "截图面板", "第三方常规浮窗挡住落点时如实报出，不再因层级非零被跳过（走查 1-19）")
        let desktop = ClickCover.Window(ownerPID: 7, layer: -2147483633, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 4000, height: 4000), regular: false, name: "Dock")
        try check(ClickCover.blocker(at: point, windows: [target, desktop], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "目标窗口在最前时负层级桌面不参与判断")
        try check(ClickCover.blocker(at: point, windows: [desktop], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "只有桌面背衬时不算被其他应用挡住，避免误报")
        let qqPanel = ClickCover.Window(ownerPID: 1, layer: 3, alpha: 1, bounds: area, regular: false, name: "QQ 悬浮窗")
        try check(ClickCover.blocker(at: point, windows: [qqPanel, own], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "QQ 自己的悬浮面板接到点击就不算被挡住")
        let shadow = ClickCover.Window(ownerPID: 8, layer: 25, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 30, height: 30), regular: false, name: "")
        try check(ClickCover.blocker(at: point, windows: [shadow, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "尺寸不足的小窗口仍放行，维持原有噪声过滤")
        try check(ConversationMatch.resultTitle(texts: ["群聊", "2026中国石油大学", "2026中国石油大学克拉玛依校区二手群（六）"], query: "2026中国石油大学克拉玛依校区二手群（六）") == "2026中国石油大学克拉玛依校区二手群（六）", "搜索行标题取完整群名而不是高亮片段")
        try check(ConversationMatch.headerMatches(candidates: ["2026中国石油大学克拉玛依校区二手群（六）"], title: "2026中国石油大学克拉玛依校区二手群（六）"), "完整标题可以绑定会话")
        try check(ConversationMatch.headerMatches(candidates: ["2026中国石油大学克拉玛依校区二手群（六）"], title: "2026中国石油大学"), "高亮前缀仍能识别完整标题")
        try check(!ConversationMatch.headerMatches(candidates: ["其他群聊窗口"], title: "群聊"), "群聊标签不能当成会话标题")
        try check(!ConversationMatch.headerMatches(candidates: ["2026中国石油大学交流群"], title: "石油"), "过短片段不能含混匹配另一个群")
        // 输入框的 AXDescription 才是“这个 composer 属于哪个会话”的证据；切换会话时它会滞后于标题栏
        try check(ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "CUPK-二手交易群（四）"),"输入框标注与刚选中的会话一致才允许粘贴/发送")
        try check(ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "【CUPK-二手交易群（四）】5群"),"标注带前后缀仍能认出同一个会话")
        try check(!ConversationMatch.composerBelongs(to: "CUPK二手市场（三）", description: "CUPK二手市场（五）"),"名字仅差群序号时也必须视为不同输入框")
        try check(!ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "中国石油大学克拉玛依校区2026级新生交流群"),"标题栏已切换但输入框仍写着别的会话时判为不匹配")
        try check(!ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: ""),"读不到输入框标注时按不匹配处理，交给短暂重试后中止")
        try check(!ConversationMatch.composerBelongs(to: "", description: "任意"),"没有绑定会话名时不允许粘贴")
        try check(ConversationMatch.composerBelongs(to: "我的手机", description: "我的手机"),"自己设备会话同样按输入框标注绑定")
        try check(ConversationMatch.exactly("CUPK-二手交易群（四）", "CUPK-二手交易群（四）"),"人工续发要求收件群名逐字相同")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（四）", "CUPK-二手交易群（四）5"),"多一个字都不算同一个会话")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（三）", "CUPK-二手交易群（四）"),"中文数字三与四不得含混匹配")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（四）", ""),"读不到输入框标注时判为不匹配")
        try check(!ConversationMatch.exactly("  ", "CUPK-二手交易群（四）"),"空白标注不算匹配")
        // 走查 1-05：搜索定位仍宽松，发送前的身份绑定统一走严格口径
        let inputName = "Vibecoding AIGC 交流群"
        try check(ConversationMatch.resultTitle(texts: ["群聊", "Vibecoding AIGC 交流群2"], query: inputName) == "Vibecoding AIGC 交流群2", "搜索定位仍按第一条结果取实际会话名，不做精确匹配")
        try check(ConversationMatch.headerMatches(candidates: ["Vibecoding AIGC 交流群2"], title: inputName), "连续性核对沿用宽松口径，既有调用点行为不变")
        try check(!ConversationMatch.headerMatches(candidates: ["Vibecoding AIGC 交流群2"], title: inputName, looseContains: false), "关掉宽松包含后，超集群名判为不同会话（走查 1-05）")
        try check(!ConversationMatch.identityBound(candidates: ["Vibecoding AIGC 交流群2"], title: inputName), "发送前的身份绑定与人工续发同为逐字相等")
        try check(ConversationMatch.identityBound(candidates: ["  Vibecoding AIGC 交流群 "], title: inputName), "身份绑定只去首尾空白，其余一字不差才算同一个会话")
        try check(!ConversationMatch.identityBound(candidates: ["【Vibecoding AIGC 交流群】总群"], title: inputName), "带装饰的另一个群同样不能绑定")
        try check(!ConversationMatch.composerBelongs(to: inputName, description: "Vibecoding AIGC 交流群2", looseContains: false), "输入框标注是超集时，严格口径判为别的会话")
        try check(ConversationMatch.bindingDivergence(input: inputName, selectedTitle: inputName) == nil, "输入名与实际进入的会话一致时不报差异")
        let superset = ConversationMatch.bindingDivergence(input: inputName, selectedTitle: "Vibecoding AIGC 交流群2")
        try check(superset?.contains("实际进入会话为「Vibecoding AIGC 交流群2」") == true && superset?.contains("疑似同名系列群") == true, "超集群名给出不可自洽的差异说明（走查 1-05）")
        try check(ConversationMatch.bindingDivergence(input: "CUPK-二手交易群（四）", selectedTitle: "CUPK-二手交易群（五）")?.contains("不同") == true, "仅差群序号时也要如实交代不是同一个会话")
        try check(ConversationMatch.bindingDivergence(input: "CUPK-二手交易群（四）", selectedTitle: "CUPK-二手交易群")?.contains("更短") == true, "进入的会话名比输入名更短时同样判为不同")
        try check(ConversationMatch.bindingDivergence(input: inputName, selectedTitle: "")?.contains("未能读取") == true, "读不到会话标题时按差异处理，不静默通过")
        try check(ConversationMatch.bindingDivergence(input: "", selectedTitle: inputName) == nil, "记录里没有输入名时无从比对，不额外报错")
        let divergence = ConversationMatch.bindingDivergence(input: inputName, selectedTitle: "Vibecoding AIGC 交流群2") ?? ""
        let divergedDetail = SendChannel.bindingDivergenceDetail(channel: SendChannel.qq, divergence: divergence, previous: "步骤：已粘贴正文与配图")
        try check(divergedDetail.contains("已停止，不发送") && divergedDetail.contains("原先记录：") && divergedDetail.contains("已粘贴正文与配图"), "差异记录转人工核对并保留此前已执行到哪一步")
        try check(SendChannel.bindingDivergenceNote(divergence).contains("不会自动重发"), "差异说明写明不会自动重发")
        // 一次性草稿任务：只有草稿模式能容忍未确认图片，且不参与排期派发、不得重复开单
        try check(DraftTolerance.toleratesUnconfirmedImage(mode: "draft"),"只填写不发送的草稿任务可以带着未确认图片继续")
        try check(!DraftTolerance.toleratesUnconfirmedImage(mode: "automatic"),"自动发送任务图片确认不了必须停住")
        var oneOffClone = jobs[0]; oneOffClone.id = "one-off-clone"; oneOffClone.mode = "draft"
        oneOffClone.status = "queued"; oneOffClone.oneOff = true; oneOffClone.cloneOf = jobs[1].id
        try check(Scheduling.nextCandidate([oneOffClone], gap: 0) == nil,"一次性草稿任务不会被排期派发选中")
        try check(Scheduling.eligible([oneOffClone], now: Date(timeIntervalSince1970: 2_000_000_000), gap: 0) == nil,"启动队列也不会替它发送")
        var queueWithClone = jobs; queueWithClone[0].status = "verified"; queueWithClone[1].status = "verified"
        try check(Scheduling.nextCandidate(queueWithClone + [oneOffClone], gap: 0)?.id != "one-off-clone","正常任务里也不会被顺手夹带")
        try check(Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [oneOffClone]),"同一来源未出结果前不能再开一张")
        var blockedClone = oneOffClone; blockedClone.status = "blocked"
        try check(!blockedClone.canRequeue && !blockedClone.canRenameRecipient,"失败的一次性草稿记录不可重新入队或改名")
        try check(Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [blockedClone]),"补草稿失败记录未核对前不能从来源重复开单")
        var cloneDone = oneOffClone; cloneDone.status = "verified"
        try check(!Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [cloneDone]),"上一张已出结果，允许再开")
        var abandoned = oneOffClone; abandoned.status = "cancelled"
        try check(!Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [abandoned]),"取消掉的算已处理")
        try check(!Scheduling.hasUnresolvedClone(of: jobs[2].id, in: [oneOffClone]),"别的来源任务不受影响")
        // 旧库里没有 oneOff / cloneOf 这两个新键，必须照样能解码
        let legacyRow = "{\"id\":\"legacy\",\"planID\":\"p\",\"planName\":\"n\",\"recipient\":\"群\",\"text\":\"正文\",\"assets\":[],\"scheduled\":1,\"mode\":\"automatic\",\"status\":\"blocked\",\"detail\":\"旧记录\",\"evidence\":\"\"}"
        let decodedLegacy = try JSONDecoder().decode(Delivery.self, from: Data(legacyRow.utf8))
        try check(!decodedLegacy.isOneOff && decodedLegacy.cloneOf == nil,"旧库记录缺少新字段仍能解码，不会被误判为一次性任务")
        try check(ForegroundRecovery.decision(frontPID: 10, targetPID: 10, selfPID: 20) == .targetIsFront, "QQ 仍在前台时图片轮询不抢焦点")
        try check(ForegroundRecovery.decision(frontPID: 20, targetPID: 10, selfPID: 20) == .recoverOwnApp, "只有本 App 自己占前台时才允许把 QQ 唤回")
        try check(ForegroundRecovery.decision(frontPID: 20, targetPID: 10, selfPID: 20) == .recoverOwnApp && ForegroundRecovery.decision(frontPID: 30, targetPID: 10, selfPID: 20) == .stop, "点程序坞把本程序带到前面时先交回 QQ；别的应用占前台仍然停止")
        try check(ForegroundRecovery.decision(frontPID: 20, targetPID: 11, selfPID: 20) == .recoverOwnApp && ForegroundRecovery.decision(frontPID: 30, targetPID: 11, selfPID: 20) == .stop, "微信发送同样只在本程序占前台时交回微信，别的应用占前台仍然停止")
        try check(ForegroundRecovery.decision(frontPID: 30, targetPID: 10, selfPID: 20) == .stop, "其他应用占前台必须停止，不能抢回焦点")
        try check(ForegroundRecovery.decision(frontPID: nil, targetPID: 10, selfPID: 20) == .stop, "读不到前台应用时停止，不猜测")
        try check(ForegroundRecovery.decision(frontPID: 10, targetPID: 10, selfPID: 10) == .targetIsFront, "前台就是目标进程时不走自愈")
        try check(ForegroundHandoff.action(frontPID: 10, targetPID: 10, selfPID: 20) == .uncoverTarget, "QQ 已在前台时只把自己的窗口移开")
        try check(ForegroundHandoff.action(frontPID: 20, targetPID: 10, selfPID: 20) == .yieldToTarget, "本程序占前台时把激活权直接交给 QQ")
        try check(ForegroundHandoff.action(frontPID: 30, targetPID: 10, selfPID: 20) == .stop, "其他应用占前台时既不抢焦点也不把窗口打到后面")
        try check(ForegroundHandoff.mayOrderBackOwnWindows(.yieldToTarget) == false, "本程序还在前台时 orderBack 会把其他应用送到前面")
        try check(ForegroundHandoff.mayOrderBackOwnWindows(.uncoverTarget) == false, "QQ 已在前台也不 orderBack，否则夹在中间的 Chrome 会盖住搜索下拉")
        try check(ForegroundHandoff.mayOrderBackOwnWindows(.stop) == false, "其他应用在前台时不允许 orderBack")
        try check(ForegroundHandoff.observedFrontPID(live: 30, cached: 10) == 30, "实时窗口列表优先于 NSWorkspace 缓存")
        try check(ForegroundHandoff.observedFrontPID(live: nil, cached: 10) == 10, "读不到实时前台时才退回缓存")
        // 前台异常细分（P3）：目标被最小化（无任何可见窗口）时，窗口列表会把排在后面的应用读成“最前”，
        // 不能再把这种失败写成“前台已切换到无辜应用”。
        try check(ForegroundAnomaly.classify(frontPID: 10, targetPID: 10, targetHasVisibleWindow: true) == .targetIsFront, "目标在前台仍然通过，判定边界不变")
        try check(ForegroundAnomaly.classify(frontPID: 30, targetPID: 10, targetHasVisibleWindow: false) == .targetHasNoVisibleWindow, "目标没有任何可见窗口时归为“没有可见窗口”，不点名排在其后的应用")
        try check(ForegroundAnomaly.classify(frontPID: 30, targetPID: 10, targetHasVisibleWindow: true) == .otherAppFront, "目标有可见窗口而前台是别的应用，才报“前台已切换”")
        try check(ForegroundAnomaly.classify(frontPID: nil, targetPID: 10, targetHasVisibleWindow: false) == .frontUnknown, "读不到前台时归为“无法读取前台”，不再借别应用的名字凑文案")
        try check(!ForegroundAnomaly.hasVisibleWindow(targetPID: 10, rows: [.init(ownerPID: 10, layer: 25, width: 300, height: 200), .init(ownerPID: 30, layer: 0, width: 800, height: 600)])
                  && ForegroundAnomaly.hasVisibleWindow(targetPID: 10, rows: [.init(ownerPID: 10, layer: 0, width: 300, height: 200)]),
                  "普通层（layer 0）且非退化尺寸才算目标可见窗口：状态项/菜单条等非 0 层不算")
        try check(QQSearchLayout.alwaysCommitSearchWithKeystrokes, "AX 设值成功也要再粘贴一次，否则 QQ NT 不会检索")
        try check(QQSearchLayout.isCompactResultHeight(48) && !QQSearchLayout.isCompactResultHeight(400), "结果行是矮条，整片下拉容器不是")
        try check(QQSearchLayout.preferredClickIndex(heights: [400, 56, 56]) == 1, "点第一条矮行，不点包住整片下拉的 Group")
        try check(QQSearchLayout.preferredClickIndex(heights: [48]) == 0, "只有一行时就点这一行")
        let ntRows = [
            QQSearchLayout.Sibling(role: "AXGroup", name: "", hasNestedRow: false, hasText: false),
            QQSearchLayout.Sibling(role: "AXGroup", name: "中国石油大学克拉玛依校区2026级新生交流群", hasNestedRow: false, hasText: true),
            QQSearchLayout.Sibling(role: "AXStaticText", name: "聊天记录", hasNestedRow: false, hasText: true),
        ]
        try check(QQSearchLayout.firstOpenableIndex(afterGroupHeading: ntRows) == 1, "NT 搜索下拉第一行是带群名的 Group，不是 AXMenuItem")
        let menuRows = [
            QQSearchLayout.Sibling(role: "AXMenuItem", name: "CUPK-二手交易群（二）", hasNestedRow: false, hasText: true),
            QQSearchLayout.Sibling(role: "AXStaticText", name: "好友", hasNestedRow: false, hasText: true),
        ]
        try check(QQSearchLayout.firstOpenableIndex(afterGroupHeading: menuRows) == 0, "旧版下拉仍取第一条 AXMenuItem")
        let nextCategoryFirst = [
            QQSearchLayout.Sibling(role: "AXStaticText", name: "聊天记录", hasNestedRow: false, hasText: true),
            QQSearchLayout.Sibling(role: "AXGroup", name: "某条聊天记录", hasNestedRow: false, hasText: true),
        ]
        try check(QQSearchLayout.firstOpenableIndex(afterGroupHeading: nextCategoryFirst) == nil, "下一分类标题出现时不再取后面的行")
        let skipChrome = [
            QQSearchLayout.Sibling(role: "AXButton", name: "清空", hasNestedRow: false, hasText: true),
            QQSearchLayout.Sibling(role: "AXGroup", name: "石油学院班长团支书群", hasNestedRow: false, hasText: true),
        ]
        try check(QQSearchLayout.firstOpenableIndex(afterGroupHeading: skipChrome) == 1, "搜索框上的清空按钮不是群聊结果")
        try check(MainWindowOpen.activatesOverTarget(busy: false, running: false) && MainWindowOpen.title(busy: false, running: false) == "打开 QQ排程助手", "空闲时打开主窗口可以带到前面")
        try check(!MainWindowOpen.activatesOverTarget(busy: false, running: true) && MainWindowOpen.title(busy: false, running: true) == "打开窗口（不抢前台）", "队列运行时打开窗口不把 QQ 挤离前台")
        try check(!MainWindowOpen.activatesOverTarget(busy: true, running: false), "单条任务进行中同样不抢前台")
        try check(!PausePoint.shouldPoll(at: 0) && !PausePoint.shouldPoll(at: 24) && PausePoint.shouldPoll(at: 25) && PausePoint.shouldPoll(at: 50), "长树每 25 个节点看一次暂停，开头不额外让出")
        try check(PausePoint.isStop("已停止。请检查微信中是否留有草稿或已提交的消息"), "微信暂停文案算用户停止")
        try check(!PausePoint.isStop("当前会话标题与目标不一致：群。已停止，不发送"), "标题对不上里的已停止不是用户点的暂停")
        try check(!PauseControl.available(busy: false, running: false) && PauseControl.menuHint(busy: false, running: false) == nil, "空闲时不提示暂停")
        try check(PauseControl.available(busy: true, running: false), "单条补草稿或续发时菜单栏暂停也要能点")
        let hint = PauseControl.menuHint(busy: false, running: true, appName: "QQ")
        try check(hint == "要停下请点这里的「暂停全部」，或按 ⌘.。主窗口可能在QQ后面。", "QQ 发送时说明窗口可能在 QQ 后面")
        try check(PauseControl.menuHint(busy: true, running: false, appName: "微信") == "要停下请点这里的「暂停全部」，或按 ⌘.。主窗口可能在微信后面。", "微信发送时暂停提示指向微信")
        try check(PauseControl.menuHint(busy: true, running: false, appName: "  ") == "要停下请点这里的「暂停全部」，或按 ⌘.。主窗口可能在QQ后面。", "没有应用名时暂停提示仍按 QQ")
        try check(ComposeFooterStatus.line(busy: false, running: false) == "草稿已保存 · 可以预览或启动", "空闲时新建页底栏可以预览或启动")
        try check(ComposeFooterStatus.line(busy: false, running: true) == "其他队列运行中 · 可以保存、预览或启动新的独立队列", "其他队列运行但通道空闲时，新建页正确说明独立队列可启动")
        let runningBusy = ComposeFooterStatus.line(busy: true, running: true)
        try check(runningBusy == "队列运行中 · 当前操作进行中 · 可预览", "队列运行且当前操作占着时，底栏仍写运行中，只承诺预览")
        try check(runningBusy.contains("运行中") && runningBusy.contains("可预览") && !runningBusy.contains("仅保存") && !runningBusy.contains("启动"), "运行且忙碌不承诺仅保存或启动")
        let pausedBusy = ComposeFooterStatus.line(busy: true, running: false)
        try check(pausedBusy == "队列已暂停 · 当前操作进行中 · 可预览", "只忙碌、队列暂停时，底栏与侧栏一样写已暂停，并只承诺预览")
        try check(!pausedBusy.contains("运行中") && !pausedBusy.contains("仅保存") && !pausedBusy.contains("启动"), "暂停中的忙碌不写成运行中，也不承诺仅保存或启动")
        try check(QueueStartGate.refusal(statuses: ["queued", "blocked", "verified", "manual", "cancelled"]) == nil, "已拦截和待执行不挡启动，不用先清掉失败记录")
        let oneUncertain = QueueStartGate.refusal(statuses: ["queued", "uncertain"])
        try check(oneUncertain == nil, "有结果待核对时仍可启动后续待执行任务")
        try check(QueueStartGate.reviewCount(["draft", "submitted", "uncertain", "blocked"]) == 3, "草稿、已提交和待核对独立统计，已拦截不并入核对")
        try check(QueueStartGate.blockingStatuses.isEmpty && QueueStartGate.blockingCount(["draft", "submitted", "uncertain"]) == 3,
                  "兼容待核对统计仍保留，但不再有阻止启动的核对状态")
        try check(QueueStartGate.refusal(statuses: []) == nil, "没有记录时可以直接启动")
        try check(QueueStartGate.menuTitle(statuses: ["queued", "blocked"]) == "启动队列", "没有待核对时，菜单仍叫启动队列")
        try check(QueueStartGate.menuTitle(statuses: ["uncertain", "queued"]) == "启动队列", "有待核对时菜单仍可启动后续待执行")
        try check(QueueStartGate.menuTitle(statuses: ["draft", "submitted"]) == "启动队列", "草稿和已提交不替换启动命令")
        try check(!QueueStartGate.replacesStart(statuses: ["uncertain", "queued"], running: false), "有待核对时仍保留立即开始入口")
        try check(!QueueStartGate.replacesStart(statuses: ["queued"], running: false), "没有待核对时队列页仍是立即开始")
        try check(!QueueStartGate.replacesStart(statuses: ["uncertain"], running: true), "队列已在运行时不改启动按钮")
        try check(QueueStartGate.createdStep(count: 2, statuses: ["queued", "uncertain"]) == "已创建 2 条任务；点击启动队列执行", "已有待核对时新建计划仍可直接启动")
        try check(QueueStartGate.createdStep(count: 2, statuses: ["queued", "queued"]) == "已创建 2 条任务；点击启动队列执行", "没有待核对时，新建计划仍提示可以启动")
        let reviewEmpty = QueueStartGate.emptySchedule(statuses: ["uncertain", "submitted"])
        try check(reviewEmpty.needsReview && reviewEmpty.title == "当前没有待执行排期" && reviewEmpty.message == "有 2 条结果留在发送记录，可稍后核对；这些记录不会自动重发。", "没有待执行时如实保留待核对提示，不要求先核对再启动")
        let pausedEmpty = QueueStartGate.emptySchedule(statuses: ["blocked"])
        try check(!pausedEmpty.needsReview && pausedEmpty.message == "有 1 条已拦截。确认没发出、草稿已处理后可以重新入队。", "只有已拦截时才提示可以重新入队")
        try check(QueueStartGate.emptySchedule(statuses: []).message == "可添加群到本计划，或到新建发送编排下一次。", "计划是空的时提示去新建或添加群")
        try check(QueueStartGate.pausedCount(["blocked", "blocked", "uncertain"]) == 2, "已拦截单独计数，不并进待核对")

    // MARK: 状态词表与战报口径收尾（走查 2026-10-06）
    do {
        let cal = Scheduling.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 0))!
        var draftJob = jobs[0]; draftJob.status = "draft"
        try check(draftJob.statusName == "未发送", "draft 状态统一显示「未发送」（此前列表未发送、详情草稿两名）")
        var queuedZombie = jobs[0]; queuedZombie.status = "queued"; queuedZombie.submittedAt = now
        try check(queuedZombie.statusName == "待执行" && queuedZombie.listGuidance != nil, "queued 带提交痕迹状态词不变，但 listGuidance 指引去核对")
        // 战报把 queued+submittedAt 归入待核对，待执行不再虚高
        let zombieReport = DailySendReport.today(deliveries: [queuedZombie], planNames: ["p": "僵尸计划"], now: now, calendar: cal)
        try check(zombieReport.pendingReview == 1 && zombieReport.queued == 0, "queued+submittedAt 战报计入待核对而非待执行")
        var queuedClean = jobs[0]; queuedClean.status = "queued"; queuedClean.submittedAt = nil
        let cleanReport = DailySendReport.today(deliveries: [queuedClean], planNames: ["p": "正常计划"], now: now, calendar: cal)
        try check(cleanReport.queued == 1 && cleanReport.pendingReview == 0, "无提交痕迹的 queued 仍按待执行计")
    }

    // MARK: 批量取消撤销窗（RecordUndo）
    do {
        let cal = Scheduling.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 0))!
        func snap(_ id: String, status: String, submitted: Bool = false, evidence: String = "") -> Delivery {
            var d = jobs[0]
            d.id = id; d.status = status; d.submittedAt = submitted ? now : nil; d.evidence = evidence
            return d
        }
        let snapshot = [snap("u-1", status: "queued"), snap("u-2", status: "queued"), snap("u-3", status: "queued")]
        // 快照=取消前的原样记录；当前=取消后的状态。全部未被改动 → 三条都恢复
        let afterCancel = [snap("u-1", status: "cancelled"), snap("u-2", status: "cancelled"), snap("u-3", status: "cancelled")]
        try check(RecordUndo.restorable(snapshot: snapshot, current: afterCancel).map(\.id) == ["u-1", "u-2", "u-3"], "撤销窗：未变化的取消记录全部可恢复")
        // 部分变化：重试过的（变回 queued 且带 evidence）、又出现提交痕迹的，都不可恢复
        let mixed: [Delivery] = [
            snap("u-1", status: "cancelled"),                    // 原样 → 恢复
            snap("u-2", status: "queued", evidence: "已重试"),    // 用户已重试 → 不覆盖
            snap("u-3", status: "cancelled", submitted: true),   // 取消后又出现提交痕迹 → 不覆盖
        ]
        try check(RecordUndo.restorable(snapshot: snapshot, current: mixed).map(\.id) == ["u-1"], "撤销窗：只有仍处于无痕迹 cancelled 的记录可恢复")
        let gone = [snap("u-9", status: "cancelled")]
        try check(RecordUndo.restorable(snapshot: snapshot, current: gone).isEmpty, "撤销窗：id 已消失的记录不可恢复")
    }

    // MARK: 发送前预告（UpcomingAnnouncement）
    do {
        let cal = Scheduling.calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 0))!
        func q(_ id: String, minutesFromNow: Int, planID: String = "p") -> Delivery {
            var d = jobs[0]
            d.id = id; d.planID = planID; d.status = "queued"
            d.submittedAt = nil; d.evidence = ""
            d.scheduled = now.addingTimeInterval(Double(minutesFromNow) * 60)
            return d
        }
        // ① 窗口内：9 分钟后发送、lead 10 分钟 → 预告，分钟数取整为 9
        let inside = [q("a-1", minutesFromNow: 9)]
        let hit = UpcomingAnnouncement.evaluate(deliveries: inside, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 10, calendar: cal, announcedID: nil, announcedDue: nil)
        try check(hit?.jobID == "a-1" && hit?.minutes == 9 && hit?.planName == "测试", "窗口内（9≤10 分钟）给出预告，分钟数向下取整")
        try check(hit?.timeText == "9:09", "预告携带绝对时刻 HH:mm")
        // ② 窗口外：20 分钟后 → 不预告
        let outside = [q("a-1", minutesFromNow: 20)]
        try check(UpcomingAnnouncement.evaluate(deliveries: outside, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 10, calendar: cal, announcedID: nil, announcedDue: nil) == nil,
                  "窗口外（>lead 分钟）不预告")
        // ③ 临近 30 秒内 → 不预告（马上要发的不再添乱）
        let imminent = [q("a-1", minutesFromNow: 0)]
        try check(UpcomingAnnouncement.evaluate(deliveries: imminent, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 10, calendar: cal, announcedID: nil, announcedDue: nil) == nil,
                  "已到点/30 秒内不预告")
        // ④ lead=0 关闭 → 不预告
        try check(UpcomingAnnouncement.evaluate(deliveries: inside, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 0, calendar: cal, announcedID: nil, announcedDue: nil) == nil,
                  "lead=0 时预告关闭")
        // ⑤ 去重：同 ID 同时刻已预告 → 不重复；时刻变了 → 再次预告
        let due1 = now.addingTimeInterval(9 * 60)
        try check(UpcomingAnnouncement.evaluate(deliveries: inside, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 10, calendar: cal,
                                                announcedID: "a-1", announcedDue: due1) == nil,
                  "同 ID 同时刻不重复预告")
        let rescheduled = [q("a-1", minutesFromNow: 8)]
        let again = UpcomingAnnouncement.evaluate(deliveries: rescheduled, now: now, gap: 30, intervalByPlan: [:],
                                                  leadMinutes: 10, calendar: cal,
                                                  announcedID: "a-1", announcedDue: due1)
        try check(again?.jobID == "a-1" && again?.minutes == 8, "改期后（ID 同时刻变）再次预告")
        // ⑥ 待核对不影响下一条正常预告，也不会预告需核对的原记录。
        var blockedCopy = inside
        var blockedJob = jobs[0]; blockedJob.id = "blk"; blockedJob.status = "uncertain"
        blockedCopy.append(blockedJob)
        try check(UpcomingAnnouncement.evaluate(deliveries: blockedCopy, now: now, gap: 30, intervalByPlan: [:],
                                                leadMinutes: 10, calendar: cal, announcedID: nil, announcedDue: nil)?.jobID == "a-1",
                  "有历史待核对时仍预告下一条干净的待执行")
        // ⑦ 旧库解码：无 upcomingLeadMinutes 字段 → nil = 默认 10 分钟
        let legacy = try JSONDecoder().decode(Settings.self, from: Data("{\"globalGapMinutes\":30,\"savedText\":\"\"}".utf8))
        try check((legacy.upcomingLeadMinutes ?? 10) == 10, "旧设置无预告字段时默认 10 分钟")
        // ⑧ 作用域（回归审计）：运行中只预告当前计划的下一条——作用域外任务不会被发送
        let planAJob = q("scope-a", minutesFromNow: 5, planID: "plan-A")
        let planBJob = q("scope-b", minutesFromNow: 9, planID: "plan-B")
        let bothPlans = [planAJob, planBJob]
        let scoped = UpcomingAnnouncement.evaluate(deliveries: bothPlans, now: now, gap: 30, intervalByPlan: [:],
                                                   leadMinutes: 10, calendar: cal, announcedID: nil, announcedDue: nil,
                                                   planScope: "plan-B")
        try check(scoped?.jobID == "scope-b", "带作用域时只预告当前计划的任务（plan-B 的 9 分钟而非 plan-A 的 5 分钟）")
        // ⑨ Postpone 目标：正常推迟 = 原时刻 + N；早已过期的任务（+30min 仍在过去）被 now+10s 托底
        let base = now.addingTimeInterval(50 * 60)
        try check(Postpone.target(scheduled: base, minutes: 30, now: now) == base.addingTimeInterval(30 * 60), "正常推迟 = 原排期 + 30 分钟")
        let longExpired = now.addingTimeInterval(-2 * 3600)
        try check(Postpone.target(scheduled: longExpired, minutes: 30, now: now) == now.addingTimeInterval(10), "过期任务推迟被 now+10 秒托底（不会静默变马上发）")
        // ⑩ canPostpone 口径：queued 无痕迹可推迟；带提交痕迹/非 queued/一次性不行
        var canP = jobs[0]; canP.status = "queued"; canP.submittedAt = nil; canP.evidence = ""
        try check(canP.canPostpone, "无痕迹待执行可推迟")
        var withTrace = canP; withTrace.submittedAt = now
        try check(!withTrace.canPostpone, "带提交痕迹的待执行不可推迟")
        var doneJob = canP; doneJob.status = "verified"
        try check(!doneJob.canPostpone, "已发送不可推迟")
    }

    // MARK: 菜单栏倒计时（MenuBarTitle）
    do {
        let cal = Scheduling.calendar
        func nt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let now = nt(2026, 10, 6, 10, 0)
        try check(MenuBarTitle.text(now: now, next: nil, calendar: cal) == nil, "没有下一群时不加文本（只留图标）")
        try check(MenuBarTitle.text(now: now, next: now.addingTimeInterval(30), calendar: cal) == "即将发送", "一分钟内显示「即将发送」")
        try check(MenuBarTitle.text(now: now, next: now.addingTimeInterval(-20), calendar: cal) == "即将发送", "已到点（负间隔）也显示「即将发送」")
        try check(MenuBarTitle.text(now: now, next: now.addingTimeInterval(30 * 60), calendar: cal) == "30m", "半小时显示紧凑分钟")
        try check(MenuBarTitle.text(now: now, next: now.addingTimeInterval(90 * 60), calendar: cal) == "1h30m", "一个半小时显示小时+分钟")
        try check(MenuBarTitle.text(now: now, next: now.addingTimeInterval(3 * 3600), calendar: cal) == "3h", "整小时省略分钟")
        try check(MenuBarTitle.text(now: now, next: nt(2026, 10, 7, 12, 0), calendar: cal) == "明天12:00", "明天退回「明天HH:mm」")
        try check(MenuBarTitle.text(now: now, next: nt(2026, 10, 9, 14, 5), calendar: cal) == "10/9 14:05", "更远退回「M/d HH:mm」，绝不显示数千分钟")
    }

    // MARK: 错峰抖动
    do {
        let now = Date(timeIntervalSince1970: 1791123600)  // 2026-10-06 02:00 UTC+8
        let cal = Scheduling.calendar
        func mk(_ id: String, _ sched: Date) -> Delivery {
            var d = jobs[0]
            d.id = id; d.status = "queued"; d.scheduled = sched
            d.submittedAt = nil; d.evidence = ""; d.oneOff = nil; d.cloneOf = nil; d.cycleTag = nil
            return d
        }
        let t0 = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let j0 = mk("j-0", t0)
        let j1 = mk("j-1", t0.addingTimeInterval(1800))  // 30 分钟
        let j2 = mk("j-2", t0.addingTimeInterval(3600))  // 60 分钟

        // 关抖动：与原逻辑一致
        let off = Scheduling.restarted([j0, j1, j2], planID: nil, now: t0, gap: 30, intervalByPlan: [:], jitter: false)
        try check(off[1].scheduled == t0.addingTimeInterval(1800), "关抖动时第二群排期与原逻辑一致")
        try check(off[2].scheduled == t0.addingTimeInterval(3600), "关抖动时第三群排期与原逻辑一致")

        // 开抖动：首群不变，后续间隔单向上浮 [30, 36]（30 最多 +20%=+6；不下调——运行期冷却按
        // 原始间隔钳底，负向偏移会被钳回，单向抖动让写入值=可执行值，预览不撒谎）
        let on = Scheduling.restarted([j0, j1, j2], planID: nil, now: t0, gap: 30, intervalByPlan: [:], jitter: true)
        try check(on[0].scheduled == t0, "开抖动时首群排期不变")
        let gap12 = on[1].scheduled.timeIntervalSince(on[0].scheduled) / 60
        let gap23 = on[2].scheduled.timeIntervalSince(on[1].scheduled) / 60
        try check(gap12 >= 30 && gap12 <= 36, "抖动后第一间隔在 [30,36] 分钟内（单向上浮）")
        try check(gap23 >= 30 && gap23 <= 36, "抖动后第二间隔在 [30,36] 分钟内（单向上浮）")
        // 预览=运行：单向上浮后的间隔不小于全局冷却（30），eligible 不会再把它往后钳
        try check(on[1].scheduled.timeIntervalSince(on[0].scheduled) >= 30 * 60 - 1, "抖动间隔不小于全局冷却，运行期无需再钳")

        // 确定性：同输入两次 restarted（同 seed 来源 = job.id）结果一致
        let on2 = Scheduling.restarted([j0, j1, j2], planID: nil, now: t0, gap: 30, intervalByPlan: [:], jitter: true)
        try check(on[1].scheduled == on2[1].scheduled && on[2].scheduled == on2[2].scheduled, "同输入同 seed 结果确定")

        // 间隔 5 分钟时不低于 5
        let j5a = mk("j-5a", t0); let j5b = mk("j-5b", t0.addingTimeInterval(300))
        let tight = Scheduling.restarted([j5a, j5b], planID: nil, now: t0, gap: 5, intervalByPlan: [:], jitter: true)
        let tg = tight[1].scheduled.timeIntervalSince(tight[0].scheduled) / 60
        try check(tg >= 5, "间隔 5 分钟抖动后不低于 5")

        // verified 的 scheduled 不被改动
        var v0 = mk("v-0", t0); v0.status = "verified"
        let v1 = mk("v-1", t0.addingTimeInterval(1800))
        let mix = Scheduling.restarted([v0, v1], planID: nil, now: t0, gap: 30, intervalByPlan: [:], jitter: true)
        try check(mix[0].scheduled == v0.scheduled, "verified 记录的排期不被抖动改动")
    }

    // MARK: 错峰抖动补充（新排 expand 路径、纯函数边界、旧库兼容）
    do {
        let now = Date(timeIntervalSince1970: 1791123600)
        let recipients = (1...8).map { Recipient(name: "抖动群\($0)") }
        let jplan = Plan(name: "抖动计划", text: "抖动正文", assetIDs: [], recipientIDs: recipients.map(\.id),
                         starts: now.addingTimeInterval(600), days: 1, times: [], intervalMinutes: 30, mode: "automatic")
        let plain = try Scheduling.expand(jplan, recipients: recipients, assets: [], now: now)
        // ① 关（默认）与显式 false 完全一致
        try check(try Scheduling.expand(jplan, recipients: recipients, assets: [], now: now, jitter: false).map(\.scheduled) == plain.map(\.scheduled), "新排 jitter 关闭时排期与既有行为逐秒一致")
        // ② 开：首群 = 用户选定的开始时刻，不变
        let shaken = try Scheduling.expand(jplan, recipients: recipients, assets: [], now: now, jitter: true)
        try check(shaken[0].scheduled == plain[0].scheduled && shaken[0].scheduled == jplan.starts, "新排抖动时首群仍是用户选定的开始时刻")
        // ③ 相邻间隔都在 [24,36]，且不再全部相等（等差特征被打散）
        let deltas = (1..<shaken.count).map { Int(shaken[$0].scheduled.timeIntervalSince(shaken[$0 - 1].scheduled) / 60) }
        try check(deltas.allSatisfy { (30...36).contains($0) }, "新排抖动后相邻间隔都在 [30,36] 分钟内（单向上浮）")
        try check(Set(deltas).count > 1, "抖动确实打散等差间隔，相邻间隔不再全部相同")
        // ④ 确定性：同计划重复新排一致；jittered 同 seed 确定、不同 seed 一般不同
        try check(try Scheduling.expand(jplan, recipients: recipients, assets: [], now: now, jitter: true).map(\.scheduled) == shaken.map(\.scheduled), "同一计划两次新排的抖动结果确定")
        try check(Scheduling.jittered(minutes: 30, seed: 20261006) == Scheduling.jittered(minutes: 30, seed: 20261006), "jittered 同 seed 两次调用结果一致")
        try check((0..<64).contains { Scheduling.jittered(minutes: 30, seed: $0) != Scheduling.jittered(minutes: 30, seed: $0 &+ 0x9e37_79b9) }, "jittered 不同 seed 会产生不同偏移")
        // ⑤ 区间与下限：多档间隔 × 多个 seed 全部落在 [max(5, m), m+o]（单向上浮）；5 分钟不低于 5；极短间隔钳到 5
        for minutes in [1, 5, 10, 30, 60, 300, 1440] {
            let offset = max(1, minutes / 5)
            let lowBound = max(5, minutes)
            let highBound = max(minutes + offset, lowBound)  // 极短间隔被 5 分钟下限钳住时区间收缩到单点
            for seed in 0..<96 {
                let value = Scheduling.jittered(minutes: minutes, seed: seed)
                try check(value >= lowBound && value <= highBound, "\(minutes) 分钟间隔的抖动值落在合法区间（seed=\(seed)）")
            }
        }
        try check((0..<200).allSatisfy { Scheduling.jittered(minutes: 5, seed: $0) >= 5 }, "间隔 5 分钟的抖动值不低于 5 分钟")
        try check(Scheduling.jittered(minutes: 1, seed: 7) == 5, "低于 5 分钟的间隔被下限钳到 5 分钟")
        // ⑥ 已发送/已拦截记录不参与重启抖动重排
        var done = plain
        done[0].status = "verified"; done[0].submittedAt = now; done[0].evidence = "已核验"
        done[1].status = "blocked"; done[1].started = now
        let rescheduled = Scheduling.restarted(done, planID: jplan.id, now: now.addingTimeInterval(3600), gap: 30, intervalByPlan: [jplan.id: 30], jitter: true)
        try check(rescheduled[0].scheduled == plain[0].scheduled && rescheduled[0].status == "verified" && rescheduled[0].evidence == "已核验", "已发送记录的排期与凭据不被重启抖动改动")
        try check(rescheduled[1].scheduled == plain[1].scheduled && rescheduled[1].status == "blocked", "已拦截记录不参与重启抖动重排")
        // 重启路径（全部落后、按原排期升序）：首条 = 点击时刻，后续间隔全部落在区间内，两次调用一致
        var lagging = plain
        for i in lagging.indices { lagging[i].scheduled = now.addingTimeInterval(Double(-7200 + i * 60)) }
        let laggyJitter = Scheduling.restarted(lagging, planID: jplan.id, now: now, gap: 30, intervalByPlan: [:], jitter: true)
        try check(laggyJitter[0].scheduled == now, "重启抖动时首条仍从点击时刻开始")
        let laggyDeltas = (1..<laggyJitter.count).map { Int(laggyJitter[$0].scheduled.timeIntervalSince(laggyJitter[$0 - 1].scheduled) / 60) }
        try check(laggyDeltas.allSatisfy { (30...36).contains($0) }, "重启抖动后相邻间隔都在 [30,36] 分钟内（单向上浮）")
        try check(Scheduling.restarted(lagging, planID: jplan.id, now: now, gap: 30, intervalByPlan: [:], jitter: true).map(\.scheduled) == laggyJitter.map(\.scheduled), "重启抖动同一批任务两次结果一致")
        // 旧库兼容：无 staggerJitter 字段时解码为 nil = 默认关闭
        let legacyJitter = try JSONDecoder().decode(Settings.self, from: Data("{\"globalGapMinutes\":30,\"savedText\":\"旧文案\"}".utf8))
        try check(legacyJitter.staggerJitter == nil && (legacyJitter.staggerJitter ?? false) == false, "旧设置无错峰抖动字段时解码为 nil 即默认关闭")
        // ⑦ 纯函数边界补充：极短间隔恒等于下限（区间收缩成单点，与 seed 无关）；一整天间隔 ±20% 区间；seed 发散性下限
        try check((0..<32).allSatisfy { Scheduling.jittered(minutes: 1, seed: $0) == 5 }, "minutes=1 时抖动恒为下限 5 分钟（与 seed 无关）")
        try check((0..<64).allSatisfy { (1440...1728).contains(Scheduling.jittered(minutes: 1440, seed: $0)) }, "minutes=1440 的抖动值全部落在 [1440,1728]（单向上浮 20%）")
        try check(Set((0..<10).map { Scheduling.jittered(minutes: 30, seed: $0) }).count >= 3, "10 个不同 seed 至少产生 3 个不同抖动值")
    }

try check(QueueStartGate.pausedNote(statuses: ["blocked"]) == "有 1 条已拦截，可在发送记录重试", "只有已暂停时给出去向指引（不再写「不挡住启动」，避免与灰掉的启动按钮矛盾）")
        // 走查 1-26：指引口径与 Delivery.canRequeue / listGuidance 对齐，不承诺做不到的事
        try check(QueueStartGate.pausedNote(statuses: ["blocked", "blocked", "blocked"], nonRetriableCount: 1) == "有 3 条已拦截（其中 1 条需先到发送记录核对实际结果），其余可在发送记录重试", "已拦截里区分能不能直接重试")
        try check(QueueStartGate.pausedNote(statuses: ["blocked", "blocked"], nonRetriableCount: 2) == "有 2 条已拦截，都需先到发送记录核对实际结果，不能直接重试", "全部不可重试时不再写可在发送记录重试")
        try check(QueueStartGate.pausedNote(statuses: ["blocked"], nonRetriableCount: 0) == "有 1 条已拦截，可在发送记录重试", "不传不可重试条数时保持旧文案，既有调用点无需改动")
        try check(QueueStartGate.nonRetriablePaused(["blocked", "blocked", "queued"], [true, false, true]) == 1, "不可重试计数只算已暂停且已尝试过的记录")
        try check(QueueStartGate.nonRetriablePaused(["blocked", "queued"], [true]) == 0, "状态与标记条数不匹配时不猜数字")
        try check(QueueStartGate.pausedNote(statuses: ["uncertain"]) == nil, "没有已暂停时不额外写一句")
        try check(QueueStartGate.blockingCount(["uncertain", "blocked"]) == 1 && QueueStartGate.pausedCount(["uncertain", "blocked"]) == 1, "待核对和已暂停可以同时各算各的")
        try check(QueueStartGate.attentionLabel(statuses: ["queued", "verified"]) == nil, "没有待核对也没有已暂停时，进度条不写需关注")
        try check(QueueStartGate.attentionLabel(statuses: ["uncertain", "draft"]) == "2 群待核对", "进度条仍如实展示需核对的记录")
        try check(QueueStartGate.attentionLabel(statuses: ["blocked", "blocked"]) == "2 群已拦截", "已暂停在进度条上不再写成需关注")
        try check(QueueStartGate.attentionLabel(statuses: ["submitted", "blocked"]) == "1 群待核对 · 1 群已拦截", "待核对和已暂停同时出现时分成两段")
        try check(QueueStartGate.overflowTitle(hiddenStatuses: ["blocked", "queued"]) == "还有 2 群 · 1 群已拦截", "折起来的群里，已暂停不叫需关注")
        try check(QueueStartGate.overflowTitle(hiddenStatuses: ["uncertain", "blocked"]) == "还有 2 群 · 1 群待核对 · 1 群已拦截", "折叠标题把待核对和已暂停分开")
        try check(ProgressTone.tone(for: "blocked") == .paused, "已暂停用安静的暂停色，不跟待核对同一块警示")
        try check(ProgressTone.tone(for: "uncertain") == .review && ProgressTone.tone(for: "draft") == .review && ProgressTone.tone(for: "submitted") == .review, "草稿、已提交和结果待核对仍是待核对外观")
        try check(ProgressTone.tone(for: "running") == .sending && ProgressTone.tone(for: "queued") == .pending, "正在发送和待执行不伪装成待核对")
        try check(ProgressTone.tone(for: "verified") == .done && ProgressTone.tone(for: "cancelled") == .cancelled, "已核验和已取消保持原来的外观")
        let picture = "5afe4ed3-dfc3-4578-b010-8f6d8c86673a.png"
        try check(AttachWait.budget(bytes: 8_022_428) > 23 && AttachWait.budget(bytes: 8_022_428) < 24, "8MB 图片的确认预算仍约 23.3 秒，封顶前不放宽")
        try check(AttachWait.budget(bytes: 50_000_000) == 24, "更大的图片确认预算仍封顶 24 秒")
        let preparing = AttachWait.preparing(name: picture)
        try check(preparing.contains(picture) && preparing.contains("尚未粘贴") && preparing.contains("尚未发送"), "解码期间说明还没粘贴，也还没发送")
        let waiting = AttachWait.line(name: picture, elapsed: 12.9, budget: AttachWait.budget(bytes: 8_022_428))
        try check(waiting == "已等待 12/24 秒，尚未发送。正在确认「\(picture)」是否进入草稿", "等待中能看到已用时间和上限，并写明尚未发送")
        try check(AttachWait.line(name: picture, elapsed: 0, budget: 23.3).hasPrefix("已等待 0/24 秒"), "刚开始等待从 0 秒计")
        try check(AttachWait.line(name: picture, elapsed: 40, budget: 23.3).hasPrefix("已等待 24/24 秒"), "超过预算的显示停在上限，不出现 40/24")
        try check(AttachWait.line(name: picture, elapsed: 1.2, budget: 6).hasPrefix("已等待 1/6 秒，尚未发送"), "微信图片确认的 6 秒窗口也写明尚未发送")
        try check(SendChannel.reviewPrompt(channel: SendChannel.wechat).contains("微信") && SendChannel.reviewPrompt(channel: SendChannel.wechat).contains("发送") && SendChannel.reviewPrompt(channel: SendChannel.wechat).contains("不发送"), "微信核对只提供发送或不发送，不能标记为自动成功")
        try check(SendChannel.reviewPrompt(channel: SendChannel.qq).contains("QQ"), "QQ 记录仍让人去 QQ 核对")
        try check(SendChannel.markedSentDetail(channel: SendChannel.wechat) == "用户在微信核对后标记已发送", "微信人工确认写进微信，不写成 QQ")
        let kept = SendChannel.markedSentDetail(channel: SendChannel.qq, previous: "步骤：已按 Return，等待 QQ 发送\n输入框当前标注为「2025资源勘查工程专业群」，与已选中的「中国石油大学克拉玛依校区2026级新生交流群」不一致")
        try check(kept.hasPrefix("用户在QQ核对后标记已发送\n原先记录：\n") && kept.contains("2025资源勘查工程专业群"), "人工确认保留原先的核对原因")
        let cancelled = SendChannel.cancelledDetail(previous: "输入框当前标注为「2025资源勘查工程专业群」，与已选中的「中国石油大学克拉玛依校区2026级新生交流群」不一致", note: "用户取消，或消息撤回后不再重发")
        try check(cancelled.hasPrefix("用户取消，或消息撤回后不再重发\n原先记录：\n") && cancelled.contains("2025资源勘查工程专业群"), "取消这条时保留原先的核对原因")
        try check(SendChannel.cancelledDetail(previous: "等待执行", note: "用户批量取消，未发送") == "用户批量取消，未发送\n原先记录：\n等待执行", "批量取消也留下取消前的说明")
        try check(SendChannel.confirmSentPrompt(channel: SendChannel.wechat) == "确认已经在微信里看到这条消息？此操作只改本地记录，不会再发送。", "确认发送前先问是不是已经在微信里看到")
        try check(SendChannel.markedSentDetail(channel: "") == "用户在QQ核对后标记已发送", "没有渠道的旧记录仍按 QQ 记")
        try check(SendChannel.crashRecoveryDetail(channel: SendChannel.wechat) == "上次程序在处理期间退出，请到微信核对后人工确认，不自动重试", "微信任务异常退出后让人去微信核对")
        try check(SendChannel.crashRecoveryDetail(channel: SendChannel.qq) == "上次程序在处理期间退出，请到QQ核对后人工确认，不自动重试", "QQ 任务异常退出后让人去 QQ 核对")
        try check(SendChannel.rescheduleDetail(channel: SendChannel.wechat) == "人工重新排期；请确保上次未发且微信草稿已处理", "重新排期提醒处理微信草稿")
        // 走查 1-08：重新排期与续发都必须追加，不覆盖已经尝试过的记录
        try check(SendChannel.rescheduleDetail(channel: SendChannel.qq, previous: "步骤：正在搜索群聊\n前台已切换到其他应用，操作暂停").contains("前台已切换到其他应用，操作暂停"), "重新排期保留上一次的暂停原因（走查 1-08）")
        try check(SendChannel.crashRecoveryDetail(channel: SendChannel.wechat, previous: "步骤：已按 Return，等待微信发送").contains("步骤：已按 Return"), "崩溃恢复保留上次执行到哪一步（走查 1-08）")
        try check(SendChannel.crashRecoveryDetail(channel: SendChannel.qq) == "上次程序在处理期间退出，请到QQ核对后人工确认，不自动重试", "不传原记录时崩溃恢复文案与旧版一致，既有调用点无需改动")
        try check(SendChannel.rescheduleDetail(channel: SendChannel.qq, previous: SendChannel.rescheduleDetail(channel: SendChannel.qq)) == SendChannel.rescheduleDetail(channel: SendChannel.qq), "重复排期不重复堆叠同一条说明")
        try check(SendChannel.saveFailure(channel: SendChannel.wechat, reason: "磁盘满") == "状态保存失败：磁盘满。请到微信核对，不要重发", "保存失败时按微信提醒，不要重发")
        try check(SendChannel.clientVerificationNote(channels: []) == "核验指QQ客户端可见结果，不是服务器送达回执。", "没有任务时核验说明仍指 QQ")
        try check(SendChannel.clientVerificationNote(channels: [SendChannel.wechat]) == "核验指微信客户端可见结果，不是服务器送达回执。", "只有微信任务时核验说明指微信")
        try check(SendChannel.clientVerificationNote(channels: [SendChannel.qq, SendChannel.wechat]) == "核验指QQ或微信客户端可见结果，不是服务器送达回执。", "两种渠道都有时核验说明一起写")
        let stopped = StoppedReasonLine.text(title: "中国石油大学克拉玛依校区2026级新生交流群", detail: "结果待核对", reason: "输入框当前标注为「2025资源勘查工程专业群」，与已选中的「中国石油大学克拉玛依校区2026级新生交流群」不一致")
        try check(stopped.hasPrefix("输入框当前标注为「2025资源勘查工程专业群」") && stopped.hasSuffix("（中国石油大学克拉玛依校区2026级新生交流群）"), "为什么停住先写标注不一致，再附群名")
        try check(StoppedReasonLine.text(title: "示例群", detail: "结果待核对", reason: nil) == "示例群：结果待核对", "没有具体原因时仍写出状态")
        try check(HomeBanner.title(nextRecipient: "示例群", reviewCount: 2) == "下一群 · 示例群", "有下一条待执行时总览写群名")
        try check(HomeBanner.title(nextRecipient: nil, reviewCount: 2) == "当前没有待执行任务", "只有待核对时总览不把核对当成启动前提")
        try check(HomeBanner.idleSubtitle(reviewCount: 2) == "待核对结果保留在发送记录，可稍后处理；可继续编排新的发送。", "有待核对时说明可稍后处理并继续编排")
        try check(HomeBanner.idleSubtitle(reviewCount: 0) == "到「新建发送」里编排一次发送，或从素材库开始。", "没有待核对时副文仍指向新建发送")
        try check(HomeBanner.showsHeroCompose(reviewCount: 2), "有待核对时仍保留新建发送")
        try check(HomeBanner.showsHeroCompose(reviewCount: 0), "没有待核对时总览主操作区仍可新建发送")
        try check(!HomeBanner.showsQueueLink(queuedCount: 0, reviewCount: 2), "仅有历史待核对时不把历史记录当待发队列")
        try check(!HomeBanner.showsQueueLink(queuedCount: 0, reviewCount: 0), "待执行和待核对都没有时，查看待发队列变灰")
        try check(HomeBanner.showsQueueLink(queuedCount: 3, reviewCount: 0), "有待执行时查看待发队列可点")
        try check(HomeBanner.firstShortcutTitle(reviewCount: 2) == "新建发送" && !HomeBanner.firstShortcutGoesToHistory(reviewCount: 2), "有待核对时也不把快捷操作强制改为发送记录")
        try check(HomeBanner.firstShortcutTitle(reviewCount: 0) == "新建发送" && !HomeBanner.firstShortcutGoesToHistory(reviewCount: 0), "没有待核对时快捷操作第一项仍是新建发送")
        try check(HomeBanner.pageTitle(hasNext: false, reviewCount: 2) == "今天要发什么？", "历史待核对不替换总览页头")
        try check(HomeBanner.pageTitle(hasNext: true, reviewCount: 2) == "今天要发什么？" && HomeBanner.pageTitle(hasNext: false, reviewCount: 0) == "今天要发什么？", "有下一条或没有待核对时，页头仍问今天要发什么")
        try check(HomeBanner.pageSubtitle(hasNext: false, reviewCount: 2) == "一屏看清排期、进度和下一次发送。", "页头副文不因历史待核对改成阻止发送提示")
        try check(HomeBanner.pageSubtitle(hasNext: false, reviewCount: 0) == "一屏看清排期、进度和下一次发送。", "没有待核对时页头副文不变")
        let homeReview = HomeBanner.headerAction(route: "home", reviewCount: 2)
        try check(homeReview?.title == "新建发送" && homeReview?.goesToHistory == false, "总览有待核对时页头主按钮仍允许新建发送")
        try check(HomeBanner.headerAction(route: "queue", reviewCount: 1)?.goesToHistory == false, "队列页有待核对时也不强制去发送记录")
        let homeIdle = HomeBanner.headerAction(route: "home", reviewCount: 0)
        try check(homeIdle?.title == "新建发送" && homeIdle?.goesToHistory == false, "没有待核对时页头仍是新建发送")
        try check(HomeBanner.headerAction(route: "assets", reviewCount: 2)?.title == "新建发送" && HomeBanner.headerAction(route: "history", reviewCount: 2)?.title == "新建发送", "素材库和发送记录页即使有待核对，页头仍可新建发送")
        try check(HomeBanner.headerAction(route: "compose", reviewCount: 2) == nil, "新建发送页不放页头按钮")
        try check(HomeBanner.title(nextRecipient: "  ", reviewCount: 0) == "当前没有待执行任务", "没有待执行也没有待核对时才说没有任务")
        let upcomingReview = HomeBanner.upcomingEmpty(statuses: ["uncertain"])
        try check(upcomingReview.needsReview && upcomingReview.title == "当前没有待执行排期" && upcomingReview.message.contains("可稍后核对") && upcomingReview.message.contains("不会自动重发"), "接下来没有待执行时只提示稍后核对，不限制新建或启动")
        try check(HomeBanner.upcomingEmpty(statuses: []).title == "队列是空的" && HomeBanner.upcomingEmpty(statuses: []).message.contains("新建发送"), "真的没有任务时才提示去新建发送")
        try check(SendChannel.scheduleBehaviorNote.contains("唤起 QQ 或微信"), "排程说明写明会唤起 QQ 或微信")
        try check(SendChannel.qqStatusPlaceholder == "先检查 QQ 与辅助功能权限。" && !SendChannel.qqStatusPlaceholder.contains("微信"), "QQ 检查卡的初始说明只写 QQ")
        try check(SendChannel.wechatStatusPlaceholder == "先检查微信与辅助功能权限。" && !SendChannel.wechatStatusPlaceholder.contains("QQ"), "微信检查卡的初始说明只写微信")
        let qqNames = SendChannel.addNamesHint(channel: SendChannel.qq)
        try check(qqNames.contains("第一条群聊结果") && !qqNames.contains("唯一匹配"), "添加 QQ 群时说明打开第一条结果")
        let wechatNames = SendChannel.addNamesHint(channel: SendChannel.wechat)
        try check(wechatNames.contains("唯一匹配") && wechatNames.contains("不发送") && !wechatNames.contains("第一条"), "添加微信联系人时不再写成打开第一条结果")
        try check(SendChannel.weChatEnterNote.contains("只按一次回车键") && SendChannel.weChatEnterNote.contains("Return 与 Enter 是同一个键") && SendChannel.weChatEnterNote.contains("不会再按第二次"), "微信设置里事先说明只按一次 Return")
        let wechatAuto = SendChannel.composeCaution(channels: [SendChannel.wechat], automatic: true)
        try check(wechatAuto?.contains("唯一匹配") == true && wechatAuto?.contains("只按一次回车键") == true && wechatAuto?.contains("Return 与 Enter 是同一个键") == true && wechatAuto?.contains("第一条") != true, "自动发送选了微信时，新建页事先说明唯一匹配和只按一次回车键")
        let wechatDraft = SendChannel.composeCaution(channels: [SendChannel.wechat], automatic: false)
        try check(wechatDraft?.contains("不会填写草稿") == true && wechatDraft?.contains("只按一次 Return") != true, "只填草稿时不提 Return，但同名仍会停住")
        let qqOnly = SendChannel.composeCaution(channels: [SendChannel.qq], automatic: true)
        try check(qqOnly?.contains("第一条群聊结果") == true && qqOnly?.contains("唯一匹配") != true, "只选 QQ 时新建页仍说明打开第一条")
        let bothChannels = SendChannel.composeCaution(channels: [SendChannel.qq, SendChannel.wechat], automatic: true)
        try check(bothChannels?.contains("第一条群聊结果") == true && bothChannels?.contains("唯一匹配") == true, "两个渠道都选时两条规则都写")
        try check(SendChannel.composeCaution(channels: [], automatic: true) == nil, "还没选群时不额外写搜索规则")
        try check(SendChannel.appPhrase([]) == "QQ 或微信" && SendChannel.appPhrase([SendChannel.qq, SendChannel.wechat]) == "QQ 或微信", "还没选群或两种都选时，不把说明写成只有 QQ")
        try check(SendChannel.appPhrase([SendChannel.wechat]) == "微信" && SendChannel.appPhrase([SendChannel.qq]) == "QQ", "只选一个渠道时说明就写那一个")
        try check(SendChannel.loginReminder(channels: [SendChannel.wechat]) == "资料保存在此 Mac\n软件需保持运行，微信需登录并解锁", "只有微信名单时，侧栏提醒登录微信")
        try check(SendChannel.sendForegroundNote(channels: [SendChannel.wechat], automatic: true) == "自动发送时短暂使用微信前台，成功后尽量切回原应用。", "只选微信群时，自动发送说明写微信")
        try check(SendChannel.sendForegroundNote(channels: [SendChannel.wechat], automatic: false) == "仅填草稿不会按发送键。填写时仍会短暂打开微信。", "草稿模式说明不再写成会自动发送")
        try check(SendChannel.restoreBehaviorNote.contains("QQ 或微信") && SendChannel.restoreBehaviorNote.contains("不抢回焦点"), "切回原应用的说明覆盖两个渠道")
        try check(FocusRestore.shouldRestore(verified: true, enabled: true, cancelled: false, locked: false, frontBundleID: FocusRestore.weChatBundleID, previousBundleID: "com.apple.Safari", targetBundleID: FocusRestore.targetBundleID(channel: SendChannel.wechat)), "微信仍在前台且已核验时可以切回原应用")
        try check(!FocusRestore.shouldRestore(verified: true, enabled: true, cancelled: false, locked: false, frontBundleID: "com.google.Chrome", previousBundleID: "com.apple.Safari", targetBundleID: FocusRestore.weChatBundleID), "用户已经离开微信时不抢回焦点")
        try check(!FocusRestore.shouldRestore(verified: false, enabled: true, cancelled: false, locked: false, frontBundleID: FocusRestore.qqBundleID, previousBundleID: "com.apple.Safari", targetBundleID: FocusRestore.qqBundleID), "未核验成功时不切回原应用")
        try check(FocusRestore.shouldRestore(verified: true, enabled: true, cancelled: false, locked: false, frontBundleID: FocusRestore.qqBundleID, previousBundleID: "com.apple.Safari", targetBundleID: FocusRestore.qqBundleID), "QQ 仍在前台且已核验时仍可以切回原应用")
        try check(!waiting.contains("已确认") && !waiting.contains("已发送"), "等待文案不能写成图片已确认或消息已发出")
        let selected = "中国石油大学克拉玛依校区2026级新生交流群"
        let other = "2025资源勘查工程专业群"
        let mismatch = "输入框当前标注为「\(other)」，与已选中的「\(selected)」不一致"
        try check(PostSendWatch.reaction(toEditorError: mismatch) == .inconclusive(label: other), "发送后标注暂时变成另一个群，只跳过这一拍")
        try check(PostSendWatch.reaction(toEditorError: "已离开刚选中的第一条会话「\(selected)」，操作暂停") == .abort, "已离开刚选中的会话仍立即停止")
        try check(PostSendWatch.reaction(toEditorError: "未能唯一定位 QQ 消息输入框，请关闭其他弹窗") == .inconclusive(label: nil), "输入框暂时定位不到时不把这一拍当成成功或会话丢失")
        for failure in ["前台已切换到 Chrome，操作暂停；不是 QQ 登录失效", "Mac 已锁屏，请解锁后继续", "已停止。请检查 QQ 中是否留有草稿或已提交的消息", "无法读取 QQ 消息列表，不能核验发送结果", "未知辅助功能错误"] {
            try check(PostSendWatch.reaction(toEditorError: failure) == .abort, "发送后核验不得吞掉安全或未知异常：\(failure)")
        }
        let recovered: [PostSendWatch.Sample] = [
            .labelMismatch(other),
            .bound(draftCleared: true, textAppeared: true, imagesAppeared: true)
        ]
        try check(PostSendWatch.verdict(recovered) == .readyToVerify, "标注先错后对，且草稿清空、消息新增，才有资格进入成功判定")
        try check(PostSendWatch.verdict([.labelMismatch(other), .bound(draftCleared: false, textAppeared: true, imagesAppeared: true)]) == .keepWatching, "标注恢复但草稿还在，不能当成已经发出")
        try check(PostSendWatch.verdict([.bound(draftCleared: true, textAppeared: false, imagesAppeared: true)]) == .keepWatching, "消息列表没有新增匹配正文时继续看")
        try check(PostSendWatch.verdict([.bound(draftCleared: true, textAppeared: true, imagesAppeared: false)]) == .keepWatching, "图片数量没增加时继续看")
        let stuck = Array(repeating: PostSendWatch.Sample.labelMismatch(other), count: 12)
        try check(PostSendWatch.verdict(stuck) == .keepWatching, "十二拍标注都对不上时不判成功")
        try check(PostSendWatch.verdict([.leftSession, .bound(draftCleared: true, textAppeared: true, imagesAppeared: true)]) == .abort, "已离开之后不再采纳后面看起来成功的读数")
        let unresolved = PostSendWatch.unresolvedDetail(trigger: "Return", selectedTitle: selected, observedLabel: other)
        try check(unresolved.contains("不再按第二次") && unresolved.contains(other) && unresolved.contains(selected), "对不上时仍只记一次 Return，并留下读到的另一个标注")
        try check(!SendAttempt.allowsSecondTrigger, "标注不符的核验结果也不解锁第二次发送")
        let plainUnresolved = PostSendWatch.unresolvedDetail(trigger: "Return", selectedTitle: selected, observedLabel: nil)
        try check(plainUnresolved == "已发出一次发送指令（Return），但无法确认图文/文件完整进入消息列表。为避免重复发送，本次不再按第二次。请到 QQ 查看；若 QQ 把发送快捷键设为 Command+Return，请在 QQ 设置里改为 Enter 发送或手动点发送按钮。不会自动重发", "没有读到另一个标注时，待核对文案与原来一致")
        let preSend = PostSendWatch.preSendMismatchDetail(marked: other, selected: selected)
        try check(preSend.contains("未粘贴、未发送") && preSend.contains("可能还在切换会话"), "发送前标注不符仍停在未粘贴、未发送")
        let afterPaste = PostSendWatch.preSendMismatchDetail(marked: other, selected: selected, draftMayExist: true)
        try check(afterPaste.contains("草稿可能已保留，未按发送键") && !afterPaste.contains("未粘贴"), "已写草稿后的会话错位不能声称未粘贴")
        try check(!preSend.contains("已按 Return") && !preSend.contains("不再按第二次"), "发送前失败不能写成已经发出发送指令")
        try check(PostSendWatch.preSendMismatchDetail(marked: "  ", selected: selected).contains("未命名会话"), "发送前读不到标注时按未命名会话停止")
        try check(PostSendWatch.verdict([.labelMismatch(other), .unreadable, .labelMismatch(other)]) == .keepWatching, "标题还在但输入框一直标着另一个群时，不能把空草稿当成已发出")
        let manualPlain = PostSendWatch.unresolvedDetail(trigger: "Return", selectedTitle: selected, observedLabel: nil, manual: true)
        try check(manualPlain == "已按人工核对发出一次发送指令（Return），但无法确认图文完整进入消息列表。为避免重复发送不再按第二次，请到 QQ 查看；不会自动重发", "人工续发对不上时仍只记一次指令")
        let manualSeen = PostSendWatch.unresolvedDetail(trigger: "Return", selectedTitle: selected, observedLabel: other, manual: true)
        try check(manualSeen.contains(other) && manualSeen.contains(selected) && manualSeen.contains("不再按第二次") && !manualSeen.contains("Command+Return"), "人工续发留下读到的另一个标注，不改成自动发送文案")
        // 重新入队保序：过期暂停任务不越过同计划里原排在它后面的待执行任务
        var requeueB1 = jobs[0]; requeueB1.id = "requeue-b1"; requeueB1.status = "blocked"; requeueB1.detail = "前台切换"; requeueB1.started = now; requeueB1.scheduled = now.addingTimeInterval(-3 * 3600)
        var requeueB2 = jobs[1]; requeueB2.id = "requeue-b2"; requeueB2.status = "blocked"; requeueB2.detail = "草稿不为空"; requeueB2.scheduled = now.addingTimeInterval(-2 * 3600)
        var requeueB3 = jobs[2]; requeueB3.id = "requeue-b3"; requeueB3.status = "blocked"; requeueB3.detail = "定位不到输入框"; requeueB3.scheduled = now.addingTimeInterval(-3600)
        var requeueQ1 = jobs[3]; requeueQ1.id = "requeue-q1"; requeueQ1.scheduled = now.addingTimeInterval(10 * 60)
        var requeueQ2 = jobs[4]; requeueQ2.id = "requeue-q2"; requeueQ2.scheduled = now.addingTimeInterval(20 * 60)
        let requeueJobs = [requeueB1, requeueB2, requeueB3, requeueQ1, requeueQ2]
        let requeueResult = Scheduling.requeued(requeueJobs, ids: [requeueB1.id, requeueB2.id, requeueB3.id], now: now, gap: 30)
        try check(Scheduling.ordered(requeueResult).map(\.id) == ["requeue-b1", "requeue-b2", "requeue-b3", "requeue-q1", "requeue-q2"], "重新入队后按排程排序与原相对顺序一致，暂停任务不跳到队尾")
        try check(requeueResult[0].status == "queued" && requeueResult[0].started == nil && requeueResult[0].finished == nil, "重新入队清空执行状态")
        try check(requeueResult[0].detail == "手动重新入队；上次暂停：前台切换", "重新入队保留上次暂停原因")
        try check(requeueResult[3].status == "queued" && requeueResult[3].detail == "等待执行" && requeueResult[4].detail == "等待执行", "序列里的原待执行任务只重排时间，不改状态")
        try check(requeueResult[0].scheduled == now && requeueResult[1].scheduled == now.addingTimeInterval(1800) && requeueResult[4].scheduled == now.addingTimeInterval(4 * 1800), "整条序列从基准时刻起按30分钟紧凑重排")
        // 无过去时间：最近发送活动在 5 分钟前时，首条不早于活动时间加间隔
        var requeueSent = jobs[5]; requeueSent.id = "requeue-sent"; requeueSent.status = "verified"; requeueSent.submittedAt = now.addingTimeInterval(-5 * 60); requeueSent.scheduled = now.addingTimeInterval(-3600)
        var requeueHeld = jobs[6]; requeueHeld.id = "requeue-held"; requeueHeld.status = "blocked"; requeueHeld.detail = "前台切换"; requeueHeld.scheduled = now.addingTimeInterval(-2 * 3600)
        let requeueClamped = Scheduling.requeued([requeueSent, requeueHeld], ids: [requeueHeld.id], now: now, gap: 30)
        try check(requeueClamped[1].scheduled == requeueSent.submittedAt!.addingTimeInterval(1800) && requeueClamped[1].scheduled >= now, "最近发送在5分钟前时，重新入队首条不早于活动时间加30分钟")
        try check(requeueClamped[0].scheduled == requeueSent.scheduled && requeueClamped[0].status == "verified", "已核验记录不参与重排")
        let requeuePaced = Scheduling.requeued([requeueSent, requeueHeld], ids: [requeueHeld.id], now: now, gap: 30, intervalByPlan: [plan.id: 60])
        try check(requeuePaced[1].scheduled == requeueSent.submittedAt!.addingTimeInterval(3600), "计划间隔更长时按计划间隔钳制重排起点")
        // 不可重试的暂停记录一律不动
        var requeueOneOff = jobs[0]; requeueOneOff.id = "requeue-oneoff"; requeueOneOff.status = "blocked"; requeueOneOff.oneOff = true; requeueOneOff.detail = "一次性草稿失败"; requeueOneOff.started = now; requeueOneOff.finished = now; requeueOneOff.scheduled = now.addingTimeInterval(-3600)
        var requeueSubmitted = jobs[1]; requeueSubmitted.id = "requeue-submitted"; requeueSubmitted.status = "blocked"; requeueSubmitted.submittedAt = now; requeueSubmitted.started = now; requeueSubmitted.scheduled = now.addingTimeInterval(-3600)
        var requeueEvidenced = jobs[2]; requeueEvidenced.id = "requeue-evidenced"; requeueEvidenced.status = "blocked"; requeueEvidenced.evidence = "回执"; requeueEvidenced.scheduled = now.addingTimeInterval(-3600)
        let requeueUntouched = Scheduling.requeued([requeueOneOff, requeueSubmitted, requeueEvidenced], ids: [requeueOneOff.id, requeueSubmitted.id, requeueEvidenced.id], now: now, gap: 30)
        try check(requeueUntouched[0].status == "blocked" && requeueUntouched[0].scheduled == requeueOneOff.scheduled && requeueUntouched[0].started == now && requeueUntouched[0].finished == now && requeueUntouched[0].detail == "一次性草稿失败", "一次性任务的暂停记录不被重新入队改写")
        try check(requeueUntouched[1].status == "blocked" && requeueUntouched[1].submittedAt == now && requeueUntouched[1].started == now && requeueUntouched[1].scheduled == requeueSubmitted.scheduled, "有提交记录的暂停记录字段原样保留")
        try check(requeueUntouched[2].status == "blocked" && requeueUntouched[2].evidence == "回执" && requeueUntouched[2].scheduled == requeueEvidenced.scheduled, "有发送凭据的暂停记录字段原样保留")
        var requeueMixed = jobs[3]; requeueMixed.id = "requeue-mixed"; requeueMixed.status = "blocked"; requeueMixed.detail = "前台切换"; requeueMixed.scheduled = now.addingTimeInterval(-3600)
        let requeueMixedResult = Scheduling.requeued([requeueOneOff, requeueMixed], ids: [requeueOneOff.id, requeueMixed.id], now: now, gap: 30)
        try check(requeueMixedResult[0].status == "blocked" && requeueMixedResult[0].scheduled == requeueOneOff.scheduled && requeueMixedResult[0].detail == "一次性草稿失败", "同计划重新入队时不可重试记录仍不被触碰")
        try check(requeueMixedResult[1].status == "queued" && requeueMixedResult[1].scheduled == now, "同计划可重试记录照常重新入队")
        // 多计划隔离：受影响计划各自独立重排，第三个计划不动
        var requeuePlanA = jobs[0]; requeuePlanA.id = "requeue-a"; requeuePlanA.planID = "plan-a"; requeuePlanA.status = "blocked"; requeuePlanA.scheduled = now.addingTimeInterval(-3600)
        var requeuePlanB = jobs[1]; requeuePlanB.id = "requeue-b"; requeuePlanB.planID = "plan-b"; requeuePlanB.status = "blocked"; requeuePlanB.scheduled = now.addingTimeInterval(-1800)
        var requeuePlanC = jobs[2]; requeuePlanC.id = "requeue-c"; requeuePlanC.planID = "plan-c"; requeuePlanC.scheduled = now.addingTimeInterval(45 * 60)
        let requeueIsolated = Scheduling.requeued([requeuePlanA, requeuePlanB, requeuePlanC], ids: [requeuePlanA.id, requeuePlanB.id], now: now, gap: 30)
        try check(requeueIsolated[2].scheduled == requeuePlanC.scheduled && requeueIsolated[2].status == "queued", "未涉及计划的待执行任务排程保持不变")
        try check(requeueIsolated[0].scheduled == now && requeueIsolated[1].scheduled == now, "两个受影响计划各自从基准时刻独立重排")
        // 保序重排不得把未来排程拉近：远期待执行任务保持原时间
        var requeueFar = jobs[3]; requeueFar.id = "requeue-far"; requeueFar.scheduled = now.addingTimeInterval(8 * 3600)
        var requeueNear = jobs[0]; requeueNear.id = "requeue-near"; requeueNear.status = "blocked"; requeueNear.detail = "前台切换"; requeueNear.scheduled = now.addingTimeInterval(-3600)
        let requeueFarResult = Scheduling.requeued([requeueNear, requeueFar], ids: [requeueNear.id], now: now, gap: 30)
        try check(requeueFarResult[0].scheduled == now && requeueFarResult[1].scheduled == requeueFar.scheduled, "重新入队不提前未来任务：远期任务保持原排程")
        try check(Scheduling.ordered(requeueFarResult).map(\.id) == ["requeue-near", "requeue-far"], "保序重排后相对顺序不变")
        // 循环发送：一轮收尾判定与下一轮自动接续（recurringEveryDays / cycleTag）
        try check(!Scheduling.cycleComplete([]), "空任务列表不算一轮收尾")
        var recurPlan = plan; recurPlan.recipientIDs = Array(recipients.prefix(3).map(\.id)); recurPlan.recurringEveryDays = 7
        var recurRound = try Scheduling.expand(recurPlan,recipients:recipients,assets:[],now:now)
        try check(recurRound.count == 3 && recurRound.allSatisfy { $0.cycleTag == nil }, "原始轮三群任务各差30分钟且不带轮次标记")
        for i in recurRound.indices { recurRound[i].status = "verified"; recurRound[i].submittedAt = now }
        try check(Scheduling.cycleComplete(recurRound), "全部核验完成算一轮收尾")
        recurRound[1].status = "manual"
        try check(Scheduling.cycleComplete(recurRound), "人工确认与界面核验同为终态")
        recurRound[2].status = "cancelled"
        try check(Scheduling.cycleComplete(recurRound), "含取消但其余全成功仍算收尾")
        for state in ["queued", "running", "draft", "submitted", "blocked", "uncertain"] {
            var pending = recurRound; pending[0].status = state
            try check(!Scheduling.cycleComplete(pending), "\(state) 还没出结果，不算收尾")
        }
        recurRound[1].status = "verified"; recurRound[2].status = "verified"
        let nextRound = try Scheduling.recur(recurPlan, jobs: recurRound, now: now, gap: 30)
        try check(nextRound != nil && nextRound!.count == 3, "三群全成功自动接续三条下一轮任务")
        try check(nextRound!.allSatisfy { $0.cycleTag == 1 }, "原始轮之后的下一轮标记第 1 轮")
        try check(nextRound!.allSatisfy { $0.status == "queued" }, "循环任务以待执行状态入队")
        try check(nextRound!.allSatisfy { $0.detail == "循环第 1 轮；自动接续上一轮" }, "循环任务说明写明轮次与自动接续")
        try check(nextRound!.allSatisfy { $0.started == nil && $0.submittedAt == nil && $0.finished == nil && $0.evidence.isEmpty }, "循环任务不继承上一轮执行痕迹")
        try check(Set(nextRound!.map(\.id)).isDisjoint(with: Set(recurRound.map(\.id))), "循环任务使用全新 id")
        try check(nextRound!.map(\.recipient) == recurRound.map(\.recipient), "循环任务沿用上一轮收件人")
        try check(nextRound!.allSatisfy { $0.text == recurRound[0].text && $0.mode == recurRound[0].mode && $0.assets == recurRound[0].assets && $0.recipientID != nil }, "循环任务沿用上一轮内容快照")
        try check(nextRound![0].scheduled == recurRound[0].scheduled.addingTimeInterval(7 * 86400), "新任务时间为上一轮时间加 7 天")
        try check(nextRound![1].scheduled.timeIntervalSince(nextRound![0].scheduled) == 1800 && nextRound![2].scheduled.timeIntervalSince(nextRound![0].scheduled) == 3600, "循环下一轮保留原时刻与逐群30分钟间隔")
        var round2Done = recurRound
        for i in round2Done.indices { round2Done[i].cycleTag = 2 }
        let round3 = try Scheduling.recur(recurPlan, jobs: round2Done, now: now, gap: 30)
        try check(round3 != nil && round3!.allSatisfy { $0.cycleTag == 3 && $0.detail.contains("循环第 3 轮") }, "上一轮已是第 2 轮时接续生成第 3 轮")
        var roundBlocked = recurRound; roundBlocked[1].status = "blocked"
        try check(try Scheduling.recur(recurPlan, jobs: roundBlocked, now: now, gap: 30) == nil, "本轮还有已暂停任务时不生成下一轮")
        var noCycle = recurPlan; noCycle.recurringEveryDays = nil
        try check(try Scheduling.recur(noCycle, jobs: recurRound, now: now, gap: 30) == nil, "未开循环的计划收尾后也不生成下一轮")
        // 顺延钳制：原时间加 1 天仍早于冷却下限时，整体按整天顺延且保留时刻
        var clampPlan = recurPlan; clampPlan.recurringEveryDays = 1
        var clampA = recurRound[0]; clampA.scheduled = now.addingTimeInterval(-10 * 60 - 86400); clampA.status = "verified"; clampA.submittedAt = now.addingTimeInterval(-5 * 60)
        var clampB = recurRound[1]; clampB.scheduled = clampA.scheduled.addingTimeInterval(1800); clampB.status = "verified"; clampB.submittedAt = now.addingTimeInterval(-4 * 60)
        let clamped = try Scheduling.recur(clampPlan, jobs: [clampA, clampB], now: now, gap: 30)
        let clampFloor = Scheduling.lastSendActivity([clampA, clampB])!.addingTimeInterval(1800)
        try check(clamped != nil && clamped!.count == 2, "需要顺延时仍生成下一轮任务")
        try check(clamped![0].scheduled >= clampFloor && clamped![0].scheduled >= now, "顺延后首条不早于最近发送活动加30分钟，也不早于当前时间")
        try check(clamped![0].scheduled == clampA.scheduled.addingTimeInterval(2 * 86400) && clamped![1].scheduled == clampB.scheduled.addingTimeInterval(2 * 86400), "原时间加一天仍过早时整体顺延一整天")
        try check(clamped![1].scheduled.timeIntervalSince(clamped![0].scheduled) == 1800, "整天顺延后逐群间隔与时刻不变")
        // 走查 1-10：循环天数只有 setRecurring 校验过，旧库/手工改库/恢复备份都可能带进 0 或负值
        try rejects("循环 0 天拒绝接续下一轮") { var p = recurPlan; p.recurringEveryDays = 0; _ = try Scheduling.recur(p, jobs: recurRound, now: now, gap: 30) }
        try rejects("循环负数天拒绝接续下一轮") { var p = recurPlan; p.recurringEveryDays = -3; _ = try Scheduling.recur(p, jobs: recurRound, now: now, gap: 30) }
        try rejects("循环超过 365 天拒绝接续下一轮") { var p = recurPlan; p.recurringEveryDays = 400; _ = try Scheduling.recur(p, jobs: recurRound, now: now, gap: 30) }
        var wideCycle = recurPlan; wideCycle.recurringEveryDays = 365
        try check(try Scheduling.recur(wideCycle, jobs: recurRound, now: now, gap: 30)?.count == 3, "一年以内的循环照常接续")
        // 走查 1-12：平移按 Calendar 加天，保留墙钟时刻，不再用定长 86400 秒
        var monthlyCycle = recurPlan; monthlyCycle.recurringEveryDays = 30
        let monthlyRound = try Scheduling.recur(monthlyCycle, jobs: recurRound, now: now, gap: 30)
        try check(monthlyRound!.enumerated().allSatisfy { $0.element.scheduled == Scheduling.shifted(recurRound[$0.offset].scheduled, byDays: 30) }, "下一轮时间等于原时间按天平移 30 天（走查 1-12）")
        try check(monthlyRound!.enumerated().allSatisfy { pair in
            let moved = Scheduling.calendar.dateComponents([.hour, .minute], from: pair.element.scheduled)
            let origin = Scheduling.calendar.dateComponents([.hour, .minute], from: recurRound[pair.offset].scheduled)
            return moved.hour == origin.hour && moved.minute == origin.minute
        }, "整月循环后每条任务仍保持自己的发送时刻，不因秒数平移漂移（走查 1-12）")
        try check(Scheduling.calendar.dateComponents([.day], from: recurRound[0].scheduled, to: monthlyRound![0].scheduled).day == 30, "下一轮与原轮正好相差 30 个日历天")
        let wallClock = Scheduling.calendar.startOfDay(for: now).addingTimeInterval(9 * 3600 + 30 * 60)
        try check(Scheduling.shifted(wallClock, byDays: 5) == Scheduling.calendar.date(byAdding: .day, value: 5, to: wallClock), "按天平移走日历而不是定长秒数")
        try check(Scheduling.calendar.component(.hour, from: Scheduling.shifted(wallClock, byDays: 5)) == 9 && Scheduling.calendar.component(.minute, from: Scheduling.shifted(wallClock, byDays: 5)) == 30, "平移五天后时刻仍是 09:30")
        // 取消排除：被取消的收件人不再进入下一轮
        var roundPartial = recurRound; roundPartial[0].status = "cancelled"
        let partialRound = try Scheduling.recur(recurPlan, jobs: roundPartial, now: now, gap: 30)
        try check(partialRound != nil && partialRound!.count == 2 && !partialRound!.contains { $0.recipient == roundPartial[0].recipient }, "上一轮被取消的群不再进入下一轮")
        var roundCancelled = recurRound
        for i in roundCancelled.indices { roundCancelled[i].status = "cancelled" }
        let emptyRound = try Scheduling.recur(recurPlan, jobs: roundCancelled, now: now, gap: 30)
        try check(emptyRound != nil && emptyRound!.isEmpty, "全部取消的收尾轮返回空数组而不是 nil")
        // 多场不塌缩：两群两场共四条任务，下一轮逐条复制，不再按收件人只留最晚一条
        var multiPlan = plan
        multiPlan.recipientIDs = Array(recipients.prefix(2).map(\.id))
        multiPlan.times = ["09:00","14:00"]; multiPlan.recurringEveryDays = 7
        multiPlan.starts = Scheduling.calendar.startOfDay(for: now).addingTimeInterval(86400)
        var multiRound = try Scheduling.expand(multiPlan, recipients: recipients, assets: [], now: now)
        for i in multiRound.indices { multiRound[i].status = "verified"; multiRound[i].submittedAt = now }
        let multiNext = try Scheduling.recur(multiPlan, jobs: multiRound, now: now, gap: 30)
        try check(multiNext != nil && multiNext!.count == 4 && multiNext!.allSatisfy { $0.cycleTag == 1 && $0.status == "queued" }, "两群两场的多场计划下一轮仍生成四条而不是塌缩成两条")
        try check(multiNext!.filter { $0.recipient == recipients[0].name }.count == 2 && multiNext!.filter { $0.recipient == recipients[1].name }.count == 2, "多场计划每群每场各保留一条，场次不丢失")
        try check(multiNext!.enumerated().allSatisfy { $0.element.scheduled == multiRound[$0.offset].scheduled.addingTimeInterval(7 * 86400) }, "多场计划每条任务时间等于自身原时间加 7 天")
        try check(multiNext![1].scheduled.timeIntervalSince(multiNext![0].scheduled) == 1800 && multiNext![3].scheduled.timeIntervalSince(multiNext![2].scheduled) == 1800, "多场下一轮同场群间 30 分钟间隔保持")
        // 第 2 轮（cycleTag=1 的多场四条）收尾后生成第 3 轮，模板只取 cycleTag 最大一轮
        var round1Done = multiNext!
        for i in round1Done.indices { round1Done[i].status = "verified"; round1Done[i].submittedAt = now }
        let multiRound3 = try Scheduling.recur(multiPlan, jobs: multiRound + round1Done, now: now, gap: 30)
        try check(multiRound3 != nil && multiRound3!.count == 4 && multiRound3!.allSatisfy { $0.cycleTag == 2 && $0.detail.contains("循环第 2 轮") }, "原始轮与第 1 轮并存时按第 1 轮模板接续生成四条第 2 轮任务")
        try check(multiRound3!.enumerated().allSatisfy { $0.element.scheduled == multiNext![$0.offset].scheduled.addingTimeInterval(7 * 86400) }, "第 3 轮时间基于第 2 轮任务再加 7 天，不回落到原始轮时间")
        // 一次性任务不阻塞：regular 全终态但一条 oneOff 卡在 queued，收尾判定与接续照常
        var withOneOff = recurRound
        var oneOffPending = recurRound[1]
        oneOffPending.id = "oneoff-pending"; oneOffPending.status = "queued"; oneOffPending.oneOff = true; oneOffPending.cloneOf = recurRound[1].id; oneOffPending.detail = "一次性补草稿"
        withOneOff.append(oneOffPending)
        try check(Scheduling.cycleComplete(withOneOff), "卡住的一次性补草稿不阻塞轮次收尾判定")
        try check(!Scheduling.cycleComplete([oneOffPending]), "只剩一次性任务时不判为收尾轮")
        let oneOffRound = try Scheduling.recur(recurPlan, jobs: withOneOff, now: now, gap: 30)
        try check(oneOffRound != nil && oneOffRound!.count == 3 && oneOffRound!.allSatisfy { !$0.isOneOff && $0.id != "oneoff-pending" }, "一次性任务不进入下一轮模板")
        // 名单移除：已移出 plan.recipientIDs 的收件人不再续发
        var removedOne = recurPlan; removedOne.recipientIDs = Array(recipients.prefix(2).map(\.id))
        let removedRound = try Scheduling.recur(removedOne, jobs: recurRound, now: now, gap: 30)
        try check(removedRound != nil && removedRound!.count == 2 && !removedRound!.contains { $0.recipient == recurRound[2].recipient }, "已从名单移除的收件人不再进入下一轮")
        var removedAll = recurPlan; removedAll.recipientIDs = []
        let noneLeft = try Scheduling.recur(removedAll, jobs: recurRound, now: now, gap: 30)
        try check(noneLeft != nil && noneLeft!.isEmpty, "名单收件人全部移除后收尾轮返回空数组而不是 nil")
        // 单计划 10000 条上限按「未取消任务」口径：历史取消不占额度
        var capJobs: [Delivery] = []
        capJobs.reserveCapacity(10000)
        for i in 0..<9996 { var job = recurRound[i % 3]; job.id = "cap-cancelled-\(i)"; job.status = "cancelled"; capJobs.append(job) }
        for i in 0..<4 { var job = recurRound[i % 3]; job.id = "cap-live-\(i)"; job.status = "verified"; capJobs.append(job) }
        let cancelledHeavy = try Scheduling.recur(recurPlan, jobs: capJobs, now: now, gap: 30)
        try check(cancelledHeavy != nil && cancelledHeavy!.count == 4 && cancelledHeavy!.allSatisfy { $0.cycleTag == 1 }, "上限只计未取消任务：大量历史取消不触发上限")
        var capOver: [Delivery] = []
        capOver.reserveCapacity(5001)
        for i in 0..<5001 { var job = recurRound[i % 3]; job.id = "cap-over-\(i)"; job.status = "verified"; capOver.append(job) }
        try rejects("循环接续超过单计划一万条未取消任务上限") { _ = try Scheduling.recur(recurPlan, jobs: capOver, now: now, gap: 30) }
        let atCap = try Scheduling.recur(recurPlan, jobs: Array(capOver.prefix(5000)), now: now, gap: 30)
        try check(atCap != nil && atCap!.count == 5000, "未取消任务加上新一轮恰好一万条时不拒绝")
        // 旧 JSON 兼容：缺新字段的行照常解码，nil 表示不循环与原始轮
        let legacyPlanJSON = Data("{\"id\":\"p1\",\"name\":\"旧计划\",\"text\":\"旧文案\",\"assetIDs\":[],\"recipientIDs\":[],\"starts\":0,\"days\":1,\"times\":[],\"intervalMinutes\":30,\"mode\":\"draft\",\"created\":0}".utf8)
        let decodedLegacyPlan = try JSONDecoder().decode(Plan.self, from: legacyPlanJSON)
        try check(decodedLegacyPlan.recurringEveryDays == nil && decodedLegacyPlan.name == "旧计划" && decodedLegacyPlan.mode == "draft", "旧计划行缺循环字段解码为不循环，其余字段保留")
        let legacyDeliveryJSON = Data("{\"id\":\"d1\",\"planID\":\"p1\",\"planName\":\"旧计划\",\"recipient\":\"旧群\",\"text\":\"正文\",\"assets\":[],\"scheduled\":1,\"mode\":\"automatic\",\"status\":\"verified\",\"detail\":\"旧记录\",\"evidence\":\"\"}".utf8)
        let decodedLegacyDelivery = try JSONDecoder().decode(Delivery.self, from: legacyDeliveryJSON)
        try check(decodedLegacyDelivery.cycleTag == nil && decodedLegacyDelivery.qqVerification == nil && decodedLegacyDelivery.recipient == "旧群" && decodedLegacyDelivery.status == "verified", "旧任务行缺核验与轮次字段兼容解码且保留原状态")
        try check(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(recurPlan)).recurringEveryDays == 7, "循环天数随计划存取往返保持")
        let roundtrip = try JSONDecoder().decode([Delivery].self, from: JSONEncoder().encode(nextRound!))
        try check(roundtrip.allSatisfy { $0.cycleTag == 1 }, "轮次标记随任务存取往返保持")
        // 性能加固回归：deliveries 差量持久化（未变化行 rowid 不变、删除落盘、事务失败不更新基线）
        do {
            let deltaRoot = root.appendingPathComponent("delta")
            let deltaDB = try Database(root: deltaRoot)
            var deltaJobs = (1...3).map { i -> Delivery in
                var job = jobs[0]
                job.id = "delta-\(i)"
                job.recipient = "增量群\(i)"
                job.status = "queued"; job.detail = "等待执行"
                job.started = nil; job.submittedAt = nil; job.finished = nil; job.evidence = ""
                return job
            }
            try deltaDB.save(Archive(recipients: recipients, assets: [], plans: [plan], deliveries: deltaJobs, settings: Settings(savedText: "")))
            let rowidsFirst = try deliveryRowids(at: deltaRoot)
            try check(rowidsFirst.count == 3, "首次保存全量写入并建立 deliveries 基线")
            deltaJobs[1].status = "verified"
            deltaJobs[1].submittedAt = now
            try deltaDB.save(Archive(recipients: recipients, assets: [], plans: [plan], deliveries: deltaJobs, settings: Settings(savedText: "")))
            let rowidsSecond = try deliveryRowids(at: deltaRoot)
            try check(rowidsSecond["delta-1"] == rowidsFirst["delta-1"] && rowidsSecond["delta-3"] == rowidsFirst["delta-3"], "只改一条时未变化行的 rowid 保持不变（不再整表 DELETE+INSERT）")
            let reloaded = try deltaDB.load("deliveries", as: Delivery.self)
            let reloadedByID = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.id, $0) })
            try check(reloaded.count == 3 && reloadedByID == Dictionary(uniqueKeysWithValues: deltaJobs.map { ($0.id, $0) }), "差量保存后回读三条全部字段与内存一致")
            try check(reloadedByID["delta-2"]?.status == "verified" && reloadedByID["delta-2"]?.submittedAt == now, "被改行内容差量落盘已更新")
            let removedJob = deltaJobs.removeLast()
            try deltaDB.save(Archive(recipients: recipients, assets: [], plans: [plan], deliveries: deltaJobs, settings: Settings(savedText: "")))
            let idsAfterDelete = try deltaDB.load("deliveries", as: Delivery.self).map(\.id).sorted()
            try check(idsAfterDelete == ["delta-1", "delta-2"] && !idsAfterDelete.contains(removedJob.id), "被删除的行差量落盘后 load 不到")
            let rowidsAfterDelete = try deliveryRowids(at: deltaRoot)
            try check(rowidsAfterDelete["delta-1"] == rowidsFirst["delta-1"], "删除其他行不影响未变化行的 rowid")
            // 基线失败一致性：失败事务不得更新差量基线，之后保存同内容数据仍须真正落盘
            var conflicted = Archive(recipients: recipients, assets: [], plans: [plan], deliveries: deltaJobs, settings: Settings(savedText: ""))
            deltaJobs[0].status = "verified"
            deltaJobs[0].submittedAt = now
            conflicted.deliveries = deltaJobs
            conflicted.recipients.append(recipients[0])
            try rejects("差量基线在事务失败时不更新") { try deltaDB.save(conflicted) }
            try check(try deltaDB.load("deliveries", as: Delivery.self).first(where: { $0.id == "delta-1" })?.status == "queued", "失败事务后磁盘保持上次成功内容")
            try check(try deltaDB.load("recipients", as: Recipient.self).count == recipients.count, "失败事务的名单表冲突行未写入")
            try deltaDB.save(Archive(recipients: recipients, assets: [], plans: [plan], deliveries: deltaJobs, settings: Settings(savedText: "")))
            try check(try deltaDB.load("deliveries", as: Delivery.self).first(where: { $0.id == "delta-1" })?.status == "verified", "失败后保存正常数据仍正确落盘（基线未错位）")
        }
        // 性能加固回归：dueDates 指纹缓存（命中一致、状态变化立即失效、多数据集不串缓存）
        do {
            var cachePlan = plan
            cachePlan.recipientIDs = Array(recipients.prefix(2).map(\.id))
            cachePlan.mode = "automatic"
            cachePlan.intervalMinutes = 30
            let cacheJobs = try Scheduling.expand(cachePlan, recipients: Array(recipients.prefix(2)), assets: [], now: now)
            try check(cacheJobs.count == 2, "缓存测试数据集两条任务")
            let once = Scheduling.nextCandidate(cacheJobs, gap: 30)
            let twice = Scheduling.nextCandidate(cacheJobs, gap: 30)
            try check(once?.id == cacheJobs[0].id && twice?.id == once?.id, "同输入两次 nextCandidate 结果一致（缓存命中）")
            try check(Scheduling.earliestSendDate(cacheJobs[1], jobs: cacheJobs, gap: 30) == cacheJobs[1].scheduled, "无发送历史时最早发送时间就是原排期")
            var advanced = cacheJobs
            advanced[0].status = "verified"
            advanced[0].submittedAt = advanced[0].scheduled.addingTimeInterval(600)
            try check(Scheduling.nextCandidate(advanced, gap: 30)?.id == advanced[1].id, "改一条状态后下一条立即切换（指纹失效生效）")
            try check(Scheduling.earliestSendDate(advanced[1], jobs: advanced, gap: 30) == advanced[1].scheduled.addingTimeInterval(600), "提交时间变化立即推后全局最早发送时间")
            var shifted = cacheJobs
            for i in shifted.indices { shifted[i].scheduled = shifted[i].scheduled.addingTimeInterval(3600) }
            try check(Scheduling.earliestSendDate(shifted[0], jobs: shifted, gap: 30) == shifted[0].scheduled, "同行数不同排期的数据集各自计算")
            try check(Scheduling.earliestSendDate(cacheJobs[0], jobs: cacheJobs, gap: 30) == cacheJobs[0].scheduled, "切回原数据集仍命中各自缓存（多数据集不串）")
        }
        // 排期清理（RecordPurge）：新排期开始时清理上一排期记录的纯函数决策（不碰持久化与发送）
        do {
            // 混合状态数据集：新计划 queued/uncertain/blocked 各一条；旧计划含沉淀状态、待核对与 running
            func purgeJob(_ id: String, planID: String, status: String, evidence: String = "", submitted: Bool = false) -> Delivery {
                var job = jobs[0]
                job.id = id
                job.planID = planID
                job.status = status
                job.evidence = evidence
                job.submittedAt = submitted ? now : nil
                return job
            }
            let mixed: [Delivery] = [
                purgeJob("purge-new-queued", planID: "plan-new", status: "queued"),
                purgeJob("purge-new-uncertain", planID: "plan-new", status: "uncertain", evidence: "新计划现场"),
                purgeJob("purge-new-blocked", planID: "plan-new", status: "blocked"),
                purgeJob("purge-old-verified", planID: "plan-old", status: "verified"),
                purgeJob("purge-old-manual", planID: "plan-old", status: "manual"),
                purgeJob("purge-old-cancelled", planID: "plan-old", status: "cancelled"),
                purgeJob("purge-old-blocked", planID: "plan-old", status: "blocked"),
                purgeJob("purge-old-draft", planID: "plan-old", status: "draft"),
                purgeJob("purge-old-queued", planID: "plan-old", status: "queued"),
                purgeJob("purge-old-uncertain", planID: "plan-old", status: "uncertain", evidence: "旧计划凭据", submitted: true),
                purgeJob("purge-old-submitted", planID: "plan-old", status: "submitted", submitted: true),
                purgeJob("purge-old-running", planID: "plan-old", status: "running"),
            ]
            // 1) 默认清理：新计划全保留、旧计划沉淀全删、uncertain/submitted 原样保留
            let conservative = RecordPurge.plan(all: mixed, keepingPlanID: "plan-new", includePendingReview: false, now: now)
            try check(conservative.kept.map(\.id) == ["purge-new-queued", "purge-new-uncertain", "purge-new-blocked", "purge-old-draft", "purge-old-uncertain", "purge-old-submitted", "purge-old-running"], "默认清理保留新计划全部与旧计划待核对、running、draft")
            try check(conservative.purged == 5, "默认清理只移除旧计划五条沉淀记录")
            try check(conservative.purgedPendingReview == 0, "默认清理从不清待核对记录")
            // 2) 用户确认后：uncertain/submitted 也删并单独计数
            let confirmed = RecordPurge.plan(all: mixed, keepingPlanID: "plan-new", includePendingReview: true, now: now)
            try check(confirmed.kept.map(\.id) == ["purge-new-queued", "purge-new-uncertain", "purge-new-blocked", "purge-old-draft", "purge-old-running"], "确认清理后只剩新计划全部与旧计划 running、draft")
            try check(confirmed.purged == 7, "确认清理移除旧计划沉淀与待核对共七条（draft 已保留）")
            try check(confirmed.purgedPendingReview == 2, "确认清理计数包含 uncertain 与 submitted 各一条")
            // 3) running 红线：旧计划的 running 在任何参数组合下都保留
            try check(RecordPurge.plan(all: mixed, keepingPlanID: "plan-new", includePendingReview: true, now: now).kept.contains { $0.id == "purge-old-running" }, "旧计划 running 在确认清理后仍保留")
            try check(RecordPurge.plan(all: mixed, keepingPlanID: "plan-old", includePendingReview: true, now: now).kept.contains { $0.id == "purge-old-running" }, "running 属于保留计划本身时同样不受影响")
            // 4) keepingPlanID 保护：确认清理时新计划自己的 uncertain/blocked 也原样保留
            try check(confirmed.kept.contains { $0.id == "purge-new-uncertain" } && confirmed.kept.contains { $0.id == "purge-new-blocked" }, "新计划 uncertain/blocked 受 keepingPlanID 保护不被清除")
            // 保护只来自 planID：同一条 uncertain 若不属于保留计划，确认后照常清除
            let flipped = RecordPurge.plan(all: mixed, keepingPlanID: "plan-old", includePendingReview: true, now: now)
            try check(!flipped.kept.contains { $0.id == "purge-new-uncertain" }, "不属于保留计划的 uncertain 不受 keepingPlanID 保护")
            // 5) 全部属于旧计划：按规则清到只剩该剩的
            let allOld = Array(mixed.dropFirst(3))
            let allOldConfirmed = RecordPurge.plan(all: allOld, keepingPlanID: "plan-new", includePendingReview: true, now: now)
            try check(allOldConfirmed.kept.map(\.id) == ["purge-old-draft", "purge-old-running"], "全旧计划确认清理后剩 draft 和 running")
            try check(allOldConfirmed.purged == 7 && allOldConfirmed.purgedPendingReview == 2, "全旧计划确认清理计数与混合场景一致")
            let allOldConservative = RecordPurge.plan(all: allOld, keepingPlanID: "plan-new", includePendingReview: false, now: now)
            try check(allOldConservative.kept.map(\.id) == ["purge-old-draft", "purge-old-uncertain", "purge-old-submitted", "purge-old-running"], "全旧计划默认清理保留 draft、待核对和 running")
            // 6) 空数组：什么都没有就什么都不清
            let empty = RecordPurge.plan(all: [], keepingPlanID: "plan-new", includePendingReview: true, now: now)
            try check(empty.kept.isEmpty && empty.purged == 0 && empty.purgedPendingReview == 0, "空输入清理结果全空")
            // 7) 顺序保持：保留记录的相对顺序与输入一致
            let orderInput: [Delivery] = [
                purgeJob("purge-seq-old-a", planID: "p", status: "verified"),
                purgeJob("purge-seq-new-a", planID: "plan-new", status: "queued"),
                purgeJob("purge-seq-old-b", planID: "p", status: "uncertain"),
                purgeJob("purge-seq-new-b", planID: "plan-new", status: "verified"),
                purgeJob("purge-seq-old-c", planID: "p", status: "running"),
            ]
            try check(RecordPurge.plan(all: orderInput, keepingPlanID: "plan-new", includePendingReview: false, now: now).kept.map(\.id) == ["purge-seq-new-a", "purge-seq-old-b", "purge-seq-new-b", "purge-seq-old-c"], "保留记录的相对顺序与输入一致")
            // 8) 带证据的待核对：用户确认后连证据一起清，默认保留供人工核对
            let withEvidence: [Delivery] = [purgeJob("purge-ev-uncertain", planID: "p", status: "uncertain", evidence: "截图收据", submitted: true)]
            try check(RecordPurge.plan(all: withEvidence, keepingPlanID: "other", includePendingReview: false, now: now).kept.map(\.id) == ["purge-ev-uncertain"], "带证据的旧计划待核对默认保留供人工核对")
            let evidencePurged = RecordPurge.plan(all: withEvidence, keepingPlanID: "other", includePendingReview: true, now: now)
            try check(evidencePurged.kept.isEmpty && evidencePurged.purged == 1 && evidencePurged.purgedPendingReview == 1, "用户确认后带证据的待核对连证据一起清除")
            // 9) 退化场景：输入全部是 running（跨新旧多个计划）——确认清理也不越过 running 红线
            let allRunning: [Delivery] = [
                purgeJob("purge-run-new", planID: "plan-new", status: "running"),
                purgeJob("purge-run-old-a", planID: "plan-old-a", status: "running"),
                purgeJob("purge-run-old-b", planID: "plan-old-b", status: "running"),
            ]
            let runningConfirmed = RecordPurge.plan(all: allRunning, keepingPlanID: "plan-new", includePendingReview: true, now: now)
            try check(runningConfirmed.kept.map(\.id) == allRunning.map(\.id) && runningConfirmed.kept.allSatisfy { $0.status == "running" }, "全部 running 且确认清理时 kept 只含 running 且一条不删")
            try check(runningConfirmed.purged == 0 && runningConfirmed.purgedPendingReview == 0, "全部 running 时确认清理不产生任何移除计数")
            // 10) 退化场景：输入全部属于保留计划本身——任何状态、任何参数下 kept 等于输入
            let samePlan: [Delivery] = [
                purgeJob("purge-same-queued", planID: "plan-x", status: "queued"),
                purgeJob("purge-same-uncertain", planID: "plan-x", status: "uncertain", submitted: true),
                purgeJob("purge-same-submitted", planID: "plan-x", status: "submitted", submitted: true),
                purgeJob("purge-same-blocked", planID: "plan-x", status: "blocked"),
                purgeJob("purge-same-running", planID: "plan-x", status: "running"),
                purgeJob("purge-same-verified", planID: "plan-x", status: "verified"),
            ]
            let samePlanConfirmed = RecordPurge.plan(all: samePlan, keepingPlanID: "plan-x", includePendingReview: true, now: now)
            try check(samePlanConfirmed.kept == samePlan && samePlanConfirmed.purged == 0 && samePlanConfirmed.purgedPendingReview == 0, "全部同一计划时 kept 等于输入且不产生移除")
            let samePlanConservative = RecordPurge.plan(all: samePlan, keepingPlanID: "plan-x", includePendingReview: false, now: now)
            try check(samePlanConservative.kept == samePlan && samePlanConservative.purged == 0, "全部同一计划时保守清理同样原样保留")
            // 11) 兜底证据防线：cancelled/queued 沉淀带 submittedAt 或 evidence 时与待核对待遇一致——
            // 它们可能对应一次真实发送（Core 的 lastSendActivity 把这类取消算进冷却），静默清除等于销毁对账凭证
            let sedimentWithTraces: [Delivery] = [
                purgeJob("purge-trace-cancelled", planID: "p", status: "cancelled", submitted: true),
                purgeJob("purge-trace-queued", planID: "p", status: "queued", evidence: "曾进入发送流程"),
            ]
            try check(RecordPurge.plan(all: sedimentWithTraces, keepingPlanID: "other", includePendingReview: false, now: now).kept.map(\.id) == ["purge-trace-cancelled", "purge-trace-queued"], "带提交/证据痕迹的取消与待执行沉淀默认保留")
            let traceConfirmed = RecordPurge.plan(all: sedimentWithTraces, keepingPlanID: "other", includePendingReview: true, now: now)
            try check(traceConfirmed.kept.isEmpty && traceConfirmed.purged == 2 && traceConfirmed.purgedPendingReview == 2, "确认后清理带痕迹沉淀并计入待核对计数")
            try check(RecordPurge.plan(all: [purgeJob("purge-clean-cancelled", planID: "p", status: "cancelled")], keepingPlanID: "other", includePendingReview: false, now: now).purged == 1, "无痕迹的取消沉淀仍按沉淀直接清理")
        }
        do {
            // 今日发送战报（DailySendReport）：三色仪表盘数据层的纯函数口径
            let cal = Scheduling.calendar
            let todayNoon = cal.startOfDay(for: now).addingTimeInterval(12 * 3600)
            let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            func reportJob(_ id: String, planID: String, status: String, finished: Date? = nil, started: Date? = nil) -> Delivery {
                var job = jobs[0]
                job.id = id
                job.planID = planID
                job.status = status
                job.finished = finished
                job.started = started
                return job
            }
            // 1) 混合状态计数：sent 只算今天核验（verified/manual），待核对=uncertain+submitted，拦截/待执行各归其类
            let mixed: [Delivery] = [
                reportJob("report-verified", planID: "planA", status: "verified", finished: todayNoon),
                reportJob("report-manual", planID: "planA", status: "manual", finished: todayNoon),
                reportJob("report-uncertain", planID: "planA", status: "uncertain"),
                reportJob("report-blocked", planID: "planA", status: "blocked"),
                reportJob("report-queued", planID: "planA", status: "queued"),
                reportJob("report-submitted", planID: "planB", status: "submitted"),
                reportJob("report-stale-verified", planID: "planB", status: "verified", finished: yesterday),
            ]
            let names = ["planA": "晨间问候", "planB": "晚间提醒"]
            let outcome = DailySendReport.today(deliveries: mixed, planNames: names, now: now, calendar: cal)
            try check(outcome.sent == 2 && outcome.pendingReview == 2 && outcome.blocked == 1 && outcome.queued == 1, "混合状态按口径计数：sent/待核对/已拦截/待执行")
            try check(outcome.hasContent, "存在非零计数时 hasContent 为真")
            // 2) 跨天 sent 不计入：昨天的 verified 不算今天的发送，但同计划今天的 submitted 仍在
            try check(outcome.lines.map(\.planName) == ["晨间问候", "晚间提醒"] && outcome.lines[0].sent == 2 && outcome.lines[0].pendingReview == 1 && outcome.lines[0].blocked == 1 && outcome.lines[0].queued == 1 && outcome.lines[1].pendingReview == 1 && outcome.lines[1].sent == 0, "计划行只含非零计数并按总数降序，跨天核验不计入 sent")
            // 3) finished 缺失回退 started 判同天
            let fallback = DailySendReport.today(deliveries: [reportJob("report-fallback", planID: "p", status: "verified", started: todayNoon)], planNames: ["p": "回退计划"], now: now, calendar: cal)
            try check(fallback.sent == 1 && fallback.lines.map(\.planName) == ["回退计划"], "verified 缺 finished 时回退 started 判定同天")
            // 4) 两者都缺失的 verified：不计 sent，也不落入其他三类
            let orphan = DailySendReport.today(deliveries: [reportJob("report-orphan", planID: "p", status: "verified")], planNames: ["p": "孤儿计划"], now: now, calendar: cal)
            try check(orphan.sent == 0 && orphan.pendingReview == 0 && orphan.blocked == 0 && orphan.queued == 0 && orphan.lines.isEmpty && !orphan.hasContent, "时间缺失的 verified 不计 sent 也不算其他三类")
            // 5) 存量口径：昨天的 uncertain / blocked 与刚入队的 queued 都不分天计入
            let stale = DailySendReport.today(deliveries: [
                reportJob("report-stale-uncertain", planID: "p", status: "uncertain", started: yesterday),
                reportJob("report-stale-blocked", planID: "p", status: "blocked", started: yesterday),
                reportJob("report-fresh-queued", planID: "p", status: "queued"),
            ], planNames: ["p": "存量计划"], now: now, calendar: cal)
            try check(stale.pendingReview == 1 && stale.blocked == 1 && stale.queued == 1 && stale.sent == 0, "待核对/已拦截/待执行是存量口径，不按日期过滤")
            // 6) planNames 缺失：记录自带 planName 快照时优先显示快照；快照为空才回退（已删计划）
            var snapshotJob = reportJob("report-deleted", planID: "gone", status: "blocked")
            try check(DailySendReport.today(deliveries: [snapshotJob], planNames: [:], now: now, calendar: cal).lines.map(\.planName) == ["测试"], "计划被删后战报优先显示记录自带的计划名快照")
            snapshotJob.planName = ""
            try check(DailySendReport.today(deliveries: [snapshotJob], planNames: [:], now: now, calendar: cal).lines.map(\.planName) == ["（已删计划）"], "快照为空时仍回退（已删计划）")
            // 7) lines 排序：按记录总数降序（3 > 2 > 1）
            let ranked: [Delivery] = [
                reportJob("report-r1", planID: "p1", status: "queued"),
                reportJob("report-r2a", planID: "p2", status: "queued"),
                reportJob("report-r2b", planID: "p2", status: "blocked"),
                reportJob("report-r3a", planID: "p3", status: "queued"),
                reportJob("report-r3b", planID: "p3", status: "blocked"),
                reportJob("report-r3c", planID: "p3", status: "uncertain"),
            ]
            let rankedOutcome = DailySendReport.today(deliveries: ranked, planNames: ["p1": "一", "p2": "二", "p3": "三"], now: now, calendar: cal)
            try check(rankedOutcome.lines.map(\.planName) == ["三", "二", "一"] && rankedOutcome.queued == 3 && rankedOutcome.blocked == 2 && rankedOutcome.pendingReview == 1, "计划行按记录总数降序排列")
            // 8) 空输入：全零、无行、无内容
            let empty = DailySendReport.today(deliveries: [], planNames: names, now: now, calendar: cal)
            try check(empty.sent == 0 && empty.pendingReview == 0 && empty.blocked == 0 && empty.queued == 0 && empty.lines.isEmpty && !empty.hasContent, "空输入战报全空且无内容")
        }
        do {
            // 自然语言时间快速输入（NaturalTime）：NSDataDetector 中文时间点 → 未来开始时间，过去时刻滚动到明天
            let cal = Scheduling.calendar
            func fixed(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
                cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
            }
            let ntNow = fixed(2026, 10, 6, 10, 0)        // 2026-10-06（周二）10:00，15:00/15:30 尚未到
            let ntEvening = fixed(2026, 10, 6, 16, 0)    // 同日下午 4 点，用于验证「已过则滚到明天」
            func dayDiff(_ a: Date, from base: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: base), to: cal.startOfDay(for: a)).day ?? -99 }
            func hm(_ date: Date) -> (Int, Int) { (cal.component(.hour, from: date), cal.component(.minute, from: date)) }
            // 1) 「明天 9 点」：语义就是明天 09:00，与当前时刻无关
            guard let t1 = NaturalTime.parse("明天 9 点", now: ntNow, calendar: cal) else { throw AppError("FAIL: 明天 9 点应能解析") }
            try check(dayDiff(t1, from: ntNow) == 1 && hm(t1) == (9, 0), "「明天 9 点」解析为明天 09:00")
            // 2) 「下午3点」无日期词：未过取今天 15:00；已过滚到明天 15:00
            guard let t2a = NaturalTime.parse("下午3点", now: ntNow, calendar: cal) else { throw AppError("FAIL: 下午3点应能解析") }
            try check(dayDiff(t2a, from: ntNow) == 0 && hm(t2a) == (15, 0), "「下午3点」未过取今天 15:00")
            guard let t2b = NaturalTime.parse("下午3点", now: ntEvening, calendar: cal) else { throw AppError("FAIL: 下午3点已过场景应能解析") }
            try check(dayDiff(t2b, from: ntEvening) == 1 && hm(t2b) == (15, 0), "「下午3点」已过滚动到明天 15:00")
            // 3) 「15:30」纯时刻：未过取今天，已过滚明天
            guard let t3a = NaturalTime.parse("15:30", now: ntNow, calendar: cal) else { throw AppError("FAIL: 15:30 应能解析") }
            try check(dayDiff(t3a, from: ntNow) == 0 && hm(t3a) == (15, 30), "「15:30」未过取今天 15:30")
            guard let t3b = NaturalTime.parse("15:30", now: ntEvening, calendar: cal) else { throw AppError("FAIL: 15:30 已过场景应能解析") }
            try check(dayDiff(t3b, from: ntEvening) == 1 && hm(t3b) == (15, 30), "「15:30」已过滚动到明天 15:30")
            // 4) 「后天 10 点」→ 10-08 10:00
            guard let t4 = NaturalTime.parse("后天 10 点", now: ntNow, calendar: cal) else { throw AppError("FAIL: 后天 10 点应能解析") }
            try check(dayDiff(t4, from: ntNow) == 2 && hm(t4) == (10, 0), "「后天 10 点」解析为后天 10:00")
            // 5) 「下周三」：宽松断言——与 now 差 1…13 天且为周三（gregorian weekday 4 = 周三，1 = 周日）
            guard let t5 = NaturalTime.parse("下周三", now: ntNow, calendar: cal) else { throw AppError("FAIL: 下周三应能解析") }
            try check((1...13).contains(dayDiff(t5, from: ntNow)) && cal.component(.weekday, from: t5) == 4, "「下周三」落在 1–13 天内且为周三")
            // 6) 看不懂的输入返回 nil，不静默猜测
            try check(NaturalTime.parse("哈哈哈", now: ntNow, calendar: cal) == nil, "无时间语义的文字返回 nil")
            try check(NaturalTime.parse("", now: ntNow, calendar: cal) == nil, "空文本返回 nil")
            // 7) 过去时刻（「昨天」）：NSDataDetector 也解析过去词，滚动规则兜底，结果必须晚于 now
            guard let t7 = NaturalTime.parse("昨天", now: ntNow, calendar: cal) else { throw AppError("FAIL: 昨天应能解析并滚动") }
            try check(t7 > ntNow, "「昨天」等过去表达滚动到未来，结果晚于 now")
            // 8) 全角数字「明天９点」（９为全角）：锁定当前行为——NSDataDetector 能识别全角数字，与半角「9」同解
            guard let t8 = NaturalTime.parse("明天９点", now: ntNow, calendar: cal) else { throw AppError("FAIL: 明天９点（全角）应能解析") }
            try check(dayDiff(t8, from: ntNow) == 1 && hm(t8) == (9, 0), "「明天９点」（全角数字）解析为明天 09:00")
            // 9) 「12-31 23:00」跨年滚动：now 为 12-31 深夜，解析出的当年 12-31 23:00 已过，滚动落到次年 1-1 23:00
            //（锁定 2026 年运行的行为：NSDataDetector 按当前年份解析「12-31」）
            let ntNewYearsEve = fixed(2026, 12, 31, 23, 30)
            guard let t9 = NaturalTime.parse("12-31 23:00", now: ntNewYearsEve, calendar: cal) else { throw AppError("FAIL: 12-31 23:00 应能解析") }
            try check(cal.component(.year, from: t9) == 2027 && hm(t9) == (23, 0) && dayDiff(t9, from: ntNewYearsEve) == 1, "「12-31 23:00」在 12-31 深夜已过时跨年滚动到次年 1-1 23:00")
            // 10) 「1月1日 9点」跨年正向：now 在 12 月中旬，NSDataDetector 直接取下一个未来的 1 月 1 日（次年）
            let ntMidDecember = fixed(2026, 12, 15, 10, 0)
            guard let t10 = NaturalTime.parse("1月1日 9点", now: ntMidDecember, calendar: cal) else { throw AppError("FAIL: 1月1日 9点 应能解析") }
            try check(cal.component(.year, from: t10) == 2027 && cal.component(.month, from: t10) == 1 && cal.component(.day, from: t10) == 1 && hm(t10) == (9, 0) && t10 > ntMidDecember, "「1月1日 9点」从 12 月中旬解析为次年 1-1 09:00（跨年正向）")
            // 11) 混合中英「tomorrow 下午3点」：英文词归一锚定后，detector 能合并中文时刻（旧实现会丢弃成 12:00）
            guard let t11 = NaturalTime.parse("tomorrow 下午3点", now: ntNow, calendar: cal) else { throw AppError("FAIL: tomorrow 下午3点 应能解析") }
            try check(dayDiff(t11, from: ntNow) == 1 && hm(t11) == (15, 0) && t11 > ntNow, "「tomorrow 下午3点」解析为明天 15:00（中英时刻合并）")
            // 12) 纯函数性：同输入两次解析结果完全一致；相对词按传入 now 归一，不随真实时钟漂移
            try check(NaturalTime.parse("明天 9 点", now: ntNow, calendar: cal) == t1, "同输入两次解析结果完全一致（纯函数）")
            guard let t12 = NaturalTime.parse("后天 8 点", now: ntEvening, calendar: cal) else { throw AppError("FAIL: 后天 8 点应能解析") }
            try check(dayDiff(t12, from: ntEvening) == 2 && hm(t12) == (8, 0), "「后天 8 点」从任意基准时刻解析均为后天 08:00")
            guard let t13 = NaturalTime.parse("10月8日 10:00", now: ntNow, calendar: cal) else { throw AppError("FAIL: 10月8日 应能解析") }
            try check(dayDiff(t13, from: ntNow) == 2 && hm(t13) == (10, 0), "「10月8日 10:00」按传入 now 定年份解析（基准 10-06 → 后天 10:00）")
        }
        print("\n\(passed) checks passed. No QQ messages sent.")
    }
}
