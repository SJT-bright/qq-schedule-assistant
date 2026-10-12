import Foundation

/// 清空发送记录只改变历史页的可见性。记录本身留在数据库中，供队列进度与防重复门禁继续使用。
enum HistoryArchive {
    /// queued/running/submitted 仍属于待执行或正在处理的操作，不能从历史页清走。
    /// 使用白名单，未来新增状态不会未经确认就成为可清空记录。
    static func canClear(_ job: Delivery) -> Bool {
        ["draft", "uncertain", "blocked", "cancelled", "manual", "verified", "failed"].contains(job.status)
    }

    static func cleared(jobs: [Delivery], ids: Set<String>, at: Date) -> [Delivery] {
        jobs.map { job in
            guard ids.contains(job.id), canClear(job), job.historyClearedAt == nil else { return job }
            var hidden = job
            hidden.historyClearedAt = at
            return hidden
        }
    }

    static func restored(jobs: [Delivery], ids: Set<String>) -> [Delivery] {
        jobs.map { job in
            guard ids.contains(job.id), job.historyClearedAt != nil else { return job }
            var visible = job
            visible.historyClearedAt = nil
            return visible
        }
    }

    /// 保留本次清空之前的完整记录；可在后台编码与落盘，不引用 Store 或其他可变共享状态。
    struct Snapshot: Codable, Equatable {
        var version = 1
        var id = UUID().uuidString
        var createdAt: Date
        var deliveries: [Delivery]
    }

    static func snapshot(jobs: [Delivery], ids: Set<String>, at: Date) -> Snapshot {
        Snapshot(createdAt: at, deliveries: jobs.filter {
            ids.contains($0.id) && canClear($0) && $0.historyClearedAt == nil
        })
    }

    /// 同步文件操作供后台任务调用。必须先成功返回，再在主线程设置隐藏标记并保存数据库。
    /// 使用随机文件名避免覆盖旧备份；原子写避免半份 JSON 被当作可恢复记录。
    static func writeBackup(_ snapshot: Snapshot, to directory: URL) throws -> URL {
        guard directory.isFileURL else { throw AppError("发送记录备份必须保存在本机文件夹") }
        try validate(snapshot)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 使用默认 Date 编码保留小数秒；ISO8601 默认格式会截断本次提交的精确时间。
        let data = try encoder.encode(snapshot)
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    static func readBackup(at file: URL) throws -> Snapshot {
        guard file.isFileURL else { throw AppError("发送记录备份必须是本机文件") }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        try validate(snapshot)
        return snapshot
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == 1 else { throw AppError("不支持这个发送记录备份版本") }
        guard Set(snapshot.deliveries.map(\.id)).count == snapshot.deliveries.count else {
            throw AppError("发送记录备份包含重复任务，未恢复")
        }
        guard snapshot.deliveries.allSatisfy({ canClear($0) && $0.historyClearedAt == nil }) else {
            throw AppError("发送记录备份包含待执行、正在发送或已清空的任务，未恢复")
        }
    }
}
