import Foundation
import Darwin

@MainActor
final class FakeRelationshipNavigator: RelationshipChatNavigator {
    var opened: [String] = []
    var blocked = false
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        opened.append(fullDisplayName)
        while blocked { await Task.yield() }
        return "fake opened: \(fullDisplayName)"
    }
}

@main
@MainActor
struct RelationshipInboxTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        guard condition else { print("FAIL \(label)"); exit(1) }
        checks += 1; print("PASS \(label)")
    }
    static func rejected(_ label: String, _ action: () throws -> Void) {
        do { try action(); check(false, label) } catch { check(true, label) }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func contact(_ id: String = "contact-1", name: String = "马广平（政治老师）") -> [String: Any] {
        ["contactId": id, "name": name, "userNote": "政治老师\n备注\t保留", "tags": [["id": "teacher", "name": "老师"]], "cadenceMode": "festival", "message": "马老师中秋节快乐！\n祝您安康。", "groupName": "老师", "festival": "中秋节"]
    }
    static func wire(_ revision: Int = 1, source: String = "source-a", contacts: [[String: Any]]? = nil) -> [String: Any] {
        ["schemaVersion": 1, "sourceApp": "relationship-echo", "sourceInstanceId": source, "revision": revision, "updatedAt": "2026-09-26T05:00:00.000Z", "mode": "manual-chat-only", "contacts": contacts ?? [contact(), contact("contact-2", name: "马广平（政治老师）")]]
    }
    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func revisionRecoveryTests(in parent: URL) async throws {
        let fm = FileManager.default
        let cacheName = "relationship-inbox-cache-v1.json"
        let checkpointName = "relationship-inbox-revisions-v1.json"
        let markerName = "relationship-inbox-history-established-v1"
        let aliasName = "relationship-inbox-aliases-v1.json"
        typealias Case = (root: URL, bridge: URL, env: [String: String])
        func setup(_ name: String) throws -> Case {
            let folder = parent.appendingPathComponent(name)
            let root = folder.appendingPathComponent("qq-data"), bridge = folder.appendingPathComponent("bridge")
            for dir in [root, bridge] { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            return (root, bridge, ["QQ_DISPATCH_DATA_DIR": root.path, "RELATIONSHIP_ECHO_BRIDGE_DIR": bridge.path])
        }
        func publish(_ sample: Case, _ object: [String: Any]) throws {
            try RelationshipInboxFiles.write(data(object), directory: sample.bridge, name: RelationshipBridgeLocation.filename)
        }
        func model(_ sample: Case) -> RelationshipInbox { RelationshipInbox(appRoot: sample.root, environment: sample.env) }
        func blockedOpen(_ inbox: RelationshipInbox, _ label: String) async {
            let fake = FakeRelationshipNavigator()
            do { _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-a", queueBusy: false, navigator: fake) }
            catch { /* Required fail-closed result. */ }
            check(fake.opened.isEmpty, label)
        }
        for damage in ["malformed", "missing", "lost-revisions"] {
            let sample = try setup("restart-cache-\(damage)")
            try publish(sample, wire(10))
            let initial = model(sample); initial.refresh()
            check(!initial.isStale && initial.snapshot?.revision == 10, "\(damage): accept revision 10 first")
            try initial.saveAlias("稳定定位别名", contactID: "contact-1")
            let cache = sample.root.appendingPathComponent(cacheName)
            if damage == "malformed" { try Data("{bad".utf8).write(to: cache, options: .atomic) }
            else if damage == "missing" { try fm.removeItem(at: cache) }
            else {
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
                json["revisions"] = [String: Any]()
                try data(json).write(to: cache, options: .atomic)
            }
            try publish(sample, wire(9))
            let restarted = model(sample); restarted.refresh()
            check(restarted.isStale && restarted.snapshot?.revision != 9, "\(damage): restart rejects revision 9")
            await blockedOpen(restarted, "\(damage): rollback never reaches navigator")
            try publish(sample, wire(10)); restarted.refresh()
            check(!restarted.isStale && restarted.snapshot?.revision == 10 && restarted.alias(for: "contact-1") == "稳定定位别名", "\(damage): valid checkpoint recovers content and alias without reconfiguration")
        }
        for damage in ["malformed", "missing", "empty-history", "checkpoint-and-marker-missing"] {
            let sample = try setup("restart-checkpoint-\(damage)")
            try publish(sample, wire(10))
            let initial = model(sample); initial.refresh()
            try initial.saveAlias("保留别名", contactID: "contact-1")
            let cp = sample.root.appendingPathComponent(checkpointName)
            let saved = try Data(contentsOf: cp)
            if damage == "malformed" { try Data("{bad".utf8).write(to: cp, options: .atomic) }
            else if damage == "empty-history" {
                var json = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
                json["revisions"] = [String: Any]()
                try data(json).write(to: cp, options: .atomic)
            } else {
                try fm.removeItem(at: cp)
                if damage == "checkpoint-and-marker-missing" { try fm.removeItem(at: sample.root.appendingPathComponent(markerName)) }
            }
            try publish(sample, wire(11))
            let restarted = model(sample); restarted.refresh()
            check(restarted.isStale && restarted.snapshot?.revision == 10, "checkpoint \(damage): does not establish new trust even from newer bridge")
            await blockedOpen(restarted, "checkpoint \(damage): navigation blocked")
            try RelationshipInboxFiles.write(saved, directory: sample.root, name: checkpointName)
            restarted.refresh()
            check(!restarted.isStale && restarted.snapshot?.revision == 11 && restarted.alias(for: "contact-1") == "保留别名", "checkpoint \(damage): restoring proven history recovers without resetting aliases")
        }
        // W-V-02: an old, checksum-valid checkpoint must not forget another source evidenced by aliases.
        let forgottenSource = try setup("checkpoint-rollback-forgets-other-source")
        try publish(forgottenSource, wire(10))
        let established = model(forgottenSource); established.refresh()
        let oldAOnlyCheckpoint = try Data(contentsOf: forgottenSource.root.appendingPathComponent(checkpointName))
        try publish(forgottenSource, wire(25, source: "source-b")); established.refresh()
        try established.saveAlias("来源B高版本别名", contactID: "contact-1")
        try publish(forgottenSource, wire(10)); established.refresh()
        let completeCheckpoint = try Data(contentsOf: forgottenSource.root.appendingPathComponent(checkpointName))
        let aliasesBeforeRollback = try Data(contentsOf: forgottenSource.root.appendingPathComponent(aliasName))
        try RelationshipInboxFiles.write(oldAOnlyCheckpoint, directory: forgottenSource.root, name: checkpointName)
        try publish(forgottenSource, wire(24, source: "source-b"))
        let forgotRestart = model(forgottenSource); forgotRestart.refresh()
        check(forgotRestart.isStale && forgotRestart.snapshot?.sourceInstanceId == "source-a" && forgotRestart.snapshot?.revision == 10, "W-V-02: valid old A10 checkpoint cannot forget B25 evidenced by B alias")
        let forgotFake = FakeRelationshipNavigator()
        do { _ = try await forgotRestart.open(contactID: "contact-1", expectedSourceID: "source-b", queueBusy: false, navigator: forgotFake) }
        catch { /* Incomplete checkpoint must keep navigation closed. */ }
        check(forgotFake.opened.isEmpty, "W-V-02: B24 never reaches fake navigator")
        check(try Data(contentsOf: forgottenSource.root.appendingPathComponent(aliasName)) == aliasesBeforeRollback, "W-V-02: rejecting incomplete checkpoint preserves alias file bytes")
        try RelationshipInboxFiles.write(completeCheckpoint, directory: forgottenSource.root, name: checkpointName)
        try publish(forgottenSource, wire(25, source: "source-b")); forgotRestart.refresh()
        check(!forgotRestart.isStale && forgotRestart.snapshot?.revision == 25 && forgotRestart.alias(for: "contact-1") == "来源B高版本别名", "W-V-02: restoring complete checkpoint recovers B25 and alias")
        _ = try await forgotRestart.open(contactID: "contact-1", expectedSourceID: "source-b", queueBusy: false, navigator: forgotFake)
        check(forgotFake.opened == ["来源B高版本别名"], "W-V-02: recovered complete history permits one explicit navigation")
        let first = try setup("first-use")
        let fresh = model(first)
        check(try fm.contentsOfDirectory(atPath: first.root.path).isEmpty, "first-use init does not invent history")
        try publish(first, wire(1)); fresh.refresh()
        check(!fresh.isStale && fresh.snapshot?.revision == 1, "true first-use accepts valid snapshot")
        let restartedFirst = model(first); restartedFirst.refresh()
        check(!restartedFirst.isStale && restartedFirst.snapshot?.revision == 1, "first-use persists across restart")
        for name in [checkpointName, markerName, cacheName] {
            check((try fm.attributesOfItem(atPath: first.root.appendingPathComponent(name).path)[.posixPermissions] as? Int) == 0o600, "\(name) is private 0600")
        }

        let writeFail = try setup("checkpoint-write-failure")
        try publish(writeFail, wire(10))
        let beforeFailure = model(writeFail); beforeFailure.refresh()
        let checkpointBytes = try Data(contentsOf: writeFail.root.appendingPathComponent(checkpointName))
        try publish(writeFail, wire(11))
        check(chmod(writeFail.root.path, 0o500) == 0, "make isolated app root read-only for real write failure")
        beforeFailure.refresh()
        let failRestart = model(writeFail); failRestart.refresh()
        let staleWhileReadOnly = beforeFailure.isStale && failRestart.isStale
        check(chmod(writeFail.root.path, 0o700) == 0, "restore isolated root writability")
        check(staleWhileReadOnly && beforeFailure.snapshot?.revision == 10, "checkpoint write failure never exposes revision 11, including restart")
        check(try Data(contentsOf: writeFail.root.appendingPathComponent(checkpointName)) == checkpointBytes, "failed checkpoint write retains old high-water record")
        try publish(writeFail, wire(9))
        let afterFailure = model(writeFail); afterFailure.refresh()
        check(afterFailure.isStale, "write failure and restart do not lose revision 10 floor")
        await blockedOpen(afterFailure, "write failure rollback cannot navigate")
        try publish(writeFail, wire(11)); afterFailure.refresh()
        check(!afterFailure.isStale && afterFailure.snapshot?.revision == 11, "write failure retries safely once storage works")

        let firstWriteFail = try setup("first-checkpoint-write-failure")
        try publish(firstWriteFail, wire(1))
        let firstAttempt = model(firstWriteFail)
        check(chmod(firstWriteFail.root.path, 0o500) == 0, "make first-use isolated root read-only")
        firstAttempt.refresh()
        let firstAttemptStale = firstAttempt.isStale && firstAttempt.snapshot == nil
        check(chmod(firstWriteFail.root.path, 0o700) == 0, "restore first-use isolated root")
        check(firstAttemptStale, "first-use failed write cannot authorize navigation")
        let firstRetry = model(firstWriteFail); firstRetry.refresh()
        check(!firstRetry.isStale && firstRetry.snapshot?.revision == 1, "uncommitted true first use can retry normally")

        for failedLeaf in [cacheName, markerName] {
            let sample = try setup("late-write-failure-\(failedLeaf)")
            try publish(sample, wire(10))
            let initial = model(sample); initial.refresh()
            try initial.saveAlias("别名保留", contactID: "contact-1")
            let blockedLeaf = sample.root.appendingPathComponent(failedLeaf)
            try fm.removeItem(at: blockedLeaf)
            try fm.createDirectory(at: blockedLeaf, withIntermediateDirectories: false)
            try publish(sample, wire(11)); initial.refresh()
            check(initial.isStale && initial.snapshot?.revision == 10, "\(failedLeaf): later write failure keeps previous displayed snapshot stale")
            let checkpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: sample.root.appendingPathComponent(checkpointName))) as! [String: Any]
            let history = checkpoint["revisions"] as! [String: [String: Any]]
            check((history["source-a"]?["number"] as? Int) == 11, "\(failedLeaf): high-water mark committed before later write failure")
            try publish(sample, wire(10))
            let restarted = model(sample); restarted.refresh()
            check(restarted.isStale, "\(failedLeaf): restart retains new floor despite content write failure")
            await blockedOpen(restarted, "\(failedLeaf): old revision cannot navigate after partial commit")
            try fm.removeItem(at: blockedLeaf)
            try publish(sample, wire(11)); restarted.refresh()
            check(!restarted.isStale && restarted.alias(for: "contact-1") == "别名保留", "\(failedLeaf): storage recovery succeeds without discarding alias")
        }

        func legacyCache(_ sample: Case, history: [String: Any]?) throws {
            var envelope: [String: Any] = ["snapshot": wire(10)]
            if let history { envelope["revisions"] = history }
            try RelationshipInboxFiles.write(data(envelope), directory: sample.root, name: cacheName)
            try RelationshipInboxFiles.write(data(["8:source-acontact-1": "旧定位别名"]), directory: sample.root, name: aliasName)
        }
        let ten = try RelationshipSnapshot.decode(data(wire(10)))
        let other = try RelationshipSnapshot.decode(data(wire(15, source: "source-b")))
        let validLegacy: [String: Any] = ["source-a": ["number": 10, "digest": ten.digest], "source-b": ["number": 15, "digest": other.digest]]
        let legacy = try setup("legacy-complete")
        try legacyCache(legacy, history: validLegacy)
        let originalAliases = try Data(contentsOf: legacy.root.appendingPathComponent(aliasName))
        try publish(legacy, wire(10))
        let migrating = model(legacy); migrating.refresh()
        check(!migrating.isStale && migrating.alias(for: "contact-1") == "旧定位别名", "complete legacy cache migrates automatically with alias")
        check(try Data(contentsOf: legacy.root.appendingPathComponent(aliasName)) == originalAliases, "legacy migration does not rewrite aliases")
        try publish(legacy, wire(14, source: "source-b"))
        let migratedRestart = model(legacy); migratedRestart.refresh()
        check(migratedRestart.isStale && migratedRestart.snapshot?.sourceInstanceId == "source-a", "legacy migration preserves all sources, not just current snapshot")
        let partial = try setup("legacy-history-missing-alias-source")
        try legacyCache(partial, history: ["source-a": validLegacy["source-a"]!])
        try RelationshipInboxFiles.write(data(["8:source-bcontact-1": "另一个来源的旧别名"]), directory: partial.root, name: aliasName)
        try publish(partial, wire(1, source: "source-b"))
        let partialModel = model(partial); partialModel.refresh()
        check(partialModel.isStale && partialModel.snapshot?.sourceInstanceId == "source-a", "legacy aliases expose missing historical source and block incomplete migration")
        for missing in [true, false] {
            let sample = try setup(missing ? "legacy-history-missing" : "legacy-history-empty")
            try legacyCache(sample, history: missing ? nil : [:])
            try publish(sample, wire(9))
            let broken = model(sample); broken.refresh()
            check(broken.isStale && broken.snapshot?.revision == 10, "incomplete legacy history preserves snapshot floor: missing=\(missing)")
            await blockedOpen(broken, "incomplete legacy history stops navigation: missing=\(missing)")
            try publish(sample, wire(11)); broken.refresh()
            check(broken.isStale && broken.snapshot?.revision == 10, "incomplete legacy history cannot silently bootstrap from newer file: missing=\(missing)")
        }
        let orphan = try setup("orphan-alias-no-history")
        try RelationshipInboxFiles.write(data(["8:source-acontact-1": "现有别名"]), directory: orphan.root, name: aliasName)
        try publish(orphan, wire(1))
        let orphanModel = model(orphan); orphanModel.refresh()
        check(orphanModel.isStale && orphanModel.snapshot == nil, "orphan alias proves previous use and cannot be treated as first use")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let resolvedTemp = realpath(NSTemporaryDirectory(), nil)!
        let temp = URL(fileURLWithPath: String(cString: resolvedTemp)).appendingPathComponent("qq-manual-inbox-\(UUID().uuidString)")
        free(resolvedTemp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let root = temp.appendingPathComponent("app")
        let bridge = temp.appendingPathComponent("bridge")
        for url in [root, bridge] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let file = bridge.appendingPathComponent(RelationshipBridgeLocation.filename)
        func publish(_ object: [String: Any]) throws {
            try RelationshipInboxFiles.write(data(object), directory: bridge, name: RelationshipBridgeLocation.filename)
        }
        let env = ["RELATIONSHIP_ECHO_BRIDGE_DIR": bridge.path, "QQ_DISPATCH_DATA_DIR": root.path]
        setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)
        setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)

        check(try RelationshipSnapshot.decode(data(wire())).contacts.count == 2, "full wire decode / duplicate name distinct ID")
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("unknown schema", { $0["schemaVersion"] = 2 }),
            ("schema bool", { $0["schemaVersion"] = true }),
            ("wrong source", { $0["sourceApp"] = "other" }),
            ("wrong mode", { $0["mode"] = "automatic" }),
            ("zero revision", { $0["revision"] = 0 }),
            ("unsafe revision", { $0["revision"] = 9_007_199_254_740_992 as Int64 }),
            ("fractional revision", { $0["revision"] = 1.5 }),
            ("string revision", { $0["revision"] = "1" }),
            ("non-UTC time", { $0["updatedAt"] = "2026-09-26T05:00:00+08:00" }),
            ("bad date", { $0["updatedAt"] = "today" }),
            ("empty source", { $0["sourceInstanceId"] = "" }),
            ("source control", { $0["sourceInstanceId"] = "x\n" }),
            ("contacts wrong type", { $0["contacts"] = "people" }),
            ("over 10000 contacts", { $0["contacts"] = (0...10000).map { contact("p-\($0)") } }),
            ("duplicate contact IDs", { $0["contacts"] = [contact(), contact()] })
        ]
        for (label, mutation) in mutations {
            var object = wire(); mutation(&object)
            rejected(label) { _ = try RelationshipSnapshot.decode(data(object)) }
        }
        let contactMutations: [(String, (inout [String: Any]) -> Void)] = [
            ("missing required field", { $0.removeValue(forKey: "message") }),
            ("null note", { $0["userNote"] = NSNull() }),
            ("empty name", { $0["name"] = "" }),
            ("long name", { $0["name"] = String(repeating: "x", count: 129) }),
            ("long note", { $0["userNote"] = String(repeating: "x", count: 4001) }),
            ("long message", { $0["message"] = String(repeating: "x", count: 10001) }),
            ("name control", { $0["name"] = "Name\n" }),
            ("message control", { $0["message"] = "x\u{7}" }),
            ("invalid cadence", { $0["cadenceMode"] = "monthly" }),
            ("duplicate tags", { $0["tags"] = [["id": "t", "name": "A"], ["id": "t", "name": "B"]] }),
            ("too many tags", { $0["tags"] = (0...100).map { ["id": "t-\($0)", "name": "tag"] } })
        ]
        for (label, mutation) in contactMutations {
            var c = contact(); mutation(&c)
            rejected(label) { _ = try RelationshipSnapshot.decode(data(wire(contacts: [c]))) }
        }
        try publish(wire())
        let inbox = RelationshipInbox(appRoot: root, environment: env)
        inbox.refresh()
        check(!inbox.isStale && inbox.contacts.count == 2, "independent snapshot load")
        let first = inbox.snapshot
        inbox.refresh()
        check(inbox.snapshot == first && inbox.contacts.count == 2, "same revision idempotent")
        check(inbox.filtered(search: "政治", tagID: "teacher").count == 2, "name note and tag filtering")
        check(inbox.filtered(search: "", tagID: "missing").isEmpty && inbox.contacts.count == 2, "filter never changes list")
        try inbox.saveAlias("马老师微信备注", contactID: "contact-1")
        check(inbox.alias(for: "contact-1") == "马老师微信备注" && inbox.alias(for: "contact-2").isEmpty, "alias follows stable ID not duplicate name")
        var renamed = contact(); renamed["name"] = "马广平老师新备注"; renamed["tags"] = [["id": "friend", "name": "朋友"]]
        try publish(wire(2, contacts: [renamed]))
        inbox.refresh()
        check(inbox.contacts.count == 1 && inbox.contacts[0].name == "马广平老师新备注", "rename and revoked contact replace full snapshot")
        check(inbox.alias(for: "contact-1") == "马老师微信备注" && inbox.tags.map(\.id) == ["friend"], "rename preserves alias and refreshes tags")
        let fake = FakeRelationshipNavigator()
        _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-a", queueBusy: false, navigator: fake)
        check(fake.opened == ["马老师微信备注"], "one click one navigator call using explicit alias")
        try inbox.saveAlias("", contactID: "contact-1")
        _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-a", queueBusy: false, navigator: fake)
        check(fake.opened.last == "马广平老师新备注", "full display name not greeting used for search")
        try inbox.saveAlias("保留别名", contactID: "contact-1")
        let restarted = RelationshipInbox(appRoot: root, environment: env)
        check(restarted.isStale && restarted.contacts.count == 1 && restarted.alias(for: "contact-1") == "保留别名", "restart cache kept stale until verification / alias persists")
        try publish(wire(1))
        restarted.refresh()
        check(restarted.isStale && restarted.snapshot?.revision == 2, "persisted revision rejects rollback")
        try publish(wire(2))
        inbox.refresh()
        check(inbox.isStale && inbox.contacts.count == 1, "same revision different content refused")
        try publish(wire(3, contacts: []))
        inbox.refresh()
        check(!inbox.isStale && inbox.contacts.isEmpty, "empty snapshot legally clears only source list")
        try publish(wire(4, contacts: [renamed]))
        inbox.refresh()
        try Data("{bad".utf8).write(to: file, options: .atomic)
        inbox.refresh()
        check(inbox.isStale && inbox.contacts.count == 1, "corrupt snapshot preserves valid list and marks stale")
        do { _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-a", queueBusy: false, navigator: fake); check(false, "stale execution blocked") }
        catch { check(fake.opened.count == 2, "stale execution blocked") }
        try publish(wire(1, source: "source-b"))
        inbox.refresh()
        check(!inbox.isStale && inbox.sourceNotice != nil && inbox.alias(for: "contact-1").isEmpty, "new source visible and does not reuse aliases")
        do { _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-a", queueBusy: false, navigator: fake); check(false, "source changed click refused") }
        catch { check(fake.opened.count == 2, "source changed click refused") }
        do { _ = try await inbox.open(contactID: "contact-1", expectedSourceID: "source-b", queueBusy: true, navigator: fake); check(false, "busy queue refused") }
        catch { check(fake.opened.count == 2, "busy queue refused") }
        try publish(wire(3))
        inbox.refresh()
        check(inbox.isStale && inbox.snapshot?.sourceInstanceId == "source-b", "older revision of previous source still refused")

        check(try RelationshipBridgeLocation.directory(appRoot: root, environment: [:]).path == root.appendingPathComponent("RelationshipEchoBridge").path, "isolated root never falls back to formal bridge")
        rejected("relative override refused") { _ = try RelationshipBridgeLocation.directory(appRoot: root, environment: ["RELATIONSHIP_ECHO_BRIDGE_DIR": "relative"]) }
        rejected("traversal override refused") { _ = try RelationshipBridgeLocation.directory(appRoot: root, environment: ["RELATIONSHIP_ECHO_BRIDGE_DIR": "/tmp/../private"]) }
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("relationship-inbox-cache-v1.json"))
        inbox.refresh()
        check(inbox.isStale && inbox.snapshot?.sourceInstanceId == "source-b", "snapshot symlink refused with cache retained")
        let linkDir = temp.appendingPathComponent("bridge-link")
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: bridge)
        rejected("directory symlink refused") { _ = try RelationshipInboxFiles.read(directory: linkDir, name: RelationshipBridgeLocation.filename, limit: 100) }
        try fm.removeItem(at: file)
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        inbox.refresh()
        check(inbox.isStale, "non-regular directory snapshot refused")
        try fm.removeItem(at: file)
        check(mkfifo(file.path, 0o600) == 0, "prepare FIFO")
        rejected("FIFO rejected without blocking") { _ = try RelationshipInboxFiles.read(directory: bridge, name: RelationshipBridgeLocation.filename, limit: 100) }
        try fm.removeItem(at: file)
        fm.createFile(atPath: file.path, contents: nil)
        let oversized = try FileHandle(forWritingTo: file)
        try oversized.truncate(atOffset: UInt64(RelationshipSnapshot.maxBytes + 1)); try oversized.close()
        inbox.refresh()
        check(inbox.isStale, "oversize rejected before JSON allocation")

        try publish(wire(5))
        let storeFake = FakeRelationshipNavigator()
        let store = try Store(root: root, relationshipNavigator: storeFake)
        store.guestMode = true
        let r = Recipient(name: "原QQ群", note: "旧名单保留")
        let plan = Plan(name: "旧计划", text: "原内容", assetIDs: [], recipientIDs: [r.id], starts: Date().addingTimeInterval(3600), days: 1, times: [], intervalMinutes: 30, mode: "automatic", recipientGaps: nil)
        let job = Delivery(planID: plan.id, planName: plan.name, recipient: r.name, text: plan.text, assets: [], scheduled: plan.starts, mode: "automatic")
        store.recipients = [r]; store.plans = [plan]; store.deliveries = [job]
        try store.persist()
        let before = try encoded(store.archive)
        check(store.handleRelationshipURL(URL(string: "qqdispatch://relationship-maintenance")!), "exact URL accepted")
        check(store.route == "recipients" && store.orderChannel == SendChannel.wechat && !store.running && !store.busy && storeFake.opened.isEmpty, "URL only navigates / no chat open or queue")
        store.guestMode = false
        store.enterGuestMode()
        check(store.guestMode && store.route == "recipients" && store.orderChannel == SendChannel.wechat, "cold wake route survives guest entry")
        for bad in ["qqdispatch://relationship-maintenance/", "qqdispatch://relationship-maintenance?name=x", "qqdispatch://relationship-maintenance#x", "qqdispatch://x", "https://relationship-maintenance", "qqdispatch://user@relationship-maintenance", "qqdispatch://relationship-maintenance:80", "qqdispatch://relationship-maintenance/path"] {
            check(!store.handleRelationshipURL(URL(string: bad)!), "reject URL \(bad)")
        }
        store.relationshipInbox.refresh(ifModifiedOnly: true)
        check(storeFake.opened.isEmpty && !store.running, "refresh does not navigate or start queue")
        store.running = true
        store.openRelationshipContact("contact-1", sourceID: "source-a")
        check(storeFake.opened.isEmpty && store.running, "running queue blocks manual click without silently pausing")
        store.running = false
        store.busy = true
        store.openRelationshipContact("contact-1", sourceID: "source-a")
        check(storeFake.opened.isEmpty, "busy operation blocks manual click")
        store.busy = false
        storeFake.blocked = true
        store.openRelationshipContact("contact-1", sourceID: "source-a")
        store.openRelationshipContact("contact-1", sourceID: "source-a")
        for _ in 0..<100 where storeFake.opened.isEmpty { await Task.yield() }
        check(storeFake.opened.count == 1 && store.busy && !store.running, "rapid repeated click creates exactly one open / queue remains stopped")
        store.start()
        check(!store.running, "queue cannot start during manual navigation")
        storeFake.blocked = false
        for _ in 0..<1000 where store.busy { await Task.yield() }
        check(!store.busy && !store.running, "navigation completion does not resume queue")
        check(try encoded(store.archive) == before, "source actions preserve old recipients plans deliveries and settings exactly")
        check(try encoded(store.db.load("recipients", as: Recipient.self)) == encoded([r]), "persisted old recipient unchanged")
        check(try encoded(store.db.load("plans", as: Plan.self)) == encoded([plan]), "persisted old plan unchanged")
        check(try encoded(store.db.load("deliveries", as: Delivery.self)) == encoded([job]), "persisted old delivery unchanged")
        let cachePerm = try fm.attributesOfItem(atPath: root.appendingPathComponent("relationship-inbox-cache-v1.json").path)[.posixPermissions] as? Int
        check(cachePerm == 0o600, "local cache permissions 0600")
        try await revisionRecoveryTests(in: temp)
        print("PASS \(checks) manual inbox checks; isolated roots cleaned; no WeChat driver invoked")
    }
}
