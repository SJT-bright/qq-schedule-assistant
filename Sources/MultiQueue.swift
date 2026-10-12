import Foundation

/// 多个已启动计划共享一个前台发送通道。每个计划保留自己的节奏，
/// 全局提交间隔仍覆盖所有计划，包括暂停或未启动计划留下的提交。
enum MultiQueueScheduling {
    private struct Candidate {
        let job: Delivery
        let due: Date
        let lastPlanActivity: Date?
        let offset: Int
    }

    /// 排期优先；冷却把多条逾期任务推到同一时刻时，优先照顾较久未提交的队列。
    /// 同计划或同等机会下继续使用原排期、原数组顺序，不能用随机 UUID 改变群顺序。
    private static func precedes(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.due != right.due { return left.due < right.due }
        if left.job.planID != right.job.planID && left.lastPlanActivity != right.lastPlanActivity {
            switch (left.lastPlanActivity, right.lastPlanActivity) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(lhs), .some(rhs)): return lhs < rhs
            case (nil, nil): break
            }
        }
        if left.job.scheduled != right.job.scheduled { return left.job.scheduled < right.job.scheduled }
        return left.offset < right.offset
    }

    /// 两次线性扫描，不为每个队列重复对全库排序或计算 dueDates 指纹。
    private static func candidate(jobs: [Delivery], activePlanIDs: Set<String>, gap: Int,
                                  intervalByPlan: [String: Int], allowedDeliveryIDs: Set<String>?) -> Candidate? {
        guard !activePlanIDs.isEmpty, gap >= 0 else { return nil }
        var globalLast: Date?
        var planLast: [String: Date] = [:]
        for job in jobs {
            // 与单队列 Scheduling.lastSendActivity 使用同一活动证据口径。
            guard let activity = Scheduling.lastSendActivity([job]) else { continue }
            globalLast = globalLast.map { max($0, activity) } ?? activity
            planLast[job.planID] = planLast[job.planID].map { max($0, activity) } ?? activity
        }
        let globalDue = globalLast.map { $0.addingTimeInterval(Double(gap) * 60) }
        var next: Candidate?
        for (offset, job) in jobs.enumerated() {
            guard activePlanIDs.contains(job.planID), job.status == "queued", !job.isOneOff,
                  job.submittedAt == nil, job.evidence.isEmpty,
                  allowedDeliveryIDs?.contains(job.id) ?? true else { continue }
            var due = job.scheduled
            if let globalDue { due = max(due, globalDue) }
            if let interval = intervalByPlan[job.planID] {
                // 设置层应校验间隔；非法输入不得反向缩短本计划冷却。
                guard interval >= 0 else { continue }
                if let last = planLast[job.planID] {
                    due = max(due, last.addingTimeInterval(Double(interval) * 60))
                }
            }
            let candidate = Candidate(job: job, due: due, lastPlanActivity: planLast[job.planID], offset: offset)
            if next.map({ precedes(candidate, $0) }) ?? true { next = candidate }
        }
        return next
    }

    static func nextCandidate(jobs: [Delivery], activePlanIDs: Set<String>, gap: Int,
                              intervalByPlan: [String: Int] = [:], allowedDeliveryIDs: Set<String>? = nil) -> Delivery? {
        candidate(jobs: jobs, activePlanIDs: activePlanIDs, gap: gap,
                  intervalByPlan: intervalByPlan, allowedDeliveryIDs: allowedDeliveryIDs)?.job
    }

    /// 运行中的任何任务都占用唯一前台通道，不能因查看或启动另一队列而并发切群。
    /// 失败和待核对留在日志；它们既不自动重发，也不阻止另一条干净待执行任务。
    static func eligible(jobs: [Delivery], activePlanIDs: Set<String>, now: Date, gap: Int,
                         intervalByPlan: [String: Int] = [:], allowedDeliveryIDs: Set<String>? = nil) -> Delivery? {
        guard !jobs.contains(where: { $0.status == "running" }),
              let next = candidate(jobs: jobs, activePlanIDs: activePlanIDs, gap: gap,
                                   intervalByPlan: intervalByPlan, allowedDeliveryIDs: allowedDeliveryIDs),
              next.due <= now else { return nil }
        return next.job
    }
}
