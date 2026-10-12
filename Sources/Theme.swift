import SwiftUI
import AppKit
import AudioToolbox

// MARK: - 配色板
// 所有颜色都是显式 RGB，避免依赖语义色在明暗两种外观下走形。
enum Theme {
    static let indigo = Color(red: 0.35, green: 0.30, blue: 0.96)
    static let violet = Color(red: 0.58, green: 0.29, blue: 0.96)
    static let blue   = Color(red: 0.18, green: 0.50, blue: 0.98)
    static let cyan   = Color(red: 0.09, green: 0.67, blue: 0.89)
    static let teal   = Color(red: 0.07, green: 0.72, blue: 0.63)
    static let green  = Color(red: 0.16, green: 0.76, blue: 0.42)
    static let amber  = Color(red: 0.98, green: 0.66, blue: 0.14)
    static let orange = Color(red: 0.97, green: 0.45, blue: 0.14)
    static let rose   = Color(red: 0.95, green: 0.27, blue: 0.45)
    static let pink   = Color(red: 0.93, green: 0.31, blue: 0.68)
    static let slate  = Color(red: 0.40, green: 0.44, blue: 0.53)
    static let wechat = Color(red: 0.03, green: 0.76, blue: 0.38)   // 微信绿 #07C160

    static let brand   = LinearGradient(colors: [blue, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandUp = LinearGradient(colors: [violet, indigo], startPoint: .top, endPoint: .bottom)
    static let cool    = LinearGradient(colors: [cyan, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warm    = LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let danger  = LinearGradient(colors: [rose, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let success = LinearGradient(colors: [teal, green], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let steel   = LinearGradient(colors: [slate, slate.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func gradient(for key: String) -> LinearGradient {
        switch key {
        case "home":       return brand
        case "compose":    return brandUp
        case "assets":     return cool
        case "recipients": return LinearGradient(colors: [Theme.violet, Theme.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "queue":      return warm
        case "schedule":   return LinearGradient(colors: [Theme.blue, Theme.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "progress":   return success
        case "history":    return success
        case "member":     return LinearGradient(colors: [Theme.amber, Theme.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "settings":   return steel
        default:           return brand
        }
    }
}

// MARK: - 明暗自适应表面
struct Surface {
    let scheme: ColorScheme
    init(_ scheme: ColorScheme) { self.scheme = scheme }
    var dark: Bool { scheme == .dark }

    /// 页面底色
    var page: Color { dark ? Color(red: 0.075, green: 0.080, blue: 0.098) : Color(red: 0.949, green: 0.953, blue: 0.968) }
    /// 卡片主面
    var card: Color { dark ? Color(red: 0.137, green: 0.145, blue: 0.170) : .white }
    /// 次级面（内嵌区块）
    var inset: Color { dark ? Color(red: 0.098, green: 0.105, blue: 0.128) : Color(red: 0.965, green: 0.968, blue: 0.980) }
    /// 顶部高光
    var highlight: Color { dark ? Color.white.opacity(0.085) : Color.white.opacity(0.95) }
    /// 底部暗边
    var edge: Color { dark ? Color.white.opacity(0.075) : Color.black.opacity(0.075) }
    /// 投影
    var shadow: Color { dark ? Color.black.opacity(0.60) : Color(red: 0.16, green: 0.19, blue: 0.34).opacity(0.16) }
    var shadowSoft: Color { dark ? Color.black.opacity(0.40) : Color(red: 0.16, green: 0.19, blue: 0.34).opacity(0.10) }
    /// 分隔线
    var hairline: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
}

/// 立体卡片的通用外壳。内容在底层，视觉全部通过 background/overlay 叠出层次。
struct DepthSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 22
    var padding: CGFloat = 20
    var hoverable: Bool = false
    var accent: Color? = nil
    var inset: Bool = false
    @ViewBuilder var content: Content
    @State private var hovering = false

    private var s: Surface { Surface(scheme) }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        // 必须显式套一层 VStack：SwiftUI 会把修饰符逐个作用到多子视图闭包的每个子视图上，
        // 那样一次调用会画出多张卡片。
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    // 面本身留一点透明度，让页面底色透上来，卡片更"透"不闷
                    .fill((inset ? s.inset : s.card).opacity(dark ? 0.92 : 0.86))
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [s.highlight.opacity(inset ? 0.5 : 1), Color.white.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                    }
                    // 悬停不再放大阴影半径：半径动画每帧重渲染模糊层。抬起感交给缩放+位移。
                    .shadow(color: s.shadowSoft, radius: 10, x: 0, y: 6)
                    .shadow(color: s.shadow.opacity(0.7), radius: 1.5, x: 0, y: 1)
            }
            .overlay {
                // 边缘只留"上亮下淡"的一圈反光：有立体感但没有硬边界
                shape.strokeBorder(
                    LinearGradient(
                        colors: [accent?.opacity(0.30) ?? s.highlight.opacity(0.8), accent?.opacity(0.06) ?? s.edge.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .scaleEffect(hovering && hoverable ? 1.012 : 1)
            .offset(y: hovering && hoverable ? -3 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.80), value: hovering)
            .onHover { if hoverable { hovering = $0 } }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

// MARK: - 兼容旧调用点的卡片
struct Card<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = Theme.indigo
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DepthSurface(radius: 24, padding: 20, accent: tint) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    IconTile(symbol: icon, size: 28, gradient: LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(title).font(.headline)
                    Spacer()
                }
                content
            }
        }
    }
}

// MARK: - 3D 渐变图标块
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 40
    var gradient: LinearGradient = Theme.brand
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
        shape
            .fill(gradient)
            .overlay {
                // 顶部内高光，制造向上受光的面
                shape.fill(
                    LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.02)], startPoint: .top, endPoint: .center)
                )
                .blendMode(.softLight)
                .allowsHitTesting(false)
            }
            .overlay { shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.7) }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 1)
            }
            .frame(width: size, height: size)
            .shadow(color: Theme.indigo.opacity(scheme == .dark ? 0.55 : 0.28), radius: size * 0.26, x: 0, y: size * 0.13)
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.10), radius: 1.5, x: 0, y: 1)
    }
}

// MARK: - 小标签
// 软玻璃 3D 质感：半透明渐变填充 + 顶部受光的弱描边 + 同色柔光投影。
// 「类别」靠形态区分，「个体」靠颜色 + 图标区分，两者叠加后同一行里任意两个标签都不会重样：
//   .tinted   彩色玻璃（渠道 / 状态 / 会员等强语义标签）
//   .neutral  中性玻璃 + 彩色图标（模式 / 附件 / 容量等元信息标签）
//   .emphasis 实心渐变 + 白字（下一群 / 需关注等需要跳出来的提示）
struct Pill: View {
    enum Variant { case tinted, neutral, emphasis }

    let text: String
    var tint: Color = Theme.indigo
    var symbol: String? = nil
    var variant: Variant = .tinted
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var capsule: Capsule { Capsule(style: .continuous) }

    var body: some View {
        HStack(spacing: compact ? 3.5 : 4.5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 8.5 : 9, weight: .bold))
                    .foregroundStyle(iconColor)
                    .shadow(color: iconGlow, radius: 1.2, x: 0, y: 0.5)
            }
            Text(text)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, compact ? 6.5 : 8.5)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background {
            capsule
                .fill(fill)
                .overlay {
                    // 顶部内高光：圆润的立体感来自这层柔光，而不是硬描边
                    capsule.fill(
                        LinearGradient(colors: [highlightTop, Color.white.opacity(0)],
                                       startPoint: .top, endPoint: .center)
                    )
                    .allowsHitTesting(false)
                }
                .shadow(color: glow, radius: compact ? 2.5 : 3.5, x: 0, y: compact ? 1 : 1.5)
        }
        .overlay {
            // 上亮下暗的渐变细描边：只留一点边缘反光，边界不再发硬
            capsule.strokeBorder(border, lineWidth: 0.7)
        }
        .fixedSize()
    }

