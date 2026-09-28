import SwiftUI
import AppKit

// MARK: - 进度块状态
enum SegmentState {
    case pending    // 未轮到（灰色凹槽）
    case active     // 正在发送（流光 + 脉冲）
    case done       // 已完成（绿色打勾，弹跳点亮）
    case failed     // 失败 / 暂停 / 待核对（橙红警示）
    case cancelled  // 已取消（灰）
}

// MARK: - 单个群的进度块模型
struct ProgressSegment: Identifiable {
    let id: String
    var title: String          // 群名（或「还有 N 群」汇总段）
    var state: SegmentState
    var detail: String?        // 附加说明（时间 / 状态名）
    var reason: String? = nil  // 需关注的原因（来自任务 detail，直接展示给用户）
    var isNext: Bool = false   // 队列运行中的下一群：心跳预告，进度即将推进到这个框
    var canRetry: Bool = false
    var isSummary: Bool = false

    init(id: String, title: String, state: SegmentState, detail: String? = nil, reason: String? = nil, canRetry: Bool = false, isNext: Bool = false, isSummary: Bool = false) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.reason = reason
        self.canRetry = canRetry
        self.isNext = isNext
        self.isSummary = isSummary
    }
}

// MARK: - Delivery → ProgressSegment 映射
enum DispatchProgressMapper {
    /// 按计划时间升序取前 limit 条生成进度块；超出部分折叠为「还有 N 群」汇总段。
    /// running=true 时把最早的待发块标记为 isNext（缓冲心跳预告）。
    static func segments(from deliveries: [Delivery], limit: Int = 12, running: Bool = false) -> [ProgressSegment] {
        guard !deliveries.isEmpty else { return [] }
        let sorted = deliveries.sorted { $0.scheduled < $1.scheduled }
        let shown = Array(sorted.prefix(max(1, limit)))
        var result: [ProgressSegment] = shown.map { job in
            ProgressSegment(id: job.id, title: job.recipient, state: mapStatus(job.status),
                            detail: job.statusName, reason: Self.reason(of: job), canRetry: job.canRequeue)
        }
        if running, let nextIndex = sorted.firstIndex(where: { $0.status == "queued" }), nextIndex < result.count,
           let shownIndex = result.firstIndex(where: { $0.id == sorted[nextIndex].id }) {
            result[shownIndex].isNext = true
            result[shownIndex].detail = "下一群 · 即将发送"
        }
        let overflow = sorted.count - shown.count
        if overflow > 0 {
            let hidden = Array(sorted.dropFirst(shown.count - 1))
            // 汇总块如实聚合：优先级 需关注 > 进行中 > 待发 > 完成，绝不假装一切正常
            let states = hidden.map { mapStatus($0.status) }
            let summaryState: SegmentState = states.contains(.failed) ? .failed
                : states.contains(.active) ? .active
                : states.contains(.pending) ? .pending
                : states.contains(.cancelled) ? .cancelled : .done
            let hiddenAttention = states.filter { $0 == .failed }.count
            let summaryTitle = hiddenAttention > 0 ? "还有 \(hidden.count) 群 · \(hiddenAttention) 群需关注" : "还有 \(hidden.count) 群"
            let summaryDetail: String? = hiddenAttention > 0 ? "有群需要人工核对"
                : summaryState == .active ? "包含进行中的群"
                : summaryState == .pending ? "尚未执行"
                : summaryState == .cancelled ? "已取消" : "已完成"
            result[result.count - 1] = ProgressSegment(
                id: "summary-\(hidden.first?.id ?? "0")",
                title: summaryTitle,
                state: summaryState,
                detail: summaryDetail,
                isSummary: true
            )
        }
        return result
    }

    /// 需关注类状态的人话原因：优先实际错误原因，避免把执行步骤当成原因，压到一行可读长度
    static func reason(of job: Delivery) -> String? {
        guard var text = job.attentionReason else { return nil }
        if text.count > 42 { text = String(text.prefix(42)) + "…" }
        return text.isEmpty ? nil : text
    }

