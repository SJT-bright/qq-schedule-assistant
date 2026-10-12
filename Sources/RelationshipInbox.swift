import Foundation
import Combine
import CryptoKit
import Darwin

// This module owns no Recipient, Plan, Delivery, Database or sending API.
/// 定位名称的保存提示。输入框再改一个字，或名单被刷新，提示就不再代表刚才那一次操作。
enum AliasFeedback {
    static let saved = "已保存，仅用于微信定位"
    struct Update: Equatable {
        var message: String
        var field: String
    }
    static func afterFieldEdit(message: String, field: String, fieldWhenShown: String) -> String {
        field == fieldWhenShown ? message : ""
    }
    static func afterRosterChange(field: String, fieldWhenShown: String, saved: String) -> Update {
        Update(message: "", field: field == fieldWhenShown ? saved : field)
    }
}

struct RelationshipInboxError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RelationshipTag: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

struct RelationshipContact: Codable, Equatable, Identifiable {
    let contactId: String
    let name: String
    let userNote: String
    let tags: [RelationshipTag]
    let cadenceMode: String
    let message: String
    let groupName: String
    let festival: String
    var id: String { contactId }
}

struct RelationshipSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let sourceApp: String
    let sourceInstanceId: String
    let revision: Int64
    let updatedAt: String
    let mode: String
    let contacts: [RelationshipContact]

    static let maxBytes = 5 * 1024 * 1024
    static func validText(_ text: String, min: Int = 0, max: Int, multiline: Bool = false) -> Bool {
        // Use UTF-16 length, also used by the JS publisher, for fixed wire limits.
        let count = text.utf16.count
        return count >= min && count <= max && !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && !(multiline && [9, 10, 13].contains($0.value))
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maxBytes else { throw RelationshipInboxError("同步文件超过 5 MiB") }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RelationshipInboxError("同步文件字段缺失、类型错误或 JSON 损坏") }
        try result.validate()
        return result
    }
    func validate() throws {
        guard schemaVersion == 1, sourceApp == "relationship-echo", mode == "manual-chat-only" else {
            throw RelationshipInboxError("不支持的同步协议；需要 manual-chat-only v1")
        }
        guard Self.validText(sourceInstanceId, min: 1, max: 128), !sourceInstanceId.trimmingCharacters(in: .whitespaces).isEmpty,
              revision > 0, revision <= 9_007_199_254_740_991 else { throw RelationshipInboxError("来源 ID 或同步版本无效") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: updatedAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard updatedAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#, options: .regularExpression) != nil,
              fractional != nil || formatter.date(from: updatedAt) != nil else { throw RelationshipInboxError("同步时间必须为 ISO8601 UTC") }
        guard contacts.count <= 10_000 else { throw RelationshipInboxError("同步联系人超过 10000 条") }
        var ids = Set<String>()
        for contact in contacts {
            guard Self.validText(contact.contactId, min: 1, max: 128), ids.insert(contact.contactId).inserted,
                  Self.validText(contact.name, min: 1, max: 128), !contact.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  Self.validText(contact.userNote, max: 4000, multiline: true),
                  Self.validText(contact.message, max: 10_000, multiline: true),
                  Self.validText(contact.groupName, max: 128), Self.validText(contact.festival, max: 128),
                  ["", "periodic", "festival", "both"].contains(contact.cadenceMode), contact.tags.count <= 100 else {
                throw RelationshipInboxError("联系人字段超限、重复 ID 或内容无效")
            }
            var tagIDs = Set<String>()
            for tag in contact.tags {
                guard Self.validText(tag.id, min: 1, max: 128), Self.validText(tag.name, min: 1, max: 128), tagIDs.insert(tag.id).inserted else {
                    throw RelationshipInboxError("联系人标签字段无效或 tag.id 重复")
                }
            }
        }
    }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

enum RelationshipBridgeLocation {
    static let filename = "manual-wechat-v1.json"
    static var defaultAppRoot: URL {
        // applicationSupport 在 macOS 上恒有返回，但这里不该用下标硬取：取不到就退回用户目录，
        // 让目录解析失败表现为「同步目录无效」而不是整个进程崩在启动路径上。
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("QQ排程助手")
    }
    static func directory(appRoot: URL, environment: [String: String]) throws -> URL {
        if let override = environment["RELATIONSHIP_ECHO_BRIDGE_DIR"] {
            guard override.hasPrefix("/"), !override.contains("\0"), !override.split(separator: "/").contains("..") else {
                throw RelationshipInboxError("隔离桥目录必须为绝对路径，且不能包含 ..")
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if environment["QQ_DISPATCH_DATA_DIR"] != nil || appRoot.standardizedFileURL != defaultAppRoot.standardizedFileURL {
            return appRoot.appendingPathComponent("RelationshipEchoBridge", isDirectory: true)
        }
        return defaultAppRoot.deletingLastPathComponent().appendingPathComponent("RelationshipEchoBridge", isDirectory: true)
    }
}

// Component-by-component openat(O_NOFOLLOW) rejects links, including a linked bridge directory.
// All reads check fstat before allocation; only fixed leaf filenames are accepted.
enum RelationshipInboxFiles {
    static func exists(directory: URL, name: String) throws -> Bool {
        let dir = try directoryFD(directory); defer { close(dir) }
        var st = stat()
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw RelationshipInboxError("无法确认本地版本记录是否存在") }
        return false
    }
    /// 还没有人同步过（缺目录或缺文件）与"文件在但不可用"必须分开：前者给引导，后者才是故障。
    enum Presence { case absent, present, unavailable }
    static func presence(directory: URL, name: String) -> Presence {
        guard !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { return .unavailable }
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else { return .unavailable }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable }
        for component in directory.path.split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); return .unavailable }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { close(fd); return errno == ENOENT ? .absent : .unavailable }
            close(fd); fd = next
        }
        defer { close(fd) }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? .absent : .unavailable }
        // 符号链接也算"在"，交给 signature/read 报真实故障，不在这里降级成首次引导。
        return .present
    }
    static func directoryFD(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw RelationshipInboxError("同步目录无效") }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RelationshipInboxError("无法读取同步目录") }
        do {
            for component in url.path.split(separator: "/") {
                guard component != ".", component != ".." else { throw RelationshipInboxError("同步目录不允许相对路径") }
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RelationshipInboxError("同步目录不存在、无权读取或包含符号链接") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    static func read(directory: URL, name: String, limit: Int) throws -> (Data, String) {
        guard !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { throw RelationshipInboxError("文件名无效") }
        let dir = try directoryFD(directory); defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RelationshipInboxError("未找到可读取的同步文件，或文件是符号链接") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw RelationshipInboxError("同步文件必须为普通文件") }
        guard st.st_size >= 0, st.st_size <= limit else { throw RelationshipInboxError("同步文件超过大小限制") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        var after = stat()
        guard data.count <= limit, fstat(fd, &after) == 0, fingerprint(st) == fingerprint(after), data.count == st.st_size else {
            throw RelationshipInboxError("同步文件读取中发生变化，请刷新重试")
        }
        return (data, fingerprint(st))
    }
    static func signature(directory: URL, name: String) throws -> String {
        let dir = try directoryFD(directory); defer { close(dir) }
        var st = stat()
        guard fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw RelationshipInboxError("同步文件缺失、非普通文件或是符号链接")
        }
        return fingerprint(st)
    }
    private static func fingerprint(_ st: stat) -> String {
        "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)"
    }
    static func write(_ data: Data, directory: URL, name: String) throws {
        let dir = try directoryFD(directory); defer { close(dir) }
        var old = stat()
        if fstatat(dir, name, &old, AT_SYMLINK_NOFOLLOW) == 0, old.st_mode & S_IFMT != S_IFREG {
            throw RelationshipInboxError("本地缓存不是普通文件；已拒绝覆盖")
        }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RelationshipInboxError("无法保存本地同步资料") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, renameat(dir, temporary, dir, name) == 0, fsync(dir) == 0 else { throw RelationshipInboxError("本地同步资料保存失败") }
    }
}