    private var fill: LinearGradient {
        switch variant {
        case .tinted:
            return LinearGradient(colors: [tint.opacity(dark ? 0.30 : 0.15), tint.opacity(dark ? 0.14 : 0.06)],
                                  startPoint: .top, endPoint: .bottom)
        case .neutral:
            return LinearGradient(colors: [Color.primary.opacity(dark ? 0.12 : 0.05), Color.primary.opacity(dark ? 0.05 : 0.02)],
                                  startPoint: .top, endPoint: .bottom)
        case .emphasis:
            return LinearGradient(colors: [tint.opacity(0.96), tint.opacity(0.76)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var highlightTop: Color {
        switch variant {
        case .tinted:  return Color.white.opacity(dark ? 0.10 : 0.40)
        case .neutral: return Color.white.opacity(dark ? 0.08 : 0.50)
        case .emphasis: return Color.white.opacity(0.30)
        }
    }

    private var border: LinearGradient {
        switch variant {
        case .tinted:
            return LinearGradient(colors: [Color.white.opacity(dark ? 0.16 : 0.50), tint.opacity(dark ? 0.12 : 0.18)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .neutral:
            return LinearGradient(colors: [Color.white.opacity(dark ? 0.12 : 0.60), Color.primary.opacity(dark ? 0.08 : 0.06)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .emphasis:
            return LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var textColor: Color {
        switch variant {
        case .tinted:  return tint
        case .neutral: return Color.primary.opacity(dark ? 0.80 : 0.65)
        case .emphasis: return Color.white
        }
    }

    private var iconColor: Color {
        switch variant {
        case .tinted:  return tint
        case .neutral: return tint
        case .emphasis: return Color.white
        }
    }

    private var iconGlow: Color {
        variant == .emphasis ? Color.black.opacity(0.25) : tint.opacity(0.35)
    }

    private var glow: Color {
        switch variant {
        case .tinted:  return tint.opacity(dark ? 0.22 : 0.14)
        case .neutral: return tint.opacity(dark ? 0.14 : 0.10)
        case .emphasis: return tint.opacity(dark ? 0.40 : 0.28)
        }
    }
}

// MARK: - 标签语义映射
// 每类标签固定「颜色 + 图标」配对：颜色负责远看区分，图标负责近看确认。
// 状态色见 StatusStyle；这里只补渠道 / 模式 / 启停这几类高频并排出现的标签。
enum TagStyle {
    static func channel(_ channel: String) -> (tint: Color, symbol: String) {
        channel == SendChannel.wechat ? (Theme.wechat, "person.2.fill") : (Theme.blue, "bubble.left.fill")
    }
    static func mode(_ mode: String) -> (tint: Color, symbol: String) {
        mode == "draft" ? (Theme.amber, "square.and.pencil") : (Theme.teal, "bolt.fill")
    }
    static func enabled(_ on: Bool) -> (tint: Color, symbol: String) {
        on ? (Theme.green, "checkmark.circle.fill") : (Theme.slate, "slash.circle")
    }
}

extension Pill {
    /// 状态标签：颜色与图标都取自 StatusStyle，保证每种状态独一无二。
    init(status: String, name: String, compact: Bool = false) {
        self.init(text: name, tint: StatusStyle.color(status), symbol: StatusStyle.symbol(status), compact: compact)
    }
    /// 执行方式标签：元信息类，用中性玻璃 + 彩色图标，与状态标签区分开。
    init(mode: String, text: String? = nil, compact: Bool = false) {
        let style = TagStyle.mode(mode)
        // draft 模式标签带「模式」后缀：状态词表已把 draft 状态统一叫「未发送」，
        // 行内状态胶囊旁再出现一枚「草稿」会被当成重复标签（走查 2026-10-06）。
        self.init(text: text ?? (mode == "draft" ? "草稿模式" : "自动发送"),
                  tint: style.tint, symbol: style.symbol, variant: .neutral, compact: compact)
    }
}

// MARK: - 可折叠分区（自绘，避免系统 DisclosureGroup 过高且样式不统一）
struct CollapsibleSection<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.indigo
    var badge: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DepthSurface(radius: 24, padding: 15, accent: tint) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: 24, height: 24)
                            .background(tint.opacity(scheme == .dark ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(title).font(.system(size: 13, weight: .semibold))
                        if let badge { Pill(text: badge, tint: tint, symbol: "tag.fill", variant: .neutral) }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(GhostPressButtonStyle())
                .quietHover(lift: 2, scale: 1)
                .accessibilityLabel(expanded ? "收起\(title)" : "展开\(title)")

                if expanded {
                    VStack(alignment: .leading, spacing: 12) { content }
                        .padding(.top, 14)
                        .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - 渐变主视觉上的半透明胶囊
struct GlassPill: View {
    let text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.8))
    }
}

// MARK: - 进度环
struct ProgressRing: View {
    var progress: Double
    var size: CGFloat = 46
    var line: CGFloat = 5
    var gradient: LinearGradient = Theme.brand
    var track: Color = Color.primary.opacity(0.09)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(gradient, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 统计磁贴
struct StatTile: View {
    let title: String
    let value: Int
    var symbol: String
    var gradient: LinearGradient
    var tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        DepthSurface(radius: 18, padding: 16, hoverable: true, accent: tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconTile(symbol: symbol, size: 30, gradient: gradient)
                    Spacer(minLength: 4)
                    Text("\(value)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(gradient)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 点击反馈（音效 + 触感 + 涟漪）
// 三层职责：
//   ClickFX.play  唯一的发声入口，自带 55ms 去重，样式层和全局兜底监听同时命中也只响一声。
//   RippleLayer   按钮自己画的涟漪+压感高光，顺带在按下那一刻触发 play，覆盖所有套用了它的样式。
//   installGlobalListener  只兜底 SwiftUI 自绘样式够不到的真实 AppKit 控件（开关、步进器、菜单）；
//                 命中视图名字里没有控件类名就不响，点在空白处不会发声。
enum ClickFX {
    static let soundKey = "clickFXSoundEnabled"
    static let motionKey = "clickFXMotionEnabled"

    enum Kind: Hashable {
        case tap
        case toggle

        // 实测本机时长：Tink 0.56s、Bottle 0.77s，都是能在连点里保持颗粒感的短音。
        var soundName: String { self == .tap ? "Tink" : "Bottle" }
    }

    static var soundEnabled: Bool { flag(ClickFX.soundKey) }
    static var motionEnabled: Bool { flag(ClickFX.motionKey) }

    private static func flag(_ key: String) -> Bool {
        // 用 object(forKey:) 区分「没存过」和「存了 false」，否则默认开会变成默认关。
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    private static var soundIDs: [Kind: SystemSoundID] = [:]
    private static var lastPlayedAt: TimeInterval = 0
    private static var monitor: Any?

    static func play(_ kind: Kind = .tap) {
        let now = ProcessInfo.processInfo.systemUptime
        // 一次按下会同时命中样式层和全局兜底监听；55ms 既挡住双响，也不至于让连点糊成一片。
        guard now - lastPlayedAt > 0.055 else { return }
        lastPlayedAt = now
        if soundEnabled { sound(kind) }
        // macOS 没有「设备是否可感知」的查询 API，系统会在无 Force Touch 等设备上自行抑制。
        guard motionEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// 卡顿的元凶是 stop()：实测 NSSound 和 AVAudioPlayer 每次 stop()+play() 都要 ~20ms
    /// （音频引擎停机，与类无关），一次点击吃掉一整个 60fps 帧，而且正好卡在涟漪起步那几帧。
    /// AudioServices 是系统给「短提示音」准备的 API：交给系统音频服务混音，实测平均 0.39ms，
    /// 不用池、不用 stop、音量跟随系统「提醒」音量。代价是不能再单独压音量。
    private static func sound(_ kind: Kind) {
        let id = soundID(for: kind)
        guard id != 0 else { return }
        AudioServicesPlayAlertSound(id)
    }

    private static var deniedSoundID: SystemSoundID = 0

    /// 点在禁用按钮上的「拒绝」反馈。Basso 是系统通用的「不行」提示音（0.77s），
    /// 与 tap/toggle 的 Tink/Bottle 一耳就能区分；同样走 AudioServices，不进点击热路径的池子。
    static func denied() {
        guard soundEnabled else { return }
        if deniedSoundID == 0, let url = soundFile("Basso") { AudioServicesCreateSystemSoundID(url as CFURL, &deniedSoundID) }
        guard deniedSoundID != 0 else { return }
        AudioServicesPlayAlertSound(deniedSoundID)
    }

    private static func soundFile(_ name: String) -> URL? {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        return ["aiff", "aif", "caf", "wav"].lazy.compactMap { ext in
            let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }.first
    }

    static func installGlobalListener() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let kind = ClickFX.controlKind(for: event) { play(kind) }
            return event
        }
    }

    /// 首声实测 5.4ms（创建 SystemSoundID 的一次性开销），挪到启动时预创建，点击路径上就不再有这一下。
    static func warmUp() {
        // 返回值刻意不用：这里要的就是「把 id 存进缓存」这个副作用。
        for kind in [Kind.tap, .toggle] { _ = soundID(for: kind) }
        if deniedSoundID == 0, let url = soundFile("Basso") { AudioServicesCreateSystemSoundID(url as CFURL, &deniedSoundID) }
    }

    private static func soundID(for kind: Kind) -> SystemSoundID {
        if let cached = soundIDs[kind] { return cached }
        var id: SystemSoundID = 0
        if let url = soundFile(kind.soundName) { AudioServicesCreateSystemSoundID(url as CFURL, &id) }
        soundIDs[kind] = id
        return id
    }

    /// 命中视图的类名里找真实控件。SwiftUI 自绘的 Button 命中到的只是 NSHostingView，
    /// 这里刻意放过它——否则点空白处也会响；那些按钮由 RippleLayer 自己发声。
    /// 实测类名：Toggle(.switch)=PlatformSwitch、Stepper=EditTrackingStepper、
    /// Menu/Picker=SwiftUIPopupButton、NSAlert/NSMenu 里的项=NSButton/NSMenuItemView。
    private static func controlKind(for event: NSEvent) -> Kind? {
        guard let content = event.window?.contentView else { return nil }
        guard let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return nil }
        var view: NSView? = hit
        var depth = 0
        while let current = view, depth < 6 {
            let name = String(describing: type(of: current))
            if name.contains("Switch") || name.contains("Stepper") || name.contains("Slider")
                || name.contains("Checkbox") || name.contains("RadioButton") || name.contains("Incrementor") {
                return .toggle
            }
            if name.contains("Button") || name.contains("Popup") || name.contains("PopUp")
                || name.contains("ComboBox") || name.contains("Segmented") || name.contains("Menu") {
                return .tap
            }
            view = current.superview
            depth += 1
        }
        return nil
    }
}

/// 涟漪本体：progress 0→1 画一圈从中心扩散并淡出的圆盘。
/// 单独拆出来是为了能直接喂一个固定 progress 做离屏取证——离屏窗口没有显示刷新驱动，
/// withAnimation 拿不到中间帧。
struct RippleDisc: View {
    var progress: CGFloat
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            // 取对角线刚好盖住四个角；用 1.45×长边在宽按钮上会画出一个面积翻倍的巨圆。
            let side = (geo.size.width * geo.size.width + geo.size.height * geo.size.height).squareRoot()
            Circle()
                .fill(color)
                .frame(width: side, height: side)
                .scaleEffect(progress)
                // 必须是 progress 的纯线性式：写成 progress<1 ? … : 0 会让动画两端都取到 0，
                // 涟漪就再也不扩散出来了。静止时 scale 为 0，圆本身没有面积。
                .opacity((1 - progress) * 0.45)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// 按下瞬间的涟漪 + 按住时常亮的压感高光。
/// 放在按钮自己的 background 闭包里，所以能被按钮圆角裁住，sheet / popover 里的按钮同样生效。
struct RippleLayer: View {
    static let duration: TimeInterval = 0.42

    var pressed: Bool
    var color: Color = .white
    var radius: CGFloat = 14
    var kind: ClickFX.Kind = .tap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            color.opacity(pressed ? 0.17 : 0)
            RippleDisc(progress: progress, color: color)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .allowsHitTesting(false)
        .animation(.easeOut(duration: pressed ? 0.08 : 0.22), value: pressed)
        .onChange(of: pressed) { _, down in
            guard down else { return }
            ClickFX.play(kind)
            restart()
        }
    }

    private func restart() {
        guard !reduceMotion, ClickFX.motionEnabled else { return }
        progress = 0
        // 同一轮里先归零再动画会被合并成一次赋值，推到下一个 runloop 才真的从中心扩出来。
        DispatchQueue.main.async { withAnimation(.easeOut(duration: Self.duration)) { progress = 1 } }
    }
}

/// 无边框按钮的点击反馈。外观与 .plain 一致（只画 label），额外补上涟漪和发声，
/// 用来替换散落在各页的 .buttonStyle(.plain) / .borderless。
struct GhostPressButtonStyle: ButtonStyle {
    var tint: Color = Theme.indigo
    var radius: CGFloat = 10
    var kind: ClickFX.Kind = .tap

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RippleLayer(pressed: configuration.isPressed, color: tint, radius: radius, kind: kind))
            .modifier(GhostPressScale(pressed: configuration.isPressed))
    }
}

private struct GhostPressScale: ViewModifier {
    var pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let active = pressed && isEnabled && !reduceMotion
        content
            .scaleEffect(active ? 0.975 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.72), value: active)
    }
}

// MARK: - 禁用也要有反应（gateDisabled）
// 裸 .disabled() 的问题：样式层不画禁用态，点了毫无反应，用户只会觉得「卡死了」。
// 这里统一三件事：视觉压暗（一眼看出点不动）＋ 拒绝音（Basso，与正常点击音明显不同）
// ＋ 底部提示条（用一句话说明「为什么现在点不了、该怎么办」）。动作语义不变：仍不会触发。
@MainActor
final class DeniedFeedback: ObservableObject {
    static let shared = DeniedFeedback()
    @Published var message: String?
    private var clearTask: Task<Void, Never>?

    func fire(_ hint: String) {
        ClickFX.denied()
        clearTask?.cancel()
        message = hint
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

struct GateDisabled: ViewModifier {
    let blocked: Bool
    var hint: String

    func body(content: Content) -> some View {
        content
            .opacity(blocked ? 0.45 : 1)
            .saturation(blocked ? 0.35 : 1)
            .accessibilityHint(blocked ? hint : "")
            .disabled(blocked)
            .overlay {
                // overlay 在 disabled 环境之外，点在压暗按钮上仍能收到手势，给拒绝反馈
                if blocked {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { DeniedFeedback.shared.fire(hint) }
                        .accessibilityHidden(true)
                }
            }
    }
}

/// 底部居中的拒绝提示条，挂在 RootView 上，由 DeniedFeedback 驱动。
struct DeniedToast: View {
    @ObservedObject private var feedback = DeniedFeedback.shared

    var body: some View {
        Group {
            if let message = feedback.message {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold))
                    Text(message).font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15).padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: feedback.message)
    }
}

// MARK: - 3D 按钮样式
struct DepthButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.brand
    var tint: Color = Theme.indigo
    var compact: Bool = false
    /// 前景色逃生口（默认仍是白字）。亮色底（琥珀 Theme.warm / Theme.success）上白字对比只有约
    /// 1.9:1，达不到 WCAG AA；QueuePlainButtonStyle 早有 tintForeground，这里补齐同一能力（5-16）。
    /// 由调用方按底色显式选择，样式层不擅自改全局按钮配色。
    var foreground: Color? = nil
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))
            .foregroundStyle(foreground ?? Color.white)
            .padding(.horizontal, compact ? 12 : 17)
            .padding(.vertical, compact ? 6.5 : 9)
            .background {
                shape
                    .fill(gradient)
                    .overlay {
                        shape.fill(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top, endPoint: .center))
                            .allowsHitTesting(false)
                    }
                    .overlay { shape.strokeBorder(.white.opacity(0.20), lineWidth: 0.7) }
                    .overlay {
                        RippleLayer(pressed: configuration.isPressed,
                                    color: .white, radius: compact ? 12 : 15)
                    }
                    // 按下不再改阴影半径：半径一变整层高斯模糊重渲染，正好落在动画起步帧上；
                    // 按压深度交给缩放和下移（见 FunctionalButtonHover），阴影保持恒定。
                    .shadow(color: tint.opacity(scheme == .dark ? 0.55 : 0.34), radius: 9, x: 0, y: 5)
                    .shadow(color: .black.opacity(0.10), radius: 1, x: 0, y: 1)
            }
            .contentShape(shape)
            .modifier(FunctionalButtonHover(
                pressed: configuration.isPressed,
                pressedScale: 0.965,
                pressedOffset: 1,
                lift: 3,
                hoverScale: 1.016,
                pressDamping: 0.7
            ))
    }
}

/// 次级（描边玻璃）按钮
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.indigo
    @Environment(\.colorScheme) private var scheme
    @Environment(\.font) private var inheritedFont

    func makeBody(configuration: Configuration) -> some View {
        let s = Surface(scheme)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            // 磅值交给调用方（大字号下才会变），字重留在这里，否则默认档会变细。
            .font((inheritedFont ?? .system(size: 13)).weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                shape
                    .fill(s.card.opacity(0.82))
                    .overlay { shape.fill(tint.opacity(configuration.isPressed ? 0.14 : 0.06)) }
                    .overlay {
                        RippleLayer(pressed: configuration.isPressed, color: tint, radius: 14)
                    }
                    // 同 DepthButtonStyle：阴影恒定，按压深度只走缩放/位移。
                    .shadow(color: s.shadowSoft, radius: 5, x: 0, y: 3)
                    .shadow(color: s.shadow.opacity(0.7), radius: 1, x: 0, y: 1)
            }
            .overlay { shape.strokeBorder(tint.opacity(0.16), lineWidth: 0.9) }
            .contentShape(shape)
            .modifier(FunctionalButtonHover(
                pressed: configuration.isPressed,
                pressedScale: 0.97,
                pressedOffset: 0,
                lift: 2.5,
                hoverScale: 1.012,
                pressDamping: 0.75
            ))
    }
}

/// 功能按钮的悬停抬起。按下仍用原来的缩放和位移；禁用和减少动态效果时不抬。
/// 只改变换，不改阴影半径，避免悬停时重绘大面积模糊阴影。
private struct FunctionalButtonHover: ViewModifier {
    var pressed: Bool
    var pressedScale: CGFloat
    var pressedOffset: CGFloat
    var lift: CGFloat
    var hoverScale: CGFloat
    var pressDamping: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var lifted: Bool { hovering && isEnabled && !pressed && !reduceMotion }

    /// 按下和悬停都会改这个值，弹簧才跟得上「悬停中再按下」。
    private var motionToken: Int {
        (pressed ? 4 : 0) | (lifted ? 2 : 0) | (hovering ? 1 : 0)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? pressedScale : (lifted ? hoverScale : 1))
            .offset(y: pressed ? pressedOffset : (lifted ? -lift : 0))
            .animation(.spring(response: 0.22, dampingFraction: pressDamping), value: motionToken)
            .onHover { inside in
                let next = inside && isEnabled && !reduceMotion
                if hovering != next { hovering = next }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovering = false }
            }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce { hovering = false }
            }
    }
}

