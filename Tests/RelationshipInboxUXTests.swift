import Foundation
import Darwin

// UX-20260928-C independent checks: humanized sync time, list findability, alias errors,
// and the manual-open contract. Isolated roots only; the navigator is a fake and no
// chat driver is ever invoked. This file does not replace Tests/RelationshipInboxTests.swift.
@MainActor
final class UXFakeNavigator: RelationshipChatNavigator {
    var opened: [String] = []
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        opened.append(fullDisplayName)
        return "UX fake opened: \(fullDisplayName)"
    }
}

@main
@MainActor
struct RelationshipInboxUXTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL \(label)"); exit(1) }
        checks += 1; print("PASS \(label)")
    }
    static func contact(_ id: String, name: String, note: String = "", tags: [[String: String]] = [], message: String = "", festival: String = "") -> [String: Any] {
        ["contactId": id, "name": name, "userNote": note, "tags": tags, "cadenceMode": "periodic", "message": message, "groupName": "", "festival": festival]
    }
    static func wire(_ revision: Int, source: String = "ux-source", contacts: [[String: Any]], updatedAt: String = "2026-09-28T12:00:00.000Z") -> [String: Any] {
        ["schemaVersion": 1, "sourceApp": "relationship-echo", "sourceInstanceId": source, "revision": revision, "updatedAt": updatedAt, "mode": "manual-chat-only", "contacts": contacts]
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let temp = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-ux-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appendingPathComponent("app"), bridge = temp.appendingPathComponent("bridge")
        for url in [root, bridge] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let env = ["QQ_DISPATCH_DATA_DIR": root.path, "RELATIONSHIP_ECHO_BRIDGE_DIR": bridge.path]
        func publish(_ object: [String: Any]) throws {
            try RelationshipInboxFiles.write(data(object), directory: bridge, name: RelationshipBridgeLocation.filename)
        }

        // MARK: - 1. 人性化同步时间（辨认新旧）

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func absolute(_ iso: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: RelationshipInbox.parseSyncDate(iso)!)
        }
        let moment = RelationshipInbox.parseSyncDate("2026-09-28T12:00:00.000Z")!
        func rel(_ offset: TimeInterval, _ iso: String) -> String { RelationshipInbox.humanizedSyncTime(iso, now: moment.addingTimeInterval(offset), calendar: calendar) }
        check(rel(0, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（刚刚）", "humanized time: just now")
        check(rel(59, "2026-09-28T12:00:00.000Z").hasSuffix("（刚刚）"), "humanized time: under a minute stays 刚刚")
        check(rel(60, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（1 分钟前）", "humanized time: one minute")
        check(rel(3 * 3600 + 120, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（3 小时前）", "humanized time: hours")
        check(rel(2 * 86400, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（2 天前）", "humanized time: days")
        check(!rel(9 * 86400, "2026-09-28T12:00:00.000Z").contains("（"), "humanized time: beyond a week shows absolute only")
        check(rel(-30, "2026-09-28T12:00:00.000Z").hasSuffix("（刚刚）"), "humanized time: a few seconds of clock skew stays 刚刚")
        check(rel(-90, "2026-09-28T12:00:00.000Z").hasSuffix("（刚刚）"), "humanized time: ninety seconds ahead still counts as just synced")
        check(rel(-3600, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（时间超前）", "humanized time: one hour ahead is not 刚刚")
        check(!rel(-3600, "2026-09-28T12:00:00.000Z").contains("刚刚"), "humanized time: hour-ahead copy does not say 刚刚")
        check(rel(-86400, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（时间超前）", "humanized time: a day ahead shows the absolute time and the anomaly")
        check(rel(-40 * 86400, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（时间超前）", "humanized time: a month ahead is not described as just synced")
        // The pair with the -90 case above is what pins the tolerance: -91 must already be refused.
        check(rel(-91, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（时间超前）", "humanized time: ninety-one seconds ahead is past the tolerance")
        check(rel(-31_536_000, "2026-09-28T12:00:00.000Z") == "\(absolute("2026-09-28T12:00:00.000Z"))（时间超前）", "humanized time: a year ahead shows the absolute local time")
        check(!rel(-31_536_000, "2026-09-28T12:00:00.000Z").contains("刚刚"), "humanized time: the reported repro (one year ahead) never says 刚刚")
        // 放行判据与显示措辞必须同源：任何一侧单独挪阈值，这里就会断。
        func issue(_ offset: TimeInterval, _ iso: String) -> RelationshipInbox.SyncTimeIssue? {
            RelationshipInbox.syncTimeIssue(iso, now: moment.addingTimeInterval(offset))
        }
        let isoFixed = "2026-09-28T12:00:00.000Z"
        check(issue(-90, isoFixed) == nil, "accept: exactly ninety seconds ahead stays inside the tolerance")
        check(issue(-90.5, isoFixed) == .abnormallyFuture, "accept: half a second past the tolerance is refused")
        check(issue(-31_536_000, isoFixed) == .abnormallyFuture, "accept: a year ahead is refused outright")
        check(issue(604_799, isoFixed) == nil, "accept: one second short of a week is a plain sync")
        check(issue(604_800, isoFixed) == .aged, "accept: exactly a week counts as aged")
        check(issue(31_536_000, isoFixed) == .aged, "accept: a year old is aged but not invalid")
        for offset: TimeInterval in [-3600, -91, -90.5, -90, -30, 0, 3600, 604_799, 604_800, 31_536_000] {
            let shown = rel(offset, isoFixed).contains("（时间超前）")
            check(shown == (issue(offset, isoFixed) == .abnormallyFuture), "display and acceptance agree on one threshold at \(offset)s")
        }
        check(RelationshipInbox.parseSyncDate("2026-09-28T12:00:00Z") != nil, "humanized time: non-fractional ISO parses")
        check(RelationshipInbox.humanizedSyncTime("not-a-date", now: moment, calendar: calendar) == "not-a-date", "humanized time: invalid input keeps raw text")
        // Offset ISO never reaches this helper: RelationshipSnapshot.validate() enforces the Z-form regex upstream.
        check(RelationshipInbox.humanizedSyncTime("", now: moment, calendar: calendar) == "", "humanized time: empty input keeps raw text")
        check(absolute("2026-09-28T12:00:00.000Z").hasPrefix("2026-09-28 20:"), "humanized time: renders in the injected calendar time zone")
        // The status line uses the machine calendar; derive the expectation through the same helper so the
        // assertion holds in any time zone. distantFuture is beyond the relative window → absolute only.
        let isoA = "2026-09-28T12:00:00.000Z", isoB = "2026-09-28T12:30:00Z"
        let expectedA = RelationshipInbox.humanizedSyncTime(isoA, now: .distantFuture, calendar: .current)
        let expectedB = RelationshipInbox.humanizedSyncTime(isoB, now: .distantFuture, calendar: .current)

        // MARK: - 2. 状态行不再展示原始 UTC ISO

        let roster: [[String: Any]] = [
            contact("c-alice", name: "陈静", note: "大学同学", tags: [["id": "friend", "name": "朋友"]]),
            contact("c-ma", name: "马广平（政治老师）", note: "高中政治老师", tags: [["id": "teacher", "name": "老师"]], message: "马老师中秋节快乐！", festival: "中秋节"),
            contact("c-li", name: "李文", note: "", tags: [["id": "teacher", "name": "老师"]]),
            contact("c-zhao", name: "赵一鸣", note: "书友会伙伴", tags: [["id": "book", "name": "书友"]], message: "赵一鸣，周末读书会见！")
        ]
        try publish(wire(7, contacts: roster))
        let inbox = RelationshipInbox(appRoot: root, environment: env)
        inbox.refresh()
        check(!inbox.isStale && inbox.contacts.count == 4, "roster loads")
        check(inbox.status.hasPrefix("已同步 4 人 · 版本 7 · 同步于 "), "status leads with count, revision and humanized sync time")
        check(inbox.rosterEpoch == 1, "first successful load marks the roster once")
        let epochAfterLoad = inbox.rosterEpoch
        inbox.refresh()
        check(inbox.rosterEpoch == epochAfterLoad + 1, "explicit refresh lets a saved-alias note clear")
        let stableEpoch = inbox.rosterEpoch
        inbox.refresh(ifModifiedOnly: true)
        check(inbox.rosterEpoch == stableEpoch, "unchanged periodic refresh does not clear an in-progress alias")
        check(AliasFeedback.afterFieldEdit(message: AliasFeedback.saved, field: "陈静", fieldWhenShown: "陈静") == AliasFeedback.saved, "saved note stays while the field still matches")
        check(AliasFeedback.afterFieldEdit(message: AliasFeedback.saved, field: "陈静2", fieldWhenShown: "陈静").isEmpty, "editing the name clears the saved note")
        check(AliasFeedback.afterFieldEdit(message: "该联系人已不在当前同步名单；请刷新后重新操作", field: "新名字", fieldWhenShown: "旧名字").isEmpty, "editing also clears a stale error")
        let kept = AliasFeedback.afterRosterChange(field: "陈静", fieldWhenShown: "陈静", saved: "陈静的微信名")
        check(kept.message.isEmpty && kept.field == "陈静的微信名", "roster refresh clears the note and reloads the saved name")
        let typing = AliasFeedback.afterRosterChange(field: "正在输入", fieldWhenShown: "陈静", saved: "陈静的微信名")
        check(typing.message.isEmpty && typing.field == "正在输入", "roster refresh does not wipe a name the user has started editing")
        check(!inbox.status.contains("T12:00:00"), "status no longer shows raw UTC ISO")
        check(inbox.status.contains(expectedA), "status sync time rendered in the machine calendar")
        try publish(wire(8, contacts: roster, updatedAt: "broken-time"))
        inbox.refresh()
        check(inbox.isStale, "broken time refuses sync")
        try publish(wire(9, contacts: roster, updatedAt: isoB))
        inbox.refresh()
        check(!inbox.isStale && inbox.status.contains(expectedB), "non-fractional wire time still humanizes")

        // MARK: - 3. 找人：空白容忍、别名可搜、姓名稳定排序

        check(inbox.contacts.map(\.contactId) == ["c-alice", "c-ma", "c-li", "c-zhao"], "contacts keeps wire order for identity checks")
        let scrambled = [roster[3], roster[0], roster[2], roster[1]]
        try publish(wire(10, contacts: scrambled))
        inbox.refresh()
        check(inbox.contacts.map(\.contactId) == ["c-zhao", "c-alice", "c-li", "c-ma"], "contacts still mirrors snapshot order")
        let namesByID = Dictionary(uniqueKeysWithValues: scrambled.map { ($0["contactId"] as! String, $0["name"] as! String) })
        let expected = ["c-zhao", "c-alice", "c-li", "c-ma"].sorted { a, b in
            let order = namesByID[a]!.localizedStandardCompare(namesByID[b]!)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        check(inbox.filtered(search: "", tagID: nil).map(\.contactId) == expected, "filtered lists in Finder-like name order (display only)")
        check(Set(inbox.filtered(search: "", tagID: nil).map(\.contactId)) == Set(inbox.contacts.map(\.contactId)), "sort keeps every contact")
        try inbox.saveAlias("老马", contactID: "c-ma")
        check(inbox.filtered(search: "老马", tagID: nil).map(\.contactId) == ["c-ma"], "saved alias is searchable")
        check(inbox.filtered(search: "  老马　", tagID: nil).map(\.contactId) == ["c-ma"], "half and full width stray spaces never blank the search")
        check(inbox.filtered(search: " 政治老师 ", tagID: nil).map(\.contactId) == ["c-ma"], "note search tolerates stray spaces")
        check(inbox.filtered(search: "老马", tagID: nil).count == 1, "alias search does not leak to other contacts")
        check(Set(inbox.filtered(search: "", tagID: "teacher").map(\.contactId)) == Set(["c-ma", "c-li"]), "tag filter unchanged by sort")
        check(inbox.filtered(search: "", tagID: nil).map(\.contactId) == inbox.filtered(search: "", tagID: nil).map(\.contactId), "repeat filtering is deterministic")
        // Same display name on two contacts: order must be decided by stable contactId, not by hash order.
        let twins: [[String: Any]] = [contact("t-b", name: "同名者"), contact("t-a", name: "同名者")]
        try publish(wire(11, contacts: twins))
        inbox.refresh()
        check(inbox.filtered(search: "", tagID: nil).map(\.contactId) == ["t-a", "t-b"], "identical names break the tie by stable ID")
        try publish(wire(12, contacts: roster))
        inbox.refresh()

        // MARK: - 4. 别名保存的错误语义

        do { _ = try inbox.saveAlias(String(repeating: "长", count: 129), contactID: "c-ma"); check(false, "over-limit alias refused") }
        catch { check("\(error)".contains("128"), "over-limit alias reports the real limit") }
        try publish(wire(13, contacts: roster.filter { $0["contactId"] as! String != "c-ma" }))
        inbox.refresh()
        check(!inbox.contacts.contains { $0.contactId == "c-ma" }, "roster refresh revokes c-ma")
        do { _ = try inbox.saveAlias("新别名", contactID: "c-ma"); check(false, "alias for revoked contact refused") }
        catch { check("\(error)".contains("已不在当前同步名单"), "revoked contact explains the real reason, not a format error") }
        try publish(wire(14, contacts: roster))
        inbox.refresh()
        try inbox.saveAlias("  保留别名  ", contactID: "c-ma")
        check(inbox.alias(for: "c-ma") == "保留别名", "alias trimming regression holds")
        try inbox.saveAlias("", contactID: "c-ma")
        check(inbox.alias(for: "c-ma").isEmpty, "empty alias clears (regression)")

        // MARK: - 5. 手动打开契约（fake navigator，从不调用真实驱动）

        let fake = UXFakeNavigator()
        try inbox.saveAlias("老马", contactID: "c-ma")
        _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake)
        check(fake.opened == ["老马"], "one click is exactly one navigator call with the saved alias")
        try inbox.saveAlias("", contactID: "c-ma")
        _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake)
        check(fake.opened.last == "马广平（政治老师）", "without alias the full display name is used, never a greeting")
        do { _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: true, navigator: fake); check(false, "busy queue must refuse") }
        catch { check(fake.opened.count == 2, "busy queue never reaches the navigator") }
        do { _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "other-source", queueBusy: false, navigator: fake); check(false, "source mismatch must refuse") }
        catch { check(fake.opened.count == 2, "source mismatch never reaches the navigator") }
        try Data("{bad".utf8).write(to: bridge.appendingPathComponent(RelationshipBridgeLocation.filename), options: .atomic)
        inbox.refresh()
        check(inbox.isStale, "corrupt bridge marks the list stale")
        do { _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake); check(false, "stale must refuse") }
        catch { check(fake.opened.count == 2, "stale list never reaches the navigator") }
        do { _ = try await inbox.open(contactID: "ghost", expectedSourceID: "ux-source", queueBusy: false, navigator: fake); check(false, "unknown contact must refuse") }
        catch { check(fake.opened.count == 2, "unknown contact never reaches the navigator") }
        try publish(wire(15, contacts: roster))
        inbox.refresh()
        check(!inbox.isStale, "valid sync recovers after corruption")
        _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake)
        check(fake.opened.count == 3, "recovery allows the next explicit click")

        // MARK: - 6. 异常未来快照整份拒收：保留旧名单，不动缓存与版本高水位

        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func isoRelative(_ seconds: TimeInterval) -> String { clock.string(from: Date().addingTimeInterval(-seconds)) }
        let aheadSixtyDays = isoRelative(-60 * 86400)
        try publish(wire(16, contacts: roster, updatedAt: aheadSixtyDays))
        inbox.refresh()
        check(inbox.isStale, "e2e: a two-month-ahead snapshot is never treated as fresh")
        check(inbox.status == RelationshipInbox.futureAnomalyStatus(aheadSixtyDays), "e2e: the status line is exactly the decided anomaly wording")
        check(inbox.status.contains("同步时间异常，请在关系回响重新同步"), "e2e: the anomaly tells the user what to do next")
        check(!inbox.status.contains("刚刚"), "e2e: an anomalous future sync never reads as 刚刚")
        check(inbox.contacts.count == 4 && inbox.snapshot?.revision == 15, "e2e: the previous valid roster stays on screen for viewing")
        let openedBeforeReject = fake.opened.count
        do { _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake); check(false, "an anomalous sync must refuse navigation") }
        catch { check(fake.opened.count == openedBeforeReject, "e2e: an anomalous sync never reaches the navigator") }
        let restarted = RelationshipInbox(appRoot: root, environment: env)
        check(restarted.snapshot?.revision == 15 && restarted.snapshot?.sourceInstanceId == "ux-source", "e2e: the rejected snapshot never overwrote the valid cache")
        // 被拒的快照不能抬高版本高水位：同一来源随后更低的版本号仍应能落地。
        try publish(wire(9, source: "ux-floor", contacts: roster, updatedAt: aheadSixtyDays))
        inbox.refresh()
        check(inbox.isStale, "e2e: the floor probe rejects its own future-dated sync")
        try publish(wire(7, source: "ux-floor", contacts: roster, updatedAt: isoRelative(60)))
        inbox.refresh()
        check(!inbox.isStale && inbox.snapshot?.revision == 7, "e2e: a rejected future sync left no floor, so revision 7 still lands")
        try publish(wire(17, contacts: roster, updatedAt: isoRelative(60)))
        inbox.refresh()
        check(!inbox.isStale && inbox.status.contains("已同步 4 人 · 版本 17"), "e2e: a corrected sync recovers on its own")
        let openedAfterRecovery = fake.opened.count
        _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake)
        check(fake.opened.count == openedAfterRecovery + 1, "e2e: recovery restores the manual locate entry")
        try publish(wire(20, contacts: roster, updatedAt: isoRelative(-85)))
        inbox.refresh()
        check(!inbox.isStale && inbox.status.contains("刚刚"), "e2e: eighty-five seconds of skew is still a just-synced roster")
        try publish(wire(21, contacts: roster, updatedAt: isoRelative(-95)))
        inbox.refresh()
        check(inbox.isStale && inbox.status.contains("同步时间异常"), "e2e: ninety-five seconds ahead is refused end to end")

        // MARK: - 7. 满一周：提示核对，但不擅自收回定位入口

        try publish(wire(22, contacts: roster, updatedAt: isoRelative(8 * 86400)))
        inbox.refresh()
        check(!inbox.isStale, "e2e: a legal eight-day-old roster is not disabled")
        check(inbox.status.contains("超过 7 天，请核对后重新同步"), "e2e: the aged roster is called out on the status line")
        check(inbox.status.contains("已同步 4 人"), "e2e: the aged warning is appended, not replacing the sync summary")
        let openedWhileAged = fake.opened.count
        _ = try await inbox.open(contactID: "c-ma", expectedSourceID: "ux-source", queueBusy: false, navigator: fake)
        check(fake.opened.count == openedWhileAged + 1, "e2e: an aged roster can still be located by hand")
        try publish(wire(23, contacts: roster, updatedAt: isoRelative(6 * 86400)))
        inbox.refresh()
        check(!inbox.status.contains("超过 7 天"), "e2e: six days old earns no warning")

        // MARK: - 8. 从没同步过 ≠ 同步坏了 ≠ 用户主动清空

        let rootB = temp.appendingPathComponent("app-first"), bridgeB = temp.appendingPathComponent("bridge-first")
        try fm.createDirectory(at: rootB, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let envB = ["QQ_DISPATCH_DATA_DIR": rootB.path, "RELATIONSHIP_ECHO_BRIDGE_DIR": bridgeB.path]
        func publishB(_ object: [String: Any]) throws {
            try RelationshipInboxFiles.write(try data(object), directory: bridgeB, name: RelationshipBridgeLocation.filename)
        }
        // 源端从没写过，连桥目录都不存在。
        let first = RelationshipInbox(appRoot: rootB, environment: envB)
        first.refresh()
        check(first.status == RelationshipInbox.firstSyncStatus, "e2e: a never-synced inbox leads with the first-sync guidance")
        check(!first.status.contains("同步失败") && !first.status.contains("已过期"), "e2e: first use is not reported as a failure")
        check(first.snapshot == nil, "e2e: first use keeps the view in its .neverSynced branch")
        try fm.createDirectory(at: bridgeB, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        first.refresh()
        check(first.status == RelationshipInbox.firstSyncStatus, "e2e: an empty bridge directory is still first use, not corruption")
        try Data("{bad".utf8).write(to: bridgeB.appendingPathComponent(RelationshipBridgeLocation.filename), options: .atomic)
        first.refresh()
        check(first.status.contains("同步失败，名单已过期"), "e2e: corruption on a never-synced root stays a real failure")
        try publishB(wire(1, source: "first-source", contacts: []))
        first.refresh()
        check(!first.isStale && first.snapshot != nil && first.contacts.isEmpty, "e2e: a legal empty roster clears the failure state")
        check(!first.status.contains("还没有同步过名单"), "e2e: an intentionally emptied roster is not first use")
        check(first.status.contains("已同步 0 人"), "e2e: the empty roster reports zero people rather than nothing synced")
        let rootC = temp.appendingPathComponent("app-link"), bridgeC = temp.appendingPathComponent("bridge-link")
        for url in [rootC, bridgeC] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let realFile = temp.appendingPathComponent("not-a-bridge.json")
        try data(wire(1, source: "link-source", contacts: roster)).write(to: realFile)
        try fm.createSymbolicLink(at: bridgeC.appendingPathComponent(RelationshipBridgeLocation.filename), withDestinationURL: realFile)
        let linked = RelationshipInbox(appRoot: rootC, environment: ["QQ_DISPATCH_DATA_DIR": rootC.path, "RELATIONSHIP_ECHO_BRIDGE_DIR": bridgeC.path])
        linked.refresh()
        check(linked.status.contains("同步失败，名单已过期") && !linked.status.contains("还没有同步过名单"), "e2e: a symlinked bridge file is a fault, never first-use guidance")
        check(linked.snapshot == nil, "e2e: the symlink target is never loaded")
        let misconfigured = RelationshipInbox(appRoot: rootC, environment: ["RELATIONSHIP_ECHO_BRIDGE_DIR": "relative/path"])
        misconfigured.refresh()
        check(misconfigured.status.contains("同步失败，名单已过期"), "e2e: a misconfigured bridge directory stays a failure")

        print("PASS \(checks) relationship inbox UX checks; isolated roots cleaned; fake navigator only, no chat driver invoked")
    }
}
