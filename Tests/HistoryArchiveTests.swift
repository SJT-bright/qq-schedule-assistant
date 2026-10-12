import Foundation

@main
struct HistoryArchiveTests {
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw AppError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000.125)
        let earlier = now.addingTimeInterval(-12.375)
        let asset = Asset(name: "配图.png", relativePath: "assets/existing.png", sha256: "source-image-hash", bytes: 128, isImage: true, imported: earlier)
        func fixture(_ status: String, id: String? = nil, planID: String = "queue-1") -> Delivery {
            var job = Delivery(planID: planID, planName: "队列一", recipient: "隔离群", text: "完整原文\n第二行", assets: [asset], scheduled: earlier, mode: "automatic")
            job.id = id ?? status
            job.status = status
            job.started = earlier
            job.submittedAt = earlier.addingTimeInterval(1.125)
            job.finished = now.addingTimeInterval(-2.625)
            job.evidence = "原始观察记录必须保留"
            job.detail = "原始步骤与错误说明"
            job.channel = "qq"
            job.recipientID = "recipient-1"
            job.cycleTag = 2
            job.qqVerification = QQVerificationEvidence(deliveryID: job.id, selectedTitle: job.recipient,
                trigger: "Return", submittedAt: job.submittedAt!, firstObservedAt: earlier.addingTimeInterval(2.125),
                confirmedAt: earlier.addingTimeInterval(3.125), baselineRowIDs: ["old-1", "old-2", "old-3"],
                confirmedRowIDs: ["old-1", "old-2", "old-3", "new-self-message"], messageID: "new-self-message",
                textMatches: true, images: 1, requiredImages: 1, draftCleared: true,
                baselineAtLatest: true, confirmedAtLatest: true)
            return job
        }

        for status in ["failed", "cancelled", "manual", "verified", "uncertain", "draft", "blocked"] {
            let original = fixture(status)
            let hidden = HistoryArchive.cleared(jobs: [original], ids: [original.id], at: now)
            try check(HistoryArchive.canClear(original) && hidden[0].historyClearedAt == now,
                      "\(status)允许从发送记录页清空")
            var restoredContent = hidden[0]
            restoredContent.historyClearedAt = nil
            try check(restoredContent == original, "\(status)清空完整保留状态、原文、配图、提交时间和核验凭据")
            try check(HistoryArchive.restored(jobs: hidden, ids: [original.id]) == [original],
                      "\(status)可以恢复原始记录")
        }
        for status in ["queued", "running", "submitted", "future-status"] {
            let original = fixture(status)
            try check(!HistoryArchive.canClear(original)
                      && HistoryArchive.cleared(jobs: [original], ids: [original.id], at: now) == [original],
                      "\(status)不得被清空")
        }

        let first = fixture("verified", id: "first")
        let otherQueue = fixture("manual", id: "second", planID: "queue-2")
        let queued = fixture("queued", id: "still-queued")
        let scoped = HistoryArchive.cleared(jobs: [first, otherQueue, queued], ids: [first.id, queued.id, "missing"], at: now)
        try check(scoped[0].historyClearedAt == now && scoped[1] == otherQueue && scoped[2] == queued,
                  "只清空明确选中的可清空记录，不影响另一队列或待执行任务")
        try check(scoped.map(\.id) == [first.id, otherQueue.id, queued.id], "清空不删任务且保留原有顺序")
        try check(HistoryArchive.cleared(jobs: scoped, ids: [first.id], at: now.addingTimeInterval(10)) == scoped,
                  "再次清空不覆盖已有批次的时间")
        try check(HistoryArchive.restored(jobs: scoped, ids: [otherQueue.id]) == scoped,
                  "恢复未选中的记录不会跨队列显示")
        try check(HistoryArchive.restored(jobs: scoped, ids: [first.id])[1] == otherQueue,
                  "恢复一条记录不修改其他记录")
        try check(HistoryArchive.cleared(jobs: [first], ids: [], at: now) == [first], "空范围清空不改变资料")

        let snapshot = HistoryArchive.snapshot(jobs: [first, otherQueue, queued, scoped[0]], ids: [first.id, queued.id], at: now)
        try check(snapshot.deliveries == [first] && snapshot.createdAt == now,
                  "快照只包含本次真正清空之前的完整记录，不包含已隐藏和待执行记录")
        let backupRoot = FileManager.default.temporaryDirectory.appendingPathComponent("qq-history-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        let firstURL = try await Task.detached { try HistoryArchive.writeBackup(snapshot, to: backupRoot) }.value
        let decoded = try HistoryArchive.readBackup(at: firstURL)
        try check(decoded == snapshot, "后台原子备份与读取保留全部字段和小数秒时间")
        let secondURL = try HistoryArchive.writeBackup(snapshot, to: backupRoot)
        try check(firstURL != secondURL && FileManager.default.fileExists(atPath: firstURL.path),
                  "重复备份创建新文件，不覆盖之前的恢复资料")
        let attributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "备份文件仅当前用户可读写")

        let encoder = JSONEncoder()
        var oldJSON = try JSONSerialization.jsonObject(with: encoder.encode(first)) as! [String: Any]
        oldJSON.removeValue(forKey: "historyClearedAt")
        let oldJob = try JSONDecoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try check(oldJob == first && oldJob.historyClearedAt == nil, "旧库缺少清空标记时按可见记录解码，原数据不变")
        let hiddenJSON = try encoder.encode(scoped[0])
        try check(try JSONDecoder().decode(Delivery.self, from: hiddenJSON) == scoped[0], "新清空标记可保存并在重启后保留")

        for invalid in [HistoryArchive.Snapshot(version: 2, createdAt: now, deliveries: [first]),
                        HistoryArchive.Snapshot(createdAt: now, deliveries: [first, first]),
                        HistoryArchive.Snapshot(createdAt: now, deliveries: [queued]),
                        HistoryArchive.Snapshot(createdAt: now, deliveries: [scoped[0]])] {
            do {
                _ = try HistoryArchive.writeBackup(invalid, to: backupRoot)
                throw AppError("FAIL: 无效快照应被拒绝")
            } catch let error as AppError {
                try check(!error.message.hasPrefix("FAIL:"), "错误版本、重复任务与非本次可清空快照拒绝落盘")
            }
        }
        try check(HistoryArchive.snapshot(jobs: [queued], ids: [queued.id], at: now).deliveries.isEmpty,
                  "纯待执行范围生成空快照，不误导为清空成功")
        print("\(passed) history archive checks passed")
    }
}