/// 不替换原有按钮样式。系统描边、无边框和纯图标的按下效果保持原样。
/// 只做上移和很小的缩放，不加阴影。宽行把 scale 设为 1，避免横向撑开。
struct QuietHover: ViewModifier {
    var lift: CGFloat = 2
    var scale: CGFloat = 1.016
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var lifted: Bool { hovering && isEnabled && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted ? scale : 1)
            .offset(y: lifted ? -lift : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: lifted)
            .onHover { inside in
                let next = inside && isEnabled && !reduceMotion
                if hovering != next { hovering = next }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { hovering = false }
            }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce { hovering = false }
            }
    }
}

// MARK: - 悬浮抬升
struct HoverLift: ViewModifier {
    var amount: CGFloat = 3
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        // 只做缩放+位移，不叠悬停阴影：悬停阴影的半径动画每帧都重渲染模糊层。
        content
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .offset(y: hovering && !reduceMotion ? -amount : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - 页面切换虚化渐入
// 切换界面时：模糊 6pt→0 + 透明度 0→1 + 轻微上移 8pt，弹簧收尾。
// 用 id 驱动：route 变化时整个 Group 重建并重放动画。
struct PageFadeTransition: ViewModifier {
    let trigger: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .offset(y: shown ? 0 : 8)
            .onAppear { playIn() }
            .onChange(of: trigger) { _, _ in shown = false; playIn() }
    }
    private func playIn() {
        guard !reduceMotion else { shown = true; return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { shown = true }
    }
}

extension View {
    func hoverLift(_ amount: CGFloat = 3) -> some View { modifier(HoverLift(amount: amount)) }
    /// 给尚未使用 Depth / Soft 的自绘按钮加悬停。调用放在 `.disabled` 之前，禁用状态才传得进来。
    func quietHover(lift: CGFloat = 2, scale: CGFloat = 1.016) -> some View {
        modifier(QuietHover(lift: lift, scale: scale))
    }
    /// 「看得见的禁用」：压暗 + 拒绝音 + 底部提示条。替代裸 `.disabled()`。
    func gateDisabled(_ blocked: Bool, hint: String) -> some View {
        modifier(GateDisabled(blocked: blocked, hint: hint))
    }
    /// route 变化时虚化渐入（首页/列表页通用）
    func pageFade(trigger: String) -> some View { modifier(PageFadeTransition(trigger: trigger)) }
}


// MARK: - 呼吸指示灯
struct PulseDot: View {
    var color: Color
    var active: Bool
    @State private var animating = false

    var body: some View {
        ZStack {
            if active {
                Circle().fill(color.opacity(0.35)).frame(width: 9, height: 9)
                    .scaleEffect(animating ? 2.1 : 1)
                    .opacity(animating ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: animating)
            }
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.7), radius: 4)
        }
        .frame(width: 16, height: 16)
        // 光环在 active 为 false 时根本不在视图树里，animating 先置 true 再插进来不会有值变化，
        // 呼吸灯就永远定格在 2.1 倍透明态（正是「队列刚开始运行」那一下，5-15）。
        // 与 PermissionLight 同一套做法：出现与上升沿都先归零、下一拍再拉起。
        .onAppear {
            animating = false
            if active { startBreath() }
        }
        .onChange(of: active) { _, on in
            animating = false
            if on { startBreath() }
        }
    }

