import SwiftUI

// 会员体系界面：登录/注册（未登录整窗锁定）与会员中心（路由 "member"）。
// 复用 Theme 组件，错误统一走 store.error 的 alert。

// MARK: - 登录 / 注册

struct LoginView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var mode = 0          // 0 登录 / 1 注册
    @State private var account = ""
    @State private var password = ""
    @State private var passwordAgain = ""

    private var isRegister: Bool { mode == 1 }
    private var canSubmit: Bool {
        !account.trimmingCharacters(in:.whitespaces).isEmpty && !password.isEmpty &&
        (!isRegister || password == passwordAgain)
    }

    var body: some View {
        ZStack {
            // 品牌渐变背景 + 装饰光斑
            LinearGradient(colors: [Theme.blue, Theme.indigo, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Circle().fill(.white.opacity(0.10)).frame(width: 460, height: 460).blur(radius: 80).offset(x: 320, y: -180)
                    Circle().fill(.black.opacity(0.16)).frame(width: 380, height: 380).blur(radius: 90).offset(x: -300, y: 260)
                }
                .ignoresSafeArea()
            ScrollView {
                VStack {
                    Spacer(minLength: 40)
                    card
                    Spacer(minLength: 24)
                    Text("本软件数据全部留在本机；账号仅用于会员核验。")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var card: some View {
        DepthSurface(radius: 26, padding: 30, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    IconTile(symbol: "paperplane.fill", size: 54, gradient: Theme.brand)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QQ 排程助手").font(.system(size: 21, weight: .bold))
                        Text("LOCAL DISPATCH").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.indigo.opacity(0.85)).tracking(1.4)
                    }
                    Spacer()
                }
                Text(isRegister ? "创建账号，免费试用 3 天" : "登录后继续使用")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)

                Picker("", selection: $mode) {
                    Text("登录").tag(0)
                    Text("注册").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                VStack(alignment: .leading, spacing: 9) {
                    fieldLabel("账号")
                    TextField("手机号、邮箱或自定义账号", text: $account)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    fieldLabel("密码")
                    SecureField("至少 6 位", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit { submit() }
                    if isRegister {
                        fieldLabel("确认密码")
                        SecureField("再输入一次密码", text: $passwordAgain)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit { submit() }
                    }
                }

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if store.licenseBusy { ProgressView().controlSize(.small).tint(.white) }
                        Text(isRegister ? "注册并领取 3 天试用" : "登录")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(DepthButtonStyle())
                .disabled(store.licenseBusy || !canSubmit)
                .opacity(store.licenseBusy || !canSubmit ? 0.55 : 1)

                Button { store.enterGuestMode() } label: {
                    Label("跳过登录，以游客身份体验", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                .disabled(store.licenseBusy || store.busy)
                Text("无需注册，可体验本地排程功能。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("新注册用户免费试用 3 天；本软件数据全部留在本机。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: 430)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func submit() {
        guard !store.licenseBusy else { return }
        let trimmed = account.trimmingCharacters(in:.whitespacesAndNewlines)
        if isRegister {
            guard password.count >= 6 else { store.error = "密码至少 6 位"; return }
            guard password == passwordAgain else { store.error = "两次输入的密码不一致"; return }
            store.register(account: trimmed, password: password)
        } else {
            store.login(account: trimmed, password: password)
        }
    }
}

// MARK: - 会员中心

struct MembershipView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var redeemCode = ""
    @State private var confirmLogout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if store.guestMode {
                    Card(title: "游客体验", icon: "person.crop.circle", tint: Theme.indigo) {
                        Text("当前以游客身份使用本地功能，资料保存在这台 Mac。")
                        Text("登录或注册后可使用账号与会员服务；现有资料会保留。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button { store.returnToLogin() } label: {
                            Label("登录 / 注册", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                        .disabled(store.busy)
                    }
                    plansCard
                } else {
                    statusCard
                    plansCard
                    redeemCard
                    accountCard
                }
            }
            .padding(22)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task { store.loadLicensePlans() }
        .confirmationDialog("确定退出登录？退出后核心功能将锁定，需要重新登录；本机数据与发送队列不受影响。",
                            isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { store.logout() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        Card(title:"会员状态",icon:"crown.fill",tint: Theme.amber) {
            switch store.licenseState {
            case .active(let profile): profileRows(profile)
            case .grace(let profile):
                profileRows(profile)
                stateNote("服务器暂时不可达，正在宽限期内；恢复联网后自动核验。", tint: Theme.amber, symbol: "wifi.slash")
            case .expired(let profile):
                if let profile { profileRows(profile) }
                stateNote("会员已过期，核心功能已锁定。购买或兑换卡密后立即恢复。", tint: Theme.rose, symbol: "exclamationmark.triangle.fill")
            case .loggedOut:
                Text("未登录").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func profileRows(_ profile: MembershipProfile) -> some View {
        HStack(spacing: 10) {
            rowLabel("账号")
            Text(profile.account).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            Spacer()
            Pill(text: profile.isTrial ? "试用" : "正式", tint: profile.isTrial ? Theme.teal : Theme.amber, symbol: profile.isTrial ? "leaf.fill" : "crown.fill")
        }
        HStack(spacing: 10) {
            rowLabel("当前套餐")
            Text(profile.planLabel).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        HStack(spacing: 10) {
            rowLabel("到期时间")
            if let until = profile.paidUntil {
                Text(until.formatted(date: .long, time: .omitted)).font(.system(size: 13, weight: .semibold))
                if until > Date() {
                    Pill(text: "剩 \(max(1, Int(ceil(until.timeIntervalSinceNow / 86400)))) 天", tint: Theme.green, symbol: "hourglass")
                } else {
                    Text("已到期").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.rose)
                }
            } else {
                Text("—").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
    }

    private func stateNote(_ text: String, tint: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.24 : 0.12), tint.opacity(scheme == .dark ? 0.10 : 0.05)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.14 : 0.45), tint.opacity(0.14)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
        )
    }

    // MARK: 套餐价格卡

    private var plansCard: some View {
        Card(title:"会员套餐",icon:"gift.fill",tint: Theme.indigo) {
            if store.licensePlans.isEmpty {
                EmptyPanel(title: "暂无套餐", symbol: "gift", message: "会员服务器未返回套餐，可到设置页检查服务器地址。", tint: Theme.indigo)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(store.licensePlans.prefix(3))) { plan in
                        PlanCard(plan: plan)
                    }
                }
            }
            Text(store.guestMode ? "登录或注册后，可使用购买的卡密开通会员。" : "购买卡密后在下方兑换；未到期续费会从原到期日顺延。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: 卡密兑换

    private var redeemCard: some View {
        Card(title:"卡密兑换",icon:"ticket",tint: Theme.teal) {
            HStack(spacing: 10) {
                TextField("输入卡密，例如 QP-M-XXXX-XXXX", text: $redeemCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { submitRedeem() }
                Button { submitRedeem() } label: {
                    HStack(spacing: 6) {
                        if store.licenseBusy { ProgressView().controlSize(.small).tint(.white) }
                        Label("兑换", systemImage: "checkmark.gobackward")
                    }
                }
                .buttonStyle(DepthButtonStyle(gradient: Theme.success, tint: Theme.green))
                .disabled(store.licenseBusy || redeemCode.trimmingCharacters(in:.whitespaces).isEmpty)
                .opacity(store.licenseBusy || redeemCode.trimmingCharacters(in:.whitespaces).isEmpty ? 0.5 : 1)
            }
            Text("卡密可向售卖渠道购买后在此兑换；一次一码，兑换成功立即刷新会员状态。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func submitRedeem() {
        guard !store.licenseBusy else { return }
        store.redeem(code: redeemCode)
        redeemCode = ""
    }

    // MARK: 账号与退出

    private var accountCard: some View {
        Card(title:"账号",icon:"person.crop.circle",tint: Theme.slate) {
            HStack(spacing: 10) {
                Text("退出后需要重新登录才能使用核心功能；本机数据、排期与发送记录全部保留。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button { confirmLogout = true } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                    .disabled(store.licenseBusy)
            }
        }
    }
}

// MARK: - 单档价格卡

struct PlanCard: View {
    let plan: PlanInfo
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DepthSurface(radius: 18, padding: 16, hoverable: true, accent: Theme.amber) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(plan.name).font(.system(size: 14, weight: .bold))
                    Spacer()
                    Pill(text: "\(plan.days) 天", tint: Theme.amber, symbol: "calendar")
                }
                Text(plan.priceDisplay)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                    .monospacedDigit()
                Text(plan.tagline).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
        }
    }
}
