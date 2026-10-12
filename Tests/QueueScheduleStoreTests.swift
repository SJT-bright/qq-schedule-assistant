import SwiftUI
import AppKit

/// 隔离的唯一前台通道：可在某条任务内等待，用于证明编辑另一队列不会取消、重入或触发提交。
@MainActor final class QueueScheduleIsolatedDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var calls: [String] = []
    var heldIDs: Set<String> = []
    var inFlight = 0
    var maximumInFlight = 0

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
        return ("blocked", "隔离假驱动，只检验队列操作，不提交消息")
    }
}

@main @MainActor struct QueueScheduleStoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError("FAIL: \(name)") }
        passed += 1; print("PASS: \(name)"); fflush(stdout)
    }
    static func waitUntil(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { throw AppError("FAIL: \(name)") }
    }

    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-queue-schedule-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let fake = QueueScheduleIsolatedDriver()
        let now = Date()
        let recipient = Recipient(id: "schedule-test-recipient", name: "隔离排期验收群")
        let spaceID = store.workspaceID
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func encoded<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
        // 差量保存的更新行可能取得新rowid；核对逐条资料，不把SQLite读取顺序误当成内容变化。
        func sameJobs(_ lhs: [Delivery], _ rhs: [Delivery]) -> Bool {
            lhs.sorted { $0.id < $1.id } == rhs.sorted { $0.id < $1.id }
        }
        func plan(_ id: String) -> Plan {
            Plan(id: id, name: "隔离队列 \(id)", text: "隔离排期，不发送", assetIDs: [],
                 recipientIDs: [recipient.id], starts: now.addingTimeInterval(600), days: 1,
                 times: [], intervalMinutes: 15, mode: "automatic", workspaceID: spaceID)
        }
        func job(_ id: String, _ planID: String, offset: TimeInterval = 600, status: String = "queued") -> Delivery {
            var value = Delivery(id: id, planID: planID, planName: "隔离队列 \(planID)", recipient: "群 \(id)",
                                 text: "隔离排期，不发送", assets: [], scheduled: now.addingTimeInterval(offset), mode: "automatic")
            value.status = status
            return value
        }
        func item(_ id: String) -> Delivery? { store.deliveries.first { $0.id == id } }
        func prepare(_ jobs: [Delivery]) async throws {
            store.stop()
            try await waitUntil("上一假驱动操作必须结束") { !store.busy && !store.historyActionBusy }
            store.activePlanID = nil
            store.recipients = [recipient]; store.plans = [plan("A"), plan("B")]; store.deliveries = jobs
            store.chosenPlanID = "A"; store.settings.globalGapMinutes = 7
            store.settings.notifyOnOutcome = false; store.settings.returnToSchedulerAfterSend = false
            store.settings.restorePreviousApp = false; store.guestMode = true; store.route = "queue"
            store.error = nil; store.isolatedDispatchDriver = fake
            fake.calls = []; fake.heldIDs = []; fake.maximumInFlight = 0; fake.cancelled = false
            try store.persist()
        }

        // 暂停状态下的预览与应用使用同一组日期；只平移目标计划，不偷偷开始发送。
        let originals = [job("A-1", "A"), job("A-2", "A", offset: 1500), job("A-3", "A", offset: 2400), job("B-1", "B", offset: 900)]
        try await prepare(originals)
        let requestedStart = now.addingTimeInterval(7200)
        let beforePreview = try encoded(store.archive)
        let preview = try store.previewPlanSchedule("A", start: requestedStart, now: now)
        try check(preview.remaining == 3 && preview.nextDate == requestedStart
                    && preview.finishDate == requestedStart.addingTimeInterval(1800),
                  "未来开始时间预览给出准确下一群、预计结束和剩余数量")
        try check((try encoded(store.archive)) == beforePreview && !store.running && fake.calls.isEmpty,
                  "预览不修改任何资料、启动状态或假驱动")
        let oldSettings = try encoded(store.settings)
        let oldBPlan = try encoded(store.plans.first { $0.id == "B" }!)
        let oldB = item("B-1")!
        let applied = store.updatePlanSchedule("A", start: requestedStart, now: now)
        try check(applied && store.deliveries == preview.deliveries
                    && (try encoded(store.plans.first { $0.id == "A" }!)) == (try encoded(preview.plan)),
                  "应用保存与预览完全相同的计划和剩余日期")
        try check(!store.running && store.runningPlanIDs.isEmpty && fake.calls.isEmpty,
                  "暂停队列改期后仍暂停，不进入聊天驱动")
        try check((try encoded(store.settings)) == oldSettings && store.settings.globalGapMinutes == 7
                    && item("B-1") == oldB && (try encoded(store.plans.first { $0.id == "B" }!)) == oldBPlan,
                  "改期不改变设置、全局最低间隔或另一计划")
        let diskJobs = try store.db.load("deliveries", as: Delivery.self)
        let diskPlans = try store.db.load("plans", as: Plan.self)
        try check(sameJobs(diskJobs, preview.deliveries)
                    && (try encoded(diskPlans.first { $0.id == "A" }!)) == (try encoded(preview.plan)),
                  "计划与任务的新排期在同一SQLite事务中真实落盘")
        let reopenedRoot = root.appendingPathComponent("reopened")
        try store.db.backup(to: reopenedRoot)
        let reopened = try Store(root: reopenedRoot)
        try check(sameJobs(reopened.deliveries, preview.deliveries)
                    && (try encoded(reopened.plans.first { $0.id == "A" }!)) == (try encoded(preview.plan))
                    && (try encoded(reopened.settings)) == oldSettings && !reopened.running && reopened.runningPlanIDs.isEmpty,
                  "重开Store保留未来开始及结束日期，设置不变且队列不自行启动")

        // 有发送痕迹或非待发状态不能被改期重新入队；数组位置、日志和证据都原样保留。
        var protected: [Delivery] = ["blocked", "uncertain", "manual", "verified", "submitted"].enumerated().map { index, status in
            var value = job("protected-\(status)", "A", offset: Double(-10000 - index), status: status)
            value.detail = "原始\(status)日志"; value.evidence = "原始\(status)凭据"
            value.started = now.addingTimeInterval(-12000); value.finished = now.addingTimeInterval(-11000)
            if status == "submitted" { value.submittedAt = now.addingTimeInterval(-11900) }
            return value
        }
        var attemptedQueued = job("queued-already-started", "A", offset: -10000)
        attemptedQueued.started = now.addingTimeInterval(-12000); attemptedQueued.detail = "已经尝试过，不能静默重排"
        var evidencedQueued = job("queued-with-evidence", "A", offset: -10000)
        evidencedQueued.evidence = "已有消息观察凭据"
        var submittedQueued = job("queued-with-checkpoint", "A", offset: -10000)
        submittedQueued.submittedAt = now.addingTimeInterval(-11900)
        var oneOff = job("oneoff-draft", "A", offset: -10000); oneOff.oneOff = true
        protected += [attemptedQueued, evidencedQueued, submittedQueued, oneOff]
        try await prepare([originals[0]] + protected + [originals[1], originals[2], originals[3]])
        let beforeProtected = store.deliveries
        let protectedPreview = try store.previewPlanSchedule("A", start: requestedStart, now: now)
        try check(protectedPreview.remaining == 3 && protectedPreview.deliveries.map(\.id) == beforeProtected.map(\.id),
                  "改期只统计干净待发记录并保留原数组位置")
        let protectedApplied = store.updatePlanSchedule("A", start: requestedStart, now: now)
        try check(protectedApplied && protected.allSatisfy { item($0.id) == $0 } && item("B-1") == originals[3],
                  "拦截、待核对、人工确认、已核验、已提交、有痕迹及一次性记录逐字段不变")
        let adjustedClean = store.deliveries.filter { ["A-1", "A-2", "A-3"].contains($0.id) }
        try check(adjustedClean.map(\.scheduled) == [requestedStart, requestedStart.addingTimeInterval(900), requestedStart.addingTimeInterval(1800)],
                  "三条干净待发整体平移且原15分钟间距保持不变")

        // 等待排期时可编辑，不改变已经独立启动的队列集合。
        try await prepare(originals)
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        let runningBefore = store.runningPlanIDs
        let runningApplied = store.updatePlanSchedule("A", start: requestedStart, now: now)
        try check(runningApplied && store.running && store.runningPlanIDs == runningBefore
                    && runningBefore == ["A", "B"] && !store.busy && fake.calls.isEmpty,
                  "运行中但无在途任务时改未来时间，保持两条队列的运行状态")

        // A 正在唯一前台通道内时，编辑 B 不得重入、取消 A 或写到 A 的资料。
        try await prepare([job("live-A", "A", offset: -300), originals[1], job("B-edit", "B", offset: 900)])
        fake.heldIDs = ["live-A"]
        store.start(planID: "A", immediate: false)
        try await waitUntil("A进入隔离驱动") { fake.calls == ["live-A"] && store.busy && store.processingPlanID == "A" }
        store.start(planID: "B", immediate: false)
        let aBeforeEdit = store.deliveries.filter { $0.planID == "A" }
        let aPlanBeforeEdit = try encoded(store.plans.first { $0.id == "A" }!)
        let settingsDuringA = try encoded(store.settings)
        let activeBeforeEdit = store.runningPlanIDs
        let bPreview = try store.previewPlanSchedule("B", start: requestedStart, now: now)
        let bEdited = store.updatePlanSchedule("B", start: requestedStart, now: now)
        try check(bEdited && item("B-edit")?.scheduled == bPreview.nextDate
                    && store.deliveries.filter { $0.planID == "A" } == aBeforeEdit
                    && (try encoded(store.plans.first { $0.id == "A" }!)) == aPlanBeforeEdit
                    && (try encoded(store.settings)) == settingsDuringA,
                  "处理A时可以编辑B，只改B的排期，A及设置不动")
        try check(store.busy && store.processingPlanID == "A" && fake.inFlight == 1
                    && fake.maximumInFlight == 1 && fake.calls == ["live-A"] && store.runningPlanIDs == activeBeforeEdit,
                  "编辑B不取消A、不再次调用驱动且独立运行集合不变")
        let beforeOwnEdit = try encoded(store.archive)
        let ownRejected = !store.updatePlanSchedule("A", start: requestedStart, now: now)
        try check(ownRejected && (try encoded(store.archive)) == beforeOwnEdit && store.busy
                    && store.processingPlanID == "A" && fake.inFlight == 1 && fake.calls == ["live-A"],
                  "A自身正在处理时拒绝编辑并保持原任务现场")
        store.stop()
        try await waitUntil("A取消后安全收尾") { !store.busy && fake.inFlight == 0 }

        // 无法归属的busy状态不能借编辑另一计划绕过共享通道保护。
        try await prepare(originals)
        store.busy = true
        let beforeUnknownBusy = try encoded(store.archive)
        let unknownBusyRejected = !store.updatePlanSchedule("B", start: requestedStart, now: now)
        try check(unknownBusyRejected && store.processingPlanID == nil
                    && (try encoded(store.archive)) == beforeUnknownBusy && fake.calls.isEmpty,
                  "unknown busy没有明确在途计划时保守拒绝编辑")
        store.busy = false

        // 保存失败回滚完整计划/任务/设置，同时停止全部运行队列。
        try await prepare(originals)
        store.start(planID: "A", immediate: false); store.start(planID: "B", immediate: false)
        let plansBeforeFailure = try encoded(store.plans)
        let jobsBeforeFailure = store.deliveries
        let settingsBeforeFailure = try encoded(store.settings)
        let chosenBeforeFailure = store.chosenPlanID
        store.recipients.append(recipient) // 仅此临时库重复主键，触发真实SQLite事务回滚。
        let failedApplied = store.updatePlanSchedule("A", start: requestedStart, now: now)
        try check(!failedApplied && !store.running && store.runningPlanIDs.isEmpty && store.error != nil
                    && (try encoded(store.plans)) == plansBeforeFailure && store.deliveries == jobsBeforeFailure
                    && (try encoded(store.settings)) == settingsBeforeFailure && store.chosenPlanID == chosenBeforeFailure
                    && fake.calls.isEmpty,
                  "改期保存失败回滚资料与页面选择，并停止全部队列")
        let failedDiskPlans = try store.db.load("plans", as: Plan.self)
        let failedDiskJobs = try store.db.load("deliveries", as: Delivery.self)
        let failedDiskSettings = try store.db.load("settings", as: Settings.self)
        try check((try encoded(failedDiskPlans)) == plansBeforeFailure && sameJobs(failedDiskJobs, jobsBeforeFailure)
                    && (try encoded(failedDiskSettings.first!)) == settingsBeforeFailure,
                  "保存失败后磁盘没有半个新排期，仍是原计划、任务和设置")

        // 编辑B保存失败还必须取消正在A的操作；假驱动没有任何提交指令。
        try await prepare([job("cancel-flight-A", "A", offset: -300), job("rollback-B", "B", offset: 900)])
        fake.heldIDs = ["cancel-flight-A"]
        store.start(planID: "A", immediate: false)
        try await waitUntil("保存失败验收A进入驱动") { store.busy && fake.calls == ["cancel-flight-A"] }
        store.start(planID: "B", immediate: false)
        let bBeforeFailure = item("rollback-B")!
        let bPlanBeforeFailure = try encoded(store.plans.first { $0.id == "B" }!)
        store.recipients.append(recipient)
        let inFlightFailure = store.updatePlanSchedule("B", start: requestedStart, now: now)
        try await waitUntil("编辑保存失败取消在途假驱动") { !store.busy && fake.inFlight == 0 }
        try check(!inFlightFailure && !store.running && store.runningPlanIDs.isEmpty && store.processingPlanID == nil
                    && item("rollback-B") == bBeforeFailure
                    && (try encoded(store.plans.first { $0.id == "B" }!)) == bPlanBeforeFailure
                    && fake.calls == ["cancel-flight-A"] && fake.maximumInFlight == 1
                    && item("cancel-flight-A")?.submittedAt == nil && store.error != nil,
                  "B改期事务失败停止全部及A在途操作，B回滚且不会触发提交")
        store.recipients = [recipient]
        store.stop(); store.isolatedDispatchDriver = nil
        print("Queue Schedule Store: \(passed) checks passed. Isolated SQLite and fake driver; no QQ sends.")
    }
}