    static func mapStatus(_ status: String) -> SegmentState {
        switch status {
        case "queued": return .pending
        case "running": return .active
        case "verified", "manual": return .done
        case "submitted": return .active   // 已提交 · 待核验，视为进行中
        case "draft", "uncertain", "blocked": return .failed
        case "cancelled": return .cancelled
        default: return .pending
        }
    }
}

// MARK: - 3D 发送进度（主组件）
struct DispatchProgress3D: View {
    var segments: [ProgressSegment]
    var doneCount: Int
    var totalCount: Int
    var queueRunning: Bool = false
    var onRetry: ((String) -> Void)? = nil
    var retryEnabled = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(doneCount) / Double(totalCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if segments.isEmpty {
                emptyHint
            } else {
                header
                segmentStrip
                reasonList
                overallBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 进度块自身的 3D 质感来自分段渐变 + 顶高光 + 阴影；
        // 不再整体抬升倾斜（旧版 rotation3DEffect 2°），平铺进宿主卡片，
        // 避免卡片内再悬浮一层斜置内容造成的重叠感。
    }

    /// 需要人工关注的块数（failed 状态）
    private var attentionCount: Int {
        segments.filter { $0.state == .failed }.count
    }

    // 顶部一行
    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel(title: queueRunning ? "发送进度" : "发送进度 · 队列未启动", symbol: "square.stack.3d.up.fill", tint: Theme.indigo)
            Spacer(minLength: 8)
            Pill(text: "已核验 \(doneCount) / \(totalCount) 群",
                 tint: doneCount >= totalCount && totalCount > 0 ? Theme.green : Theme.indigo,
                 symbol: "checkmark.seal.fill")
            if attentionCount > 0 {
                Pill(text: "\(attentionCount) 群需关注", tint: Theme.orange,
                     symbol: "exclamationmark.triangle.fill", variant: .emphasis)
            }
        }
    }

    // 群块横排
    private var segmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Group {
                        if segment.canRetry, let onRetry {
                            Button { onRetry(segment.id) } label: {
                                VStack(spacing: 4) {
                    SegmentBlock(segment: segment, reduceMotion: reduceMotion, scheme: scheme,
                                 appearDelay: reduceMotion ? 0 : Double(index) * 0.03)
                                Label("点击重新入队", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                                }
                            }.buttonStyle(.plain).disabled(!retryEnabled)
                        } else {
                    SegmentBlock(segment: segment, reduceMotion: reduceMotion, scheme: scheme,
                                 appearDelay: reduceMotion ? 0 : Double(index) * 0.03)
                        }
                    }
                    // 统一列高：横向 ScrollView 的容器高度取懒加载子视图的最小需求，
                    // 不固定会让「点击重新入队」行溢出、被下方面板叠住
                    .frame(height: 82, alignment: .top)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
    }

    /// 「为什么需关注」：把每个警示块的触发原因直接列出来，不让用户猜
    private var reasonList: some View {
        let failed = segments.filter { $0.state == .failed && !$0.isSummary && $0.reason != nil }
        let shown = failed.prefix(4)
        let hiddenExtra = failed.count - shown.count
        return Group {
            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.orange)
                        Text("为什么需要关注").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary)
                        Text("鼠标悬停任意群块也可看原因").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(shown), id: \.id) { segment in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(Theme.orange).frame(width: 5, height: 5).padding(.top, 4)
                            Text(verbatim: "\(segment.title)：\(segment.detail ?? "需要人工处理")——\(segment.reason ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    if hiddenExtra > 0 {
                        Text("还有 \(hiddenExtra) 条需关注，原因见「发送记录」详情。")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.orange.opacity(scheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.orange.opacity(0.30), lineWidth: 1))
            }
        }
    }

    // 整体 3D 进度条
    private var overallBar: some View {
        let fraction = self.fraction
        return HStack(spacing: 12) {
            OverallProgressTrack(fraction: fraction, reduceMotion: reduceMotion)
            Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(fraction >= 1 ? Theme.green : Theme.indigo)
                .frame(minWidth: 42, alignment: .trailing)
        }
    }

    private var emptyHint: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("暂无发送任务").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("启动计划后，这里会按群逐块点亮发送进度。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 单个群块（3D 立体小块）
private struct SegmentBlock: View {
    let segment: ProgressSegment
    let reduceMotion: Bool
    let scheme: ColorScheme
    var appearDelay: Double = 0
    @State private var appeared = false
    @State private var donePop = false
    @State private var breathing = false

    private var width: CGFloat { segment.isSummary ? 84 : 72 }
    private var height: CGFloat { 46 }

    var body: some View {
        VStack(spacing: 4) {
            blockBody
            // 待发/下一群的群名已显示在块内，外部不再重复一行标题
            if segment.state != .pending {
                Text(segment.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width + 6)
            }
        }
        .help(helpText)
        .scaleEffect((appeared ? 1.0 : 0.6) * (donePop ? 1.05 : 1.0))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + appearDelay) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { appeared = true }
                }
                if segment.state == .done { triggerDonePop() }
                if segment.state == .failed { startBreathing() }
            }
        }
        .onChange(of: segment.state) { _, newState in
            if newState == .done { triggerDonePop() }
            if newState == .failed { startBreathing() }
        }
    }

    /// done 弹跳：块体 1.0→1.06→1.0 单次过冲
    private func triggerDonePop() {
        guard !reduceMotion else { return }
        donePop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { donePop = false }
        }
    }

    /// failed 低频呼吸：填充透明度 + 描边脉冲（0.9s 往复，幅度小不刺眼）
    private func startBreathing() {
        guard !reduceMotion, !breathing else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
    }

    @ViewBuilder
    private var blockBody: some View {
        switch segment.state {
        case .pending:
            if segment.isNext { upcomingBlock } else { pendingBlock }
        case .active: activeBlock
        case .done: doneBlock
        case .failed: failedBlock
        case .cancelled: cancelledBlock
        }
    }

    /// 悬停说明：每一块都能回答"这是什么状态 / 为什么"
    private var helpText: String {
        let name = segment.title
        switch segment.state {
        case .pending:
            return segment.isNext ? "\(name) · 下一群：缓冲结束后立即推进到这一群" : "\(name) · 待发送，按间隔依次执行"
        case .active:
            return "\(name) · 正在发送（QQ 正在执行本群）"
        case .done:
            return "\(name) · 已核验：QQ 界面确认发送成功"
        case .failed:
            let base = "\(name) · \(segment.detail ?? "需要人工处理")"
            return segment.reason == nil ? base : "\(base)。\n原因：\(segment.reason!)"
        case .cancelled:
            return "\(name) · 已取消，不会发送"
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
    }

    // —— 通用 3D 质感修饰 ——
    // 顶部内高光描边（白色渐变只画上半）
    private func topHighlight<S: Shape>(_ shape: S) -> some View {
        LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .center)
            .frame(height: height / 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
    }

    // 底部深色内阴影
    private func bottomInnerShadow<S: Shape>(_ shape: S) -> some View {
        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
            .frame(height: height / 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    private func label(_ text: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 1)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
    }

    // —— pending：灰色凹槽，块内显示群名（超长省略）+ clock 图标 ——
    private var pendingBlock: some View {
        let inset = scheme == .dark
            ? Color(red: 0.085, green: 0.092, blue: 0.112)
            : Color(red: 0.878, green: 0.882, blue: 0.898)
        return label(segment.title, symbol: "clock")
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [inset, inset.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                    .overlay { topHighlightInnerCut }
                    .overlay { bottomInnerShadow(shape) }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 2, x: 0, y: 1.5)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.9
                )
            }
            .overlay(alignment: .top) {
                // 凹槽顶部 1px 高光线：未点亮的"边缘反光"质感
                Rectangle()
                    .fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
            .opacity(0.85)
    }

    // 凹槽感：内凹高光（上暗下亮的反向描边）
    private var topHighlightInnerCut: some View {
        LinearGradient(colors: [.black.opacity(0.16), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    // —— upcoming（下一群缓冲心跳）：凹槽被靛蓝光晕缓缓点亮，预告进度即将推进到这里 ——
    @State private var nextPulse = false
    private var upcomingBlock: some View {
        let inset = scheme == .dark
            ? Color(red: 0.085, green: 0.092, blue: 0.112)
            : Color(red: 0.878, green: 0.882, blue: 0.898)
        return label(segment.title, symbol: "bolt.fill")
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [inset, inset.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                    .overlay { topHighlightInnerCut }
                    .overlay { bottomInnerShadow(shape) }
                    .overlay {
                        // 心跳填充：靛蓝光从底部缓缓涨落
                        LinearGradient(colors: [Theme.indigo.opacity(0.02), Theme.indigo.opacity(nextPulse ? 0.34 : 0.10)],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(shape)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: Theme.indigo.opacity(nextPulse ? 0.35 : 0.12), radius: nextPulse ? 9 : 4, y: 2)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Theme.indigo.opacity(nextPulse ? 0.85 : 0.30), Theme.indigo.opacity(nextPulse ? 0.40 : 0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.4
                )
            }
            .overlay {
                if !reduceMotion {
                    shape
                        .strokeBorder(Theme.indigo.opacity(nextPulse ? 0.45 : 0.0), lineWidth: 2.5)
                        .scaleEffect(nextPulse ? 1.09 : 1.0)
                        .blur(radius: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { nextPulse = true }
            }
            .opacity(1)
    }

    // —— active：主题色渐变 + 流光 + 脉冲 ——
    private var activeBlock: some View {
        label("发送中", symbol: "paperplane.fill")
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [Theme.indigo.opacity(0.94), Theme.violet.opacity(0.80)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { topHighlight(shape) }
                    .overlay { bottomInnerShadow(shape) }
                    .shadow(color: Theme.indigo.opacity(scheme == .dark ? 0.55 : 0.32), radius: reduceMotion ? 6 : glowRadius, x: 0, y: reduceMotion ? 3 : 5)
                    // 辉光呼吸由 pulsing 驱动（5↔9），见 glowRadius
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.20), lineWidth: 0.7)
            }
            .overlay {
                if !reduceMotion {
                    // 流光带：TimelineView 驱动，白色高光带循环扫过
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        GeometryReader { proxy in
                            let bandWidth: CGFloat = 26
                            let travel = proxy.size.width + bandWidth * 2
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .frame(width: bandWidth, height: proxy.size.height * 1.4)
                                .rotationEffect(.degrees(18))
                                .offset(x: -bandWidth + travel * t, y: -proxy.size.height * 0.2)
                                .blur(radius: 2)
                        }
                        .mask { shape }
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if !reduceMotion { pulseRing }
            }
    }

    // 脉冲光晕
    @State private var pulsing = false
    private var pulseRing: some View {
        shape
            .strokeBorder(Theme.indigo.opacity(pulsing ? 0.55 : 0.0), lineWidth: 2)
            .scaleEffect(pulsing ? 1.10 : 1.0)
            .shadow(color: Theme.indigo.opacity(pulsing ? 0.5 : 0.1), radius: pulsing ? 9 : 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulsing = true }
            }
            .allowsHitTesting(false)
    }

    private var glowRadius: CGFloat { pulsing ? 9 : 5 }

    // —— done：绿色渐变 + 打勾弹跳 ——
    private var doneBlock: some View {
        label("已发送", symbol: "checkmark.circle.fill")
            .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating : .nonRepeating, value: segment.state == .done ? 1 : 0)
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [Theme.green.opacity(0.94), Theme.teal.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { topHighlight(shape) }
                    .overlay { bottomInnerShadow(shape) }
                    .shadow(color: Theme.green.opacity(scheme == .dark ? 0.50 : 0.28), radius: 6, x: 0, y: 4)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
            }
    }

    // —— failed：橙红警示 + 低频呼吸；块面直接显示具体状态（已暂停/结果待核对/草稿待确认），原因见悬停与下方列表 ——
    private var failedBlock: some View {
        label(segment.isSummary ? "需关注" : (segment.detail ?? "需关注"), symbol: "exclamationmark.triangle.fill")
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [Theme.orange.opacity(0.94), Theme.rose.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { topHighlight(shape) }
                    .overlay { bottomInnerShadow(shape) }
                    .shadow(color: Theme.orange.opacity(scheme == .dark ? 0.45 : 0.26), radius: 5, x: 0, y: 3)
                    .opacity(breathing ? 1.0 : 0.86)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(breathing ? 0.32 : 0.18), lineWidth: 0.7)
            }
    }

    // —— cancelled：灰色取消 ——
    private var cancelledBlock: some View {
        label("已取消", symbol: "xmark.circle")
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(LinearGradient(colors: [Theme.slate.opacity(0.90), Theme.slate.opacity(0.64)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { topHighlight(shape) }
                    .overlay { bottomInnerShadow(shape) }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.36 : 0.14), radius: 3, x: 0, y: 2)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.7)
            }
    }
}

// MARK: - 整体 3D 进度条
private struct OverallProgressTrack: View {
    var fraction: Double
    let reduceMotion: Bool
    @State private var animatedFraction: Double = 0

    private var trackHeight: CGFloat { 14 }

    /// 完成度 0→1 时填充色从 indigo 过渡到 green
    private var fillEnd: Color { Color(Theme.indigo).blend(with: Theme.green, weight: fraction) }
    private var fillGradient: LinearGradient {
        LinearGradient(colors: [Color(Theme.indigo).blend(with: Theme.green, weight: fraction * 0.8), fillEnd],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                // 胶囊轨道：内凹深色
                Capsule()
                    .fill(LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                Capsule()
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 0.9)

                // 填充条：颜色随完成度从 indigo 过渡到 green
                if animatedFraction > 0.001 {
                    Capsule()
                        .fill(fillGradient)
                        .frame(width: max(trackHeight, width * animatedFraction))
                        .overlay {
                            // 顶部高光
                            LinearGradient(colors: [.white.opacity(0.40), .white.opacity(0.02)], startPoint: .top, endPoint: .center)
                                .clipShape(Capsule())
                        }
                        .overlay {
                            // 斜向流动条纹
                            if !reduceMotion {
                                TimelineView(.animation) { context in
                                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                                    GeometryReader { inner in
                                        StripesPattern()
                                            .stroke(.white.opacity(0.20), lineWidth: 2.5)
                                            .frame(width: inner.size.width + 40, height: inner.size.height)
                                            .offset(x: -20 + 40 * t)
                                            .mask { Capsule() }
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            // 引导光点：填充前沿的小发光圆点
                            if !reduceMotion {
                                TimelineView(.animation) { context in
                                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                                    let glow = 0.55 + 0.45 * sin(phase * .pi * 2)
                                    Circle()
                                        .fill(fillGradient)
                                        .frame(width: trackHeight - 4, height: trackHeight - 4)
                                        .background(
                                            Circle().fill(Theme.green.opacity(0.35 * glow)).blur(radius: 3)
                                        )
                                        .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                                        .shadow(color: Theme.green.opacity(0.55 * glow), radius: 4 + 2 * glow)
                                }
                            }
                        }
                        .shadow(color: fillEnd.opacity(0.35), radius: 4, x: 0, y: 2)
                }
            }
        }
        .frame(height: trackHeight)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { animatedFraction = fraction }
        }
        .onChange(of: fraction) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { animatedFraction = newValue }
        }
    }
}

// 斜向条纹图案
private struct StripesPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 10
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += spacing
        }
        return path
    }
}

