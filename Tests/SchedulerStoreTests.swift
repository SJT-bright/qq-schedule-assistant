import SwiftUI
import AppKit

@MainActor final class IsolatedQueueDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var calls: [String] = []
    var inFlight = 0
    var maximumInFlight = 0
    var behavior: (Delivery) async throws -> (String, String) = { _ in ("blocked", "隔离驱动前置失败") }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false
        calls.append(delivery.id); inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        return try await behavior(delivery)
    }
}

@main @MainActor struct SchedulerStoreTests {
    static func main() async throws {
        // 每个真实驱动入口都有同一个保险开关；心跳只可到达 execute 的探针拦截。
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-scheduler-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let now = Date()
        let recipient = Recipient(name: "隔离验收群")
        let plan = Plan(name: "隔离排期", text: "仅测试不发送", assetIDs: [], recipientIDs: [recipient.id], starts: now.addingTimeInterval(3600), days: 1, times: [], intervalMinutes: 30, mode: "draft")
        var sent = Delivery(planID: plan.id, planName: plan.name, recipient: recipient.name, text: plan.text, assets: [], scheduled: now.addingTimeInterval(-1200), mode: "draft")
        sent.status = "verified"; sent.submittedAt = now.addingTimeInterval(-1200)
        var queued = sent; queued.id = UUID().uuidString; queued.status = "queued"; queued.submittedAt = nil; queued.scheduled = now.addingTimeInterval(600)
        store.recipients = [recipient]; store.plans = [plan]; store.deliveries = [sent, queued]
        store.running = true; store.activePlanID = plan.id
        try store.persist()
        store.updatePlanInterval(plan.id, minutes: 25, lowerGlobal: true)
        precondition(store.error == nil && store.running && store.plans[0].intervalMinutes == 25 && store.settings.globalGapMinutes == 25)
        precondition(abs(store.earliestSendDate(store.deliveries[1]).timeIntervalSince(now) - 300) < 0.1)
        let persistedPlans = try store.db.load("plans", as: Plan.self)
        precondition(persistedPlans[0].intervalMinutes == 25)
        print("PASS running wait applies interval atomically and retains running; future earliest time recomputed")
        store.busy = true
        store.updatePlanInterval(plan.id, minutes: 1, lowerGlobal: true)
        precondition(store.plans[0].intervalMinutes == 25 && store.settings.globalGapMinutes == 25 && store.running)
        precondition(store.error != nil)
        store.busy = false; store.error = nil
        print("PASS busy application rejected without changing settings")
        store.tick() // Still five minutes early: cannot enter a chat driver.
        precondition(!store.busy && store.deliveries[1].status == "queued" && store.step.contains("等待"))
        print("PASS early tick reports cooldown and leaves job queued")
        store.running = false
        store.updatePlanInterval(plan.id, minutes: 30, lowerGlobal: false)
        precondition(!store.running && store.plans[0].intervalMinutes == 30)
        print("PASS paused update remains paused")
        var unresolved = sent; unresolved.id = UUID().uuidString; unresolved.status = "uncertain"
        store.deliveries.append(unresolved); store.running = true
        store.tick()
        precondition(!store.busy && store.running && store.step.contains("等待") && !store.step.contains("待核对"))
        store.running = false
        print("PASS historical uncertain record does not block dispatch or replace cooldown explanation")
        var cadencePlan = plan
        cadencePlan.id = "cadence-15-minute-plan"; cadencePlan.starts = now.addingTimeInterval(-3600)
        var completed = sent
        completed.planID = cadencePlan.id; completed.submittedAt = now.addingTimeInterval(-60)
        completed.scheduled = now.addingTimeInterval(-60); completed.finished = now.addingTimeInterval(-57)
        completed.evidence = "保留原核验凭据"
        let pending = (0..<5).map { index -> Delivery in
            var job = queued; job.id = "cadence-pending-\(index)"; job.planID = cadencePlan.id
            job.scheduled = now.addingTimeInterval(1740 + Double(index * 1800))
            return job
        }
        var other = queued; other.id = "other-plan-pending"; other.planID = "other-plan"
        store.plans = [cadencePlan]; store.deliveries = [completed] + pending + [other]
        store.activePlanID = cadencePlan.id; store.settings.globalGapMinutes = 30; store.running = true
        let beforePreview = store.deliveries
        let preview = try store.previewPlanInterval(cadencePlan.id, minutes: 15, lowerGlobal: true, now: now)
        precondition(preview.remaining == 5 && preview.nextDate == now.addingTimeInterval(840))
        precondition(preview.finishDate == now.addingTimeInterval(4440))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let unchangedPreview = try encoder.encode(store.deliveries) == encoder.encode(beforePreview)
        precondition(unchangedPreview)
        print("PASS 30-to-15 preview recalculates next and finish dates without changing data")
        precondition(store.updatePlanInterval(cadencePlan.id, minutes: 15, lowerGlobal: true, now: now))
        let adjusted = store.deliveries.filter { $0.planID == cadencePlan.id && $0.status == "queued" }
        precondition(adjusted.map(\.scheduled) == (0..<5).map { now.addingTimeInterval(840 + Double($0 * 900)) })
        precondition(store.running && store.settings.globalGapMinutes == 15 && store.plans[0].intervalMinutes == 15)
        let completedUnchanged = try encoder.encode(store.deliveries[0]) == encoder.encode(completed)
        let otherUnchanged = try encoder.encode(store.deliveries.last!) == encoder.encode(other)
        precondition(completedUnchanged && otherUnchanged)
        print("PASS applying 15-minute cadence matches preview and preserves completed and other-plan jobs")
        let reopenedRoot = root.appendingPathComponent("reopened")
        try store.db.backup(to: reopenedRoot)
        let reopened = try Store(root: reopenedRoot)
        precondition(!reopened.running && reopened.plans[0].intervalMinutes == 15 && reopened.settings.globalGapMinutes == 15)
        precondition(reopened.deliveries.filter { $0.planID == cadencePlan.id && $0.status == "queued" }.map(\.scheduled).sorted() == adjusted.map(\.scheduled).sorted())
        let reloadedPreview = try reopened.previewPlanInterval(cadencePlan.id, minutes: 15, lowerGlobal: false, now: now)
        precondition(reloadedPreview.nextDate == preview.nextDate && reloadedPreview.finishDate == preview.finishDate)
        print("PASS reopening Store preserves 15-minute cadence and all remaining scheduled dates")
        let beforeInvalid = try encoder.encode(store.archive)
        precondition(!store.updatePlanInterval(cadencePlan.id, minutes: 0, lowerGlobal: true, now: now))
        let afterInvalid = try encoder.encode(store.archive)
        precondition(afterInvalid == beforeInvalid)
        print("PASS invalid interval leaves persisted plan, global gap and jobs unchanged")
        var executionChecks = 0
        func checkExecution(_ condition: Bool, _ name: String) throws {
            guard condition else { throw AppError("FAIL: \(name)") }
            executionChecks += 1; print("PASS \(name)")
        }
        func waitForIdle() async throws {
            let deadline = Date().addingTimeInterval(3)
            while store.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try checkExecution(!store.busy, "isolated driver operation settles without concurrent dispatch")
        }
        var executionPlan = plan
        executionPlan.id = "current-execution-plan"; executionPlan.mode = "automatic"; executionPlan.intervalMinutes = 1
        var otherPlan = executionPlan; otherPlan.id = "other-execution-plan"
        func executionJob(_ id: String, planID: String? = nil) -> Delivery {
            Delivery(id: id, planID: planID ?? executionPlan.id, planName: executionPlan.name, recipient: id,
                text: "隔离驱动内容", assets: [], scheduled: Date().addingTimeInterval(-300), mode: "automatic")
        }
        let fake = IsolatedQueueDriver()
        func prepareExecution(_ jobs: [Delivery]) throws {
            store.running = false; store.activePlanID = nil; store.error = nil; store.route = "queue"
            store.recipients = [recipient]; store.plans = [executionPlan, otherPlan]; store.deliveries = jobs
            store.chosenPlanID = executionPlan.id; store.settings.globalGapMinutes = 0
            store.settings.notifyOnOutcome = false; store.guestMode = true
            store.isolatedDispatchDriver = fake; fake.calls = []; fake.maximumInFlight = 0; fake.cancelled = false
            fake.behavior = { _ in ("blocked", "隔离驱动前置失败") }
            try store.persist()
        }
        let first = executionJob("skip-first"), second = executionJob("skip-second")
        let third = executionJob("skip-third")
        let otherQueued = executionJob("other-plan-never-send", planID: otherPlan.id)
        var oldReview = executionJob("old-review", planID: "old-history-plan")
        oldReview.status = "uncertain"; oldReview.started = Date().addingTimeInterval(-7200)
        oldReview.submittedAt = Date().addingTimeInterval(-7199); oldReview.evidence = "保留旧凭据"; oldReview.detail = "旧记录原文"
        try prepareExecution([first, second, third, otherQueued, oldReview])
        fake.behavior = { job in
            if job.id == second.id { throw AppError("隔离驱动找不到会话") }
            return ("blocked", "隔离驱动前置校验未通过")
        }
        store.start(immediate: false)
        try await waitForIdle()
        try checkExecution(store.running && store.activePlanID == executionPlan.id && store.deliveries[0].status == "blocked"
            && store.route == "queue" && store.error == nil, "historical review does not block scoped start; blocked result skips only current group")
        store.tick(); store.tick()
        try await waitForIdle()
        try checkExecution(store.running && store.deliveries[1].status == "blocked" && store.deliveries[1].detail.contains("找不到会话")
            && fake.calls == [first.id, second.id] && fake.maximumInFlight == 1,
            "thrown pre-submit error logs detail and continues same plan without retrying or concurrent QQ work")
        store.tick(); try await waitForIdle(); store.tick()
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id, second.id, third.id]
            && store.deliveries[3] == otherQueued && store.deliveries[4] == oldReview,
            "finished current plan stops without sending other plan or rewriting historical review")
        let skippedDisk = try store.db.load("deliveries", as: Delivery.self)
        try checkExecution([first.id, second.id, third.id].allSatisfy { id in skippedDisk.first(where: { $0.id == id })?.status == "blocked" },
            "skipped blocked state is durable in the real isolated SQLite database")

        try prepareExecution([first, second, otherQueued, oldReview])
        fake.behavior = { _ in
            try fake.beforeSubmit()
            return ("verified", "缺少消息凭据的假成功")
        }
        store.start(immediate: false); try await waitForIdle()
        let unconfirmed = store.deliveries[0]
        store.tick()
        try checkExecution(store.running && store.activePlanID == executionPlan.id && unconfirmed.status == "uncertain"
            && unconfirmed.submittedAt != nil && unconfirmed.qqVerification == nil && unconfirmed.evidence.isEmpty
            && store.deliveries[1].status == "queued" && store.step.contains("等待") && fake.calls == [first.id],
            "fake verified is saved as uncertain; next queued group waits actual submission cooldown instead of review gate")

        try prepareExecution([first, second, otherQueued])
        fake.behavior = { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return ("blocked", "不应继续") }
        store.start(immediate: false)
        let inFlightDeadline = Date().addingTimeInterval(1)
        while fake.calls.isEmpty && store.busy && Date() < inFlightDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try checkExecution(store.busy && fake.calls == [first.id], "user pause test reaches in-flight isolated driver")
        store.stop(); try await waitForIdle(); store.tick()
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id] && store.deliveries[1] == second,
            "explicit user stop cancels current operation and never resurrects queue or dispatches next group")

        try prepareExecution([first, second])
        fake.behavior = { _ in throw AppError("已停止：用户要求停止") }
        store.start(immediate: false); try await waitForIdle(); store.tick()
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id] && store.deliveries[1] == second,
            "PausePoint stop signal keeps queue stopped rather than treating user stop as skippable failure")

        try prepareExecution([first, second])
        store.recipients.append(recipient) // 真实事务重复主键失败；只有隔离库。
        store.start(immediate: false)
        try checkExecution(!store.running && !store.busy && store.activePlanID == nil && store.deliveries[0] == first
            && fake.calls.isEmpty && store.error != nil, "initial persist failure stops queue before any driver call")

        try prepareExecution([first, second])
        fake.behavior = { _ in
            store.recipients.append(recipient)
            defer { store.recipients = [recipient] }
            try fake.beforeSubmit()
            return ("blocked", "检查点失败后不得发送")
        }
        store.start(immediate: false); try await waitForIdle(); store.tick()
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id]
            && store.deliveries[0].status == "blocked" && store.deliveries[0].submittedAt == nil
            && store.deliveries[1] == second && store.error != nil,
            "checkpoint persistence failure stays stopped even if subsequent failure log can be saved")

        try prepareExecution([first, second])
        fake.behavior = { _ in store.recipients.append(recipient); return ("blocked", "结果落盘将失败") }
        store.start(immediate: false); try await waitForIdle(); store.tick()
        let failedResultDisk = try store.db.load("deliveries", as: Delivery.self)
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id] && store.error != nil
            && store.deliveries[0].status == "running" && failedResultDisk.first(where: { $0.id == first.id })?.status == "running"
            && store.deliveries[1] == second, "outcome save failure rolls back state and stops instead of losing record and continuing")

        try prepareExecution([first, second, otherQueued, oldReview])
        store.sendSingle(first.id); try await waitForIdle(); store.tick()
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls == [first.id]
            && store.deliveries[1] == second && store.deliveries[2] == otherQueued,
            "one-job manual action ignores unrelated review but does not start any queue or other plan")
        var manuallyDone = first; manuallyDone.status = "manual"; manuallyDone.finished = Date().addingTimeInterval(-7200)
        try prepareExecution([manuallyDone, otherQueued, oldReview])
        store.start(immediate: false)
        try checkExecution(!store.running && store.activePlanID == nil && fake.calls.isEmpty
            && store.deliveries[1] == otherQueued && store.error?.contains("当前计划没有") == true,
            "all checkmarks in selected plan do not require old review or silently start a different plan")
        for trace in ["submittedAt", "evidence"] {
            var traced = first
            if trace == "submittedAt" { traced.submittedAt = Date().addingTimeInterval(-7200) }
            else { traced.evidence = "已有发送痕迹，不能重复执行" }
            try prepareExecution([traced, second])
            store.sendSingle(traced.id); store.execute(traced)
            try checkExecution(fake.calls.isEmpty && !store.busy && store.deliveries[0] == traced
                && store.deliveries[1] == second && store.error?.contains("提交痕迹") == true,
                "\(trace) protects a queued record from both single-send and direct execution")
        }
        store.isolatedDispatchDriver = nil
        store.error = nil; store.running = false
        store.plans = [plan]; store.activePlanID = plan.id
        store.deliveries = [queued]
        store.deliveries[0].scheduled = Date().addingTimeInterval(3.5)
        store.settings.notifyOnOutcome = false
        store.startDispatchHeartbeat()
        store.running = true
        store.step = "等待第一拍心跳"
        let firstDeadline = Date().addingTimeInterval(2.5)
        while store.step == "等待第一拍心跳", Date() < firstDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // 未激活的 DispatchSource 在这里失败：点击开始后只有手动 tick，之后不会再醒。
        guard store.step != "等待第一拍心跳" else {
            print("FAIL: production heartbeat never fired; future jobs cannot dispatch")
            fflush(stdout)
            try? FileManager.default.removeItem(at: root)
            exit(1)
        }
        precondition(store.running && !store.busy && store.deliveries[0].status == "queued")
        print("PASS production heartbeat fires before due time and preserves queued job")
        let dueDeadline = Date().addingTimeInterval(5)
        while store.running, Date() < dueDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!store.running && store.step.contains("探针模式：已拦截任务执行"))
        precondition(store.deliveries[0].started == nil && store.deliveries[0].submittedAt == nil && store.deliveries[0].evidence.isEmpty)
        print("PASS repeated heartbeat reaches due job without opening QQ or submitting")
        store.deliveries[0].scheduled = Date().addingTimeInterval(1)
        store.step = "暂停保持"
        try await Task.sleep(nanoseconds: 2_500_000_000)
        precondition(!store.running && store.step == "暂停保持" && store.deliveries[0].status == "queued")
        print("PASS paused heartbeat never executes an overdue job")
        store.running = true
        let resumeDeadline = Date().addingTimeInterval(2.5)
        while store.running, Date() < resumeDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!store.running && store.step.contains("探针模式：已拦截任务执行"))
        print("PASS resumed queue wakes an overdue job automatically")
        print("\(13 + executionChecks) Store integration checks passed. Isolated data; no QQ sends.")
    }
}
