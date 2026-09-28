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
    @Published var recipients: [Recipient] = []
    @Published var assets: [Asset] = []
    @Published var plans: [Plan] = []
    @Published var deliveries: [Delivery] = []
    @Published var settings = Settings()
    @Published var running = false { didSet { updateActivity() } }
    @Published var activePlanID: String?
    @Published var busy = false
    @Published var step = "尚未启动队列"
    @Published var error: String?
    @Published var diagnostic = "先检查 QQ 与辅助功能权限。"
    @Published var route = "home"
    @Published var qqPermission: Bool = QQDriver.trusted
    @Published var wechatPermission: Bool = WeChatDriver.trusted
    // MARK: 会员体系状态
    @Published var licenseState: LicenseState = .loggedOut
    @Published var guestMode = false
    @Published var licenseBusy = false
    @Published var licensePlans: [PlanInfo] = PlanCatalog.fallback   // 会员中心价格卡；服务端不可达时保持内置兜底
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
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private func updateActivity() {
        if running && activity == nil { activity = ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled],reason:"执行用户启动的 QQ 排期") }
        if !running, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
    }
    // 今日任务（今天 00:00 起，含未来天；用于总览时间线）
    var todayDeliveries: [Delivery] {
        deliveries.filter { $0.scheduled >= Calendar.current.startOfDay(for: Date()) }.sorted { $0.scheduled < $1.scheduled }
    }
    var intervalByPlan: [String:Int] {
        var result: [String:Int] = [:]
        for plan in plans {
            let minutes = Scheduling.paceMinutes(plan)
            result[plan.id] = min(result[plan.id] ?? minutes, minutes)
        }
        return result
    }
    var nextDelivery: Delivery? { nextDelivery(planID: activePlanID) }
    func nextDelivery(planID: String?) -> Delivery? {
        Scheduling.nextCandidate(deliveries, gap: settings.globalGapMinutes, planID: planID, intervalByPlan: intervalByPlan)
    }
    func earliestSendDate(_ job: Delivery) -> Date {
        Scheduling.earliestSendDate(job, jobs: deliveries, gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan)
    }
    func timingExplanation(_ job: Delivery) -> String {
        if busy { return "正在处理当前群，完成后继续" }
        if deliveries.contains(where: { ["draft", "submitted", "uncertain"].contains($0.status) }) { return "有待核对任务，请到发送记录处理" }
        if let activePlanID, activePlanID != job.planID, running { return "正在运行其他计划，此计划未启动" }
        let due = earliestSendDate(job)
        if !running { return "队列已暂停，点击启动后执行" }
        if due > Date() {
            return due > job.scheduled ? "正在等待发送间隔；原排期已顺延，以最早发送时间为准" : "等待预定时间，到时自动发送"
        }
        return "已满足发送时间，正在调度"
    }
    var queuedCount: Int { deliveries.filter { $0.status == "queued" }.count }
    var verifiedCount: Int { deliveries.filter { ["verified","manual"].contains($0.status) }.count }
    var attentionCount: Int { deliveries.filter { ["draft","uncertain","blocked","submitted"].contains($0.status) }.count }
    private let lockFD: Int32
    var archive: Archive { Archive(recipients:recipients,assets:assets,plans:plans,deliveries:deliveries,settings:settings) }
    private var permissionTimer: Timer?
    private var permissionActivationObserver: NSObjectProtocol?

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
    }

    func refreshPermissions() {
        // Accessibility belongs to this process, not to the destination chat app.
        let granted = QQDriver.trusted
        qqPermission = granted
        wechatPermission = granted
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
        if let observer = permissionActivationObserver { NotificationCenter.default.removeObserver(observer) }
    }

    init(root: URL, relationshipNavigator: RelationshipChatNavigator? = nil) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        lockFD = Darwin.open(root.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR,0o600)
        guard lockFD >= 0, flock(lockFD,LOCK_EX | LOCK_NB) == 0 else { throw AppError("QQ排程助手已经在运行，请使用已打开的窗口") }
        db = try Database(root:root)
        relationshipInbox = RelationshipInbox(appRoot: root)
        self.relationshipNavigator = relationshipNavigator ?? wechatDriver
        recipients = try db.load("recipients",as:Recipient.self)
        assets = try db.load("assets",as:Asset.self)
        plans = try db.load("plans",as:Plan.self)
        deliveries = try db.load("deliveries",as:Delivery.self)
        startPermissionWatch()
        settings = try db.load("settings",as:Settings.self).first ?? Settings(savedText: "")
        if settings.textTemplates == nil { settings.textTemplates = settings.savedText.isEmpty ? [] : [TextTemplate(text:settings.savedText)] }
        // 会员：先用本地档案离线判定（active/grace/expired），随后异步向服务器校验
        license.baseURL = LicenseService.normalize(settings.licenseServerURL)
        licenseState = LicenseState.resolve(profile:settings.licenseProfile,now:Date(),lastValidated:settings.licenseLastValidated)
        if case .expired = licenseState { route = "member" }
        #if RENDER_HARNESS
        // 渲染工具自行注入演示态，不访问钥匙串与网络
        #else
        Task { restoreSession() }
        #endif
        let firstLaunch = !FileManager.default.fileExists(atPath:root.appendingPathComponent("initialized").path)
        settings.prepareWorkspaces(recipientIDs: recipients.filter(\.enabled).map(\.id))
        deliveries = Scheduling.recovered(deliveries)
        let refreshed = LiveMessage.refreshed(archive)
        plans = refreshed.plans; deliveries = refreshed.deliveries
        try persist()
        if firstLaunch { try Data("1".utf8).write(to:root.appendingPathComponent("initialized"),options:.atomic) }
        driver.onStep = { [weak self] in self?.step = $0 }
        wechatDriver.onStep = { [weak self] in self?.step = $0 }
        relationshipInbox.refresh()
        #if !RENDER_HARNESS
        relationshipTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.relationshipInbox.refresh(ifModifiedOnly: true) }
        }
        let dispatchTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer = dispatchTimer
        RunLoop.main.add(dispatchTimer, forMode: .common)
        #endif
    }
    func persist() throws { try db.save(archive) }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func saveSettings() { perform { try persist() } }

    // MARK: 会员体系（登录 / 注册 / 兑换 / 校验；纯判定逻辑在 Core.swift）

    /// 服务器地址变更时同步到 LicenseService
    func enterGuestMode() {
        guard !licenseBusy, !busy, !running else { return }
        guestMode = true
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
                applyLicenseProfile(profile, validated: true)
            } catch {
                if LicenseService.isAuthError(error) {
                    KeychainStore.delete()
                    applyLicenseProfile(nil, validated: false)
                    step = "登录已过期，请重新登录"
                }
                // 网络等其他失败：保持 grace/expired 判定，不打扰用户
            }
        }
    }

    /// 统一落地档案：写 Settings + 重算 licenseState；expired 时首次自动跳会员中心（仅在路由不在 member 时设置，避免死循环）
    private func applyLicenseProfile(_ profile: MembershipProfile?, saveToken: String? = nil, validated: Bool) {
        if let saveToken { KeychainStore.save(saveToken); guestMode = false }
        settings.licenseProfile = profile
        settings.licenseLastValidated = validated ? Date() : nil
        licenseState = LicenseState.resolve(profile:profile,now:Date(),lastValidated:settings.licenseLastValidated)
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
                applyLicenseProfile(result.profile, saveToken: result.token, validated: true)
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
                if !loaded.isEmpty { licensePlans = loaded }
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
                if !loaded.isEmpty { licensePlans = loaded }
            } catch { licensePlans = PlanCatalog.fallback }
        }
    }

    static func dueText(_ profile: MembershipProfile) -> String {
        profile.paidUntil?.formatted(date:.abbreviated,time:.omitted) ?? profile.planLabel
    }

    /// 功能门禁：active/grace 放行；expired 引导到会员中心；loggedOut 提示登录。只挡新动作，不打断运行中的队列。
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
        saveSettings()
    }
    /// 草稿配图变动即时同步：把选中素材刷新到本空间未发送任务的附件快照，
    /// 删除/新增配图立即生效，无需再点保存并同步；保护条件与 LiveMessage.refreshed 一致
    func syncUnsentAssets(_ ids: [String], workspaceID: String? = nil) {
        perform {
            let spaceID = workspaceID ?? self.workspaceID
            guard let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == spaceID }) else { return }
            let resolved = ids.compactMap { id in assets.first { $0.id == id } }
            let resolvedIDs = resolved.map(\.id)
            settings.broadcastWorkspaces?[i].draft.assetIDs = resolvedIDs
            if let tid = settings.broadcastWorkspaces?[i].draft.selectedTemplateID,
               let t = settings.broadcastWorkspaces?[i].templates.firstIndex(where: { $0.id == tid }) {
                settings.broadcastWorkspaces?[i].templates[t].assetIDs = resolvedIDs
            }
            let spacePlanIDs = Set(plans.filter { ($0.workspaceID ?? "legacy") == spaceID }.map(\.id))
            var changed = false
            for d in deliveries.indices where spacePlanIDs.contains(deliveries[d].planID) {
                let job = deliveries[d]
                if (job.status == "queued" || job.canRequeue) && job.submittedAt == nil && job.evidence.isEmpty, job.assets != resolved {
                    deliveries[d].assets = resolved; changed = true
                }
            }
            for p in plans.indices where (plans[p].workspaceID ?? "legacy") == spaceID {
                if plans[p].assetIDs != resolvedIDs { plans[p].assetIDs = resolvedIDs; changed = true }
            }
            if changed { try persist() }
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
            try persist()
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
        let refreshed = LiveMessage.refreshed(archive)
        plans = refreshed.plans; deliveries = refreshed.deliveries
        do { try persist() } catch {
            settings = old.settings; plans = old.plans; deliveries = old.deliveries; throw error
        }
        step = "文案已保存，关联的未发送任务已同步"
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
        guard !busy, !importingList else { return }
        importingList = true; discoveredNames = []; importLog = []
        importProgress = "正在读取 QQ 会话列表…"
        task = Task {
            do {
                let names = try await driver.readSessionList()
                // 过滤掉已在名单里的
                let existing = Set(recipients.map(\.name))
                let fresh = names.filter { !existing.contains($0) }
                discoveredNames = fresh
                importProgress = fresh.isEmpty ? "QQ 会话里的群都已在本名单中" : "读到 \(fresh.count) 个候选群名，请勾选要录入的"
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
        guard !busy, !importingList, !names.isEmpty else { return }
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
            if !verified.isEmpty {
                perform { [weak self] in
                    guard let self else { return }
                    for name in verified where !self.recipients.contains(where: { $0.name == name }) {
                        self.recipients.append(Recipient(name: name, note: "QQ 导入 · 已检索验证", enabled: true, channel: SendChannel.qq))
                    }
                    try self.persist()
                    self.step = "已录入 \(verified.count) 个经检索验证的群"
                }
                orderChannel = SendChannel.qq // 让「发送顺序」立即切到 QQ，看到刚导入的群
            }
            importProgress = verified.isEmpty ? "没有通过验证的群名，未录入任何项" : "完成：录入 \(verified.count) 个，未通过 \(names.count - verified.count) 个"
            importingList = false
        }
    }

    func addRecipients(_ input: String, channel: String = SendChannel.qq) {
        perform {
            let lines = input.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw AppError("请输入群名或联系人名称，一行一个") }
            for line in lines where !recipients.contains(where:{$0.name == line}) { recipients.append(Recipient(name:line, note:"", enabled:true, channel:channel)) }
            try persist()
            orderChannel = channel // 添加后自动切到对应渠道的发送顺序，立即看到新群
            let label = channel == SendChannel.wechat ? "微信" : "QQ"
            step = "已加入 \(lines.count) 个\(label)目标；同名不重复添加"
        }
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
    func updatePlanInterval(_ planID: String, minutes: Int, lowerGlobal: Bool) {
        guard !busy else { error = "当前群正在处理，结束后即可应用间隔"; return }
        guard let i = plans.firstIndex(where: { $0.id == planID }) else { return }
        perform {
            let oldPlans = plans, oldJobs = deliveries; let oldSettings = settings
            let gap = lowerGlobal ? min(settings.globalGapMinutes, minutes) : settings.globalGapMinutes
            let preserveStart = plans[i].days > 1 || !plans[i].times.isEmpty || Scheduling.lastSendActivity(deliveries.filter { $0.planID == planID }) == nil
            let updated = try Scheduling.retimed(deliveries, planID: planID, minutes: minutes, now: Date(), globalGap: gap, preserveFutureStart: preserveStart)
            plans[i].intervalMinutes = minutes; plans[i].recipientGaps = nil
            deliveries = updated; settings.globalGapMinutes = gap
            do { try persist() } catch { plans = oldPlans; deliveries = oldJobs; settings = oldSettings; throw error }
            step = "已改为每\(minutes)分钟一群；待执行任务已重排，" + (running ? "队列继续运行" : "队列保持暂停")
        }
    }
    func cancelAllQueued(planIDs: Set<String>? = nil) {
        perform {
            var changed = 0
            for i in deliveries.indices where deliveries[i].status == "queued" && (planIDs == nil || planIDs!.contains(deliveries[i].planID)) {
                deliveries[i].status = "cancelled"; deliveries[i].detail = "用户批量取消，未发送"; deliveries[i].finished = Date(); changed += 1
            }
            guard changed > 0 else { throw AppError("当前没有待执行任务") }
            running = false; try persist()
            step = "已取消 \(changed) 条待执行任务，未发送任何消息"
        }
    }
    @discardableResult func importFiles(_ urls: [URL]) -> [String] {
        var imported: [String] = []
        perform {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let hash = try Database.digest(url)
                if let existing = assets.first(where:{$0.sha256 == hash && $0.name == url.lastPathComponent}) { imported.append(existing.id); continue }
                let asset = try db.importAsset(url); assets.append(asset)
                do { try persist() } catch { assets.removeAll{$0.id == asset.id}; throw error }
                imported.append(asset.id)
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
        let jobs = try Scheduling.expand(plan,recipients:recipients,assets:assets)
        for pair in zip(jobs,jobs.dropFirst()) {
            guard pair.1.scheduled.timeIntervalSince(pair.0.scheduled) >= Double(settings.globalGapMinutes * 60) - 1 else { throw AppError("部分群间隔小于全局最小间隔 \(settings.globalGapMinutes) 分钟，请调整") }
        }
        guard deliveries.count + jobs.count <= 10000 else { throw AppError("队列超过 10000 条，请缩短计划") }
        let duplicate = jobs.contains { job in deliveries.contains { old in old.status != "cancelled" && old.recipient == job.recipient && abs(old.scheduled.timeIntervalSince(job.scheduled)) < 60 } }
        guard !duplicate else { throw AppError("同一收件人在这个时间已有任务，请到发送记录查看，避免重复创建") }
        var plan = plan
        plan.textTemplateID = try saveTextTemplate(id: plan.textTemplateID, text: plan.text, workspaceID: plan.workspaceID, assetIDs: plan.assetIDs)
        if let i = settings.broadcastWorkspaces?.firstIndex(where: { $0.id == (plan.workspaceID ?? workspaceID) }) {
            settings.broadcastWorkspaces?[i].draft.selectedTemplateID = plan.textTemplateID
            settings.broadcastWorkspaces?[i].draft.text = plan.text
        }
        plans.append(plan); deliveries.append(contentsOf:jobs)
        do { try persist() } catch { plans.removeAll{$0.id == plan.id}; deliveries.removeAll{$0.planID == plan.id}; throw error }
        settings.savedText = plan.text; try persist(); route = "queue"; step = "已创建 \(jobs.count) 条任务；点击启动队列执行"
    }
    /// immediate=true（人工点启动）时第一条立即执行，后续按本次保存的间隔计时；
    /// immediate=false（创建并启动本计划）按计划里选定的开始时间执行。
    /// 无人值守时队列继续按时刻表与全局间隔运行。
    func start(planID: String? = nil, immediate: Bool = true) {
        guard guardMembership() else { return }   // 会员门禁：不打断运行中的队列，只挡新启动
        guard !busy else { return }
        guard QQDriver.trusted else { error = "辅助功能权限尚未生效，请到设置检查；任务保持待执行"; route = "settings"; return }
        if deliveries.contains(where:{["draft","uncertain","submitted"].contains($0.status)}) { error = "有待人工核对的任务，请先到发送记录处理，队列不会自动跳过"; route = "history"; return }
        if immediate, deliveries.contains(where: { $0.status == "queued" && (planID == nil || $0.planID == planID) }) {
            let previous = deliveries
            deliveries = Scheduling.restarted(deliveries, planID: planID, now: Date(), gap: settings.globalGapMinutes, intervalByPlan: intervalByPlan)
            do { try persist() } catch {
                deliveries = previous; self.error = error.localizedDescription; return
            }
            activePlanID = planID
            running = true
            guard let job = deliveries.filter({ $0.status == "queued" && (planID == nil || $0.planID == planID) })
                .min(by: { $0.scheduled < $1.scheduled }) else { return }
            step = "已启动：立即处理「\(job.recipient)」；下一群从本次实际发送起按当前间隔计时"
            execute(job)
            return
        }
        activePlanID = planID
        running = true
        step = planID == nil ? "全部待执行任务已启动，到时自动依次发送" : "本计划已启动，到时自动依次发送，无需逐条确认"
        tick()
    }
    func addAndStart(_ plan: Plan) throws {
        guard !busy && !running else { throw AppError("请先暂停当前队列，再启动新计划；或仅保存排期") }
        guard QQDriver.trusted else { throw AppError("请先到设置授权辅助功能，再创建并启动；也可以先仅保存排期") }
        guard !deliveries.contains(where:{["running","draft","uncertain","submitted"].contains($0.status)}) else { throw AppError("请先处理待核对记录，再启动新计划") }
        try addPlan(plan)
        start(planID:plan.id, immediate:false)   // 新计划按用户选定的开始时间，不提前
    }
    func stop() { running = false; driver.cancelled = true; wechatDriver.cancelled = true; task?.cancel(); step = "队列已暂停" }
    func sendSingle(_ id: String) {
        guard guardMembership() else { return }   // 会员门禁
        guard !busy, let index = deliveries.firstIndex(where:{$0.id == id && $0.status == "queued"}) else { return }
        guard !deliveries.contains(where:{["running","submitted","draft","uncertain"].contains($0.status)}) else { error = "请先处理待核对记录"; return }
        let last = Scheduling.lastSendActivity(deliveries) ?? .distantPast
        guard Date().timeIntervalSince(last) >= Double(settings.globalGapMinutes * 60) else { error = "尚未达到全局发送间隔，请等待后再执行"; return }
        // Explicit one-job action: retain the immutable message and recipient; never start the timer queue.
        let old = deliveries[index]
        running = false; deliveries[index].mode = "automatic"; deliveries[index].scheduled = Date()
        do { try persist() } catch { deliveries[index] = old; self.error = error.localizedDescription; return }
        execute(deliveries[index])
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
        guard !busy, !running, !importingList else {
            error = "请先暂停队列，并等待当前操作结束，再打开微信聊天"
            return
        }
        guard guardMembership() else { return }
        busy = true
        step = "正在定位微信聊天；发送由你手动完成"
        task = Task {
            defer { busy = false; task = nil }
            do {
                step = try await relationshipInbox.open(contactID: contactID, expectedSourceID: sourceID, queueBusy: false, navigator: relationshipNavigator)
            } catch { step = error.localizedDescription; self.error = step }
        }
    }

    func tryQQ(_ recipient: String? = nil, channel: String = SendChannel.qq) {
        guard guardMembership() else { return }   // 会员门禁
        guard !busy else { return }
        running = false; busy = true
        let isWeChat = channel == SendChannel.wechat
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
                diagnostic = step
            } catch { step = error.localizedDescription; diagnostic = step; self.error = step }
            busy = false; task = nil
        }
    }
    func tick() {
        guard running && !busy else { return }
        guard let job = Scheduling.eligible(deliveries,now:Date(),gap:settings.globalGapMinutes,planID:activePlanID,intervalByPlan:intervalByPlan) else {
            if let next = nextDelivery { step = timingExplanation(next) }
            else { running = false; step = "当前排期已完成或没有待执行任务" }
            return
        }
        // 错过时刻的任务不再冻结：按全局间隔顺延补发，节奏仍受间隔保护
        execute(job)
    }
    func execute(_ job: Delivery) {
        guard !busy, let i = deliveries.firstIndex(where:{$0.id == job.id && $0.status == "queued"}) else { return }
        let previousApp = NSWorkspace.shared.frontmostApplication
        busy = true; deliveries[i].status = "running"; deliveries[i].started = Date(); deliveries[i].detail = "处理前已写入数据库"
        do { try persist() } catch {
            deliveries[i].status = job.status; deliveries[i].started = job.started; deliveries[i].detail = job.detail
            self.error = "任务未能开始：\(error.localizedDescription)"; running = false; busy = false; return
        }
        let activeDriver = driverFor(job.channelName)
        activeDriver.beforeSubmit = { [weak self] in
            guard let self, let index = self.deliveries.firstIndex(where:{$0.id == job.id}) else { throw AppError("任务不存在") }
            self.deliveries[index].status = "submitted"; self.deliveries[index].detail = "发送按键前检查点；异常退出须人工核对"
            if self.deliveries[index].submittedAt == nil { self.deliveries[index].submittedAt = Date() }
            try self.persist()
        }
        task = Task {
            do {
                let result = try await activeDriver.run(job,root:db.root)
                mutate(job.id,status:result.0,detail:result.1)
                if result.0 != "verified" { running = false; route = "history" }
                step = "\(job.recipient)：\(result.0 == "verified" ? "界面核验通过" : "等待人工处理")"
                // Only restore after confirmed success, and never steal focus back if the user switched away.
                if result.0 == "verified", settings.restorePreviousApp ?? true,
                   !activeDriver.cancelled, !QQDriver.locked,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.qq",
                   let previousApp, !previousApp.isTerminated, previousApp.bundleIdentifier != "com.tencent.qq" {
                    _ = previousApp.activate(options:[])
                }
            } catch {
                let wasSubmitted = deliveries.first(where:{$0.id == job.id})?.status == "submitted"
                mutate(job.id,status:wasSubmitted ? "uncertain" : "blocked",detail:"步骤：\(step)\n\(error.localizedDescription)")
                running = false; step = "已暂停：\(error.localizedDescription)"
            }
            busy = false; task = nil
        }
    }
    /// 目标会话当前没有草稿时的一次性补草稿：按这条任务的原文与素材，另开一条“草稿模式”任务
    /// 把内容填进 QQ 输入框，但绝不触发发送；原来那条 blocked 记录（含 started）一字不改地保留。
    func prepareDraftCopy(_ id: String) {
        guard !busy else { error = "有任务正在处理，请等它结束"; return }
        guard let source = deliveries.first(where: { $0.id == id }) else { return }
        guard source.status == "blocked", source.submittedAt == nil, source.evidence.isEmpty else {
            error = "只有尚未提交的暂停任务可以另开草稿填充"; return
        }
        guard !source.text.isEmpty || !source.assets.isEmpty else { error = "这条任务没有内容"; return }
        guard !Scheduling.hasUnresolvedClone(of: source.id, in: deliveries) else {
            error = "这条任务已经有一张未处理完的草稿填充任务，请先在发送记录里核对它"; return
        }
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
        guard !busy else { error = "有任务正在处理，请等它结束"; return }
        guard confirmedRecipient, confirmedText, confirmedImage else {
            error = "请先逐项确认：收件群正确、正文与计划一致、图片已在草稿里"; return
        }
        guard let i = deliveries.firstIndex(where: { $0.id == id }) else { return }
        let job = deliveries[i]
        guard job.status == "blocked", job.submittedAt == nil, job.evidence.isEmpty else {
            error = "只有尚未提交的暂停任务可以按已核对草稿续发"; return
        }
        guard let qq = driverFor(job.channelName) as? QQDriver else {
            error = "这条任务不是 QQ 渠道，暂不支持按草稿续发"; return
        }
        busy = true
        deliveries[i].detail = "已按人工核对发起续发（未重新粘贴内容），结果待核验"
        do { try persist() } catch {
            deliveries[i] = job; busy = false
            self.error = "任务未能开始：\(error.localizedDescription)"; return
        }
        qq.beforeSubmit = { [weak self] in
            guard let self, let index = self.deliveries.firstIndex(where: { $0.id == job.id }) else { throw AppError("任务不存在") }
            self.deliveries[index].status = "submitted"
            self.deliveries[index].detail = "人工核对草稿后的发送按键前检查点；异常退出须人工核对"
            if self.deliveries[index].submittedAt == nil { self.deliveries[index].submittedAt = Date() }
            try self.persist()
        }
        step = "\(job.recipient)：按已核对草稿续发（只发一次）"
        task = Task {
            do {
                let result = try await qq.sendExistingDraft(job, root: db.root)
                mutate(job.id, status: result.0, detail: result.1)
                if result.0 != "verified" { running = false; route = "history" }
                step = "\(job.recipient)：\(result.0 == "verified" ? "界面核验通过" : "等待人工处理")"
            } catch {
                let wasSubmitted = deliveries.first(where: { $0.id == job.id })?.status == "submitted"
                mutate(job.id, status: wasSubmitted ? "uncertain" : "blocked", detail: "步骤：\(step)\n\(error.localizedDescription)")
                running = false
                step = "已暂停：\(error.localizedDescription)"
            }
            busy = false; task = nil
        }
    }

    func mutate(_ id: String, status: String, detail: String) {
        guard let i = deliveries.firstIndex(where:{$0.id == id}) else { return }
        deliveries[i].status = status; deliveries[i].detail = detail; deliveries[i].finished = Date()
        if status == "verified" { deliveries[i].evidence = detail }
        do { try persist() } catch { running = false; self.error = "状态保存失败：\(error.localizedDescription)。请核对 QQ，不要重发" }
    }
    func requeuePaused(_ ids: Set<String>) {
        guard !busy, guardMembership() else { return }
        let old = deliveries
        let count = deliveries.filter { ids.contains($0.id) && $0.canRequeue }.count
        guard count > 0 else { error = "这些任务可能已提交，请先核对发送记录"; return }
        deliveries = Scheduling.requeued(deliveries, ids: ids, now: Date(), gap: settings.globalGapMinutes)
        do { try persist(); step = "已将 \(count) 条暂停任务重新入队；点击启动 / 继续发送" }
        catch { deliveries = old; self.error = error.localizedDescription }
    }

    func appendRecipients(planID: String, ids: Set<String>) -> Bool {
        guard !busy, !running, guardMembership(), let index = plans.firstIndex(where: { $0.id == planID }) else { return false }
        let oldJobs = deliveries; let oldPlans = plans; let oldRecipients = recipients
        do {
            let chosen = recipients.filter { ids.contains($0.id) }
            let added = try Scheduling.additionalDeliveries(plan: plans[index], recipients: chosen, jobs: deliveries, now: Date(), gap: settings.globalGapMinutes)
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

    func reschedule(_ id: String) {
        guard !busy, let i = deliveries.firstIndex(where:{$0.id == id}), ["queued","blocked"].contains(deliveries[i].status) else { return }
        let last = Scheduling.lastSendActivity(deliveries) ?? .distantPast
        deliveries[i].scheduled = max(Date().addingTimeInterval(10),last.addingTimeInterval(Double(settings.globalGapMinutes * 60)))
        deliveries[i].status = "queued"; deliveries[i].detail = "人工重新排期；请确保上次未发且 QQ 草稿已处理"; deliveries[i].finished = nil
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
    func restoreBackup() {
        guard !busy else { error = "请先暂停并等待当前操作结束"; return }
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
            backup.deliveries = Scheduling.recovered(backup.deliveries)
            try db.save(backup)
            stop(); recipients = backup.recipients; assets = backup.assets; plans = backup.plans; deliveries = backup.deliveries; settings = backup.settings
            if settings.textTemplates == nil { settings.textTemplates = settings.savedText.isEmpty ? [] : [TextTemplate(text:settings.savedText)] }
            settings.prepareWorkspaces(recipientIDs: recipients.filter(\.enabled).map(\.id))
            // 恢复的备份可能来自旧版本或另一台机器：会员档案与服务器地址一并重新落地
            license.baseURL = LicenseService.normalize(settings.licenseServerURL)
            licenseState = LicenseState.resolve(profile:settings.licenseProfile,now:Date(),lastValidated:settings.licenseLastValidated)
            step = "备份已恢复，队列保持暂停；原数据库和素材保存在恢复前备份中"
        }
    }
}

// MARK: - 导航定义

struct NavItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    var summary: String {
        ["home":"今天的排期与进度", "recipients":"QQ群管理与微信手动维系", "compose":"选择群聊、编辑内容与时间", "assets":"保存要发送的图片与文件", "queue":"开始、暂停、重试发送", "history":"查看结果与失败原因", "member":"账号与套餐", "settings":"权限、发送间隔与备份"][id] ?? ""
    }
}