// MARK: - 紧凑版（首页 hero 卡片）
struct DispatchProgress3DCompact: View {
    var segments: [ProgressSegment]
    var doneCount: Int
    var totalCount: Int
    var queueRunning: Bool = false    // 队列是否已启动；未启动时明确说「等待启动」而不是「正在发送」
    var compactTint: Color = .white   // 深色背景上用白

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(doneCount) / Double(totalCount))
    }

    // 当前群：第一个 active；没有 active 则取第一个 pending；再没有则取最后一个 done
    private var currentTitle: String? {
        segments.first(where: { $0.state == .active })?.title
            ?? segments.first(where: { $0.state == .pending })?.title
            ?? segments.last(where: { $0.state == .done })?.title
    }

    private var headline: String {
        if fraction >= 1 { return "今日已全部完成 · \(totalCount) 群" }
        if let active = segments.first(where: { $0.state == .active })?.title {
            return queueRunning ? "正在发送 · \(active)" : "等待继续 · \(active)（队列未启动）"
        }
        guard let title = currentTitle else { return "暂无发送任务" }
        if queueRunning { return "缓冲中 · 即将推进 \(title)" }
        return "等待启动 · 下一群 \(title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if currentTitle != nil {
                    Image(systemName: segments.contains(where: { $0.state == .active }) ? "paperplane.fill" : (queueRunning ? "bolt.fill" : "clock.badge.exclamationmark"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(compactTint.opacity(0.9))
                    Text(verbatim: headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(compactTint)
                        .lineLimit(1)
                } else {
                    Text("暂无发送任务")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(compactTint.opacity(0.85))
                }
                Spacer(minLength: 6)
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(compactTint)
            }
            CompactTrack(fraction: fraction, reduceMotion: reduceMotion, tint: compactTint)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60, alignment: .top)
        .clipped()
    }
}