@MainActor
protocol RelationshipChatNavigator: AnyObject {
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String
}

@MainActor
final class RelationshipInbox: ObservableObject {
    private struct Revision: Codable, Equatable { let number: Int64; let digest: String }
    // Content is disposable. Version history is committed separately and must never default to empty.
    private struct Cache: Codable {
        var snapshot: RelationshipSnapshot?
        var revisions: [String: Revision]? // Read-only migration of build 33 caches.
        var formatVersion: Int?
    }
    private struct SnapshotOnly: Decodable { var snapshot: RelationshipSnapshot? }
    private struct Checkpoint: Codable {
        var schemaVersion = 1
        var revisions: [String: Revision]
        var contentDigest: String
    }
    @Published private(set) var snapshot: RelationshipSnapshot?
    @Published private(set) var isStale = true
    @Published private(set) var status = "尚未读取关系回响同步名单"
    @Published private(set) var sourceNotice: String?
    @Published private(set) var aliases: [String: String] = [:]
    @Published private(set) var isOpening = false
    @Published private(set) var openingContactID: String?
    /// 显式刷新，或同步内容真正变化时加一。未改动的定时复查不加，避免把正在输入的别名清掉。
    @Published private(set) var rosterEpoch = 0
    private let appRoot: URL
    private let bridgeDirectory: URL?
    private let configurationError: String?
    private var revisions: [String: Revision] = [:]
    private var legacyMigration: [String: Revision]?
    private var historyEstablished = false
    private var historyIssue: String?
    private var lastSignature: String?
    private let cacheName = "relationship-inbox-cache-v1.json"
    private let aliasName = "relationship-inbox-aliases-v1.json"
    private let checkpointName = "relationship-inbox-revisions-v1.json"
    private let historyMarkerName = "relationship-inbox-history-established-v1"

