import Foundation

/// 修改剩余队列的时间只平移尚未尝试过的任务；不会增加任务、重试发送或改写历史。
enum QueueSchedule {
    struct Preview {
        let plan: Plan
        let deliveries: [Delivery]
        let remaining: Int
        let nextDate: Date
        let finishDate: Date
    }

    static func isCleanQueued(_ job: Delivery) -> Bool {
        job.status == "queued" && !job.isOneOff && job.started == nil && job.submittedAt == nil
            && job.evidence.isEmpty && job.qqVerification == nil
    }

    static func make(plan: Plan, jobs: [Delivery], requestedStart: Date, now: Date,
                     globalGap: Int) throws -> Preview {
        try moved(plan: plan, jobs: jobs, requestedStart: requestedStart, now: now, globalGap: globalGap)
    }

    static func moved(plan: Plan, jobs: [Delivery], requestedStart: Date, now: Date,
                      globalGap: Int) throws -> Preview {
        guard requestedStart.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
              plan.starts.timeIntervalSinceReferenceDate.isFinite, (plan.scheduleOffsetSeconds ?? 0).isFinite else {
            throw AppError("开始日期或排期偏移无效")
        }
        guard requestedStart >= now.addingTimeInterval(-60) else { throw AppError("首群时间已过，请选择当前或未来的时间") }
        guard (0...1440).contains(globalGap), (1...1440).contains(plan.intervalMinutes) else { throw AppError("发送间隔无效") }
        guard !jobs.contains(where: { $0.planID == plan.id && $0.status == "running" }) else {
            throw AppError("当前队列正在处理一条任务，结束后再修改剩余排期")
        }
        guard Set(jobs.map(\.id)).count == jobs.count else { throw AppError("任务编号重复，未修改排期") }
        guard plan.queueCancelledAt == nil else { throw AppError("此队列已取消，请先重新开始新一轮") }
        let indices = jobs.indices.filter { QueueBatch.contains(jobs[$0], in: plan) && isCleanQueued(jobs[$0]) }.sorted {
            if jobs[$0].scheduled != jobs[$1].scheduled { return jobs[$0].scheduled < jobs[$1].scheduled }
            return $0 < $1
        }
        guard let first = indices.first else { throw AppError("当前队列没有尚未尝试的待执行任务") }
        guard indices.allSatisfy({ jobs[$0].scheduled.timeIntervalSinceReferenceDate.isFinite
            && (jobs[$0].scheduleOffsetSeconds ?? 0).isFinite }) else { throw AppError("原任务日期或排期偏移无效") }
        // 不完整的历史活动时间不能成为提前发送的理由；沿用单队列同一证据口径。
        let activityDates = jobs.compactMap { Scheduling.lastSendActivity([$0]) }
        guard activityDates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw AppError("历史提交时间无效，未修改排期") }
        let globalLast = activityDates.max()
        let planLast = Scheduling.lastSendActivity(jobs.filter { $0.planID == plan.id })
        var nextDate = max(requestedStart, now)
        if let globalLast { nextDate = max(nextDate, globalLast.addingTimeInterval(Double(globalGap) * 60)) }
        if let planLast { nextDate = max(nextDate, planLast.addingTimeInterval(Double(Scheduling.paceMinutes(plan)) * 60)) }
        let delta = nextDate.timeIntervalSince(jobs[first].scheduled)
        let offset = (plan.scheduleOffsetSeconds ?? 0) + delta
        guard delta.isFinite, offset.isFinite, nextDate.timeIntervalSinceReferenceDate.isFinite else { throw AppError("新的排期偏移超出支持范围") }
        var updatedPlan = plan
        updatedPlan.scheduleOffsetSeconds = offset
        var result = jobs
        for index in indices {
            let target = jobs[index].scheduled.addingTimeInterval(delta)
            guard target.timeIntervalSinceReferenceDate.isFinite else { throw AppError("新的任务日期超出支持范围") }
            result[index].scheduled = target
            result[index].scheduleOffsetSeconds = offset
        }
        // 保存的相互间距原样保留；预计结束需计入运行时对逐条提交施加的间隔下限。
        let cadence = Double(max(globalGap, Scheduling.paceMinutes(updatedPlan))) * 60
        var finishDate = result[first].scheduled
        for index in indices.dropFirst() {
            finishDate = max(result[index].scheduled, finishDate.addingTimeInterval(cadence))
        }
        guard finishDate.timeIntervalSinceReferenceDate.isFinite else { throw AppError("预计结束日期超出支持范围") }
        return Preview(plan: updatedPlan, deliveries: result, remaining: indices.count,
                       nextDate: result[first].scheduled, finishDate: finishDate)
    }
}
