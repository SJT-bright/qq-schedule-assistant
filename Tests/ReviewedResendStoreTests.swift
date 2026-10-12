import SwiftUI
import AppKit

/// 只使用临时资料和假驱动；环境保险开关始终拦截真实 QQ / 微信。
@MainActor final class ReviewedResendDriver: ChatDriver {
    var cancelled = false
    var beforeSubmit: () throws -> Void = {}
    var verificationEvidence: QQVerificationEvidence?
    var calls: [Delivery] = []
    var submits = 0
    var behavior: (Delivery) async throws -> (String, String) = { _ in ("blocked", "隔离前置检查失败") }
    func run(_ delivery: Delivery, root: URL) async throws -> (String, String) {
        cancelled = false; verificationEvidence = nil; calls.append(delivery)
        try Task.checkCancellation()
        return try await behavior(delivery)
    }
}

@main @MainActor struct ReviewedResendStoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw AppError("FAIL: \(name)") }
        passed += 1; print("PASS: \(name)"); fflush(stdout)
    }
    static func idle(_ store: Store) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(!store.busy, "隔离驱动已结束")
    }
    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-reviewed-resend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let fake = ReviewedResendDriver()
        let recipient = Recipient(id: "reviewed-recipient", name: "隔离重发群")
        let asset = Asset(id: "image-snapshot", name: "原图.png", relativePath: "assets/original.png",
                          sha256: "original-digest", bytes: 100, isImage: true)
        let plan = Plan(id: "reviewed-plan", name: "原发送计划", text: "计划后来修改过的文字", assetIDs: [],
                        recipientIDs: [recipient.id], starts: Date().addingTimeInterval(7200), days: 1,
                        times: [], intervalMinutes: 1, mode: "automatic")
        var otherPlan = plan; otherPlan.id = "other-plan"
        var source = Delivery(id: "original-attempt", planID: plan.id, planName: "原计划名称快照",
                              recipient: recipient.name, text: "核对记录里的原正文", assets: [asset],
                              scheduled: Date().addingTimeInterval(-7200), mode: "automatic",
                              status: "uncertain", detail: "原失败原因及已按一次 Return 的记录",
                              started: Date().addingTimeInterval(-7190), submittedAt: Date().addingTimeInterval(-7180),
                              finished: Date().addingTimeInterval(-7170), evidence: "原提交观察不得删除",
                              channel: SendChannel.qq, recipientID: recipient.id, cycleTag: 2,
                              historyClearedAt: Date().addingTimeInterval(-600), scheduleOffsetSeconds: 1800)
        source.qqVerification = QQVerificationEvidence(deliveryID: source.id, selectedTitle: recipient.name,
            trigger: "Return", submittedAt: source.submittedAt!, firstObservedAt: source.submittedAt!.addingTimeInterval(1),
            confirmedAt: source.submittedAt!.addingTimeInterval(2), baselineRowIDs: ["old-tail"],
            confirmedRowIDs: ["old-tail", "old-self"], messageID: "old-self", textMatches: true,
            images: 1, requiredImages: 1, draftCleared: true, baselineAtLatest: true, confirmedAtLatest: true)
        let next = Delivery(id: "untouched-next", planID: plan.id, planName: plan.name, recipient: "后续群",
                            text: "后续原文", assets: [], scheduled: Date().addingTimeInterval(7200), mode: "automatic")
        var other = next; other.id = "untouched-other"; other.planID = otherPlan.id

        func prepare(_ records: [Delivery], active: Set<String> = []) async throws {
            store.stop(); try await idle(store)
            store.recipients = [recipient]; store.assets = [asset]; store.plans = [plan, otherPlan]
            store.deliveries = records; store.guestMode = true; store.isolatedDispatchDriver = fake
            store.settings.globalGapMinutes = 0; store.settings.notifyOnOutcome = false
            store.settings.staggerJitter = false
            store.settings.restorePreviousApp = false; store.settings.returnToSchedulerAfterSend = false
            store.chosenPlanID = otherPlan.id; store.runningPlanIDs = active; store.error = nil
            fake.calls = []; fake.submits = 0; fake.verificationEvidence = nil
            fake.behavior = { _ in ("blocked", "隔离前置检查失败") }
            try store.persist()
        }
        func disk(_ id: String) throws -> Delivery? {
            try store.db.load("deliveries", as: Delivery.self).first { $0.id == id }
        }

        // 不确认、状态变化、探针与门禁都不得创建新的记录或碰驱动。
        try await prepare([source, next, other])
        for confirmations in [(false, true), (true, false), (false, false)] {
            try check(!store.resendReviewed(source, confirmedUnsent: confirmations.0, confirmedDraftCleared: confirmations.1)
                        && store.deliveries == [source, next, other] && fake.calls.isEmpty,
                      "未完整确认未发出及草稿已清空，原记录不变")
        }
        var changed = source; changed.detail += "\n核对期间记录已更新"
        store.deliveries[0] = changed
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries == [changed, next, other] && fake.calls.isEmpty,
                  "确认弹窗里的旧快照不能重发已变化的记录")
        try await prepare([source])
        store.isolatedDispatchDriver = nil
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries == [source] && DispatchProbe.drivenEntries.contains("人工核对后重新发送"),
                  "探针在创建记录之前拦截真实重发入口")
        store.isolatedDispatchDriver = fake; store.guestMode = false; store.licenseState = .loggedOut
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries == [source] && fake.calls.isEmpty, "无会员或游客授权时不建立重发任务")

        for status in ["running", "verified", "manual", "cancelled", "unknown"] {
            var closed = source; closed.status = status
            try await prepare([closed])
            try check(!store.resendReviewed(closed, confirmedUnsent: true, confirmedDraftCleared: true)
                        && store.deliveries == [closed] && fake.calls.isEmpty, "\(status)不是人工重发入口")
        }
        var cleanQueued = next
        try await prepare([cleanQueued])
        try check(!store.resendReviewed(cleanQueued, confirmedUnsent: true, confirmedDraftCleared: true)
                    && fake.calls.isEmpty, "普通待执行任务继续走原单发入口")
        cleanQueued.status = "blocked"; cleanQueued.text = ""; cleanQueued.assets = []
        try await prepare([cleanQueued])
        try check(!store.resendReviewed(cleanQueued, confirmedUnsent: true, confirmedDraftCleared: true)
                    && fake.calls.isEmpty, "没有发送内容时不建立空重发")

        // 两条运行队列都保持运行：单条重发不改任何后续任务与页面选择。
        try await prepare([source, next, other], active: [plan.id, otherPlan.id])
        fake.behavior = { _ in try await Task.sleep(nanoseconds: 100_000_000); return ("blocked", "隔离草稿守卫拒绝已有草稿") }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "核对后进入单条重发通道")
        let attempt = store.deliveries.last!
        try check(attempt.id != source.id && attempt.cloneOf == source.id && attempt.isOneOff
                    && attempt.status == "running" && attempt.mode == "automatic", "重发使用新 UUID 和一次性自动发送记录")
        try check(attempt.text == source.text && attempt.assets == source.assets && attempt.recipient == source.recipient
                    && attempt.channel == source.channel && attempt.recipientID == source.recipientID
                    && attempt.planName == source.planName, "原群、正文和附件快照不受后来的模板修改影响")
        try check(attempt.submittedAt == nil && attempt.evidence.isEmpty && attempt.qqVerification == nil
                    && attempt.historyClearedAt == nil && attempt.cycleTag == nil && attempt.scheduleOffsetSeconds == nil,
                  "新尝试不继承旧提交凭据、归档标记或循环排期")
        try check(store.runningPlanIDs == [plan.id, otherPlan.id] && store.chosenPlanID == otherPlan.id
                    && store.deliveries.dropLast() == [source, next, other] && (try disk(source.id)) == source,
                  "两条队列的启动状态、选择、后续排期和旧失败记录完全保留")
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries.count == 4, "忙碌期间连续点击不创建第二个尝试")
        store.tick()
        try await idle(store)
        try check(fake.calls.map(\.id) == [attempt.id] && store.deliveries.last?.status == "blocked"
                    && store.deliveries.last?.submittedAt == nil && store.deliveries.dropLast() == [source, next, other],
                  "草稿检查失败只拦截新尝试，不提交、不启动后续群")
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries.count == 4, "原记录已有重发尝试时指向新记录，不重复创建")

        // 新失败必须重新人工核对，可从新记录建立下一次尝试；仍保留全部记录。
        let failed = store.deliveries.last!
        try check(store.resendReviewed(failed, confirmedUnsent: true, confirmedDraftCleared: true),
                  "重发失败后可核对这次新记录并再次人工重发")
        try await idle(store)
        try check(store.deliveries.count == 5 && store.deliveries.last?.cloneOf == failed.id
                    && (try disk(failed.id)) == failed && (try disk(source.id)) == source,
                  "多次人工重发沿来源链保留每次失败与最初提交痕迹")

        // 明确人工重发立即执行；新提交为后续自动队列建立新的间隔下限。
        var recent = source; recent.submittedAt = Date().addingTimeInterval(-20)
        try await prepare([recent, next])
        store.settings.globalGapMinutes = 0; store.plans[0].intervalMinutes = 30
        fake.behavior = { _ in try fake.beforeSubmit(); fake.submits += 1; return ("uncertain", "隔离人工立即重发") }
        try check(store.resendReviewed(recent, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.busy && !store.running, "人工确认重发立即处理，不被旧计划冷却继续挡住")
        try await idle(store)
        try check(fake.calls.count == 1 && fake.submits == 1 && (try disk(recent.id)) == recent
                    && store.earliestSendDate(next) >= store.deliveries.last!.submittedAt!.addingTimeInterval(1800),
                  "重发保留原记录，并按本次提交为后续任务计算计划间隔")
        var globalRecent = recent; globalRecent.id = "other-recent"; globalRecent.planID = otherPlan.id
        try await prepare([source, globalRecent])
        store.settings.globalGapMinutes = 30
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.busy && store.deliveries.dropLast() == [source, globalRecent],
                  "人工确认重发立即处理，不被另一队列旧提交时间挡住")
        try await idle(store)
        try check(fake.calls.count == 1 && !store.running && (try disk(globalRecent.id)) == globalRecent,
                  "人工立即重发不改其他队列记录或启动暂停队列")

        // 每次暂停后立即开始都会重排，包括原来固定在未来几天的待发任务。
        var first = next; first.id = "start-first"; first.scheduled = Date().addingTimeInterval(7200)
        var second = next; second.id = "start-second"; second.scheduled = Date().addingTimeInterval(86400)
        var third = next; third.id = "start-third"; third.scheduled = Date().addingTimeInterval(172800)
        var oneOff = next; oneOff.id = "one-off-draft"; oneOff.oneOff = true; oneOff.mode = "draft"
        var submittedQueue = recent; submittedQueue.id = "submitted-queue"; submittedQueue.status = "queued"
        try await prepare([recent, first, second, third, other, oneOff, submittedQueue])
        store.plans[0].intervalMinutes = 15; store.settings.globalGapMinutes = 30
        fake.behavior = { _ in
            try await Task.sleep(nanoseconds: 40_000_000)
            try fake.beforeSubmit(); fake.submits += 1
            return ("uncertain", "隔离：首群提交一次后待人工核对")
        }
        let clicked = Date()
        store.start(planID: plan.id, expectedDeliveryID: first.id)
        let startedFirst = store.deliveries.first { $0.id == first.id }!
        let movedSecond = store.deliveries.first { $0.id == second.id }!
        let movedThird = store.deliveries.first { $0.id == third.id }!
        try check(store.busy && startedFirst.status == "running" && store.runningPlanIDs == [plan.id]
                    && startedFirst.scheduled >= clicked && startedFirst.scheduled <= Date(),
                  "暂停后点立即开始直接处理预览首群，未来排期和旧提交冷却都不造成等待")
        try check(movedSecond.scheduled == startedFirst.scheduled.addingTimeInterval(1800)
                    && movedThird.scheduled == startedFirst.scheduled.addingTimeInterval(3600)
                    && (try disk(second.id)) == movedSecond && (try disk(third.id)) == movedThird,
                  "剩余跨天任务从点击时间按当前有效间隔重排，并在发送前整体落盘")
        try check((try disk(recent.id)) == recent && (try disk(other.id)) == other
                    && (try disk(oneOff.id)) == oneOff && (try disk(submittedQueue.id)) == submittedQueue
                    && store.chosenPlanID == otherPlan.id,
                  "立即开始保留历史核对记录、其他队列、一次性草稿及带提交痕迹 queued")
        let whileBusy = store.deliveries
        store.start(planID: otherPlan.id, expectedDeliveryID: other.id)
        try check(store.deliveries == whileBusy && store.runningPlanIDs == [plan.id],
                  "立即开始仍串行；在途时另一队列不能重排或抢占驱动")
        try await idle(store)
        let firstOutcome = store.deliveries.first { $0.id == first.id }!
        store.tick()
        try check(fake.calls.map(\.id) == [first.id] && fake.submits == 1 && firstOutcome.status == "uncertain"
                    && store.earliestSendDate(movedSecond) >= firstOutcome.submittedAt!.addingTimeInterval(1800),
                  "首群只提交一次；未确认日志保留，后续自动发送继续遵守本次实际提交后的间隔")
        store.stop()
        try await Task.sleep(nanoseconds: 20_000_000)
        let clickedAgain = Date()
        store.start(planID: plan.id, expectedDeliveryID: second.id)
        let startedSecond = store.deliveries.first { $0.id == second.id }!
        let movedAgain = store.deliveries.first { $0.id == third.id }!
        try check(store.busy && startedSecond.status == "running" && startedSecond.scheduled >= clickedAgain
                    && startedSecond.scheduled <= Date() && startedSecond.scheduled < movedSecond.scheduled,
                  "再次全部暂停后点击立即开始，又立即处理下一群，不沿用上次排期或冷却")
        try check(movedAgain.scheduled == startedSecond.scheduled.addingTimeInterval(1800)
                    && (try disk(first.id)) == firstOutcome && (try disk(other.id)) == other,
                  "第二次点击重新起算剩余排期，不改前次已提交记录或其他计划")
        try await idle(store)
        store.tick()
        try check(fake.calls.map(\.id) == [first.id, second.id] && fake.submits == 2 && !store.busy,
                  "两次人工立即开始各提交当前下一群一次，第三群继续按新间隔等待")

        try await prepare([recent, first, second, other], active: [otherPlan.id])
        store.start(planID: plan.id, expectedDeliveryID: first.id)
        try check(store.busy && store.processingPlanID == plan.id
                    && store.runningPlanIDs == [plan.id, otherPlan.id] && (try disk(other.id)) == other,
                  "另一队列等待时立即开始仍优先处理点击的首群，保留两队列各自运行状态")
        try await idle(store)
        try check(fake.calls.map(\.id) == [first.id], "直接执行指定首群不让心跳选中另一计划")

        try await prepare([recent, first, second, other], active: [otherPlan.id])
        store.start(planID: plan.id, expectedDeliveryID: "stale-preview")
        try check(!store.busy && fake.calls.isEmpty && store.deliveries == [recent, first, second, other]
                    && store.runningPlanIDs == [otherPlan.id], "首群预览变化时拒绝启动并保持其他队列")

        try await prepare([recent, first, second, other])
        store.start(planID: plan.id, immediate: false)
        store.tick()
        try check(!store.busy && fake.calls.isEmpty && store.runningPlanIDs == [plan.id]
                    && store.deliveries == [recent, first, second, other],
                  "按排期启动仍保留用户指定的未来时间，不执行人工立即重排")

        try await prepare([recent, first, second, other], active: [otherPlan.id])
        store.recipients.append(recipient)
        store.start(planID: plan.id, expectedDeliveryID: first.id)
        try check(!store.running && !store.busy && fake.calls.isEmpty && store.error != nil
                    && store.deliveries == [recent, first, second, other] && (try disk(first.id)) == first,
                  "立即重排保存失败回滚原排期，停止全部队列且不进入驱动")

        try await prepare([recent, first, second, other])
        store.settings.globalGapMinutes = 30
        store.sendSingle(first.id)
        try check(store.busy && !store.running && store.deliveries[1].scheduled <= Date()
                    && store.deliveries[0] == recent && store.deliveries[2] == second && store.deliveries[3] == other,
                  "现在发送此条也立即处理，不等待旧冷却，也不启动或改排其他任务")
        try await idle(store)
        try check(fake.calls.map(\.id) == [first.id], "手动单发仍只进入一条驱动")

        // 提交检查点与结果均只写入新尝试，旧凭据不能冒充本次成功。
        try await prepare([source, next, other])
        fake.behavior = { job in
            try fake.beforeSubmit(); fake.submits += 1
            try check((try disk(job.id))?.status == "submitted" && (try disk(job.id))?.submittedAt != nil,
                      "新尝试在发送指令之前写入同一个持久化检查点")
            return ("uncertain", "隔离：已提交一次但核验未通过")
        }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "单条重发进入提交路径")
        try await idle(store)
        let unconfirmed = store.deliveries.last!
        try check(fake.submits == 1 && unconfirmed.status == "uncertain" && unconfirmed.submittedAt != nil
                    && unconfirmed.qqVerification == nil && (try disk(source.id)) == source,
                  "一次提交后核验失败保存待核对，旧证据不作为本次成功")
        store.tick(); try await Task.sleep(nanoseconds: 50_000_000)
        try check(fake.calls.count == 1 && !store.running, "待核对的新尝试不自动重试，也不启动暂停中的队列")

        try await prepare([source])
        fake.behavior = { _ in try fake.beforeSubmit(); fake.submits += 1; throw AppError("隔离：提交后前台被切换") }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "提交后异常验收开始")
        try await idle(store)
        try check(store.deliveries.last?.status == "uncertain" && store.deliveries.last?.submittedAt != nil
                    && store.deliveries.last?.detail.contains("前台被切换") == true && fake.submits == 1,
                  "提交后异常保留提交时间和原因，不改成完成或再按发送")

        try await prepare([source, next])
        fake.behavior = { job in
            try fake.beforeSubmit(); fake.submits += 1
            let current = store.deliveries.first { $0.id == job.id }!
            let submit = current.submittedAt!
            fake.verificationEvidence = QQVerificationEvidence(deliveryID: job.id, selectedTitle: job.recipient,
                trigger: "隔离发送按钮", submittedAt: submit, firstObservedAt: submit.addingTimeInterval(1),
                confirmedAt: submit.addingTimeInterval(2), baselineRowIDs: ["a", "b", "old-tail"],
                confirmedRowIDs: ["a", "b", "old-tail", "fresh-self"], messageID: "fresh-self",
                textMatches: true, images: 1, requiredImages: 1, draftCleared: true,
                baselineAtLatest: true, confirmedAtLatest: true)
            return ("verified", "隔离新本人图文完整且双拍稳定")
        }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "合格新凭据验收开始")
        try await idle(store)
        let success = store.deliveries.last!
        try check(success.status == "verified" && success.qqVerification?.deliveryID == success.id
                    && success.qqVerification?.isValid(for: success) == true && (try disk(success.id)) == success
                    && (try disk(source.id)) == source && (try disk(next.id)) == next,
                  "只有本次新消息凭据允许完成并落盘，旧记录和下一群不变")
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true),
                  "原记录已有成功重发后不会再建立重复尝试")

        // 数据库失败：建立、检查点、结果三处都失败关闭并保留可恢复的记录。
        try await prepare([source, next, other], active: [plan.id, otherPlan.id])
        store.recipients.append(recipient)
        try check(!store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true)
                    && store.deliveries == [source, next, other] && !store.running && fake.calls.isEmpty
                    && (try disk(source.id)) == source, "创建副本事务失败回滚、不碰驱动，并停止全部队列")

        try await prepare([source, next, other], active: [plan.id, otherPlan.id])
        fake.behavior = { _ in
            store.recipients.append(recipient)
            defer { store.recipients = [recipient] }
            try fake.beforeSubmit(); fake.submits += 1
            return ("uncertain", "不应抵达")
        }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "检查点失败验收开始")
        try await idle(store)
        try check(fake.submits == 0 && !store.running && store.deliveries.last?.status == "blocked"
                    && store.deliveries.last?.submittedAt == nil && (try disk(source.id)) == source,
                  "检查点落盘失败绝不提交，停止全部队列并保留原记录")

        try await prepare([source, next])
        fake.behavior = { _ in store.recipients.append(recipient); return ("blocked", "隔离结果保存失败") }
        try check(store.resendReviewed(source, confirmedUnsent: true, confirmedDraftCleared: true), "结果保存失败验收开始")
        try await idle(store)
        let interrupted = store.deliveries.last!
        try check(!store.running && interrupted.status == "running" && (try disk(interrupted.id)) == interrupted
                    && (try disk(source.id)) == source && store.error != nil,
                  "结果保存失败保留已落盘过程，不伪造完成或清掉失败")
        store.recipients = [recipient]
        let recoveredRoot = root.appendingPathComponent("reopened")
        try store.db.backup(to: recoveredRoot)
        let reopened = try Store(root: recoveredRoot)
        try check(!reopened.running && reopened.deliveries.first { $0.id == interrupted.id }?.status == "uncertain"
                    && reopened.deliveries.first { $0.id == source.id } == source,
                  "重开应用后只恢复人工核对状态，保留旧记录且不自动重发")

        // QQ / 微信、未发送、已拦截、已提交及遗留 queued 痕迹都能经显式核对进入新尝试。
        for status in ["draft", "blocked", "submitted", "queued"] {
            var review = source; review.status = status; review.channel = SendChannel.wechat
            try await prepare([review])
            try check(store.resendReviewed(review, confirmedUnsent: true, confirmedDraftCleared: true),
                      "微信\(status)可在核对后创建单条重发")
            try await idle(store)
            try check(fake.calls.first?.channelName == SendChannel.wechat && (try disk(review.id)) == review,
                      "微信\(status)沿原渠道处理且保留原记录")
        }
        print("PASS \(passed) reviewed resend store checks; no real QQ / WeChat sends")
    }
}
