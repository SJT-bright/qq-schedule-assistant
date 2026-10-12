import Foundation

@main
struct MultiQueueTests {
    static var passed = 0
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw AppError("FAIL: \(name)") }
        passed += 1
    }
    static func job(_ id: String, plan: String = "A", offset: TimeInterval = 0,
                    status: String = "queued", submitted: TimeInterval? = nil) -> Delivery {
        var result = Delivery(id: id, planID: plan, planName: "队列 \(plan)", recipient: "群 \(id)",
                              text: "图文", assets: [], scheduled: base.addingTimeInterval(offset), mode: "automatic")
        result.status = status
        result.submittedAt = submitted.map { base.addingTimeInterval($0) }
        return result
    }
    static func next(_ jobs: [Delivery], active: Set<String> = ["A", "B"], gap: Int = 30,
                     intervals: [String: Int] = [:]) -> String? {
        MultiQueueScheduling.nextCandidate(jobs: jobs, activePlanIDs: active, gap: gap,
                                            intervalByPlan: intervals)?.id
    }
    static func due(_ jobs: [Delivery], seconds: TimeInterval, active: Set<String> = ["A", "B"],
                    gap: Int = 30, intervals: [String: Int] = [:]) -> String? {
        MultiQueueScheduling.eligible(jobs: jobs, activePlanIDs: active,
                                      now: base.addingTimeInterval(seconds), gap: gap,
                                      intervalByPlan: intervals)?.id
    }

    static func main() throws {
        let a = job("A1"), b = job("B1", plan: "B"), c = job("C1", plan: "C", offset: -100)
        try check(next([c, a, b]) == "A1", "不会串入未启动的队列 C")
        try check(next([c, a, b], active: []) == nil, "暂停所有队列后没有候选")
        try check(next([a, b], active: ["B"]) == "B1", "暂停 A 不影响已启动的 B")
        try check(next([b, a], active: ["A"]) == "A1", "暂停 B 不影响已启动的 A")
        try check(next([job("zzz"), job("aaa")]) == "zzz", "同秒同队列保留保存顺序而非 UUID 顺序")
        try check(next([b, a]) == "B1", "无历史同秒多队列稳定取保存顺序")
        for _ in 0..<20 { try check(next([b, a]) == "B1", "相同输入重复查询排序稳定") }

        var blocked = job("blocked", offset: -100, status: "blocked")
        blocked.started = base.addingTimeInterval(-10)
        try check(due([blocked, a, b], seconds: 0) == "A1", "提交前拦截不占发送冷却且继续本队列下一条")
        var uncertain = job("uncertain", offset: -100, status: "uncertain", submitted: 0)
        uncertain.started = base.addingTimeInterval(-1)
        try check(due([uncertain, a, b], seconds: 1799.999) == nil, "结果不确定但已提交时保留完整全局间隔")
        try check(due([uncertain, a, b], seconds: 1800) == "B1", "待核对不阻挡下一队列且不重试旧任务")
        var submittedQueued = a; submittedQueued.submittedAt = base
        var evidenceQueued = b; evidenceQueued.evidence = "已发送一次"
        try check(next([submittedQueued, evidenceQueued]) == nil, "错误 queued 状态也不会重发已有提交或凭据")
        var oneOff = a; oneOff.oneOff = true
        try check(next([oneOff, b]) == "B1", "一次性草稿不混入自动队列")

        let inactiveRunning = job("running-C", plan: "C", status: "running")
        try check(due([a, b, inactiveRunning], seconds: 100_000) == nil, "任意队列的运行任务占用唯一前台通道")
        let cancelledSubmitted = job("cancelled-C", plan: "C", status: "cancelled", submitted: 5)
        try check(due([a, b, cancelledSubmitted], seconds: 1804.999) == nil, "暂停未启动队列的已提交记录仍保留全局冷却")
        try check(due([a, b, cancelledSubmitted], seconds: 1805) == "A1", "全局间隔边界包含准确到期时刻")

        let sentA = job("sent-A", status: "verified", submitted: 0)
        let backlogA = job("A2", offset: -200)
        let waitingB = job("B2", plan: "B", offset: -100)
        try check(next([sentA, backlogA, waitingB], intervals: ["A": 60, "B": 15]) == "B2", "各队列间隔独立，B 不等待 A 的六十分钟间隔")
        try check(due([sentA, backlogA, waitingB], seconds: 1799.999, intervals: ["A": 60, "B": 15]) == nil, "独立计划也不能突破全局三十分钟下限")
        try check(due([sentA, backlogA, waitingB], seconds: 1800, intervals: ["A": 60, "B": 15]) == "B2", "B 到自身和全局间隔后可执行")
        try check(due([sentA, backlogA, waitingB], seconds: 3599.999, active: ["A"], intervals: ["A": 60]) == nil, "暂停 B 不缩短 A 的独立间隔")
        try check(due([sentA, backlogA, waitingB], seconds: 3600, active: ["A"], intervals: ["A": 60]) == "A2", "A 独立间隔准确到期可执行")
        try check(next([sentA, backlogA, waitingB], intervals: ["A": 30, "B": 30]) == "B2", "同一到期时刻优先尚未获得发送机会的队列")
        let sentB = job("sent-B", plan: "B", status: "verified", submitted: 1800)
        try check(next([sentA, sentB, backlogA, waitingB], intervals: ["A": 30, "B": 30]) == "A2", "之后同一到期时刻优先较久未发送的队列")
        let futureB = job("future-B", plan: "B", offset: 3601)
        try check(next([sentA, backlogA, futureB], intervals: ["A": 30, "B": 30]) == "A2", "公平性不使未来队列抢先到期队列")

        var alternating: [Delivery] = []
        for index in 0..<16 {
            alternating.append(job("A-\(index)", offset: -10_000 + Double(index)))
            alternating.append(job("B-\(index)", plan: "B", offset: -5_000 + Double(index)))
        }
        for step in 0..<32 {
            let seconds = Double(step * 1800)
            let selected = MultiQueueScheduling.eligible(jobs: alternating, activePlanIDs: ["A", "B"],
                                                        now: base.addingTimeInterval(seconds), gap: 30,
                                                        intervalByPlan: ["A": 30, "B": 30])
            try check(selected?.planID == (step % 2 == 0 ? "A" : "B"), "积压队列公平交替第 \(step + 1) 次")
            guard let index = alternating.firstIndex(where: { $0.id == selected?.id }) else { throw AppError("选中任务不存在") }
            alternating[index].status = "verified"
            alternating[index].submittedAt = base.addingTimeInterval(seconds)
        }
        try check(next(alternating) == nil, "两个队列完成后不进入其他计划")

        // 单活跃队列的新接口必须与原调度结果完全一致；同时比较精确冷却边界。
        var seed: UInt64 = 0x71a245ee
        func random(_ upper: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        let statuses = ["queued", "blocked", "verified", "uncertain", "cancelled", "manual", "draft", "submitted"]
        for sample in 0..<400 {
            var jobs: [Delivery] = []
            for index in 0..<24 {
                let plan = ["A", "B", "C"][random(3)]
                var value = job("sample-\(sample)-\(index)", plan: plan, offset: Double(random(120) - 60) * 60,
                                status: statuses[random(statuses.count)])
                if random(3) == 0 { value.started = base.addingTimeInterval(Double(random(60) - 30) * 60) }
                if random(5) == 0 { value.submittedAt = base.addingTimeInterval(Double(random(60) - 30) * 60) }
                if random(4) == 0 { value.finished = base.addingTimeInterval(Double(random(60) - 30) * 60) }
                if random(8) == 0 { value.evidence = "凭据" }
                if random(12) == 0 { value.oneOff = true }
                jobs.append(value)
            }
            let gap = random(31), intervals = ["A": 15, "B": 30, "C": 60]
            let original = Scheduling.nextCandidate(jobs, gap: gap, planID: "A", intervalByPlan: intervals)
            let multi = MultiQueueScheduling.nextCandidate(jobs: jobs, activePlanIDs: ["A"], gap: gap, intervalByPlan: intervals)
            try check(original?.id == multi?.id, "单队列与旧调度候选一致样本 \(sample)")
            if let original {
                let earliest = Scheduling.earliestSendDate(original, jobs: jobs, gap: gap, intervalByPlan: intervals)
                let before = MultiQueueScheduling.eligible(jobs: jobs, activePlanIDs: ["A"], now: earliest.addingTimeInterval(-0.001), gap: gap, intervalByPlan: intervals)
                let exact = MultiQueueScheduling.eligible(jobs: jobs, activePlanIDs: ["A"], now: earliest, gap: gap, intervalByPlan: intervals)
                try check(before == nil && exact?.id == original.id, "单队列冷却边界与原调度一致样本 \(sample)")
            }
        }
        try check(next([a], gap: -1) == nil, "非法全局间隔不反向缩短冷却")
        try check(next([a], intervals: ["A": -1]) == nil, "非法队列间隔不反向缩短冷却")

        var large: [Delivery] = []
        for index in 0..<10_000 {
            large.append(job("large-\(index)", plan: "queue-\(index % 16)", offset: Double(index),
                             status: index % 5 == 0 ? "verified" : "queued", submitted: index % 5 == 0 ? Double(index) : nil))
        }
        let active = Set((0..<16).map { "queue-\($0)" })
        let start = Date()
        for _ in 0..<100 {
            _ = MultiQueueScheduling.eligible(jobs: large, activePlanIDs: active, now: base.addingTimeInterval(100_000), gap: 30)
        }
        let averageMilliseconds = Date().timeIntervalSince(start) * 10
        try check(averageMilliseconds < 100, "一万条任务十六队列平均候选查询低于一百毫秒")
        print(String(format: "PERFORMANCE: 10,000 jobs / 16 queues, 100 queries average %.3f ms", averageMilliseconds))
        print("PASS: \(passed) multi-queue checks")
    }
}