    private func startBreath() {
        DispatchQueue.main.async { animating = true }
    }
}

// MARK: - 分区标题
struct SectionLabel: View {
    let title: String
    var symbol: String
    var tint: Color = Theme.indigo
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if let trailing { Pill(text: trailing, tint: tint, symbol: "tag.fill", variant: .neutral) }
            Spacer()
        }
    }
}

// MARK: - 倒计时文本
struct CountdownText: View {
    let target: Date
    var prefix: String = "距开始"
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if target.timeIntervalSinceNow <= 0 {
            // 已经到点：文案固定成「已到时间」，不再留一个每秒空转的重绘周期（页面停留在总览时白耗电）
            chip(remain: 0, label: Self.format(0))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remain = target.timeIntervalSince(context.date)
                chip(remain: remain, label: Self.format(remain))
            }
        }
    }

    private func chip(remain: TimeInterval, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "hourglass").font(.system(size: compact ? 10 : 11, weight: .semibold))
            Text(remain <= 0 ? "\(prefix) · 已到时间" : "\(prefix) \(label)")
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(remain <= 0 ? Theme.green : Theme.indigo)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            LinearGradient(colors: [(remain <= 0 ? Theme.green : Theme.indigo).opacity(scheme == .dark ? 0.26 : 0.14),
                                    (remain <= 0 ? Theme.green : Theme.indigo).opacity(scheme == .dark ? 0.12 : 0.06)],
                           startPoint: .top, endPoint: .bottom),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.45), lineWidth: 0.7))
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60, s = total % 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 空状态
struct EmptyPanel: View {
    let title: String
    let symbol: String
    let message: String
    var tint: Color = Theme.indigo
    /// 嵌在「接下来」这类半屏卡片里时收成一行说明，避免大图标把正文挤出窗口。
    var compact: Bool = false