// 紧凑版轨道（深色背景可读）
private struct CompactTrack: View {
    var fraction: Double
    let reduceMotion: Bool
    let tint: Color
    @State private var animatedFraction: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.18))
                Capsule()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.9)
                if animatedFraction > 0.001 {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.green.opacity(0.95), Theme.teal.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, width * animatedFraction))
                        .overlay {
                            LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)], startPoint: .top, endPoint: .center)
                                .clipShape(Capsule())
                        }
                        .overlay {
                            if !reduceMotion {
                                TimelineView(.animation) { context in
                                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                                    GeometryReader { inner in
                                        StripesPattern()
                                            .stroke(.white.opacity(0.22), lineWidth: 2)
                                            .frame(width: inner.size.width + 40, height: inner.size.height)
                                            .offset(x: -20 + 40 * t)
                                            .mask { Capsule() }
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1)
                }
            }
        }
        .frame(height: 8)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { animatedFraction = fraction }
        }
        .onChange(of: fraction) { _, newValue in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { animatedFraction = newValue }
        }
    }
}

// MARK: - 便捷统计
extension DispatchProgressMapper {
    /// 已完成（verified/manual）数量
    static func doneCount(from deliveries: [Delivery]) -> Int {
        deliveries.filter { ["verified", "manual"].contains($0.status) }.count
    }
}


// 颜色线性插值（进度条 indigo→green 过渡用）
extension Color {
    func blend(with other: Color, weight: Double) -> Color {
        let w = CGFloat(min(max(weight, 0), 1))
        guard let a = NSColor(self).usingColorSpace(.sRGB),
              let b = NSColor(other).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: Double(a.redComponent + (b.redComponent - a.redComponent) * w),
            green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * w),
            blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * w),
            opacity: Double(a.alphaComponent + (b.alphaComponent - a.alphaComponent) * w)
        )
    }
}
