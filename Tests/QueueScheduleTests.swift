import Foundation

@main struct QueueScheduleTests {
    static var passed = 0
    static let parser = ISO8601DateFormatter()
    static func date(_ value: String) -> Date { parser.date(from: value)! }
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw AppError("FAIL: \(name)") }
        passed += 1
    }
    static func rejects(_ name: String, _ work: () throws -> Void) throws {
        do { try work() } catch { passed += 1; return }
        throw AppError("FAIL: \(name) unexpectedly accepted")
    }
    static func main() throws {
        let now = date("2026-10-10T08:00:00+08:00")
        let recipients = (0..<3).map { Recipient(id: "r\($0)", name: "隔离群\($0)") }
        var plan = Plan(id: "current-plan", name: "可改期队列", text: "仅纯函数检查，不发送", assetIDs: [],
                        recipientIDs: recipients.prefix(2).map(\.id), starts: date("2026-10-12T09:00:00+08:00"),
                        days: 2, times: ["09:00", "14:00"], intervalMinutes: 30, mode: "automatic")
        plan.recurringEveryDays = 2; plan.textTemplateID = "immutable-template"
        let original = try Scheduling.expand(plan, recipients: recipients, assets: [], now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let originalPlan = try encoder.encode(plan), originalJobs = try encoder.encode(original)

        let earlierStart = date("2026-10-11T20:25:00+08:00")
        let early = try QueueSchedule.make(plan: plan, jobs: original, requestedStart: earlierStart, now: now, globalGap: 30)
        let delta = earlierStart.timeIntervalSince(original[0].scheduled)
        try check(early.nextDate == earlierStart && early.remaining == 8 && early.finishDate == original.last!.scheduled.addingTimeInterval(delta),
                  "提前跨日期改首群后，首群、剩余数与末群同步匹配")
        try check(early.deliveries.count == original.count && early.deliveries.map(\.id) == original.map(\.id)
                    && zip(early.deliveries, original).allSatisfy { $0.scheduled == $1.scheduled.addingTimeInterval(delta) },
                  "全部尚未尝试任务平移同一 delta，ID、数量、群顺序与轮次间距不变")
        var normalized = early.plan; normalized.scheduleOffsetSeconds = nil
        try check(try encoder.encode(normalized) == originalPlan && early.plan.scheduleOffsetSeconds == delta,
                  "只累加计划偏移，不改原起点、轮次、模板、循环与内容")
        try check(try encoder.encode(plan) == originalPlan && encoder.encode(original) == originalJobs,
                  "预览不修改输入计划或任务")
        let laterStart = date("2026-10-15T07:05:00+08:00")
        let later = try QueueSchedule.moved(plan: early.plan, jobs: early.deliveries, requestedStart: laterStart, now: now, globalGap: 30)
        let overallDelta = laterStart.timeIntervalSince(original[0].scheduled)
        try check(later.plan.scheduleOffsetSeconds == overallDelta && later.deliveries.allSatisfy { $0.scheduleOffsetSeconds == overallDelta }
                    && zip(later.deliveries, original).allSatisfy { $0.scheduled == $1.scheduled.addingTimeInterval(overallDelta) },
                  "再次延后累计偏移，任务快照与当前计划一致，不重复加旧偏移")
        let reexpanded = try Scheduling.expand(later.plan, recipients: recipients, assets: [], now: now)
        try check(reexpanded.map(\.scheduled) == later.deliveries.map(\.scheduled), "expand 重建的轮次起点与累计改期一致")
        let persistedPlan = try JSONDecoder().decode(Plan.self, from: encoder.encode(later.plan))
        let persistedJobs = try JSONDecoder().decode([Delivery].self, from: encoder.encode(later.deliveries))
        try check(persistedPlan.scheduleOffsetSeconds == overallDelta && persistedJobs == later.deliveries,
                  "计划偏移和每条任务的偏移快照完整持久化往返")
        let legacyPlan = try JSONDecoder().decode(Plan.self, from: originalPlan)
        let legacyJobs = try JSONDecoder().decode([Delivery].self, from: originalJobs)
        try check(legacyPlan.scheduleOffsetSeconds == nil && legacyJobs.allSatisfy { $0.scheduleOffsetSeconds == nil },
                  "旧 JSON 缺偏移字段解码为 nil")
        var zeroPlan = plan; zeroPlan.scheduleOffsetSeconds = 0
        let zeroExpanded = try Scheduling.expand(zeroPlan, recipients: recipients, assets: [], now: now)
        try check(zeroExpanded.map(\.scheduled) == original.map(\.scheduled), "旧 nil 和显式零偏移保持完全相同的时刻")

        // 首群直接选日期和时分；预设仅保留后续轮次的相对间距。
        var exactPlan = plan
        exactPlan.starts = date("2026-10-10T23:40:00+08:00")
        exactPlan.times = ["19:00", "09:00", "14:00"]
        exactPlan.scheduleOffsetSeconds = try Scheduling.initialScheduleOffset(starts: exactPlan.starts, times: exactPlan.times)
        let exactJobs = try Scheduling.expand(exactPlan, recipients: recipients, assets: [], now: now)
        try check(exactJobs[0].scheduled == exactPlan.starts && exactJobs[2].scheduled == date("2026-10-11T04:40:00+08:00")
                    && exactJobs[4].scheduled == date("2026-10-11T09:40:00+08:00")
                    && exactJobs[6].scheduled == date("2026-10-11T23:40:00+08:00"),
                  "首群精确对齐选定 23:40，排序后的后续多轮跨零点保留间距")
        try check(try Scheduling.initialScheduleOffset(starts: exactPlan.starts, times: []) == 0,
                  "单轮没有 preset 时 starts 直接作为首群时刻")
        var single = plan; single.times = []; single.days = 1
        single.scheduleOffsetSeconds = 3600
        let shiftedSingle = try Scheduling.expand(single, recipients: recipients, assets: [], now: now)
        try check(shiftedSingle[0].scheduled == single.starts.addingTimeInterval(3600), "无 presets 的既有单轮也应用整体改期偏移")

        let retimed = try Scheduling.retimed(early.deliveries, planID: early.plan.id, minutes: 15, now: now,
                                            globalGap: 5, plan: early.plan)
        try check(retimed[0].scheduled == early.nextDate && retimed[1].scheduled == early.nextDate.addingTimeInterval(900)
                    && retimed[2].scheduled == early.deliveries[2].scheduled
                    && retimed[4].scheduled == early.deliveries[4].scheduled,
                  "改期后再次改间隔保留新轮次起点、跨零点和第二天分布")
        // days=1 的循环已走到原起点第八天，再向前平移十天；horizon 必须撤销偏移。
        var cyclePlan = plan; cyclePlan.days = 1; cyclePlan.recurringEveryDays = 1
        var laterCyclePlan = cyclePlan; laterCyclePlan.starts = date("2026-10-20T09:00:00+08:00")
        let laterCycleJobs = try Scheduling.expand(laterCyclePlan, recipients: recipients, assets: [], now: now)
        let negativeCycle = try QueueSchedule.moved(plan: cyclePlan, jobs: laterCycleJobs,
            requestedStart: date("2026-10-10T09:00:00+08:00"), now: now, globalGap: 5)
        let negativeRetimed = try Scheduling.retimed(negativeCycle.deliveries, planID: cyclePlan.id, minutes: 15,
            now: now, globalGap: 5, plan: negativeCycle.plan)
        try check(negativeRetimed[2].scheduled == date("2026-10-10T14:00:00+08:00")
                    && negativeRetimed[3].scheduled == date("2026-10-10T14:15:00+08:00"),
                  "负偏移跨多天的后续循环，slotStarts 不漏下午轮次或把轮次压成一串")

        // 已尝试任务、一次性记录、结构核验及其他计划不能被改期。
        let image = Asset(id: "protected-image", name: "原图.png", relativePath: "assets/original.png", sha256: "digest", bytes: 1, isImage: true)
        var protected: [Delivery] = []
        for state in ["blocked", "uncertain", "submitted", "draft", "verified", "manual", "cancelled"] {
            var value = original[0]; value.id = "protected-\(state)"; value.status = state
            value.started = now.addingTimeInterval(-7201); value.submittedAt = now.addingTimeInterval(-7200)
            value.assets = [image]; value.evidence = "不可改写的 \(state) 证据"; value.historyClearedAt = now.addingTimeInterval(-7000)
            protected.append(value)
        }
        var started = original[0]; started.id = "queued-started"; started.started = now.addingTimeInterval(-7200)
        var submitted = original[0]; submitted.id = "queued-submitted"; submitted.submittedAt = now.addingTimeInterval(-7200)
        var evidenced = original[0]; evidenced.id = "queued-evidence"; evidenced.evidence = "不可重发"
        var oneOff = original[0]; oneOff.id = "queued-one-off"; oneOff.oneOff = true
        var proof = original[0]; proof.id = "queued-proof"
        proof.qqVerification = QQVerificationEvidence(deliveryID: proof.id, selectedTitle: proof.recipient, trigger: "Return",
            submittedAt: now.addingTimeInterval(-7200), firstObservedAt: now.addingTimeInterval(-7199), confirmedAt: now.addingTimeInterval(-7198),
            baselineRowIDs: ["tail"], confirmedRowIDs: ["tail", "new"], messageID: "new", textMatches: true,
            images: 0, requiredImages: 0, draftCleared: true, baselineAtLatest: true, confirmedAtLatest: true)
        var other = original[0]; other.id = "other-plan"; other.planID = "B"; other.status = "running"
        protected += [started, submitted, evidenced, oneOff, proof, other]
        let full = protected + original
        let protectedMove = try QueueSchedule.moved(plan: plan, jobs: full, requestedStart: earlierStart, now: now, globalGap: 5)
        try check(Array(protectedMove.deliveries.prefix(protected.count)) == protected && protectedMove.remaining == original.count,
                  "只移动本计划 clean queued；started、submitted、evidence、proof、oneOff、历史和其他正在运行计划全部原样")
        var tiedA = original[0], tiedB = original[1]
        tiedA.id = "z-first"; tiedB.id = "a-second"; tiedB.scheduled = tiedA.scheduled
        let tiedMove = try QueueSchedule.moved(plan: plan, jobs: [tiedA, tiedB], requestedStart: earlierStart, now: now, globalGap: 5)
        try check(tiedMove.deliveries.map(\.id) == ["z-first", "a-second"] && tiedMove.deliveries.map(\.scheduled) == [earlierStart, earlierStart],
                  "相同原排期按保存顺序平移，不按 UUID 重排或引入新任务")

        var coolingPlan = plan; coolingPlan.intervalMinutes = 60
        var planSent = original[0]; planSent.id = "plan-sent"; planSent.status = "verified"; planSent.submittedAt = now.addingTimeInterval(-1800)
        var globalSent = planSent; globalSent.id = "global-sent"; globalSent.planID = "B"; globalSent.submittedAt = now.addingTimeInterval(-30)
        let cooling = try QueueSchedule.moved(plan: coolingPlan, jobs: [planSent, globalSent] + original,
            requestedStart: now, now: now, globalGap: 30)
        try check(cooling.nextDate == now.addingTimeInterval(1800), "首群同时遵守全局实际提交间隔和本计划六十分钟冷却")
        coolingPlan.recipientGaps = [recipients[1].id: 15]
        let customCooling = try QueueSchedule.moved(plan: coolingPlan, jobs: [planSent, globalSent] + original,
            requestedStart: now, now: now, globalGap: 30)
        try check(customCooling.nextDate == now.addingTimeInterval(1770), "逐群间隔计划按 pace 下限计算，仍保留全局冷却")
        let justPast = try QueueSchedule.moved(plan: plan, jobs: original, requestedStart: now.addingTimeInterval(-60), now: now, globalGap: 5)
        try check(justPast.nextDate == now, "一分钟内合法时间钳到当下，绝不保留已过期首群")
        var narrowPlan = single; narrowPlan.intervalMinutes = 15; narrowPlan.scheduleOffsetSeconds = nil
        narrowPlan.recipientIDs = recipients.map(\.id)
        let narrowJobs = try Scheduling.expand(narrowPlan, recipients: recipients, assets: [], now: now)
        let narrowMove = try QueueSchedule.moved(plan: narrowPlan, jobs: narrowJobs, requestedStart: now.addingTimeInterval(3600), now: now, globalGap: 30)
        try check(narrowMove.deliveries[1].scheduled.timeIntervalSince(narrowMove.deliveries[0].scheduled) == 900
                    && narrowMove.deliveries[2].scheduled.timeIntervalSince(narrowMove.deliveries[0].scheduled) == 1800
                    && narrowMove.finishDate == narrowMove.nextDate.addingTimeInterval(3600),
                  "旧排期间距十五分钟仍保留，预计结束计入调高后的三十分钟全局提交间隔")

        // 部分完成后改剩余任务，下一循环必须把完成群和待发群统一到当前偏移。
        var partialPlan = single; partialPlan.scheduleOffsetSeconds = nil; partialPlan.recurringEveryDays = 1
        let partialBase = try Scheduling.expand(partialPlan, recipients: recipients, assets: [], now: now)
        var partiallyDone = partialBase
        partiallyDone[0].status = "manual"; partiallyDone[0].started = now.addingTimeInterval(-2)
        partiallyDone[0].submittedAt = now.addingTimeInterval(-1); partiallyDone[0].finished = now
        partiallyDone[0].historyClearedAt = now; partiallyDone[0].qqVerification = proof.qqVerification
        let completedHistory = partiallyDone[0]
        let partialTarget = partialBase[1].scheduled.addingTimeInterval(3 * 3600)
        let partialMove = try QueueSchedule.moved(plan: partialPlan, jobs: partiallyDone, requestedStart: partialTarget, now: now, globalGap: 5)
        try check(partialMove.deliveries[0] == completedHistory && partialMove.deliveries[1].scheduleOffsetSeconds == 3 * 3600,
                  "部分完成改期时完成群历史字段一律不改，剩余群记录当前偏移")
        var finishedPartial = partialMove.deliveries
        finishedPartial[1].status = "manual"; finishedPartial[1].finished = now
        let nextCycle = try Scheduling.recur(partialMove.plan, jobs: finishedPartial, now: now, gap: 5)!
        try check(nextCycle.map(\.scheduled) == partialBase.map { Scheduling.shifted($0.scheduled.addingTimeInterval(3 * 3600), byDays: 1) }
                    && nextCycle.allSatisfy { $0.scheduleOffsetSeconds == 3 * 3600 },
                  "改期后的下一循环统一所有群时刻，完成群不沿用旧偏移造成混排")
        try check(nextCycle.allSatisfy { $0.qqVerification == nil && $0.historyClearedAt == nil && $0.started == nil
                    && $0.submittedAt == nil && $0.finished == nil && $0.evidence.isEmpty && $0.status == "queued" }
                    && Set(nextCycle.map(\.id)).isDisjoint(with: Set(finishedPartial.map(\.id))),
                  "新循环全新任务无旧归档标记、核验依据或提交痕迹，不重复使用旧任务")
        var nextDone = nextCycle
        for index in nextDone.indices { nextDone[index].status = "manual"; nextDone[index].finished = now }
        let secondCycle = try Scheduling.recur(partialMove.plan, jobs: finishedPartial + nextDone, now: now, gap: 5)!
        try check(secondCycle.map(\.scheduled) == nextCycle.map { Scheduling.shifted($0.scheduled, byDays: 1) }
                    && secondCycle.allSatisfy { $0.scheduleOffsetSeconds == 3 * 3600 }, "第二次循环不再重复增加已应用偏移")
        let added = try Scheduling.additionalDeliveries(plan: partialMove.plan, recipients: [recipients[2]], jobs: finishedPartial,
                                                       now: now, gap: 5)
        try check(added.count == 1 && added[0].scheduleOffsetSeconds == 3 * 3600 && added[0].qqVerification == nil
                    && added[0].historyClearedAt == nil, "追加群的新任务快照当前偏移，清除模板携带的归档和核验依据")

        try rejects("过期超过一分钟拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: original, requestedStart: now.addingTimeInterval(-60.001), now: now, globalGap: 5) }
        try rejects("没有 clean queued 拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: protected, requestedStart: now, now: now, globalGap: 5) }
        try rejects("目标计划正在运行拒绝") {
            var running = original[0]; running.status = "running"
            _ = try QueueSchedule.make(plan: plan, jobs: [running] + Array(original.dropFirst()), requestedStart: now, now: now, globalGap: 5)
        }
        try rejects("重复任务编号拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: [original[0], original[0]], requestedStart: now, now: now, globalGap: 5) }
        try rejects("非法全局间隔拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: original, requestedStart: now, now: now, globalGap: -1) }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            try rejects("非有限首群日期拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: original, requestedStart: Date(timeIntervalSinceReferenceDate: invalid), now: now, globalGap: 5) }
            try rejects("非有限 now 拒绝") { _ = try QueueSchedule.make(plan: plan, jobs: original, requestedStart: now, now: Date(timeIntervalSinceReferenceDate: invalid), globalGap: 5) }
            try rejects("非有限 plan offset 拒绝") { var bad = plan; bad.scheduleOffsetSeconds = invalid; _ = try QueueSchedule.make(plan: bad, jobs: original, requestedStart: now, now: now, globalGap: 5) }
            try rejects("非有限 queued 日期拒绝") { var bad = original; bad[0].scheduled = Date(timeIntervalSinceReferenceDate: invalid); _ = try QueueSchedule.make(plan: plan, jobs: bad, requestedStart: now, now: now, globalGap: 5) }
            try rejects("非有限 queued offset 拒绝") { var bad = original; bad[0].scheduleOffsetSeconds = invalid; _ = try QueueSchedule.make(plan: plan, jobs: bad, requestedStart: now, now: now, globalGap: 5) }
            try rejects("expand 非有限 plan offset 拒绝") { var bad = plan; bad.scheduleOffsetSeconds = invalid; _ = try Scheduling.expand(bad, recipients: recipients, assets: [], now: now) }
            try rejects("recur 非有限 plan offset 拒绝") { var bad = partialMove.plan; bad.scheduleOffsetSeconds = invalid; _ = try Scheduling.recur(bad, jobs: finishedPartial, now: now, gap: 5) }
            try rejects("recur 非有限历史任务 offset 拒绝") { var bad = finishedPartial; bad[0].scheduleOffsetSeconds = invalid; _ = try Scheduling.recur(partialMove.plan, jobs: bad, now: now, gap: 5) }
            try rejects("initialOffset 非有限日期拒绝") { _ = try Scheduling.initialScheduleOffset(starts: Date(timeIntervalSinceReferenceDate: invalid), times: ["09:00"]) }
        }
        try rejects("仍保留 expand 过去时间门禁") { var bad = plan; bad.scheduleOffsetSeconds = -10 * 86400; _ = try Scheduling.expand(bad, recipients: recipients, assets: [], now: now) }
        try rejects("仍保留 expand 轮次重叠门禁") { var bad = plan; bad.times = ["09:00", "09:20"]; bad.scheduleOffsetSeconds = 3600; _ = try Scheduling.expand(bad, recipients: recipients, assets: [], now: now) }
        try rejects("initialOffset 非法 presets 拒绝") { _ = try Scheduling.initialScheduleOffset(starts: now, times: ["25:00"]) }
        print("PASS: \(passed) QueueSchedule checks. Pure scheduling; no drivers or production data.")
    }
}
