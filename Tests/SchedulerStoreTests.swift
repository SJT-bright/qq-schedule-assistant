import SwiftUI
import AppKit

@main @MainActor struct SchedulerStoreTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-scheduler-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)
        let now = Date()
        let recipient = Recipient(name: "隔离验收群")
        let plan = Plan(name: "隔离排期", text: "仅测试不发送", assetIDs: [], recipientIDs: [recipient.id], starts: now.addingTimeInterval(3600), days: 1, times: [], intervalMinutes: 30, mode: "draft")
        var sent = Delivery(planID: plan.id, planName: plan.name, recipient: recipient.name, text: plan.text, assets: [], scheduled: now.addingTimeInterval(-1200), mode: "draft")
        sent.status = "verified"; sent.submittedAt = now.addingTimeInterval(-1200)
        var queued = sent; queued.id = UUID().uuidString; queued.status = "queued"; queued.submittedAt = nil; queued.scheduled = now.addingTimeInterval(600)
        store.recipients = [recipient]; store.plans = [plan]; store.deliveries = [sent, queued]
        store.running = true; store.activePlanID = plan.id
        try store.persist()
        store.updatePlanInterval(plan.id, minutes: 25, lowerGlobal: true)
        precondition(store.error == nil && store.running && store.plans[0].intervalMinutes == 25 && store.settings.globalGapMinutes == 25)
        precondition(abs(store.earliestSendDate(store.deliveries[1]).timeIntervalSince(now) - 300) < 0.1)
        let persistedPlans = try store.db.load("plans", as: Plan.self)
        precondition(persistedPlans[0].intervalMinutes == 25)
        print("PASS running wait applies interval atomically and retains running; future earliest time recomputed")
        store.busy = true
        store.updatePlanInterval(plan.id, minutes: 1, lowerGlobal: true)
        precondition(store.plans[0].intervalMinutes == 25 && store.settings.globalGapMinutes == 25 && store.running)
        precondition(store.error != nil)
        store.busy = false; store.error = nil
        print("PASS busy application rejected without changing settings")
        store.tick() // Still five minutes early: cannot enter a chat driver.
        precondition(!store.busy && store.deliveries[1].status == "queued" && store.step.contains("等待"))
        print("PASS early tick reports cooldown and leaves job queued")
        store.running = false
        store.updatePlanInterval(plan.id, minutes: 30, lowerGlobal: false)
        precondition(!store.running && store.plans[0].intervalMinutes == 30)
        print("PASS paused update remains paused")
        var unresolved = sent; unresolved.id = UUID().uuidString; unresolved.status = "uncertain"
        store.deliveries.append(unresolved); store.running = true
        store.tick()
        precondition(!store.busy && store.step.contains("待核对"))
        store.running = false
        print("PASS uncertain record blocks dispatch with explicit reason")
        print("5 Store integration checks passed. Isolated data; no QQ sends.")
    }
}