    init(appRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.appRoot = appRoot
        do { bridgeDirectory = try RelationshipBridgeLocation.directory(appRoot: appRoot, environment: environment); configurationError = nil }
        catch { bridgeDirectory = nil; configurationError = error.localizedDescription }
        // A valid cached snapshot is still a lower bound even if its legacy revision dictionary is broken.
        if let (data, _) = try? RelationshipInboxFiles.read(directory: appRoot, name: cacheName, limit: 16 * 1024 * 1024) {
            if let saved = (try? JSONDecoder().decode(SnapshotOnly.self, from: data))?.snapshot,
               (try? saved.validate()) != nil {
                setSnapshot(saved)
                revisions[saved.sourceInstanceId] = Revision(number: saved.revision, digest: saved.digest)
                status = "显示上次有效名单，等待同步校验"
            }
            if let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.formatVersion == nil,
               let saved = snapshot, let history = cache.revisions, Self.validHistory(history),
               history[saved.sourceInstanceId] == Revision(number: saved.revision, digest: saved.digest) {
                revisions = history
                legacyMigration = history
            }
        }
        if let (data, _) = try? RelationshipInboxFiles.read(directory: appRoot, name: aliasName, limit: 16 * 1024 * 1024),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            aliases = saved.filter { RelationshipSnapshot.validText($0.value, max: 128) }
        }
        // Broken or missing history is explicit state, not permission to bootstrap again.
        do { try ensureHistory() }
        catch { historyIssue = error.localizedDescription; status = "同步失败，名单已过期：\(error.localizedDescription)" }
    }

    private static func validHistory(_ history: [String: Revision]) -> Bool {
        !history.isEmpty && history.allSatisfy { source, revision in
            RelationshipSnapshot.validText(source, min: 1, max: 128) &&
            !source.trimmingCharacters(in: .whitespaces).isEmpty &&
            revision.number > 0 && revision.number <= 9_007_199_254_740_991 &&
            revision.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        }
    }
    private static func historyDigest(_ history: [String: Revision]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(history)).map { String(format: "%02x", $0) }.joined()
    }
    private static func aliasSource(_ key: String) -> String? {
        guard let separator = key.firstIndex(of: ":"), let length = Int(key[..<separator]), (1...512).contains(length) else { return nil }
        let suffix = Array(key[key.index(after: separator)...].utf8)
        guard suffix.count > length else { return nil }
        return String(bytes: suffix.prefix(length), encoding: .utf8)
    }
    private func historyFailure() -> RelationshipInboxError {
        RelationshipInboxError("本地同步版本记录缺失、损坏或不完整，已停止定位。请保留当前资料并恢复完整版本记录后刷新；不要删除资料重新同步。")
    }
    static func parseSyncDate(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
    /// 两端同机取系统时钟，真实偏差是亚秒级；超前超过这个量就是源端时间异常，不能再当刚同步。
    static let futureSyncTolerance: TimeInterval = 90
    /// 合同没有约定名单有效期，所以满一周只提示核对，不自动收回手动定位入口。
    static let agedSyncThreshold: TimeInterval = 7 * 86400
    enum SyncTimeIssue: Equatable { case abnormallyFuture, aged }
    /// 首次使用者看到的是引导而不是故障；视图的空状态段落已写明后续步骤，这里不再重复整句。
    static let firstSyncStatus = "还没有同步过名单：请在关系回响勾选联系人后点击“同步到微信维系列表”"
    static func futureAnomalyStatus(_ iso: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        "同步时间异常，请在关系回响重新同步：\(humanizedSyncTime(iso, now: now, calendar: calendar))"
    }
    /// 显示与放行共用这一条判断，措辞和拦截不会各走一套阈值。
    static func syncTimeIssue(_ iso: String, now: Date = Date()) -> SyncTimeIssue? {
        guard let date = parseSyncDate(iso) else { return nil }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < -futureSyncTolerance { return .abnormallyFuture }
        if elapsed >= agedSyncThreshold { return .aged }
        return nil
    }
    // Local-time display for the sync status line; unparseable input keeps the raw wire value.
    static func humanizedSyncTime(_ iso: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = parseSyncDate(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let absolute = formatter.string(from: date)
        let elapsed = now.timeIntervalSince(date)
        // 几十秒的时钟误差仍算刚同步。一小时乃至跨天超前不能再显示成「刚刚」。
        if elapsed < -futureSyncTolerance { return "\(absolute)（时间超前）" }
        let relative: String?
        if elapsed < 60 { relative = "刚刚" }
        else if elapsed < 3600 { relative = "\(Int(elapsed / 60)) 分钟前" }
        else if elapsed < 86400 { relative = "\(Int(elapsed / 3600)) 小时前" }
        else if elapsed < agedSyncThreshold { relative = "\(Int(elapsed / 86400)) 天前" }
        else { relative = nil }
        guard let relative else { return absolute }
        return "\(absolute)（\(relative)）"
    }
    private func ensureHistory() throws {
        if try RelationshipInboxFiles.exists(directory: appRoot, name: checkpointName) {
            let record: Checkpoint
            do {
                let (data, _) = try RelationshipInboxFiles.read(directory: appRoot, name: checkpointName, limit: 16 * 1024 * 1024)
                record = try JSONDecoder().decode(Checkpoint.self, from: data)
                guard record.schemaVersion == 1, Self.validHistory(record.revisions),
                      record.contentDigest == (try Self.historyDigest(record.revisions)) else { throw historyFailure() }
                guard aliases.keys.allSatisfy({ key in Self.aliasSource(key).map { record.revisions[$0] != nil } ?? false }) else { throw historyFailure() }
                // In-memory history and any valid cache can only raise the floor, never lower it.
                for (source, known) in revisions {
                    guard let persisted = record.revisions[source], persisted.number >= known.number,
                          persisted.number != known.number || persisted.digest == known.digest else { throw historyFailure() }
                }
            } catch { throw historyFailure() }
            revisions = record.revisions
            historyEstablished = true
            legacyMigration = nil
            historyIssue = nil
            return
        }
        // A marker survives loss of the checkpoint and content cache. A v2 content cache is also evidence.
        guard !historyEstablished, try !RelationshipInboxFiles.exists(directory: appRoot, name: historyMarkerName) else { throw historyFailure() }
        if let legacyMigration, historyIssue == nil {
            // A complete old cache can migrate automatically, preserving every known source and alias.
            guard aliases.keys.allSatisfy({ key in Self.aliasSource(key).map { legacyMigration[$0] != nil } ?? false }) else { throw historyFailure() }
            revisions = legacyMigration
            return
        }
        guard historyIssue == nil, revisions.isEmpty,
              try !RelationshipInboxFiles.exists(directory: appRoot, name: cacheName),
              try !RelationshipInboxFiles.exists(directory: appRoot, name: aliasName) else { throw historyFailure() }
        // Only a root with no history/cache/alias evidence is a true first use.
    }

    private func commitHistory(_ history: [String: Revision]) throws {
        let record = Checkpoint(revisions: history, contentDigest: try Self.historyDigest(history))
        try RelationshipInboxFiles.write(JSONEncoder().encode(record), directory: appRoot, name: checkpointName)
        // Commit this floor in memory before either of the later writes can fail.
        revisions = history
        historyEstablished = true
        legacyMigration = nil
        try RelationshipInboxFiles.write(Data("relationship-inbox-history-v1\n".utf8), directory: appRoot, name: historyMarkerName)
    }
    var contacts: [RelationshipContact] { snapshot?.contacts ?? [] }
    var tags: [RelationshipTag] {
        var seen = Set<String>()
        return contacts.flatMap(\.tags).filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    // Display order for long lists: Finder-like name order, deterministic on equal names.
    private var sortedContacts: [RelationshipContact] = []
    @discardableResult
    private func setSnapshot(_ next: RelationshipSnapshot?) -> RelationshipSnapshot? {
        snapshot = next
        sortedContacts = (next?.contacts ?? []).sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.contactId < b.contactId : order == .orderedAscending
        }
        return next
    }
    func filtered(search: String, tagID: String?) -> [RelationshipContact] {
        // A search field accumulates stray spaces (including full-width); they should not blank the list.
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sortedContacts.filter { contact in
            let savedAlias = alias(for: contact.contactId)
            return (tagID == nil || contact.tags.contains { $0.id == tagID }) &&
                (query.isEmpty || contact.name.localizedCaseInsensitiveContains(query) || contact.userNote.localizedCaseInsensitiveContains(query)
                    || contact.tags.contains { $0.name.localizedCaseInsensitiveContains(query) }
                    || (!savedAlias.isEmpty && savedAlias.localizedCaseInsensitiveContains(query)))
        }
    }
    func key(for contactID: String) -> String {
        // Length-prefixing avoids ambiguous joins when source IDs contain delimiters.
        let source = snapshot?.sourceInstanceId ?? ""
        return "\(source.utf8.count):\(source)\(contactID)"
    }
    func alias(for contactID: String) -> String { aliases[key(for: contactID)] ?? "" }
    func saveAlias(_ alias: String, contactID: String) throws {
        guard contacts.contains(where: { $0.contactId == contactID }) else {
            throw RelationshipInboxError("该联系人已不在当前同步名单；请刷新后重新操作")
        }
        guard RelationshipSnapshot.validText(alias, max: 128) else {
            throw RelationshipInboxError("微信显示名称应为不超过 128 字的单行文本")
        }
        var next = aliases
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { next.removeValue(forKey: key(for: contactID)) } else { next[key(for: contactID)] = value }
        try RelationshipInboxFiles.write(JSONEncoder().encode(next), directory: appRoot, name: aliasName)
        aliases = next
    }
    /// 成功名单的状态行：人数 · 版本 · 同步时间（相对时间按 `now` 现算），满一周追加核对提醒。
    /// 抽出来是因为「文件没变」的那一拍也要重算——否则「刚刚」和「超过 7 天」会永远冻在首次读取那一瞬间（4-07）。
    private static func syncedStatus(_ snapshot: RelationshipSnapshot, now: Date = Date()) -> String {
        var line = "已同步 \(snapshot.contacts.count) 人 · 版本 \(snapshot.revision) · 同步于 \(humanizedSyncTime(snapshot.updatedAt, now: now))"
        // 满一周仍可用，只是要说清楚：合同没约定有效期，不能自作主张收回定位入口。
        if syncTimeIssue(snapshot.updatedAt, now: now) == .aged { line += " · 超过 7 天，请核对后重新同步" }
        return line
    }
    func refresh(ifModifiedOnly: Bool = false) {
        do {
            do { try ensureHistory() }
            catch { lastSignature = nil; throw error }
            guard let bridgeDirectory else { throw RelationshipInboxError(configurationError ?? "同步目录无效") }
            // 没人同步过不是故障：只有从没拿到过名单且桥确实缺失时才走引导，其余照旧报失败并保留旧名单。
            if snapshot == nil, RelationshipInboxFiles.presence(directory: bridgeDirectory, name: RelationshipBridgeLocation.filename) == .absent {
                isStale = true
                status = Self.firstSyncStatus
                return
            }
            let signature = try RelationshipInboxFiles.signature(directory: bridgeDirectory, name: RelationshipBridgeLocation.filename)
            if ifModifiedOnly, signature == lastSignature {
                // 源文件没动不代表状态行不用动：按当前时间复评相对时间与「满 7 天」。
                // 只在文案真的变了才赋值，避免每 3 秒白推一次视图刷新。
                if let snapshot, !isStale {
                    let line = Self.syncedStatus(snapshot)
                    if line != status { status = line }
                }
                return
            }
            lastSignature = signature
            let (data, readSignature) = try RelationshipInboxFiles.read(directory: bridgeDirectory, name: RelationshipBridgeLocation.filename, limit: RelationshipSnapshot.maxBytes)
            let next = try RelationshipSnapshot.decode(data)
            // 源端时钟异常超前的这一份整份不接受：不换名单、不动版本高水位、不覆盖有效缓存，只标记过期并说明原因。
            if Self.syncTimeIssue(next.updatedAt) == .abnormallyFuture {
                isStale = true
                status = Self.futureAnomalyStatus(next.updatedAt)
                return
            }
            if let previous = revisions[next.sourceInstanceId] {
                guard next.revision >= previous.number else { throw RelationshipInboxError("拒绝旧同步版本回退（\(next.revision) < \(previous.number)）") }
                guard next.revision != previous.number || next.digest == previous.digest else { throw RelationshipInboxError("同一同步版本的内容发生变化，请在关系回响重新同步") }
            }
            let changedSource = snapshot.map { $0.sourceInstanceId != next.sourceInstanceId } ?? false
            let contentChanged = snapshot?.sourceInstanceId != next.sourceInstanceId
                || snapshot?.revision != next.revision
                || snapshot?.updatedAt != next.updatedAt
                || snapshot?.contacts.map(\.contactId) != next.contacts.map(\.contactId)
            var nextRevisions = revisions
            nextRevisions[next.sourceInstanceId] = Revision(number: next.revision, digest: next.digest)
            // Never expose a snapshot or permit navigation until its high-water mark is durably saved.
            try commitHistory(nextRevisions)
            try RelationshipInboxFiles.write(JSONEncoder().encode(Cache(snapshot: next, revisions: nil, formatVersion: 2)), directory: appRoot, name: cacheName)
            setSnapshot(next); revisions = nextRevisions; lastSignature = readSignature; isStale = false
            if changedSource { sourceNotice = "来源已更新；微信定位别名按来源分别保存，请重新核对名单。" }
            status = Self.syncedStatus(next)
            if !ifModifiedOnly || contentChanged { rosterEpoch += 1 }
        } catch {
            // 与 ensureHistory 失败路径对齐：盖戳后落盘失败的拍要允许下一拍重读，
            // 否则 lastSignature 停在最新指纹上，3 秒自动同步被一次瞬时 IO 失败永久楔死
            lastSignature = nil
            isStale = true
            status = "同步失败，名单已过期：\(error.localizedDescription)"
            if !ifModifiedOnly { rosterEpoch += 1 }
        }
    }
    static func acceptsWakeURL(_ url: URL) -> Bool {
        // Exact literal only: rejects paths, parameters, credentials, fragments and encoded variants.
        url.absoluteString == "qqdispatch://relationship-maintenance"
    }
    func open(contactID: String, expectedSourceID: String, queueBusy: Bool, navigator: RelationshipChatNavigator) async throws -> String {
        guard !queueBusy, !isOpening else { throw RelationshipInboxError("请先暂停队列，并等待当前操作结束，再打开微信聊天") }
        refresh()
        guard !isStale, let snapshot, snapshot.sourceInstanceId == expectedSourceID,
              let contact = contacts.first(where: { $0.contactId == contactID }) else { throw RelationshipInboxError("同步名单已过期或联系人已撤销，请刷新后重新选择") }
        isOpening = true; openingContactID = contactID
        defer { isOpening = false; openingContactID = nil }
        let savedAlias = alias(for: contactID)
        return try await navigator.openRelationshipChat(savedAlias.isEmpty ? contact.name : savedAlias)
    }
}
