import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin

let starterText = """
Vibecoding AIGC 交流群｜目前免费开放 🚀

想入门 AI，却不知道从哪里开始？或者已经用过一些工具，想把想法做成作品？欢迎一起交流。

群里可免费指导 Codex、Grok、Claude 等 AI 工具的安装配置与使用，分享终端操作、AI 视频提示词和常见报错排查。从选择工具、启动项目，到做出第一个网页、一张海报或一段 AI 视频，一步步上手。

我在两个月内通过 AI 项目累计赚到 1 万元以上，也整理了自己的实践路径和标准操作流程（SOP）。目前已为学校定制中石大课表小程序，食堂评分小程序正在完善中。欢迎交流这些项目是怎么从想法做到落地的。

群里也会分享 AI 新动态、实用资源和项目经验，交流网站与小程序、Agent 工作流、视频设计及 PPT 制作，互相看作品、提建议，找伙伴一起共创。

感兴趣的友友可以加我好友，进群一起学、一起做！
"""

@MainActor
final class Store: ObservableObject {
    private var timingRevision = 0
    var presentationRevision: Int { timingRevision }
    private var timingCache: (revision: Int, intervals: [String:Int], dues: [String:Date], next: [String:Delivery])?
    @Published var recipients: [Recipient] = []
    @Published var assets: [Asset] = []
    @Published var plans: [Plan] = [] { didSet { timingRevision &+= 1 } }
    @Published var deliveries: [Delivery] = [] { didSet { timingRevision &+= 1 } }
    @Published var settings = Settings() { didSet { timingRevision &+= 1 } }
    /// running 是全局活动汇总；每条队列的启动状态由 runningPlanIDs 独立管理。
    @Published var running = false {
        didSet {
            if !running && !runningPlanIDs.isEmpty { runningPlanIDs = [] }
            if running && runningPlanIDs.isEmpty, let id = activePlanID { runningPlanIDs = [id] }
            updateActivity(); scheduleNextTick()
        }
    }
    @Published var runningPlanIDs: Set<String> = [] {
        didSet { timingRevision &+= 1; if running != !runningPlanIDs.isEmpty { running = !runningPlanIDs.isEmpty } }
    }
    /// 有限启动只允许这些普通任务；失败同样消耗一条，绝不会超量补发下一群。
    @Published private(set) var runSelection: [String: Set<String>] = [:] { didSet { timingRevision &+= 1 } }
    /// 保留单队列兼容入口；页面选择不再依赖执行队列。
    @Published var activePlanID: String? {
        didSet { if running && runningPlanIDs.isEmpty, let id = activePlanID { runningPlanIDs = [id] } }
    }
    @Published private(set) var processingPlanID: String?
    @Published private(set) var historyActionBusy = false
    @Published private(set) var historyNotice: String?
    @Published var busy = false
    @Published var step = "尚未启动队列"
    /// 循环发送的独立提示通道：不再借 step（会被驱动/闸门文案覆盖），由队列页与发送记录页的横幅展示，手动关闭。
    /// 多条并存（多计划各自触发），写入一律走 postRecurNotice，最多保留最新 3 条。
    @Published var recurNotices: [String] = []
    @Published var error: String?
    @Published var qqDiagnostic = SendChannel.qqStatusPlaceholder
    @Published var wechatDiagnostic = SendChannel.wechatStatusPlaceholder
    /// 当前会占前台的目标应用名。菜单栏暂停提示用它，避免微信任务写成 QQ。
    @Published var operationAppName = "QQ"
    @Published var route = "home"
    /// 队列页用户手选或动作钉住的计划 ID；仅会话内存，不落盘、不参与 Codable 持久化。
    /// 空串表示未钉住，queuePlanID 按最早到期任务自动推导。提升到 Store 是因为
    /// 路由切换会整体重建 QueueView（.id(store.route)），@State 钉住会被重置。
    @Published var chosenPlanID = ""
    @Published var qqPermission: Bool = QQDriver.trusted
    @Published var wechatPermission: Bool = WeChatDriver.trusted
    // MARK: 会员体系状态
    @Published var licenseState: LicenseState = .loggedOut
    @Published var guestMode = false
    @Published var licenseBusy = false
    @Published var licensePlans: [PlanInfo] = Store.normalizedLicensePlans(PlanCatalog.fallback)   // 会员中心价格卡；装入前经 normalizedLicensePlans 清洗月卡文案
    @Published var licenseTestResult: String?                        // 设置页「测试连接」结果
    let license = LicenseService()
    let db: Database
    let driver = QQDriver()
    let wechatDriver = WeChatDriver()
    let relationshipInbox: RelationshipInbox
    private let relationshipNavigator: RelationshipChatNavigator
    private var relationshipTimer: Timer?

    /// 按任务渠道选择驱动
    func driverFor(_ channelName: String) -> ChatDriver {
        channelName == SendChannel.wechat ? wechatDriver : driver
    }
    #if RENDER_HARNESS
    /// 隔离集成测试仅注入假驱动；正式构建没有这条替换路径。
    var isolatedDispatchDriver: (any ChatDriver)?
    var isolatedPresentationEffects: (any SendPresentationEffects)?
    #endif
    private var presentationEffects: any SendPresentationEffects {
        #if RENDER_HARNESS
        return isolatedPresentationEffects ?? SilentSendPresentation.shared
        #else
        return SystemSendPresentation.shared
        #endif
    }
    /// 调度心跳（替代原每秒重复 Timer）：空闲时手动逐次重排降频，见 scheduleNextTick
    private var dispatchSource: DispatchSourceTimer?
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private func updateActivity() {
        if running && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled],reason:"执行用户启动的 QQ 排期") }
        if !running, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
    }
    // 今日任务（今天 00:00 起，含未来天；用于总览时间线）
    // 走查 1-12：排期语义由 Scheduling.calendar（硬编码北京时间）决定，这里必须用同一个日历求「今天」，
    // 否则本机时区不是 Asia/Shanghai 时，总览的「今日 N 条」会和时刻表分项对不上账。
    var todayDeliveries: [Delivery] {
        deliveries.filter { $0.scheduled >= Scheduling.calendar.startOfDay(for: Date()) }.sorted { $0.scheduled < $1.scheduled }
    }
    var intervalByPlan: [String:Int] {
        refreshTimingCache()
        return timingCache!.intervals
    }
    /// 仅资料变更时重算；时钟、页面切换和倒计时不再反复扫描全部历史。
    private func refreshTimingCache() {
        if timingCache?.revision == timingRevision { return }
        var result: [String:Int] = [:]
        for plan in plans {
            let minutes = Scheduling.paceMinutes(plan)
            result[plan.id] = min(result[plan.id] ?? minutes, minutes)
        }
        let dues = Scheduling.dueDates(deliveries, gap: settings.globalGapMinutes, intervalByPlan: result)
        var next: [String:Delivery] = [:]
        let allowed = dispatchableIDs
        for job in deliveries where allowed.contains(job.id) {
            if let old = next[job.planID] {
                let a = dues[job.id] ?? job.scheduled, b = dues[old.id] ?? old.scheduled
                if a > b || (a == b && job.scheduled >= old.scheduled) { continue }
            }
            next[job.planID] = job
        }
        timingCache = (timingRevision, result, dues, next)
    }
    var nextDelivery: Delivery? {
        running ? MultiQueueScheduling.nextCandidate(jobs: deliveries, activePlanIDs: runningPlanIDs,
                  gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan, allowedDeliveryIDs: dispatchableIDs) : nextDelivery(planID: nil)
    }
    func queueJobs(planID: String) -> [Delivery] {
        guard let plan = plans.first(where: { $0.id == planID }) else { return [] }
        return QueueBatch.jobs(in: plan, from: deliveries)
    }
    private var dispatchableIDs: Set<String> {
        let byID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(deliveries.compactMap { job in
            guard QueueBatch.canDispatch(job), let plan = byID[job.planID],
                  plan.queueCancelledAt == nil, QueueBatch.contains(job, in: plan),
                  !isQueueRunning(plan.id) || (runSelection[plan.id]?.contains(job.id) ?? true) else { return nil }
            return job.id
        })
    }
    func isQueueRunning(_ planID: String?) -> Bool {
        planID.map { runningPlanIDs.contains($0) || (running && runningPlanIDs.isEmpty && activePlanID == $0) } ?? false
    }
    func nextDelivery(planID: String?) -> Delivery? {
        if let planID { refreshTimingCache(); return timingCache!.next[planID] }
        return MultiQueueScheduling.nextCandidate(jobs: deliveries, activePlanIDs: Set(plans.map(\.id)),
                      gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan, allowedDeliveryIDs: dispatchableIDs)
    }
    func earliestSendDate(_ job: Delivery) -> Date {
        refreshTimingCache()
        return timingCache!.dues[job.id] ?? job.scheduled
    }
    func timingExplanation(_ job: Delivery) -> String {
        if busy && processingPlanID == job.planID { return "正在处理当前群，完成后继续" }
        let due = earliestSendDate(job)
        if !isQueueRunning(job.planID) { return "此队列已暂停，点击启动后执行" }
        if busy { return "另一队列正在使用 QQ，结束后按排期执行" }
        if due > Date() {
            return due > job.scheduled ? "正在等待发送间隔；原排期已顺延，以最早发送时间为准" : "等待预定时间，到时自动发送"
        }
        return "已满足发送时间，正在调度"
    }
    var queuedCount: Int { deliveries.filter { $0.status == "queued" }.count }
    var verifiedCount: Int { deliveries.filter { ["verified","manual"].contains($0.status) }.count }

    private let lockFD: Int32
    var archive: Archive { Archive(recipients:recipients,assets:assets,plans:plans,deliveries:deliveries,settings:settings) }
    private var permissionTimer: Timer?
    /// 等值守卫用：本次运行至少把 permission-status.json 写过一次（PID 每次启动都变）
    private var permissionStatusWritten = false
    private var permissionActivationObserver: NSObjectProtocol?
    /// 退出前把防抖中的草稿立刻落盘，保住旧的「每次击键必落盘」的退出安全性
    private var terminationObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    /// 走查 5-02：「发送成功后自动返回排程助手」的常驻监听者。原先唯一订阅点挂在
    /// MenuBarExtra 的面板内容上，面板没展开过就没有监听者，主窗口关闭后这条设置形同虚设。
    private var returnAfterSendObserver: NSObjectProtocol?

    // MARK: 草稿落盘防抖（只作用于 saveDraft / saveStaging 两条高频路径）
    /// 内存照旧立即更新，persist 延迟 500ms 合并；其余 persist 调用点一律立即整库落盘，不受影响
    private var draftPersistTask: Task<Void, Never>?
    private var draftPersistPending = false
    private static let draftPersistDelayNanos: UInt64 = 500_000_000

    /// 取消待执行的防抖落盘（不落盘）。调用方随后自行整库 persist 时使用（如 addPlan）。
    private func cancelScheduledDraftPersist() {
        draftPersistTask?.cancel(); draftPersistTask = nil; draftPersistPending = false
    }

    /// 草稿/暂存内容已写入内存，persist 防抖 500ms；期间再次调用会重置计时。
    /// 失败写 error 通道，不影响内存状态。
    func scheduleDraftPersist() {
        cancelScheduledDraftPersist()
        draftPersistPending = true
        draftPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.draftPersistDelayNanos)
            guard let self, !Task.isCancelled else { return }
            self.draftPersistPending = false
            do { try self.persist() } catch { self.error = "草稿自动保存失败：\(error.localizedDescription)" }
        }
    }

    /// 立即取消防抖任务并同步 persist：离开编辑页、App 退后台/失活、退出前调用。
    /// 没有待落盘的草稿时是 no-op，不产生额外整库写。
    func flushDraftPersist() {
        guard draftPersistPending else { cancelScheduledDraftPersist(); return }
        cancelScheduledDraftPersist()
        perform { try persist() }
    }


    /// 每 2 秒刷新一次权限状态；用户在系统设置里勾选后 UI 自动变亮
    func startPermissionWatch() {
        guard permissionTimer == nil else { return }
        refreshPermissions()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        permissionActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
                self?.relationshipInbox.refresh()
            }
        }
        // 退出前同步落盘防抖中的草稿。queue: .main 保证在主线程，assumeIsolated 同步执行——
        // 退出路径不能用异步任务，进程可能等不到它跑
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.flushDraftPersist() } }
        // 失去焦点（用户切走 App）时同样落盘：macOS 的 scenePhase 几乎不会走到 .inactive，这里才是真正的「失活」时机
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.flushDraftPersist() } }
    }

    /// 走查 5-02：常驻的「唤回主窗口」监听点。此前全仓唯一的订阅者挂在 MenuBarExtra 的面板内容上，
    /// 面板没展开过就没有监听者——「关闭主窗口，菜单栏继续调度」这条主路径下，
    /// 「发送成功后自动返回排程助手」只会把 App 激活到前台，窗口回不来。
    /// Store 与进程同生命周期，这里收到的通知先按 AppKit 兜底唤起，唤起不了再由
    /// `QQDispatchApp` 的菜单栏标签视图调 `openWindow(id:"main")` 重新开窗。
    func startMainWindowWakeObserver() {
        guard returnAfterSendObserver == nil else { return }
        returnAfterSendObserver = NotificationCenter.default.addObserver(
            forName: .init("QQDispatchReturnAfterSend"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.bringMainWindowForward() { self.step = "已请求重新打开主窗口" }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func refreshPermissions() {
        // Accessibility belongs to this process, not to the destination chat app.
        // 走查 5-21：两枚灯各自读自己驱动的信任位，不再由 QQ 一处赋值给微信（今天两者同为
        // 进程级 AXIsProcessTrusted，取值仍相等；分成两个来源后驱动侧可独立收紧，UI 不再自相矛盾）。
        let granted = QQDriver.trusted
        let wechatGranted = WeChatDriver.trusted
        // 等值守卫：信任状态没变时不碰 @Published，避免每 2 秒触发一次全 UI 失效；
        // 本次运行首次调用必须放行，保证 permission-status.json 至少写入一次（PID 每次启动都变）
        guard !permissionStatusWritten || qqPermission != granted || wechatPermission != wechatGranted else { return }
        qqPermission = granted
        wechatPermission = wechatGranted
        permissionStatusWritten = true
        let statusURL = db.root.appendingPathComponent("permission-status.json")
        let status: [String: Any] = ["trusted": granted,
            "appPath": Bundle.main.bundlePath,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
           (try? Data(contentsOf: statusURL)) != data {
            try? data.write(to: statusURL, options: .atomic)
        }
    }

    deinit {
        permissionTimer?.invalidate()
        relationshipTimer?.invalidate()
        dispatchSource?.cancel()
        draftPersistTask?.cancel()
        if let observer = permissionActivationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = terminationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = resignActiveObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = returnAfterSendObserver { NotificationCenter.default.removeObserver(observer) }
    }

    init(root: URL, relationshipNavigator: RelationshipChatNavigator? = nil) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        lockFD = Darwin.open(root.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR,0o600)
        guard lockFD >= 0, flock(lockFD,LOCK_EX | LOCK_NB) == 0 else { throw AppError("QQ排程助手已经在运行，请使用已打开的窗口") }
        db = try Database(root:root)
        relationshipInbox = RelationshipInbox(appRoot: root)
        self.relationshipNavigator = relationshipNavigator ?? wechatDriver
        var skippedRows = 0
        recipients = try db.load("recipients",as:Recipient.self); skippedRows += db.lastSkippedRows
        assets = try db.load("assets",as:Asset.self); skippedRows += db.lastSkippedRows
        plans = try db.load("plans",as:Plan.self); skippedRows += db.lastSkippedRows
        deliveries = try db.load("deliveries",as:Delivery.self); skippedRows += db.lastSkippedRows
        startPermissionWatch()
        startMainWindowWakeObserver()
        // 菜单栏条带倒计时：挂到独立小模型（MenuBarStatus），绝不直接在 label 里读 Store——
        // 启动期 Store 的 @Published 连环触发会把 label 反复 invalidate，状态按钮初始化死循环。
        MenuBarStatus.shared.attach(store: self)
        settings = try db.load("settings",as:Settings.self).first ?? Settings(savedText: "")
        skippedRows += db.lastSkippedRows
        // 行级容错：单行坏数据不再让整个 App 启动失败；坏行原样留在磁盘并写入隔离区（走查 1-07）
        if skippedRows > 0 {
            let quarantined = db.quarantineCount()
            error = "数据库有 \(skippedRows) 行无法读取，已跳过并原样保留在隔离区（quarantine_rows，累计 \(quarantined) 条）；"
                + "全量落盘时坏行会按原样写回，不会被删除。请先到「设置与备份 → 备份数据库与素材」留一份整库副本，"
                + "再到「导出隔离区」取回坏行原文核对。"
        }
        if settings.textTemplates == nil { settings.textTemplates = settings.savedText.isEmpty ? [] : [TextTemplate(text:settings.savedText)] }
        // 会员：先用本地档案离线判定（active/grace/expired），随后异步向服务器校验
        license.baseURL = LicenseService.normalize(settings.licenseServerURL)
        licenseState = settings.resolvedLicenseState()
        if case .expired = licenseState { route = "member" }
        // 走查 2026-10-06：记住的游客选择在这里恢复。已过期时不自动恢复（否则等于
        // 重开 3-15 刚堵上的付费墙绕行），让用户看到过期提示后再自行选择。
        var licenseExpired = false
        if case .expired = licenseState { licenseExpired = true }
        if settings.guestMode == true, !guestMode, !licenseExpired {
            guestMode = true
            finishEntryNavigation()
        }
        #if RENDER_HARNESS
        // 渲染工具自行注入演示态，不访问钥匙串与网络
        #else
        Task { restoreSession() }
        #endif
        let firstLaunch = !FileManager.default.fileExists(atPath:root.appendingPathComponent("initialized").path)
        settings.prepareWorkspaces(recipientIDs: recipients.filter(\.enabled).map(\.id))
        deliveries = QQVerificationReview.recovered(Scheduling.recovered(deliveries))
        let refreshed = LiveMessage.refreshed(archive, refreshReplaySnapshots: false)
        plans = refreshed.plans; deliveries = refreshed.deliveries
        // 走查 1-10：旧库、手工改库或恢复备份都可能带进 0 / 负值 / 超过一年的循环天数。
        // Scheduling.recur 现在会直接抛错（每次收尾都报一次），这里启动即清洗并如实提示。
        sanitizeRecurringPlans()
        // 有坏行时跳过启动时的整库重写：坏行原样保留在磁盘供导出备份；
        // 恢复/刷新变换只在内存进行，下次启动会重新应用（recovered/refreshed 均为幂等）
        if skippedRows == 0 { try persist() }
        // 循环发送触发点：App 关着时一轮可能已全部跑完 / 核验完，启动即补生成下一轮。
        // 只补排队任务，不启动发送；lastSendActivity 钳制保证新任务不会排到过去。
        // 循环提示走 recurNotices 独立通道，不会被下一行的启动闸 step 文案覆盖（安全提示优先归 step）。
        // 有坏行时跳过补轮：补轮的 persist 是整库重写，会把还没来得及备份的坏行从磁盘抹掉。
        if skippedRows == 0 {
            for planID in plans.filter({ $0.recurringEveryDays != nil }).map(\.id) { maybeRecur(planID: planID) }
        }
        if let refusal = QueueStartGate.refusal(statuses: deliveries.map(\.status)) { step = refusal }
        if firstLaunch { try Data("1".utf8).write(to:root.appendingPathComponent("initialized"),options:.atomic) }
        driver.onStep = { [weak self] in self?.step = $0 }
        wechatDriver.onStep = { [weak self] in self?.step = $0 }
        relationshipInbox.refresh()
        #if !RENDER_HARNESS
        relationshipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relationshipInbox.refresh(ifModifiedOnly: true) }
        }
        startDispatchHeartbeat()
        #endif
    }
    func persist() throws {
        do { try db.save(archive) }
        catch { stop(); throw error } // 任何持久化失败均停止所有自动队列及当前操作。
        // 瞬时连接级故障（磁盘 I/O、锁竞争、满盘）已在 Database 内部自愈重连并重试成功，
        // 不会走到这里；能到这里的失败是自愈后仍然失败，按用户要求停车并如实报错。
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func saveSettings() { perform { try persist() } }

    // MARK: 会员体系（登录 / 注册 / 兑换 / 校验；纯判定逻辑在 Core.swift）

    /// 服务器地址变更时同步到 LicenseService
    func enterGuestMode() {
        guard !licenseBusy, !busy, !running else { return }
        guestMode = true
        settings.guestMode = true
        saveSettings()   // 走查 2026-10-06：记住游客选择，重启不再回登录页
        error = nil
        finishEntryNavigation()
        step = "游客体验中；队列未启动"
    }

    private func finishEntryNavigation() {
        if route != "recipients" || orderChannel != SendChannel.wechat { route = "home" }
    }

    func returnToLogin() {
        guard !busy else { return }
        stop()
        guestMode = false
        settings.guestMode = false
        saveSettings()
        error = nil
        route = "home"
    }

    func updateLicenseServer() {
        license.baseURL = LicenseService.normalize(settings.licenseServerURL)
    }

    /// 启动时校验：钥匙串有 token → /api/me 刷新档案；401/403 清凭据回登录；网络失败保持本地宽容判定
    func restoreSession() {
        guard let token = KeychainStore.load() else { return }   // 无 token：维持本地 resolve 结果
        guard !licenseBusy else { return }
        licenseBusy = true
        Task {
            defer { licenseBusy = false }
            do {
                let profile = try await license.me(token: token)
                // 走查 3-15：服务端对已过期账号同样返回 200 + 档案，所以「请求成功」不等于「会员有效」。
                // 服务器明确回答已过期时本次不能计为有效验证（不刷新宽限计时点），否则每 72 小时联网
                // 就能把宽限期重新充满，过期账号永久放行。
                applyLicenseProfile(profile, validated: LicenseState.serverConfirmedValid(profile, lastServerTime: settings.licenseLastServerTime))
            } catch {
                if LicenseService.isAuthError(error) {
                    KeychainStore.delete()
                    applyLicenseProfile(nil, validated: false)
                    step = "登录已过期，请重新登录"
                }
                // 网络等其他失败：这才是宽限期真正要覆盖的场景（离线容错），保持本地判定，不打扰用户
            }
        }
    }

    /// 统一落地档案：写 Settings + 重算 licenseState；expired 时首次自动跳会员中心（仅在路由不在 member 时设置，避免死循环）
    private func applyLicenseProfile(_ profile: MembershipProfile?, saveToken: String? = nil, validated: Bool) {
        if let saveToken { KeychainStore.save(saveToken); guestMode = false; settings.guestMode = false }
        settings.licenseProfile = profile
        // 走查 3-15：宽限计时点与单调时间锚一并交给 Settings 落地——服务端明确答过期时（validated=false）
        // 计时点清空、锚点只采信服务端时间不采信本机时钟；本次有效时计时点取 max(本机时钟, server_time)。
        settings.recordLicenseValidation(validated: validated, serverTime: profile?.serverTime, localNow: Date())
        licenseState = settings.resolvedLicenseState()
        if case .expired = licenseState, !guestMode, route != "member" { route = "member" }
        saveSettings()
    }

    /// token 可空：登录/注册携带新 token 落钥匙串；兑换沿用原 token
    private func runLicenseTask(_ operation: @escaping () async throws -> (profile: MembershipProfile, token: String?), successStep: @escaping (MembershipProfile) -> String, onSuccess: ((MembershipProfile) -> Void)? = nil) {
        guard !licenseBusy else { return }
        licenseBusy = true
        error = nil
        Task {
            defer { licenseBusy = false }
            do {
                let result = try await operation()
                // 走查 3-15：登录/注册/兑换同样可能在 200 里带回一个已过期的档案，判定口径与 restoreSession 一致
                applyLicenseProfile(result.profile, saveToken: result.token, validated: LicenseState.serverConfirmedValid(result.profile, lastServerTime: settings.licenseLastServerTime))
                step = successStep(result.profile)
                onSuccess?(result.profile)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func login(account: String, password: String) {
        let name = account.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { error = "请输入账号和密码"; return }
        runLicenseTask({
            let session = try await self.license.login(account:name,password:password)
            return (session.profile, session.token)
        }, successStep: { profile in
            "登录成功，\(profile.planLabel)有效至 \(Self.dueText(profile))"
        }, onSuccess: { _ in self.finishEntryNavigation() })
    }

    func register(account: String, password: String) {
        let name = account.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { error = "请输入账号和密码"; return }
        runLicenseTask({
            let session = try await self.license.register(account:name,password:password)
            return (session.profile, session.token)
        }, successStep: { profile in
            "注册成功，已开通 \(profile.planLabel)，有效至 \(Self.dueText(profile))"
        }, onSuccess: { _ in self.finishEntryNavigation() })
    }

    func redeem(code: String) {
        let trimmed = code.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "请输入卡密"; return }
        guard let token = KeychainStore.load() else { error = "请先登录"; return }
        runLicenseTask({ (try await self.license.redeem(token:token,code:trimmed), nil) }, successStep: { profile in
            "兑换成功，会员有效至 \(Self.dueText(profile))"
        })
    }

    /// 服务端登出失败也不阻塞本地登出；本机数据与队列不受影响
    func logout() {
        guard !licenseBusy else { return }
        let token = KeychainStore.load()
        licenseBusy = true
        Task {
            defer { licenseBusy = false }
            if let token { _ = try? await license.logout(token:token) }
            KeychainStore.delete()
            applyLicenseProfile(nil, validated: false)
            route = "home"
            step = "已退出登录"
        }
    }

    /// 设置页「测试连接」：读套餐并显示数量
    func testLicenseServer() {
        guard !licenseBusy else { return }
        updateLicenseServer()
        licenseTestResult = nil
        licenseBusy = true
        Task {
            defer { licenseBusy = false }
            do {
                let loaded = try await license.plans()
                if !loaded.isEmpty { licensePlans = Self.normalizedLicensePlans(loaded) }
                licenseTestResult = "已连接，读到 \(loaded.count) 个套餐"
                step = licenseTestResult ?? ""
            } catch {
                licenseTestResult = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// 会员中心价格卡数据；失败静默回退内置套餐
    func loadLicensePlans() {
        updateLicenseServer()
        Task {
            do {
                let loaded = try await license.plans()
                if !loaded.isEmpty { licensePlans = Self.normalizedLicensePlans(loaded) }
            } catch { licensePlans = Self.normalizedLicensePlans(PlanCatalog.fallback) }
        }
    }

    /// 月卡文案规整（Core 边界审计）：服务端暂不返回原价字段，「当前优惠价」缺少
    /// 「优惠价 vs 原价」的对比依据，因此会员中心卡面不展示「优惠」字样，只保留时长描述。
    /// 兜底目录定义在 Core.swift、卡面渲染在 AuthUI.swift，均不在本次可改范围，
    /// 故在装入 licensePlans 时统一清洗；服务端返回的 tagline 同样过这道，避免同一问题透传。
    static func normalizedLicensePlans(_ plans: [PlanInfo]) -> [PlanInfo] {
        plans.map { plan in
            guard plan.tagline.contains("当前优惠价") else { return plan }
            let cleaned = plan.tagline
                .replacingOccurrences(of: "当前优惠价 · ", with: "")
                .replacingOccurrences(of: "当前优惠价", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PlanInfo(id: plan.id, name: plan.name, days: plan.days,
                            priceFen: plan.priceFen,
                            tagline: cleaned.isEmpty ? "\(plan.days) 天会员" : cleaned)
        }
    }

    static func dueText(_ profile: MembershipProfile) -> String {
        profile.paidUntil?.formatted(date:.abbreviated,time:.omitted) ?? profile.planLabel
    }

    /// 功能门禁：active/grace 放行；expired 引导到会员中心；loggedOut 提示登录。只挡新动作，不打断运行中的队列。
    /// 走查 3-15：`.grace` 现在只能由「联系不上服务器」的离线分支得到——服务器明确回答已过期时
    /// 不再刷新宽限计时点（见 `LicenseState.serverConfirmedValid`），过期账号不会再靠联网续命。
    @discardableResult func guardMembership() -> Bool {
        if guestMode { return true }
        switch licenseState {
        case .active, .grace: return true
        case .expired:
            error = memberGateMessage
            route = "member"
            return false
        case .loggedOut:
            error = memberGateMessage
            return false
        }
    }

    var memberGateMessage: String {
        switch licenseState {
        case .expired: return "会员已过期，请到会员中心续费"
        default: return "请先登录"
        }
    }

    /// 侧栏状态卡的会员摘要
    var membershipHint: String {
        if guestMode { return "游客体验" }
        switch licenseState {
        case .loggedOut: return "未登录"
        case .active(let profile), .grace(let profile):
            if let until = profile.paidUntil {
                let days = Int(ceil(until.timeIntervalSinceNow / 86400))
                if days > 0 { return "\(profile.isTrial ? "试用" : "会员")剩 \(days) 天" }
            }
            if let days = profile.daysLeft, days > 0 { return "会员剩 \(days) 天" }
            return "会员有效至 \(Self.dueText(profile))"
        case .expired: return "会员已过期"
        }
    }

    var workspaceID: String { settings.activeWorkspaceID ?? "legacy" }
    var workspaces: [BroadcastWorkspace] { settings.broadcastWorkspaces ?? [] }
    var workspaceName: String { workspaces.first(where: { $0.id == workspaceID })?.name ?? "默认群发" }
    func saveDraft(_ draft: BroadcastDraft, workspaceID: String) {
        guard let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == workspaceID }) else { return }
        settings.broadcastWorkspaces?[i].draft = draft
        if self.workspaceID == workspaceID {
            settings.savedText = draft.text
            settings.preferredRecipientIDs = draft.recipientIDs; settings.preferredAssetIDs = draft.assetIDs
            settings.broadcastWorkspaces?[i].templates = settings.textTemplates ?? []
        }
        // 编辑页每次击键都会走到这里：内存照旧立即更新，persist 防抖合并，避免每键整库重写
        scheduleDraftPersist()
    }
    /// 草稿配图变动即时同步：把选中素材刷新到**当前草稿所绑定模板**产生的计划及其未发送任务的附件快照，
    /// 删除/新增配图立即生效，无需再点保存并同步；保护条件与 LiveMessage.refreshed 一致。
    /// 走查 1-03：作用域从「整个群发空间」收窄到「当前模板」——同空间里其他计划、其他模板不再被
    /// 一次勾选连带改写；拿不到模板 id 时只写草稿，不动任何计划；落盘失败整体回滚，界面与磁盘不分叉。
    func syncUnsentAssets(_ ids: [String], workspaceID: String? = nil, templateID: String? = nil) {
        guard !busy else { error = "当前群正在处理，等这一条结束后再改配图；现在的改动只留在草稿里，不会同步到计划"; return }
        perform {
            let spaceID = workspaceID ?? self.workspaceID
            guard let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == spaceID }) else { return }
            let oldSettings = settings, oldPlans = plans, oldJobs = deliveries
            let resolved = ids.compactMap { id in assets.first { $0.id == id } }
            let resolvedIDs = resolved.map(\.id)
            var changed = false
            if settings.broadcastWorkspaces?[i].draft.assetIDs != resolvedIDs {
                settings.broadcastWorkspaces?[i].draft.assetIDs = resolvedIDs; changed = true
            }
            if let tid = settings.broadcastWorkspaces?[i].draft.selectedTemplateID,
               let t = settings.broadcastWorkspaces?[i].templates.firstIndex(where: { $0.id == tid }),
               settings.broadcastWorkspaces?[i].templates[t].assetIDs != resolvedIDs {
                settings.broadcastWorkspaces?[i].templates[t].assetIDs = resolvedIDs; changed = true
            }
            // 只改由当前模板产生的计划（计划↔模板口径与 LiveMessage.refreshed 同源）
            let targeted = templateID == nil ? Set<String>()
                : Set(plans.filter { ($0.workspaceID ?? "legacy") == spaceID && $0.textTemplateID == templateID }.map(\.id))
            for d in deliveries.indices where targeted.contains(deliveries[d].planID) {
                let job = deliveries[d]
                if let plan = plans.first(where: { $0.id == job.planID }), QueueBatch.contains(job, in: plan),
                   !job.isOneOff, job.started == nil, (job.status == "queued" || job.canRequeue),
                   job.submittedAt == nil, job.evidence.isEmpty, job.assets != resolved {
                    deliveries[d].assets = resolved; changed = true
                }
            }
            for p in plans.indices where targeted.contains(plans[p].id) {
                if plans[p].assetIDs != resolvedIDs { plans[p].assetIDs = resolvedIDs; changed = true }
            }
            if changed {
                do { try persist() } catch { settings = oldSettings; plans = oldPlans; deliveries = oldJobs; throw error }
            }
        }
    }
    func saveStaging(workspaceID: String, text: String? = nil, files: [URL]? = nil) {
        guard let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == workspaceID }) else { return }
        perform {
            if let text { settings.broadcastWorkspaces?[i].stagingText = text }
            if let files {
                let folder = db.root.appendingPathComponent("assets/workspace-drafts").appendingPathComponent(workspaceID)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var stored: [String] = []
                for file in files {
                    if file.path.hasPrefix(folder.path + "/") { stored.append(String(file.path.dropFirst(db.root.path.count + 1))); continue }
                    let target = folder.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
                    try FileManager.default.copyItem(at: file, to: target); stored.append(String(target.path.dropFirst(db.root.path.count + 1)))
                }
                settings.broadcastWorkspaces?[i].stagingFiles = stored
            }
            // 一体化输入框每次击键都会走到这里：文件照旧立即复制，persist 防抖合并
            scheduleDraftPersist()
        }
    }
    func switchWorkspace(_ id: String) {
        perform { let old = settings; do { try settings.switchWorkspace(id); try persist() } catch { settings = old; throw error } }
    }
    func createWorkspace(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请填写空间名称"; return }
        guard !workspaces.contains(where: { $0.name == name }) else { error = "已有同名空间"; return }
        perform {
            let old = settings
            var space = BroadcastWorkspace(name: name); space.draft.interval = settings.globalGapMinutes
            settings.broadcastWorkspaces = workspaces + [space]
            do { try settings.switchWorkspace(space.id); try persist() } catch { settings = old; throw error }
        }
    }

    @discardableResult func saveTextTemplate(id: String? = nil, text: String, workspaceID: String? = nil, assetIDs: [String]? = nil) throws -> String {
        let spaceID = workspaceID ?? self.workspaceID
        guard let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == spaceID }) else { throw AppError("群发空间不存在") }
        let old = archive
        // Resolve legacy identities against the old text before replacing it.
        plans = LiveMessage.linked(archive).plans
        var templates = settings.broadcastWorkspaces?[i].templates ?? []
        let templateID: String
        if let id, let j = templates.firstIndex(where: { $0.id == id }) {
            templates[j].text = text
            // 传入配图才覆盖：addPlan 等纯文字保存不能抹掉模板已有配图
            if let assetIDs { templates[j].assetIDs = assetIDs }
            templateID = id
        } else {
            let template = TextTemplate(text: text, assetIDs: assetIDs); templates.append(template); templateID = template.id
        }
        settings.broadcastWorkspaces?[i].templates = templates
        if settings.broadcastWorkspaces?[i].draft.selectedTemplateID == templateID {
            settings.broadcastWorkspaces?[i].draft.text = text
        }
        if spaceID == self.workspaceID {
            settings.textTemplates = templates
            settings.savedText = text
        }
        let before = deliveries
        let refreshed = LiveMessage.refreshed(archive)
        plans = refreshed.plans; deliveries = refreshed.deliveries
        do { try persist() } catch {
            settings = old.settings; plans = old.plans; deliveries = old.deliveries; throw error
        }
        // 同步范围可见：相同文案会合并成一个模板，保存可能波及多个计划的未发送任务，把条数说清楚
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let synced = deliveries.filter { job in
            guard let prev = beforeByID[job.id] else { return false }
            return prev.text != job.text || prev.assets.map(\.id) != job.assets.map(\.id)
        }.count
        step = synced > 0 ? "文案已保存，并同步到 \(synced) 条未发送任务的文案与配图" : "文案已保存，当前没有需要同步的未发送任务"
        return templateID
    }
    func deleteTextTemplate(_ id: String) {
        perform {
            var templates = settings.textTemplates ?? []
            templates.removeAll { $0.id == id }
            settings.textTemplates = templates
            if !templates.contains(where: { $0.text == settings.savedText }) { settings.savedText = templates.first?.text ?? "" }
            try persist()
            step = "已删除 1 条文案"
        }
    }
    // MARK: 从 QQ 导入群名单（读取 → 勾选 → 逐个检索验证 → 录入）

    @Published var orderChannel: String = SendChannel.qq // 「发送顺序」卡片当前显示的渠道；QQ 与微信各自独立排序

    @Published var importingList = false
    @Published var discoveredNames: [String] = []
    @Published var importProgress = ""          // 「3/7 · 正在验证：xxx」
    @Published var importLog: [String] = []     // 每条验证结果

    /// 第一步：从 QQ 会话列表读取候选群名（只读）
    func readQQSessionList() {
        guard guardMembership() else { return }   // 会员门禁
        // 走查 1-04：读取与检索验证都会打开 QQ、抢剪贴板并占用前台，和队列发送驱动的是同一个客户端、
        // 同一个 task 句柄，必须与发送互斥（openRelationshipContact 早已是 !busy/!running/!importingList 三方门禁）。
        guard !busy, !importingList, !running else {
            if running { error = "队列运行中：先点「暂停全部」，再读取 QQ 会话列表" }
            return
        }
        importingList = true; discoveredNames = []; importLog = []
        importProgress = "正在读取 QQ 会话列表…"
        task = Task {
            do {
                let names = try await driver.readSessionList()
                // 过滤掉已在名单里的
                let existing = Set(recipients.map(\.name))
                // 走查 4-11：候选行用名称做 ForEach 标识、用名称集合承载多选，所以同名候选必须先聚合——
                // QQ 按名称搜索只打开第一条结果，两个同名群在界面与检索层都无法区分，
                // 列两行只会让勾选态互相干扰、并在录入时被静默合并成一条。
                var seen = Set<String>()
                var fresh: [String] = []
                var duplicates = 0
                for name in names where !existing.contains(name) {
                    if seen.contains(name) { duplicates += 1; continue }
                    seen.insert(name); fresh.append(name)
                }
                discoveredNames = fresh
                importProgress = fresh.isEmpty ? "QQ 会话里的群都已在本名单中"
                    : "读到 \(fresh.count) 个候选群名"
                    + (duplicates > 0 ? "（另有 \(duplicates) 行群名重复：搜索只会打开第一条结果，同名群无法区分，已合并）" : "")
                    + "，请勾选要录入的"
            } catch {
                self.error = error.localizedDescription
                importProgress = ""
            }
            importingList = false
        }
    }

    /// 第二步：检查勾选名称的第一条群聊结果是否可打开
    func importVerified(_ names: [String]) {
        guard guardMembership() else { return }   // 会员门禁
        guard !busy, !importingList, !running, !names.isEmpty else {
            if running { error = "队列运行中：先点「暂停全部」，再验证群名" }
            return
        }
        importingList = true; importLog = []
        task = Task { [weak self] in
            guard let self else { return }
            var verified: [String] = []
            for (index, name) in names.enumerated() {
                importProgress = "\(index + 1)/\(names.count) · 正在检索验证：\(name)"
                do {
                    try await driver.verifySearchable(name)
                    verified.append(name)
                    importLog.append("✅ \(name)：第一条检索结果可打开")
                } catch {
                    importLog.append("❌ \(name)：\(error.localizedDescription)")
                }
            }
            var recorded = 0
            if !verified.isEmpty {
                perform { [weak self] in
                    guard let self else { return }
                    let before = self.recipients
                    var added = 0
                    for name in verified where !self.recipients.contains(where: { $0.name == name }) {
                        self.recipients.append(Recipient(name: name, note: "QQ 导入 · 已检索验证", enabled: true, channel: SendChannel.qq)); added += 1
                    }
                    // 走查 4-01 / 4-12：数字只统计真正加入的，落盘失败整批回滚，界面与磁盘不分叉
                    do { try self.persist() } catch { self.recipients = before; added = 0; throw error }
                    recorded = added
                    self.step = "已录入 \(added) 个经检索验证的群"
                        + (verified.count - added > 0 ? "；\(verified.count - added) 个同名群已在名单里，未重复添加" : "")
                }
                guard error == nil else { importingList = false; importProgress = "录入失败：\(error ?? "")"; return }
                orderChannel = SendChannel.qq // 让「发送顺序」立即切到 QQ，看到刚导入的群
            }
            importProgress = verified.isEmpty ? "没有通过验证的群名，未录入任何项"
                : "完成：录入 \(recorded) 个，通过验证 \(verified.count) 个，未通过 \(names.count - verified.count) 个"
            importingList = false
        }
    }

    /// 按行加入名单。走查 4-01：返回**真正新增**的条数，并把「同名已存在」「同名但属于其他渠道」分开如实交代
    /// ——名单按名称全局去重，所以给微信渠道粘贴一个已有 QQ 群名时，并不会新增微信目标，
    /// 界面不能拿输入行数冒充加入数。落盘失败整批回滚，内存与磁盘不分叉（走查 4-12 的另一半在调用侧）。
    @discardableResult
    func addRecipients(_ input: String, channel: String = SendChannel.qq) -> Int {
        var added = 0
        perform {
            let lines = input.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw AppError("请输入群名或联系人名称，一行一个") }
            let before = recipients
            var sameChannel = 0, otherChannel: [String] = []
            for line in lines {
                if let hit = recipients.first(where: { $0.name == line }) {
                    if hit.channelName == channel { sameChannel += 1 } else { otherChannel.append(hit.name) }
                    continue
                }
                recipients.append(Recipient(name:line, note:"", enabled:true, channel:channel)); added += 1
            }
            do { try persist() } catch { recipients = before; added = 0; throw error }
            orderChannel = channel // 添加后自动切到对应渠道的发送顺序，立即看到新群
            let label = channel == SendChannel.wechat ? "微信" : "QQ"
            var note = "已加入 \(added) 个\(label)目标"
            if sameChannel > 0 { note += "；\(sameChannel) 个同名\(label)目标已存在，未重复添加" }
            if !otherChannel.isEmpty {
                note += "；\(otherChannel.count) 行只命中了其他渠道的同名群（\(otherChannel.prefix(3).joined(separator: "、"))），未新增\(label)目标，也没被选中"
            }
            step = note
        }
        return added
    }
    func renameRecipient(id: String?, deliveryID: String?, name: String) throws {
        guard !busy && !running else { throw AppError("请先暂停队列，再修改群名") }
        let target: String
        if let deliveryID {
            guard let job = deliveries.first(where: { $0.id == deliveryID }), job.canRenameRecipient else { throw AppError("该任务当前不能修改群名") }
            target = try RecipientRename.resolve(job, recipients: recipients)
        } else if let id { target = id }
        else { throw AppError("未找到对应群聊") }
        let updated = try RecipientRename.renamed(archive, id: target, name: name)
        try db.save(updated)
        recipients = updated.recipients; deliveries = updated.deliveries
        step = "群名已同步到群聊名单和待执行队列"
    }
    func moveRecipient(id: String, offset: Int) {
        perform {
            let moved = RecipientList.moved(recipients, id: id, offset: offset)
            guard moved != recipients else { return }
            recipients = moved
            try persist()
        }
    }
    func deleteRecipient(_ id: String) {
        perform {
            guard let name = recipients.first(where:{$0.id == id})?.name else { return }
            recipients.removeAll { $0.id == id }
            settings.preferredRecipientIDs = settings.preferredRecipientIDs?.filter { $0 != id }
            try persist()
            step = "已从名单移除：\(name)。历史记录不受影响"
        }
    }
    struct IntervalPreview {
        let deliveries: [Delivery]
        let globalGap: Int
        let remaining: Int
        let nextDate: Date
        let finishDate: Date
    }
    /// 预览与应用共用一次重排计算，下一群、剩余任务与预计结束使用同一口径。
    func previewPlanInterval(_ planID: String, minutes: Int, lowerGlobal: Bool, now: Date = Date()) throws -> IntervalPreview {
        guard let plan = plans.first(where: { $0.id == planID }) else { throw AppError("计划不存在") }
        let gap = lowerGlobal ? min(settings.globalGapMinutes, minutes) : settings.globalGapMinutes
        let preserveStart = plan.days > 1 || !plan.times.isEmpty || Scheduling.lastSendActivity(deliveries.filter { $0.planID == planID }) == nil
        let updated = try Scheduling.retimed(deliveries, planID: planID, minutes: minutes, now: now,
                                            globalGap: gap, preserveFutureStart: preserveStart, plan: plan)
        let remaining = Scheduling.ordered(updated.filter {
            $0.planID == planID && $0.status == "queued" && !$0.isOneOff && $0.submittedAt == nil && $0.evidence.isEmpty
        })
        guard let first = remaining.first, let last = remaining.last else { throw AppError("当前计划没有待执行任务") }
        return IntervalPreview(deliveries: updated, globalGap: gap, remaining: remaining.count,
                               nextDate: first.scheduled, finishDate: last.scheduled)
    }
    @discardableResult
    func updatePlanInterval(_ planID: String, minutes: Int, lowerGlobal: Bool, now: Date = Date()) -> Bool {
        guard !busy else { error = "当前群正在处理，结束后即可应用间隔"; return false }
        guard let i = plans.firstIndex(where: { $0.id == planID }) else { error = "计划不存在"; return false }
        let oldPlans = plans, oldJobs = deliveries, oldSettings = settings, oldChosen = chosenPlanID
        do {
            let preview = try previewPlanInterval(planID, minutes: minutes, lowerGlobal: lowerGlobal, now: now)
            // 保留单群间隔、每天的轮次和全部已提交/已完成记录。
            plans[i].intervalMinutes = minutes
            deliveries = preview.deliveries; settings.globalGapMinutes = preview.globalGap
            chosenPlanID = planID
            try persist()
            error = nil
            step = "已改为每\(minutes)分钟一群；\(preview.remaining)条待执行任务已重排，" + (running ? "队列继续运行" : "队列保持暂停")
            scheduleNextTick()
            return true
        } catch {
            plans = oldPlans; deliveries = oldJobs; settings = oldSettings; chosenPlanID = oldChosen
            self.error = error.localizedDescription
            return false
        }
    }
    /// 等待中的队列可改期；已进入 QQ 的当前群使用原排期直到本次操作收尾。
    func canEditPlanSchedule(_ planID: String) -> Bool {
        guard !deliveries.contains(where: { $0.planID == planID && $0.status == "running" }) else { return false }
        return !busy || (processingPlanID != nil && processingPlanID != planID)
    }
    func previewPlanSchedule(_ planID: String, start: Date, now: Date = Date()) throws -> QueueSchedule.Preview {
        guard canEditPlanSchedule(planID) else { throw AppError("当前群正在处理，结束后可修改剩余排期") }
        guard let plan = plans.first(where: { $0.id == planID }) else { throw AppError("队列不存在") }
        return try QueueSchedule.moved(plan: plan, jobs: deliveries, requestedStart: start,
                                       now: now, globalGap: settings.globalGapMinutes)
    }
    @discardableResult
    func updatePlanSchedule(_ planID: String, start: Date, now: Date = Date()) -> Bool {
        let oldPlans = plans, oldJobs = deliveries
        do {
            let preview = try previewPlanSchedule(planID, start: start, now: now)
            guard let index = plans.firstIndex(where: { $0.id == planID }) else { throw AppError("队列不存在") }
            plans[index] = preview.plan; deliveries = preview.deliveries
            try persist()
            error = nil
            step = "已修改此队列剩余 \(preview.remaining) 群的排期；" + (isQueueRunning(planID) ? "此队列继续按新排期运行" : "此队列保持暂停")
            scheduleNextTick()
            return true
        } catch {
            plans = oldPlans; deliveries = oldJobs
            self.error = error.localizedDescription
            return false
        }
    }
    /// 批量取消的撤销窗（对标 Gmail Undo Send/Spark）：取消立即执行（安全操作），8 秒内可原样恢复。
    /// 只保留最近一次的快照——连续两次批量取消，第二次会覆盖第一次的撤销机会。
    struct PendingUndoCancellation {
        let snapshot: [Delivery]
        let label: String
    }
    @Published var pendingUndoCancellation: PendingUndoCancellation?
    private var undoCommitTimer: Timer?

    /// 撤销最近的批量取消：只恢复「仍是 cancelled 且没产生新痕迹」的记录（Core.RecordUndo 口径），
    /// 已被改期/重试/核对的部分如实播报，不静默吞掉。
    func undoLastCancellation() {
        guard let pending = pendingUndoCancellation else { return }
        pendingUndoCancellation = nil
        undoCommitTimer?.invalidate()
        perform {
            let restorable = RecordUndo.restorable(snapshot: pending.snapshot, current: self.deliveries)
            guard !restorable.isEmpty else {
                self.step = "撤销未生效：这些任务已发生变化，请到发送记录查看"
                return
            }
            for original in restorable {
                if let i = self.deliveries.firstIndex(where: { $0.id == original.id }) {
                    self.deliveries[i] = original
                }
            }
            do { try self.persist() } catch {
                self.error = "撤销未能保存：\(error.localizedDescription)"; return
            }
            self.step = "已撤销：\(restorable.count) 条任务恢复待执行"
        }
    }

    private func scheduleUndoCommit() {
        undoCommitTimer?.invalidate()
        undoCommitTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingUndoCancellation = nil }
        }
    }

    func cancelAllQueued(planIDs: Set<String>? = nil) {
        perform {
            let previous = deliveries
            var changed = 0
            var touchedPlans = Set<String>()
            for i in deliveries.indices where deliveries[i].status == "queued" && (planIDs == nil || planIDs!.contains(deliveries[i].planID)) {
                deliveries[i].status = "cancelled"; deliveries[i].detail = SendChannel.cancelledDetail(previous: deliveries[i].detail, note: "用户批量取消，未发送"); deliveries[i].finished = Date(); changed += 1
                touchedPlans.insert(deliveries[i].planID)
            }
            guard changed > 0 else { throw AppError("当前没有待执行任务") }
            // 先快照运行态再落盘：persist 失败时任务回到待执行，队列运行态也必须原样恢复，
            // 否则磁盘是待执行、界面却停在「已暂停」（审计 2026-10-06）。
            runningPlanIDs.subtract(touchedPlans)
            activePlanID = runningPlanIDs.sorted().first
            // 落盘失败回滚全部内存改动：磁盘仍为待执行，界面也回到待执行，队列保持暂停
            do { try persist() } catch {
                deliveries = previous; stop()
                throw error
            }
            step = "已取消 \(changed) 条待执行任务，未发送任何消息"
            // 撤销窗快照：previous 里那些本次从 queued 变成 cancelled 的原样记录
            let cancelledSnapshot = previous.filter { original in
                guard let now = deliveries.first(where: { $0.id == original.id }) else { return false }
                return now.status == "cancelled" && original.status == "queued"
            }
            pendingUndoCancellation = PendingUndoCancellation(
                snapshot: cancelledSnapshot,
                label: "已取消 \(changed) 条待执行任务（不涉及已核对记录）")
            scheduleUndoCommit()
            // 批量取消也可能让某轮全部收尾：取消不是发送完成，此时暂停循环而不是为已发送的群排下一轮
            // （取消路径不走 maybeRecur，上面的 step「已取消 X 条」也不会被循环提示覆盖）
            for planID in touchedPlans.sorted() { suspendRecurringAfterCancel(planID: planID) }
        }
    }

    /// 用户显式取消当前队列：立即停止接续及本计划的在途操作，提交过的记录只收尾核对。
    /// 与暂停不同，下一次开始将建立完整的新一轮，而不是恢复剩余项。
    @discardableResult func cancelQueue(planID: String) -> Bool {
        guard !historyActionBusy, let index = plans.firstIndex(where: { $0.id == planID }) else { return false }
        let previousJobs = deliveries, previousPlans = plans
        stop(planID: planID)
        let now = Date()
        plans[index].queueCancelledAt = now
        for i in deliveries.indices where QueueBatch.contains(deliveries[i], in: plans[index]) && QueueBatch.canDispatch(deliveries[i]) {
            deliveries[i].status = "cancelled"; deliveries[i].finished = now
            deliveries[i].detail = SendChannel.cancelledDetail(previous: deliveries[i].detail, note: "用户取消此队列，后续未执行；重开将另建完整新一轮")
        }
        do {
            try persist()
            pendingUndoCancellation = nil; undoCommitTimer?.invalidate()
            step = "此队列已取消；重新开始会重发整队，包括已发群" + (running ? "；其他队列继续运行" : "")
            return true
        } catch {
            deliveries = previousJobs; plans = previousPlans; self.error = "取消未能保存：\(error.localizedDescription)"
            return false
        }
    }

    /// 核对页的「不发送」仅取消这一条，保留原时间、提交痕迹和核验凭据。
    @discardableResult func declineReviewed(_ reviewed: Delivery) -> Bool {
        guard !historyActionBusy,
              let current = deliveries.first(where: { $0.id == reviewed.id }), current == reviewed,
              ReviewedResend.existingAttempt(sourceID: current.id, jobs: deliveries) == nil,
              current.status != "running", current.status != "verified", current.status != "manual",
              current.status != "cancelled", current.status != "submitted" || processingPlanID != current.planID || !busy else {
            error = "记录正在处理或已变化，请重新查看后选择"; return false
        }
        return mutate(current.id, status: "cancelled", detail: SendChannel.cancelledDetail(previous: current.detail, note: "用户核对后选择不发送，不再自动处理这条"))
    }
    @discardableResult func importFiles(_ urls: [URL]) -> [String] {
        var imported: [String] = []
        // 走查 5-05：调用方（一体化输入框「应用到本次发送」）会读 store.error 判断本次导入结果，
        // 而 error 的语义是「最近一次尚未被消解的错误」，不是本次操作的返回值——进入时先清掉陈旧值，
        // 真失败时下面的 perform 仍会写入真实原因。
        error = nil
        perform {
            let before = assets
            // 走查 1-22：记下本次真正复制出去的素材目录，任何一步失败都连磁盘一起回滚，不留孤儿目录
            var created: [URL] = []
            do {
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let hash = try Database.digest(url)
                    if let existing = assets.first(where:{$0.sha256 == hash && $0.name == url.lastPathComponent}) { imported.append(existing.id); continue }
                    let asset = try db.importAsset(url, precomputedDigest: hash)   // 走查 1-22：复用上面算好的哈希，不再整文件哈希第二遍
                    created.append(db.url(for: asset).deletingLastPathComponent())
                    assets.append(asset)
                    imported.append(asset.id)
                }
                // 循环内只改内存，循环外一次整库落盘
                try persist()
            } catch {
                assets = before; imported.removeAll()
                for dir in created { try? FileManager.default.removeItem(at: dir) }
                throw error
            }
            step = "素材已复制到本机资料库"
        }
        return imported
    }
    @discardableResult func chooseFiles(imagesOnly: Bool = false) -> [String] {
        let panel = NSOpenPanel(); panel.title = imagesOnly ? "添加本次配图" : "导入图片或文件"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if imagesOnly { panel.allowedContentTypes = [.image] }
        if panel.runModal() == .OK { return importFiles(panel.urls) }
        return []
    }
    /// 删除素材：被计划或未完成任务引用时拒绝，防止发送时缺图；
    /// 已发送任务内嵌的是元数据副本，本机文件删除后其“复制图片”会失效（详情文字仍保留）
    func deleteAsset(_ id: String) {
        perform {
            if let plan = plans.first(where: { $0.assetIDs.contains(id) }) {
                throw AppError("素材正被计划「\(plan.name)」使用，请先在该计划里移除这张配图，再删除素材")
            }
            if let job = deliveries.first(where: { ["queued","running","draft","uncertain","blocked","submitted"].contains($0.status) && $0.assets.contains { $0.id == id } }) {
                throw AppError("素材属于待执行任务「\(job.recipient)」，暂时不能删除；可先取消该任务或等队列结束")
            }
            guard let asset = assets.first(where: { $0.id == id }) else { return }
            assets.removeAll { $0.id == id }
            // 同步清掉群发空间草稿里的引用，避免留下选了已删素材的死 id
            if settings.broadcastWorkspaces != nil {
                for i in settings.broadcastWorkspaces!.indices {
                    settings.broadcastWorkspaces![i].draft.assetIDs.removeAll { $0 == id }
                }
            }
            do {
                try persist()
                try? FileManager.default.removeItem(at: db.url(for: asset).deletingLastPathComponent())
            } catch { assets.append(asset); throw error }
            step = "素材已删除；已发送任务的详情文字仍保留，但无法再复制这张图片"
        }
    }
    /// 重命名素材：磁盘文件与 relativePath 同步改名；全部任务内嵌的素材副本一并更新，
    /// 保证待执行任务发送时路径有效、历史任务的复制按钮不失效。persist 失败回滚改名。
    func renameAsset(_ id: String, to rawName: String) {
        perform {
            guard !busy else { throw AppError("当前群处理中，请稍后再重命名素材") }
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError("素材名称不能为空") }
            guard !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("%") else { throw AppError("名称不能包含 / : % 字符") }
            guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
            let asset = assets[i]
            let ext = (asset.name as NSString).pathExtension
            var finalName = trimmed
            if !ext.isEmpty, (finalName as NSString).pathExtension.lowercased() != ext.lowercased() {
                finalName += "." + ext
            }
            guard finalName != asset.name else { return }
            let newRelative = (asset.relativePath as NSString).deletingLastPathComponent.appending("/").appending(finalName)
            let oldURL = db.url(for: asset)
            let newURL = db.root.appendingPathComponent(newRelative)
            guard !FileManager.default.fileExists(atPath: newURL.path) else { throw AppError("素材库已有同名文件「\(finalName)」") }
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let oldName = assets[i].name
            let oldRelative = assets[i].relativePath
            let oldDeliveries = deliveries
            assets[i].name = finalName
            assets[i].relativePath = newRelative
            for j in deliveries.indices {
                if let k = deliveries[j].assets.firstIndex(where: { $0.id == id }) {
                    deliveries[j].assets[k].name = finalName
                    deliveries[j].assets[k].relativePath = newRelative
                }
            }
            do { try persist() }
            catch {
                try? FileManager.default.moveItem(at: newURL, to: oldURL)
                assets[i].name = oldName
                assets[i].relativePath = oldRelative
                deliveries = oldDeliveries
                throw error
            }
            step = "已重命名为「\(finalName)」"
        }
    }
    func addPlan(_ plan: Plan) throws {
        guard guardMembership() else { throw AppError(memberGateMessage) }   // 会员门禁：只挡新计划
        // 错峰抖动同时覆盖新排与重启两条路径（设置项承诺的就是两处）；expand 的抖动只在
        // 落盘前生效一次，写入值即运行值（jittered 单向上浮，不会再被运行期冷却钳动）。
        let jobs = try Scheduling.expand(plan,recipients:recipients,assets:assets,jitter:settings.staggerJitter ?? false)
        for pair in zip(jobs,jobs.dropFirst()) {
            guard pair.1.scheduled.timeIntervalSince(pair.0.scheduled) >= Double(settings.globalGapMinutes * 60) - 1 else { throw AppError("部分群间隔小于全局最小间隔 \(settings.globalGapMinutes) 分钟，请调整") }
        }
        guard deliveries.count + jobs.count <= 10000 else { throw AppError("队列超过 10000 条，请缩短计划") }
        let duplicate = jobs.contains { job in deliveries.contains { old in old.status != "cancelled" && old.recipient == job.recipient && abs(old.scheduled.timeIntervalSince(job.scheduled)) < 60 } }
        guard !duplicate else { throw AppError("同一收件人在这个时间已有任务，请到发送记录查看，避免重复创建") }
        var plan = plan
        guard let spaceIndex = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == (plan.workspaceID ?? workspaceID) }) else {
            throw AppError("群发空间不存在")
        }
        let beforeSettings = settings, beforePlans = plans, beforeJobs = deliveries
        // 新队列模板、计划、任务与草稿一次提交；不通过共享模板的全库同步路径。
        let template = TextTemplate(text: plan.text, assetIDs: plan.assetIDs, ownerPlanID: plan.id)
        plan.textTemplateID = template.id
        settings.broadcastWorkspaces?[spaceIndex].templates.append(template)
        settings.broadcastWorkspaces?[spaceIndex].draft.selectedTemplateID = template.id
        settings.broadcastWorkspaces?[spaceIndex].draft.text = plan.text
        if (plan.workspaceID ?? workspaceID) == workspaceID {
            settings.textTemplates = settings.broadcastWorkspaces?[spaceIndex].templates
        }
        cancelScheduledDraftPersist()
        plans.append(plan); deliveries.append(contentsOf:jobs)
        settings.savedText = plan.text
        // 计划、任务与 savedText 合并为一次整库落盘；失败整体回滚（含空间草稿），界面与磁盘一致
        do { try persist() } catch {
            settings = beforeSettings; plans = beforePlans; deliveries = beforeJobs
            throw error
        }
        chosenPlanID = plan.id
        route = "queue"; step = QueueStartGate.createdStep(count: jobs.count, statuses: deliveries.map(\.status))
    }

    /// 新建独立队列进入编排页；复制当前草稿供编辑，不启动发送、不修改已有任务。
    func beginNewQueue() {
        guard let space = workspaces.first(where: { $0.id == workspaceID }) else { return }
        var draft = space.draft
        var number = plans.count + 1
        while plans.contains(where: { $0.name == "发送队列 \(number)" || $0.name == "【\(workspaceName)】发送队列 \(number)" }) { number += 1 }
        draft.name = "发送队列 \(number)"; draft.selectedTemplateID = nil
        draft.starts = Date(timeIntervalSince1970: ceil(Date().addingTimeInterval(60).timeIntervalSince1970 / 60) * 60)
        saveDraft(draft, workspaceID: workspaceID)
        chosenPlanID = ""; route = "compose"
    }

    /// 清空当前范围的历史。先在后台备份快照，再只改可见标记；当前队列进度及提交证据不变。
    func clearHistory(planIDs: Set<String>) {
        guard !historyActionBusy else { return }
        let ids = Set(deliveries.filter { planIDs.contains($0.planID) && $0.historyClearedAt == nil && HistoryArchive.canClear($0) }.map(\.id))
        guard !ids.isEmpty else { historyNotice = "没有可清空的发送记录"; return }
        let snapshot = HistoryArchive.snapshot(jobs: deliveries, ids: ids, at: Date())
        let folder = db.root.appendingPathComponent("history-archives", isDirectory: true)
        historyActionBusy = true; historyNotice = "正在保存可恢复备份…"
        Task { @MainActor in
            defer { historyActionBusy = false }
            do {
                _ = try await Task.detached(priority: .utility) { try HistoryArchive.writeBackup(snapshot, to: folder) }.value
                // 备份期间其他队列/人工核对可以继续。用当前记录重新检查，绝不覆盖最新状态。
                let previous = deliveries
                let originals = Dictionary(snapshot.deliveries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let unchangedIDs = Set(deliveries.filter { ids.contains($0.id) && originals[$0.id] == $0 }.map(\.id))
                deliveries = HistoryArchive.cleared(jobs: deliveries, ids: unchangedIDs, at: snapshot.createdAt)
                let count = zip(previous, deliveries).filter { $0.historyClearedAt != $1.historyClearedAt }.count
                do { try persist() } catch { deliveries = previous; throw error }
                historyNotice = "已清空 \(count) 条记录，可点「恢复已清空」找回；待发任务不受影响"
                    + (unchangedIDs.count < ids.count ? "；\(ids.count - unchangedIDs.count) 条已变化记录保留" : "")
            } catch { self.error = "清空记录失败：\(error.localizedDescription)"; historyNotice = nil }
        }
    }
    func restoreHistory(planIDs: Set<String>) {
        guard !historyActionBusy else { return }
        let ids = Set(deliveries.filter { planIDs.contains($0.planID) && $0.historyClearedAt != nil }.map(\.id))
        guard !ids.isEmpty else { return }
        let previous = deliveries
        deliveries = HistoryArchive.restored(jobs: deliveries, ids: ids)
        do { try persist(); historyNotice = "已恢复 \(ids.count) 条发送记录" }
        catch { deliveries = previous; self.error = "恢复记录失败：\(error.localizedDescription)" }
    }

    /// 新排期开始前清理上一排期的记录。旧兼容入口；编排页不再自动调用它。
    /// 红线：任何路径都不得在用户未确认的情况下删除 uncertain/submitted 记录——
    /// 本方法只做转发与落盘，不自行决定保留口径；running/submitted 等任何情况下必须保留的
    /// 状态由 Core 的 RecordPurge.plan 把关（kept 返回保留后的完整数组）。
    /// persist 失败时整体回滚（照抄 addPlan / syncUnsentAssets 的既有写法），界面与磁盘不分叉。
    func purgePreviousPlanRecords(keepingPlanID: String, includePendingReview: Bool) {
        perform {
            let outcome = RecordPurge.plan(all: deliveries, keepingPlanID: keepingPlanID,
                                           includePendingReview: includePendingReview, now: Date())
            // 没清掉任何东西就不动库、不刷 step，避免出现「已清空 0 条」这种没意义的话
            guard outcome.purged > 0 || outcome.purgedPendingReview > 0 else { return }
            let previous = deliveries
            deliveries = outcome.kept
            do { try persist() } catch {
                deliveries = previous
                throw error
            }
            if includePendingReview {
                step = outcome.purgedPendingReview > 0
                    ? "已清空 \(outcome.purged) 条上一排期记录（含 \(outcome.purgedPendingReview) 条待核对）"
                    : "已清空 \(outcome.purged) 条上一排期记录"
            } else {
                step = "已清空 \(outcome.purged) 条上一排期记录；待核对记录已保留"
            }
        }
    }

    /// 清旧记录 + 建新计划，一步完成且原子（GUI 走查 2026-10-06 发现的边界：
    /// 先清后建分开做时，若建计划失败——最常见是开始时间又过期了——旧记录已经被清掉，
    /// 用户两头落空。这里把两步放进同一个回滚单元：建失败就把旧记录原样还原再报错。
    /// step 最后拼成一句「已清空 N 条…；已创建…」，清理结果不再被建计划的文案覆盖。
    func purgeThenCreate(plan: Plan, start: Bool, includePendingReview: Bool) {
        perform {
            let before = deliveries
            let outcome = RecordPurge.plan(all: deliveries, keepingPlanID: plan.id,
                                           includePendingReview: includePendingReview, now: Date())
            var purgedNote: String?
            if outcome.purged > 0 || outcome.purgedPendingReview > 0 {
                deliveries = outcome.kept
                purgedNote = "已清空 \(outcome.purged) 条上一排期记录"
                    + (outcome.purgedPendingReview > 0 ? "（含 \(outcome.purgedPendingReview) 条待核对）" : "")
            }
            do {
                if start { try addAndStart(plan) } else { try addPlan(plan) }
            } catch {
                deliveries = before   // 建失败：旧记录原样奉还，用户不至于两头落空
                throw error
            }
            if let purgedNote { step = purgedNote + "；" + step }
        }
    }
    /// immediate=true（人工点启动）时第一条立即执行，后续按本次保存的间隔计时；
    /// immediate=false（创建并启动本计划）按计划里选定的开始时间执行。
    /// 无人值守时队列继续按时刻表与全局间隔运行。
    /// UI 走查探针的最后一道保险：设了 QQ_DISPATCH_NO_SEND 环境变量时，一切会驱动
    /// 真实 QQ/微信的入口直接拦截。正式运行不设这个变量，零影响。
    /// 入口清单与拦截文案统一收在 `DispatchProbe.drivenEntries`（Core.swift）——
    /// **新增任何发送/驱动入口时先看那份清单，在入口开头调用 `DispatchProbe.refusal(entry:)`**，
    /// 否则就会重演走查 1-09：「按已核对草稿续发」不走 execute，绕过了最内层兜底。
    private var sendKillSwitch: Bool {
        #if RENDER_HARNESS
        if isolatedDispatchDriver != nil { return false }
        #endif
        return DispatchProbe.isActive
    }
    private var dispatchPermissionGranted: Bool {
        #if RENDER_HARNESS
        if isolatedDispatchDriver != nil { return true }
        #endif
        return QQDriver.trusted && WeChatDriver.trusted
    }

    /// 只启动当前明确选择的计划；未选择时钉住实际下一条的计划，不能串入历史或其他计划。
    func queueStartPlanID(requested: String?) -> String? {
        if let requested { return requested }
        return displayedQueuePlanID
    }

    func start(planID: String? = nil, immediate: Bool = true, expectedDeliveryID: String? = nil, limit: Int? = nil) {
        if sendKillSwitch, let refusal = DispatchProbe.refusal(entry: "启动队列") { step = refusal; return }
        guard guardMembership() else { return }   // 会员门禁：不打断运行中的队列，只挡新启动
        // 走查 1-04：群名检索/导入正在驱动 QQ 时不能同时启动发送
        guard !importingList else { error = "正在读取群聊，结束后再启动队列"; return }
        // 双驱动都查（今天底层同为进程级 AXIsProcessTrusted，取值恒等；未来若拆分各自权限，这里仍然诚实）
        guard dispatchPermissionGranted else { error = "辅助功能权限尚未生效（QQ/微信共用同一授权），请到设置检查；任务保持待执行"; route = "settings"; return }
        guard let scope = queueStartPlanID(requested: planID), !isQueueRunning(scope),
              let planIndex = plans.firstIndex(where: { $0.id == scope }) else {
            error = "当前计划没有可自动执行的待发群；待核对记录保留在发送记录里"; return
        }
        if let limit, !(1...10000).contains(limit) { error = "本次发送条数需在 1 到 10000 之间"; return }
        guard !immediate || !busy else { error = "当前 QQ 操作结束后可以立即开始；现在可按排期启动此队列"; return }
        let oldPlans = plans, oldJobs = deliveries
        let isReplay = plans[planIndex].queueCancelledAt != nil
        guard !isReplay || immediate else { error = "此队列已取消，点“重新发送整条队列”开始新一轮"; return }
        let now = Date()
        do {
            var preparedPlans = plans, preparedJobs = deliveries
            if isReplay {
                let replay = try QueueBatch.replay(plans[planIndex], jobs: deliveries, at: now,
                                                  gap: settings.globalGapMinutes, jitter: settings.staggerJitter ?? false)
                preparedPlans[planIndex] = replay.0; preparedJobs += replay.1
            }
            let current = QueueBatch.jobs(in: preparedPlans[planIndex], from: preparedJobs).filter(QueueBatch.canDispatch)
            let ids = Set(current.map(\.id))
            guard let intended = MultiQueueScheduling.nextCandidate(jobs: preparedJobs, activePlanIDs: [scope],
                          gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan, allowedDeliveryIDs: ids) else {
                throw AppError("当前计划没有可自动执行的待发群；待核对记录保留在发送记录里")
            }
            if let expectedDeliveryID, !isReplay, expectedDeliveryID != intended.id {
                throw AppError("待发群顺序已变化，请查看当前“下一群”后再启动")
            }
            if immediate {
                let restarted = Scheduling.restarted(current, planID: scope, now: now, gap: settings.globalGapMinutes,
                                                      intervalByPlan: intervalByPlan, compressFuture: true,
                                                      jitter: settings.staggerJitter ?? false)
                let replacements = Dictionary(uniqueKeysWithValues: restarted.map { ($0.id, $0) })
                preparedJobs = preparedJobs.map { replacements[$0.id] ?? $0 }
            }
            let ordered = preparedJobs.enumerated().filter { ids.contains($0.element.id) }.sorted {
                $0.element.scheduled == $1.element.scheduled ? $0.offset < $1.offset : $0.element.scheduled < $1.element.scheduled
            }.map(\.element)
            guard let first = ordered.first, first.id == intended.id else {
                throw AppError("立即开始后的首群与预览不一致，已停止启动，请重新查看队列")
            }
            preparedPlans[planIndex].sendLimit = limit
            plans = preparedPlans; deliveries = preparedJobs
            try persist()
            if let limit { runSelection[scope] = Set(ordered.prefix(limit).map(\.id)) }
            else { runSelection.removeValue(forKey: scope) }
            activePlanID = scope; runningPlanIDs.insert(scope); error = nil
            pendingUndoCancellation = nil; undoCommitTimer?.invalidate()
            step = immediate ? "立即开始：首群「\(first.recipient)」；后续从本次发送起按间隔顺延"
                             : "本队列已启动，到时自动依次发送；故障群记入发送记录后跳过"
            if !busy { appendChannelAppHintIfMissing(planID: scope) }
            if immediate { execute(first) } else { tick() }
        } catch {
            plans = oldPlans; deliveries = oldJobs; self.error = error.localizedDescription
        }
    }
    /// 走查 2026-10-06：启动后按聊天 App 是否在运行给三态提示（都拼在 step 后面，不拦截启动——
    /// 发送时会自动唤起）。未运行→提醒会自动唤起并要求已登录解锁；在运行→明说在运行，让用户放心。
    func appendChannelAppHintIfMissing(planID: String?) {
        guard let channel = nextDelivery(planID: planID)?.channelName else { return }
        let bundleID = channel == SendChannel.wechat ? FocusRestore.weChatBundleID : FocusRestore.qqBundleID
        let name = SendChannel.displayName(channel)
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            step += "；\(name)未在运行，发送时会自动唤起，请确保其已登录并解锁"
        } else {
            step += "；\(name)在运行 ✓"
        }
    }

    func addAndStart(_ plan: Plan) throws {
        if sendKillSwitch { throw AppError("探针模式：已拦截「创建并启动」；不会打开 QQ 或微信") }
        guard !busy else { throw AppError("当前操作结束后即可创建并启动新队列；现在可以预览") }
        guard !importingList else { throw AppError("正在读取或验证群名，等它结束后再创建并启动") }   // 走查 1-04
        guard dispatchPermissionGranted else { throw AppError("请先到设置授权辅助功能，再创建并启动；也可以先仅保存排期") }
        try addPlan(plan)
        start(planID:plan.id, immediate:false)   // 新计划按用户选定的开始时间，不提前
    }
    func stop() { running = false; activePlanID = nil; runSelection = [:]; driver.cancelled = true; wechatDriver.cancelled = true; task?.cancel(); step = "全部队列已暂停" }
    /// 只暂停所选队列；正在操作其他队列时不取消它的驱动和 task。
    func stop(planID: String) {
        runningPlanIDs.remove(planID)
        runSelection.removeValue(forKey: planID)
        activePlanID = runningPlanIDs.sorted().first
        if processingPlanID == planID {
            driver.cancelled = true; wechatDriver.cancelled = true; task?.cancel()
        }
        if !busy { step = running ? "此队列已暂停；其他队列继续运行" : "队列已暂停" }
        scheduleNextTick()
    }
    private func settleStoppedQueue(_ planID: String) {
        runningPlanIDs.remove(planID)
        runSelection.removeValue(forKey: planID)
        activePlanID = runningPlanIDs.sorted().first
    }

    /// 走查 5-01：菜单栏「退出」按钮的动作。真正的门禁在 `AppDelegate.applicationShouldTerminate`，
    /// 这里只发起一次标准终止流程，让 ⌘Q、应用菜单「退出」和这颗按钮共用同一道闸——
    /// 只补按钮会漏掉另外两条退出路径。
    func requestExit() { NSApp.terminate(nil) }

    /// 标准退出立即暂停全部，等待在途记录收尾；不弹确认窗，也不清理提交凭据。
    func requestExitConfirmation(_ completion: @escaping (Bool) -> Void) {
        stop()
        flushDraftPersist()
        let deadline = Date().addingTimeInterval(Self.exitSettleBudget)
        Task { @MainActor in
            while self.busy, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            completion(true)
        }
    }
    /// 走查 5-01：退出前给在途任务留的收尾窗口上限（秒）。只等，不催，更不拦。
    private static let exitSettleBudget: TimeInterval = 2

    @discardableResult func sendSingle(_ id: String) -> Bool {
        if sendKillSwitch { step = "探针模式：已拦截「发送此条」；不会打开 QQ 或微信"; return false }
        guard guardMembership() else { return false }
        guard !busy, !importingList, !historyActionBusy,
              let index = deliveries.firstIndex(where:{$0.id == id && $0.status == "queued"}) else { return false }
        guard deliveries[index].canSendImmediately else {
            error = "这条任务已有执行或提交痕迹，请到发送记录核对，不会重复执行"; return false
        }
        // Explicit one-job action: retain the immutable message and recipient; never start the timer queue.
        let old = deliveries[index]
        deliveries[index].mode = "automatic"; deliveries[index].scheduled = Date()
        do { try persist() } catch { deliveries[index] = old; self.error = error.localizedDescription; return false }
        execute(deliveries[index])
        return busy
    }

    /// 显式重发只占用全局串行通道；不启动、暂停或重排任何其他队列。
    @discardableResult
    func resendReviewed(_ reviewed: Delivery, confirmedUnsent: Bool, confirmedDraftCleared: Bool) -> Bool {
        if sendKillSwitch, let refusal = DispatchProbe.refusal(entry: "人工核对后重新发送") {
            step = refusal; error = refusal; return false
        }
        guard guardMembership() else { return false }
        guard !busy, !importingList, !historyActionBusy else {
            error = "有任务正在处理，请等它结束后重新发送"; return false
        }
        guard confirmedUnsent, confirmedDraftCleared else {
            error = "请先在\(SendChannel.displayName(reviewed.channelName))核对未成功发出，并清空输入框草稿"; return false
        }
        guard let source = deliveries.first(where: { $0.id == reviewed.id }), source == reviewed else {
            error = "这条记录已变化，请重新打开详情核对后再发送"; return false
        }
        do {
            let now = Date()
            let attempt = try ReviewedResend.attempt(from: source, jobs: deliveries, at: now)
            deliveries.append(attempt)
            do { try persist() } catch {
                deliveries.removeAll { $0.id == attempt.id }
                throw error
            }
            error = nil
            step = "\(source.recipient)：人工核对后重新发送，仅处理此条"
            execute(attempt)
            return busy
        } catch {
            self.error = "重新发送未能开始：\(error.localizedDescription)"; return false
        }
    }
    // Source inbox actions never add recipients/plans/deliveries or resume a queue.
    @discardableResult
    func handleRelationshipURL(_ url: URL) -> Bool {
        guard RelationshipInbox.acceptsWakeURL(url) else { return false }
        route = "recipients"
        orderChannel = SendChannel.wechat
        relationshipInbox.refresh()
        return true
    }
    func openRelationshipContact(_ contactID: String, sourceID: String) {
        if sendKillSwitch { step = "探针模式：已拦截「打开微信聊天」"; return }
        guard !busy, !running, !importingList else {
            error = "请先暂停队列，并等待当前操作结束，再打开微信聊天"
            return
        }
        guard guardMembership() else { return }
        busy = true
        operationAppName = "微信"
        step = "正在定位微信聊天；发送由你手动完成"
        task = Task {
            defer { busy = false; task = nil }
            do {
                step = try await relationshipInbox.open(contactID: contactID, expectedSourceID: sourceID, queueBusy: false, navigator: relationshipNavigator)
            } catch { step = error.localizedDescription; self.error = step }
        }
    }

    func tryQQ(_ recipient: String? = nil, channel: String = SendChannel.qq) {
        if sendKillSwitch { step = "探针模式：已拦截「打开 QQ/微信」；真实渠道未被触碰"; return }
        guard guardMembership() else { return }   // 会员门禁
        guard !busy, !importingList else {
            if importingList { error = "正在读取或验证群名，等它结束后再试跑" }   // 走查 1-04：同一个 QQ、同一个 task 句柄
            return
        }
        running = false; busy = true
        operationAppName = SendChannel.displayName(channel)
        let isWeChat = channel == SendChannel.wechat
        error = nil
        step = recipient == nil ? (isWeChat ? "正在打开微信" : "正在打开 QQ") : "开始试跑；不会填写或发送消息"
        task = Task {
            do {
                if isWeChat {
                    if let recipient { step = try await wechatDriver.probe(recipient) }
                    else { try await wechatDriver.openWeChat(); step = "微信已打开；如未登录请先登录" }
                } else {
                    if let recipient { step = try await driver.probe(recipient) }
                    else { try await driver.openQQ(); step = "QQ 已打开；如显示登录页面，请手动登录" }
                }
                if isWeChat { wechatDiagnostic = step } else { qqDiagnostic = step }
            } catch is CancellationError {
                step = recipient == nil ? "打开操作已停止" : "试跑已停止；未填写草稿、未发送消息"
                if isWeChat { wechatDiagnostic = step } else { qqDiagnostic = step }
                self.error = nil
            } catch {
                step = error.localizedDescription
                if isWeChat { wechatDiagnostic = step } else { qqDiagnostic = step }
                self.error = step
            }
            busy = false; task = nil
        }
    }
    func tick() {
        guard running && !busy, !importingList else { return }
        // 单队列旧测试/入口的兼容转换，不将未启动队列纳入派发。
        if runningPlanIDs.isEmpty, let id = activePlanID ?? queueStartPlanID(requested: nil) { runningPlanIDs = [id] }
        let finishedIDs = runningPlanIDs.filter { nextDelivery(planID: $0) == nil }
        for id in finishedIDs.sorted() {
            settleStoppedQueue(id)
        }
        guard !runningPlanIDs.isEmpty else {
            running = false; activePlanID = nil
            step = "已启动队列的待发群已处理完；未确认与拦截记录可稍后在发送记录手动处理"
            return
        }
        guard let job = MultiQueueScheduling.eligible(jobs: deliveries, activePlanIDs: runningPlanIDs,
                       now: Date(), gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan,
                       allowedDeliveryIDs: dispatchableIDs) else {
            if let next = nextDelivery {
                let appName = SendChannel.displayName(next.channelName)
                if operationAppName != appName { operationAppName = appName }
                let explanation = timingExplanation(next)
                if step != explanation { step = explanation }
            }
            return
        }
        execute(job)
    }
    /// 生产启动和隔离集成测试共用这一入口；单次计时器每拍结束后重新排下一拍。
    func startDispatchHeartbeat() {
        guard dispatchSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tick()
                self.scheduleNextTick()
            }
        }
        dispatchSource = source
        source.schedule(deadline: .now() + 1, repeating: .infinity)
        // DispatchSource 初始为挂起态；只 schedule 不 activate 时永远不会回调。
        source.activate()
    }
    /// 计算并重排下一次调度心跳的间隔：运行中或 busy → 1 秒；空闲时若能算出下一个待执行
    /// 任务的最早到期时间（nextCandidate + earliestSendDate，与 tick 同参）→
    /// min(max(到期秒数 + 0.5, 1), 15) 秒；算不出 → 15 秒。空转早退仍在 tick 内，这里只管唤醒节奏。
    private func scheduleNextTick() {
        guard let source = dispatchSource else { return }
        let interval: TimeInterval
        if running || busy {
            interval = 1
        } else if let next = Scheduling.nextCandidate(deliveries, gap: settings.globalGapMinutes, planID: activePlanID, intervalByPlan: intervalByPlan) {
            let due = earliestSendDate(next)
            interval = min(max(due.timeIntervalSinceNow + 0.5, 1), 15)
        } else {
            interval = 15
        }
        source.schedule(deadline: .now() + interval, repeating: .infinity)
    }
    func execute(_ job: Delivery) {
        if sendKillSwitch { running = false; step = "探针模式：已拦截任务执行；不会打开 QQ 或微信"; return }
        // busy 是驱动遍历期间唯一防止重入的守卫（走查 2-30）：整条 AX 链路跑完才复位，
        // 期间 tick / sendSingle / tryQQ / 导入 全部靠它串行化；再叠加 importingList 挡住群名检索（1-04）。
        guard !busy, !importingList, let i = deliveries.firstIndex(where:{$0.id == job.id && $0.status == "queued"
            && $0.canSendImmediately && $0 == job}) else { return }
        let previousApp = NSWorkspace.shared.frontmostApplication
        operationAppName = SendChannel.displayName(job.channelName)
        busy = true; processingPlanID = job.planID; deliveries[i].status = "running"; deliveries[i].started = Date()
        // 走查 1-05 / 1-08 交接（fixes-B 第 1-05 条第 2 点）：一条被重新入队 / 重新排期的记录，
        // detail 里存着「上次卡在哪一步」。原先这里整串覆盖成「处理前已写入数据库」，
        // 会话绑定差异那类说明就被第二次尝试抹掉了。改为追加（AGENTS.md 第 9 行）。
        deliveries[i].detail = SendChannel.keptRecord(note: "处理前已写入数据库", previous: deliveries[i].detail)
        do { try persist() } catch {
            deliveries[i].status = job.status; deliveries[i].started = job.started; deliveries[i].detail = job.detail
            self.error = "任务未能开始：\(error.localizedDescription)"; running = false; activePlanID = nil; busy = false; processingPlanID = nil; return
        }
        if !job.isOneOff, runSelection[job.planID] != nil { runSelection[job.planID]?.remove(job.id) }
        let activeDriver: any ChatDriver
        #if RENDER_HARNESS
        activeDriver = isolatedDispatchDriver ?? driverFor(job.channelName)
        #else
        activeDriver = driverFor(job.channelName)
        #endif
        var checkpointSaveFailed = false
        activeDriver.beforeSubmit = { [weak self] in
            guard let self, let index = self.deliveries.firstIndex(where:{$0.id == job.id}) else { throw AppError("任务不存在") }
            try Task.checkCancellation()
            let previous = self.deliveries[index]
            // 走查 1-08：检查点同样是追加——按下发送键这件事要留痕，不能把之前的过程说明换掉。
            self.deliveries[index].status = "submitted"
            self.deliveries[index].detail = SendChannel.keptRecord(note: "发送按键前检查点；异常退出须人工核对", previous: self.deliveries[index].detail)
            if self.deliveries[index].submittedAt == nil { self.deliveries[index].submittedAt = Date() }
            do { try self.persist() } catch {
                self.deliveries[index] = previous
                checkpointSaveFailed = true
                self.running = false; self.activePlanID = nil
                self.error = SendChannel.saveFailure(channel: job.channelName, reason: error.localizedDescription)
                throw error
            }
        }
        if settings.minimizeAfterSuccess != false { presentationEffects.showScheduler() }
        task = Task {
            defer {
                activeDriver.beforeSubmit = {}
                busy = false; processingPlanID = nil; task = nil
                if !job.isOneOff, isQueueRunning(job.planID), runSelection[job.planID]?.isEmpty == true {
                    settleStoppedQueue(job.planID)
                    step = "本次指定条数已处理，剩余任务保持暂停" + (running ? "；其他队列继续运行" : "")
                }
                scheduleNextTick()
            }
            do {
                try Task.checkCancellation()
                let result = try await activeDriver.run(job,root:db.root)
                let resultStatus = ["verified", "blocked", "uncertain", "draft"].contains(result.0) ? result.0 : "uncertain"
                let resultDetail = resultStatus == result.0 ? result.1 : "驱动返回了不能作为自动结果的状态「\(result.0)」，保留为待核对。\(result.1)"
                // 走查 1-05 / 1-08 交接：驱动正常返回 blocked / uncertain（不抛错）时也不能抹掉过程说明。
                let saved = mutate(job.id, status: resultStatus, detail: outcomeDetail(status: resultStatus, detail: resultDetail,
                                                                      previous: deliveries.first(where: { $0.id == job.id })?.detail ?? ""), qqVerification: activeDriver.verificationEvidence)
                let outcome = saved ? (deliveries.first(where: { $0.id == job.id })?.status ?? "uncertain") : "uncertain"
                // 任务已有结果（成功或未确认）：撤下它的「即将发送」预告，通知中心不留过时信息
                removeUpcomingAnnouncement(jobID: job.id)
                // 保存失败、用户明确暂停仍停止；普通未确认或拦截只结束本群，下一拍执行同计划下一条。
                if checkpointSaveFailed { running = false; activePlanID = nil }
                else if Task.isCancelled || activeDriver.cancelled { settleStoppedQueue(job.planID) }
                if saved {
                    step = outcome == "verified" ? "\(job.recipient)：界面核验通过"
                        : skippedOutcomeNote(recipient: job.recipient, status: outcome)
                }
                await returnAfterSuccessfulSend(job: job, verified: saved && outcome == "verified", driver: activeDriver, previousApp: previousApp)
            } catch {
                let current = deliveries.first(where:{$0.id == job.id})
                let wasSubmitted = current?.submittedAt != nil || current?.status == "submitted"
                let explicitlyStopped = Task.isCancelled || activeDriver.cancelled || error is CancellationError || PausePoint.isStop(error.localizedDescription)
                // 走查 1-05 / 1-08：驱动侧的会话绑定差异（bindingDivergence）等说明落在这条记录里，
                // 追加而不是覆盖，保留上一次执行到哪一步（AGENTS.md 第 9 行）。
                let saved = mutate(job.id,status:wasSubmitted ? "uncertain" : "blocked",
                       detail:SendChannel.keptRecord(note: "步骤：\(step)\n\(error.localizedDescription)", previous: current?.detail ?? ""))
                removeUpcomingAnnouncement(jobID: job.id)
                if checkpointSaveFailed || !saved {
                    running = false; activePlanID = nil
                    if saved { step = "全部队列已暂停：\(error.localizedDescription)" }
                } else if explicitlyStopped {
                    settleStoppedQueue(job.planID)
                    step = "此队列已暂停：\(error.localizedDescription)" + (running ? "；其他队列继续运行" : "")
                } else {
                    step = skippedOutcomeNote(recipient: job.recipient, status: wasSubmitted ? "uncertain" : "blocked")
                    await returnAfterSuccessfulSend(job: job, verified: false, driver: activeDriver, previousApp: previousApp)
                }
            }
        }
    }
    private func skippedOutcomeNote(recipient: String, status: String) -> String {
        let outcome = status == "blocked" ? "已拦截" : (status == "draft" ? "草稿待处理" : "待核对")
        return "\(recipient)：\(outcome)，已记入发送记录，不自动重发；" + (running ? "跳过本群，继续当前计划下一群" : "队列保持暂停")
    }
    private func removeUpcomingAnnouncement(jobID: String) {}
    private func returnAfterSuccessfulSend(job: Delivery, verified: Bool, driver: any ChatDriver, previousApp: NSRunningApplication? = nil) async {
        guard !driver.cancelled, !Task.isCancelled,
              let completed = deliveries.first(where: { $0.id == job.id }) else { return }
        if !verified {
            guard ["blocked", "uncertain", "draft"].contains(completed.status), settings.minimizeAfterSuccess != false,
                  presentationEffects.mayMinimizeAfterFailure(channel: job.channelName) else { return }
            // 故障只记录，不播成功音。界面仍由本软件或聊天客户端占用时也收窗，
            // 用户已暂停、切走或正在处理保存故障时保留现场。
            if let issue = await presentationEffects.minimizeWindows(channel: job.channelName) { step += "；\(issue)" }
            return
        }
        guard completed.status == "verified",
              completed.channelName != SendChannel.qq || completed.qqVerification?.isValid(for: completed) == true else { return }
        let locked = job.channelName == SendChannel.wechat ? WeChatDriver.locked : QQDriver.locked
        guard !locked else { return }
        if settings.successSoundEnabled != false, !presentationEffects.playSuccessSound() {
            step += "；成功提示音未能播放"
        }
        if settings.minimizeAfterSuccess != false {
            if let issue = await presentationEffects.minimizeWindows(channel: job.channelName) { step += "；\(issue)" }
            return  // 成功收窗优先，不能再被旧的自动返回逻辑展开。
        }
        let returnToScheduler = settings.returnToSchedulerAfterSend ?? true
        let destination = returnToScheduler ? NSRunningApplication.current : previousApp
        if FocusRestore.shouldRestore(verified: verified, enabled: returnToScheduler || (settings.restorePreviousApp ?? true),
                                      cancelled: driver.cancelled, locked: locked,
                                      frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                      previousBundleID: destination?.bundleIdentifier,
                                      targetBundleID: FocusRestore.targetBundleID(channel: job.channelName)),
           let destination, !destination.isTerminated {
            _ = destination.activate(options: [])
            if returnToScheduler {
                // 走查 5-02：窗口对象还在（关闭 / 最小化 / 被压在 QQ 后面）就直接唤起；
                // 真取不到时才发通知，由常驻监听者（Store 自己 + MenuBarExtra 标题视图的 openWindow）补开窗口。
                if !bringMainWindowForward() { requestMainWindow() }
            }
        }
    }

    /// 把已存在的主窗口带回前台。返回 false 表示窗口对象确实不在了，需要走 SwiftUI 重新开窗。
    @discardableResult func bringMainWindowForward() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "QQ排程助手" && $0.canBecomeMain }) else { return false }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// 请求把主窗口打开/唤回。监听者不再只挂在菜单栏面板上（走查 5-02）。
    func requestMainWindow() {
        NotificationCenter.default.post(name: .init("QQDispatchReturnAfterSend"), object: nil)
    }
    /// 目标会话当前没有草稿时的一次性补草稿：按这条任务的原文与素材，另开一条“草稿模式”任务
    /// 把内容填进 QQ 输入框，但绝不触发发送；原来那条 blocked 记录（含 started）一字不改地保留。
    func prepareDraftCopy(_ id: String) {
        // 走查 1-09：本入口在 DispatchProbe.drivenEntries 清单里，拦截要放在追加克隆任务之前，
        // 否则探针模式下会留下一条永远跑不了的克隆记录。
        if let refusal = DispatchProbe.refusal(entry: "另开只填写不发送的任务") { step = refusal; return }
        guard !busy, !importingList else {
            error = importingList ? "正在读取或验证群名，等它结束再另开草稿任务" : "有任务正在处理，请等它结束"; return
        }
        guard let source = deliveries.first(where: { $0.id == id }) else { return }
        guard source.mode == "automatic", !source.isOneOff else {
            error = "一次性补草稿记录不能再次派生任务"; return
        }
        guard source.status == "blocked", source.submittedAt == nil, source.evidence.isEmpty else {
            error = "只有尚未提交的暂停任务可以另开草稿填充"; return
        }
        guard !source.text.isEmpty || !source.assets.isEmpty else { error = "这条任务没有内容"; return }
        guard !Scheduling.hasUnresolvedClone(of: source.id, in: deliveries) else {
            error = "这条任务已经有一张未处理完的草稿填充任务，请先在发送记录里核对它"; return
        }
        running = false; activePlanID = nil
        let clone = Delivery(planID: source.planID, planName: source.planName, recipient: source.recipient,
                             text: source.text, assets: source.assets, scheduled: Date(), mode: "draft",
                             status: "queued", detail: "一次性草稿填充（只填写，不发送）· 来源 \(source.id)",
                             channel: source.channel, recipientID: source.recipientID,
                             oneOff: true, cloneOf: source.id)
        deliveries.append(clone)
        do { try persist() } catch {
            deliveries.removeAll { $0.id == clone.id }
            self.error = "草稿任务未能建立：\(error.localizedDescription)"; return
        }
        step = "已另开一条“只填写不发送”的任务：\(clone.recipient)"
        execute(clone)
    }

    /// 人工当场核对过 QQ 草稿之后的续发：不重新搜索、不清空、不再粘贴任何内容，
    /// 只发这一条、只发一条发送指令。原来的 blocked 记录保持不动，直到本次结果写回为止
    /// （检查点把它推进到 submitted，再按核验结果落到 verified / uncertain）。
    func sendVerifiedDraft(_ id: String, confirmedRecipient: Bool, confirmedText: Bool, confirmedImage: Bool) {
        // 走查 1-09 / 约束 3：这条入口不走 execute，原先既没有探针拦截也没有会员门禁，
        // 是 DispatchProbe.drivenEntries 清单里唯一的漏网入口。
        if let refusal = DispatchProbe.refusal(entry: "按已核对草稿续发") { step = refusal; return }
        guard guardMembership() else { return }
        guard !busy, !importingList else {
            error = importingList ? "正在读取或验证群名，等它结束再续发" : "有任务正在处理，请等它结束"; return
        }
        guard confirmedRecipient, confirmedText, confirmedImage else {
            error = "请先逐项确认：收件群正确、正文与计划一致、图片已在草稿里"; return
        }
        guard let i = deliveries.firstIndex(where: { $0.id == id }) else { return }
        let job = deliveries[i]
        guard job.mode == "automatic", !job.isOneOff else {
            error = "一次性补草稿记录不能作为发送任务续发"; return
        }
        guard job.status == "blocked", job.submittedAt == nil, job.evidence.isEmpty else {
            error = "只有尚未提交的暂停任务可以按已核对草稿续发"; return
        }
        guard let qq = driverFor(job.channelName) as? QQDriver else {
            error = "这条任务不是 QQ 渠道，暂不支持按草稿续发"; return
        }
        // 人工续发是一次性动作，无论结果如何都不能替用户接续其他群或其他计划。
        running = false; activePlanID = nil
        operationAppName = SendChannel.displayName(job.channelName)
        busy = true
        // 走查 1-08（AGENTS.md 第 9 行）：这条记录是「已经尝试过」的暂停记录，续发说明只能追加，
        // 不能整串覆盖掉上次卡在哪一步。
        deliveries[i].detail = SendChannel.keptRecord(note: "已按人工核对发起续发（未重新粘贴内容），结果待核对", previous: deliveries[i].detail)
        do { try persist() } catch {
            deliveries[i] = job; busy = false
            self.error = "任务未能开始：\(error.localizedDescription)"; return
        }
        qq.beforeSubmit = { [weak self] in
            guard let self, let index = self.deliveries.firstIndex(where: { $0.id == job.id }) else { throw AppError("任务不存在") }
            try Task.checkCancellation()
            let previous = self.deliveries[index]
            self.deliveries[index].status = "submitted"
            // 走查 1-08：检查点追加，不覆盖上面那条「已按人工核对发起续发」与更早的暂停原因。
            self.deliveries[index].detail = SendChannel.keptRecord(note: "人工核对草稿后的发送按键前检查点；异常退出须人工核对", previous: self.deliveries[index].detail)
            if self.deliveries[index].submittedAt == nil { self.deliveries[index].submittedAt = Date() }
            do { try self.persist() } catch {
                self.deliveries[index] = previous
                self.error = SendChannel.saveFailure(channel: job.channelName, reason: error.localizedDescription)
                throw error
            }
        }
        step = "\(job.recipient)：按已核对草稿续发（只发一次）"
        if settings.minimizeAfterSuccess != false { presentationEffects.showScheduler() }
        task = Task {
            defer { qq.beforeSubmit = {}; busy = false; task = nil; scheduleNextTick() }
            do {
                try Task.checkCancellation()
                let result = try await qq.sendExistingDraft(job, root: db.root)
                let saved = mutate(job.id, status: result.0, detail: outcomeDetail(status: result.0, detail: result.1,
                                                                       previous: deliveries.first(where: { $0.id == job.id })?.detail ?? ""), qqVerification: qq.verificationEvidence)
                let outcome = saved ? (deliveries.first(where: { $0.id == job.id })?.status ?? "uncertain") : "uncertain"
                // 任务已有结果（成功或未确认）：撤下它的「即将发送」预告，通知中心不留过时信息
                removeUpcomingAnnouncement(jobID: job.id)
                if saved { step = outcome == "verified" ? "\(job.recipient)：界面核验通过" : skippedOutcomeNote(recipient: job.recipient, status: outcome) }
                await returnAfterSuccessfulSend(job: job, verified: saved && outcome == "verified", driver: qq)
            } catch {
                let current = deliveries.first(where: { $0.id == job.id })
                let wasSubmitted = current?.submittedAt != nil || current?.status == "submitted"
                let saved = mutate(job.id, status: wasSubmitted ? "uncertain" : "blocked",
                       detail: SendChannel.keptRecord(note: "步骤：\(step)\n\(error.localizedDescription)", previous: current?.detail ?? ""))
                running = false; activePlanID = nil
                if saved { step = "本条续发结束：\(error.localizedDescription)；保留在发送记录，队列保持暂停" }
            }
        }
    }

    /// 走查 1-05 / 1-08 交接：驱动正常返回终态时的说明要不要接续历史。
    /// 核验通过的三类（verified / manual / cancelled）原样写入——`mutate` 会把 detail 一并落进
    /// `evidence`，那段必须是干净的核验凭据，掺进历史会让 `evidence.isEmpty` 的续发门禁失准；
    /// 其余（blocked / uncertain）改为追加，保留这条记录上一次卡在哪一步（AGENTS.md 第 9 行）。
    private func outcomeDetail(status: String, detail: String, previous: String) -> String {
        ["verified", "manual", "cancelled"].contains(status) ? detail : SendChannel.keptRecord(note: detail, previous: previous)
    }
    /// 返回值只表示本条新状态是否真实落盘；核验是否通过必须读保存后的 status。
    /// 拒绝假 verified 并成功保存 uncertain 也返回 true，不能把它与数据库失败混为停队。
    @discardableResult
    func mutate(_ id: String, status: String, detail: String, qqVerification: QQVerificationEvidence? = nil) -> Bool {
        guard let i = deliveries.firstIndex(where:{$0.id == id}) else { return false }
        let previous = deliveries[i]
        if status == "verified", previous.channelName == SendChannel.qq,
           previous.status != "submitted" || qqVerification?.isValid(for: previous) != true {
            deliveries[i].status = "uncertain"
            deliveries[i].detail = SendChannel.keptRecord(note: "核验凭据不足，不能标记完成；稍后可在发送记录人工核对，不会自动重发。\n\(detail)", previous: previous.detail)
            do { try persist() } catch {
                deliveries[i] = previous
                running = false; activePlanID = nil
                self.error = SendChannel.saveFailure(channel: previous.channelName, reason: error.localizedDescription)
                return false
            }
            return true
        }
        deliveries[i].status = status; deliveries[i].detail = detail; deliveries[i].finished = Date()
        if status == "verified" { deliveries[i].evidence = detail; deliveries[i].qqVerification = qqVerification }
        // 落盘失败回滚本条内存状态，界面与磁盘保持一致（磁盘仍是旧状态），消除「重启后取消复活」类分叉
        do { try persist() } catch { deliveries[i] = previous; running = false; activePlanID = nil; self.error = SendChannel.saveFailure(channel: previous.channelName, reason: error.localizedDescription); return false }
        // 循环发送触发点：发送类终态（核验通过 / 人工确认已发送）后尝试生成下一轮。
        // 取消不算发送完成：若本轮因取消全部收尾，改为暂停循环，不为已发送的群排下一轮（见 suspendRecurringAfterCancel）。
        if status == "cancelled" {
            suspendRecurringAfterCancel(planID: deliveries[i].planID)
        } else if status == "verified" || status == "manual" {
            maybeRecur(planID: deliveries[i].planID)
        }
        return true
    }
    /// 把「已暂停」记录重新入队。走查 5-07：`Delivery.canRequeue` 不看 `started`，所以已经打开过会话、
    /// 可能填过草稿的记录同样能重排——这类记录必须由调用方显式声明「上次没有发出、草稿已清空」，
    /// 不能一键生效。同时如实说明副作用：本计划其余待执行任务会按间隔一起顺延（`Scheduling.requeued`）。
    func requeuePaused(_ ids: Set<String>, acknowledgedAttempted: Bool = false) {
        guard !busy, guardMembership() else { return }
        let targets = deliveries.filter { ids.contains($0.id) && $0.canRequeue }
        guard !targets.isEmpty else { error = "这些任务可能已提交，请先核对发送记录"; return }
        let attempted = targets.filter { $0.started != nil }.count
        if attempted > 0, !acknowledgedAttempted {
            error = "这条已经尝试执行，请到发送记录核对，在页面内选择“发送”或“不发送”"
            route = "history"
            return
        }
        let old = deliveries
        deliveries = Scheduling.requeued(deliveries, ids: ids, now: Date(), gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan)
        do { try persist(); step = "已将 \(targets.count) 条暂停任务重新入队；本计划其余待执行任务按间隔顺延；点击启动 / 继续发送" }
        catch { deliveries = old; self.error = error.localizedDescription }
    }

    /// 追加一条循环提示：统一带计划名前缀「计划名」，多计划并发触发时用户能分清来源；
    /// 超过 3 条丢弃最早的，只保留最新 3 条，避免横幅无限增高。
    func postRecurNotice(planID: String, _ text: String) {
        let planName = plans.first(where: { $0.id == planID })?.name ?? "计划"
        recurNotices.append("「\(planName)」\(text)")
        if recurNotices.count > 3 { recurNotices.removeFirst(recurNotices.count - 3) }
    }

    /// 走查 1-10：清洗非法循环间隔（0 / 负值 / 超过 365 天）。`setRecurring` 只接受 1...30，
    /// 但旧库、手工改库和恢复备份都可能绕过它；`Scheduling.recur` 现在会拒绝并抛错，
    /// 与其每次收尾都报错，不如启动/恢复时一次性关掉并写进循环提示通道。
    func sanitizeRecurringPlans() {
        for i in plans.indices {
            if let days = plans[i].recurringEveryDays, !(1...365).contains(days) {
                plans[i].recurringEveryDays = nil
                postRecurNotice(planID: plans[i].id, "循环间隔 \(days) 天无效（需在 1–365 之间），已停止自动接续下一轮；需要继续请在「循环设置」重新开启")
            }
        }
    }

    /// 开启 / 关闭循环发送。开启即对已收尾的计划立刻尝试生成下一轮（未收尾则内部 no-op）。
    /// 不启动发送、不改 running。关闭 = 连同取消循环自动排入的待执行轮（cycleTag 非空的 queued 任务）。
    func setRecurring(planID: String, everyDays: Int?) {
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
        if let everyDays, !(1...30).contains(everyDays) { error = "循环间隔需在 1 到 30 天之间"; return }
        let old = plans[index].recurringEveryDays
        let wasDraft = plans[index].mode == "draft"
        plans[index].recurringEveryDays = everyDays
        if let everyDays {
            do { try persist() } catch {
                plans[index].recurringEveryDays = old
                self.error = error.localizedDescription
                return
            }
            step = "已开启循环：一轮结束后每隔 \(everyDays) 天自动进入下一轮"
            maybeRecur(planID: planID)
            // 循环提示合并为一条：草稿模式下一轮不会自动发送，每条都要人工确认后循环才接续，先把预期讲清楚
            postRecurNotice(planID: planID, wasDraft
                ? "已开启循环：一轮结束后每隔 \(everyDays) 天自动进入下一轮；草稿模式：一轮里每条都需人工确认后，循环才会接续"
                : "已开启循环：一轮结束后每隔 \(everyDays) 天自动进入下一轮")
        } else {
            // 关闭循环同时取消自动排入的待执行轮：直接赋值路径（不经 mutate、不触发 suspend——
            // 循环标记此时已置 nil，suspendRecurringAfterCancel 天然 no-op）。
            // 关循环与批量取消一次性落盘；persist 失败整体回滚，循环保持原样。
            let oldDeliveries = deliveries
            var cancelled = 0
            for i in deliveries.indices where deliveries[i].planID == planID && deliveries[i].status == "queued" && deliveries[i].cycleTag != nil {
                deliveries[i].status = "cancelled"
                // 走查 5-08：与批量取消同一口径（SendChannel.cancelledDetail → keptRecord），
                // 这条任务可能带着「手动重新入队；上次暂停：…」等历史说明，不能整串覆盖。
                deliveries[i].detail = SendChannel.cancelledDetail(previous: deliveries[i].detail, note: "循环已停止，自动取消本轮后续任务")
                deliveries[i].finished = Date()
                cancelled += 1
            }
            do { try persist() } catch {
                plans[index].recurringEveryDays = old
                deliveries = oldDeliveries
                self.error = error.localizedDescription
                return
            }
            postRecurNotice(planID: planID, cancelled == 0 ? "已停止循环" : "已停止循环，并取消自动排入的 \(cancelled) 条待执行任务")
        }
    }

    /// 循环发送：本轮任务全部到达终态后，按原时间表自动生成下一轮排队任务。
    /// 只生成 queued 任务，不启动发送、不改 running；是否真发仍由队列启动控制。
    /// 幂等：recur 的前置条件是本轮全部终态，而生成出的新任务为 queued（非终态），
    /// 再次触发时 cycleComplete 必为假，因此不会重复生成下一轮。
    /// 提示走 recurNotices 独立通道：不被驱动的 step 文案覆盖，队列页 / 发送记录页横幅展示。
    func maybeRecur(planID: String) {
        guard let index = plans.firstIndex(where: { $0.id == planID }),
              let everyDays = plans[index].recurringEveryDays,
              plans[index].queueCancelledAt == nil, runSelection[planID] == nil else { return }
        let jobs = queueJobs(planID: planID)
        guard Scheduling.cycleComplete(jobs) else { return }
        do {
            guard let nextRound = try Scheduling.recur(plans[index], jobs: jobs, now: Date(), gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan) else { return }
            if nextRound.isEmpty {
                // 收尾但无可复制的收件人（上一轮全部被取消）：自动关闭循环
                if disableRecurring(planID: planID) {
                    postRecurNotice(planID: planID, "所有收件人已取消，循环已自动停止")
                }
                return
            }
            let old = deliveries
            deliveries += nextRound
            do { try persist() } catch { deliveries = old; running = false; activePlanID = nil; self.error = error.localizedDescription; return }
            let round = nextRound.compactMap(\.cycleTag).max() ?? (jobs.compactMap(\.cycleTag).max() ?? 0) + 1
            if let first = nextRound.map(\.scheduled).min() {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                // 走查 1-12 / 4-06：排期时刻由 Scheduling.calendar（北京时间）决定，提示文案必须用同一套
                // 日历和时区，否则本机时区非北京时「首条约 X 点」与计划自己的墙钟时刻对不上。
                formatter.calendar = Scheduling.calendar
                formatter.timeZone = Scheduling.calendar.timeZone
                postRecurNotice(planID: planID, "第 \(round) 轮已自动排入（循环每 \(everyDays) 天一轮），首条约 \(formatter.string(from: first))")
            } else {
                postRecurNotice(planID: planID, "第 \(round) 轮已自动排入（循环每 \(everyDays) 天一轮）")
            }
        } catch {
            // 超出单计划任务上限等：自动关闭循环，已有任务保持不动
            if disableRecurring(planID: planID) {
                postRecurNotice(planID: planID, "循环已达单计划任务上限（10000 条），已自动停止")
            }
        }
    }

    /// 取消导致的“本轮全部收尾”不排下一轮：该计划开着循环且本轮已收尾时，自动暂停循环。
    /// 未开循环、或本轮还有未收尾任务时 no-op。与 maybeRecur 的区别：取消不是发送完成，
    /// 不能替用户把已发送的群再排一轮；需要继续时到间隔设置重新开启循环。
    private func suspendRecurringAfterCancel(planID: String) {
        guard let index = plans.firstIndex(where: { $0.id == planID }),
              plans[index].recurringEveryDays != nil else { return }
        let jobs = queueJobs(planID: planID)
        guard Scheduling.cycleComplete(jobs) else { return }
        if disableRecurring(planID: planID) {
            // 计划名已由 postRecurNotice 统一加前缀，正文不再重复“本计划”
            postRecurNotice(planID: planID, "本轮已收尾（含取消的任务），循环已自动暂停；需要继续请在循环设置重新开启")
        }
    }

    /// 循环自动关闭（收件人全取消 / 超上限 / 取消致本轮收尾）：落盘关闭标记，失败则回滚并置 error。
    /// 返回是否成功落盘（true = 循环确实已关闭）。
    @discardableResult
    private func disableRecurring(planID: String) -> Bool {
        guard let index = plans.firstIndex(where: { $0.id == planID }) else { return false }
        let old = plans[index].recurringEveryDays
        plans[index].recurringEveryDays = nil
        do { try persist() } catch {
            plans[index].recurringEveryDays = old
            self.error = error.localizedDescription
            return false
        }
        return true
    }

    func appendRecipients(planID: String, ids: Set<String>) -> Bool {
        guard !busy, !isQueueRunning(planID), guardMembership(), let index = plans.firstIndex(where: { $0.id == planID }) else { return false }
        let oldJobs = deliveries; let oldPlans = plans; let oldRecipients = recipients
        do {
            let chosen = recipients.filter { ids.contains($0.id) }
            // 走查 1-06 / 交接：把素材库传进去，新任务按「本计划的配图」取快照，
            // 而不是沿用队尾那条任务的附件（界面文案承诺的是「沿用本计划的图文」）。
            let added = try Scheduling.additionalDeliveries(plan: plans[index], recipients: chosen, jobs: deliveries, now: Date(), gap: settings.globalGapMinutes, assets: assets)
            guard !added.isEmpty else { throw AppError("所选群已在计划中，无需重复添加") }
            deliveries += added
            for r in chosen where added.contains(where: { $0.recipient == r.name && $0.channelName == r.channelName }) {
                if !plans[index].recipientIDs.contains(r.id) { plans[index].recipientIDs.append(r.id) }
                if let i = recipients.firstIndex(where: { $0.id == r.id }) { recipients[i].enabled = true }
            }
            try persist()
            step = "已向本计划追加 \(added.count) 个群；尚未启动发送"
            return true
        } catch {
            deliveries = oldJobs; plans = oldPlans; recipients = oldRecipients
            self.error = error.localizedDescription; return false
        }
    }

    /// 人工确认「上次没发出、草稿已处理」之后重新排期。走查 5-07：`canReschedule` 不看 `started`，
    /// 已经开始执行过的记录回到待执行同样需要人工声明，所以 `acknowledgedAttempted` 必须由带声明文案的
    /// 入口显式传 true（目前只有详情面板那颗「确认未发且草稿已清空，重新排期」）。
    /// 走查 1-08：排期说明改为追加，保留这条记录原先的暂停原因（AGENTS.md 第 9 行）。
    /// 单任务推迟 N 分钟（右键菜单）：只动这一条的 scheduled，运行期 due 的 max 钳制方向
    /// 保证推迟绝不会被反向提前；后续任务不手动顺延，翻转后的顺序由 dueDates 自动兜底
    /// （调度审计 2026-10-06）。目标时刻带 now+10 秒托底，过期任务推迟不会静默变「马上发」。
    func postpone(_ id: String, minutes: Int) {
        guard !busy, minutes > 0, let i = deliveries.firstIndex(where: { $0.id == id }), deliveries[i].canPostpone else { return }
        let previous = deliveries[i]
        deliveries[i].scheduled = Postpone.target(scheduled: previous.scheduled, minutes: minutes, now: Date())
        deliveries[i].detail = SendChannel.keptRecord(note: "已手动推迟 \(minutes) 分钟（原定 \(previous.scheduled.formatted(date: .abbreviated, time: .shortened))）", previous: previous.detail)
        do { try persist() } catch {
            deliveries[i] = previous
            self.error = "推迟未能保存：\(error.localizedDescription)"
        }
    }

    func reschedule(_ id: String, acknowledgedAttempted: Bool = false) {
        guard !busy, let i = deliveries.firstIndex(where:{$0.id == id}), deliveries[i].canReschedule else { return }
        if deliveries[i].started != nil, !acknowledgedAttempted {
            error = "这条上次已经开始执行过，请到发送记录详情里逐项确认后再重新排期"; return
        }
        let last = Scheduling.lastSendActivity(deliveries) ?? .distantPast
        deliveries[i].scheduled = max(Date().addingTimeInterval(10),last.addingTimeInterval(Double(settings.globalGapMinutes * 60)))
        deliveries[i].status = "queued"
        deliveries[i].historyClearedAt = nil
        deliveries[i].detail = SendChannel.rescheduleDetail(channel: deliveries[i].channelName, previous: deliveries[i].detail)
        deliveries[i].finished = nil
        if deliveries[i].submittedAt == nil { deliveries[i].started = nil }
        saveSettings()
    }
    func backup() {
        let panel = NSOpenPanel(); panel.title = "选择备份保存位置"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        perform {
            let folder = parent.appendingPathComponent("QQ排程备份-\(Int(Date().timeIntervalSince1970))")
            try persist(); try db.backup(to:folder)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(archive).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
            NSWorkspace.shared.activateFileViewerSelecting([folder]); step = "数据库和素材已完整备份"
        }
    }
    func exportRecords() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "QQ发送记录.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; try e.encode(deliveries).write(to:url,options:.atomic) }
    }
    /// 导出隔离区（走查 1-07 交接）：坏行的原文只在那里还能取回，`exportRecords` 只导 deliveries，
    /// 按提示「先导出备份」拿不到坏行。逐表导出 (来源表, 行 id, payload, 原因, 发现时间)。
    func exportQuarantine() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "QQ排程助手-隔离区.json"; guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let tables = ["recipients", "assets", "plans", "deliveries", "settings"]
            let rows = tables.flatMap { table in
                db.quarantinedRows(for: table).map { row in [
                    "source": table, "id": row.id, "reason": row.reason,
                    "notedAt": ISO8601DateFormatter().string(from: row.notedAt),
                    "payload": row.payload.map { String(decoding: $0, as: UTF8.self) } ?? "",
                ] as [String: Any] }
            }
            guard !rows.isEmpty else { throw AppError("隔离区里没有待取回的坏行") }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            step = "已导出隔离区 \(rows.count) 条坏行原文"
        }
    }
    /// 待核对（含已暂停）记录条数：恢复备份前的确认文案用（走查 5-06）
    var reviewPendingCount: Int { deliveries.filter { ["draft", "submitted", "uncertain", "blocked"].contains($0.status) }.count }
    /// 恢复备份：整库替换，属于最破坏性的操作。走查 5-06 按 AGENTS.md 第 6 行补齐门禁——
    /// 除了 `busy`，还要求队列已暂停（`running`），并由界面二次确认披露「将被替换的条数 + 待核对条数」。
    func restoreBackup(confirmed: Bool = false) {
        guard !busy else { error = "请先暂停并等待当前操作结束"; return }
        guard !running else { error = "队列运行中：请先点「暂停全部」，等这条间隔走完再恢复备份"; return }
        guard confirmed || reviewPendingCount == 0 else {
            error = "发送记录里有 \(reviewPendingCount) 条待核对或已拦截的任务，恢复会整体替换当前资料；请先处理完再恢复"; return
        }
        let panel = NSOpenPanel(); panel.title = "选择包含 manifest.json 与 assets 的备份文件夹"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        perform {
            var backup = try JSONDecoder().decode(Archive.self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
            guard backup.version == 1, (1...1440).contains(backup.settings.globalGapMinutes), backup.deliveries.allSatisfy({ ["draft","automatic"].contains($0.mode) }) else { throw AppError("备份版本或排程设置无效") }
            let referenced = backup.assets + backup.deliveries.flatMap(\.assets)
            var seen = Set<String>()
            for a in referenced where seen.insert(a.id).inserted {
                guard a.relativePath.hasPrefix("assets/"), !a.relativePath.split(separator:"/").contains(".."), !a.relativePath.hasPrefix("/") else { throw AppError("备份文件路径无效") }
                let source = folder.appendingPathComponent(a.relativePath)
                guard source.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"), try Database.digest(source) == a.sha256 else { throw AppError("备份素材校验失败：\(a.name)") }
                let target = db.root.appendingPathComponent(a.relativePath)
                if FileManager.default.fileExists(atPath:target.path) { guard try Database.digest(target) == a.sha256 else { throw AppError("素材 ID 冲突，恢复已停止") } }
                else { try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true); try FileManager.default.copyItem(at:source,to:target) }
            }
            let safety = db.root.appendingPathComponent("backups/恢复前-\(UUID().uuidString)")
            try db.backup(to:safety)
            backup.deliveries = QQVerificationReview.recovered(Scheduling.recovered(backup.deliveries))
            // 走查 1-07 交接：先把本连接的坏行内存索引清空再整库写入。
            // 不清的话，旧库里记录过的坏行会被 `replace` 原样写回刚恢复的表（隔离表历史仍保留，不销毁数据）。
            db.resetQuarantineIndex()
            try db.save(backup)
            stop(); recipients = backup.recipients; assets = backup.assets; plans = backup.plans; deliveries = backup.deliveries; settings = backup.settings
            if settings.textTemplates == nil { settings.textTemplates = settings.savedText.isEmpty ? [] : [TextTemplate(text:settings.savedText)] }
            settings.prepareWorkspaces(recipientIDs: recipients.filter(\.enabled).map(\.id))
            // 走查 1-10：备份可能来自旧版本 / 另一台机器，循环天数同样要清洗
            sanitizeRecurringPlans()
            // 恢复的备份可能来自旧版本或另一台机器：会员档案与服务器地址一并重新落地
            license.baseURL = LicenseService.normalize(settings.licenseServerURL)
            licenseState = settings.resolvedLicenseState()
            step = "备份已恢复，队列保持暂停；原数据库和素材保存在恢复前备份中"
        }
    }
}

// MARK: - 会员判定（走查 3-15：判据已统一收进 Core 的 LicenseState，勿在此重复定义）
//
// 这里曾有一份 `serverConfirmedValid` 补丁扩展。`Sources/Core.swift` 的加固版落地后，两者构成
// **重载**，而 Swift 的重载排序偏向「需要补的默认参数更少」的候选，于是 `App.swift` 的调用点
// 一直命中这份只信本机 `Date()` 的旧实现，加固版沦为死代码（拨慢本机时钟仍可刷新宽限计时点）。
// 删除后所有调用点统一绑定 Core 版本：服务端明确回答过期即 false，时基取
// `max(本机时钟, 单调服务端锚点)`，不再被本机时钟倒退绕过。

// MARK: - 导航定义

struct NavItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    var summary: String {
        ["home":"今天的排期与进度", "recipients":"QQ群管理与微信手动维系", "compose":"选择群聊、编辑内容与时间", "assets":"保存要发送的图片与文件", "queue":"开始、暂停、重试发送", "schedule":"调整开始时间、间隔与循环", "progress":"各队列进度与统计", "history":"查看结果与失败原因", "member":"账号与套餐", "settings":"权限、发送间隔与备份"][id] ?? ""
    }
}

let navItems: [NavItem] = [
    NavItem(id: "home",       title: "总览",       symbol: "square.grid.2x2.fill"),
    NavItem(id: "compose",    title: "新建发送",   symbol: "square.and.pencil"),
    NavItem(id: "assets",     title: "素材库",     symbol: "photo.on.rectangle.angled"),
    NavItem(id: "recipients", title: "群与联系人", symbol: "person.2.fill"),
    NavItem(id: "queue",      title: "发送队列",   symbol: "calendar.badge.clock"),
    NavItem(id: "schedule",   title: "排期与间隔", symbol: "calendar.day.timeline.left"),
    NavItem(id: "progress",   title: "发送进度",   symbol: "speedometer"),
    NavItem(id: "history",    title: "发送记录",   symbol: "clock.arrow.circlepath"),
    NavItem(id: "member",     title: "会员中心",   symbol: "crown.fill"),
    NavItem(id: "settings",   title: "设置与备份", symbol: "slider.horizontal.3")
]

/// 按钮按自身宽度排，一行放不下就换行，避免被挤成高瘦竖条。
struct FlowHStack: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let limit = finite(proposal.width) else {
            let width = sizes.reduce(CGFloat(0)) { $0 + $1.width } + hSpacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > limit + 0.5 {
                y += rowH + vSpacing
                x = 0
                rowH = 0
            }
            rowH = max(rowH, size.height)
            x += size.width + hSpacing
        }
        return CGSize(width: limit, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowH: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX + 0.5 {
                x = bounds.minX
                y += rowH + vSpacing
                rowH = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: size.height))
            rowH = max(rowH, size.height)
            x += size.width + hSpacing
        }
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value < 100_000 else { return nil }
        return value
    }
}

/// 第二块优先放在右侧；剩下的宽度不够时，整块换到下一行。
struct SideOrBelow: Layout {
    var spacing: CGFloat = 10
    var minLeading: CGFloat = 140

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let width = finite(proposal.width) ?? 800
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if width - trailing.width - spacing >= minLeading {
            let leadingWidth = width - trailing.width - spacing
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: proposal.height))
            return CGSize(width: width, height: max(leading.height, trailing.height))
        }
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        let wrapped = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: leading.height + spacing + wrapped.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            return
        }
        let trailingIdeal = subviews[1].sizeThatFits(.unspecified)
        if bounds.width - trailingIdeal.width - spacing >= minLeading {
            let leadingWidth = bounds.width - trailingIdeal.width - spacing
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: bounds.height))
            let rowH = max(leading.height, trailingIdeal.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (rowH - leading.height) / 2),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: leadingWidth, height: leading.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - trailingIdeal.width, y: bounds.minY + (rowH - trailingIdeal.height) / 2),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: trailingIdeal.width, height: trailingIdeal.height))
        } else {
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: leading.height))
            let wrapped = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + leading.height + spacing),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: wrapped.height))
        }
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value < 100_000 else { return nil }
        return value
    }
}

@MainActor
extension Store {
    /// 首页、菜单与默认队列页绑定同一个当前计划；历史日志不决定启动去向。
    var displayedQueuePlanID: String? {
        let scoped = plans.filter { workspaceID.isEmpty || ($0.workspaceID ?? "legacy") == workspaceID }
        if scoped.contains(where: { $0.id == chosenPlanID }) { return chosenPlanID }
        let ids = Set(scoped.map(\.id))
        return Scheduling.nextCandidate(deliveries, gap: settings.globalGapMinutes,
                                        allowedPlanIDs: ids, intervalByPlan: intervalByPlan)?.planID
            ?? scoped.max(by: { $0.created < $1.created })?.id
    }
    var displayedQueueJobs: [Delivery] {
        guard let planID = displayedQueuePlanID else { return [] }
        return queueJobs(planID: planID)
    }
    var displayedQueueCandidate: Delivery? {
        guard let planID = displayedQueuePlanID else { return nil }
        return nextDelivery(planID: planID)
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            // 未登录：整窗锁定为登录界面，不渲染主界面
            if store.licenseState == .loggedOut && !store.guestMode { LoginView() } else { mainPane }
        }
        .frame(minWidth: 760, minHeight: 640)
        .overlay(alignment: .bottom) { DeniedToast().padding(.bottom, 44) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { store.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("收起操作提示")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Surface(scheme).inset)
            }
        }
    }

    private var mainPane: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240)
            Rectangle().fill(Surface(scheme).hairline).frame(width: 1)
            detail
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        let s = Surface(scheme)
        return VStack(alignment: .leading, spacing: 0) {
            brandHeader
            ScrollView {
                VStack(spacing: 3) {
                    Text("发送工作台").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 5)
                    ForEach(["compose", "queue", "schedule", "progress", "history", "recipients", "assets"], id: \.self) { id in
                        if let item = navItems.first(where: { $0.id == id }) {
                            NavRow(item: item, selected: store.route == item.id, badge: badge(for: item.id)) { store.route = item.id }
                        }
                    }
                    Divider().padding(.vertical, 10)
                    Text("其他功能").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    ForEach(navItems.filter { ["home", "settings", "member"].contains($0.id) }) { item in
                        NavRow(item: item, selected: store.route == item.id, badge: nil) { store.route = item.id }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            Spacer(minLength: 8)
            statusCard
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                s.inset
                LinearGradient(colors: [Theme.indigo.opacity(scheme == .dark ? 0.18 : 0.075), .clear],
                               startPoint: .top, endPoint: .center)
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "paperplane.fill", size: 42, gradient: Theme.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text("QQ 排程助手").font(.system(size: 15, weight: .bold))
                Text("LOCAL DISPATCH").font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.indigo.opacity(0.85)).tracking(1.2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func badge(for id: String) -> Int? {
        switch id {
        case "queue": return store.displayedQueueJobs.filter { $0.status == "queued" }.count
        case "history": return QueueStartGate.reviewCount(store.deliveries.filter { $0.historyClearedAt == nil }.map(\.status))
        default: return nil
        }
    }

    private var statusCard: some View {
        DepthSurface(radius: 16, padding: 14, accent: store.running ? Theme.green : nil) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    PulseDot(color: store.running ? Theme.green : Theme.slate, active: store.running)
                    Text(store.running ? "\(store.runningPlanIDs.count) 条队列运行中" : "队列已暂停")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(store.running ? Theme.green : .secondary)
                    Spacer()
                }
                if let next = store.nextDelivery, store.running {
                    CountdownText(target: store.earliestSendDate(next), prefix: "距下一群", compact: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(membershipTint)
                    Text(store.membershipHint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if store.route != "member" {
                        Button("查看") { store.route = "member" }
                            .font(.system(size: 10)).buttonStyle(GhostPressButtonStyle()).quietHover().foregroundStyle(membershipTint)
                    }
                }
                Text(SendChannel.loginReminder(channels: store.recipients.map(\.channelName)))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 详情区

    private var detail: some View {
        let s = Surface(scheme)
        return VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.6)
            Group {
                switch store.route {
                case "home": HomeView()
                case "assets": AssetsView()
                case "recipients": RecipientsView()
                case "queue": QueueView(history: false)
                case "schedule": QueueView(history: false, pane: .schedule)
                case "progress": QueueView(history: false, pane: .progress)
                case "history": QueueView(history: true)
                case "member": MembershipView()
                case "settings": SettingsView()
                default: ComposeView(workspaceID: store.workspaceID).id(store.workspaceID)
                }
            }
            .id(store.route)                       // 路由变化时整组重建，重放渐入
            .pageFade(trigger: store.route)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footerBar
        }
        .background(s.page)
    }

    private var headerBar: some View {
        let compact = false
        return SideOrBelow(spacing: 8, minLeading: compact ? 120 : 180) {
            HStack(spacing: compact ? 8 : 12) {
                if compact {
                    Image(systemName: navItems.first(where: { $0.id == store.route })?.symbol ?? "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                } else {
                    IconTile(symbol: navItems.first(where: { $0.id == store.route })?.symbol ?? "square.grid.2x2.fill",
                             size: 42, gradient: Theme.gradient(for: store.route))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if compact {
                        Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    } else {
                        Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                            .foregroundStyle(LinearGradient(colors: [Color.primary, Color.primary.opacity(0.66)], startPoint: .top, endPoint: .bottom))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            headerActions
        }
        .padding(.horizontal, 22)
        .padding(.vertical, compact ? 9 : 12)
    }

    /// 日志核对是次级入口，页头保留正常的新建操作。
    private var showsHeaderAction: Bool {
        guard let action = HomeBanner.headerAction(route: store.route, reviewCount: reviewCount) else { return false }
        return !(store.route == "queue" && action.goesToHistory)
    }

    private var headerActions: some View {
        let compact = false
        let action = HomeBanner.headerAction(route: store.route, reviewCount: reviewCount)
        return FlowHStack(hSpacing: 8, vSpacing: 8) {
            if !compact { LiveClock().fixedSize() }
            if store.busy { ProgressView().controlSize(.small).fixedSize() }
            if store.running || store.busy {
                if compact {
                    Button { store.stop() } label: { Text("暂停全部").frame(height: 32) }
                        .buttonStyle(QueuePlainButtonStyle())
                        .help("暂停全部发送")
                } else {
                    Button { store.stop() } label: { Label("暂停全部", systemImage: "pause.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.orange))
                        .fixedSize()
                }
            }
            if compact {
                Button { store.route = "compose" } label: { Text("新建发送").frame(height: 32) }
                    .buttonStyle(QueuePlainButtonStyle(prominent: true))
            } else if showsHeaderAction, let action {
                Button { store.route = action.goesToHistory ? "history" : "compose" } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .buttonStyle(DepthButtonStyle(
                    gradient: action.goesToHistory ? Theme.warm : Theme.brand,
                    tint: action.goesToHistory ? Theme.amber : Theme.indigo))
                .fixedSize()
            }
        }
    }

    private var footerBar: some View {
        SideOrBelow(spacing: 8, minLeading: 160) {
            HStack(spacing: 8) {
                Image(systemName: store.busy ? "arrow.triangle.2.circlepath" : "info.circle.fill")
                    .foregroundStyle(store.busy ? Theme.blue : Theme.indigo)
                Text(store.step).font(.system(size: 12.5)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.route != "queue" && store.route != "history" {
                FlowHStack(hSpacing: 6, vSpacing: 6) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let dateText = context.date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
                        Pill(text: dateText, tint: Theme.blue, symbol: "calendar", variant: .neutral)
                    }
                    .fixedSize()
                    Pill(text: "资料保存在本机", tint: Theme.slate, symbol: "internaldrive.fill", variant: .neutral).fixedSize()
                    Pill(text: "\(store.recipients.count) 群 · \(store.assets.count) 素材", tint: Theme.pink, symbol: "tray.full.fill", variant: .neutral).fixedSize()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var membershipTint: Color {
        switch store.licenseState {
        case .active: return Theme.green
        case .grace: return Theme.amber
        case .expired: return Theme.rose
        case .loggedOut: return Theme.slate
        }
    }

    private var reviewCount: Int { QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status)) }
    private var title: String {
        if store.route == "home" {
            return HomeBanner.pageTitle(hasNext: store.displayedQueueCandidate != nil, reviewCount: reviewCount)
        }
        return ["compose":"新建发送", "assets":"你的素材，随时可用", "recipients":"群与联系人", "queue":"发送队列", "schedule":"排期与间隔", "progress":"发送进度", "history":"发送记录", "member":"会员与套餐", "settings":"连接、存储与备份"][store.route] ?? "新建发送"
    }
    private var subtitle: String {
        if store.route == "recipients", store.orderChannel == SendChannel.wechat { return "关系回响是配套的微信通讯录管理工具；本页面读取它同步的联系人名单，用于打开微信聊天。在关系回响筛选人物，打开微信聊天后手动发送。" }
        if store.route == "home" {
            return HomeBanner.pageSubtitle(hasNext: store.displayedQueueCandidate != nil, reviewCount: reviewCount)
        }
        return ["compose":"选择群聊并定好开始时间，再准备内容。", "assets":"导入后独立保存，原文件移动也不影响使用。", "recipients":"QQ 按名称搜索并打开第一条群聊结果。", "queue":"启动、暂停队列，盯住下一群和任务列表。", "schedule":"按队列调整开始时间、间隔与循环。", "progress":"各队列的进度、统计与需关注记录。", "history":"区分草稿、提交与核对，不确定的结果不自动重发。", "member":"套餐、续费与卡密兑换，随时掌握会员状态。", "settings":"不接管登录，不保存密码，所有数据留在本机。"][store.route] ?? "" }
}

// MARK: - 侧边栏导航行

struct NavRow: View {
    let item: NavItem
    let selected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconTile(symbol: item.symbol, size: 27, gradient: Theme.gradient(for: item.id))
                    .saturation(selected ? 1 : 0.55)
                    .opacity(selected ? 1 : 0.85)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color.primary)
                    Text(item.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.brand, in: Capsule())
                        .shadow(color: Theme.indigo.opacity(0.4), radius: 3, y: 1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Theme.indigo.opacity(scheme == .dark ? 0.20 : 0.09)
                                   : (hovering ? Color.primary.opacity(0.05) : Color.clear))
                    .shadow(color: selected ? Theme.indigo.opacity(0.16) : .clear, radius: 6, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Theme.indigo.opacity(0.22) : .clear, lineWidth: 0.9)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(GhostPressButtonStyle())
        .modifier(NavRowLift(active: selected))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// 侧栏导航行的「浮起/落下」：悬停上浮 + 阴影投影，离开时落回并轻微过冲
private struct NavRowLift: ViewModifier {
    let active: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let lifted = hovering && !active
        content
            .scaleEffect(lifted && !reduceMotion ? 1.02 : 1)
            .offset(y: lifted && !reduceMotion ? -2.5 : 0)
            .shadow(color: lifted && !reduceMotion ? Theme.indigo.opacity(0.30) : .clear,
                    radius: lifted ? 9 : 0, y: lifted ? 4 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - 实时时钟

struct LiveClock: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Image(systemName: "clock.fill").font(.system(size: 10)).foregroundStyle(Theme.indigo)
                Text(context.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Color.primary.opacity(scheme == .dark ? 0.10 : 0.05), Color.primary.opacity(scheme == .dark ? 0.04 : 0.02)],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.55), Color.primary.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.7)
            )
        }
    }
}

// MARK: - 总览

struct HomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 战报口径的 O(n) 遍历只在 body 求值时跑一次，算完用局部 let 复用；
        // 不要再拆进 computed property 里重复调用。
        let planNames = Dictionary(store.plans.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let report = DailySendReport.today(deliveries: store.displayedQueueJobs, planNames: planNames, now: Date(), calendar: Scheduling.calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                HStack(spacing: 14) {
                    StatTile(title: "待执行", value: store.displayedQueueJobs.filter { $0.status == "queued" }.count, symbol: "clock.fill", gradient: Theme.brand, tint: Theme.indigo)
                    StatTile(title: "本计划已核对", value: DispatchProgressMapper.doneCount(from: store.displayedQueueJobs), symbol: "checkmark.seal.fill", gradient: Theme.success, tint: Theme.green)
                    StatTile(title: "待核对", value: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status)), symbol: "exclamationmark.triangle.fill", gradient: Theme.warm, tint: Theme.amber)
                    StatTile(title: "素材", value: store.assets.count, symbol: "photo.stack.fill", gradient: Theme.cool, tint: Theme.teal)
                }
                // 走查 1-26 交接：总览的灰字与队列页同口径——已暂停里区分能不能直接重试，
                // 不能再对着 `canRequeue == false` 的记录写「可在发送记录重试」。
                if let paused = QueueStartGate.pausedNote(statuses: store.displayedQueueJobs.map(\.status),
                                                          nonRetriableCount: QueueStartGate.nonRetriablePaused(
                                                            store.displayedQueueJobs.map(\.status), store.displayedQueueJobs.map { !$0.canRequeue })) {
                    Text(paused).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if report.hasContent {
                    todaySendReportCard(report)
                }
                todayTimelineCard
                HStack(alignment: .top, spacing: 16) {
                    upcomingCard
                    VStack(spacing: 16) {
                        quickActions
                        recipientSummary
                    }
                    .frame(width: 300)
                }
            }
            .padding(22)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 今日时刻表（一眼看出今天要发什么）

    private var todayTimelineCard: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "今日时刻表", symbol: "calendar.day.timeline.left", tint: Theme.indigo,
                             trailing: store.displayedQueueJobs.filter { $0.scheduled >= Scheduling.calendar.startOfDay(for: Date()) }.isEmpty ? "今天空闲" : "按时间排列")
                TodayTimelineView(deliveries: store.displayedQueueJobs, running: store.isQueueRunning(store.displayedQueuePlanID), onRetry: { id in
                    if let planID = store.deliveries.first(where: { $0.id == id })?.planID { store.chosenPlanID = planID }
                    store.route = "history"
                }, retryEnabled: !store.busy)
            }
        }
    }

    // MARK: 今日发送战报（三色语言：绿=已发送 · 黄=待核对 · 红=已拦截）

    private func todaySendReportCard(_ report: DailySendReport.Outcome) -> some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "今日发送战报", symbol: "circle.grid.3x3.fill", tint: Theme.indigo)
                FlowHStack(hSpacing: 6, vSpacing: 6) {
                    reportCountPill("已发送", count: report.sent, tint: Theme.green, symbol: "checkmark.circle.fill")
                    reportCountPill("待核对", count: report.pendingReview, tint: Theme.amber, symbol: "exclamationmark.circle.fill")
                    reportCountPill("已拦截", count: report.blocked, tint: Theme.rose, symbol: "pause.circle.fill")
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(report.lines.prefix(5).enumerated()), id: \.offset) { _, line in
                        sendReportLine(line)
                    }
                    if report.lines.count > 5 {
                        Text("还有 \(report.lines.count - 5) 个计划…")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("绿=已发送 · 黄=待核对（去 QQ 确认） · 红=已拦截（可在发送记录重试）")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if report.pendingReview > 0 || report.blocked > 0 {
                        Button { store.route = "history" } label: {
                            Text("去处理").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(SoftButtonStyle(tint: Theme.amber))
                    }
                }
            }
        }
    }

    /// 计数胶囊：为 0 的类别弱化显示但保留，三色语言始终稳定。
    private func reportCountPill(_ label: String, count: Int, tint: Color, symbol: String) -> some View {
        Pill(text: "\(label) \(count)", tint: tint, symbol: symbol, compact: true)
            .opacity(count > 0 ? 1 : 0.35)
    }

    /// 单计划一行：行首三色点串（有该类任务才点亮），行尾紧凑计数。
    private func sendReportLine(_ line: DailySendReport.PlanLine) -> some View {
        HStack(spacing: 8) {
            // 固定宽度容下 4 枚点，计划名列才能上下对齐
            HStack(spacing: 3) {
                if line.sent > 0 { Circle().fill(Theme.green).frame(width: 8, height: 8) }
                if line.pendingReview > 0 { Circle().fill(Theme.amber).frame(width: 8, height: 8) }
                if line.blocked > 0 { Circle().fill(Theme.rose).frame(width: 8, height: 8) }
                if line.queued > 0 { Circle().fill(Theme.slate).frame(width: 8, height: 8) }
            }
            .frame(width: 41, alignment: .leading)
            Text(line.planName).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(line.sent) 发 · \(line.pendingReview) 核 · \(line.blocked) 拦 · \(line.queued) 待")
                .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var reviewNote: String? {
        let count = QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))
        return count > 0 ? "本计划有 \(count) 条结果留在发送记录，可稍后核对；其余待执行任务继续。" : nil
    }

    private var heroCard: some View {
        let next = store.displayedQueueCandidate
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PulseDot(color: .white, active: store.isQueueRunning(store.displayedQueuePlanID))
                        // 从没建过任务时说「已暂停」会误导（走查 2026-10-06：新用户没开始过哪来的暂停）
                        Text(store.isQueueRunning(store.displayedQueuePlanID) ? "排期正在运行"
                                : store.displayedQueueJobs.isEmpty ? "还没有排期"
                                : "排期已暂停")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                    }
                    Text(HomeBanner.title(nextRecipient: next?.recipient, reviewCount: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))))
                        .font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let next {
                        HStack(spacing: 8) {
                            Label("最早发送 " + store.earliestSendDate(next).formatted(date: .abbreviated, time: .standard), systemImage: "calendar")
                            Text("·")
                            Text(next.planName)
                            Text("·")
                            Text(SendChannel.displayName(next.channelName))
                        }
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    } else {
                        Text(HomeBanner.idleSubtitle(reviewCount: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    }
                    if let reviewNote {
                        Text(reviewNote)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let next {
                    VStack(spacing: 6) {
                        ProgressRing(progress: 1 - min(1, max(0, store.earliestSendDate(next).timeIntervalSinceNow / 3600)),
                                     size: 88, line: 8,
                                     gradient: LinearGradient(colors: [.white, .white.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                     track: .white.opacity(0.22))
                            .overlay {
                                VStack(spacing: 0) {
                                    Text("下一群").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(store.isQueueRunning(store.displayedQueuePlanID) ? CountdownText.format(store.earliestSendDate(next).timeIntervalSince(context.date)) : "已暂停")
                                            .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                                    }
                                }
                            }
                    }
                }
            }
            Spacer(minLength: 16)
            heroProgress
            HStack(spacing: 10) {
                if reviewNote != nil {
                    Button { store.route = "history" } label: { Label("去发送记录", systemImage: "exclamationmark.triangle.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                        .help("日志可稍后核对，不影响当前计划其他待执行任务")
                }
                if store.isQueueRunning(store.displayedQueuePlanID) {
                    Button { store.stop() } label: { Label("暂停全部", systemImage: "pause.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                } else {
                    Button { store.start(planID: store.displayedQueuePlanID) } label: { Label("启动当前计划", systemImage: "play.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                        .disabled(store.busy || store.displayedQueueCandidate == nil)
                    Button { store.route = "queue" } label: { Label("查看待发队列", systemImage: "list.bullet") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                        .disabled(!HomeBanner.showsQueueLink(queuedCount: store.displayedQueueJobs.filter { $0.status == "queued" }.count, reviewCount: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))))
                        .opacity(HomeBanner.showsQueueLink(queuedCount: store.displayedQueueJobs.filter { $0.status == "queued" }.count, reviewCount: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))) ? 1 : 0.5)
                }
                if HomeBanner.showsHeroCompose(reviewCount: QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))) {
                    Button { store.route = "compose" } label: { Label("新建发送", systemImage: "plus.circle.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                }
                Spacer()
                GlassPill(text: "全局间隔 \(store.settings.globalGapMinutes) 分钟", symbol: "timer")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Theme.brand)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(.white.opacity(0.16)).frame(width: 230, height: 230).blur(radius: 46).offset(x: 74, y: 118)
                }
                .overlay(alignment: .topLeading) {
                    Circle().fill(.black.opacity(0.14)).frame(width: 190, height: 190).blur(radius: 50).offset(x: -80, y: -96)
                }
                .clipShape(shape)
                .shadow(color: Theme.indigo.opacity(scheme == .dark ? 0.5 : 0.32), radius: 22, y: 12)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
        .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.9) }
    }

    private var heroProgress: some View {
        let planID = store.displayedQueuePlanID
        let jobs: [Delivery]
        if let planID {
            jobs = store.deliveries
                .filter { $0.planID == planID && $0.status != "cancelled" }
                .sorted { $0.scheduled < $1.scheduled }
        } else {
            jobs = []
        }
        return DispatchProgress3DCompact(
            segments: DispatchProgressMapper.segments(from: jobs, limit: jobs.count, running: store.isQueueRunning(store.displayedQueuePlanID)),
            doneCount: DispatchProgressMapper.doneCount(from: jobs),
            totalCount: jobs.count,
            queueRunning: store.isQueueRunning(store.displayedQueuePlanID)
        )
        .padding(.bottom, 6)
    }

    private var upcomingCard: some View {
        let upcoming = store.displayedQueueJobs.filter { $0.status == "queued" }.sorted { $0.scheduled < $1.scheduled }.prefix(5)
        return DepthSurface(radius: 20, padding: 20, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "接下来", symbol: "list.bullet.rectangle.portrait.fill", tint: Theme.indigo, trailing: "\(store.displayedQueueJobs.filter { $0.status == "queued" }.count) 条")
                if upcoming.isEmpty {
                    let empty = HomeBanner.upcomingEmpty(statuses: store.displayedQueueJobs.map(\.status))
                    EmptyPanel(title: empty.title, symbol: empty.needsReview ? "exclamationmark.triangle.fill" : "calendar", message: empty.message, tint: empty.needsReview ? Theme.amber : Theme.indigo, compact: true)
                } else {
                    VStack(spacing: 9) {
                        ForEach(Array(upcoming)) { job in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.scheduled, format: .dateTime.month().day().hour().minute())
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                    Text(RelativeDay.label(for: job.scheduled)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .frame(width: 96, alignment: .leading)
                                Rectangle().fill(StatusStyle.color(job.status)).frame(width: 3, height: 34).clipShape(Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(job.recipient).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        ChannelPill(channel: job.channelName, compact: true)
                                    }
                                    Text("\(job.planName) · \(job.assets.count) 个附件").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Pill(mode: job.mode)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 11)
                            .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                        }
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "快捷操作", symbol: "bolt.fill", tint: Theme.violet)
                let reviewCount = QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))
                actionRow(HomeBanner.firstShortcutTitle(reviewCount: reviewCount),
                          HomeBanner.firstShortcutGoesToHistory(reviewCount: reviewCount) ? "exclamationmark.triangle.fill" : "square.and.pencil",
                          Theme.brandUp) {
                    store.route = HomeBanner.firstShortcutGoesToHistory(reviewCount: reviewCount) ? "history" : "compose"
                }
                actionRow("导入素材", "square.and.arrow.down.fill", Theme.cool) { _ = store.chooseFiles() }
                actionRow("备份数据库", "externaldrive.fill.badge.checkmark", Theme.success) { store.backup() }
                actionRow("QQ 连接检查", "link.circle.fill", Theme.steel) {
                    let report = store.driver.diagnostic()
                    store.qqDiagnostic = report
                    store.step = report.split(whereSeparator: \.isNewline).first.map(String.init) ?? report
                }
            }
        }
    }

    private func actionRow(_ title: String, _ symbol: String, _ gradient: LinearGradient, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconTile(symbol: symbol, size: 26, gradient: gradient)
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(GhostPressButtonStyle())
        .hoverLift(2)
    }

    private var recipientSummary: some View {
        let enabled = store.recipients.filter(\.enabled).count
        return DepthSurface(radius: 20, padding: 18, accent: Theme.pink) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "名单状态", symbol: "person.2.fill", tint: Theme.pink)
                HStack(spacing: 14) {
                    ProgressRing(progress: store.recipients.isEmpty ? 0 : Double(enabled) / Double(store.recipients.count),
                                 size: 54, line: 6,
                                 gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay { Text("\(enabled)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.violet) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已启用 \(enabled) / \(store.recipients.count) 个群").font(.system(size: 12.5, weight: .medium))
                        Text("停用的群不会被新计划选中").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Button { store.route = "recipients" } label: { Text("管理名单") }.buttonStyle(SoftButtonStyle(tint: Theme.violet))
            }
        }
    }
}

enum RelativeDay {
    /// 走查 4-06 / 1-12：「今天/明天」与排期引擎用同一套日历（Scheduling.calendar，北京时间），
    /// 否则本机时区不是 Asia/Shanghai 时，同一屏会出现两套日期口径。
    static func label(for date: Date) -> String {
        let cal = Scheduling.calendar
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInTomorrow(date) { return "明天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        return days > 0 ? "\(days) 天后" : "\(-days) 天前"
    }
}

// MARK: - 预览模型

struct PlanPreview: Identifiable { let plan: Plan; let jobs: [Delivery]; var id: String { plan.id } }

// MARK: - 新建发送

struct ComposeView: View {
    let workspaceID: String
    @State private var creatingWorkspace = false
    @State private var newWorkspaceName = ""
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("composeTextExpanded") private var textExpanded = false
    @State private var text = ""
    @State private var name = "新一轮图文发送"
    @State private var recipients = Set<String>()
    @State private var assets = Set<String>()
    @State private var date = Date().addingTimeInterval(300)
    @State private var days = 1
    @State private var interval = 30
    @State private var times = "09:00,14:00,19:00"
    @State private var multiRound = false
    @State private var recurring = false
    @State private var recurringDays = 1
    @State private var mode = "automatic"
    @State private var previewData: PlanPreview?
    @State private var customGaps = false
    @State private var recipientGaps: [String:Int] = [:]
    @State private var addingRecipients = false
    @State private var newRecipients = ""
    @State private var addingChannel = SendChannel.qq
    @State private var deleteTemplateTarget: TextTemplate?
    private var selectedRecipients: [Recipient] { store.recipients.filter { recipients.contains($0.id) } }
    /// 走查 4-03：名单里被停用的群。「全选」不碰它们；单独勾选要先显式确认，
    /// 因为 `Scheduling.expand` 只接受已启用收件人（Core.swift），勾选一个停用群必然连带改写全局启用位。
    private var disabledRecipientIDs: Set<String> { Set(store.recipients.filter { !$0.enabled }.map(\.id)) }
    @State private var pendingEnable: Set<String> = []
    /// 待确认弹窗里显示的群名（按名单顺序，最多列 5 个）
    private var pendingEnableNames: String {
        store.recipients.filter { pendingEnable.contains($0.id) }.prefix(5).map(\.name).joined(separator: "、")
    }
    @State private var selectedTemplateID: String?
    // 表单生命周期内稳定的计划 id：展开结果与抖动种子可复现，预览所见即落盘所得。
    @State private var planID = UUID().uuidString
    // 展开结果记忆（类引用：写它的属性不算修改 SwiftUI 状态，不触发视图刷新循环）
    @State private var expandMemo = ExpandMemo()
    @State private var showAdvanced = false
    @State private var initialized = false
    @State private var groupSearch = ""
    @State private var onlySelected = false
    @State private var showAllGroups = false
    @State private var showMessage = true
    @State private var showImporter = false
    /// 待确认的建计划动作。弹窗的展示与否单独用 Bool，避免关弹窗把数据一并清空。
    private struct StagedPlanCreation { let plan: Plan; let start: Bool }
    @State private var stagedPlan: StagedPlanCreation?
    @State private var showPlanPurgeDialog = false
    private var matchingGroups: [Recipient] {
        store.recipients.filter { (!onlySelected || recipients.contains($0.id)) && (groupSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(groupSearch)) }
    }
    private var visibleGroups: [Recipient] { showAllGroups || !groupSearch.isEmpty || onlySelected ? matchingGroups : Array(matchingGroups.prefix(4)) }
    private var pendingImport: Bool {
        guard let space = store.workspaces.first(where: { $0.id == workspaceID }) else { return false }
        return !space.stagingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !space.stagingFiles.isEmpty
    }
    private var preparationIssue: String? {
        if pendingImport { return "还有导入内容未应用，请先应用或清空导入区" }
        if recipients.isEmpty { return "先选择至少一个群聊" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assets.isEmpty { return "填写本次文案，或添加图片 / 文件" }
        if case .failure(let error) = scheduleResult { return error.localizedDescription }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workspaceSection
                recipientsSection
                messageSection
                CollapsibleSection(title: "批量导入文字与图片", symbol: "square.and.arrow.down", tint: Theme.teal,
                                   badge: pendingImport ? "待应用" : nil, expanded: $showImporter) { unifiedComposer }
                advancedSection
            }
            .padding(22)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !initialized else { return }; initialized = true
            if let draft = store.workspaces.first(where: { $0.id == workspaceID })?.draft {
                text = draft.text; name = draft.name; recipients = Set(draft.recipientIDs).intersection(Set(store.recipients.map(\.id)))
                assets = Set(draft.assetIDs).intersection(Set(store.assets.map(\.id)))
                date = draft.starts; days = draft.days; interval = draft.interval; times = draft.times
                multiRound = draft.multiRound; mode = draft.mode; customGaps = draft.customGaps
                recipientGaps = draft.recipientGaps; selectedTemplateID = draft.selectedTemplateID
                // 开始时间自动读当前时间：只在加载草稿这一刻生效（切换群发空间会带新 id 重建本页，
                // 同样走到这里）。草稿开始时间早于等于当前时间（留 30 秒余量）时，改成「当前时间 + 60 秒、
                // 向上取整到分钟」并写回空间草稿持久化；用户手动设置的未来时间不在加载路径上，永远不会被覆盖。
                if draft.starts <= Date().addingTimeInterval(30) {
                    date = Self.freshStartDate()
                    store.saveDraft(draftSnapshot, workspaceID: workspaceID)
                    store.flushDraftPersist()
                }
            }
            showImporter = pendingImport
        }
        .onChange(of: draftSnapshot) { _, draft in if initialized { store.saveDraft(draft, workspaceID: workspaceID) } }
        // 离开新建发送页（含其中的一体化导入暂存框）时立即落盘防抖中的草稿
        .onDisappear { store.flushDraftPersist() }
        .onChange(of: assets) { _, _ in
            // 删除/新增配图立即同步到队列未发送任务，不必再点保存并同步
            guard initialized else { return }
            // 走查 1-03：带上当前草稿绑定的模板 id，同步只波及这个模板产生的计划
            store.syncUnsentAssets(draftSnapshot.assetIDs, workspaceID: workspaceID, templateID: selectedTemplateID)
        }
        .sheet(isPresented: $creatingWorkspace) {
            VStack(alignment: .leading, spacing: 18) {
                Text("新建群发空间").font(.title3.bold())
                Text("每个空间独立保存文案、所选群聊、素材与发送设置。新空间从空白开始。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("例如：活动通知、二手推广", text: $newWorkspaceName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { creatingWorkspace = false }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Spacer()
                    Button("创建空间") {
                        store.saveDraft(draftSnapshot, workspaceID: workspaceID)
                        store.createWorkspace(newWorkspaceName)
                        if store.error == nil { creatingWorkspace = false }
                    }.buttonStyle(DepthButtonStyle()).disabled(newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 480)
        }
        .sheet(isPresented:$addingRecipients) { addRecipientsSheet }
        // 走查 4-03：勾选已停用的群之前，把「会改写全局名单」这件事说清楚并要一次确认
        .alert("这些群在名单里是停用状态", isPresented: Binding(get: { !pendingEnable.isEmpty }, set: { if !$0 { pendingEnable = [] } })) {
            Button("确认勾选并恢复启用") { enableAndSelect(pendingEnable) }
            Button("取消", role: .cancel) { pendingEnable = [] }
        } message: {
            Text("「\(pendingEnableNames)」在全局群聊名单里已被停用。新建发送只能选已启用的收件人，勾选它们会把启用状态一并恢复到全局名单，之后所有空间的新计划都会把它们算进去。")
        }
        .alert("删除这条文案？", isPresented: Binding(get:{ deleteTemplateTarget != nil }, set:{ if !$0 { deleteTemplateTarget = nil } }), presenting: deleteTemplateTarget) { template in
            Button("删除", role: .destructive) {
                if selectedTemplateID == template.id { selectedTemplateID = nil; text = "" }
                store.deleteTextTemplate(template.id); deleteTemplateTarget = nil
            }
            Button("取消", role: .cancel) { deleteTemplateTarget = nil }
        } message: { template in
            Text("将删除「\(template.title.isEmpty ? "未命名文案" : template.title)」。素材与发送记录不受影响。")
        }
        .safeAreaInset(edge:.bottom) { bottomBar }
        .sheet(item:$previewData) { data in previewSheet(data).modifier(planPurgeDialog) }
        // 新排期开始前的旧记录确认。红线：任何路径都不得在用户未确认的情况下删除
        // uncertain/submitted 记录——只有这里的三个选项会带 includePendingReview 进入
        // purgePreviousPlanRecords；running/busy 时不弹、直接保留全部。
        // 底部操作条与预览弹层各挂一份同一内容的弹窗（预览弹层是 sheet，弹窗必须挂在
        // sheet 内容上才能正常弹出），共用同一份展示状态。
        .modifier(planPurgeDialog)
    }

    /// 建计划前的旧记录确认弹窗内容。
    private var planPurgeDialog: PlanPurgeDialogModifier {
        PlanPurgeDialogModifier(isPresented: $showPlanPurgeDialog, reviewPendingCount: reviewPendingCount) {
            runStagedPlan(includePendingReview: $0)
        }
    }

    private struct PlanPurgeDialogModifier: ViewModifier {
        @Binding var isPresented: Bool
        let reviewPendingCount: Int
        let onPick: (Bool?) -> Void
        func body(content: Content) -> some View {
            content.confirmationDialog(
                "新排期开始，上一排期的记录要怎么处理？",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("全部清空，不可恢复\(reviewPendingCount > 0 ? "（含 \(reviewPendingCount) 条待核对）" : "")", role: .destructive) {
                    onPick(true)
                }
                Button("只清已完成，保留待核对") { onPick(false) }
                Button("保留全部记录") { onPick(nil) }
                // 走查 2026-10-06：系统自动补的「OK」让人看不懂——显式给出反悔出口：不建了，原样返回
                Button("先不建了，返回", role: .cancel) { isPresented = false }
            } message: {
                Text("旧计划的发送记录按所选方式处理，不影响本次新计划的任务。「全部清空」后无法恢复，请确认旧排期不再需要。")
            }
        }
    }

    private var draftSnapshot: BroadcastDraft {
        BroadcastDraft(text: text, name: name, recipientIDs: store.recipients.filter { recipients.contains($0.id) }.map(\.id),
                       assetIDs: store.assets.filter { assets.contains($0.id) }.map(\.id), starts: date, days: days, interval: interval,
                       times: times, multiRound: multiRound, mode: mode, customGaps: customGaps, recipientGaps: recipientGaps, selectedTemplateID: selectedTemplateID)
    }
    private var workspaceSection: some View {
        HStack(spacing: 12) {
            Picker("群发空间", selection: Binding(get: { workspaceID }, set: { id in
                store.saveDraft(draftSnapshot, workspaceID: workspaceID)
                store.switchWorkspace(id)
            })) { ForEach(store.workspaces) { space in Text(space.name).tag(space.id) } }
                .frame(maxWidth: 300)
            Text("自动保存草稿").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { newWorkspaceName = ""; creatingWorkspace = true } label: { Label("新建空间", systemImage: "plus") }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
        }
    }

    private var messageSection: some View {
        CollapsibleSection(title: "2 · 文案与配图", symbol: "square.and.pencil", tint: Theme.indigo,
                           badge: "\(text.count) 字 · \(assets.count) 个附件", expanded: $showMessage) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("文案", selection: Binding(get: { selectedTemplateID ?? "" }, set: { id in
                        selectedTemplateID = id.isEmpty ? nil : id
                        text = store.settings.textTemplates?.first { $0.id == id }?.text ?? ""
                    })) {
                        Text("新文案").tag("")
                        ForEach(store.settings.textTemplates ?? []) { template in
                            Text(template.title.isEmpty ? "未命名文案" : template.title).lineLimit(1).tag(template.id)
                        }
                    }.frame(maxWidth: 320)
                    Spacer(minLength: 8)
                    CopyButton("复制文案") { try ClipboardCopy.text(text) }.disabled(text.isEmpty)
                    Button("保存并同步") {
                        store.perform { selectedTemplateID = try store.saveTextTemplate(id: selectedTemplateID, text: text, workspaceID: workspaceID, assetIDs: draftSnapshot.assetIDs) }
                    }.buttonStyle(DepthButtonStyle(compact: true))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assets.isEmpty)
                    Menu {
                        Button("另存为新文案") { store.perform { selectedTemplateID = try store.saveTextTemplate(text: text, workspaceID: workspaceID) } }
                        Button("删除当前文案", role: .destructive) { deleteTemplateTarget = store.settings.textTemplates?.first { $0.id == selectedTemplateID } }.disabled(selectedTemplateID == nil)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
                TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(height: 180).padding(10)
                    .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("本次发送文案")
                selectedAssetsStrip
                ImageDropTarget(hint: "把图片或文件从访达拖到这里，或点击选择",
                                onDrop:{ urls in
                    let imported = store.importFiles(urls)
                    assets.formUnion(imported)
                    if !imported.isEmpty { store.step = "已加入 \(imported.count) 个拖入文件，保存在素材库并选中" }
                },onError:{ store.error = $0 },onBrowse:{
                    assets.formUnion(store.chooseFiles())
                }).frame(height: 44)
                HStack(spacing: 8) {
                    Text(store.settings.textTemplates?.first(where: { $0.id == selectedTemplateID })?.text == text ? "已保存 · 未发送任务使用此文案" : "草稿已保留 · 保存后同步未发送任务")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { assets.formUnion(store.chooseFiles()) } label: { Label("添加配图", systemImage: "photo.badge.plus") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.teal))
                        .help("选择图片或文件")
                }
            }
        }
    }

    /// 已选配图横条：缩略图 + 移除，替代原「配图与文件」折叠区的选择功能
    @ViewBuilder private var selectedAssetsStrip: some View {
        let selected = store.assets.filter { assets.contains($0.id) }
        if !selected.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(selected) { a in
                        VStack(spacing: 3) {
                            ZStack(alignment: .topTrailing) {
                                AssetThumbnail(asset:a).frame(width: 76, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Button { assets.remove(a.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .buttonStyle(GhostPressButtonStyle())
                                .quietHover(lift: 1.5, scale: 1.04)
                                .padding(3)
                                .help("移除这张配图")
                            }
                            Text(a.name).font(.system(size: 9.5)).lineLimit(1).truncationMode(.middle)
                                .frame(width: 76).foregroundStyle(.secondary)
                        }
                    }
                    Button { assets.removeAll() } label: { Label("清空", systemImage: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                        .padding(.top, 16)
                        .help("清空本次选择")
                }
            }
        }
    }

    // MARK: 一体化发送框

    private var unifiedComposer: some View {
        UnifiedComposerView(workspaceID: workspaceID) { content in
            var imported = false
            store.perform {
                let result = try store.applyUnifiedContent(content, selectAssets: { ids in
                    assets.formUnion(ids)
                }, setText: { value in
                    text = value
                })
                if let templateID = result.templateID { selectedTemplateID = templateID }
                imported = true
            }
            return imported
        }
        .padding(.top, 2)
    }

    // MARK: 开始时间与间隔
    /// 原「3 · 时间与间隔」整卡并入第 1 张卡的右上角：标题在左、控件在右，
    /// 窄窗放不下时由 FlowHStack 自动换行。全部绑定与校验逻辑保持原样。
    private var scheduleControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            FlowHStack(hSpacing: 8, vSpacing: 8) {
                DatePicker("开始发送", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, Scheduling.calendar.timeZone)
                    .accessibilityLabel("开始发送日期和时间")
                    .fixedSize()
                roundMenu.fixedSize()
            }
            FlowHStack(hSpacing: 6, vSpacing: 6) {
                Text("每隔").font(.system(size: 12))
                TextField("分钟", value: $interval, format: .number).textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .accessibilityLabel("本次群间隔分钟数")
                Text("分钟换一群").font(.system(size: 12))
            }
            scheduleSummaryLine
            // 对标调研（go-cqhttp FAQ / 微信群发限制科普）：同内容高频触发风控是同类工具差评之首，
            // 把安全节奏写成显式建议，而不是等 blocked 了再解释。
            if interval < 10 {
                Text("间隔小于 10 分钟较容易触发 QQ 风控，建议 10 分钟以上并避开整点。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint = scheduleHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode == "draft" {
                // 草稿的真实代价（每条即停+逐条人工确认）事前可见，不再只藏在设置页
                Text("草稿模式：每填完一条草稿队列就会暂停，需要到发送记录逐条核对后再手动继续下一条。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.amber)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 走查 2026-10-06：排期摘要——实时显示「首群何时发 · 末群何时发 · 共几群」，
    /// 让用户在保存前就能看到整个发送计划的时间跨度，不用保存后去队列页确认。
    private var scheduleSummaryLine: some View {
        Group {
            if case .success(let deliveries) = scheduleResult, !deliveries.isEmpty {
                let first = deliveries.first!.scheduled
                let last = deliveries.last!.scheduled
                let fmt = first.formatted(.dateTime.month().day().hour().minute())
                let lastFmt = last.formatted(.dateTime.hour().minute())
                let sameDay = calendar.isDate(first, inSameDayAs: last)
                let text = sameDay
                    ? "共 \(deliveries.count) 群：\(fmt) 开始 → \(lastFmt) 发完"
                    : "共 \(deliveries.count) 群：\(fmt) 开始 → \(last.formatted(.dateTime.month().day().hour().minute())) 发完"
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.indigo)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var calendar: Calendar { Scheduling.calendar }

    private var roundMenu: some View {
        Menu {
            // 切回单轮只关闭多轮。开始时间保持手输的值，不用“现在起 5 分钟”盖掉。
            Button("单轮") { multiRound = false }
            Button("每天三轮 · 每 5 小时一轮") { applyTemplate("09:00,14:00,19:00") }
            Button("每天四轮 · 每 6 小时一轮") { applyTemplate("00:00,06:00,12:00,18:00") }
            Button("每天八轮 · 每 3 小时一轮") { applyTemplate("00:00,03:00,06:00,09:00,12:00,15:00,18:00,21:00") }
        } label: { Label(multiRound ? "每天多轮" : "单轮（只发这一次）", systemImage: "repeat") }
            .help("首轮从选定的日期和时间开始，后续轮次保持所选间隔")
            .buttonStyle(SoftButtonStyle(tint: Theme.violet))
    }

    /// 过期和低于下限仍由 scheduleResult 拦住保存、预览和启动。这里只留一句。
    private var scheduleHint: String? {
        let minimum = store.settings.globalGapMinutes
        let past = date < Date()
        let low = interval < minimum
        if past && low { return "开始时间已过，间隔低于 \(minimum) 分钟下限。" }
        if past { return "开始时间已过，请改日期或时间。" }
        if low { return "间隔低于 \(minimum) 分钟下限。" }
        if case .failure(let error) = scheduleResult {
            let message = error.localizedDescription
            if message.contains("已经过去") { return "开始时间已过，请改日期或时间。" }
            if message.contains("最小间隔") || (message.contains("间隔") && message.contains("小于")) {
                return "有间隔低于 \(minimum) 分钟下限。"
            }
            return message
        }
        return nil
    }

    // MARK: 收件人

    private var recipientsSection: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("1 · 选择群聊", systemImage: "person.2.fill").font(.system(size: 17, weight: .bold))
                        Text("已选 \(recipients.count) / 共 \(store.recipients.count) 个群")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.violet)
                    }
                    Spacer(minLength: 12)
                    scheduleControls
                }
                Text("点击群名即可勾选或取消。这里只决定本次发送给谁，不会修改已有队列。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let caution = SendChannel.composeCaution(channels: selectedRecipients.map(\.channelName), automatic: mode == "automatic") {
                    Text(caution)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedRecipients.contains(where: { $0.channelName == SendChannel.wechat }) ? Theme.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    // 走查 4-03：「全选」只选已启用的群，不再一颗按钮批量把停用群翻成启用（那会改写全局名单）
                    Button { selectRecipients(Set(store.recipients.filter(\.enabled).map(\.id))) } label: {
                        Label("全选 \(store.recipients.filter(\.enabled).count) 个已启用的群", systemImage: "checkmark.circle.fill")
                    }.buttonStyle(DepthButtonStyle())
                    Button("取消全选") { recipients.removeAll() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Spacer()
                    Button { addingRecipients = true } label: { Label("导入群聊名称", systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet))
                }
                if !disabledRecipientIDs.isEmpty {
                    // 停用的群要单独确认：Scheduling.expand 只接受已启用收件人，勾选它必然连带恢复全局启用位
                    Text("名单里有 \(disabledRecipientIDs.count) 个已停用的群（行上带「已停用」标记）。全选不会选中它们；单独勾选会先问你一次。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField("搜索群名", text: $groupSearch).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("搜索可选群聊")
                    Toggle("只看已选", isOn: $onlySelected).toggleStyle(.checkbox)
                }
                if store.recipients.isEmpty {
                    Text("还没有群聊，点击上方“导入群聊名称”，每行粘贴一个群名即可。")
                        .font(.system(size: 12)).padding(.vertical, 10)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(visibleGroups) { r in recipientRow(r) }
                    }
                }
                if matchingGroups.isEmpty && !store.recipients.isEmpty {
                    Text("没有匹配的群聊，试试其他关键词或关闭“只看已选”。").font(.caption).foregroundStyle(.secondary)
                }
                if groupSearch.isEmpty && !onlySelected && matchingGroups.count > 4 {
                    Button(showAllGroups ? "收起群聊列表" : "展开全部 \(matchingGroups.count) 个群") { showAllGroups.toggle() }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet))
                }
                HStack {
                    Text(store.recipients.isEmpty ? "添加群聊后即可选择" : {
                        let enabled = store.recipients.filter(\.enabled)
                        let unselectedEnabled = enabled.filter { !recipients.contains($0.id) }.count
                        let disabled = store.recipients.count - enabled.count
                        if unselectedEnabled > 0 {
                            return "还有 \(unselectedEnabled) 个群未选，点击上方群名加入" + (disabled > 0 ? "；另有 \(disabled) 个已停用群不列入全选" : "")
                        }
                        return disabled > 0 ? "可选群已全部选中；另有 \(disabled) 个已停用群" : "已选择全部群聊"
                    }())
                        .font(.system(size: 11)).foregroundStyle(Theme.violet)
                    Spacer()
                    Toggle("分别设置群间隔",isOn:$customGaps).toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private func recipientRow(_ r: Recipient) -> some View {
        let on = recipients.contains(r.id)
        return VStack(alignment:.leading,spacing:6) {
            Button {
                if on { recipients.remove(r.id) } else { selectRecipients([r.id]) }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(on ? Theme.violet : .secondary)
                    Text(r.name).font(.system(size: 13, weight: on ? .medium : .regular))
                        .fixedSize(horizontal:false,vertical:true).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    ChannelPill(channel: r.channelName, compact: true)
                    if !r.enabled { Pill(text: "已停用", tint: Theme.slate, symbol: "slash.circle", variant: .neutral) }
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(on ? Theme.violet.opacity(scheme == .dark ? 0.14 : 0.07) : Surface(scheme).inset.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Theme.violet.opacity(0.25) : Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostPressButtonStyle())
            .quietHover(lift: 2, scale: 1)

            if customGaps && on {
                if selectedRecipients.first?.id == r.id {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Theme.green)
                        Text("本轮首群 · 从开始时间发送").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.leading, 30)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("距上一群").font(.system(size: 11))
                        TextField("分钟",value:Binding(get:{recipientGaps[r.id] ?? interval},set:{recipientGaps[r.id] = $0}),format:.number)
                            .textFieldStyle(.roundedBorder).frame(width:64)
                            .accessibilityLabel("\(r.name) 距上一群分钟数")
                        Text("分钟").font(.system(size: 11))
                    }.padding(.leading, 30)
                }
            }
        }
    }

    // MARK: 更多设置

    private var advancedSection: some View {
        CollapsibleSection(title: "更多设置", symbol: "slider.horizontal.3", tint: Theme.slate,
                           badge: mode == "draft" ? "草稿模式" : nil, expanded: $showAdvanced) {
            TextField("计划名称",text:$name).textFieldStyle(.roundedBorder)
            Stepper("持续 \(days) 天",value:$days,in:1...30)
            Toggle("每天多个轮次",isOn:$multiRound).toggleStyle(.switch)
            if multiRound {
                TextField("轮次参考时刻：09:00,14:00,19:00",text:$times).textFieldStyle(.roundedBorder)
                Text("首轮以开始发送时间为准；参考时刻只决定后续轮次之间的间隔。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("执行方式",selection:$mode) { Text("自动发送").tag("automatic"); Text("仅填草稿").tag("draft") }.pickerStyle(.segmented)
            Toggle("循环发送",isOn:$recurring).toggleStyle(.switch)
            if recurring {
                Stepper("间隔 \(recurringDays) 天进入下一轮",value:$recurringDays,in:1...30)
                Text("一轮全部发送完成且无待核对任务时，自动按相同时间表生成下一轮；是否发送仍由队列启动控制")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(SendChannel.sendForegroundNote(channels: store.recipients.filter { recipients.contains($0.id) }.map(\.channelName), automatic: mode == "automatic"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 底部操作条

    private var bottomBar: some View {
        SideOrBelow(spacing: 8, minLeading: 120) {
            HStack(spacing: 8) {
                IconTile(symbol: "tray.full.fill", size: 28, gradient: Theme.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recipients.count == store.recipients.count ? "共 \(store.recipients.count) 群 · \(assets.count) 个附件" : "已选 \(recipients.count) / 共 \(store.recipients.count) 群 · \(assets.count) 个附件").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(footerNotice)
                        .font(.system(size: 10.5)).foregroundStyle(preparationIssue == nil ? Theme.slate : Theme.orange).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FlowHStack(hSpacing: 8, vSpacing: 6) {
                Button("仅保存") { beginPlanCreation(start: false) }
                    .buttonStyle(SoftButtonStyle(tint: Theme.slate)).gateDisabled(preparationIssue != nil || store.busy,
                    hint: preparationIssue ?? "正在执行发送，等这一条结束后再保存")
                    .help("保存为新的独立队列；保留已有队列与记录").fixedSize()
                Button("预览内容与排期") { makePreview() }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    .gateDisabled(preparationIssue != nil, hint: preparationIssue ?? "").fixedSize()
                Button { beginPlanCreation(start: true) } label: { Label("启动排期", systemImage: "play.fill") }
                    .buttonStyle(DepthButtonStyle())
                    .gateDisabled(store.busy || preparationIssue != nil,
                                  hint: store.busy ? "正在执行发送，等这一条结束后再操作"
                                  : (preparationIssue ?? ""))
                    .help("保存并启动新的独立队列；保留已有队列与记录")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    /// 底部和卡片共用一句。按钮仍看 preparationIssue，过期和低于下限时保持禁用。
    private var footerNotice: String {
        if let hint = scheduleHint { return hint }
        if let issue = preparationIssue { return issue }
        return ComposeFooterStatus.line(busy: store.busy, running: store.running)
    }

    // MARK: 弹窗

    private var addRecipientsSheet: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing: 12) {
                IconTile(symbol: "person.badge.plus", size: 38, gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入群聊名称").font(.title3.bold())
                    Text(SendChannel.addNamesHint(channel: addingChannel) + "添加后自动选中。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("发送渠道", selection: $addingChannel) {
                Text("QQ 群").tag(SendChannel.qq)
                Text("微信群").tag(SendChannel.wechat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextEditor(text:$newRecipients).frame(height:190).scrollContentBackground(.hidden)
                .padding(8)
                .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            HStack {
                Button("取消") { addingRecipients = false }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                Button("添加并选中") {
                    let names = Set(newRecipients.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty })
                    store.addRecipients(newRecipients, channel: addingChannel)
                    if store.error == nil {
                        // 走查 4-01：回选限定在本次渠道，同名但属于另一个渠道的既有条目不能被选进这次发送
                        selectRecipients(Set(store.recipients.filter { names.contains($0.name) && $0.channelName == addingChannel }.map(\.id)))
                        newRecipients = ""; addingRecipients = false
                    }
                }.buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), tint: Theme.violet))
                .disabled(newRecipients.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:580)
    }

    private func previewSheet(_ data: PlanPreview) -> some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment: .center, spacing: 6) {
                // 立体图标的投影画在自身布局框外，不留空就会压住标题和副标题的第一个字。
                IconTile(symbol: "checkmark.seal.fill", size: 36, gradient: Theme.brand)
                    .padding(.trailing, 20)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("核对这次发送").font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(data.jobs.count) 条任务 · \(data.plan.mode == "draft" ? "草稿模式" : "自动发送") · \(data.plan.assetIDs.count) 个附件")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .zIndex(1)
                Spacer(minLength: 8)
                if let first = data.jobs.first?.scheduled, first > Date() { CountdownText(target: first, prefix: "距首次", compact: true).fixedSize() }
            }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    AttachmentStrip(assets:data.jobs.first?.assets ?? [])
                    CopyButton("复制文案") { try ClipboardCopy.text(data.plan.text) }.disabled(data.plan.text.isEmpty)
                    Text(data.plan.text.isEmpty ? "（仅附件）" : data.plan.text).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                }
            }.frame(height:200).padding(12)
                .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            if let caution = SendChannel.composeCaution(channels: data.jobs.map(\.channelName), automatic: data.plan.mode != "draft") {
                Text(caution)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(data.jobs.contains(where: { $0.channelName == SendChannel.wechat }) ? Theme.orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(data.jobs) { job in
                        HStack(spacing: 10) {
                            Text(job.scheduled,format:.dateTime.month().day().hour().minute()).monospacedDigit().frame(width:130,alignment:.leading).font(.system(size: 12))
                            HStack(spacing: 5) {
                                Text(job.recipient).font(.system(size: 12)).lineLimit(1)
                                ChannelPill(channel: job.channelName, compact: true)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }.frame(minHeight:140)
            HStack {
                Button("返回编辑") { previewData = nil }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                Button("仅保存排期") { beginPlanCreation(plan: data.plan, start: false) }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                Button("创建并启动本计划") { beginPlanCreation(plan: data.plan, start: true) }
                    .buttonStyle(DepthButtonStyle())
                    .gateDisabled(store.busy, hint: "当前 QQ 操作结束后即可创建并启动新队列")
            }
        }.padding(24).frame(width:720,height:640)
        // 同根视图：预览弹层里的「创建并启动本计划」被门控点按时，提示条要在弹层内可见
        .overlay(alignment: .bottom) { DeniedToast().padding(.bottom, 44) }
    }

    // MARK: 逻辑

    /// 底部「仅保存 / 启动排期」共用入口：先按原逻辑校验并构建计划，再决定旧记录怎么处理。
    /// 有旧记录且队列空闲时先弹确认（见 body 上的 confirmationDialog）；
    /// 红线：任何路径都不得在用户未确认的情况下删除 uncertain/submitted 记录，
    /// running/busy 时不弹也不清，行为与从前一致（保留全部记录）。
    private func beginPlanCreation(start: Bool) {
        guard preparationIssue == nil else { store.error = preparationIssue; return }
        let plan: Plan
        do {
            _ = try scheduleResult.get()
            plan = try draftPlan()
        } catch { store.error = error.localizedDescription; return }
        beginPlanCreation(plan: plan, start: start)
    }

    /// 预览弹层里的两个按钮：计划在打开预览时已构建并校验过，直接进入建计划流程。
    private func beginPlanCreation(plan: Plan, start: Bool) {
        runPlan(plan, start: start, includePendingReview: nil)
    }

    /// 弹窗三个选项的落点：includePendingReview=nil 表示保留全部记录，只建计划不清旧账。
    private func runStagedPlan(includePendingReview: Bool?) {
        guard let staged = stagedPlan else { return }
        runPlan(staged.plan, start: staged.start, includePendingReview: includePendingReview)
    }

    /// 先清旧记录（用户已确认口径）再照常执行原建计划动作；两条都在 perform 里，失败写 error 通道。
    private func runPlan(_ plan: Plan, start: Bool, includePendingReview: Bool?) {
        if let includePendingReview {
            store.purgeThenCreate(plan: plan, start: start, includePendingReview: includePendingReview)
        } else {
            store.perform {
                if start { try store.addAndStart(plan) } else { try store.addPlan(plan) }
                previewData = nil
            }
        }
    }

    /// 弹窗选项里「待核对」的条数：按 QueueStartGate.reviewStatuses 统计完整日志，不改变清理范围。
    private var reviewPendingCount: Int { QueueStartGate.reviewCount(store.deliveries.map(\.status)) }

    /// 「当前时间 + 60 秒」向上取整到下一个整分钟。只在加载过期草稿时使用；
    /// 与排期引擎共用 Scheduling.calendar（北京时间）这套日历口径。
    private static func freshStartDate(from now: Date = Date()) -> Date {
        let target = now.addingTimeInterval(60)
        let cal = Scheduling.calendar
        let floored = cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: target)) ?? target
        return floored < target ? (cal.date(byAdding: .minute, value: 1, to: floored) ?? target) : floored
    }

    private func applyTemplate(_ value: String) {
        times = value; multiRound = true; mode = "automatic"
    }
    /// 走查 4-03：「本次发给谁」是局部选择，不再静默把全局名单的 `enabled` 翻成启用。
    /// 命中已停用的群时先问一次（`pendingEnable` 弹窗）：确认后才恢复启用并选中，取消就什么都不改。
    /// 之所以不能只选不启用：`Scheduling.expand` 硬性要求收件人 `enabled`（Core.swift 的「收件人不存在或已停用」）。
    private func selectRecipients(_ ids: Set<String>) {
        let blocked = ids.intersection(disabledRecipientIDs)
        guard blocked.isEmpty else { pendingEnable = blocked; return }
        recipients.formUnion(ids)
    }
    /// 弹窗确认后真正落笔：把这几个群恢复启用（写盘）并选进本次发送
    private func enableAndSelect(_ ids: Set<String>) {
        for index in store.recipients.indices where ids.contains(store.recipients[index].id) {
            store.recipients[index].enabled = true
        }
        recipients.formUnion(ids)
        store.saveSettings()
        pendingEnable = []
    }
    private func draftPlan() throws -> Plan {
        // 计划 id 在表单生命周期内保持稳定：同一份草稿反复展开（摘要行/预览/落盘）得到同一批
        // 任务 id 与抖动种子，预览所见即落盘所得；保存后重新打开表单才会生成新的 id。
        let start = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
        let slots = multiRound ? try Scheduling.times(times) : []
        var plan = Plan(id: planID,name:"【\(store.workspaceName)】" + (name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名计划" : name),text:text,assetIDs:store.assets.filter{assets.contains($0.id)}.map(\.id),recipientIDs:selectedRecipients.map(\.id),starts:start,days:days,times:slots,intervalMinutes:interval,mode:mode,recipientGaps:customGaps ? recipientGaps : nil, workspaceID: workspaceID, textTemplateID: selectedTemplateID, recurringEveryDays: recurring ? recurringDays : nil)
        if multiRound { plan.scheduleOffsetSeconds = try Scheduling.initialScheduleOffset(starts: start, times: slots) }
        return plan
    }
    /// 展开结果记忆：一次 body 求值会多次读取排期（摘要行、校验、底栏按钮、hint），打字或焦点
    /// 变化都触发整页重算；大计划下 expand 每次构造上千个 Delivery。这里按「计划字段 + 名单 +
    /// 素材 + 全局间隔 + 抖动开关」做键，输入没变就复用上次结果。文本参与键值，命中即与重算一致。
    private final class ExpandMemo {
        var key = ""
        var value: Result<[Delivery], Error>?
    }
    private var expandKey: String {
        let selectedIDs = selectedRecipients.map(\.id)
        let planInputs: [String] = [
            planID, name, text, selectedTemplateID ?? "", String(date.timeIntervalSince1970),
            String(days), multiRound ? times : "", String(interval), mode,
            customGaps ? recipientGaps.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") : "",
            selectedIDs.sorted().joined(separator: ","), String(recurring), String(recurringDays),
            workspaceID,
        ]
        let storeInputs: [String] = [
            store.workspaceName,
            String(store.settings.globalGapMinutes), String(store.settings.staggerJitter ?? false),
            store.recipients.filter { selectedIDs.contains($0.id) }.map(String.init(describing:)).joined(separator: "|"),
            store.assets.filter { assets.contains($0.id) }.map(String.init(describing:)).joined(separator: "|"),
        ]
        return (planInputs + storeInputs).joined(separator: "\u{1F}")
    }
    private var scheduleResult: Result<[Delivery],Error> {
        let key = expandKey
        if let memo = expandMemo.value, expandMemo.key == key { return memo }
        let fresh = Result {
            let plan = try draftPlan()
            guard interval >= store.settings.globalGapMinutes else { throw AppError("统一间隔不得小于全局最小间隔 \(store.settings.globalGapMinutes) 分钟") }
            for id in plan.recipientIDs.dropFirst() { guard (plan.recipientGaps?[id] ?? interval) >= store.settings.globalGapMinutes else { throw AppError("逐群间隔不得小于全局最小间隔 \(store.settings.globalGapMinutes) 分钟") } }
            return try Scheduling.expand(plan,recipients:store.recipients,assets:store.assets,jitter:store.settings.staggerJitter ?? false)
        }
        expandMemo.key = key
        expandMemo.value = fresh
        return fresh
    }
    private func makePreview() {
        store.perform {
            // 直接复用 scheduleResult：同一份输入只展开一次（此前预览会把同一计划再展开一遍）
            let jobs = try scheduleResult.get()
            let plan = try draftPlan()
            previewData = PlanPreview(plan:plan,jobs:jobs)
        }
    }
}

// MARK: - 素材缩略图

struct AssetThumbnail: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    let asset: Asset
    var body: some View {
        Group {
            if asset.isImage, let image = ImageAttachment.thumbnail(at:store.db.url(for:asset)) {
                Image(nsImage:image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.indigo.opacity(0.14), Theme.violet.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: asset.isImage ? "photo" : "doc.fill")
                        .font(.system(size: 22)).foregroundStyle(Theme.indigo.opacity(0.8))
                }
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(Surface(scheme).inset)
        .clipped()
        .accessibilityLabel(asset.name)
    }
}

struct AttachmentStrip: View {
    @EnvironmentObject var store: Store
    let assets: [Asset]
    /// 详情面板里只作预览：缩略图与文件名收小，把竖向空间留给状态说明和正文。
    var compact: Bool = false
    var body: some View {
        if !assets.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment:.top,spacing: compact ? 9 : 12) {
                    ForEach(assets) { asset in
                        VStack(spacing: compact ? 4 : 5) {
                            AssetThumbnail(asset:asset).frame(width: compact ? 84 : 110, height: compact ? 72 : 96)
                                .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 10, style: .continuous))
                            Text(asset.name).font(.caption).lineLimit(compact ? 1 : 2)
                                .frame(width: compact ? 84 : 110)
                                .help(asset.name)
                            CopyButton(asset.isImage ? "复制图片" : "复制文件") { try ClipboardCopy.file(store.db.url(for:asset),isImage:asset.isImage) }
                                .font(.system(size: compact ? 11 : 13))
                        }
                    }
                }
            }.frame(height: compact ? 148 : 180)
        }
    }
}

// MARK: - 素材库

struct AssetsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var sort = "recent"
    @State private var grid = true
    @State private var deleteTarget: Asset?
    @State private var renameTarget: Asset?
    @State private var renameText = ""
    @State private var previewAsset: Asset?

    private var list: [Asset] {
        let filtered = store.assets.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case "name": return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "size": return filtered.sorted { $0.bytes > $1.bytes }
        default: return filtered.sorted { $0.imported > $1.imported }
        }
    }

    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("搜索素材名称",text:$search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Surface(scheme).card.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                .frame(maxWidth: 300)

                Picker("", selection: $sort) {
                    Text("最近导入").tag("recent"); Text("名称").tag("name"); Text("大小").tag("size")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)

                Spacer()
                Button { grid.toggle() } label: {
                    Image(systemName: grid ? "square.grid.2x2" : "list.bullet")
                }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                .help(grid ? "切换为列表视图" : "切换为网格视图")
                .accessibilityLabel(grid ? "切换为列表视图" : "切换为网格视图")
                Button { store.chooseFiles() } label: { Label("导入素材", systemImage: "plus") }
                    .buttonStyle(DepthButtonStyle(gradient: Theme.cool, tint: Theme.teal))
            }
            .padding(.horizontal, 22).padding(.top, 18)

            ScrollView {
                if store.assets.isEmpty {
                    EmptyPanel(title: "素材库还是空的", symbol: "photo.on.rectangle.angled", message: "导入后可反复选择发送，文件保存在本机。", tint: Theme.teal)
                        .padding(.top, 40)
                } else if list.isEmpty {
                    EmptyPanel(title: "没有匹配的素材", symbol: "magnifyingglass", message: "换个关键词试试。", tint: Theme.slate)
                        .padding(.top, 40)
                } else {
                    if grid {
                        // 下限 220 ≥ 卡片内容最小宽度（按钮行），否则单元格被撑爆：
                        // 相邻卡片互相叠压、整行越出边距，窄窗口下首卡被推到左缘裁切
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:220,maximum:320),spacing:16)],spacing:16) {
                            ForEach(list) { a in assetCard(a) }
                        }.padding(.horizontal, 22).padding(.vertical, 4)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(list) { a in assetRow(a) }
                        }.padding(.horizontal, 22).padding(.vertical, 4)
                    }
                }
            }
            .padding(.bottom, 18)
        }
        .alert("删除这个素材？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { asset in
            Button("删除", role: .destructive) { store.deleteAsset(asset.id); deleteTarget = nil }
            Button("保留", role: .cancel) {}
        } message: { asset in
            Text("将从素材库移除「\(asset.name)」并删除本机副本；已发送任务的详情仍会保留，但将无法再复制这张图片。若素材正被计划或待执行任务使用，会提示无法删除。")
        }
        .alert("重命名素材", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }), presenting: renameTarget) { asset in
            TextField("素材名称", text: $renameText)
            Button("保存") { store.renameAsset(asset.id, to: renameText); renameTarget = nil }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: { asset in
            Text("为「\(asset.name)」取一个新名字。扩展名会自动保留；待执行任务会同步更新，发送不受影响。")
        }
        .sheet(item: $previewAsset) { asset in AssetPreviewSheet(asset: asset) }
    }

    private func assetCard(_ a: Asset) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button { previewAsset = a } label: {
                AssetThumbnail(asset:a).frame(height:158)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 15, topTrailingRadius: 15))
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostPressButtonStyle())
            .help("点击预览大图")
            VStack(alignment:.leading,spacing:7) {
                Button { renameTarget = a; renameText = a.name } label: {
                    Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .truncationMode(.middle)
                        .frame(height:34, alignment:.topLeading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GhostPressButtonStyle())
                .foregroundStyle(.primary)
                .help("点击重命名")
                HStack(spacing: 6) {
                    Pill(text: ByteCountFormatter.string(fromByteCount:a.bytes,countStyle:.file), tint: Theme.slate, symbol: "internaldrive.fill", variant: .neutral)
                    if a.isImage { Pill(text: "图片", tint: Theme.teal, symbol: "photo.fill", variant: .neutral) }
                    Spacer(minLength: 0)
                    Button { deleteTarget = a } label: { Image(systemName: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                        .help("删除此素材")
                }
                HStack(spacing: 6) {
                    // 卡片宽度有限：用短标签“复制”，完整说明在悬停提示里
                    CopyButton("复制") { try ClipboardCopy.file(store.db.url(for:a),isImage:a.isImage) }
                    Button { NSWorkspace.shared.open(store.db.url(for:a)) } label: {
                        Text("预览").lineLimit(1)
                    }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.db.url(for:a)]) } label: {
                        Image(systemName: "folder")
                    }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    .help("在 Finder 中显示")
                    Spacer(minLength: 0)
                }
            }.padding(12)
        }
        .background(Surface(scheme).card.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .shadow(color: Surface(scheme).shadowSoft, radius: 10, y: 6)
        .shadow(color: Surface(scheme).shadow, radius: 1.5, y: 1)
        .hoverLift(3)
    }

    private func assetRow(_ a: Asset) -> some View {
        HStack(spacing: 12) {
            Button { previewAsset = a } label: {
                AssetThumbnail(asset:a).frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(GhostPressButtonStyle())
            .quietHover(lift: 1.5, scale: 1.04)
            .help("点击预览")
            Button { renameTarget = a; renameText = a.name } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount:a.bytes,countStyle:.file)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(GhostPressButtonStyle())
            .quietHover(lift: 2, scale: 1)
            .foregroundStyle(.primary)
            .help("点击重命名")
            Spacer()
            CopyButton(a.isImage ? "复制图片" : "复制文件") { try ClipboardCopy.file(store.db.url(for:a),isImage:a.isImage) }
                    Button("预览") { NSWorkspace.shared.open(store.db.url(for:a)) }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.db.url(for:a)]) } label: { Image(systemName: "folder") }
                .buttonStyle(SoftButtonStyle(tint: Theme.slate))
            Button { deleteTarget = a } label: { Image(systemName: "trash") }
                .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                .help("删除此素材")
        }
        .padding(10)
        .background(Surface(scheme).card.opacity(0.85), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .shadow(color: Surface(scheme).shadowSoft, radius: 5, y: 3)
    }
}

// MARK: - 素材预览弹窗

/// 应用内大图预览：不用跳到外部程序就能确认素材内容，顺带提供复制与 Finder 定位
struct AssetPreviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let asset: Asset
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: asset.isImage ? "photo.fill" : "doc.fill", size: 34, gradient: Theme.cool)
                Text(asset.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Surface(scheme).inset)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: asset.isImage ? "photo" : "doc.fill")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                CopyButton(asset.isImage ? "复制图片" : "复制文件") { try ClipboardCopy.file(store.db.url(for:asset),isImage:asset.isImage) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.db.url(for:asset)]) }
                    .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount:asset.bytes,countStyle:.file))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 660, height: 600)
        .onAppear { image = ImageAttachment.largePreview(at: store.db.url(for: asset)) }
    }
}

// MARK: - 群与联系人

/// 「来自关系回响」卡片的视图层判定。排版留在视图里，判定集中在这里，便于隔离验证。
enum InboxViewRules {
    /// 名单为空时的三种情形不能互相冒充：从没同步过是首次使用，同步失败是故障，
    /// 收到过空名单是用户在关系回响主动清空。
    enum EmptyRoster: Equatable { case neverSynced, syncFailed, noneSelected }
    static func emptyRoster(hasSnapshot: Bool, isStale: Bool) -> EmptyRoster {
        // 走查 2026-10-06：isStale（同步目录失效）优先于 !hasSnapshot——否则"曾同步过但数据过期"
        // 会被当成"从未同步"，与顶部红色"同步失败"banner 矛盾。
        if isStale { return .syncFailed }
        if !hasSnapshot { return .neverSynced }
        return .noneSelected
    }
    static func hasFilters(search: String, tagName: String) -> Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tagName.isEmpty
    }
    /// 标签按显示名去重：源端同名不同 ID 的标签在菜单里长得一模一样，用户无从选择，
    /// 而他想要的结果本来就是两者的并集。ID 只用于跨来源稳定性，不进入这一层筛选。
    static func tagOptions(_ contacts: [RelationshipContact]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for contact in contacts {
            for name in Set(contact.tags.map(\.name)) { counts[name, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func applyTag<T: Equatable>(_ found: [T], tagName: String, tagsOf: (T) -> [RelationshipTag]) -> [T] {
        guard !tagName.isEmpty else { return found }
        return found.filter { contact in tagsOf(contact).contains { $0.name == tagName } }
    }
    /// 点「打开微信聊天」会把 store.busy 置位；这段自有定位期间不该反过来叫用户去暂停队列。
    static func isOwnLocating(isOpening: Bool, busy: Bool, running: Bool, importingList: Bool, operationApp: String) -> Bool {
        if isOpening { return true }
        let wechat = SendChannel.displayName(SendChannel.wechat)
        return busy && !running && !importingList && operationApp == wechat
    }
    static func aliasFeedbackFailed(_ message: String) -> Bool { !message.isEmpty && message != AliasFeedback.saved }

    /// macOS 上 SwiftUI 不会因为 sizeCategory 自动改字号：实测把 .large / .extraLarge /
    /// .accessibilityLarge 注入环境后，`.system(size:)`、语义字体和 @ScaledMetric 三种写法的
    /// 渲染高度逐档相同。所以这张卡自己按有效文字大小取倍数，字号不再被硬锁在固定值上。
    /// macOS 默认上报 .large，必须锚在 1.0，否则所有人在默认状态下就被放大；低于默认档也不缩。
    static func fontScale(for category: ContentSizeCategory) -> CGFloat {
        switch category {
        case .extraLarge: return 1.12
        case .extraExtraLarge: return 1.25
        case .extraExtraExtraLarge: return 1.38
        case .accessibilityMedium: return 1.45
        case .accessibilityLarge: return 1.60
        case .accessibilityExtraLarge: return 1.80
        case .accessibilityExtraExtraLarge: return 2.00
        case .accessibilityExtraExtraExtraLarge: return 2.20
        default: return 1.0
        }
    }
    /// 默认档必须逐字回到原字号，缩放后按整磅取整，避免半磅模糊。
    static func scaledSize(_ base: CGFloat, scale: CGFloat) -> CGFloat { (base * scale).rounded() }
}

/// 视图内统一取字号：默认档下与原来的 `.system(size:)` 完全一致。
private func inboxFont(_ base: CGFloat, scale: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: InboxViewRules.scaledSize(base, scale: scale), weight: weight)
}

struct RelationshipInboxView: View {
    @EnvironmentObject var store: Store
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var inbox: RelationshipInbox
    @State private var search = ""
    @State private var selectedTagName = ""
    @FocusState private var searchFocused: Bool

    private var fontScale: CGFloat { InboxViewRules.fontScale(for: sizeCategory) }
    private func f(_ base: CGFloat, weight: Font.Weight = .regular) -> Font { inboxFont(base, scale: fontScale, weight: weight) }
    private var hasFilters: Bool { InboxViewRules.hasFilters(search: search, tagName: selectedTagName) }
    private var tagOptions: [(name: String, count: Int)] { InboxViewRules.tagOptions(inbox.contacts) }
    private var filtered: [RelationshipContact] {
        InboxViewRules.applyTag(inbox.filtered(search: search, tagID: nil), tagName: selectedTagName) { $0.tags }
    }
    private var isLocating: Bool {
        InboxViewRules.isOwnLocating(isOpening: inbox.isOpening, busy: store.busy, running: store.running,
                                     importingList: store.importingList, operationApp: store.operationAppName)
    }

    init(inbox: RelationshipInbox) { self.inbox = inbox }
    #if RENDER_HARNESS
    /// 离屏验收专用：筛选命中零条、别名输入框展开这两个状态只能由内部状态进入，
    /// 正式构建不带 -D RENDER_HARNESS，这两个入口不会进包。
    init(inbox: RelationshipInbox, demoSearch: String, demoTag: String, demoEditingAliasFor: String?) {
        self.inbox = inbox
        _search = State(initialValue: demoSearch)
        _selectedTagName = State(initialValue: demoTag)
        _demoEditingAliasFor = State(initialValue: demoEditingAliasFor)
    }
    @State private var demoEditingAliasFor: String?
    #endif

    @ViewBuilder private var searchField: some View {
        TextField("搜索姓名、备注、标签或定位名称", text: $search)
            .textFieldStyle(.roundedBorder).focused($searchFocused)
            .frame(minWidth: 170, maxWidth: .infinity)
            .accessibilityLabel("搜索维系列表")
    }
    @ViewBuilder private var clearSearchButton: some View {
        if !search.isEmpty {
            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(GhostPressButtonStyle()).quietHover(lift: 1.5, scale: 1.04).foregroundStyle(.secondary)
                .accessibilityLabel("清除搜索关键词")
        }
    }
    @ViewBuilder private var tagPicker: some View {
        Picker("标签", selection: $selectedTagName) {
            Text("全部标签").tag("")
            ForEach(tagOptions, id: \.name) { option in
                Text("\(option.name) · \(option.count) 人").tag(option.name)
            }
        }.fixedSize()
    }
    @ViewBuilder private var clearTagButton: some View {
        if !selectedTagName.isEmpty {
            Button("清除标签") { selectedTagName = "" }
                .buttonStyle(GhostPressButtonStyle()).quietHover().font(f(11)).foregroundStyle(Theme.green)
        }
    }

    var body: some View {
        Card(title: "来自关系回响", icon: "person.2.wave.2", tint: Theme.green) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在关系回响选择人物与标签；在这里打开聊天，由你手动发送。")
                        .font(f(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(inbox.status).font(f(11))
                        .foregroundStyle(inbox.isStale ? Theme.orange : Theme.green)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("同步状态：\(inbox.status)")
                    if let notice = inbox.sourceNotice {
                        Text(notice).font(f(11)).foregroundStyle(Theme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button { inbox.refresh() } label: { Label("刷新名单", systemImage: "arrow.clockwise") }
                    .font(f(13))
                    .buttonStyle(SoftButtonStyle(tint: Theme.green))
                    .fixedSize()
            }
            // 窄列或大字号下把搜索与标签换成两行，不靠截断或藏掉控件过关。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchField; clearSearchButton; tagPicker; clearTagButton }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { searchField; clearSearchButton }
                    HStack(spacing: 8) { tagPicker; clearTagButton }
                }
            }
            // 零尺寸命令载体：只为让 ⌘F 落到搜索框，不占布局。
            Button("聚焦搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(GhostPressButtonStyle(radius: 0)).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            if isLocating {
                Text("正在定位微信会话…结果会显示在窗口底部；请在微信里核对会话，由你手动发送。")
                    .font(f(11)).foregroundStyle(Theme.blue)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.running || store.busy || store.importingList {
                Text("当前有队列或操作正在执行；暂停并等待结束后可打开聊天。")
                    .font(f(11)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.wechatPermission {
                Text("打开聊天需要 QQ排程助手的辅助功能权限，可在“设置与备份”查看。")
                    .font(f(11)).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(hasFilters ? "筛选中：显示 \(filtered.count) / \(inbox.contacts.count) 人" : "显示 \(filtered.count) / \(inbox.contacts.count) 人 · 独立维系列表")
                .font(f(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if inbox.contacts.isEmpty {
                switch InboxViewRules.emptyRoster(hasSnapshot: inbox.snapshot != nil, isStale: inbox.isStale) {
                case .neverSynced:
                    VStack(alignment: .leading, spacing: 5) {
                        // 走查 2026-10-06：首次使用指引按处理顺序编号，与同步动作一一对应。
                        Text("还没有收到同步名单。① 在关系回响勾选联系人；② 点击“同步到微信维系列表”；③ 回到这里点击“刷新名单”。")
                            .font(f(12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if inbox.isStale {
                            // 顶部状态行（inbox.status）已给出原因，这里不再复述，只指路。
                            Text("如果你已经同步过：按上方状态行里的原因处理后，点击“刷新名单”。")
                                .font(f(11)).foregroundStyle(Theme.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.vertical, 12)
                case .syncFailed:
                    // 顶部状态行已显示“同步失败，名单已过期：<原因>”，下方只给修复动作，不重复描述原因。
                    Text("修复方法：按上方状态行里的原因处理后，点击“刷新名单”。")
                        .font(f(12)).foregroundStyle(.secondary).padding(.vertical, 12)
                        .fixedSize(horizontal: false, vertical: true)
                case .noneSelected:
                    Text("关系回响当前未选择同步联系人。")
                        .font(f(12)).foregroundStyle(.secondary).padding(.vertical, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if filtered.isEmpty {
                HStack(spacing: 10) {
                    Text("没有匹配的联系人；筛选不会改变同步范围。")
                        .font(f(12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("清除筛选") { search = ""; selectedTagName = "" }
                        .buttonStyle(GhostPressButtonStyle()).quietHover().font(f(12)).foregroundStyle(Theme.green)
                        .fixedSize()
                }.padding(.vertical, 12)
            }
            LazyVStack(spacing: 10) {
                ForEach(filtered) { contact in
                    #if RENDER_HARNESS
                    let row = RelationshipInboxRow(inbox: inbox, contact: contact, sourceID: inbox.snapshot?.sourceInstanceId ?? "",
                                                   startEditingAlias: demoEditingAliasFor == contact.contactId)
                    #else
                    let row = RelationshipInboxRow(inbox: inbox, contact: contact, sourceID: inbox.snapshot?.sourceInstanceId ?? "")
                    #endif
                    row.id(inbox.key(for: contact.contactId))
                }
            }
        }
        .onChange(of: tagOptions.map(\.name)) { _, names in
            if !selectedTagName.isEmpty && !names.contains(selectedTagName) { selectedTagName = "" }
        }
    }
}

private struct RelationshipInboxRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var inbox: RelationshipInbox
    let contact: RelationshipContact
    let sourceID: String
    @State private var alias = ""
    @State private var aliasResult = ""
    @State private var aliasWhenShown = ""
    @State private var editingAlias = false
    @FocusState private var aliasFocused: Bool

    init(inbox: RelationshipInbox, contact: RelationshipContact, sourceID: String) {
        self.inbox = inbox
        self.contact = contact
        self.sourceID = sourceID
    }
    #if RENDER_HARNESS
    init(inbox: RelationshipInbox, contact: RelationshipContact, sourceID: String, startEditingAlias: Bool) {
        self.inbox = inbox
        self.contact = contact
        self.sourceID = sourceID
        _editingAlias = State(initialValue: startEditingAlias)
    }
    #endif

    private var savedAlias: String { inbox.alias(for: contact.contactId) }
    private var isLocating: Bool { inbox.openingContactID == contact.contactId }
    private var aliasFeedbackFailed: Bool { InboxViewRules.aliasFeedbackFailed(aliasResult) }
    private var fontScale: CGFloat { InboxViewRules.fontScale(for: sizeCategory) }
    private func f(_ base: CGFloat, weight: Font.Weight = .regular) -> Font { inboxFont(base, scale: fontScale, weight: weight) }

    private func save() {
        do {
            try inbox.saveAlias(alias, contactID: contact.contactId)
            alias = inbox.alias(for: contact.contactId)
            aliasWhenShown = alias
            aliasResult = AliasFeedback.saved
            editingAlias = false
        } catch {
            aliasWhenShown = alias
            aliasResult = error.localizedDescription
            editingAlias = true  // 保存失败时留在输入框里，用户改一个字就能重试
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.name).font(f(15, weight: .semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !contact.userNote.isEmpty {
                        Text(contact.userNote).font(f(12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !contact.tags.isEmpty {
                        Text(contact.tags.map(\.name).joined(separator: " · "))
                            .font(f(11)).foregroundStyle(Theme.green).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !savedAlias.isEmpty {
                        Text("微信定位名称：\(savedAlias)").font(f(11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        store.openRelationshipContact(contact.contactId, sourceID: sourceID)
                    } label: {
                        if isLocating {
                            Label {
                                Text("正在定位微信…")
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Label("打开微信聊天", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                        .buttonStyle(SoftButtonStyle(tint: Theme.green))
                        .font(f(13))
                        .fixedSize()
                        .disabled(inbox.isStale || inbox.isOpening || store.running || store.busy || store.importingList || !store.wechatPermission)
                        .help(isLocating ? "正在使用完整名称定位会话，请稍候" : "使用完整名称定位会话，保留已有草稿；请核对后手动发送")
                        .accessibilityLabel("打开与 \(contact.name) 的微信聊天")
                        .accessibilityValue(isLocating ? "正在定位微信会话" : "")
                    if inbox.isOpening && !isLocating {
                        Text("正在为其他联系人定位，完成后再点这里")
                            .font(f(10)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: InboxViewRules.scaledSize(168, scale: fontScale), alignment: .trailing)
                    }
                }
            }
            if !contact.message.isEmpty {
                DisclosureGroup("参考文案\(contact.festival.isEmpty ? "" : " · " + contact.festival)") {
                    Text(contact.message).font(f(12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                        .fixedSize(horizontal: false, vertical: true)
                }.font(f(12))
                    .accessibilityLabel("\(contact.name) 的参考文案")
            }
            // 定位名称默认折叠：长名单里每行常驻输入框会把主操作挤成背景噪声。
            if editingAlias {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("微信中显示的名称（可选）", text: $alias)
                            .textFieldStyle(.roundedBorder).focused($aliasFocused)
                            .frame(minWidth: 150, maxWidth: .infinity)
                            .onSubmit(save)
                            .accessibilityLabel("\(contact.name) 的微信定位名称")
                        Button("保存", action: save).buttonStyle(SoftButtonStyle(tint: Theme.slate)).font(f(13)).fixedSize()
                        Button("取消") {
                            alias = savedAlias
                            aliasResult = ""
                            editingAlias = false
                        }.buttonStyle(GhostPressButtonStyle()).quietHover().font(f(12)).foregroundStyle(.secondary).fixedSize()
                    }
                    if !aliasResult.isEmpty {
                        Text(aliasResult).font(f(10))
                            .foregroundStyle(aliasFeedbackFailed ? Theme.orange : Theme.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button(savedAlias.isEmpty ? "设置定位名称" : "修改定位名称") {
                        aliasResult = ""
                        alias = savedAlias
                        editingAlias = true
                        aliasFocused = true
                    }
                    .buttonStyle(GhostPressButtonStyle()).quietHover().font(f(11)).foregroundStyle(Theme.slate)
                    .fixedSize()
                    .accessibilityLabel("\(savedAlias.isEmpty ? "设置" : "修改")\(contact.name) 的微信定位名称")
                    if !aliasResult.isEmpty {
                        Text(aliasResult).font(f(10))
                            .foregroundStyle(aliasFeedbackFailed ? Theme.orange : Theme.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { alias = inbox.alias(for: contact.contactId) }
        .onChange(of: alias) { _, new in
            aliasResult = AliasFeedback.afterFieldEdit(message: aliasResult, field: new, fieldWhenShown: aliasWhenShown)
        }
        .onChange(of: inbox.rosterEpoch) { _, _ in
            let update = AliasFeedback.afterRosterChange(field: alias, fieldWhenShown: aliasWhenShown, saved: inbox.alias(for: contact.contactId))
            alias = update.field
            aliasResult = update.message
        }
    }
}

/// 「已核对草稿，发送这条」：必须逐项勾选收件群 / 正文 / 图片三项确认，且只针对当前这一行任务。
struct VerifiedSendButton: View {
    @EnvironmentObject var store: Store
    let job: Delivery
    var fills = false
    @State private var showing = false
    @State private var okRecipient = false
    @State private var okText = false
    @State private var okImage = false
    /// 走查 4-02：三项人工勾选必须绑定本次 sheet 生命周期。`@State` 在 sheet 关闭后仍保留，
    /// 取消后重开就能直接点「发送这一条」——那是把唯一的核对闸门状态留给了上一次的操作。
    /// 每次打开都归零，关闭时也归零，绝不复用上一轮的确认。
    private func openReview() {
        okRecipient = false; okText = false; okImage = false
        showing = true
    }
    var body: some View {
        Group {
            if fills {
                Button { openReview() } label: {
                    Text("核对后发送").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(QueuePlainButtonStyle(expands: true))
            } else {
                Button { openReview() } label: {
                    Label("核对后发送", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).fixedSize()
            }
        }
        .disabled(store.busy)
        .help("打开核对后再发送这一条；不会重新搜索或重贴")
        .sheet(isPresented: $showing, onDismiss: { okRecipient = false; okText = false; okImage = false }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("按已核对草稿续发这一条").font(.headline)
                Text("程序不会重新搜索、不会清空输入框、不会再粘贴任何内容；只核验归属与正文，然后发出一次发送指令。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("任务 \(job.id)　收件群 \(job.recipient)　附件 \(job.assets.count) 个").font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Toggle("QQ 里当前会话就是「\(job.recipient)」", isOn: $okRecipient)
                Toggle("草稿正文与这条任务的计划文字完全一致", isOn: $okText)
                Toggle("图片已经看得见地在草稿里", isOn: $okImage)
                HStack {
                    Button("取消", role: .cancel) { showing = false }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Spacer()
                    Button("发送这一条（仅一次）") {
                        showing = false
                        store.sendVerifiedDraft(job.id, confirmedRecipient: okRecipient, confirmedText: okText, confirmedImage: okImage)
                    }
                    .buttonStyle(DepthButtonStyle(gradient: Theme.brandUp, tint: Theme.indigo, compact: true))
                    .disabled(!(okRecipient && okText && okImage) || store.busy)
                }
            }
            .padding(20).frame(width: 420)
        }
    }
}

struct RenameRecipientButton: View {
    @EnvironmentObject var store: Store
    let name: String
    var recipientID: String? = nil
    var deliveryID: String? = nil
    var title = "修改群名"
    var fills = false
    @State private var showing = false
    @State private var editedName = ""
    @State private var error = ""
    var body: some View {
        Group {
            if fills {
                Button { editedName = name; error = ""; showing = true } label: {
                    Text(title).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(QueuePlainButtonStyle(expands: true))
            } else {
                Button { editedName = name; error = ""; showing = true } label: {
                    Label(title, systemImage: "pencil")
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                .fixedSize()
            }
        }
        .gateDisabled(store.busy || store.running,
                      hint: store.running ? "队列运行中：先点「暂停全部」，再改群名"
                      : "正在执行发送，等这一条结束后再改群名")
        .help("修改后同步群聊名单和待执行队列；运行时请先暂停")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("修改群名").font(.headline)
                TextField("输入正确群名", text: $editedName).textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Text("同步到群聊名单及该群的待执行、可重试任务。已发送记录保留原名。")
                    .font(.caption).foregroundStyle(.secondary)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消") { showing = false }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Spacer()
                    Button("保存并同步") { save() }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.brandUp, tint: Theme.indigo, compact: true))
                        .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 390)
        }
    }
    private func save() {
        do {
            try store.renameRecipient(id: recipientID, deliveryID: deliveryID, name: editedName)
            showing = false
        } catch { self.error = error.localizedDescription }
    }
}

struct RecipientsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var newNames = ""
    @State private var newChannel = SendChannel.qq
    @State private var verifiedSelection: Set<String> = []
    @State private var deleteTarget: Recipient?
    @State private var search = ""

    var body: some View {
        ScrollView { VStack(spacing:16) {
            HStack {
                Picker("联系人渠道", selection: $store.orderChannel) {
                    Text("QQ").tag(SendChannel.qq)
                    Text("微信").tag(SendChannel.wechat)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
            }
            if store.orderChannel == SendChannel.wechat {
                RelationshipInboxView(inbox: store.relationshipInbox)
            }
            if store.orderChannel == SendChannel.qq {
            Card(title:"从 QQ 导入群名",icon:"square.and.arrow.down.on.square",tint: Theme.blue) {
                Text("只识别 QQ 会话名称本身，不导入聊天内容；时间、未读数、[图片] 等消息摘要会自动过滤。勾选后逐个做真实检索验证，只有 QQ 第一条搜索结果可打开的群才会录入为 QQ 群。会打开搜索结果核对，不填写或发送消息。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Button { store.readQQSessionList() } label: { Label("读取 QQ 会话列表", systemImage: "list.bullet.rectangle.portrait.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.cool, tint: Theme.teal))
                        .disabled(store.busy || store.importingList)
                    if !store.discoveredNames.isEmpty {
                        Button { store.importVerified(Array(verifiedSelection)) } label: { Label("验证并录入 (\(verifiedSelection.count))", systemImage: "checkmark.seal.fill") }
                            .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                            .disabled(verifiedSelection.isEmpty || store.importingList)
                    }
                    Spacer()
                    if store.importingList { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(store.importProgress).font(.system(size: 11)).foregroundStyle(.secondary) } }
                }
                if !store.discoveredNames.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                            ForEach(store.discoveredNames, id: \.self) { name in
                                Button {
                                    if verifiedSelection.contains(name) { verifiedSelection.remove(name) } else { verifiedSelection.insert(name) }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: verifiedSelection.contains(name) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13))
                                            .foregroundStyle(verifiedSelection.contains(name) ? Theme.teal : .secondary)
                                        Text(name).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(verifiedSelection.contains(name) ? Theme.teal.opacity(scheme == .dark ? 0.18 : 0.08) : Surface(scheme).inset,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(verifiedSelection.contains(name) ? Theme.teal.opacity(0.30) : Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(GhostPressButtonStyle())
                                .quietHover(lift: 2, scale: 1)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    HStack {
                        Button("全选") { verifiedSelection = Set(store.discoveredNames) }.buttonStyle(SoftButtonStyle(tint: Theme.teal))
                        Button("清空选择") { verifiedSelection.removeAll() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                        Spacer()
                        Text("已选 \(verifiedSelection.count) / \(store.discoveredNames.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !store.importLog.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.importLog, id: \.self) { line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(line.hasPrefix("✅") ? Theme.green : Theme.orange)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            }
            Card(title:"添加群或联系人",icon:"person.badge.plus",tint: Theme.violet) {
                HStack(spacing: 10) {
                    Text("发送渠道").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Picker("发送渠道", selection: $newChannel) {
                        Text("QQ").tag(SendChannel.qq)
                        Text("微信").tag(SendChannel.wechat)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                }
                Text(SendChannel.addNamesHint(channel: newChannel)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("添加后会自动切到对应渠道的发送顺序。").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text:$newNames).frame(height:76).scrollContentBackground(.hidden).padding(8)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                HStack { Spacer(); Button("添加到名单") {
                        // 走查 4-12：与「新建发送」的导入弹窗同一口径——只有成功才清空输入框，
                        // 报错时保留整段粘贴，不让 50 行群名随一次落盘失败一起丢。
                        store.addRecipients(newNames, channel: newChannel)
                        if store.error == nil { newNames = "" }
                    }
                    .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), tint: Theme.violet)) }
            }
            Card(title:"发送顺序",icon:"list.number",tint: Theme.indigo) {
                TextField("搜索名单中的群名", text: $search).textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Picker("发送渠道", selection: $store.orderChannel) {
                        Text("QQ").tag(SendChannel.qq)
                        Text("微信").tag(SendChannel.wechat)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                    Text("QQ \(store.recipients.filter { $0.channelName == SendChannel.qq }.count) · 微信 \(store.recipients.filter { $0.channelName == SendChannel.wechat }.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if store.recipients.isEmpty {
                    EmptyPanel(title: "名单还是空的", symbol: "person.2", message: "在上方输入框选好渠道，把完整群名一行一个添加进来。", tint: Theme.violet)
                } else {
                    let ordered = RecipientList.filtered(store.recipients, channel: store.orderChannel)
                    if ordered.isEmpty {
                        let label = store.orderChannel == SendChannel.wechat ? "微信" : "QQ"
                        EmptyPanel(title: "\(label)名单还是空的", symbol: "person.2", message: "在上方输入框选好\(label)渠道，把完整群名一行一个添加进来。", tint: Theme.violet)
                    } else {
                        if !search.isEmpty && !ordered.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) {
                            Text("没有匹配的群聊").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 8) {
                            ForEach(Array(ordered.enumerated()),id:\.element.id) { index,r in
                                if search.isEmpty || r.name.localizedCaseInsensitiveContains(search) {
                                    recipientCard(index: index, r: r, isLast: index + 1 == ordered.count)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("名单启用状态只影响新计划。已创建任务使用保存时的快照，需要在队列中单独取消。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(22).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        .onAppear { newChannel = store.orderChannel }
        .onChange(of: store.orderChannel) { _, value in newChannel = value }
        .alert("从名单移除？", isPresented: Binding(get:{ deleteTarget != nil }, set:{ if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { r in
            Button("移除", role: .destructive) { store.deleteRecipient(r.id); deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { r in
            Text("将移除「\(r.name)」。已排队的任务使用名称快照，不受影响。")
        }
    }

    private func recipientCard(index: Int, r: Recipient, isLast: Bool) -> some View {
        HStack(alignment:.top,spacing:12) {
            Text(String(format:"%02d",index+1))
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.indigo)
                .frame(width: 34, height: 34)
                .background(Theme.indigo.opacity(scheme == .dark ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment:.leading,spacing:4) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal:false,vertical:true)
                    ChannelPill(channel: r.channelName)
                }
                Text(r.note.isEmpty ? "手动添加" : r.note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 7) {
                    Pill(text: r.enabled ? "已启用" : "已停用",
                         tint: TagStyle.enabled(r.enabled).tint, symbol: TagStyle.enabled(r.enabled).symbol,
                         variant: .neutral)
                    Toggle("",isOn:Binding(get:{store.recipients.first(where:{$0.id == r.id})?.enabled ?? false},set:{ v in if let i = store.recipients.firstIndex(where:{$0.id == r.id}) { store.recipients[i].enabled = v; store.saveSettings() } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("启用 \(r.name)")
                    RenameRecipientButton(name: r.name, recipientID: r.id)
                    Button { store.tryQQ(r.name, channel: r.channelName) } label: { Label("试跑定位", systemImage: "location.viewfinder") }
                        .help("打开 QQ/微信按名称搜索并进入该群，确认能自动定位；不填写、不发送任何消息。")
                        .buttonStyle(SoftButtonStyle(tint: Theme.blue)).disabled(store.busy)
                        .help("打开对应聊天工具、搜索并进入此会话，不发送消息")
                }
                HStack(spacing: 5) {
                    Button { store.moveRecipient(id: r.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(index == 0)
                    Button { store.moveRecipient(id: r.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(isLast)
                    Button { deleteTarget = r } label: { Image(systemName: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                }
            }
        }
        .padding(12)
        .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .opacity(r.enabled ? 1 : 0.62)
    }
}

// MARK: - 队列 / 记录

private enum QueueMetrics {
    static let control: CGFloat = 32
    static let actionWidth: CGFloat = 120
    static let gap: CGFloat = 8
    static let radius: CGFloat = 8
}

/// 队列和记录页的平面按钮。默认 32 点高，可指定更高（去核对 40 点）。鼠标移入上移 2 点，移出归位；禁用和减少动态效果时不移动。不缩放、不加投影。
private struct QueuePlainButtonStyle: ButtonStyle {
    var prominent = false
    var fixedWidth: CGFloat? = nil
    var expands = false
    var tint: Color? = nil
    var height: CGFloat? = nil
    /// 亮色底（琥珀/橙）上的深色文字；不传则按 prominent 默认白字
    var tintForeground: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        QueuePlainChrome(prominent: prominent, fixedWidth: fixedWidth, expands: expands,
                         tint: tint, height: height, tintForeground: tintForeground,
                         pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct QueuePlainChrome<Label: View>: View {
    var prominent: Bool
    var fixedWidth: CGFloat?
    var expands: Bool
    var tint: Color? = nil
    var height: CGFloat? = nil
    var tintForeground: Color? = nil
    var pressed: Bool
    @ViewBuilder var label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var lifted: Bool { hovering && isEnabled && !reduceMotion }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous)
        label()
            .font(.system(size: height != nil ? 14 : 13, weight: prominent ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, expands || fixedWidth != nil ? 8 : 12)
            .frame(width: fixedWidth, height: height ?? QueueMetrics.control)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(shape.fill(fill))
            .overlay {
                RippleLayer(pressed: pressed, color: prominent ? .white : (tint ?? Theme.indigo),
                            radius: QueueMetrics.radius)
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(prominent ? 0 : (scheme == .dark ? 0.18 : 0.12)), lineWidth: 1))
            .contentShape(shape)
            .opacity(pressed && isEnabled ? 0.78 : 1)
            .fixedSize(horizontal: fixedWidth == nil && !expands, vertical: false)
            .offset(y: lifted ? -2 : 0)
            .animation(reduceMotion ? .none : .easeOut(duration: 0.16), value: lifted)
            .onHover { hovering = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
    }

    private var foreground: Color {
        if let tintForeground { return tintForeground.opacity(isEnabled ? 1 : 0.55) }
        if prominent { return Color.white.opacity(isEnabled ? 1 : 0.78) }
        return Color.primary.opacity(isEnabled ? 0.9 : 0.38)
    }

    private var fill: Color {
        if prominent { return (tint ?? Theme.indigo).opacity(isEnabled ? (hovering ? 0.86 : 1) : 0.35) }
        if !isEnabled { return Color.primary.opacity(scheme == .dark ? 0.05 : 0.03) }
        if hovering { return Color.primary.opacity(scheme == .dark ? 0.14 : 0.07) }
        return Color.primary.opacity(scheme == .dark ? 0.08 : 0.045)
    }
}

private final class QueueRowsMemo {
    struct Key: Equatable {
        var revision: Int; var workspace: String; var plan: String
        var history: Bool; var query: String; var filter: String
    }
    var key: Key?
    var rows: [Delivery] = []
}

/// 发送工作台的三个队列页面分工（2026-10-12 拆分，回应「功能太密」）：
/// control = 启动/暂停与任务列表；schedule = 排期与间隔；progress = 进度与统计。
/// 三页共用同一 Store 状态与队列选择，只差展示区块。
enum QueuePane { case control, schedule, progress }

struct QueueView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    let history: Bool
    /// 历史页固定走自己的区块；pane 只影响队列侧页面
    var pane: QueuePane = .control
    @State private var selected: Delivery?
    @State private var query = ""
    @State private var filter = "all"
    @State private var limitedSend = false
    @State private var sendCountText = "1"
    @State private var expansionPlan: Plan?
    @State private var intervalText = ""
    @State private var scheduleDate = Date()
    @State private var scheduleDirty = false
    @State private var scheduleMemo = SchedulePreviewMemo()
    private final class SchedulePreviewMemo {
        var key = ""
        var value: Result<QueueSchedule.Preview, Error>?
    }
    @State private var spaceFilter: String? = nil
    @State private var contentPreview = false
    @State private var moreDeliveryID: String?
    /// 发送记录默认折叠（用户要求极简）。QueueView 挂在 .id(store.route) 上，路由切换即重建，天然每次进入都回到折叠态。
    @State private var historyCollapsed = true
    @State private var historyPlanID = ""
    @State private var rowsMemo = QueueRowsMemo()
    private var queueRunning: Bool { store.isQueueRunning(queuePlanID) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scopedPlans: [Plan] { store.plans.filter { (spaceFilter ?? store.workspaceID).isEmpty || ($0.workspaceID ?? "legacy") == (spaceFilter ?? store.workspaceID) } }
    private var scopedJobs: [Delivery] { let ids = Set(scopedPlans.map(\.id)); return store.deliveries.filter { ids.contains($0.planID) } }
    private var displayedJobs: [Delivery] { history ? scopedJobs.filter { $0.historyClearedAt == nil && (historyPlanID.isEmpty || $0.planID == historyPlanID) } : planJobs }
    private var queuedCount: Int { displayedJobs.filter { $0.status == "queued" }.count }
    private var verifiedCount: Int { DispatchProgressMapper.doneCount(from: displayedJobs) }
    // 队列只统计当前计划；历史页保留范围内全部日志。
    private var reviewCount: Int { QueueStartGate.reviewCount(displayedJobs.map(\.status)) }
    /// “需关注”口径：与“待处理”筛选（draft / uncertain / submitted / blocked）一致，
    /// 比 reviewCount 多含 blocked（已暂停不挡启动），发送记录页折叠头角标与自动展开都用它。
    private var attentionCount: Int { displayedJobs.filter { ["draft", "uncertain", "submitted", "blocked"].contains($0.status) }.count }
    private var queuePlanID: String? {
        if spaceFilter == nil { return store.displayedQueuePlanID }
        if scopedPlans.contains(where: { $0.id == store.chosenPlanID }) { return store.chosenPlanID }
        let ids = Set(scopedPlans.map(\.id))
        return Scheduling.nextCandidate(store.deliveries, gap: store.settings.globalGapMinutes,
                                        allowedPlanIDs: ids, intervalByPlan: store.intervalByPlan)?.planID
            ?? scopedPlans.max(by: { $0.created < $1.created })?.id
    }
    private var planJobs: [Delivery] { queuePlanID.map { store.queueJobs(planID: $0) } ?? [] }
    private var queueCancelled: Bool { scopedPlans.first(where: { $0.id == queuePlanID })?.queueCancelledAt != nil }
    private var sendLimit: Int? { limitedSend ? Int(sendCountText) : nil }
    private var sendLimitValid: Bool { !limitedSend || (1...10000).contains(Int(sendCountText) ?? 0) }
    private var pausedNoteText: String? {
        QueueStartGate.pausedNote(
            statuses: displayedJobs.map(\.status),
            nonRetriableCount: QueueStartGate.nonRetriablePaused(displayedJobs.map(\.status), displayedJobs.map { !$0.canRequeue }))
    }
    private var stopExplanation: String? {
        guard !history, reviewCount > 0 else { return nil }
        return queueCancelled
            ? "本计划有 \(reviewCount) 条结果留在发送记录，可稍后核对；此队列已取消，不自动重发这些记录。"
            : "本计划有 \(reviewCount) 条结果留在发送记录，可稍后核对；其余待执行任务继续，不自动重发这些记录。"
    }
    private var queueCandidate: Delivery? {
        guard let id = queuePlanID else { return nil }
        return store.nextDelivery(planID: id)
    }
    private var requestedInterval: Int? {
        intervalText.isEmpty ? scopedPlans.first(where: { $0.id == queuePlanID })?.intervalMinutes : Int(intervalText)
    }

    /// 间隔输入框与循环天数草稿跟随当前计划同步：跨计划 / 跨次进入都取目标计划自己的值，
    /// 防止把 A 计划的间隔或循环天数串用到 B 计划上。
    private func syncPlanControls(syncSchedule: Bool = true) {
        let plan = scopedPlans.first(where: { $0.id == queuePlanID })
        intervalText = String(plan?.intervalMinutes ?? store.settings.globalGapMinutes)
        recurringDaysDraft = plan?.recurringEveryDays ?? 1
        limitedSend = plan?.sendLimit != nil
        sendCountText = String(plan?.sendLimit ?? 1)
        // 走查 5-03：换计划 / 重进页面时「同步降低全局间隔」回到默认不勾选，不能延续上一次的授权
        lowerGlobalGap = false
        if syncSchedule { syncScheduleControl() }
    }
    private func syncScheduleControl() {
        let saved = queueCandidate.map { store.earliestSendDate($0) } ?? Date().addingTimeInterval(60)
        let future = max(saved, Date().addingTimeInterval(60))
        let calendar = Scheduling.calendar
        let minute = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: future)) ?? future
        scheduleDate = minute < future ? minute.addingTimeInterval(60) : minute
        scheduleDirty = false
    }

    /// 循环自动排入、尚未执行的后续轮任务数（关闭循环时会一并取消，需先确认）
    private var autoQueuedInPlan: Int {
        planJobs.filter { $0.status == "queued" && $0.cycleTag != nil }.count
    }

    /// 循环提示独立横幅：不跟随 step 被驱动文案覆盖；队列页与发送记录页共用，手动关闭清空全部。
    private var recurNoticeBanner: some View {
        Group {
            if !store.recurNotices.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(store.recurNotices.joined(separator: "\n"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        store.recurNotices = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(GhostPressButtonStyle())
                    .accessibilityLabel("关闭循环提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 22)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
            }
        }
    }


    private var filters: [(String, String)] {
        history ? [("all","全部"),("verified","已核对"),("attention","需关注"),("cancelled","已取消")]
                : [("all","全部"),("queued","待执行"),("running","发送中"),("attention","需关注")]
    }

    private var jobs: [Delivery] {
        let key = QueueRowsMemo.Key(revision: store.presentationRevision, workspace: spaceFilter ?? store.workspaceID,
                                   plan: history ? historyPlanID : (queuePlanID ?? ""), history: history, query: query, filter: filter)
        if rowsMemo.key == key { return rowsMemo.rows }
        var base = displayedJobs.filter { history ? $0.status != "queued" : ["queued","running","submitted","blocked","draft","uncertain"].contains($0.status) }
        switch filter {
        case "verified": base = base.filter { ["verified","manual"].contains($0.status) }
        case "attention": base = base.filter { ["draft","uncertain","blocked","submitted"].contains($0.status) }
        case "cancelled": base = base.filter { $0.status == "cancelled" }
        case "queued": base = base.filter { $0.status == "queued" }
        case "running": base = base.filter { $0.status == "running" }
        default: break
        }
        if !query.isEmpty {
            base = base.filter { $0.recipient.localizedCaseInsensitiveContains(query) || $0.planName.localizedCaseInsensitiveContains(query) }
        }
        let sorted = base.enumerated().sorted { lhs, rhs in
            let leftDate = history ? (lhs.element.finished ?? lhs.element.scheduled) : lhs.element.scheduled
            let rightDate = history ? (rhs.element.finished ?? rhs.element.scheduled) : rhs.element.scheduled
            if leftDate != rightDate { return history ? leftDate > rightDate : leftDate < rightDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
        rowsMemo.key = key; rowsMemo.rows = sorted
        return sorted
    }

    var body: some View {
        Group {
            if let original = selected {
                DeliveryDetailSheet(original: original, onClose: { selected = nil })
                    .environmentObject(store)
            } else { queuePage }
        }
    }

    private var queuePage: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:12) {
                    if history {
                        historySections
                    } else {
                        switch pane {
                        case .control: controlSections
                        case .schedule: scheduleSections
                        case .progress: progressSections
                        }
                    }
                    Color.clear.frame(height: 8)
                }.padding(.top, 14).frame(maxWidth: .infinity)
            }.scrollIndicators(.visible)
        }
        .sheet(item: $expansionPlan) { plan in ExpandQueuePlanView(planID: plan.id).environmentObject(store) }
        .sheet(isPresented: $contentPreview) { QueueContentPreviewSheet(planID: queuePlanID ?? "").environmentObject(store) }
        .onAppear {
            syncPlanControls()
            // 发送失败会自动跳转到发送记录页：有需关注记录（含已暂停）时直接展开列表，用户一眼能看到记录
            if history, attentionCount > 0 { historyCollapsed = false }
        }
        .onChange(of: queuePlanID) { _, _ in syncPlanControls() }
        .onChange(of: queueCandidate?.id) { _, _ in if !scheduleDirty { syncScheduleControl() } }
        .onChange(of: intervalText) { _, _ in
            // 缩短间隔时显示同步项，可由用户取消；只有点击应用才保存。
            lowerGlobalGap = requestedBelowGlobal && requestedInterval != savedInterval
        }
        // 跟随全局工作区切换时，作用域变了，钉住的计划重置为自动推导；页面内 Picker 切空间在上面 set 闭包里已重置
        .onChange(of: store.workspaceID) { _, _ in if spaceFilter == nil { store.chosenPlanID = ""; historyPlanID = "" } }
        .onChange(of: spaceFilter) { _, _ in historyPlanID = "" }
    }

    /// 发送记录页（history=true）保持原布局：提示横幅 + 统计 + 筛选 + 折叠列表
    @ViewBuilder private var historySections: some View {
        recurNoticeBanner
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            queueStat("待执行", value: queuedCount, symbol: "clock.fill", tint: Theme.indigo)
            queueStat("已核对完成", value: verifiedCount, symbol: "checkmark.seal.fill", tint: Theme.green)
            queueStat("待核对", value: reviewCount, symbol: "exclamationmark.triangle.fill", tint: Theme.amber)
            queueStat("累计·含取消", value: displayedJobs.count, symbol: "shippingbox.fill", tint: Theme.slate)
        }
        .padding(.horizontal, 22).padding(.vertical, 3)
        if let paused = pausedNoteText {
            Text(paused).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 22)
        }
        scopeBar
        toolbar
        if let notice = store.historyNotice {
            Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22)
        }
        undoBanner
        recordList
    }

    /// 「发送队列」页：只留启动/暂停与任务列表；排期、间隔、循环、进度都迁到各自页面
    @ViewBuilder private var controlSections: some View {
        queueSwitcher
        queueControls
        recurNoticeBanner
        runningCard
        if let paused = pausedNoteText {
            Text(paused).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 22)
        }
        if let stopExplanation {
            Text(stopExplanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22)
        }
        paneScopeBar
        toolbar
        undoBanner
        recordList
    }

    /// 「排期与间隔」页：开始时间、间隔、循环各自成卡，一页只讲清"什么时候发、隔多久"
    @ViewBuilder private var scheduleSections: some View {
        queueSwitcher
        recurNoticeBanner
        paneScopeBar
        scheduleCard
        intervalCard
        timingSummary
    }

    /// 「发送进度」页：统计、进度瓦片与各队列一览
    @ViewBuilder private var progressSections: some View {
        queueSwitcher
        paneScopeBar
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            queueStat("待执行", value: queuedCount, symbol: "clock.fill", tint: Theme.indigo)
            queueStat("已核对完成", value: verifiedCount, symbol: "checkmark.seal.fill", tint: Theme.green)
            queueStat("待核对", value: reviewCount, symbol: "exclamationmark.triangle.fill", tint: Theme.amber)
            // 队列侧页面不列出已取消行，累计里也不数它们；发送记录页含已取消，保持全量
            queueStat("累计·不含取消", value: displayedJobs.filter { $0.status != "cancelled" }.count, symbol: "shippingbox.fill", tint: Theme.slate)
        }
        .padding(.horizontal, 22).padding(.vertical, 3)
        if let paused = pausedNoteText {
            Text(paused).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 22)
        }
        if let stopExplanation {
            Text(stopExplanation).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22)
        }
        progressCard
        queueOverview
    }

    /// 批量取消的撤销窗（8 秒）：简单场景取代二次确认，复杂场景作为确认后的补救层
    @ViewBuilder private var undoBanner: some View {
        if let undo = store.pendingUndoCancellation {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(Theme.indigo)
                Text(undo.label)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button { store.undoLastCancellation() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    .disabled(store.busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 22)
        }
    }

    /// 列表与空态：历史页走折叠列表，队列页走完整任务行
    @ViewBuilder private var recordList: some View {
        if jobs.isEmpty {
            EmptyPanel(title: query.isEmpty && filter == "all" ? (history ? "还没有发送记录" : queueCancelled ? "此队列已取消" : "队列是空的") : "没有匹配的任务",
                       symbol: history ? "clock" : "calendar",
                       message: query.isEmpty && filter == "all" ? (!history && queueCancelled ? "旧记录保留在发送记录；点击“重新发送整条队列”建立新的完整批次。" : "新建发送后，可在这里查看进度和结果。") : "清空搜索或切换到“全部”查看其他任务。",
                       tint: history ? Theme.green : Theme.indigo)
                .padding(.top, 26)
        } else if history {
            // 发送记录：默认折叠，只留区块头；空列表走上面的 EmptyPanel，不出现区块头
            VStack(alignment: .leading, spacing: 8) {
                historyCollapseHeader
                if !historyCollapsed {
                    LazyVStack(spacing: 8) {
                        ForEach(jobs) { job in historyRow(job) }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 4)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(jobs) { job in row(job) }
            }
            .padding(.horizontal, 22).padding(.vertical, 4)
        }
    }

    /// 队列三页共用的空间切换条：只留群发空间；排期/循环的入口已迁到「排期与间隔」页
    private var paneScopeBar: some View {
        FlowHStack(hSpacing: 12, vSpacing: 8) {
            Picker("群发空间", selection: Binding(get: { spaceFilter ?? store.workspaceID }, set: { spaceFilter = $0; store.chosenPlanID = "" })) {
                Text("全部空间").tag("")
                ForEach(store.workspaces) { space in Text(space.name).tag(space.id) }
            }
            .controlSize(.small).frame(width: 188)
        }
        .padding(.horizontal, 22)
    }

    /// 「排期与间隔」页：开始时间卡
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            inlineScheduleEditor
        }
        .padding(12)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    /// 「排期与间隔」页：发送间隔卡
    private var intervalCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            inlineIntervalEditor
        }
        .padding(12)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    /// 「发送进度」页：进度瓦片独立成卡
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            progressBlock
            if reviewCount > 0 {
                Button { store.route = "history" } label: { Label("去发送记录", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.orange))
            }
        }
        .padding(12)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    /// 「发送进度」页：空间内各队列一览——哪条队列还压着多少任务，一眼看完
    private var queueOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("各队列一览").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 2)
            if orderedQueues.isEmpty {
                EmptyPanel(title: "当前空间还没有队列", symbol: "calendar",
                           message: "在「新建发送」创建第一批任务后，这里会显示每条队列的进度。",
                           tint: Theme.indigo)
            }
            ForEach(orderedQueues) { plan in
                let jobs = store.queueJobs(planID: plan.id).filter { $0.status != "cancelled" }
                let pending = jobs.filter { $0.status == "queued" }.count
                let done = DispatchProgressMapper.doneCount(from: jobs)
                let attention = QueueStartGate.reviewCount(jobs.map(\.status))
                HStack(spacing: 10) {
                    Image(systemName: store.isQueueRunning(plan.id) ? "play.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(store.isQueueRunning(plan.id) ? Theme.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("待执行 \(pending) · 已核对 \(done) · 待核对 \(attention)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if plan.id == queuePlanID {
                        Text("当前").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.indigo)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.indigo.opacity(0.12), in: Capsule())
                    }
                    Button("查看") { store.chosenPlanID = plan.id }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).controlSize(.small)
                        .help("把这条队列设为当前队列")
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Surface(scheme).card.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    private func queueStat(_ title: String, value: Int, symbol: String, tint: Color, note: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.78)
            if let note {
                Text(note).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 3)
            Text("\(value)").font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(tint).monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
    }

    /// 循环发送开关用的间隔草稿（天）：开循环时 Stepper 变更即写入计划，这里只记最近一次选择
    @State private var recurringDaysDraft = 1
    /// 关闭循环前确认：会同时取消循环自动排入的待执行任务

    private var savedInterval: Int {
        scopedPlans.first { $0.id == queuePlanID }?.intervalMinutes ?? store.settings.globalGapMinutes
    }

    /// 用户在本页缩短间隔时显示同步选项；只有点击应用才保存，也可取消该选项。
    @State private var lowerGlobalGap = false
    /// 当前输入值是否低于全局最小间隔
    private var requestedBelowGlobal: Bool {
        guard let proposed = Int(intervalText), (1...1440).contains(proposed) else { return false }
        return proposed < store.settings.globalGapMinutes
    }

    /// 当前队列计划若开了循环，任务数文案追加的循环标记
    private var recurringBadge: String {
        guard let days = scopedPlans.first(where: { $0.id == queuePlanID })?.recurringEveryDays else { return "" }
        return " · 循环中（每 \(days) 天一轮）"
    }

    private var intervalIssue: String? {
        guard let proposed = requestedInterval, (1...1440).contains(proposed) else { return "请输入 1 到 1440 的整数分钟。" }
        if requestedBelowGlobal && !lowerGlobalGap { return "要使用 \(proposed) 分钟间隔，请勾选同步降低最低间隔。" }
        return nil
    }
    private var intervalHasChanges: Bool {
        requestedInterval != savedInterval || (requestedBelowGlobal && lowerGlobalGap)
    }
    private var intervalPreview: Store.IntervalPreview? {
        guard let id = queuePlanID, let minutes = requestedInterval else { return nil }
        if !intervalHasChanges {
            let remaining = Scheduling.ordered(planJobs.filter {
                $0.status == "queued" && !$0.isOneOff && $0.submittedAt == nil && $0.evidence.isEmpty
            })
            guard let next = queueCandidate else { return nil }
            let firstDate = store.earliestSendDate(next)
            var finish = firstDate
            for job in remaining where job.id != next.id {
                finish = max(store.earliestSendDate(job), finish.addingTimeInterval(Double(max(minutes, store.settings.globalGapMinutes) * 60)))
            }
            return Store.IntervalPreview(deliveries: store.deliveries, globalGap: store.settings.globalGapMinutes,
                                         remaining: remaining.count, nextDate: firstDate, finishDate: finish)
        }
        return try? store.previewPlanInterval(id, minutes: minutes, lowerGlobal: lowerGlobalGap)
    }
    private func intervalDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                      locale: Locale(identifier: "zh_CN"), timeZone: Scheduling.calendar.timeZone))
    }
    private var requestedScheduleDate: Date {
        let calendar = Scheduling.calendar
        return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduleDate)) ?? scheduleDate
    }
    private var schedulePreviewResult: Result<QueueSchedule.Preview, Error>? {
        guard scheduleDirty, let id = queuePlanID else { return nil }
        let now = Date()
        let key = "\(id)|\(requestedScheduleDate.timeIntervalSince1970)|\(store.presentationRevision)|\(store.busy)|\(store.processingPlanID ?? "")|\(Int(now.timeIntervalSince1970 / 60))"
        if scheduleMemo.key == key { return scheduleMemo.value }
        let result = Result { try store.previewPlanSchedule(id, start: requestedScheduleDate, now: now) }
        scheduleMemo.key = key; scheduleMemo.value = result
        return result
    }
    private var inlineScheduleEditor: some View {
        let result = schedulePreviewResult
        let preview = result.flatMap { try? $0.get() }
        let editable = queuePlanID.map(store.canEditPlanSchedule) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            FlowHStack(hSpacing: 8, vSpacing: 8) {
                DatePicker("开始发送", selection: Binding(get: { scheduleDate }, set: { scheduleDate = $0; scheduleDirty = true }),
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, Scheduling.calendar.timeZone)
                    .accessibilityLabel("此队列下一群开始发送日期和时间")
                    .fixedSize()
                Button("修改排期") {
                    guard let id = queuePlanID else { return }
                    if store.updatePlanSchedule(id, start: requestedScheduleDate) { syncScheduleControl() }
                }
                .buttonStyle(QueuePlainButtonStyle(prominent: true))
                .disabled(!scheduleDirty || preview == nil || !editable)
                if scheduleDirty {
                    Button("取消修改") { syncScheduleControl() }
                        .buttonStyle(QueuePlainButtonStyle())
                }
                Text("调整下一群及后续待发群").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            if scheduleDirty, let preview {
                Text("修改后 · 未保存：下一群 \(intervalDate(preview.nextDate))，预计结束 \(intervalDate(preview.finishDate))，剩余 \(preview.remaining) 群")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.indigo)
                    .fixedSize(horizontal: false, vertical: true)
                if preview.nextDate > requestedScheduleDate {
                    Text("发送间隔尚未结束，将在上方最早可发送时间执行。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            } else if scheduleDirty, let result, case .failure(let error) = result {
                Text(error.localizedDescription).font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
            if !editable {
                Text("当前群处理结束后，可修改剩余排期。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
    private var inlineIntervalEditor: some View {
        let preview = intervalPreview
        return VStack(alignment: .leading, spacing: 8) {
            FlowHStack(hSpacing: 8, vSpacing: 8) {
                Text("发送间隔").fontWeight(.semibold)
                HStack(spacing: 6) {
                    Text("每")
                    TextField("分钟", text: $intervalText)
                        .textFieldStyle(.plain).multilineTextAlignment(.center)
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .frame(width: 54, height: QueueMetrics.control)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(scheme == .dark ? 0.08 : 0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
                        .accessibilityLabel("发送间隔分钟数")
                    Text("分钟 / 群")
                }
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("\(minutes) 分钟") { intervalText = String(minutes) }
                        .buttonStyle(QueuePlainButtonStyle(tint: requestedInterval == minutes ? Theme.indigo : nil))
                        .accessibilityLabel("间隔快捷选择 \(minutes) 分钟")
                }
                Button("应用并重排") {
                    guard let id = queuePlanID, let minutes = requestedInterval else { return }
                    if store.updatePlanInterval(id, minutes: minutes, lowerGlobal: lowerGlobalGap) { syncPlanControls(syncSchedule: false) }
                }
                .buttonStyle(QueuePlainButtonStyle(prominent: true))
                .disabled(store.busy || preview == nil || !intervalHasChanges)
                Text("已保存 \(savedInterval) 分钟").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            if requestedBelowGlobal {
                Toggle(isOn: $lowerGlobalGap) {
                    Text("同时将所有队列共用的最低间隔改为 \(requestedInterval ?? 0) 分钟")
                        .font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox).accessibilityLabel("同步降低全局最小发送间隔")
            }
            if let preview {
                FlowHStack(hSpacing: 12, vSpacing: 5) {
                    Text(intervalHasChanges ? "调整后 · 未应用" : "剩余排期").foregroundStyle(intervalHasChanges ? Theme.indigo : .secondary)
                    Text("下一群 \(intervalDate(preview.nextDate))")
                    Text("预计结束 \(intervalDate(preview.finishDate))")
                    Text("剩余 \(preview.remaining) 群").foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5)).monospacedDigit()
            }
            if store.busy {
                Text("当前群正在发送，结束后可应用。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if let intervalIssue {
                Text(intervalIssue).font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
        }
    }

    private var timingSummary: some View {
        let recurringDays = scopedPlans.first { $0.id == queuePlanID }?.recurringEveryDays
        return VStack(alignment: .leading, spacing: 8) {
            // 循环发送：开启后一轮全部收尾时自动生成下一轮排队任务；是否发送仍由队列启动控制
            HStack(spacing: QueueMetrics.gap) {
                Toggle(isOn: Binding(
                    get: { recurringDays != nil },
                    set: { on in
                        guard let id = queuePlanID else { return }
                        if on {
                            store.setRecurring(planID: id, everyDays: recurringDaysDraft)
                        } else {
                            store.setRecurring(planID: id, everyDays: nil)
                        }
                    })) {
                    Text("循环发送").font(.system(size: 13))
                }
                .toggleStyle(.switch).controlSize(.small)
                .disabled(queuePlanID == nil)
                if let savedDays = recurringDays {
                    Stepper("每 \(savedDays) 天一轮", value: Binding(
                        get: { savedDays },
                        set: { newValue in
                            recurringDaysDraft = newValue
                            if let id = queuePlanID { store.setRecurring(planID: id, everyDays: newValue) }
                        }), in: 1...30)
                    .font(.system(size: 13)).fixedSize()
                }
                Spacer(minLength: 8)
            }
            Text("一轮全部发送完成且无待核对任务时，自动按相同时间表生成下一轮；是否发送仍由队列启动控制")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QueueMetrics.radius, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
        .padding(.horizontal, 22)
    }

    private var historyScopeIDs: Set<String> {
        historyPlanID.isEmpty ? Set(scopedPlans.map(\.id)) : Set(scopedPlans.filter { $0.id == historyPlanID }.map(\.id))
    }
    private var clearableHistoryCount: Int { displayedJobs.filter(HistoryArchive.canClear).count }
    private var hiddenHistoryCount: Int { scopedJobs.filter { historyScopeIDs.contains($0.planID) && $0.historyClearedAt != nil }.count }
    private var orderedQueues: [Plan] { scopedPlans.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created } }
    private var queueSwitcher: some View {
        VStack(alignment: .leading, spacing: 7) {
            FlowHStack(hSpacing: 12, vSpacing: 8) {
                Picker("发送队列", selection: Binding(get: { queuePlanID ?? "" }, set: { store.chosenPlanID = $0 })) {
                    ForEach(Array(orderedQueues.enumerated()), id: \.element.id) { index, plan in
                        Text("队列 \(index + 1) · \(plan.name)" + (store.isQueueRunning(plan.id) ? " · 运行中" : ""))
                            .tag(plan.id)
                    }
                }.frame(minWidth: 220, maxWidth: 480)
                Button { store.beginNewQueue() } label: { Label("新建队列", systemImage: "plus") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                if !store.runningPlanIDs.isEmpty {
                    Text("\(store.runningPlanIDs.count) 条队列运行中").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                }
            }
            Text("各队列分别启动、暂停和设置间隔；共用同一个 QQ，按到期顺序轮流发送。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }.padding(.horizontal, 22)
    }

    private var queueControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("本次限定条数", isOn: $limitedSend).toggleStyle(.switch).controlSize(.small)
                    .fixedSize().disabled(queueRunning)
                if limitedSend {
                    TextField("条数", text: $sendCountText).frame(width: 64)
                        .accessibilityLabel("本次发送条数").disabled(queueRunning)
                    Text("条，处理完自动暂停").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("处理全部待发任务").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if limitedSend {
                Text("本次最多处理 \(sendLimit ?? 0) 条；故障跳过也计入条数，其余保持暂停。")
                    .font(.system(size: 11)).foregroundStyle(sendLimitValid ? Color.secondary : Theme.rose)
            }
            if queueCancelled {
                Text("此队列已取消。重新开始会按原图文重发整队，已发群也会进入新的发送记录。")
                    .font(.system(size: 12)).foregroundStyle(Theme.orange)
            }
            FlowHStack(hSpacing: 10, vSpacing: 10) {
                Button {
                    guard let targetPlanID = queuePlanID, sendLimitValid else { return }
                    let expectedDeliveryID = store.nextDelivery(planID: targetPlanID)?.id
                    store.chosenPlanID = targetPlanID   // 启动会重排任务时间，先钉住目标计划防止卡片漂移
                    let minutesToApply = requestedInterval
                    // 走查 5-03：「立即开始」不再无条件顺手把全局最小间隔降到输入值。
                    // 只有本计划间隔变了、或者用户已经显式勾选「同步降低全局间隔」时才落笔。
                    if let minutes = minutesToApply,
                       (1...1440).contains(minutes),
                       let saved = store.plans.first(where: { $0.id == targetPlanID }),
                       saved.intervalMinutes != minutes || (lowerGlobalGap && store.settings.globalGapMinutes > minutes) {
                        store.updatePlanInterval(targetPlanID, minutes: minutes, lowerGlobal: lowerGlobalGap)
                        guard store.plans.first(where: { $0.id == targetPlanID })?.intervalMinutes == minutes,
                              !lowerGlobalGap || store.settings.globalGapMinutes <= minutes else { return }
                    }
                    store.start(planID: targetPlanID, expectedDeliveryID: expectedDeliveryID, limit: sendLimit)
                    if store.isQueueRunning(targetPlanID) { syncPlanControls() }
                } label: { Label(queueCancelled ? "重新发送整条队列" : "立即开始 · \(queueCandidate?.recipient ?? "下一群")", systemImage: "play.fill") }
                    .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                    .gateDisabled(store.busy || queueRunning || (queueCandidate == nil && !queueCancelled) || !sendLimitValid || !(1...1440).contains(requestedInterval ?? 0),
                                  hint: queueRunning ? "此队列已启动，先暂停此队列再手动开始"
                                  : store.busy ? "正在执行发送，等这一条结束后再操作"
                                  : "当前范围没有可立即执行的待发送任务")
                    .help(queueCancelled ? "按原图文新建完整批次并立即开始；已发、故障和取消的群都会进入新批次，旧记录保留" : "立即处理：\(queueCandidate?.recipient ?? "下一群")；剩余任务从本次发送起按间隔重新排队")
                Button {
                    guard !scheduleDirty, let targetPlanID = queuePlanID, store.nextDelivery(planID: targetPlanID) != nil else { return }
                    store.chosenPlanID = targetPlanID   // 钉住目标计划，防止顺延重排后卡片跳到别的计划
                    store.start(planID: targetPlanID, immediate: false, limit: sendLimit)
                } label: { Label("按排期启动", systemImage: "calendar.badge.clock") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    .gateDisabled(scheduleDirty || queueRunning || queueCandidate == nil || queueCancelled || !sendLimitValid,
                                  hint: scheduleDirty ? "先点击修改排期保存开始时间，或取消修改"
                                  : queueRunning ? "此队列已启动" : "此队列没有待发送任务")
                    .help("保留原定发送时间；已过期的任务按间隔顺延处理")
                if let review = planJobs.first(where: \.canResendAfterReview) {
                    Button { selected = review } label: { Label("核对故障", systemImage: "exclamationmark.bubble") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.orange))
                }
                Button { expansionPlan = scopedPlans.first { $0.id == queuePlanID } } label: {
                    Label("添加群聊", systemImage: "person.2.badge.plus")
                }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    .gateDisabled(store.busy || queueRunning || queuePlanID == nil,
                                  hint: queueRunning ? "此队列已启动，先暂停此队列再改名单"
                                  : store.busy ? "正在执行发送，等这一条结束后再操作"
                                  : "当前空间还没有计划，先在「新建发送」创建")
                Button { contentPreview = true } label: {
                    Label("内容预览", systemImage: "doc.text.magnifyingglass")
                }
                    .buttonStyle(SoftButtonStyle(tint: Theme.blue))
                    .gateDisabled(queuePlanID == nil, hint: "当前空间还没有计划，先在「新建发送」创建")
                    .help("查看本计划将发送的文字、图片、链接与文件（只读）")
                if queueRunning, let id = queuePlanID {
                    Button { store.stop(planID: id) } label: { Label("暂停此队列", systemImage: "pause.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.orange))
                }
                if !queueCancelled, let id = queuePlanID, !planJobs.isEmpty {
                    Button { store.chosenPlanID = id; store.cancelQueue(planID: id) } label: { Label("取消此队列", systemImage: "xmark.circle") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose)).disabled(store.historyActionBusy)
                }
                Text("本队列 \(planJobs.count) 条任务" + recurringBadge)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if reviewCount > 0 {
                Text(queueCancelled ? "本计划有 \(reviewCount) 条结果需要稍后核对；此队列已取消，不再接续。" : "本计划有 \(reviewCount) 条结果需要稍后核对；其余待执行群正常接续。")
                    .font(.system(size: 13)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if queueRunning {
                // 走查 2026-10-04：压暗的按钮旁边必须有一句「为什么点不了」，不能只靠点击后的提示条。
                // 走查 2026-10-06 #11：「已暂停」与任务状态词撞车，改成「暂不可用」。
                Text("此队列运行中，可切换其他队列、查看内容或暂停此队列。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 22)
    }

    /// 发送记录页的空间/队列切换条；队列侧页面用 paneScopeBar（只留群发空间）
    private var scopeBar: some View {
        FlowHStack(hSpacing: 12, vSpacing: 8) {
            Picker("群发空间", selection: Binding(get: { spaceFilter ?? store.workspaceID }, set: { spaceFilter = $0; store.chosenPlanID = "" })) {
                Text("全部空间").tag("")
                ForEach(store.workspaces) { space in Text(space.name).tag(space.id) }
            }
            .controlSize(.small).frame(width: 188)
            if history {
                Picker("发送队列", selection: $historyPlanID) {
                    Text("全部队列").tag("")
                    ForEach(scopedPlans) { plan in Text(plan.name).tag(plan.id) }
                }.controlSize(.small).frame(width: 250)
            }
        }
        .padding(.horizontal, 22)
    }

    private var toolbar: some View {
        FlowHStack(hSpacing: 10, vSpacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("搜索群名或计划名", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(width: 205, height: 36)
            .background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface(scheme).hairline, lineWidth: 1))
            Picker("", selection: $filter) {
                ForEach(filters, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: CGFloat(filters.count) * 74, height: 36)
            HStack(spacing: 8) {
                if history {
                    Button { store.clearHistory(planIDs: historyScopeIDs) } label: {
                        Label(store.historyActionBusy ? "正在清空…" : "清空记录", systemImage: "trash")
                    }.buttonStyle(SoftButtonStyle(tint: Theme.rose))
                        .disabled(store.historyActionBusy || clearableHistoryCount == 0)
                        .help("清空所选空间/队列的历史记录；可恢复，不影响待发任务")
                    if hiddenHistoryCount > 0 {
                        Button { store.restoreHistory(planIDs: historyScopeIDs) } label: {
                            Label("恢复已清空（\(hiddenHistoryCount)）", systemImage: "arrow.uturn.backward")
                        }.buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(store.historyActionBusy)
                    }
                }
                Button { store.exportRecords() } label: { Label("导出记录", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
            }
        }
        .padding(.horizontal, 22)
    }

    private var progressBlock: some View {
        let activeJobs = planJobs.filter { $0.status != "cancelled" }
        return DispatchProgress3D(
            segments: DispatchProgressMapper.segments(from: activeJobs, limit: activeJobs.count, running: queueRunning),
            doneCount: DispatchProgressMapper.doneCount(from: activeJobs),
            totalCount: activeJobs.count,
            queueRunning: queueRunning,
            onRetry: { deliveryID in
                // 进度块只打开核对页，不修改或自动重试原记录。
                if let planID = store.deliveries.first(where: { $0.id == deliveryID })?.planID { store.chosenPlanID = planID }
                selected = store.deliveries.first { $0.id == deliveryID }
            }, retryEnabled: !store.busy,
            attentionLabel: QueueStartGate.attentionLabel(statuses: activeJobs.map(\.status))
        )
        .padding(.top, 8)
    }

    /// 队列正在运行的其他计划（钉住的计划自身没有待执行时，说明去哪看）
    private var runningElsewherePlan: Plan? {
        guard let activeID = store.runningPlanIDs.sorted().first(where: { $0 != queuePlanID }) else { return nil }
        return store.plans.first(where: { $0.id == activeID })
    }
    /// 本空间里除当前计划外、最早还有待执行任务的计划（不含一次性任务：它们不参与自动派发）
    private var otherScopedPendingPlan: (plan: Plan, count: Int)? {
        let others = scopedJobs.filter { $0.status == "queued" && !$0.isOneOff && $0.planID != queuePlanID }
        guard !others.isEmpty else { return nil }
        let grouped = Dictionary(grouping: others, by: \.planID)
        guard let earliest = grouped.min(by: { lhs, rhs in
            (lhs.value.map(\.scheduled).min() ?? .distantFuture) < (rhs.value.map(\.scheduled).min() ?? .distantFuture)
        }), let plan = scopedPlans.first(where: { $0.id == earliest.key }) else { return nil }
        return (plan, earliest.value.count)
    }
    /// 只有当前计划每条显示任务都已核对或人工标记已发，才显示全部完成。
    private var currentPlanAllDone: Bool {
        guard !queueCancelled else { return false }
        let regular = planJobs.filter { $0.status != "cancelled" }
        return !regular.isEmpty && regular.allSatisfy { ["verified", "manual"].contains($0.status) }
    }
    private var canShowEmptyHint: Bool { currentPlanAllDone }
    /// 空态两级文案
    private var emptyStateMessage: String? {
        guard canShowEmptyHint else { return nil }
        if let plan = runningElsewherePlan {
            return "队列正在运行其他计划（\(plan.name)）；本计划当前没有待执行任务"
        }
        if let other = otherScopedPendingPlan {
            return "本计划已全部完成；\(other.plan.name) 还有 \(other.count) 条待执行"
        }
        return nil
    }
    /// 空态“切换查看”按钮指向的计划；目标计划不在当前作用域（如别的群发空间）时不给按钮，只留文案
    private var emptyStateSwitchTarget: Plan? {
        guard canShowEmptyHint else { return nil }
        if let plan = runningElsewherePlan {
            return scopedPlans.contains(where: { $0.id == plan.id }) ? plan : nil
        }
        return otherScopedPendingPlan?.plan
    }

    private var runningCard: some View {
        DepthSurface(radius: 18, padding: 14, accent: queueRunning ? Theme.green : nil) {
            if let next = store.nextDelivery(planID: queuePlanID) {
                HStack(spacing: 14) {
                    IconTile(symbol: queueRunning ? "paperplane.fill" : "pause.fill", size: 42,
                             gradient: queueRunning ? Theme.success : Theme.steel)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("下一群：\(next.recipient)").font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text("最早发送 \(store.earliestSendDate(next).formatted(date: .abbreviated, time: .standard)) · \(next.planName)")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if queueRunning && !store.busy {
                        CountdownText(target: store.earliestSendDate(next), prefix: "距发送")
                    }
                }
                Text(store.timingExplanation(next))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 8)
                // 排期摘要一行带过；具体编辑去「排期与间隔」页（2026-10-12 拆分，控制页不再堆编辑器）
                timingDigestRow
            } else {
                let empty = QueueStartGate.emptySchedule(statuses: planJobs.map(\.status))
                HStack(spacing: 14) {
                    IconTile(symbol: currentPlanAllDone ? "checkmark.circle.fill" : attentionCount > 0 ? "exclamationmark.triangle.fill" : "clock.fill",
                             size: 42, gradient: currentPlanAllDone ? Theme.success : attentionCount > 0 ? Theme.warm : Theme.steel)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(queueCancelled ? "此队列已取消" : currentPlanAllDone ? "本计划已全部完成" : empty.title).font(.system(size: 15, weight: .bold))
                        Text(queueCancelled ? "原发送结果与取消记录均保留；重新开始会重发整队，包括已发群。" : emptyStateMessage ?? empty.message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 两级空态补充：正在跑别的计划 / 本空间其他计划还有待执行，都可一键切换查看
                        if let target = emptyStateSwitchTarget {
                            Button("切换查看") { store.chosenPlanID = target.id }
                                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 8)
                }
            }
            if reviewCount > 0 {
                Button { store.route = "history" } label: { Label("去发送记录", systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.orange))
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 22)
    }

    /// 控制页的排期摘要：一行讲清当前安排 + 跳「排期与间隔」页（进度瓦片迁到「发送进度」页）
    private var timingDigestRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.day.timeline.left").font(.system(size: 13)).foregroundStyle(.secondary)
            Text(timingDigest).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { store.route = "schedule" } label: { Label("排期与间隔", systemImage: "slider.horizontal.3") }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                .help("调整开始时间、发送间隔与循环设置")
        }
        .padding(.top, 8)
    }
    private var timingDigest: String {
        var parts: [String] = []
        if let next = queueCandidate {
            parts.append("开始 \(store.earliestSendDate(next).formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append("间隔 \(savedInterval) 分钟")
        parts.append("剩余 \(planJobs.filter { $0.status == "queued" }.count) 群")
        return parts.joined(separator: " · ") + recurringBadge
    }

    private func rowStamp(_ job: Delivery) -> String {
        let date = history ? (job.finished ?? job.scheduled) : job.scheduled
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
    }

    /// 列表只留一句下一步。原始诊断和完整原因仍在详情。
    private func rowHint(_ job: Delivery) -> String? {
        let app = SendChannel.displayName(job.channelName)
        switch job.status {
        case "draft", "uncertain", "submitted":
            return "到\(app)核对，未发出可重新发送。"
        case "blocked":
            return "到\(app)核对后选择“发送”或“不发送”。"
        case "queued":
            if job.submittedAt != nil || !job.evidence.isEmpty { return "已有提交记录，先去核对。" }
            return nil
        default:
            return nil
        }
    }

    private func row(_ job: Delivery) -> some View {
        let opensReview = job.canResendAfterReview
        let expanded = moreDeliveryID == job.id
        return VStack(alignment: .leading, spacing: 8) {
            SideOrBelow(spacing: 12, minLeading: 350) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 2) {
                        Text(rowStamp(job)).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(RelativeDay.label(for: job.scheduled))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 100, alignment: .leading)
                    IconTile(symbol: StatusStyle.symbol(job.status), size: 30,
                             gradient: StatusStyle.gradient(job.status))
                    VStack(alignment: .leading, spacing: 4) {
                        FlowHStack(hSpacing: 7, vSpacing: 4) {
                            Text(job.recipient).font(.system(size: 14, weight: .semibold))
                                .lineLimit(1).truncationMode(.tail)
                            ChannelPill(channel: job.channelName, compact: true)
                            Pill(status: job.status, name: job.statusName)
                            Pill(mode: job.mode)
                        }
                        Text("\(job.planName) · \(job.assets.count) 个附件")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if job.status != "queued", !job.detail.isEmpty {
                            Text(job.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        if let hint = rowHint(job) {
                            Text(hint).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                FlowHStack(hSpacing: 8, vSpacing: 8) {
                    if opensReview {
                        Button { selected = job } label: { Label("去核对", systemImage: "checkmark.seal.fill") }
                            .buttonStyle(SoftButtonStyle(tint: Theme.amber))
                            .accessibilityLabel("\(job.recipient) 去核对")
                    } else {
                        Button { selected = job } label: { Text("详情") }
                            .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                            .help("查看完整原因和处理操作")
                            .accessibilityLabel("\(job.recipient) 详情")
                    }
                    if job.canRenameRecipient {
                        Button { moreDeliveryID = expanded ? nil : job.id } label: { Text(expanded ? "收起" : "更多") }
                            .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                            .accessibilityLabel(expanded ? "收起\(job.recipient)的更多操作" : "展开\(job.recipient)的更多操作")
                    }
                }
            }
            if expanded {
                morePanel(job)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface(scheme).card.opacity(0.88), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 17)
                .fill(StatusStyle.gradient(job.status)).frame(width: 3.5)
        }
        .shadow(color: Surface(scheme).shadowSoft, radius: 6, y: 3)
        // 右键时间微调（对标 Buffer 单帖菜单）：只对无痕迹的待执行任务开放；
        // 「提前」不提供——冷却下限会把提前钳回原值，行上显示的时刻就成了达不到的假时刻。
        .contextMenu {
            if job.canPostpone {
                Button { store.postpone(job.id, minutes: 30) } label: { Label("推迟 30 分钟", systemImage: "clock.arrow.circlepath") }
                Button { store.postpone(job.id, minutes: 60) } label: { Label("推迟 1 小时", systemImage: "clock.arrow.circlepath") }
                Button { store.postpone(job.id, minutes: 24 * 60) } label: { Label("推迟到明天同一时刻", systemImage: "calendar.badge.clock") }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func morePanel(_ job: Delivery) -> some View {
        // 按用户要求精简：复制群名/复制详情/复制文案、重填草稿、核对后发送、取消均已移出，
        // 行内只保留「改名」；核对后续发在「去核对」详情里。
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: QueueMetrics.gap), count: 3), spacing: QueueMetrics.gap) {
            if job.canRenameRecipient {
                RenameRecipientButton(name: job.recipient, deliveryID: job.id, title: "改名", fills: true)
            }
        }
        .padding(.top, 2)
    }

    /// 发送记录的区块头：`发送记录 · N 条` + chevron，整头可点切换折叠。
    /// N 取当前过滤/搜索后的 jobs.count，与展开后的行数一致。
    private var historyCollapseHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { historyCollapsed.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text("发送记录 · \(jobs.count) 条")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if attentionCount > 0 {
                    Text("需关注 \(attentionCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.amber, in: Capsule())
                        .help("含待核对与已暂停任务")
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(historyCollapsed ? 0 : 90))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(GhostPressButtonStyle())
        .quietHover(lift: 1, scale: 1)
        .background(Surface(scheme).card.opacity(0.88), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .accessibilityLabel(historyCollapsed ? "展开发送记录，共 \(jobs.count) 条" : "收起发送记录，共 \(jobs.count) 条")
        .accessibilityHint("显示或隐藏发送记录列表")
    }

    /// 发送记录页的极简行：图标 + 群名 + 四值状态（发送 / 未发送 / 待核对 / 处理中；已取消单列，不渲染原因日志）。
    /// 与 queue 页 row() 分开实现，互不影响。处理能力收进次级入口（点行开详情、右键菜单），待核对记录仍随时可处理。
    private func historyRow(_ job: Delivery) -> some View {
        // 状态四值化：verified / manual = 发送；blocked / draft = 未发送；submitted / uncertain = 待核对（中性，不诱导重发）；
        // running = 处理中（正在执行，detail 只是过程信息，不当原因展示）
        let state: (label: String, tint: Color, symbol: String)
        switch job.status {
        case "verified", "manual": state = (job.statusName, Theme.green, "checkmark.circle.fill")
        case "blocked": state = ("已拦截", Theme.rose, "pause.circle.fill")
        case "draft": state = ("未发送", Theme.orange, "exclamationmark.circle.fill")
        case "submitted", "uncertain": state = ("待核对", Theme.amber, "questionmark.circle.fill")
        case "cancelled": state = ("已取消", Theme.slate, "xmark.circle.fill")
        case "running": state = ("发送中", Theme.indigo, "hourglass")
        default: state = ("未发送", Theme.orange, "exclamationmark.circle.fill")
        }
        let cancelled = job.status == "cancelled"
        // 已落定的行（发送 / 已取消）与处理中的行不渲染原因与日志；running 的 detail 只是“处理前已写入数据库”这类过程信息
        let settled = cancelled || job.status == "verified" || job.status == "manual" || job.status == "running"
        let lines = job.detail.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // 原因优先取 attentionReason（Core 已跳过“步骤：”行）；为空回退 detail 首个非空行
        let reason: String? = settled ? nil : (job.attentionReason ?? lines.first)
        // 走查 5-11：日志的切分原先拿「改写后的原因」回原始行里做逐字相等匹配。`Delivery.attentionReason`
        // 会跳过“步骤：”行，全是步骤行时还会 dropFirst(3) 改写字符串，于是 firstIndex(of:) 返回 nil
        // ——界面上“原因：”显示出来了，后面的步骤日志却整块消失。改成按 Core 的同一判据先定「原因行下标」，
        // 日志 = 该行之后的其余行，不再依赖字符串相等。
        var reasonIndex: Int? = nil
        if !settled, !lines.isEmpty { reasonIndex = lines.firstIndex(where: { !$0.hasPrefix("步骤：") }) ?? 0 }
        let logLines: [String] = reasonIndex.map { Array(lines.dropFirst($0 + 1)) } ?? []
        let expanded = moreDeliveryID == job.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: state.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.tint)
                Text(job.recipient)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(state.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.tint)
            }
            // 走查遗留：发送记录此前只有群名和状态，没有「什么时候发的」。已发送行用完成时刻
            // （finished 缺失时回退排期时刻），其余行展示原定排期时间。
            // 已取消记录的 finished 是取消时刻（cancelAllQueued 写入），不是排期：再标「排期于」
            // 会与创建时选的时间对不上（走查 2026-10-06）。与排期明显不同时改标「取消于」。
            let stamp: (label: String, date: Date) = {
                if state.label == "已发送", let f = job.finished { return ("发送于", f) }
                if state.label == "已取消", let f = job.finished, abs(f.timeIntervalSince(job.scheduled)) > 60 { return ("取消于", f) }
                return ("排期于", job.scheduled)
            }()
            Text("\(stamp.label) \(stamp.date.formatted(.dateTime.year().month().day().hour().minute()))")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            // 原因与日志只给未落定的行（未发送 / 待核对）；已确认发送与已取消保持极简
            if let reason {
                Text("原因：\(reason)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !logLines.isEmpty {
                    Text("日志：" + logLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
            }
            // 改名面板：右键菜单「改名」只负责把 moreDeliveryID 指到本行（popover 无法直接从 contextMenu 弹出）
            if expanded { morePanel(job) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface(scheme).card.opacity(0.88), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13)
                .fill(state.tint.opacity(0.85)).frame(width: 3)
        }
        .contentShape(Rectangle())
        // 整行是 onTapGesture 而不是 Button，样式层够不到，这里补一声。
        .onTapGesture { ClickFX.play(); selected = job }
        .contextMenu {
            if job.canResendAfterReview {
                Button { selected = job } label: { Label("去核对", systemImage: "checkmark.seal.fill") }
            }
            Button { selected = job } label: { Label("详情", systemImage: "info.circle") }
            if job.canRenameRecipient {
                Button { moreDeliveryID = expanded ? nil : job.id } label: { Label(expanded ? "收起改名" : "改名", systemImage: "pencil") }
            }
        }
        .help("点按查看详情与处理操作；故障记录核对后选择发送或不发送")
        .accessibilityElement(children: .contain)
    }

}

/// 详情面板。关闭一律走 dismiss()：QueueView 挂在 .id(store.route) 上，任务结束、授权或会员态变化
/// 都会整组重建它，那时父视图的 @State selected 已脱离视图树，写 nil 收不回已呈现的 sheet。
struct DeliveryDetailSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let original: Delivery
    var onClose: (() -> Void)? = nil
    @State private var resendError: String?
    @State private var redirectedDeliveryID: String?
    private func close() { if let onClose { onClose() } else { dismiss() } }

    var body: some View {
        let job = store.deliveries.first(where:{$0.id == (redirectedDeliveryID ?? original.id)}) ?? original
        return VStack(alignment:.leading, spacing:0) {
            header(job)
            Divider().padding(.horizontal, 20)
            ScrollView {
                VStack(alignment:.leading, spacing:14) {
                    if let guidance = job.listGuidance { notice(guidance) }
                    section("状态说明", symbol: "list.bullet.rectangle") {
                        Text(job.detail).font(.system(size: 12)).textSelection(.enabled)
                    }
                    if !job.assets.isEmpty {
                        section("附件 \(job.assets.count)", symbol: "photo.on.rectangle.angled") {
                            AttachmentStrip(assets: job.assets, compact: true)
                        }
                    }
                    section("发送内容", symbol: "text.quote") {
                        Text(job.text.isEmpty ? "（无文字）" : job.text)
                            .font(.system(size: 12.5)).textSelection(.enabled)
                    }
                    Text("任务 ID：\(job.id)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth:.infinity, alignment:.leading)
                .padding(20)
            }
            Divider().padding(.horizontal, 20)
            actionBar(job)
        }.frame(width: onClose == nil ? 720 : nil, height: onClose == nil ? 600 : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 头部一行三段：身份在左、徽章在身份下、处理入口在右。原来「修改群名」独占一行
    /// 且左对齐，和下面的操作区脱节，现在收进右上角。
    @ViewBuilder private func header(_ job: Delivery) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: StatusStyle.symbol(job.status), size: 36, gradient: StatusStyle.gradient(job.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.recipient).font(.system(size: 16, weight: .bold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                FlowHStack(hSpacing: 6, vSpacing: 4) {
                    ChannelPill(channel: job.channelName, compact: true)
                    Pill(status: job.status, name: job.statusName)
                    Pill(mode: job.mode, text: job.mode == "draft" ? "草稿模式" : "自动发送")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.canRenameRecipient && !job.canResendAfterReview {
                RenameRecipientButton(name: job.recipient, deliveryID: job.id)
            }
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(GhostPressButtonStyle(tint: Theme.slate, radius: 12))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Surface(scheme).inset.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            .accessibilityLabel("返回发送记录")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.amber.opacity(scheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.amber.opacity(0.30), lineWidth: 0.9))
    }

    @ViewBuilder private func section<Content: View>(_ title: String, symbol: String,
                                                    @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title: title, symbol: symbol)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Surface(scheme).inset.opacity(0.7), in: shape)
                .overlay(shape.strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        }
    }

    @ViewBuilder private func actionBar(_ job: Delivery) -> some View {
        let actionable = job.canResendAfterReview || job.canSendImmediately
        if actionable {
            let existing = ReviewedResend.existingAttempt(sourceID: job.id, jobs: store.deliveries)
            VStack(alignment: .leading, spacing: 10) {
                Text("先到\(SendChannel.displayName(job.channelName))查看实际消息。点击“发送”表示你已确认未成功发出、输入框草稿已清空；会立即按原图文发送。“不发送”保留原记录并停止此条。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let existing {
                    Text("此条已有新的发送记录（\(existing.statusName)）；点击下方任一决定会转到新记录，不会重复建立尝试或修改原记录。")
                        .font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
                if let resendError {
                    Text(resendError).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.rose)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("发送") {
                        if let existing { redirectedDeliveryID = existing.id; resendError = nil; return }
                        let began = job.canResendAfterReview
                            ? store.resendReviewed(job, confirmedUnsent: true, confirmedDraftCleared: true)
                            : store.sendSingle(job.id)
                        if began { close() }
                        else { resendError = store.error ?? "这条未能开始，请查看原因后再操作" }
                    }.buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                        .disabled(existing == nil && (store.busy || store.importingList || store.historyActionBusy))
                    Button("不发送") {
                        if let existing { redirectedDeliveryID = existing.id; resendError = nil; return }
                        if store.declineReviewed(job) { close() }
                        else { resendError = store.error ?? "记录已变化，请重新查看" }
                    }.buttonStyle(SoftButtonStyle(tint: Theme.rose))
                        .disabled(existing == nil && (store.historyActionBusy || (job.status == "submitted" && store.busy)))
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
    }
}

// MARK: - 队列内容预览（只读）

/// 发送前确认「到底会发什么」：文字、链接、图片、文件紧凑直出，不可修改；要改去新建发送
struct QueueContentPreviewSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let planID: String

    private var planName: String { store.plans.first { $0.id == planID }?.name ?? "当前计划" }
    private var queuedCount: Int { store.deliveries.filter { $0.planID == planID && $0.status == "queued" }.count }
    private var job: Delivery? {
        let jobs = store.queueJobs(planID: planID).sorted { $0.scheduled < $1.scheduled }
        return jobs.first { $0.status == "queued" } ?? jobs.first
    }
    private var links: [URL] {
        guard let job, !job.text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(job.text.startIndex..., in: job.text)
        return detector.matches(in: job.text, range: range).compactMap { $0.url }
    }
    /// 该计划的全部任务，按计划时间升序（发送时间轴数据源）
    private var jobs: [Delivery] {
        store.queueJobs(planID: planID).sorted { $0.scheduled < $1.scheduled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: "doc.text.magnifyingglass", size: 34, gradient: Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("将发送的内容").font(.system(size: 15, weight: .bold))
                    Text("\(planName) · \(queuedCount) 群待执行，每群发送相同内容")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
            }
            Divider().opacity(0.6)
            if let job {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 9) {
                        contentSection("文字", symbol: "text.alignleft") {
                            Text(job.text.isEmpty ? "（无文字）" : job.text)
                                .font(.system(size: 12.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(9).background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        if !links.isEmpty {
                            contentSection("链接 \(links.count)", symbol: "link") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(links, id: \.absoluteString) { url in
                                        Text(url.absoluteString)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .lineLimit(1).truncationMode(.middle)
                                            .foregroundStyle(Theme.blue).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        let images = job.assets.filter(\.isImage)
                        if !images.isEmpty {
                            contentSection("图片 \(images.count)", symbol: "photo.stack") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(images) { a in
                                            AssetThumbnail(asset: a).frame(width: 64, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .help(a.name)
                                        }
                                    }
                                }
                            }
                        }
                        let files = job.assets.filter { !$0.isImage }
                        if !files.isEmpty {
                            contentSection("文件 \(files.count)", symbol: "doc.fill") {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(files) { a in
                                        Label(a.name, systemImage: "doc")
                                            .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        if job.text.isEmpty && job.assets.isEmpty {
                            Text("此计划当前没有文字或附件。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        contentSection("发送时间轴", symbol: "clock.badge.checkmark") {
                            sendTimeline
                        }
                    }
                    .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyPanel(title: "该计划暂无任务", symbol: "tray", message: "没有可预览的发送内容。", tint: Theme.slate)
            }
            HStack(spacing: 6) {
                Image(systemName: "eye").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Text("仅预览；要修改请到「新建发送」调整草稿并同步。")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
    }

    @ViewBuilder private func contentSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: 发送时间轴（只读概览：每群一行，按计划时间排列）

    private let timelineMaxRows = 10
    /// 行高固定，竖线才能精确落在圆点圆心
    private let timelineRowHeight: CGFloat = 20

    private var sendTimeline: some View {
        let shown = Array(jobs.prefix(timelineMaxRows))
        let more = jobs.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.id) { item in
                timelineRow(item)
            }
            if more > 0 {
                Text("… 还有 \(more) 群")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 14) // 与上方正文对齐（圆点 8 + 间距 6）
                    .frame(height: timelineRowHeight, alignment: .center)
            }
        }
        .overlay(alignment: .leading) {
            // 竖线连接首尾圆点圆心；单行不画
            if shown.count > 1 {
                Rectangle().fill(Theme.indigo.opacity(0.15)).frame(width: 2)
                    .padding(.leading, 3) // 8pt 圆点的圆心 x = 4
                    .padding(.top, timelineRowHeight / 2)
                    .padding(.bottom, more > 0 ? timelineRowHeight * 1.5 : timelineRowHeight / 2)
            }
        }
    }

    private func timelineRow(_ item: Delivery) -> some View {
        let tint = timelineDotColor(item.status)
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(item.scheduled.formatted(.dateTime.month().day().hour().minute()))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            Text(item.recipient).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            Text(item.statusName).font(.system(size: 11)).foregroundStyle(tint)
            if !item.assets.isEmpty {
                Text("· \(item.assets.count) 个附件").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: timelineRowHeight)
        .accessibilityElement(children: .combine)
    }

    /// 时间轴圆点颜色（本页固定口径）
    private func timelineDotColor(_ status: String) -> Color {
        switch status {
        case "verified", "manual": return Theme.green
        case "blocked": return Theme.orange
        case "uncertain", "submitted": return Theme.amber
        case "cancelled": return Theme.slate
        case "draft": return Theme.rose
        case "running": return Theme.blue
        default: return Theme.indigo // queued 及未知状态
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ClickFX.soundKey) private var clickSoundOn = true
    @AppStorage(ClickFX.motionKey) private var clickMotionOn = true
    @State private var dataSizeText: String = "计算中…"
    @State private var dataBreakdown: [(String, Int64)] = []
    /// 走查 5-06：恢复备份的二次确认
    @State private var confirmRestore = false
    /// 展示给用户的应用路径：安装在 /Applications 下时只显示标准安装路径，避免一长串
    /// 实际目录让用户认错条目；其他位置（开发/临时目录运行）显示完整路径。
    /// 这里显示的就是系统「辅助功能」授权列表里要认准的那个 App——旧版升级后
    /// 重新添加授权时应以此路径为准。
    private var appPathDisplay: String {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") ? "/Applications/QQ排程助手" : path
    }
    var body: some View {
        ScrollView { VStack(spacing:16) {
            Card(title:"QQ 客户端连接",icon:"link",tint: Theme.blue) {
                HStack(spacing: 10) {
                    PermissionLight(granted: store.qqPermission, label: "QQ 辅助功能")
                    Spacer()
                    Button { store.refreshPermissions() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(store.busy)
                }
                Text("使用已登录的 macOS QQ，不需要 QQ 密码、机器人 Token 或云服务。首次使用请授权辅助功能。")
                    .font(.system(size: 12.5))
                HStack(spacing: 9) {
                    Button { store.tryQQ() } label: { Label("启动 QQ", systemImage: "arrow.up.forward.app.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.cool, tint: Theme.teal))
                        .gateDisabled(store.busy || !store.qqPermission, hint: "QQ 辅助功能尚未授权：先点「授权辅助功能」，系统设置里开启后再回来")
                    Button { QQDriver.requestPermission() } label: { Label("授权辅助功能", systemImage: "lock.shield.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } label: { Label("系统权限设置", systemImage: "gearshape.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Button { store.qqDiagnostic = store.driver.diagnostic() } label: { Label("只读检查 QQ", systemImage: "stethoscope") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet)).disabled(store.busy)
                }
                if !store.qqPermission {
                    Text("从旧版升级后，请在系统设置关闭再开启 QQ排程助手的开关。仍未生效时，移除旧条目，再添加下方显示的当前应用；返回软件会立即检查，必要时退出后重开。")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange)
                }
                Text("当前应用：\(appPathDisplay)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("先到「群与联系人」点击群名旁的「试跑定位」，观看打开 QQ → 搜索名称 → 进入会话。要试填图文，请在「新建发送」选择图片、文字和单个群，使用草稿模式；自动发送模式才会提交消息。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(store.qqDiagnostic).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(13)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                Text("支持中文 QQ 界面。QQ 升级、布局变化或额外确认窗口可能需要人工接管。建议先用测试群的草稿模式验收。自动模式会按一次回车键提交，请把 QQ 的发送快捷键设为回车键直接发送（Mac 上 Enter 与 Return 是同一个键）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title:"微信客户端连接",icon:"link",tint: Theme.wechat) {
                HStack(spacing: 10) {
                    PermissionLight(granted: store.wechatPermission, label: "微信辅助功能")
                    Spacer()
                    Button { store.refreshPermissions() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(store.busy)
                }
                Text("使用已登录的 macOS 微信。定位与发送核对依赖微信辅助功能控件，个别版本可能读不全——届时任务会停在「已提交 · 待核对」等你确认，不会盲发。")
                    .font(.system(size: 12.5))
                HStack(spacing: 9) {
                    Button { store.tryQQ(channel: SendChannel.wechat) } label: { Label("启动微信", systemImage: "arrow.up.forward.app.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green)).disabled(store.busy || !store.wechatPermission)
                        .opacity(store.wechatPermission ? 1 : 0.45)
                    Button { WeChatDriver.requestPermission() } label: { Label("授权辅助功能", systemImage: "lock.shield.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.green))
                    Button { store.wechatDiagnostic = store.wechatDriver.diagnostic() } label: { Label("只读检查微信", systemImage: "stethoscope") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.green)).disabled(store.busy)
                    Spacer()
                }
                if !store.wechatPermission {
                    Text("QQ 和微信共用本软件的辅助功能权限。授权后返回软件会立即检查；若系统已开启但仍未授权，请关闭再开启本软件的开关，必要时退出后重开。")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange)
                }
                Text("先到「群与联系人」用渠道切换到微信，添加目标后点「试跑定位」：打开微信 → 搜索名称 → 进入会话，不发送任何消息。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(SendChannel.weChatEnterNote)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(store.wechatDiagnostic).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(13)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            }
            Card(title:"排程行为",icon:"timer",tint: Theme.amber) {
                HStack {
                    Toggle("核验发送成功后播放专用音效", isOn: Binding(
                        get: { store.settings.successSoundEnabled ?? true },
                        set: { store.settings.successSoundEnabled = $0; store.saveSettings() })).toggleStyle(.switch)
                    Button("试听成功音效") { _ = SystemSendPresentation.shared.playSuccessSound() }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                }
                Toggle("成功后最小化聊天窗口和本软件窗口", isOn: Binding(
                    get: { store.settings.minimizeAfterSuccess ?? true },
                    set: { store.settings.minimizeAfterSuccess = $0; store.saveSettings() })).toggleStyle(.switch)
                Text("成功后播放专用音效并收窗，下一条到时展开。故障仅记入发送记录；你未暂停或切走时也会收窗，不播放成功音。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("发送成功后自动返回排程助手", isOn: Binding(get: { store.settings.returnToSchedulerAfterSend ?? true }, set: { store.settings.returnToSchedulerAfterSend = $0; store.saveSettings() })).toggleStyle(.switch)
                    .disabled(store.settings.minimizeAfterSuccess != false)
                Toggle("发送成功后尽量切回原应用",isOn:Binding(get:{store.settings.restorePreviousApp ?? true},set:{store.settings.restorePreviousApp = $0; store.saveSettings()})).toggleStyle(.switch)
                    .disabled(store.settings.minimizeAfterSuccess != false)
                Text("关闭成功后最小化，才使用自动返回设置；自动返回排程助手优先。发送未核验或你已切换应用时，不自动切换窗口。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("错峰发送（打散等差间隔）", isOn: Binding(
                    get: { store.settings.staggerJitter ?? false },
                    set: { store.settings.staggerJitter = $0; store.saveSettings() })).toggleStyle(.switch)
                Text("开启后新建计划与重启排期时，后续群的间隔加 0~20% 随机上浮，避免整点等差间隔触发风控。默认关闭。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text("发送故障、待核对和排程提示只在软件内显示，不弹系统通知或确认窗。核对页只有“发送”和“不发送”。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Stepper("全局最小发送间隔：\(store.settings.globalGapMinutes) 分钟",value:$store.settings.globalGapMinutes,in:1...1440)
                    .onChange(of:store.settings.globalGapMinutes) { _,_ in store.saveSettings() }
                Text(SendChannel.scheduleBehaviorNote)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                // 走查 5-01：退出不再是无声的 stop()+terminate()，把新行为一并写进这里的说明。
                Text("关闭主窗口后程序仍在菜单栏运行；彻底停止请点“暂停全部”或退出软件。退出时停止队列并保存当前操作，重开保持暂停；已提交但结果不明的记录留待核对。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title:"界面反馈",icon:"hand.tap.fill",tint: Theme.violet) {
                Toggle("点击音效", isOn: $clickSoundOn).toggleStyle(.switch)
                Toggle("点击涟漪动效", isOn: $clickMotionOn).toggleStyle(.switch)
                Text("每次按下按钮会同时给出轻响、触控板震动和一圈扩散涟漪。系统「减少动态效果」开启时自动只保留音效。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Button("试听：主按钮") {}.buttonStyle(DepthButtonStyle(compact: true))
                    Button("试听：次按钮") {}.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Spacer()
                }
            }
            Card(title:"会员服务器",icon:"crown.fill",tint: Theme.amber) {
                HStack(spacing: 10) {
                    TextField("http://127.0.0.1:8790", text: Binding(
                        get: { store.settings.licenseServerURL ?? LicenseService.defaultBaseURLString },
                        set: { store.settings.licenseServerURL = $0; store.updateLicenseServer(); store.saveSettings() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    Button { store.testLicenseServer() } label: { Label("测试连接", systemImage: "dot.radiowaves.left.and.right") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.amber)).disabled(store.licenseBusy)
                    if store.licenseBusy { ProgressView().controlSize(.small) }
                }
                if let result = store.licenseTestResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Theme.green)
                        Text(result).font(.system(size: 12)).foregroundStyle(Theme.green)
                    }
                }
                Text("登录、注册、套餐与卡密兑换都请求这个自建会员服务。默认本机 127.0.0.1:8790，可改为团队部署的地址，修改后立即生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title:"本机资料库",icon:"externaldrive.fill",tint: Theme.teal) {
                HStack(alignment: .top, spacing: 8) {
                    Text(store.db.root.path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth:.infinity, alignment:.leading)
                        .padding(11)
                        .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(store.db.root.path, forType: .string)
                        store.step = "已复制数据目录路径到剪贴板"
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                        .help("复制完整路径")
                }
                HStack(spacing: 14) {
                    storageBadge(label: "总占用", size: dataBreakdown.reduce(0) { $0 + $1.1 }, tint: Theme.indigo, symbol: "externaldrive.fill")
                    storageBadge(label: "数据库", size: dataBreakdown.first(where: { $0.0 == "db" })?.1 ?? 0, tint: Theme.violet, symbol: "cylinder.split.1x2")
                    storageBadge(label: "素材", size: dataBreakdown.first(where: { $0.0 == "assets" })?.1 ?? 0, tint: Theme.teal, symbol: "photo.stack")
                    storageBadge(label: "备份", size: dataBreakdown.first(where: { $0.0 == "backups" })?.1 ?? 0, tint: Theme.green, symbol: "clock.arrow.circlepath")
                    Spacer(minLength: 0)
                }
                // 连接级自愈留痕：瞬时磁盘故障已在 Database 内部重连重试成功，不打扰、不停车，这里如实记账
                if store.db.recoveryCount > 0 {
                    Text("数据库连接自愈：本次运行已自动恢复 \(store.db.recoveryCount) 次（最近一次 \(store.db.lastRecovery?.at.formatted(date: .abbreviated, time: .shortened) ?? "—")）。瞬时磁盘故障已修复，未影响队列；若频繁出现建议检查磁盘健康并备份数据库。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    Button { NSWorkspace.shared.open(store.db.root) } label: { Label("打开数据文件夹", systemImage: "folder.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.db.root]) } label: { Label("在访达中显示", systemImage: "magnifyingglass") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Button { store.backup() } label: { Label("备份数据库与素材", systemImage: "externaldrive.fill.badge.checkmark") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                    Button { confirmRestore = true } label: { Label("恢复备份", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.amber))
                        .disabled(store.busy || store.running)
                        .help(store.running ? "队列运行中：先点「暂停全部」，再恢复备份" : "整库替换当前资料；确认后会先在 backups/ 留一份恢复前副本")
                    // 走查 1-07 交接：坏行原文只在隔离区里，启动提示叫人「先导出备份」却拿不到坏行，这里补出口。
                    // 判据用本次连接的内存索引（hasUndecodableRows），不在 body 里做 SQL 计数查询。
                    if store.db.hasUndecodableRows {
                        Button { store.exportQuarantine() } label: { Label("导出隔离区坏行", systemImage: "exclamationmark.triangle.fill") }
                            .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                            .help("把 quarantine_rows 里的原始 payload 逐条导出，供人工核对或手工修库")
                    }
                }
                // 走查 5-06：恢复备份会整体替换名单/计划/记录，按 AGENTS.md 第 6 行要求先披露范围并二次确认，
                // 队列运行中或直接不给点；有待核对记录时必须由用户明确确认才会执行。
                .confirmationDialog("用备份替换当前资料？", isPresented: $confirmRestore, titleVisibility: .visible) {
                    Button("选择备份文件夹并恢复", role: .destructive) { store.restoreBackup(confirmed: true) }
                    Button("返回", role: .cancel) {}
                } message: {
                    Text("将把本机资料整体替换为所选备份的内容：\(store.recipients.count) 个群、\(store.plans.count) 个计划、\(store.deliveries.count) 条记录会被备份里的同名条目取代。"
                        + (store.reviewPendingCount > 0 ? "当前还有 \(store.reviewPendingCount) 条待核对或已暂停的记录，它们同样会被替换，未处理的结果不会带进备份。" : "")
                        + "恢复前会自动在 backups/恢复前-… 保留当前数据库与素材；恢复后队列保持暂停。")
                }
                Text("SQLite 保存群名单、素材索引、计划快照和发送记录；assets 保存文件原件。备份包含文案和文件，恢复前自动保留原数据库及素材。软件不会自动清理历史素材。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(22).frame(maxWidth: 900).frame(maxWidth: .infinity) }
        .task { await refreshDataUsage() }
    }

    private func storageBadge(label: String, size: Int64, tint: Color, symbol: String) -> some View {
        let text = size == 0 ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(scheme == .dark ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }

    private func refreshDataUsage() async {
        let root = store.db.root
        let result = await Task.detached(priority: .utility) {
            Self.computeUsage(at: root)
        }.value
        await MainActor.run {
            self.dataBreakdown = result
        }
    }

    nonisolated private static func computeUsage(at root: URL) -> [(String, Int64)] {
        let fm = FileManager.default
        var dbBytes: Int64 = 0
        for ext in ["library.sqlite3", "library.sqlite3-wal", "library.sqlite3-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: root.appendingPathComponent(ext).path),
               let size = attrs[.size] as? Int64 { dbBytes += size }
        }
        var assetBytes: Int64 = 0
        let assets = root.appendingPathComponent("assets")
        if let en = fm.enumerator(at: assets, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in en {
                if let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   attrs.isRegularFile == true, let size = attrs.fileSize { assetBytes += Int64(size) }
            }
        }
        var backupBytes: Int64 = 0
        let backups = root.appendingPathComponent("backups")
        if let en = fm.enumerator(at: backups, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in en {
                if let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   attrs.isRegularFile == true, let size = attrs.fileSize { backupBytes += Int64(size) }
            }
        }
        return [("db", dbBytes), ("assets", assetBytes), ("backups", backupBytes)]
    }
}

// MARK: - 未核验结果说明

/// 未核验结果留在日志中，后续群继续；不把跳过的结果标为成功，也不自动重发。
enum UnverifiedStop {
    static func note(recipient: String, appName: String = "QQ") -> String {
        "\(recipient)：结果未能核验，已留在发送记录待人工处理；继续当前计划下一条待执行任务。"
    }
    static func explanation(appName: String = "QQ") -> String {
        "未核验的结果保留在发送记录，可稍后核对和手动重发；队列继续其他待执行群。"
    }
}

// MARK: - 退出门禁（走查 5-01）

/// 「退出」原先是一次 `stop()` + `NSApp.terminate`：一次真实发送正卡在 QQ 输入框里，
/// 进程也会立刻结束，记录留在「正在发送」、客户端里留着半成品的草稿，谁都没得到交代。
/// 这里只改一件事：退出前先问一次，并把会留下的东西如实写进文案。
/// 判定不放宽、记录不清除（AGENTS.md 第 9 行）——用户坚持要走就让他走，但他要知道代价。
enum ExitGate {
    /// 驱动此刻正在操作目标客户端：会话已打开，输入框里可能已经填了一半。
    static let activeStatuses: Set<String> = ["running"]
    /// 已经尝试过、结果还没定论：按下过发送键、核验不出结果，或停在草稿等待人工确认。
    static let unresolvedStatuses: Set<String> = ["submitted", "uncertain", "draft"]
    static func active(_ statuses: [String]) -> Int { statuses.filter { activeStatuses.contains($0) }.count }
    static func unresolved(_ statuses: [String]) -> Int { statuses.filter { unresolvedStatuses.contains($0) }.count }
    /// 队列在跑、有一条前台操作正占着客户端，或存在未定论记录——任意一条成立，退出就要打断发送。
    static func interruptsSend(running: Bool, busy: Bool, statuses: [String]) -> Bool {
        running || busy || active(statuses) > 0 || unresolved(statuses) > 0
    }

    struct Confirmation {
        let interrupts: Bool
        let title: String
        let body: String
        let confirmTitle: String
    }

    static func confirmation(running: Bool, busy: Bool, statuses: [String], appName: String = "QQ") -> Confirmation {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "QQ" : trimmed
        let active = active(statuses)
        let unresolved = unresolved(statuses)
        guard interruptsSend(running: running, busy: busy, statuses: statuses) else {
            return Confirmation(interrupts: false, title: "退出 QQ排程助手？",
                                body: "关闭主窗口后程序仍在菜单栏继续调度；退出会停止全部排程。"
                                    + "当前没有正在进行的发送，也没有待核对的记录；待执行任务保持原样，"
                                    + "下次启动后仍需要手动点「启动队列」。",
                                confirmTitle: "确认退出")
        }
        var lines: [String] = []
        if active > 0 {
            lines.append("有 \(active) 条任务正在\(shown)里执行\((running || busy) ? "" : "（队列已暂停，但这一条还没走完）")，退出会把它拦腰打断。")
        } else if running {
            lines.append("队列正在运行：退出会把它停在两条任务之间，剩下的排期不会再自动执行。")
        } else if busy {
            lines.append("当前有一次\(shown)操作正在进行（试跑、读取或验证群名、填草稿、按已核对草稿续发），现在退出会拦腰打断它。")
        } else {
            lines.append("有 \(unresolved) 条记录已经尝试过\(shown)，结果还没有定论。")
        }
        if active == 0 && unresolved > 0 {
            lines.append("另外那 \(unresolved) 条已经按下过发送键或核验不出结果。")
        }
        lines.append("· 已经填进\(shown)输入框的草稿不会被撤回，会话里可能留下半成品的草稿，需要你手动清理。")
        lines.append("· 这些记录不会被清除，也不会被自动改写成「已发送」：下次启动时「正在发送 / 已提交」会转成『结果待核对』，"
                    + "可稍后到发送记录核对实际结果，不影响其他待执行任务启动。")
        lines.append("· 待执行任务保持原样，重启后仍要手动点「启动队列」。")
        lines.append("退出前可先点「暂停全部」，等正在处理的这一条结束；日志核对可稍后处理。")
        return Confirmation(interrupts: true, title: (running || busy || active > 0) ? "退出会打断正在进行的发送" : "退出 QQ排程助手？",
                            body: lines.joined(separator: "\n"), confirmTitle: "仍然退出")
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }

    /// 走查 5-01：终止回调要读队列与在途记录。Store 由 `QQDispatchApp.init` 在进程内唯一构造，
    /// 这里只挂弱引用、不改变它的生命周期；取不到时按旧行为直接放行，绝不把用户锁在 App 里。
    static weak var store: Store?
    /// 用户已经确认过的那一次：放行后不再重复弹窗（reply(true) 之后仍可能再走一遍终止流程）。
    private var exitApproved = false
    /// 已经有一个确认框在等用户回答：随后到来的终止请求只排队等结果，不再叠第二层弹窗。
    private var exitPromptPending = false

    /// 走查 5-01：⌘Q、应用菜单「退出」、菜单栏「退出」按钮、代码里任何 `NSApp.terminate` 都先经过这里。
    /// 队列在跑，或有记录处于「已 started / 已提交但未定论」时，必须先如实警告再确认；
    /// 用户取消就返回 .terminateCancel，一个状态都不改（不放宽校验、不清除记录）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if exitApproved { return .terminateNow }
        guard let store = Self.store else { return .terminateNow }
        if exitPromptPending { return .terminateLater }
        exitPromptPending = true
        let finish: (Bool) -> Void = { [weak self] approved in
            if let self {
                self.exitPromptPending = false
                if approved { self.exitApproved = true }
            }
            sender.reply(toApplicationShouldTerminate: approved)
        }
        // AppKit 在主线程调用本回调；万一不是主线程，也只排回主队列，不拿 assumeIsolated 硬闯——
        // 它会 trap，为了一次退出确认把进程弄崩是不可接受的。
        if Thread.isMainThread {
            MainActor.assumeIsolated { store.requestExitConfirmation(finish) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { store.requestExitConfirmation(finish) } }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 兜底真实 AppKit 控件（开关 / 步进器 / 菜单）的点击声，SwiftUI 自绘样式够不到这些。
        ClickFX.installGlobalListener()
        ClickFX.warmUp()
        // 发送结果系统通知：启动时登记通知中心与已保存的开关状态。
        QuietDispatchNotifications.clearPreviousNotifications()
    }
}
#if !RENDER_HARNESS
@main
struct QQDispatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: Store
    @State private var showShortcuts = false
    @Environment(\.scenePhase) private var scenePhase
    init() {
        do {
            let root = ProcessInfo.processInfo.environment["QQ_DISPATCH_DATA_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("QQ排程助手")
            let model = try Store(root:root)
            _store = StateObject(wrappedValue:model)
            // 走查 5-01：把进程内唯一构造的 Store 交给终止回调，
            // ⌘Q / 应用菜单「退出」/ 菜单栏「退出」按钮由此共用同一道退出闸。
            AppDelegate.store = model
        } catch {
            let alert = NSAlert(); alert.messageText = "QQ排程助手无法启动"; alert.informativeText = error.localizedDescription; alert.runModal(); exit(1)
        }
    }
    var body: some Scene {
        WindowGroup("QQ排程助手",id:"main") { RootView().environmentObject(store).environment(\.timeZone,TimeZone(identifier:"Asia/Shanghai")!).tint(.indigo)
            .sheet(isPresented: $showShortcuts) { ShortcutHelpView() }
            .onOpenURL { url in _ = store.handleRelationshipURL(url) }
            // 退后台/关窗时把防抖中的草稿立即落盘，收窄崩溃丢草稿的窗口；「失活」由 didResignActiveNotification 兜底
            .onChange(of: scenePhase) { _, phase in if phase != .active { store.flushDraftPersist() } }
        }.defaultSize(width:1220,height:840)
            .commands {
                CommandGroup(replacing:.newItem) {}
                CommandGroup(after: .windowArrangement) {
                    Button("键盘快捷键") { showShortcuts = true }.keyboardShortcut("?", modifiers: .command)
                }
                CommandMenu("前往") {
                    Button("总览") { store.route = "home" }.keyboardShortcut("1",modifiers:.command)
                    Button("新建发送") { store.route = "compose" }.keyboardShortcut("2",modifiers:.command)
                    Button("素材库") { store.route = "assets" }.keyboardShortcut("3",modifiers:.command)
                    Button("群与联系人") { store.route = "recipients" }.keyboardShortcut("4",modifiers:.command)
                    Button("发送队列") { store.route = "queue" }.keyboardShortcut("5",modifiers:.command)
                    Button("发送记录") { store.route = "history" }.keyboardShortcut("6",modifiers:.command)
                    Button("会员中心") { store.route = "member" }
                    Button("设置与备份") { store.route = "settings" }.keyboardShortcut("7",modifiers:.command)
                }
                CommandMenu("排程") {
                    Button("启动当前计划") { store.start(planID: store.displayedQueuePlanID) }
                        .keyboardShortcut("r",modifiers:.command)
                        .disabled(store.isQueueRunning(store.displayedQueuePlanID) || store.busy || store.displayedQueueCandidate == nil)
                    Button("暂停全部") { store.stop() }.keyboardShortcut(".",modifiers:.command)
                    Button("导入素材") { store.chooseFiles() }.keyboardShortcut("i",modifiers:.command)
                }
            }
        // 对标 MeetingBar/Itsycal：条带常驻「下一群还有多久」。label 只能经由独立小模型（MenuBarStatus）
        // 渲染单个 Text——直接读 Store 会在启动期被 @Published 风暴反复 invalidate，状态按钮初始化死循环、
        // 整个 App 卡死（macOS 26 实测两次）；HStack/TimelineView 形态同样卡死。
        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
/// 菜单栏条带状态：独立小模型，label 绝不直接读 Store。Store 的任意 @Published 变化都会让它
/// 整体失效——启动期的连环失效会让 MenuBarExtraController.updateButton 的 setImage 在重入下
/// 布局/图像解析死循环，整个 App 卡死在 didFinishLaunching（macOS 26 实测两次，见 Store.init 注释）。
/// 这里只靠自己的 30 秒定时器刷新；store 侧变化（建任务、启动、发送完成）最多延迟一个周期反映到条带。
@MainActor final class MenuBarStatus: ObservableObject {
    @MainActor static let shared = MenuBarStatus()
    @Published var title = "✈️"
    private var timer: Timer?
    private weak var store: Store?
    func attach(store: Store) {
        self.store = store
        refresh()
        guard timer == nil else { return }
        // 定时器挂在主 runloop（attach 必在主线程调用），回调用 assumeIsolated 回到主 Actor。
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func refresh() {
        guard let store else { return }
        if store.busy { title = "✈️ 发送中"; return }
        var parts = ["✈️"]
        if store.running, let countdown = MenuBarTitle.text(now: Date(), next: store.nextDelivery.map { store.earliestSendDate($0) }, calendar: Scheduling.calendar) {
            parts.append("\(store.runningPlanIDs.count) 队列 · " + countdown)
        } else { parts.append("已暂停") }
        let attention = QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))
        if attention > 0 { parts.append("⚠️\(attention)") }
        title = parts.joined(separator: " ")
    }
}

/// MenuBarExtra 的 label：单独成 View 才能以 @ObservedObject 只订阅 MenuBarStatus（单例直接读
/// @Published 不会建立订阅）。✈️ 前缀保证条带永不为空。
private struct MenuBarLabel: View {
    @ObservedObject private var status = MenuBarStatus.shared
    var body: some View { Text(status.title) }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    var body: some View {
        // 与总览「今日发送战报」同口径：body 求值时算一次即可（O(n) 遍历）。
        let planNames = Dictionary(store.plans.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let report = DailySendReport.today(deliveries: store.displayedQueueJobs, planNames: planNames, now: Date(), calendar: Scheduling.calendar)
        Button(MainWindowOpen.title(busy: store.busy, running: store.running)) {
            openWindow(id: "main")
            if MainWindowOpen.activatesOverTarget(busy: store.busy, running: store.running) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        .onReceive(NotificationCenter.default.publisher(for: .init("QQDispatchReturnAfterSend"))) { _ in openWindow(id: "main") }
        if let hint = PauseControl.menuHint(busy: store.busy, running: store.running, appName: store.operationAppName) {
            Text(hint)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        MenuTodaySection()
        Divider()
        HStack(spacing: 8) {
            Text(store.running ? "队列运行中" : "队列已暂停")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(store.running ? Theme.green : .secondary)
            Spacer()
            Text("待执行 \(store.displayedQueueJobs.filter { $0.status == "queued" }.count) 条")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if report.hasContent {
            // 菜单栏首屏的三色摘要；为 0 的类别弱化，与总览胶囊同一套语言。
            // 走查 2026-10-06：外行想点它看详情——包一层按钮直达发送队列。
            Button {
                store.route = "queue"
                openWindow(id: "main")
            } label: {
            HStack(spacing: 0) {
                Text("今日 ").foregroundStyle(.secondary)
                Text("✓\(report.sent)").foregroundStyle(Theme.green).opacity(report.sent > 0 ? 1 : 0.45)
                Text(" · 待核 ").foregroundStyle(.secondary)
                Text("\(report.pendingReview)").foregroundStyle(Theme.amber).opacity(report.pendingReview > 0 ? 1 : 0.45)
                Text(" · 拦 ").foregroundStyle(.secondary)
                Text("\(report.blocked)").foregroundStyle(Theme.rose).opacity(report.blocked > 0 ? 1 : 0.45)
            }
            .font(.system(size: 11))
            } .buttonStyle(.plain)
        }
        if let next = store.displayedQueueCandidate {
            Text("下一群：\(next.recipient) · 最早 \(store.earliestSendDate(next).formatted(date:.omitted,time:.standard))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if !store.isQueueRunning(store.displayedQueuePlanID) {
            Button("启动当前队列") { store.start(planID: store.displayedQueuePlanID) }
                .disabled(store.busy || store.displayedQueueCandidate == nil)
        }
        let reviewCount = QueueStartGate.reviewCount(store.displayedQueueJobs.map(\.status))
        if reviewCount > 0 {
            Text("本计划 \(reviewCount) 条结果可稍后核对，其他待执行群继续。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("查看发送记录") {
                store.route = "history"
                openWindow(id: "main")
                if MainWindowOpen.activatesOverTarget(busy: store.busy, running: store.running) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        Divider()
        Button("暂停全部") { store.stop() }.disabled(!PauseControl.available(busy: store.busy, running: store.running))
        // 走查 5-01：退出前先把「会打断什么」写在按钮上方，点下去还有二次确认；
        // 只补这颗按钮不够——⌘Q 与应用菜单的「退出」由 applicationShouldTerminate 拦同一道闸。
        if ExitGate.interruptsSend(running: store.running, busy: store.busy, statuses: store.deliveries.map(\.status)) {
            Text(store.running || store.busy ? "有发送正在进行：退出会停止排程，\(store.operationAppName) 里可能残留草稿。可先暂停并等当前操作结束。" : "未定论日志会保留，核对可稍后处理。")
                .font(.system(size: 11)).foregroundStyle(Theme.rose)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button("退出") { store.requestExit() }
    }
}

// MARK: - 键盘快捷键速查

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var rows: [(String, [(String, String)])] = [
        ("页面跳转", [
            ("⌘1", "总览"),
            ("⌘2", "新建发送"),
            ("⌘3", "素材库"),
            ("⌘4", "群与联系人"),
            ("⌘5", "发送队列"),
            ("⌘6", "发送记录"),
            ("⌘7", "设置与备份")
        ]),
        ("排程操作", [
            ("⌘R", "启动当前计划；待核对日志可稍后处理"),
            ("⌘.", "暂停全部（发送中主窗口可能在 QQ 或微信后面）"),
            ("⌘I", "导入素材")
        ]),
        ("其他", [
            ("⌘?", "显示此速查"),
            ("⌘Q", "退出软件；有发送正在进行或结果未定论时会先要求确认")
        ])
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "command", size: 36, gradient: Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("键盘快捷键").font(.system(size: 18, weight: .bold))
                    Text("随时按 ⌘? 再次打开").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SoftButtonStyle(tint: Theme.slate))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(rows, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0).font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.indigo)
                                .tracking(1.2)
                            DepthSurface(radius: 14, padding: 0, accent: Theme.indigo) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.1.enumerated()), id: \.offset) { idx, item in
                                        HStack(spacing: 14) {
                                            Text(item.0).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .frame(minWidth: 60, alignment: .leading)
                                                .padding(.horizontal, 10).padding(.vertical, 4)
                                                .background(Theme.indigo.opacity(scheme == .dark ? 0.20 : 0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            Text(item.1).font(.system(size: 12.5))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        if idx < group.1.count - 1 {
                                            Divider().opacity(0.4).padding(.leading, 14)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            Text("快捷键仅在主窗口聚焦时生效；菜单栏菜单项同样可用。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            // 走查 2026-10-06：侧栏顺序（新建/队列/记录/群/素材/总览/会员/设置）与 ⌘ 编号不一致，
            // 在面板底部把编号↔页面映射写全，避免用户按侧栏位置猜编号。CommandMenu 绑定不动。
            Text("侧栏排序与快捷键编号不同：⌘1=总览 · ⌘2=新建 · ⌘3=素材 · ⌘4=群 · ⌘5=队列 · ⌘6=记录 · ⌘7=设置")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 540)
    }
}

struct ExpandQueuePlanView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let planID: String
    @State private var selectedIDs: Set<String> = []
    private var plan: Plan? { store.plans.first { $0.id == planID } }
    private var candidates: [Recipient] {
        guard let plan else { return [] }
        let jobs = store.deliveries.filter { $0.planID == planID }
        return store.recipients.filter { r in
            !plan.recipientIDs.contains(r.id) && !jobs.contains { $0.recipient == r.name && $0.channelName == r.channelName }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加群到本计划").font(.system(size: 22, weight: .bold))
            Text(plan?.name ?? "计划不存在").foregroundStyle(.secondary)
            Text("名单共 \(store.recipients.count) 个群，还有 \(candidates.count) 个未加入本计划。每个新增群追加一条任务，沿用本计划的图文，按发送间隔排到队尾。")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("全选新增群") { selectedIDs = Set(candidates.map(\.id)) }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                Button("清空选择") { selectedIDs = [] }
                    .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                Text("已选 \(selectedIDs.count) 个")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(candidates) { r in
                        Toggle(isOn: Binding(get: { selectedIDs.contains(r.id) }, set: { if $0 { selectedIDs.insert(r.id) } else { selectedIDs.remove(r.id) } })) {
                            HStack { Text(r.name); Spacer(); ChannelPill(channel: r.channelName, compact: true) }
                        }.toggleStyle(.checkbox)
                    }
                    if candidates.isEmpty { Text("名单中的群已全部加入本计划。") }
                }.padding(8)
            }.frame(minHeight: 130, maxHeight: 320)
            Text("只加入队列，不会立即发送。原有任务和发送记录保留。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("返回") { dismiss() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                Button("加入队列（\(selectedIDs.count) 个群）") {
                    if store.appendRecipients(planID: planID, ids: selectedIDs) { dismiss() }
                }.buttonStyle(DepthButtonStyle()).disabled(selectedIDs.isEmpty || store.busy || store.running)
            }
        }.padding(24).frame(width: 600)
    }
}