    var body: some View {
        if compact {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, size: 32, gradient: LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } else {
            VStack(spacing: 14) {
                IconTile(symbol: symbol, size: 58, gradient: LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 46)
        }
    }
}

// MARK: - 状态色
enum StatusStyle {
    // 每种状态一个专属色相，避免与渠道蓝 / 微信绿并排时撞色。
    static func color(_ status: String) -> Color {
        switch status {
        case "verified": return Theme.green
        case "manual": return Theme.teal
        case "running": return Theme.cyan
        case "submitted": return Theme.violet
        case "uncertain": return Theme.amber
        case "blocked": return Theme.orange
        case "draft": return Theme.rose
        case "cancelled": return Theme.slate
        default: return Theme.indigo
        }
    }
    static func symbol(_ status: String) -> String {
        switch status {
        case "verified": return "checkmark.seal.fill"
        case "manual": return "hand.thumbsup.fill"
        case "running": return "arrow.triangle.2.circlepath"
        case "submitted": return "paperplane.fill"
        case "uncertain": return "questionmark.circle.fill"
        case "blocked": return "pause.circle.fill"
        case "draft": return "doc.text.fill"
        case "cancelled": return "xmark.circle.fill"
        default: return "clock.fill"
        }
    }
    static func gradient(_ status: String) -> LinearGradient {
        let c = color(status)
        return LinearGradient(colors: [c, c.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - 权限状态灯
// 授权 = 亮绿呼吸光；未授权 = 暗灰静止。界限一目了然。
struct PermissionLight: View {
    var granted: Bool
    var label: String
    @State private var glowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if granted {
                    Circle().fill(Theme.green.opacity(0.35)).frame(width: 16, height: 16)
                        .scaleEffect(glowing ? 1.5 : 1)
                        .opacity(glowing ? 0 : 0.9)
                    Circle().fill(Theme.green).frame(width: 9, height: 9)
                        .shadow(color: Theme.green.opacity(0.7), radius: glowing ? 5 : 2)
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5).frame(width: 11, height: 11)
                    Circle().fill(Color.primary.opacity(0.18)).frame(width: 5, height: 5)
                }
            }
            .frame(width: 18, height: 18)
            Text(label)
                .font(.system(size: 11.5, weight: granted ? .semibold : .medium))
                .foregroundStyle(granted ? Theme.green : Color.primary.opacity(0.45))
            Image(systemName: granted ? "checkmark.seal.fill" : "xmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(granted ? Theme.green : Color.primary.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            granted ? Theme.green.opacity(0.10) : Color.primary.opacity(0.04),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(granted ? Theme.green.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 0.8))
        .onAppear {
            guard granted, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { glowing = true }
        }
        .onChange(of: granted) { _, value in
            glowing = false
            guard value, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { glowing = true }
        }
        .accessibilityLabel("\(label)：\(granted ? "已授权" : "未授权")")
    }
}


struct CopyButton: View {
    @EnvironmentObject private var store: Store
    let title: String
    let action: () throws -> Void
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    init(_ title: String = "复制", action: @escaping () throws -> Void) {
        self.title = title; self.action = action
    }
    var body: some View {
        Button {
            do {
                try action()
                copied = true
                store.step = "已复制，可用 ⌘V 粘贴"
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds:2_000_000_000)
                    if !Task.isCancelled { copied = false }
                }
            } catch { store.error = error.localizedDescription }
        } label: {
            Label(copied ? "已复制" : title, systemImage:copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(SoftButtonStyle(tint: copied ? Theme.teal : Theme.indigo))
        .fixedSize()
        .help("复制到剪贴板，然后用 ⌘V 粘贴")
        .onDisappear { resetTask?.cancel(); copied = false }
    }
}
