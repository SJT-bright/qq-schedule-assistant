import SwiftUI
import AppKit

@MainActor final class WorkflowDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var verificationEvidence: QQVerificationEvidence?
    var calls: [String] = []
    var behavior: (Delivery) async throws -> (String, String) = { _ in ("blocked", "隔离故障") }
    var inFlight = 0
    var maximum = 0
    func run(_ job: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; verificationEvidence = nil; calls.append(job.id)
        inFlight += 1; maximum = max(maximum, inFlight)
        defer { inFlight -= 1 }
        return try await behavior(job)
    }
}

@MainActor final class WorkflowPresentation: SendPresentationEffects {
    var events: [String] = []
    func showScheduler() { events.append("show") }
    func playSuccessSound() -> Bool { events.append("sound"); return true }
    func minimizeWindows(channel: String) async -> String? { events.append("minimize"); return nil }
    func mayMinimizeAfterFailure(channel: String) -> Bool { true }
}

@main @MainActor struct QueueWorkflowStoreTests {
    static var passed = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw AppError("FAIL: \(label)") }
        passed += 1; print("PASS: \(label)"); fflush(stdout)
    }
    static func idle(_ store: Store) async throws {
        let until = Date().addingTimeInterval(3)
        while store.busy, Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!store.busy, "隔离操作收尾")
    }
    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-workflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root), fake = WorkflowDriver(), presentation = WorkflowPresentation()
        let recipients = (1...4).map { Recipient(id: "r\($0)", name: "隔离群\($0)") }
        let image = Asset(id: "two-image-snapshot", name: "原图.png", relativePath: "assets/original.png", sha256: "snapshot", bytes: 100, isImage: true)
        func plan(_ id: String) -> Plan {
            Plan(id: id, name: "隔离队列\(id)", text: "旧队列原文", assetIDs: [image.id],
                 recipientIDs: recipients.map(\.id), starts: Date().addingTimeInterval(3600), days: 1,
                 times: [], intervalMinutes: 15, mode: "automatic", workspaceID: store.workspaceID)
        }
        func jobs(_ id: String) -> [Delivery] {
            recipients.enumerated().map { position, recipient in
                Delivery(id: "\(id)-\(position)", planID: id, planName: "隔离队列\(id)", recipient: recipient.name,
                         text: "原文快照\(position)", assets: [image, image],
                         scheduled: Date().addingTimeInterval(Double(3600 + position * 900)), mode: "automatic",
                         channel: SendChannel.qq, recipientID: recipient.id)
            }
        }
        func prepare(_ records: [Delivery]? = nil) async throws {
            store.stop(); try await idle(store)
            store.plans = [plan("A"), plan("B")]; store.recipients = recipients; store.assets = [image]
            store.deliveries = records ?? jobs("A") + jobs("B")
            store.guestMode = true; store.settings.globalGapMinutes = 15; store.settings.staggerJitter = false
            store.settings.restorePreviousApp = false; store.settings.returnToSchedulerAfterSend = false
            store.isolatedDispatchDriver = fake; store.error = nil; store.chosenPlanID = "A"
            store.isolatedPresentationEffects = presentation; presentation.events = []
            fake.calls = []; fake.maximum = 0; fake.behavior = { _ in ("blocked", "隔离故障") }
            try store.persist()
        }
        func makeDue(_ planID: String) {
            for i in store.deliveries.indices where store.deliveries[i].planID == planID && QueueBatch.canDispatch(store.deliveries[i]) {
                store.deliveries[i].scheduled = Date().addingTimeInterval(-10 + Double(i) / 100)
            }
        }
        func encoded<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return try e.encode(value) }

        // 限量只处理所选 N 条，失败也占一条；其他计划从未被启动。
        try await prepare()
        let beforeB = store.deliveries.filter { $0.planID == "B" }
        store.start(planID: "A", limit: 2); try await idle(store)
        try check(fake.calls == ["A-0"] && store.isQueueRunning("A") && !store.isQueueRunning("B"), "首条立即执行，额度与启动范围独立")
        makeDue("A"); store.tick(); try await idle(store); store.tick()
        try check(fake.calls == ["A-0", "A-1"] && !store.running && fake.maximum == 1, "故障跳过后处理第二条，达到两条即停止，全程串行")
        try check(store.deliveries.filter { $0.planID == "B" } == beforeB && store.queueJobs(planID: "A").filter(QueueBatch.canDispatch).count == 2, "未选群与其他计划保留待发")
        try check(try store.db.load("plans", as: Plan.self).first { $0.id == "A" }?.sendLimit == 2, "本次条数设置保存，重开不会自行续发")
        store.start(planID: "A", limit: 1); try await idle(store)
        try check(fake.calls == ["A-0", "A-1", "A-2"] && !store.running, "暂停继续只发剩余下一条，首群重新计时")

        // 两个有限批次同时运行，A 达到额度后仍接续 B，不串入未选群。
        try await prepare()
        fake.behavior = { _ in try await Task.sleep(nanoseconds: 60_000_000); return ("blocked", "隔离故障") }
        store.start(planID: "A", limit: 2); store.start(planID: "B", immediate: false, limit: 1)
        try await idle(store); makeDue("A"); makeDue("B")
        store.tick(); try await idle(store); store.tick(); try await idle(store); store.tick()
        try check(fake.calls == ["A-0", "A-1", "B-0"] && !store.running && fake.maximum == 1, "两队列各守额度，一条收尾后另一条正常接续")
        try check(presentation.events == ["show", "minimize", "show", "minimize", "show", "minimize"], "故障收窗且下一任务重新展开，不冒用成功音")

        // 取消 B 不取消 A 正在占用的串行操作。
        try await prepare()
        fake.behavior = { _ in try await Task.sleep(nanoseconds: 100_000_000); return ("blocked", "隔离故障") }
        store.start(planID: "A", limit: 2); store.start(planID: "B", immediate: false)
        try check(store.cancelQueue(planID: "B") && store.busy && store.isQueueRunning("A"), "取消别的队列保留当前在途任务")
        try await idle(store); makeDue("A"); store.tick(); try await idle(store)
        try check(fake.calls == ["A-0", "A-1"] && !store.running, "取消别的队列不影响本队列完成额度")

        // 取消后整队重开包含已发、人工已发、待核对及未发，使用独立批次。
        var originals = jobs("A")
        originals[0].status = "verified"; originals[0].evidence = "旧完成依据"
        originals[1].status = "manual"; originals[1].detail = "旧人工记录"
        originals[2].status = "uncertain"; originals[2].submittedAt = Date().addingTimeInterval(-100)
        originals[2].evidence = "已提交的旧线索"; originals[2].started = Date().addingTimeInterval(-101)
        var oneOff = originals[2]; oneOff.id = "old-one-off"; oneOff.oneOff = true; oneOff.cloneOf = originals[2].id
        try await prepare(originals + [oneOff] + jobs("B"))
        store.runningPlanIDs = ["B"]
        try check(store.cancelQueue(planID: "A") && store.isQueueRunning("B"), "取消所选队列，其他队列继续")
        let cancelledSnapshot = store.deliveries, untouchedB = store.plans[1]
        store.start(planID: "A", limit: 1); try await idle(store)
        let replay = store.queueJobs(planID: "A")
        try check(replay.count == 4 && Set(replay.map(\.id)).isDisjoint(with: Set(cancelledSnapshot.map(\.id))), "整队重开四条，包括已发群，全部新 UUID")
        try check(store.deliveries.filter { Set(cancelledSnapshot.map(\.id)).contains($0.id) } == cancelledSnapshot, "新一轮保留所有旧状态、原因与凭据")
        try check(replay.map(\.text) == originals.map(\.text) && replay.map(\.assets) == originals.map(\.assets), "整队使用各条原文与完整附件快照")
        try check(replay.allSatisfy { $0.submittedAt == nil && $0.evidence.isEmpty && $0.qqVerification == nil && $0.cloneOf == nil && !$0.isOneOff && $0.cycleTag == nil && $0.historyClearedAt == nil }, "新批次不继承旧提交、循环、人工克隆或归档依据")
        try check(store.isQueueRunning("B") && !store.isQueueRunning("A") && (try encoded(store.plans[1])) == (try encoded(untouchedB)), "限量重发只停止本计划，不改其他计划设置")
        var obsoleteQueued = originals[0]; obsoleteQueued.id = "orphan-old-batch"; obsoleteQueued.status = "queued"; obsoleteQueued.started = nil; obsoleteQueued.evidence = ""
        store.deliveries.append(obsoleteQueued) // 旧批次中即便出现 queued 也不可混入新队列。
        try check(store.nextDelivery(planID: "A")?.dispatchBatchID == store.plans[0].dispatchBatchID, "旧批次 queued 不参与新队列派发")
        store.deliveries.removeLast()

        // 第二次取消重开仍是四条，不复制上一次历史或人工一次性尝试。
        store.stop(planID: "B"); try check(store.cancelQueue(planID: "A"), "第二次取消")
        store.start(planID: "A", limit: 1); try await idle(store)
        try check(store.queueJobs(planID: "A").count == 4, "重复重开不把历次历史累加进模板")

        // 用户取消正在提交前/后的操作，已提交信息保留为 uncertain，禁止继续下一群。
        for submitted in [false, true] {
            try await prepare()
            fake.behavior = { _ in
                if submitted { try fake.beforeSubmit() }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return ("blocked", "不应运行至这里")
            }
            store.start(planID: "A")
            try await Task.sleep(nanoseconds: 40_000_000)
            try check(store.cancelQueue(planID: "A"), "在途取消可立即受理")
            try await idle(store); store.tick()
            let interrupted = store.deliveries.first { $0.id == "A-0" }!
            try check(fake.calls == ["A-0"] && !store.running && store.plans[0].queueCancelledAt != nil, "在途取消后不接续下一群")
            try check(interrupted.status == (submitted ? "uncertain" : "blocked") && (interrupted.submittedAt != nil) == submitted, "提交前后分别保留真实停止状态")
        }

        // 不发送原样保留提交痕迹，不影响正在等待的其他队列；旧快照与正在处理的记录拒绝。
        try await prepare(originals + jobs("B")); store.runningPlanIDs = ["B"]
        let reviewed = store.deliveries[2]
        try check(store.declineReviewed(reviewed), "核对页直接选择不发送，无弹窗")
        let declined = store.deliveries[2]
        try check(declined.status == "cancelled" && declined.submittedAt == reviewed.submittedAt && declined.started == reviewed.started && declined.evidence == reviewed.evidence && declined.detail.contains(reviewed.detail) && store.isQueueRunning("B"), "不发送保留旧凭据且不停止另一队列")
        try check(!store.declineReviewed(reviewed), "陈旧核对快照不会改写新状态")

        try await prepare(originals)
        let sourceWithAttempt = store.deliveries[2]
        var existingAttempt = jobs("A")[0]
        existingAttempt.id = "existing-review-attempt"
        existingAttempt.oneOff = true; existingAttempt.cloneOf = sourceWithAttempt.id
        existingAttempt.status = "blocked"
        store.deliveries.append(existingAttempt)
        let frozenWithAttempt = store.deliveries
        try check(!store.declineReviewed(sourceWithAttempt) && store.deliveries == frozenWithAttempt,
                  "原记录已有新尝试时，两种决定都须转到新记录，不改原记录")

        // 保存失败时不创建新轮或触发驱动，所有队列停止，内存和磁盘一致。
        try await prepare(); try check(store.cancelQueue(planID: "A"), "保存失败场景先取消")
        let beforeJobs = store.deliveries, beforePlans = try encoded(store.plans)
        store.recipients.append(recipients[0]); store.runningPlanIDs = ["B"]
        store.start(planID: "A", limit: 1)
        try check(fake.calls.isEmpty && !store.running && store.deliveries == beforeJobs && (try encoded(store.plans)) == beforePlans && store.error != nil, "新轮落盘失败整体回滚，不发送并暂停全部")
        store.recipients = recipients
        let copyRoot = root.appendingPathComponent("reopened")
        try store.db.backup(to: copyRoot)
        let reopened = try Store(root: copyRoot)
        try check(!reopened.running && reopened.plans.first { $0.id == "A" }?.queueCancelledAt != nil, "重开保留取消标记，不恢复运行态")

        // 成功必须有本次完整的两图凭据；少图时只留待核对，不响成功音。
        for images in [1, 2] {
            try await prepare([jobs("A")[0]])
            store.plans[0].recurringEveryDays = 1
            fake.behavior = { job in
                try fake.beforeSubmit()
                let submitted = store.deliveries.first { $0.id == job.id }!.submittedAt!
                fake.verificationEvidence = QQVerificationEvidence(deliveryID: job.id, selectedTitle: job.recipient,
                    trigger: "隔离单次提交", submittedAt: submitted,
                    firstObservedAt: submitted.addingTimeInterval(1), confirmedAt: submitted.addingTimeInterval(2),
                    baselineRowIDs: ["one", "two", "tail"], confirmedRowIDs: ["one", "two", "tail", "fresh-self"],
                    messageID: "fresh-self", textMatches: true, images: images, requiredImages: 2, draftCleared: true,
                    baselineAtLatest: true, confirmedAtLatest: true)
                return ("verified", "隔离完整图文结果")
            }
            store.start(planID: "A", limit: 1); try await idle(store); store.tick()
            let result = store.deliveries[0]
            try check(result.status == (images == 2 ? "verified" : "uncertain") && result.submittedAt != nil,
                      "缺图不得完成，完整两图与正文的本次凭据才通过")
            try check(presentation.events == (images == 2 ? ["show", "sound", "minimize"] : ["show", "minimize"]),
                      "只有严格成功才响音，结果保存后收窗")
            try check(store.deliveries.count == 1 && !store.running, "有限发送不接续循环，不因成功而超量")
        }

        // 新批次追加群仍属于当前批次，不继承旧历史的批次或排期。
        try await prepare(); try check(store.cancelQueue(planID: "A"), "追加场景先取消")
        store.start(planID: "A", limit: 1); try await idle(store)
        let addedRecipient = Recipient(id: "r5", name: "追加隔离群")
        store.recipients.append(addedRecipient)
        try check(store.appendRecipients(planID: "A", ids: [addedRecipient.id]), "新一轮可以追加群")
        try check(store.queueJobs(planID: "A").count == 5 && store.deliveries.last?.dispatchBatchID == store.plans[0].dispatchBatchID,
                  "追加任务参与当前批次派发")

        let batch = store.plans[0].dispatchBatchID
        let oldRecords = store.deliveries.filter { $0.dispatchBatchID != batch }
        let currentRecords = store.queueJobs(planID: "A")
        let source = TextTemplate(text: "新模板文字", assetIDs: [image.id], ownerPlanID: "A")
        store.plans[0].textTemplateID = source.id
        store.settings.broadcastWorkspaces?[0].templates = [source]
        let startupRefresh = LiveMessage.refreshed(store.archive, refreshReplaySnapshots: false)
        try check(startupRefresh.deliveries == store.deliveries, "重开不把整队重发快照自动换成新模板")
        _ = try store.saveTextTemplate(id: source.id, text: "用户明确修改的新图文", assetIDs: [image.id])
        try check(store.deliveries.filter { $0.dispatchBatchID != batch } == oldRecords, "明确同步模板也不改历次旧批次")
        try check(store.queueJobs(planID: "A").first == currentRecords.first
                  && store.queueJobs(planID: "A").filter(QueueBatch.canDispatch).allSatisfy { $0.text == "用户明确修改的新图文" && $0.assets == [image] },
                  "模板只刷新当前批次的未尝试任务，故障原文与附件仍保留")

        try await prepare()
        var stale = store.deliveries[0]; stale.text = "过时界面的错误正文"
        store.execute(stale)
        try check(fake.calls.isEmpty && !store.busy && store.deliveries[0] != stale, "过时界面快照不能被直接执行")

        // 老 Codable 资料可直接载入，新增字段全部缺省 nil。
        var oldPlan = try JSONSerialization.jsonObject(with: encoded(plan("legacy"))) as! [String: Any]
        for key in ["dispatchBatchID", "queueCancelledAt", "sendLimit"] { oldPlan.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Plan.self, from: JSONSerialization.data(withJSONObject: oldPlan))
        try check(decoded.dispatchBatchID == nil && decoded.queueCancelledAt == nil && decoded.sendLimit == nil, "旧计划向后兼容且不默认重发")
        print("\(passed) queue workflow store checks passed")
    }
}
