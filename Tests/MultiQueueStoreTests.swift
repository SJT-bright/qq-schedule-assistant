import SwiftUI
import AppKit

/// 所有调用均在隔离数据库和假驱动中执行；正式发送入口同时由环境保险开关拦截。
@MainActor final class MultiQueueIsolatedDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var calls: [String] = []
    var heldIDs: Set<String> = []
    var inFlight = 0
    var maximumInFlight = 0
    var behavior: (Delivery) throws -> (String, String) = { _ in ("blocked", "隔离驱动前置拦截") }

    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false
        calls.append(delivery.id)
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        while heldIDs.contains(delivery.id) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        return try behavior(delivery)
    }
}

@main @MainActor struct MultiQueueStoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError("FAIL: \(name)") }
        passed += 1; print("PASS: \(name)"); fflush(stdout)
    }
    static func awaitCondition(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(condition(), name)
    }

    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-multi-queue-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let fake = MultiQueueIsolatedDriver()
        let recipient = Recipient(id: "isolated-recipient", name: "隔离验收群")
        let spaceID = store.workspaceID
        func plan(_ id: String) -> Plan {
            Plan(id: id, name: "发送队列 \(id)", text: "隔离假驱动，不发送", assetIDs: [],
                 recipientIDs: [recipient.id], starts: Date().addingTimeInterval(-300), days: 1,
                 times: [], intervalMinutes: 1, mode: "automatic", workspaceID: spaceID)
        }
        func job(_ id: String, _ planID: String, future: Bool = false, status: String = "queued") -> Delivery {
            var result = Delivery(id: id, planID: planID, planName: "发送队列 \(planID)", recipient: "群 \(id)",
                                  text: "隔离假驱动，不发送", assets: [],
                                  scheduled: Date().addingTimeInterval(future ? 3600 : -300), mode: "automatic")
            result.status = status
            return result
        }
        func item(_ id: String) -> Delivery? { store.deliveries.first { $0.id == id } }
        func prepare(_ jobs: [Delivery]) async throws {
            store.stop()
            try await awaitCondition("上一隔离操作已结束") { !store.busy && !store.historyActionBusy }
            store.activePlanID = nil
            store.recipients = [recipient]; store.plans = [plan("A"), plan("B"), plan("C")]
            store.deliveries = jobs
            store.chosenPlanID = "A"; store.settings.globalGapMinutes = 0
            store.settings.notifyOnOutcome = false; store.settings.returnToSchedulerAfterSend = false
            store.settings.restorePreviousApp = false; store.guestMode = true; store.route = "queue"
            store.error = nil; store.isolatedDispatchDriver = fake
            fake.calls = []; fake.heldIDs = []; fake.maximumInFlight = 0; fake.cancelled = false
            fake.behavior = { _ in ("blocked", "隔离驱动前置拦截") }
            try store.persist()
        }

        // 正在 A 的前台操作中启动 B，只加入启动集合，不得进入第二个驱动。
        try await prepare([job("A-first", "A"), job("A-second", "A"), job("B-first", "B"), job("C-never", "C")])
        fake.heldIDs = ["A-first"]
        store.start(planID: "A", immediate: false)
        try await awaitCondition("A 已进入隔离前台通道") { fake.calls == ["A-first"] && store.busy }
        store.chosenPlanID = "B"
        store.start(planID: "B", immediate: false)
        store.tick(); store.tick()
        try check(store.runningPlanIDs == ["A", "B"] && store.isQueueRunning("A") && store.isQueueRunning("B"),
                  "忙碌时按排期启动 B 保留两个独立启动状态")
        try check(fake.calls == ["A-first"] && fake.maximumInFlight == 1 && store.processingPlanID == "A",
                  "启动或心跳不会重入唯一前台通道")
        try check(store.displayedQueuePlanID == "B" && store.chosenPlanID == "B",
                  "查看 B 不被正在执行的 A 拉回")
        store.stop(planID: "B")
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(store.runningPlanIDs == ["A"] && store.busy && store.processingPlanID == "A" && fake.inFlight == 1,
                  "暂停 B 不取消正在 A 的驱动")
        fake.heldIDs = []
        try await awaitCondition("A 前台操作正常收尾") { !store.busy }
        try check(item("A-first")?.status == "blocked" && item("B-first")?.status == "queued"
                    && store.displayedQueuePlanID == "B" && fake.maximumInFlight == 1,
                  "A 的结果只写 A 的日志且保持查看 B")

        // 暂停当前操作 A，只取消它；B 的启动状态及任务继续保留。
        try await prepare([job("pause-A", "A"), job("untouched-A", "A"), job("continue-B", "B"), job("untouched-C", "C")])
        fake.heldIDs = ["pause-A"]
        store.start(planID: "A", immediate: false)
        try await awaitCondition("暂停验收进入 A 驱动") { fake.calls == ["pause-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        store.stop(planID: "A")
        try await awaitCondition("暂停 A 的取消已收尾") { !store.busy }
        try check(store.running && store.runningPlanIDs == ["B"] && item("pause-A")?.status == "blocked"
                    && item("untouched-A")?.status == "queued", "暂停正在 A 后只移除 A 并保留未发任务")
        store.tick()
        try await awaitCondition("B 独立驱动收尾") { !store.busy }
        try check(fake.calls == ["pause-A", "continue-B"] && fake.maximumInFlight == 1
                    && item("untouched-C")?.status == "queued", "取消 A 之后 B 可以继续且不会夹带 C")

        // 完成 A 不停止正在等待的 B，也不加入未启动的 C。
        try await prepare([job("finished-A", "A"), job("waiting-B", "B", future: true), job("never-C", "C")])
        fake.heldIDs = ["finished-A"]
        store.start(planID: "A", immediate: false)
        try await awaitCondition("完成验收进入 A 驱动") { fake.calls == ["finished-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        fake.heldIDs = []
        try await awaitCondition("完成验收 A 操作收尾") { !store.busy }
        store.tick()
        try check(store.running && store.runningPlanIDs == ["B"] && fake.calls == ["finished-A"]
                    && item("waiting-B")?.status == "queued" && item("never-C")?.status == "queued",
                  "A 处理完后 B 继续等待，未启动 C 永远不加入")
        let bIndex = store.deliveries.firstIndex { $0.id == "waiting-B" }!
        store.deliveries[bIndex].scheduled = Date().addingTimeInterval(-1)
        store.tick()
        try await awaitCondition("B 到期后前台操作收尾") { !store.busy }
        store.tick()
        try check(!store.running && store.runningPlanIDs.isEmpty && fake.calls == ["finished-A", "waiting-B"]
                    && item("never-C")?.status == "queued", "所有已启动队列完成后不串入 C")

        // 批量取消仅作用于所选队列。
        try await prepare([job("cancel-A1", "A", future: true), job("cancel-A2", "A", future: true), job("keep-B", "B", future: true)])
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        let preservedB = item("keep-B")!
        store.cancelAllQueued(planIDs: ["A"])
        try check(store.runningPlanIDs == ["B"] && item("cancel-A1")?.status == "cancelled"
                    && item("cancel-A2")?.status == "cancelled" && item("keep-B") == preservedB && fake.calls.isEmpty,
                  "取消 A 的待发任务不影响 B 的数据或启动状态")

        // 假 verified 不满足核验门禁，保留提交检查点并继续其他队列，而不重发本条。
        try await prepare([job("fake-success-A", "A"), job("next-B", "B"), job("extra-A", "A"), job("no-C", "C")])
        fake.heldIDs = ["fake-success-A"]
        fake.behavior = { value in
            if value.id == "fake-success-A" { try fake.beforeSubmit(); return ("verified", "只有文字，没有消息结构凭据") }
            return ("blocked", "隔离驱动拦截")
        }
        store.start(planID: "A", immediate: false)
        try await awaitCondition("假成功验收进入 A 驱动") { fake.calls == ["fake-success-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        fake.heldIDs = []
        try await awaitCondition("假成功保存结束") { !store.busy }
        let unconfirmed = item("fake-success-A")!
        try check(unconfirmed.status == "uncertain" && unconfirmed.submittedAt != nil
                    && unconfirmed.qqVerification == nil && unconfirmed.evidence.isEmpty,
                  "缺少结构凭据的 fake verified 仍为 uncertain 并保留唯一提交")
        store.tick()
        try await awaitCondition("其他队列在假成功后继续") { !store.busy }
        try check(fake.calls == ["fake-success-A", "next-B"] && item("fake-success-A") == unconfirmed
                    && item("extra-A")?.status == "queued" && item("no-C")?.status == "queued",
                  "未确认结果不重试，A 自身冷却仍生效且 B 可继续")

        // 清空可在 A 在途时进行；后台备份后仅隐藏 A 的终态，不覆盖在途与其他队列。
        var oldA = job("old-A", "A", status: "uncertain")
        oldA.started = Date().addingTimeInterval(-7201); oldA.submittedAt = Date().addingTimeInterval(-7200)
        oldA.evidence = "原始提交证据"; oldA.detail = "原始待核对日志"
        var submittedA = job("submitted-A", "A", status: "submitted")
        submittedA.started = Date().addingTimeInterval(-7201); submittedA.submittedAt = Date().addingTimeInterval(-7200)
        submittedA.evidence = "在途检查点证据"
        var manualA = job("manual-A", "A", status: "manual"); manualA.finished = Date().addingTimeInterval(-7200)
        var oldB = job("old-B", "B", status: "manual"); oldB.finished = Date().addingTimeInterval(-7200)
        try await prepare([job("live-A", "A"), job("pending-A", "A"), oldA, submittedA, manualA, oldB])
        fake.heldIDs = ["live-A"]
        store.start(planID: "A", immediate: false)
        try await awaitCondition("清空验收 A 在途操作已占用通道") { fake.calls == ["live-A"] && store.busy }
        let beforeClear = store.deliveries
        store.clearHistory(planIDs: ["A"])
        try await awaitCondition("清空的后台备份和数据库标记保存完成") { !store.historyActionBusy }
        try check(store.busy && store.processingPlanID == "A" && store.runningPlanIDs == ["A"] && fake.calls == ["live-A"],
                  "清空记录不暂停或重入当前发送")
        try check(item("old-A")?.historyClearedAt != nil && item("manual-A")?.historyClearedAt != nil
                    && item("old-B")?.historyClearedAt == nil && item("live-A")?.historyClearedAt == nil
                    && item("pending-A")?.historyClearedAt == nil && item("submitted-A")?.historyClearedAt == nil,
                  "只隐藏所选 A 的历史，其他队列、queued、running、submitted 保留")
        let withoutMarkers = store.deliveries.map { value -> Delivery in var original = value; original.historyClearedAt = nil; return original }
        try check(withoutMarkers == beforeClear, "清空仅修改可见标记，状态、提交时间和证据全部不变")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("history-archives"), includingPropertiesForKeys: nil)
        let backup = try HistoryArchive.readBackup(at: files.last!)
        try check(Set(backup.deliveries.map(\.id)) == ["old-A", "manual-A"]
                    && backup.deliveries.first(where: { $0.id == "old-A" }) == oldA,
                  "清空前完整日志和精确提交时间保存到可恢复备份")
        let hiddenDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(hiddenDisk.first(where: { $0.id == "old-A" })?.historyClearedAt != nil
                    && hiddenDisk.first(where: { $0.id == "submitted-A" }) == submittedA,
                  "隐藏标记真实持久化且在途证据原样落盘")
        store.restoreHistory(planIDs: ["A"])
        try check(store.deliveries == beforeClear && store.busy && fake.calls == ["live-A"],
                  "恢复只撤销可见标记，不发送、改状态或影响在途驱动")
        store.stop(planID: "A")
        try await awaitCondition("清空验收在途操作安全退出") { !store.busy }

        // 整库事务失败：不论出错点在哪，都停下全部发送，保留回滚后的原始记录。
        try await prepare([job("save-A", "A", future: true), job("save-B", "B", future: true)])
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        let beforeFailedStart = store.deliveries
        store.recipients.append(recipient) // 隔离库重复主键，真实 SQLite 事务失败。
        let saveIndex = store.deliveries.firstIndex { $0.id == "save-A" }!
        store.deliveries[saveIndex].scheduled = Date().addingTimeInterval(-1)
        let intended = store.deliveries[saveIndex]
        store.tick()
        try check(!store.running && store.runningPlanIDs.isEmpty && !store.busy && store.processingPlanID == nil
                    && fake.calls.isEmpty && item("save-A") == intended && item("save-B") == beforeFailedStart.last
                    && store.error != nil, "驱动开始前数据库失败停止全部队列且不调用驱动")

        try await prepare([job("checkpoint-A", "A"), job("checkpoint-B", "B", future: true)])
        fake.heldIDs = ["checkpoint-A"]
        fake.behavior = { _ in
            store.recipients.append(recipient)
            defer { store.recipients = [recipient] }
            try fake.beforeSubmit()
            return ("blocked", "检查点失败后不应提交")
        }
        store.start(planID: "A", immediate: false)
        try await awaitCondition("检查点验收已进入 A 驱动") { fake.calls == ["checkpoint-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        fake.heldIDs = []
        try await awaitCondition("检查点保存失败已收尾") { !store.busy }
        try check(!store.running && store.runningPlanIDs.isEmpty && fake.calls == ["checkpoint-A"]
                    && item("checkpoint-A")?.submittedAt == nil && item("checkpoint-B")?.status == "queued"
                    && store.error != nil, "单次提交检查点保存失败停止全部队列且不残留假提交")

        try await prepare([job("outcome-A", "A"), job("outcome-B", "B", future: true)])
        fake.heldIDs = ["outcome-A"]
        fake.behavior = { _ in store.recipients.append(recipient); return ("blocked", "结果事务将失败") }
        store.start(planID: "A", immediate: false)
        try await awaitCondition("结果失败验收已进入 A 驱动") { fake.calls == ["outcome-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        fake.heldIDs = []
        try await awaitCondition("结果保存失败已收尾") { !store.busy }
        let failedDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(!store.running && store.runningPlanIDs.isEmpty && item("outcome-A")?.status == "running"
                    && failedDisk.first(where: { $0.id == "outcome-A" })?.status == "running"
                    && item("outcome-B")?.status == "queued" && store.error != nil,
                  "结果保存失败停止全部队列且原 running 检查点在内存和磁盘一致")

        try await prepare([job("clear-pending-A", "A", future: true), job("clear-pending-B", "B", future: true), oldA])
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        store.recipients.append(recipient)
        store.clearHistory(planIDs: ["A"])
        try await awaitCondition("清空事务失败的后台操作收尾") { !store.historyActionBusy }
        try check(!store.running && store.runningPlanIDs.isEmpty && item("old-A") == oldA && fake.calls.isEmpty
                    && store.error != nil, "清空保存失败回滚标记并停止全部队列")

        try await prepare([job("clear-flight-A", "A"), job("clear-flight-B", "B", future: true), oldA])
        fake.heldIDs = ["clear-flight-A"]
        fake.behavior = { _ in try fake.beforeSubmit(); return ("verified", "数据库失败后不得到达提交") }
        store.start(planID: "A", immediate: false)
        try await awaitCondition("清空事务失败验收进入 A 在途驱动") { fake.calls == ["clear-flight-A"] && store.busy }
        store.start(planID: "B", immediate: false)
        store.recipients.append(recipient)
        store.clearHistory(planIDs: ["A"])
        try await awaitCondition("清空失败取消在途操作完成") { !store.historyActionBusy && !store.busy }
        try check(!store.running && store.runningPlanIDs.isEmpty && item("old-A") == oldA
                    && item("clear-flight-A")?.submittedAt == nil && item("clear-flight-B")?.status == "queued"
                    && fake.calls == ["clear-flight-A"] && store.error != nil,
                  "发送中清空保存失败取消所有操作，不再到达提交检查点")

        var hiddenA = oldA; hiddenA.historyClearedAt = Date().addingTimeInterval(-100)
        try await prepare([job("restore-pending-A", "A", future: true), job("restore-pending-B", "B", future: true), hiddenA])
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        store.recipients.append(recipient)
        store.restoreHistory(planIDs: ["A"])
        try check(!store.running && store.runningPlanIDs.isEmpty && item("old-A") == hiddenA && fake.calls.isEmpty
                    && store.error != nil, "恢复保存失败回滚标记并停止全部队列")

        try await prepare([job("cancel-save-A", "A", future: true), job("cancel-save-B", "B", future: true)])
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        let beforeFailedCancel = store.deliveries
        store.recipients.append(recipient)
        store.cancelAllQueued(planIDs: ["A"])
        try check(!store.running && store.runningPlanIDs.isEmpty && store.deliveries == beforeFailedCancel
                    && fake.calls.isEmpty && store.error != nil, "取消保存失败回滚任务并停止全部队列")

        // 新队列的模板必须有自己的 owner，不能因空间中只剩一条新模板而吸附旧 nil 计划。
        try await prepare([])
        let legacyImage = Asset(id: "legacy-queue-image", name: "旧群原图.png", relativePath: "assets/legacy-queue-image.png",
                                sha256: "isolated-legacy-image", bytes: 1, isImage: true)
        let newImage = Asset(id: "new-queue-image", name: "新队列图.png", relativePath: "assets/new-queue-image.png",
                             sha256: "isolated-new-image", bytes: 1, isImage: true)
        let bImage = Asset(id: "B-queue-image", name: "B队列图.png", relativePath: "assets/B-queue-image.png",
                           sha256: "isolated-B-image", bytes: 1, isImage: true)
        var legacyPlan = plan("legacy-unlinked")
        legacyPlan.name = "旧版群发"; legacyPlan.text = "旧队列原文，不能被新队列吸附"
        legacyPlan.assetIDs = [legacyImage.id]; legacyPlan.textTemplateID = nil
        var legacyJob = job("legacy-original-job", legacyPlan.id, future: true)
        legacyJob.text = legacyPlan.text; legacyJob.assets = [legacyImage]
        var emptySpace = BroadcastWorkspace(id: spaceID, name: "默认群发")
        emptySpace.draft.text = legacyPlan.text; emptySpace.draft.assetIDs = [legacyImage.id]
        emptySpace.draft.recipientIDs = [recipient.id]
        store.settings.broadcastWorkspaces = [emptySpace]; store.settings.activeWorkspaceID = spaceID
        store.settings.textTemplates = []; store.settings.savedText = legacyPlan.text
        store.assets = [legacyImage, newImage, bImage]; store.plans = [legacyPlan]; store.deliveries = [legacyJob]
        try store.persist()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func encoded<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
        let originalLegacyPlanData = try encoded(legacyPlan)
        var newA = plan("owned-queue-A")
        newA.name = "独立队列 A"; newA.text = "新队列 A 的原文"; newA.assetIDs = [newImage.id]
        newA.starts = Date().addingTimeInterval(7200)
        try store.addPlan(newA)
        let savedA = store.plans.first { $0.id == newA.id }!
        let aTemplate = store.workspaces.first { $0.id == spaceID }!.templates.first { $0.id == savedA.textTemplateID }!
        try check(try encoded(store.plans.first { $0.id == legacyPlan.id }!) == originalLegacyPlanData
                    && item(legacyJob.id) == legacyJob,
                  "旧计划 nil 模板且空间无模板时，创建新队列保留旧计划和原始图文任务")
        try check(aTemplate.ownerPlanID == newA.id && aTemplate.text == newA.text && aTemplate.assetIDs == [newImage.id]
                    && savedA.textTemplateID == aTemplate.id,
                  "创建的新队列与自己的 owner 模板绑定")
        let originalAJob = store.deliveries.first { $0.planID == newA.id }!
        try check(originalAJob.text == newA.text && originalAJob.assets == [newImage] && !store.running && fake.calls.isEmpty,
                  "创建队列只保存自己的图文，不启动或发送任何队列")

        var newB = plan("owned-queue-B")
        newB.name = "独立队列 B"; newB.text = "新队列 B 的原文"; newB.assetIDs = [bImage.id]
        newB.starts = Date().addingTimeInterval(10800)
        try store.addPlan(newB)
        let savedB = store.plans.first { $0.id == newB.id }!
        let originalBJob = store.deliveries.first { $0.planID == newB.id }!
        let bTemplate = store.workspaces.first { $0.id == spaceID }!.templates.first { $0.id == savedB.textTemplateID }!
        try check(bTemplate.ownerPlanID == newB.id && bTemplate.id != aTemplate.id
                    && item(originalAJob.id) == originalAJob && item(legacyJob.id) == legacyJob,
                  "第二条队列得到不同 owner 模板且不修改 A 或 legacy")
        _ = try store.saveTextTemplate(id: aTemplate.id, text: "只修改 A 的正文", workspaceID: spaceID,
                                      assetIDs: [legacyImage.id])
        let editedA = store.plans.first { $0.id == newA.id }!
        let editedAJob = item(originalAJob.id)!
        try check(editedA.text == "只修改 A 的正文" && editedA.assetIDs == [legacyImage.id]
                    && editedAJob.text == editedA.text && editedAJob.assets == [legacyImage],
                  "修改 A 模板同步 A 的未发正文和图片")
        try check(item(originalBJob.id) == originalBJob && item(legacyJob.id) == legacyJob
                    && (try encoded(store.plans.first { $0.id == legacyPlan.id }!)) == originalLegacyPlanData
                    && (try encoded(store.plans.first { $0.id == newB.id }!)) == (try encoded(savedB)),
                  "编辑 A 不修改 B 或旧 nil 计划及其图文")

        // SQLite 失败不能留下模板、草稿或计划的一半更新，磁盘同样没有新队列。
        let beforeFailureSettings = store.settings, beforeFailurePlans = store.plans, beforeFailureJobs = store.deliveries
        let diskPlansBefore = try store.db.load("plans", as: Plan.self)
        let diskJobsBefore = try store.db.load("deliveries", as: Delivery.self)
        let diskSettingsBefore = try store.db.load("settings", as: Settings.self)
        store.recipients.append(recipient)
        var failedPlan = plan("failed-owned-queue")
        failedPlan.text = "失败不得留下孤儿模板"; failedPlan.assetIDs = [newImage.id]
        failedPlan.starts = Date().addingTimeInterval(14400)
        var saveRejected = false
        do { try store.addPlan(failedPlan) } catch { saveRejected = true }
        try check(saveRejected && (try encoded(store.settings)) == (try encoded(beforeFailureSettings))
                    && (try encoded(store.plans)) == (try encoded(beforeFailurePlans)) && store.deliveries == beforeFailureJobs,
                  "新队列保存失败整体回滚 Settings、所有 plans 和 jobs，不留下 owner 模板或草稿修改")
        let diskPlansAfter = try store.db.load("plans", as: Plan.self)
        let diskJobsAfter = try store.db.load("deliveries", as: Delivery.self)
        let diskSettingsAfter = try store.db.load("settings", as: Settings.self)
        try check((try encoded(diskPlansAfter)) == (try encoded(diskPlansBefore))
                    && diskJobsAfter == diskJobsBefore && (try encoded(diskSettingsAfter)) == (try encoded(diskSettingsBefore)),
                  "保存失败的 SQLite 事务没有半个新队列、模板或草稿留在磁盘")
        store.recipients = [recipient]; store.error = nil
        try store.persist()

        let reloadedRoot = root.appendingPathComponent("owned-template-reloaded")
        try store.db.backup(to: reloadedRoot)
        let reloaded = try Store(root: reloadedRoot)
        try check(reloaded.deliveries.first { $0.id == legacyJob.id } == legacyJob
                    && (try encoded(reloaded.plans.first { $0.id == legacyPlan.id }!)) == originalLegacyPlanData
                    && reloaded.deliveries.first { $0.id == originalAJob.id } == editedAJob
                    && reloaded.deliveries.first { $0.id == originalBJob.id } == originalBJob,
                  "重载 Store 的 linked/refreshed 仍保留 A、B、旧 nil 计划各自图文")
        try check(!reloaded.running && reloaded.runningPlanIDs.isEmpty
                    && reloaded.plans.first { $0.id == newA.id }?.textTemplateID == aTemplate.id
                    && reloaded.plans.first { $0.id == newB.id }?.textTemplateID == bTemplate.id,
                  "重载保留独立模板身份，保持所有队列未启动")

        // 使用真实编排页的带空间前缀名称，不用直接构造无前缀名称绕过编号规则。
        var createdNames: [String] = [], draftNames: [String] = []
        for index in 0..<3 {
            store.beginNewQueue()
            let draft = store.workspaces.first { $0.id == spaceID }!.draft
            draftNames.append(draft.name)
            var numbered = plan("numbered-queue-\(index)")
            numbered.name = "【\(store.workspaceName)】" + draft.name
            numbered.text = "编号队列 \(index)"; numbered.assetIDs = [newImage.id]
            numbered.starts = Date().addingTimeInterval(Double(18000 + index * 3600))
            try store.addPlan(numbered)
            createdNames.append(store.plans.first { $0.id == numbered.id }!.name)
        }
        try check(Set(draftNames).count == 3 && Set(createdNames).count == 3
                    && createdNames.allSatisfy { $0.hasPrefix("【默认群发】发送队列 ") },
                  "连续新建并保存带前缀队列名称时编号各不相同")
        try check(store.workspaces.first { $0.id == spaceID }!.templates.first { $0.id == aTemplate.id }?.ownerPlanID == newA.id
                    && store.workspaces.first { $0.id == spaceID }!.templates.first { $0.id == bTemplate.id }?.ownerPlanID == newB.id
                    && item(originalAJob.id) == editedAJob && item(originalBJob.id) == originalBJob && item(legacyJob.id) == legacyJob,
                  "新建队列的 saveDraft 不覆盖已有 owner 模板或其他图文任务")
        store.stop(); store.isolatedDispatchDriver = nil
        print("PASS: \(passed) multi-queue Store checks. Isolated SQLite and fake driver; no QQ sends.")
    }
}