let navItems: [NavItem] = [
    NavItem(id: "home",       title: "总览",       symbol: "square.grid.2x2.fill"),
    NavItem(id: "compose",    title: "新建发送",   symbol: "square.and.pencil"),
    NavItem(id: "assets",     title: "素材库",     symbol: "photo.on.rectangle.angled"),
    NavItem(id: "recipients", title: "群与联系人", symbol: "person.2.fill"),
    NavItem(id: "queue",      title: "发送队列",   symbol: "calendar.badge.clock"),
    NavItem(id: "history",    title: "发送记录",   symbol: "clock.arrow.circlepath"),
    NavItem(id: "member",     title: "会员中心",   symbol: "crown.fill"),
    NavItem(id: "settings",   title: "设置与备份", symbol: "slider.horizontal.3")
]

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            // 未登录：整窗锁定为登录界面，不渲染主界面
            if store.licenseState == .loggedOut && !store.guestMode { LoginView() } else { mainPane }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .alert("需要处理",isPresented:Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
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
                    ForEach(["compose", "queue", "history", "recipients", "assets"], id: \.self) { id in
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
        case "queue": return store.queuedCount
        case "history": return store.attentionCount
        default: return nil
        }
    }

    private var statusCard: some View {
        DepthSurface(radius: 16, padding: 14, accent: store.running ? Theme.green : nil) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    PulseDot(color: store.running ? Theme.green : Theme.slate, active: store.running)
                    Text(store.running ? "队列运行中" : "队列已暂停")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(store.running ? Theme.green : .secondary)
                    Spacer()
                }
                if let next = store.nextDelivery, store.running {
                    CountdownText(target: store.earliestSendDate(next), prefix: "下一群", compact: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(membershipTint)
                    Text(store.membershipHint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if store.route != "member" {
                        Button("查看") { store.route = "member" }
                            .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(membershipTint)
                    }
                }
                Text("资料保存在此 Mac\n软件需保持运行，QQ 需登录并解锁")
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
        HStack(spacing: 14) {
            IconTile(symbol: navItems.first(where: { $0.id == store.route })?.symbol ?? "square.grid.2x2.fill",
                     size: 42, gradient: Theme.gradient(for: store.route))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color.primary, Color.primary.opacity(0.66)], startPoint: .top, endPoint: .bottom))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            LiveClock()
            if store.busy { ProgressView().controlSize(.small) }
            if store.running || store.busy {
                Button { store.stop() } label: { Label("暂停全部", systemImage: "pause.fill") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.orange))
            }
            if store.route != "compose" {
                Button { store.route = "compose" } label: { Label("新建发送", systemImage: "plus") }
                    .buttonStyle(DepthButtonStyle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footerBar: some View {
        HStack(spacing: 9) {
            Image(systemName: store.busy ? "arrow.triangle.2.circlepath" : "info.circle.fill")
                .foregroundStyle(store.busy ? Theme.blue : Theme.indigo)
            Text(store.step).font(.system(size: 11.5)).lineLimit(2)
            Spacer()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let dateText = context.date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
                Pill(text: dateText, tint: Theme.blue, symbol: "calendar", variant: .neutral)
            }
            Pill(text: "资料保存在本机", tint: Theme.slate, symbol: "internaldrive.fill", variant: .neutral)
            Pill(text: "\(store.recipients.count) 群 · \(store.assets.count) 素材", tint: Theme.pink, symbol: "tray.full.fill", variant: .neutral)
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

    private var title: String { ["home":"今天要发什么？", "compose":"新建发送", "assets":"你的素材，随时可用", "recipients":"群与联系人", "queue":"发送队列", "history":"每一次发送都有记录", "member":"会员与套餐", "settings":"连接、存储与备份"][store.route] ?? "新建发送" }
    private var subtitle: String {
        if store.route == "recipients", store.orderChannel == SendChannel.wechat { return "在关系回响筛选人物，打开微信聊天后手动发送。" }
        return ["home":"一屏看清排期、进度和下一次发送。", "compose":"先选择群聊，再准备内容，最后设置发送时间。", "assets":"导入后独立保存，原文件移动也不影响使用。", "recipients":"QQ 按名称搜索并打开第一条群聊结果。", "queue":"保存文案同步待发群聊；点击间隔设置调整发送节奏。", "history":"区分草稿、提交与核验，不确定的结果不自动重发。", "member":"套餐、续费与卡密兑换，随时掌握会员状态。", "settings":"不接管登录，不保存密码，所有数据留在本机。"][store.route] ?? "" }
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
        .buttonStyle(.plain)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                HStack(spacing: 14) {
                    StatTile(title: "待执行", value: store.queuedCount, symbol: "clock.fill", gradient: Theme.brand, tint: Theme.indigo)
                    StatTile(title: "已确认发送", value: store.verifiedCount, symbol: "checkmark.seal.fill", gradient: Theme.success, tint: Theme.green)
                    StatTile(title: "待人工处理", value: store.attentionCount, symbol: "exclamationmark.triangle.fill", gradient: Theme.warm, tint: Theme.amber)
                    StatTile(title: "素材", value: store.assets.count, symbol: "photo.stack.fill", gradient: Theme.cool, tint: Theme.teal)
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
                             trailing: store.todayDeliveries.isEmpty ? "今天空闲" : "按时间排列")
                TodayTimelineView(deliveries: store.deliveries, running: store.running, onRetry: { store.requeuePaused([$0]) }, retryEnabled: !store.busy)
            }
        }
    }

    private var heroCard: some View {
        let next = store.nextDelivery
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        PulseDot(color: .white, active: store.running)
                        Text(store.running ? "排期正在运行" : "排期已暂停")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                    }
                    Text(next == nil ? "当前没有待执行任务" : "下一群 · \(next!.recipient)")
                        .font(.system(size: 25, weight: .bold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if let next {
                        HStack(spacing: 8) {
                            Label("最早发送 " + store.earliestSendDate(next).formatted(date: .abbreviated, time: .standard), systemImage: "calendar")
                            Text("·")
                            Text(next.planName)
                        }
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    } else {
                        Text("到「新建发送」里编排一次发送，或从素材库开始。")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
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
                                        Text(store.running ? CountdownText.format(store.earliestSendDate(next).timeIntervalSince(context.date)) : "已暂停")
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
                if store.running {
                    Button { store.stop() } label: { Label("暂停全部", systemImage: "pause.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                } else {
                    Button { store.route = "queue" } label: { Label("查看待发队列", systemImage: "list.bullet") }
                        .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
                        .disabled(store.queuedCount == 0)
                        .opacity(store.queuedCount == 0 ? 0.5 : 1)
                }
                Button { store.route = "compose" } label: { Label("新建发送", systemImage: "plus.circle.fill") }
                    .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.18)], startPoint: .top, endPoint: .bottom), tint: .black))
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
        let planID = store.activePlanID ?? store.nextDelivery?.planID
        let jobs: [Delivery]
        if let planID {
            jobs = store.deliveries
                .filter { $0.planID == planID }
                .sorted { $0.scheduled < $1.scheduled }
        } else {
            jobs = []
        }
        return DispatchProgress3DCompact(
            segments: DispatchProgressMapper.segments(from: jobs, limit: jobs.count, running: store.running),
            doneCount: DispatchProgressMapper.doneCount(from: jobs),
            totalCount: jobs.count,
            queueRunning: store.running
        )
        .padding(.bottom, 6)
    }

    private var upcomingCard: some View {
        let upcoming = store.deliveries.filter { $0.status == "queued" }.sorted { $0.scheduled < $1.scheduled }.prefix(5)
        return DepthSurface(radius: 20, padding: 20, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "接下来", symbol: "list.bullet.rectangle.portrait.fill", tint: Theme.indigo, trailing: "\(store.queuedCount) 条")
                if upcoming.isEmpty {
                    EmptyPanel(title: "队列是空的", symbol: "calendar", message: "在「新建发送」中选择素材和收件人，预览后创建计划。", tint: Theme.indigo)
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
                actionRow("新建发送", "square.and.pencil", Theme.brandUp) { store.route = "compose" }
                actionRow("导入素材", "square.and.arrow.down.fill", Theme.cool) { _ = store.chooseFiles() }
                actionRow("备份数据库", "externaldrive.fill.badge.checkmark", Theme.success) { store.backup() }
                actionRow("QQ 连接检查", "link.circle.fill", Theme.steel) { store.diagnostic = store.driver.diagnostic() }
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
        .buttonStyle(.plain)
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
    static func label(for date: Date) -> String {
        let cal = Calendar.current
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
    @State private var mode = "automatic"
    @State private var previewData: PlanPreview?
    @State private var customGaps = false
    @State private var recipientGaps: [String:Int] = [:]
    @State private var addingRecipients = false
    @State private var newRecipients = ""
    @State private var addingChannel = SendChannel.qq
    @State private var deleteTemplateTarget: TextTemplate?
    private var selectedRecipients: [Recipient] { store.recipients.filter { recipients.contains($0.id) } }
    @State private var selectedTemplateID: String?
    @State private var showAdvanced = false
    @State private var initialized = false
    @State private var groupSearch = ""
    @State private var onlySelected = false
    @State private var showAllGroups = false
    @State private var showMessage = true
    @State private var showImporter = false
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
                scheduleSection
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
            }
            showImporter = pendingImport
        }
        .onChange(of: draftSnapshot) { _, draft in if initialized { store.saveDraft(draft, workspaceID: workspaceID) } }
        .onChange(of: assets) { _, _ in
            // 删除/新增配图立即同步到队列未发送任务，不必再点保存并同步
            guard initialized else { return }
            store.syncUnsentAssets(draftSnapshot.assetIDs, workspaceID: workspaceID)
        }
        .sheet(isPresented: $creatingWorkspace) {
            VStack(alignment: .leading, spacing: 18) {
                Text("新建群发空间").font(.title3.bold())
                Text("每个空间独立保存文案、所选群聊、素材与发送设置。新空间从空白开始。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("例如：活动通知、二手推广", text: $newWorkspaceName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("取消") { creatingWorkspace = false }
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
        .sheet(item:$previewData) { data in previewSheet(data) }
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
                                .buttonStyle(.plain)
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

    private var scheduleSection: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.blue) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    SectionLabel(title: "3 · 时间与间隔", symbol: "clock.fill", tint: Theme.blue)
                    Spacer()
                    DatePicker("开始",selection:$date,displayedComponents:multiRound ? [.date] : [.date,.hourAndMinute]).labelsHidden()
                    Menu {
                        Button("单轮") { multiRound = false; date = Date().addingTimeInterval(300) }
                        Button("早中晚 · 09 / 14 / 19 点") { applyTemplate("09:00,14:00,19:00") }
                        Button("全天四轮") { applyTemplate("00:00,06:00,12:00,18:00") }
                        Button("全天八轮") { applyTemplate("00:00,03:00,06:00,09:00,12:00,15:00,18:00,21:00") }
                    } label: { Label(multiRound ? "每天多轮" : "单轮",systemImage:"repeat") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet))
                }
                HStack(spacing: 10) {
                    if !multiRound {
                        Button("5分钟后") { date = Date().addingTimeInterval(300) }.buttonStyle(SoftButtonStyle(tint: Theme.blue))
                        Button("30分钟后") { date = Date().addingTimeInterval(1800) }.buttonStyle(SoftButtonStyle(tint: Theme.blue))
                    }
                    Spacer()
                    Text("每隔")
                    TextField("分钟", value: $interval, format: .number).textFieldStyle(.roundedBorder)
                        .frame(width: 65).accessibilityLabel("本次群间隔分钟数")
                    Text("分钟换一群")
                }.font(.system(size: 12))
                if interval < store.settings.globalGapMinutes {
                    HStack {
                        Text("当前最小间隔为 \(store.settings.globalGapMinutes) 分钟").font(.caption).foregroundStyle(Theme.orange)
                        Button("使用 \(store.settings.globalGapMinutes) 分钟") { interval = store.settings.globalGapMinutes }
                            .buttonStyle(SoftButtonStyle(tint: Theme.orange))
                        Spacer()
                    }
                }
                if !multiRound && date < Date() {
                    Text("开始时间已过去，可点击上方快捷时间重新安排。").font(.caption).foregroundStyle(Theme.orange)
                }
                compactSchedule
            }
        }
    }

    private var compactSchedule: some View {
        Group {
            switch scheduleResult {
            case .success(let jobs):
                if let first = jobs.first, let last = jobs.last {
                    HStack(spacing: 12) {
                        IconTile(symbol: "calendar.badge.clock", size: 30, gradient: Theme.warm)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("\(jobs.count) 条任务").font(.system(size: 14, weight: .bold))
                                Pill(text: Scheduling.duration(Int(last.scheduled.timeIntervalSince(first.scheduled)/60)), tint: Theme.cyan, symbol: "arrow.left.and.right", variant: .neutral)
                            }
                            Text("至 \(last.scheduled.formatted(.dateTime.month().day().hour().minute())) · 首条 \(first.scheduled.formatted(.dateTime.hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if first.scheduled > Date() { CountdownText(target: first.scheduled, prefix: "距首次", compact: true) }
                    }
                }
            case .failure(let error):
                HStack(spacing: 10) {
                    IconTile(symbol: "exclamationmark.triangle.fill", size: 28, gradient: Theme.warm)
                    Text(error.localizedDescription).font(.system(size: 12)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
    }

    // MARK: 收件人

    private var recipientsSection: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("1 · 选择群聊", systemImage: "person.2.fill").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Text("已选 \(recipients.count) / 共 \(store.recipients.count) 个群")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.violet)
                }
                Text("点击群名即可勾选或取消。这里只决定本次发送给谁，不会修改已有队列。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { selectRecipients(Set(store.recipients.map(\.id))) } label: {
                        Label("全选全部 \(store.recipients.count) 个群", systemImage: "checkmark.circle.fill")
                    }.buttonStyle(DepthButtonStyle())
                    Button("取消全选") { recipients.removeAll() }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Spacer()
                    Button { addingRecipients = true } label: { Label("导入群聊名称", systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet))
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
                    Text(store.recipients.isEmpty ? "添加群聊后即可选择" : recipients.count == store.recipients.count ? "已选择全部群聊" : "还有 \(store.recipients.count - recipients.count) 个群未选，可直接点击上方群名加入")
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
            .buttonStyle(.plain)

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
            if multiRound { TextField("轮次：09:00,14:00,19:00",text:$times).textFieldStyle(.roundedBorder) }
            Picker("执行方式",selection:$mode) { Text("自动发送").tag("automatic"); Text("仅填草稿").tag("draft") }.pickerStyle(.segmented)
            Text("自动发送时短暂使用 QQ 前台，成功后尽量切回原应用。").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 底部操作条

    private var bottomBar: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "tray.full.fill", size: 28, gradient: Theme.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(recipients.count == store.recipients.count ? "共 \(store.recipients.count) 群 · \(assets.count) 个附件" : "已选 \(recipients.count) / 共 \(store.recipients.count) 群 · \(assets.count) 个附件").font(.system(size: 12.5, weight: .semibold))
                Text(preparationIssue ?? (store.running || store.busy ? "当前队列运行中 · 可预览或仅保存" : "草稿已保存 · 可以预览或启动"))
                    .font(.system(size: 10.5)).foregroundStyle(preparationIssue == nil ? Theme.slate : Theme.orange).lineLimit(2)
            }
            Spacer()
            Button("仅保存") {
                store.perform { try store.addPlan(draftPlan()); store.route = "queue" }
            }.buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(preparationIssue != nil || store.busy)
            Button("预览内容与排期") { makePreview() }.buttonStyle(SoftButtonStyle(tint: Theme.indigo)).disabled(preparationIssue != nil)
            Button { startCurrent() } label: { Label("启动排期", systemImage: "play.fill") }
                .buttonStyle(DepthButtonStyle())
                .disabled(store.running || store.busy || preparationIssue != nil)
                .opacity(store.running || store.busy || preparationIssue != nil ? 0.45 : 1)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    private var firstScheduled: Date? {
        if case .success(let jobs) = scheduleResult { return jobs.first?.scheduled }
        return nil
    }

    // MARK: 弹窗

    private var addRecipientsSheet: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing: 12) {
                IconTile(symbol: "person.badge.plus", size: 38, gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入群聊名称").font(.title3.bold())
                    Text("每行一个完整群名（QQ 或微信），添加后自动选中").font(.caption).foregroundStyle(.secondary)
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
                    if store.error == nil { selectRecipients(Set(store.recipients.filter { names.contains($0.name) }.map(\.id))); newRecipients = ""; addingRecipients = false }
                }.buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), tint: Theme.violet))
                .disabled(newRecipients.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:580)
    }

    private func previewSheet(_ data: PlanPreview) -> some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing: 12) {
                IconTile(symbol: "checkmark.seal.fill", size: 38, gradient: Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("核对这次发送").font(.title3.bold())
                    Text("\(data.jobs.count) 条任务 · \(data.plan.mode == "draft" ? "草稿模式" : "自动发送") · \(data.plan.assetIDs.count) 个附件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let first = data.jobs.first?.scheduled, first > Date() { CountdownText(target: first, prefix: "距首次", compact: true) }
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
                Button("仅保存排期") { store.perform { try store.addPlan(data.plan); previewData = nil } }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                Button("创建并启动本计划") { store.perform { try store.addAndStart(data.plan); previewData = nil } }
                    .buttonStyle(DepthButtonStyle())
                    .disabled(store.busy || store.running)
                    .opacity(store.busy || store.running ? 0.45 : 1)
            }
        }.padding(24).frame(width:720,height:640)
    }

    // MARK: 逻辑

    private func startCurrent() {
        guard preparationIssue == nil else { store.error = preparationIssue; return }
        store.perform {
            _ = try scheduleResult.get()
            let plan = try draftPlan()
            try store.addAndStart(plan)
        }
    }
    private func applyTemplate(_ value: String) {
        times = value; multiRound = true; mode = "automatic"
        // 当天还有没过完的轮次就保留今天，避免点预设后日期被静默推到明天
        let today = Scheduling.calendar.startOfDay(for: Date())
        let slots = (try? Scheduling.times(value)) ?? []
        let hasUpcomingToday = slots.contains { slot in
            let parts = slot.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2,
                  let moment = Scheduling.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: today) else { return false }
            return moment > Date()
        }
        date = hasUpcomingToday ? today : Scheduling.calendar.date(byAdding:.day,value:1,to:today)!
    }
    private func selectRecipients(_ ids: Set<String>) {
        for index in store.recipients.indices where ids.contains(store.recipients[index].id) {
            store.recipients[index].enabled = true
        }
        recipients.formUnion(ids)
        store.saveSettings()
    }
    private func draftPlan() throws -> Plan {
        Plan(name:"【\(store.workspaceName)】" + (name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名计划" : name),text:text,assetIDs:store.assets.filter{assets.contains($0.id)}.map(\.id),recipientIDs:selectedRecipients.map(\.id),starts:date,days:days,times:multiRound ? try Scheduling.times(times) : [],intervalMinutes:interval,mode:mode,recipientGaps:customGaps ? recipientGaps : nil, workspaceID: workspaceID, textTemplateID: selectedTemplateID)
    }
    private var scheduleResult: Result<[Delivery],Error> {
        Result {
            let plan = try draftPlan()
            guard interval >= store.settings.globalGapMinutes else { throw AppError("统一间隔不得小于全局最小间隔 \(store.settings.globalGapMinutes) 分钟") }
            for id in plan.recipientIDs.dropFirst() { guard (plan.recipientGaps?[id] ?? interval) >= store.settings.globalGapMinutes else { throw AppError("逐群间隔不得小于全局最小间隔 \(store.settings.globalGapMinutes) 分钟") } }
            return try Scheduling.expand(plan,recipients:store.recipients,assets:store.assets)
        }
    }
    private func makePreview() {
        store.perform {
            _ = try scheduleResult.get()
            let plan = try draftPlan()
            previewData = PlanPreview(plan:plan,jobs:try Scheduling.expand(plan,recipients:store.recipients,assets:store.assets))
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
    var body: some View {
        if !assets.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment:.top,spacing:12) {
                    ForEach(assets) { asset in
                        VStack(spacing:5) {
                            AssetThumbnail(asset:asset).frame(width:110,height:96)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(asset.name).font(.caption).lineLimit(2).frame(width:110)
                            CopyButton(asset.isImage ? "复制图片" : "复制文件") { try ClipboardCopy.file(store.db.url(for:asset),isImage:asset.isImage) }
                        }
                    }
                }
            }.frame(height:180)
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
            .buttonStyle(.plain)
            .help("点击预览大图")
            VStack(alignment:.leading,spacing:7) {
                Button { renameTarget = a; renameText = a.name } label: {
                    Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .truncationMode(.middle)
                        .frame(height:34, alignment:.topLeading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            .help("点击预览")
            Button { renameTarget = a; renameText = a.name } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount:a.bytes,countStyle:.file)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

struct RelationshipInboxView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var inbox: RelationshipInbox
    @State private var search = ""
    @State private var selectedTag = ""

    var body: some View {
        Card(title: "来自关系回响", icon: "person.2.wave.2", tint: Theme.green) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在关系回响选择人物与标签；在这里打开聊天，由你手动发送。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(inbox.status).font(.system(size: 11))
                        .foregroundStyle(inbox.isStale ? Theme.orange : Theme.green)
                        .textSelection(.enabled)
                    if let notice = inbox.sourceNotice {
                        Text(notice).font(.system(size: 11)).foregroundStyle(Theme.orange)
                    }
                }
                Spacer(minLength: 8)
                Button { inbox.refresh() } label: { Label("刷新名单", systemImage: "arrow.clockwise") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.green))
            }
            HStack {
                TextField("搜索姓名、备注或标签", text: $search).textFieldStyle(.roundedBorder)
                Picker("标签", selection: $selectedTag) {
                    Text("全部标签").tag("")
                    ForEach(inbox.tags) { tag in Text(tag.name).tag(tag.id) }
                }.frame(width: 190)
            }
            if store.running || store.busy || store.importingList {
                Text("当前有队列或操作正在执行；暂停并等待结束后可打开聊天。")
                    .font(.system(size: 11)).foregroundStyle(Theme.orange)
            }
            if !store.wechatPermission {
                Text("打开聊天需要 QQ排程助手的辅助功能权限，可在“设置与备份”查看。")
                    .font(.system(size: 11)).foregroundStyle(Theme.orange)
            }
            let filtered = inbox.filtered(search: search, tagID: selectedTag.isEmpty ? nil : selectedTag)
            Text("显示 \(filtered.count) / \(inbox.contacts.count) 人 · 独立维系列表")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if inbox.contacts.isEmpty {
                Text(inbox.snapshot == nil ? "请先在关系回响点击“同步到微信维系列表”。" : "关系回响当前未选择同步联系人。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else if filtered.isEmpty {
                Text("没有匹配的联系人；筛选不会改变同步范围。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            LazyVStack(spacing: 10) {
                ForEach(filtered) { contact in
                    RelationshipInboxRow(inbox: inbox, contact: contact, sourceID: inbox.snapshot?.sourceInstanceId ?? "")
                        .id(inbox.key(for: contact.contactId))
                }
            }
        }
        .onChange(of: inbox.tags.map(\.id)) { _, ids in
            if !selectedTag.isEmpty && !ids.contains(selectedTag) { selectedTag = "" }
        }
    }
}

private struct RelationshipInboxRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var inbox: RelationshipInbox
    let contact: RelationshipContact
    let sourceID: String
    @State private var alias = ""
    @State private var aliasResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    if !contact.userNote.isEmpty {
                        Text(contact.userNote).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !contact.tags.isEmpty {
                        Text(contact.tags.map(\.name).joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Theme.green).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    store.openRelationshipContact(contact.contactId, sourceID: sourceID)
                } label: { Label("打开微信聊天", systemImage: "bubble.left.and.bubble.right") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.green))
                    .disabled(inbox.isStale || inbox.isOpening || store.running || store.busy || store.importingList || !store.wechatPermission)
                    .help("使用完整名称定位会话，保留已有草稿；请核对后手动发送")
            }
            if !contact.message.isEmpty {
                DisclosureGroup("参考文案\(contact.festival.isEmpty ? "" : " · " + contact.festival)") {
                    Text(contact.message).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }.font(.system(size: 12))
            }
            HStack {
                TextField("微信中显示的名称（可选）", text: $alias).textFieldStyle(.roundedBorder)
                Button("保存定位名称") {
                    do { try inbox.saveAlias(alias, contactID: contact.contactId); alias = inbox.alias(for: contact.contactId); aliasResult = "已保存，仅用于微信定位" }
                    catch { aliasResult = error.localizedDescription }
                }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                if !aliasResult.isEmpty { Text(aliasResult).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { alias = inbox.alias(for: contact.contactId) }
    }
}

/// 「已核对草稿，发送这条」：必须逐项勾选收件群 / 正文 / 图片三项确认，且只针对当前这一行任务。
struct VerifiedSendButton: View {
    @EnvironmentObject var store: Store
    let job: Delivery
    @State private var showing = false
    @State private var okRecipient = false
    @State private var okText = false
    @State private var okImage = false
    var body: some View {
        Button { showing = true } label: {
            Label("已核对草稿，发送这条", systemImage: "checkmark.seal.fill")
        }
        .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).disabled(store.busy)
        .sheet(isPresented: $showing) {
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
                    Spacer()
                    Button("发送这一条（仅一次）") {
                        showing = false
                        store.sendVerifiedDraft(job.id, confirmedRecipient: okRecipient, confirmedText: okText, confirmedImage: okImage)
                    }
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
    @State private var showing = false
    @State private var editedName = ""
    @State private var error = ""
    var body: some View {
        Button { editedName = name; error = ""; showing = true } label: {
            Label("修改群名", systemImage: "pencil")
        }
        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
        .disabled(store.busy || store.running)
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
                    Spacer()
                    Button("保存并同步") { save() }.buttonStyle(.borderedProminent)
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
                                .buttonStyle(.plain)
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
                    Picker("渠道", selection: $newChannel) {
                        Text("QQ").tag(SendChannel.qq)
                        Text("微信").tag(SendChannel.wechat)
                    }
                    .pickerStyle(.segmented).frame(width: 200)
                    Spacer()
                }
                Text("一行一个群聊名称；QQ 搜索后直接打开第一条群聊结果。").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("添加后会自动切到对应渠道的发送顺序。").font(.system(size: 11)).foregroundStyle(.secondary)
                TextEditor(text:$newNames).frame(height:76).scrollContentBackground(.hidden).padding(8)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                HStack { Spacer(); Button("添加到名单") { store.addRecipients(newNames, channel: newChannel); newNames = "" }
                    .buttonStyle(DepthButtonStyle(gradient: LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing), tint: Theme.violet)) }
            }
            Card(title:"发送顺序",icon:"list.number",tint: Theme.indigo) {
                TextField("搜索名单中的群名", text: $search).textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Picker("渠道", selection: $store.orderChannel) {
                        Text("QQ").tag(SendChannel.qq)
                        Text("微信").tag(SendChannel.wechat)
                    }
                    .pickerStyle(.segmented).frame(width: 200)
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

struct QueueView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    let history: Bool
    @State private var selected: Delivery?
    @State private var query = ""
    @State private var filter = "all"
    @State private var confirmCancelAll = false
    @State private var selectedPlanID = ""
    @State private var expansionPlan: Plan?
    @State private var intervalText = ""
    @State private var spaceFilter: String? = nil
    @State private var contentPreview = false
    private var scopedPlans: [Plan] { store.plans.filter { (spaceFilter ?? store.workspaceID).isEmpty || ($0.workspaceID ?? "legacy") == (spaceFilter ?? store.workspaceID) } }
    private var scopedJobs: [Delivery] { let ids = Set(scopedPlans.map(\.id)); return store.deliveries.filter { ids.contains($0.planID) } }
    private var queuedCount: Int { scopedJobs.filter { $0.status == "queued" }.count }
    private var verifiedCount: Int { scopedJobs.filter { ["verified", "manual"].contains($0.status) }.count }
    private var attentionCount: Int { scopedJobs.filter { ["draft", "uncertain", "blocked", "submitted"].contains($0.status) }.count }
    private var queuePlanID: String? {
        if scopedPlans.contains(where: { $0.id == selectedPlanID }) { return selectedPlanID }
        return scopedJobs.filter { $0.status == "queued" }.min(by: { $0.scheduled < $1.scheduled })?.planID ?? scopedPlans.max(by: { $0.created < $1.created })?.id
    }
    private var planJobs: [Delivery] { store.deliveries.filter { $0.planID == queuePlanID } }
    private var requestedInterval: Int? {
        intervalText.isEmpty ? scopedPlans.first(where: { $0.id == queuePlanID })?.intervalMinutes : Int(intervalText)
    }


    private var filters: [(String, String)] {
        history ? [("all","全部"),("verified","已核验"),("attention","待处理"),("cancelled","已取消")]
                : [("all","全部"),("queued","待执行"),("running","处理中"),("attention","待处理")]
    }

    private var jobs: [Delivery] {
        var base = scopedJobs.filter { history ? $0.status != "queued" : ["queued","running","submitted","blocked","draft","uncertain"].contains($0.status) }
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
        return base.sorted { history ? ($0.finished ?? $0.scheduled) > ($1.finished ?? $1.scheduled) : $0.scheduled < $1.scheduled }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:12) {
            if !history {
                queueControls; runningCard
            }
            HStack(spacing:14) {
                queueStat("待执行", value: queuedCount, symbol: "clock.fill", tint: Theme.indigo)
                queueStat("已确认发送", value: verifiedCount, symbol: "checkmark.seal.fill", tint: Theme.green)
                queueStat("待人工处理", value: attentionCount, symbol: "exclamationmark.triangle.fill", tint: Theme.amber)
                queueStat("累计任务", value: scopedJobs.count, symbol: "shippingbox.fill", tint: Theme.slate)
            }
            .padding(.horizontal, 22)
            scopeBar
            if showIntervalSettings { timingSummary }

            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("搜索群名或计划名",text:$query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Surface(scheme).card.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                .frame(maxWidth: 280)

                Picker("", selection: $filter) {
                    ForEach(filters, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: CGFloat(filters.count) * 82)

                Spacer()
                if !history && queuedCount > 0 {
                    Button { confirmCancelAll = true } label: { Label("取消当前范围待执行", systemImage: "xmark.circle") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                }
                Button { store.exportRecords() } label: { Label("导出记录", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
            }
            .padding(.horizontal, 22)

            if jobs.isEmpty {
                EmptyPanel(title: query.isEmpty && filter == "all" ? (history ? "还没有发送记录" : "队列是空的") : "没有匹配的任务",
                           symbol: history ? "clock" : "calendar",
                           message: query.isEmpty && filter == "all" ? "新建发送后，可在这里查看进度和结果。" : "清空搜索或切换到“全部”查看其他任务。",
                           tint: history ? Theme.green : Theme.indigo)
                    .padding(.top, 26)
            } else {
                    LazyVStack(spacing: 8) {
                        ForEach(jobs) { job in row(job) }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("核验指 QQ 客户端可见结果，不是服务器送达回执。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 22).padding(.bottom, 14)
                }.padding(.top, 14).frame(maxWidth: .infinity)
            }.scrollIndicators(.visible)
        }
        .alert("取消当前范围待执行任务？", isPresented: $confirmCancelAll) {
            Button("确认取消", role: .destructive) { store.cancelAllQueued(planIDs: Set(scopedPlans.map(\.id))) }
            Button("返回", role: .cancel) {}
        } message: {
            Text("将把 \(queuedCount) 条待执行任务标记为已取消，不会发送任何消息。此操作不影响已核验记录。")
        }
        .sheet(item:$selected) { original in detailSheet(original) }
        .sheet(item: $expansionPlan) { plan in ExpandQueuePlanView(planID: plan.id).environmentObject(store) }
        .sheet(isPresented: $contentPreview) { QueueContentPreviewSheet(planID: queuePlanID ?? "").environmentObject(store) }
        .onAppear { intervalText = String(scopedPlans.first(where: { $0.id == queuePlanID })?.intervalMinutes ?? store.settings.globalGapMinutes) }
        .onChange(of: queuePlanID) { _, _ in intervalText = String(scopedPlans.first(where: { $0.id == queuePlanID })?.intervalMinutes ?? store.settings.globalGapMinutes) }
    }

    private func queueStat(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(value)").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(tint)
        }.padding(12).background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: 12))
    }

    @State private var showIntervalSettings = false

    private var timingSummary: some View {
        let plan = scopedPlans.first { $0.id == queuePlanID }
        let proposed = Int(intervalText)
        let next = store.nextDelivery(planID: queuePlanID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label("间隔设置", systemImage: "timer").font(.headline)
                Picker("计划", selection: Binding(get: { queuePlanID ?? "" }, set: { selectedPlanID = $0 })) {
                    ForEach(scopedPlans) { plan in Text(plan.name).tag(plan.id) }
                }.labelsHidden().frame(maxWidth: 280)
                Spacer()
                Text(store.busy ? "当前群处理中 · 可编辑，结束后应用" : (store.running ? "运行中 · 可直接修改并应用" : "暂停中 · 可调整间隔"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("每").font(.system(size: 15, weight: .medium))
                TextField("分钟", text: $intervalText).textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                    .frame(width: 78).accessibilityLabel("发送间隔分钟数")
                Text("分钟发一个群").font(.system(size: 15, weight: .semibold))
                ForEach([5, 10, 30, 60], id: \.self) { value in
                    Button("\(value)") { intervalText = String(value) }
                        .buttonStyle(SoftButtonStyle(tint: proposed == value ? Theme.indigo : Theme.slate))
                        .help("设为\(value)分钟")
                }
                Spacer()
                Button("应用间隔") {
                    if let id = queuePlanID, let minutes = proposed { store.updatePlanInterval(id, minutes: minutes, lowerGlobal: true) }
                }.buttonStyle(DepthButtonStyle())
                    .disabled(store.busy || proposed == nil || !(1...1440).contains(proposed ?? 0) || next == nil)
            }.disabled(plan == nil)
            Text("当前全局最小间隔 \(store.settings.globalGapMinutes) 分钟 · 若设得更短，会同步降低最小间隔；当前计划待发群按新间隔重排")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("当前已保存：\(plan?.intervalMinutes ?? store.settings.globalGapMinutes) 分钟")
                Spacer()
                if let next { Text("下一群最早发送：\(store.earliestSendDate(next).formatted(date: .abbreviated, time: .standard))") }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).background(Surface(scheme).card, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 22).padding(.vertical, 6)
        .background(Surface(scheme).page)
    }

    private var queueControls: some View {
        HStack(spacing: 10) {
            Button {
                if let id = queuePlanID, let minutes = requestedInterval,
                   (1...1440).contains(minutes),
                   let saved = store.plans.first(where: { $0.id == id }),
                   saved.intervalMinutes != minutes || store.settings.globalGapMinutes > minutes {
                    store.updatePlanInterval(id, minutes: minutes, lowerGlobal: true)
                    guard store.plans.first(where: { $0.id == id })?.intervalMinutes == minutes,
                          store.settings.globalGapMinutes <= minutes else { return }
                }
                store.start(planID: queuePlanID)
            } label: { Label("立即开始", systemImage: "play.fill") }
                .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                .disabled(store.busy || store.running || !planJobs.contains(where: { $0.status == "queued" }) || !(1...1440).contains(requestedInterval ?? 0))
                .help("首群立即发送；后续从实际发送时间起按当前间隔计时")
            Button { store.start(planID: queuePlanID, immediate: false) } label: { Label("按排期启动", systemImage: "calendar.badge.clock") }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                .disabled(store.busy || store.running || !planJobs.contains(where: { $0.status == "queued" }))
                .help("保留原定发送时间；已过期的任务按间隔顺延处理")
            Button { store.requeuePaused(Set(planJobs.filter(\.canRequeue).map(\.id))) } label: {
                Label("重试暂停（\(planJobs.filter(\.canRequeue).count)）", systemImage: "arrow.clockwise")
            }.buttonStyle(SoftButtonStyle(tint: Theme.orange)).disabled(store.busy || !planJobs.contains(where: \.canRequeue))
            Button { expansionPlan = scopedPlans.first { $0.id == queuePlanID } } label: { Label("添加群聊", systemImage: "person.2.badge.plus") }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).disabled(store.busy || store.running || queuePlanID == nil)
            Button { contentPreview = true } label: { Label("内容预览", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(SoftButtonStyle(tint: Theme.blue)).disabled(queuePlanID == nil)
                .help("查看本计划将发送的文字、图片、链接与文件（只读）")
            Spacer()
            Text("本计划 \(planJobs.count) 条任务").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 22)
    }

    /// 群发空间 / 计划选择器与间隔入口：压缩成小尺寸后移到列表上方，
    /// 替代原先独占一整行的顶部选择区，消除顶部大片留白。
    private var scopeBar: some View {
        HStack(spacing: 10) {
            Picker("群发空间", selection: Binding(get: { spaceFilter ?? store.workspaceID }, set: { spaceFilter = $0; selectedPlanID = "" })) {
                Text("全部空间").tag("")
                ForEach(store.workspaces) { space in Text(space.name).tag(space.id) }
            }
            .controlSize(.small).frame(maxWidth: 190)
            if !history {
                Picker("计划", selection: Binding(get: { queuePlanID ?? "" }, set: { selectedPlanID = $0 })) {
                    ForEach(scopedPlans) { plan in Text(plan.name).tag(plan.id) }
                }
                .controlSize(.small).frame(maxWidth: 250)
                Button { showIntervalSettings.toggle() } label: { Label("间隔设置", systemImage: "timer") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    .accessibilityLabel(showIntervalSettings ? "收起间隔设置" : "间隔设置")
                Text("每 \(scopedPlans.first { $0.id == queuePlanID }?.intervalMinutes ?? store.settings.globalGapMinutes) 分钟 / 群")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
    }

    private var progressBlock: some View {
        let planID = queuePlanID
        let jobs: [Delivery]
        if let planID {
            jobs = store.deliveries
                .filter { $0.planID == planID }
                .sorted { $0.scheduled < $1.scheduled }
        } else {
            jobs = []
        }
        return DispatchProgress3D(
            segments: DispatchProgressMapper.segments(from: jobs, limit: jobs.count, running: store.running),
            doneCount: DispatchProgressMapper.doneCount(from: jobs),
            totalCount: jobs.count,
            queueRunning: store.running,
            onRetry: { store.requeuePaused([$0]) }, retryEnabled: !store.busy
        )
        .padding(.top, 8)
    }

    private var runningCard: some View {
        DepthSurface(radius: 18, padding: 14, accent: store.running ? Theme.green : nil) {
            if let next = store.nextDelivery(planID: queuePlanID) {
                HStack(spacing: 14) {
                    IconTile(symbol: store.running ? "paperplane.fill" : "pause.fill", size: 42,
                             gradient: store.running ? Theme.success : Theme.steel)
                    VStack(alignment:.leading,spacing:5) {
                        Text("下一群：\(next.recipient)").font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text("最早发送 \(store.earliestSendDate(next).formatted(date:.abbreviated,time:.standard)) · \(next.planName)")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if store.running && !store.busy && (store.activePlanID == nil || store.activePlanID == next.planID) {
                        CountdownText(target: store.earliestSendDate(next), prefix: "距发送")
                    }

                }
                Text(store.timingExplanation(next))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 8)
                progressBlock
            } else {
                HStack(spacing: 14) {
                    IconTile(symbol: "checkmark.circle.fill", size: 42, gradient: Theme.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前没有待执行排期").font(.system(size: 15, weight: .bold))
                        Text("可点击已暂停任务重新入队，或添加群到本计划。").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                progressBlock
            }
        }
        .padding(.horizontal, 22)
    }

    private func row(_ job: Delivery) -> some View {
        return HStack(alignment:.top,spacing:13) {
            VStack(spacing: 2) {
                Text(job.scheduled,format:.dateTime.month().day().hour().minute())
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(RelativeDay.label(for: job.scheduled)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)

            IconTile(symbol: StatusStyle.symbol(job.status), size: 30, gradient: StatusStyle.gradient(job.status))

            VStack(alignment:.leading,spacing:4) {
                HStack(spacing: 7) {
                    // layoutPriority 让群名始终截断显示而不是被溢出的按钮盖住
                    Text(job.recipient).font(.system(size: 13.5, weight: .medium)).lineLimit(1).layoutPriority(1)
                    Pill(status: job.status, name: job.statusName)
                    Pill(mode: job.mode)
                }
                Text("\(job.planName) · \(job.assets.count) 个附件").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if job.status != "queued" {
                    HStack {
                CopyButton("复制群名") { try ClipboardCopy.text(job.recipient) }
                CopyButton("复制详情") { try ClipboardCopy.text(job.detail) }.disabled(job.detail.isEmpty)
                CopyButton("复制文案") { try ClipboardCopy.text(job.text) }.disabled(job.text.isEmpty)
            }
            Text(job.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if job.canRenameRecipient { RenameRecipientButton(name: job.recipient, deliveryID: job.id) }
                if job.canRequeue {
                    Button { store.requeuePaused([job.id]) } label: { Label("重新入队", systemImage: "arrow.clockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.orange)).disabled(store.busy)
                    if job.assets.contains(where: \.isImage) {
                        Button { store.prepareDraftCopy(job.id) } label: { Label("按任务重填草稿（不发送）", systemImage: "doc.badge.plus") }
                            .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).disabled(store.busy)
                        VerifiedSendButton(job: job)
                    }
                }
                Button("详情") { selected = job }.buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                if job.status == "queued" || job.status == "blocked" {
                    Button("取消") { store.mutate(job.id,status:"cancelled",detail:"用户取消，未继续发送") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose)).disabled(store.busy)
                }
            }
        }
        .padding(12)
        .background(Surface(scheme).card.opacity(0.88), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 17)
                .fill(StatusStyle.gradient(job.status)).frame(width: 3.5)
        }
        .shadow(color: Surface(scheme).shadowSoft, radius: 6, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func detailSheet(_ original: Delivery) -> some View {
        let job = store.deliveries.first(where:{$0.id == original.id}) ?? original
        return VStack(alignment:.leading,spacing:15) {
            HStack(spacing: 12) {
                IconTile(symbol: StatusStyle.symbol(job.status), size: 40, gradient: StatusStyle.gradient(job.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.recipient).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    HStack(spacing: 6) {
                        ChannelPill(channel: job.channelName, compact: true)
                        Pill(status: job.status, name: job.statusName)
                        Pill(mode: job.mode, text: job.mode == "draft" ? "草稿模式" : "自动发送")
                    }
                }
                Spacer()
            }
            HStack {
                if job.canRenameRecipient { RenameRecipientButton(name: job.recipient, deliveryID: job.id) }
                CopyButton("复制群名") { try ClipboardCopy.text(job.recipient) }
                CopyButton("复制详情") { try ClipboardCopy.text(job.detail) }.disabled(job.detail.isEmpty)
                CopyButton("复制文案") { try ClipboardCopy.text(job.text) }.disabled(job.text.isEmpty)
            }
            Text(job.detail).font(.system(size: 12)).textSelection(.enabled)
                .padding(11)
                .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            ScrollView { VStack(alignment:.leading,spacing:12) {
                AttachmentStrip(assets:job.assets)
                Text(job.text).textSelection(.enabled).font(.system(size: 12.5))
            }.frame(maxWidth:.infinity,alignment:.leading) }.frame(minHeight:170)
            Text("任务 ID：\(job.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            if job.status == "queued" {
                Button("现在自动发送此条（不启动其他任务）") { selected = nil; store.sendSingle(job.id) }
                    .buttonStyle(DepthButtonStyle()).disabled(store.busy)
            }
            if ["draft","uncertain","submitted","blocked"].contains(job.status) {
                Text("先在 QQ 查看实际消息。下面的按钮只更改本地记录，不会再发送。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Button("我已核对，消息已发送") { store.mutate(job.id,status:"manual",detail:"用户在 QQ 核对后标记已发送"); selected = nil }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green)).disabled(store.busy)
                    Button("取消此条，不再发送") { store.mutate(job.id,status:"cancelled",detail:"用户取消，或消息撤回后不再重发"); selected = nil }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose)).disabled(store.busy)
                }
            }
            HStack {
                Button("关闭") { selected = nil }.buttonStyle(SoftButtonStyle(tint: Theme.slate))
                Spacer()
                if ["queued","blocked"].contains(job.status) {
                    Button("确认未发且草稿已清空，重新排期") { store.reschedule(job.id); selected = nil }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo)).disabled(store.busy)
                }
            }
        }.padding(24).frame(width:720,height:600)
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
        let jobs = store.deliveries.filter { $0.planID == planID }.sorted { $0.scheduled < $1.scheduled }
        return jobs.first { $0.status == "queued" } ?? jobs.first
    }
    private var links: [URL] {
        guard let job, !job.text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(job.text.startIndex..., in: job.text)
        return detector.matches(in: job.text, range: range).compactMap { $0.url }
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
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var dataSizeText: String = "计算中…"
    @State private var dataBreakdown: [(String, Int64)] = []
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
                        .buttonStyle(DepthButtonStyle(gradient: Theme.cool, tint: Theme.teal)).disabled(store.busy || !store.qqPermission)
                        .opacity(store.qqPermission ? 1 : 0.45)
                    Button { QQDriver.requestPermission() } label: { Label("授权辅助功能", systemImage: "lock.shield.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } label: { Label("系统权限设置", systemImage: "gearshape.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Button { store.diagnostic = store.driver.diagnostic() } label: { Label("只读检查 QQ", systemImage: "stethoscope") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.violet)).disabled(store.busy)
                }
                if !store.qqPermission {
                    Text("从旧版升级后，请在系统设置关闭再开启 QQ排程助手的开关。仍未生效时，移除旧条目，再添加下方显示的当前应用；返回软件会立即检查，必要时退出后重开。")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange)
                }
                Text("当前应用：\(Bundle.main.bundlePath)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("先到「群与联系人」点击群名旁的「试跑定位」，观看打开 QQ → 搜索名称 → 进入会话。要试填图文，请在「新建发送」选择图片、文字和单个群，使用草稿模式；自动发送模式才会提交消息。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(store.diagnostic).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(13)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                Text("支持中文 QQ 界面。QQ 升级、布局变化或额外确认窗口可能需要人工接管。建议先用测试群的草稿模式验收；自动模式按 Return 提交，请把 QQ 的发送快捷键设为 Enter。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title:"微信客户端连接",icon:"link",tint: Theme.wechat) {
                HStack(spacing: 10) {
                    PermissionLight(granted: store.wechatPermission, label: "微信辅助功能")
                    Spacer()
                    Button { store.refreshPermissions() } label: { Label("重新检查", systemImage: "arrow.clockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate)).disabled(store.busy)
                }
                Text("使用已登录的 macOS 微信。定位与发送核验依赖微信辅助功能控件，个别版本可能读不全——届时任务会停在「已提交 · 待核验」等你确认，不会盲发。")
                    .font(.system(size: 12.5))
                HStack(spacing: 9) {
                    Button { store.tryQQ(channel: SendChannel.wechat) } label: { Label("启动微信", systemImage: "arrow.up.forward.app.fill") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green)).disabled(store.busy || !store.wechatPermission)
                        .opacity(store.wechatPermission ? 1 : 0.45)
                    Button { WeChatDriver.requestPermission() } label: { Label("授权辅助功能", systemImage: "lock.shield.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.green))
                    Button { store.diagnostic = store.wechatDriver.diagnostic() } label: { Label("只读检查微信", systemImage: "stethoscope") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.green)).disabled(store.busy)
                    Spacer()
                }
                if !store.wechatPermission {
                    Text("QQ 和微信共用本软件的辅助功能权限。授权后返回软件会立即检查；若系统已开启但仍未授权，请关闭再开启本软件的开关，必要时退出后重开。")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange)
                }
                Text("先到「群与联系人」用渠道切换到微信，添加目标后点「试跑定位」：打开微信 → 搜索名称 → 进入会话，不发送任何消息。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(store.diagnostic).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(13)
                    .background(Surface(scheme).inset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
            }
            Card(title:"排程行为",icon:"timer",tint: Theme.amber) {
                Toggle("发送成功后尽量切回原应用",isOn:Binding(get:{store.settings.restorePreviousApp ?? true},set:{store.settings.restorePreviousApp = $0; store.saveSettings()})).toggleStyle(.switch)
                Text("只在 QQ 仍为前台且发送已核验时恢复；如果你已切换窗口，则不抢回焦点。QQ 掉线后仍需手动登录，软件不保存登录凭据。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Stepper("全局最小发送间隔：\(store.settings.globalGapMinutes) 分钟",value:$store.settings.globalGapMinutes,in:1...1440)
                    .onChange(of:store.settings.globalGapMinutes) { _,_ in store.saveSettings() }
                Text("所有计划共用间隔，逐个处理。运行排期期间阻止空闲系统休眠，不绕过锁屏、合盖或手动睡眠。错过时间的任务按发送间隔顺延，不集中连发。发送时自动唤起 QQ；被切换到其他窗口、已有草稿或结果不确定时暂停。退出程序不再调度；重新打开默认暂停，需要手动启动。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text("关闭主窗口后程序仍在菜单栏运行；彻底停止请点「暂停全部」或退出软件。").font(.system(size: 11)).foregroundStyle(.secondary)
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
                HStack(spacing: 9) {
                    Button { NSWorkspace.shared.open(store.db.root) } label: { Label("打开数据文件夹", systemImage: "folder.fill") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([store.db.root]) } label: { Label("在访达中显示", systemImage: "magnifyingglass") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.slate))
                    Button { store.backup() } label: { Label("备份数据库与素材", systemImage: "externaldrive.fill.badge.checkmark") }
                        .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                    Button { store.restoreBackup() } label: { Label("恢复备份", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.amber)).disabled(store.busy)
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

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
}
#if !RENDER_HARNESS
@main
struct QQDispatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: Store
    @State private var showShortcuts = false
    init() {
        do {
            let root = ProcessInfo.processInfo.environment["QQ_DISPATCH_DATA_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("QQ排程助手")
            let model = try Store(root:root)
            _store = StateObject(wrappedValue:model)
        } catch {
            let alert = NSAlert(); alert.messageText = "QQ排程助手无法启动"; alert.informativeText = error.localizedDescription; alert.runModal(); exit(1)
        }
    }
    var body: some Scene {
        WindowGroup("QQ排程助手",id:"main") { RootView().environmentObject(store).environment(\.timeZone,TimeZone(identifier:"Asia/Shanghai")!).tint(.indigo)
            .sheet(isPresented: $showShortcuts) { ShortcutHelpView() }
            .onOpenURL { url in _ = store.handleRelationshipURL(url) }
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
                    Button("启动队列") { store.start() }.keyboardShortcut("r",modifiers:.command)
                    Button("暂停全部") { store.stop() }.keyboardShortcut(".",modifiers:.command)
                    Button("导入素材") { store.chooseFiles() }.keyboardShortcut("i",modifiers:.command)
                }
            }
        MenuBarExtra("QQ排程助手",systemImage:store.running ? "paperplane.fill" : "paperplane") {
            MenuContent().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开 QQ排程助手") { openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }
            .keyboardShortcut("o", modifiers: .command)
        Divider()
        MenuTodaySection()
        Divider()
        HStack(spacing: 8) {
            Text(store.running ? "队列运行中" : "队列已暂停")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(store.running ? Theme.green : .secondary)
            Spacer()
            Text("待执行 \(store.queuedCount) 条")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if let next = store.nextDelivery {
            Text("下一群：\(next.recipient) · 最早 \(store.earliestSendDate(next).formatted(date:.omitted,time:.standard))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Divider()
        Button("暂停全部") { store.stop() }.disabled(!store.running)
        Button("退出") { store.stop(); NSApp.terminate(nil) }
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
            ("⌘R", "启动队列"),
            ("⌘.", "暂停全部"),
            ("⌘I", "导入素材")
        ]),
        ("其他", [
            ("⌘?", "显示此速查")
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
                Button("清空选择") { selectedIDs = [] }
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
