import SwiftUI
import AppKit

/// 发送结果门禁的 Store 集成检查。所有资料都是临时创建；不启动调度心跳，也不进入聊天驱动。
@main @MainActor struct VerificationStoreTests {
    static func main() async throws {
        setenv("QQ_DISPATCH_NO_SEND", "1", 1)
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-verification-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw AppError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        let now = Date()
        let recipient = Recipient(name: "隔离核验群")
        var plan = Plan(name: "隔离结果门禁", text: "仅验证状态，不发送", assetIDs: [], recipientIDs: [recipient.id], starts: now.addingTimeInterval(3600), days: 1, times: [], intervalMinutes: 30, mode: "automatic")
        plan.recurringEveryDays = 1
        var submitted = Delivery(planID: plan.id, planName: plan.name, recipient: recipient.name, text: plan.text, assets: [], scheduled: now.addingTimeInterval(-30), mode: "automatic")
        submitted.status = "submitted"
        submitted.started = now.addingTimeInterval(-10)
        submitted.submittedAt = now.addingTimeInterval(-5)
        submitted.detail = "发送按键前检查点；保留既有过程"
        submitted.evidence = "旧观察记录必须保留"
        func proof(for job: Delivery) -> QQVerificationEvidence {
            QQVerificationEvidence(deliveryID: job.id, selectedTitle: recipient.name, trigger: "点击QQ发送按钮",
                submittedAt: now.addingTimeInterval(-5), firstObservedAt: now.addingTimeInterval(-3),
                confirmedAt: now.addingTimeInterval(-2), baselineRowIDs: ["old-1", "old-2", "old-3"],
                confirmedRowIDs: ["old-1", "old-2", "old-3", "new-self-message"],
                messageID: "new-self-message", textMatches: true, images: 0, requiredImages: 0, draftCleared: true,
                baselineAtLatest: true, confirmedAtLatest: true)
        }
        func prepare(_ job: Delivery, recurring: Bool = true) throws {
            var selectedPlan = plan
            selectedPlan.recurringEveryDays = recurring ? 1 : nil
            store.recipients = [recipient]
            store.plans = [selectedPlan]
            store.deliveries = [job]
            store.settings.notifyOnOutcome = false
            store.running = true
            store.activePlanID = plan.id
            store.error = nil
            try store.persist()
        }

        var defaultJob = submitted
        defaultJob.id = "default-queued"
        defaultJob.status = "queued"
        defaultJob.started = nil; defaultJob.submittedAt = nil; defaultJob.evidence = ""; defaultJob.detail = "等待执行"
        try prepare(defaultJob)
        let defaultDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(defaultDisk.first?.status == "queued" && defaultDisk.first?.qqVerification == nil,
                  "未运行任务落盘仍为queued，不会默认生成核验结果")

        for status in ["queued", "running"] {
            var job = submitted
            job.id = "spoof-\(status)"; job.status = status
            try prepare(job)
            let accepted = store.mutate(job.id, status: "verified", detail: "伪造核验成功", qqVerification: proof(for: job))
            try check(accepted && store.deliveries[0].status == "uncertain" && store.deliveries[0].qqVerification == nil,
                      "\(status)即使传入有效结构凭据也不能跳过submitted检查点")
            try check(store.running && store.activePlanID == plan.id && store.deliveries.count == 1 && store.deliveries[0].finished == nil,
                      "拒绝\(status)假成功后仅记录uncertain，继续队列但不完成任务或生成循环")
        }

        try prepare(submitted)
        let noProofAccepted = store.mutate(submitted.id, status: "verified", detail: "只有文字说明，不能证明已发")
        try check(noProofAccepted && store.deliveries[0].status == "uncertain" && store.deliveries[0].qqVerification == nil,
                  "submitted缺少结构凭据必须进入uncertain而不是verified")
        try check(store.deliveries[0].submittedAt == submitted.submittedAt && store.deliveries[0].started == submitted.started
                    && store.deliveries[0].evidence == submitted.evidence && store.deliveries[0].detail.contains(submitted.detail),
                  "拒绝缺证据核验时保留检查点、旧说明和旧观察记录")
        try check(store.running && store.activePlanID == plan.id && store.deliveries.count == 1 && store.deliveries[0].finished == nil,
                  "缺证据不算完成、不生成循环，保存待核对后队列继续")
        let rejectedDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(rejectedDisk.first?.status == "uncertain" && rejectedDisk.first?.submittedAt == submitted.submittedAt
                    && rejectedDisk.first?.evidence == submitted.evidence && rejectedDisk.first?.qqVerification == nil,
                  "缺凭据的uncertain状态及原提交痕迹真实落盘")

        try prepare(submitted)
        var wrongTaskProof = proof(for: submitted)
        wrongTaskProof.deliveryID = "another-delivery"
        let wrongTaskAccepted = store.mutate(submitted.id, status: "verified", detail: "其他任务的凭据", qqVerification: wrongTaskProof)
        try check(wrongTaskAccepted && store.deliveries[0].status == "uncertain" && store.deliveries[0].qqVerification == nil,
                  "另一任务的消息凭据不能核验当前任务")

        var invalidStarted = submitted
        invalidStarted.started = now
        try prepare(invalidStarted)
        let reversedTimeAccepted = store.mutate(invalidStarted.id, status: "verified", detail: "检查点早于任务开始", qqVerification: proof(for: invalidStarted))
        try check(reversedTimeAccepted && store.deliveries[0].status == "uncertain",
                  "开始与提交时间倒置的任务不能成为verified")

        for missingPosition in ["baseline", "confirmed"] {
            try prepare(submitted)
            var missingLatestProof = proof(for: submitted)
            if missingPosition == "baseline" { missingLatestProof.baselineAtLatest = false }
            else { missingLatestProof.confirmedAtLatest = false }
            let missingLatestAccepted = store.mutate(submitted.id, status: "verified", detail: "没有消息列表最新位置证明", qqVerification: missingLatestProof)
            try check(missingLatestAccepted && store.deliveries[0].status == "uncertain"
                        && store.deliveries[0].qqVerification == nil && store.deliveries[0].finished == nil && store.running && store.activePlanID == plan.id,
                      "\(missingPosition)缺少最新位置证明时不能凭行ID差异判verified")
        }

        try prepare(submitted, recurring: false)
        let validProof = proof(for: submitted)
        let validAccepted = store.mutate(submitted.id, status: "verified", detail: "完整且稳定的新增本人消息核验", qqVerification: validProof)
        try check(validAccepted && store.deliveries[0].status == "verified" && store.deliveries[0].qqVerification == validProof,
                  "submitted具有有效新增本人消息凭据时才允许verified")
        let verifiedDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(verifiedDisk.first?.status == "verified" && verifiedDisk.first?.qqVerification == validProof
                    && verifiedDisk.first?.finished != nil && verifiedDisk.first?.submittedAt == submitted.submittedAt,
                  "成功结果和同一份结构凭据一并持久化")
        let reopenedRoot = root.appendingPathComponent("reopened")
        try store.db.backup(to: reopenedRoot)
        let reopened = try Store(root: reopenedRoot)
        try check(!reopened.running && reopened.deliveries.first?.status == "verified"
                    && reopened.deliveries.first?.qqVerification == validProof,
                  "重开Store保留verified与相同结构凭据，队列不会自行启动")

        try prepare(submitted, recurring: false)
        let submitClock = submitted.submittedAt!
        let createdSecond = UInt64(floor(submitClock.timeIntervalSince1970) + 2)
        let freshID = String(((createdSecond + 17_280_000) << 32) | 1)
        let clockFormatter = DateFormatter(); clockFormatter.locale = Locale(identifier: "en_US_POSIX")
        clockFormatter.timeZone = TimeZone(secondsFromGMT: 28800); clockFormatter.dateFormat = "HH:mm"
        let v2 = QQVerificationEvidence(ruleVersion: 2, deliveryID: submitted.id, selectedTitle: recipient.name, trigger: "Return",
            submittedAt: submitClock, firstObservedAt: submitClock.addingTimeInterval(3), confirmedAt: submitClock.addingTimeInterval(4.2),
            baselineRowIDs: ["a", "b", "tail"], confirmedRowIDs: ["a", "b", "tail", freshID], messageID: freshID,
            textMatches: true, images: 0, requiredImages: 0, draftCleared: true,
            qqVersion: QQMessageClock.supportedVersion, messageTimeLabel: clockFormatter.string(from: Date(timeIntervalSince1970: Double(createdSecond))),
            messageTimezoneOffset: 28800, confirmedPhase: .quiet)
        try check(store.mutate(submitted.id, status: "verified", detail: "本次兼容凭据", qqVerification: v2)
                  && store.deliveries[0].status == "verified" && store.deliveries[0].qqVerification == v2,
                  "缺滚动条的v2新消息时间和完整凭据允许Store落盘")
        let v2Disk = try store.db.load("deliveries", as: Delivery.self)
        try check(v2Disk[0].qqVerification == v2 && QQVerificationReview.recovered(v2Disk)[0].status == "verified",
                  "重验v2持久化凭据仍保持完成，不回退待核对")
        var pendingProof = v2; pendingProof.confirmedPhase = .pending
        try prepare(submitted, recurring: false)
        try check(store.mutate(submitted.id, status: "verified", detail: "仍在发送", qqVerification: pendingProof)
                  && store.deliveries[0].status == "uncertain" && store.running,
                  "转圈未结束的v2不能完成，但继续当前计划的其余队列")
        try prepare(submitted, recurring: false)
        _ = store.mutate(submitted.id, status: "verified", detail: "完整v1仍兼容", qqVerification: validProof)

        var legacyVerified = submitted
        legacyVerified.id = "legacy-without-typed-proof"
        legacyVerified.status = "verified"
        legacyVerified.finished = now.addingTimeInterval(-1)
        legacyVerified.evidence = "旧版仅有结论说明，原文不能丢失"
        legacyVerified.detail = "原核验过程与上一条错误说明"
        var manuallyConfirmed = legacyVerified
        manuallyConfirmed.id = "human-confirmed"; manuallyConfirmed.status = "manual"
        let validVerified = store.deliveries[0]
        let reviewed = QQVerificationReview.recovered([legacyVerified, manuallyConfirmed, validVerified])
        try check(reviewed[0].status == "uncertain" && reviewed[0].detail.contains(legacyVerified.detail),
                  "旧verified缺少typedproof时撤回自动完成并保留原说明")
        var expectedLegacy = legacyVerified
        expectedLegacy.status = "uncertain"; expectedLegacy.detail = reviewed[0].detail
        try check(reviewed[0] == expectedLegacy && reviewed[0].evidence == legacyVerified.evidence
                    && reviewed[0].scheduled == legacyVerified.scheduled && reviewed[0].started == legacyVerified.started
                    && reviewed[0].submittedAt == legacyVerified.submittedAt && reviewed[0].finished == legacyVerified.finished,
                  "旧记录复核只改status/detail，原evidence与所有时间完整保留")
        try check(QQVerificationReview.recovered(reviewed) == reviewed,
                  "旧记录复核重复执行幂等，不重复追加说明或更改凭据")
        try check(reviewed[1] == manuallyConfirmed && reviewed[2] == validVerified,
                  "人工确认和具有有效typedproof的verified保持逐字段不变")

        try prepare(submitted, recurring: false)
        // 重复主键会在Database.save的真实SQLite事务中失败；只污染这份临时Store。
        store.recipients = [recipient, recipient]
        let failedSaveAccepted = store.mutate(submitted.id, status: "verified", detail: "证据有效但保存失败", qqVerification: validProof)
        try check(!failedSaveAccepted && store.deliveries[0] == submitted && !store.running && store.error != nil,
                  "保存失败返回false并回滚submitted，不向调用方报告完成")
        let failedDisk = try store.db.load("deliveries", as: Delivery.self)
        try check(failedDisk.first?.status == "submitted" && failedDisk.first?.qqVerification == nil
                    && failedDisk.first?.finished == nil && failedDisk.first?.evidence == submitted.evidence,
                  "事务失败后磁盘保持submitted及原记录，没有遗留假成功凭据")
        store.recipients = [recipient]
        store.running = false
        print("Verification Store: \(passed) checks passed. Isolated data; no QQ sends.")
    }
}
