import SwiftUI

// MARK: - 进度块状态
enum SegmentState {
    case pending
    case active
    case done
    case failed
    case paused
    case cancelled
}

// MARK: - 单个群的进度块模型
struct ProgressSegment: Identifiable {
    let id: String
    var title: String          // 群名（或「还有 N 群」汇总段）
    var state: SegmentState
    var detail: String?        // 附加说明（时间 / 状态名）
    var reason: String? = nil  // 需关注的原因（来自任务 detail，直接展示给用户）
    var isNext: Bool = false   // 队列运行时由调度顺序标记的下一群
    var canRetry: Bool = false
    var isSummary: Bool = false
    var needsReview: Bool = false

    init(id: String, title: String, state: SegmentState, detail: String? = nil, reason: String? = nil, canRetry: Bool = false, isNext: Bool = false, isSummary: Bool = false, needsReview: Bool = false) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.reason = reason
        self.canRetry = canRetry
        self.isNext = isNext
        self.isSummary = isSummary
        self.needsReview = needsReview
    }
}

// MARK: - Delivery → ProgressSegment 映射
enum DispatchProgressMapper {
    /// 按计划时间升序取前 limit 条生成进度块；超出部分折叠为「还有 N 群」汇总段。
    /// 已取消的任务直接退出队列显示，不再占据进度块（记录仍在发送记录里可查）。
    /// running=true 时把最早的待发块标记为 isNext。
    static func segments(from deliveries: [Delivery], limit: Int = 12, running: Bool = false) -> [ProgressSegment] {
        let active = deliveries.filter { $0.status != "cancelled" }
        guard !active.isEmpty else { return [] }
        let sorted = Scheduling.ordered(active)
        let shown = Array(sorted.prefix(max(1, limit)))
        var result: [ProgressSegment] = shown.map { job in
            ProgressSegment(id: job.id, title: job.recipient, state: mapStatus(job.status),
                            detail: job.statusName, reason: Self.reason(of: job), canRetry: job.canRequeue,
                            needsReview: QueueStartGate.reviewStatuses.contains(job.status))
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
                : states.contains(.paused) ? .paused
                : states.contains(.active) ? .active
                : states.contains(.pending) ? .pending
                : states.contains(.cancelled) ? .cancelled : .done
            let hiddenStatuses = hidden.map(\.status)
            let hiddenReview = QueueStartGate.reviewCount(hiddenStatuses)
            let hiddenPaused = QueueStartGate.pausedCount(hiddenStatuses)
            let summaryTitle = QueueStartGate.overflowTitle(hiddenStatuses: hiddenStatuses)
            let summaryDetail: String? = hiddenReview > 0 ? "待核对结果留在日志，其他待执行群继续"
                : hiddenPaused > 0 ? "已拦截，到发送记录核对后选择"
                : summaryState == .active ? "包含进行中的群"
                : summaryState == .pending ? "尚未执行"
                : summaryState == .cancelled ? "已取消" : "已核对完成"
            result[result.count - 1] = ProgressSegment(
                id: "summary-\(hidden.first?.id ?? "0")",
                title: summaryTitle,
                state: summaryState,
                detail: summaryDetail,
                isSummary: true,
                needsReview: hiddenReview > 0
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
        switch ProgressTone.tone(for: status) {
        case .pending: return .pending
        case .sending: return .active
        case .done: return .done
        case .review: return .failed
        case .paused: return .paused
        case .cancelled: return .cancelled
        }
    }
}

// MARK: - 发送进度（主组件）
struct DispatchProgress3D: View {
    var segments: [ProgressSegment]
    var doneCount: Int
    var totalCount: Int
    var queueRunning: Bool = false
    var onRetry: ((String) -> Void)? = nil
    var retryEnabled = true
    var attentionLabel: String? = nil

    @Environment(\.colorScheme) private var scheme

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
                overallBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 顶部一行
    private var header: some View {
        HStack(spacing: 10) {
            SectionLabel(title: queueRunning ? "发送进度" : "发送进度 · 队列未启动",
                         symbol: "square.stack.3d.up.fill", tint: Theme.indigo)
            Spacer(minLength: 8)
            Pill(text: "已核对 \(doneCount) / \(totalCount) 群", tint: Theme.indigo,
                 symbol: "checkmark.seal.fill")
            if let attentionLabel {
                Pill(text: attentionLabel, tint: Theme.orange,
                     symbol: "exclamationmark.triangle.fill", variant: .emphasis)
            }
        }
    }

    // 群块横排。可重试的块整体可点，点击说明收进块内悬停提示（外层 .help 会被块内 .help 遮蔽），不再另排小字
    private var segmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(segments) { segment in
                    Group {
                        if !segment.isSummary && (segment.canRetry || segment.needsReview || segment.state == .paused), let onRetry {
                            Button { onRetry(segment.id) } label: {
                                SegmentBlock(segment: segment, scheme: scheme)
                            }
                            .buttonStyle(GhostPressButtonStyle())
                            .disabled(!retryEnabled)
                            .accessibilityHint("查看原记录，核对后选择发送或不发送")
                        } else {
                            SegmentBlock(segment: segment, scheme: scheme)
                        }
                    }
                }
            }
            .padding(.vertical, 2).padding(.horizontal, 2)
        }
    }

    // 整体进度条
    private var overallBar: some View {
        let fraction = self.fraction
        return HStack(spacing: 12) {
            OverallProgressTrack(fraction: fraction)
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
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 单个群的状态卡
private struct SegmentBlock: View {
    let segment: ProgressSegment
    let scheme: ColorScheme

    /// 跟随外层 Button 的 disabled 状态；自绘渐变不会自动变灰，需自己降级提示“暂不可点”
    @Environment(\.isEnabled) private var isEnabled

    /// 已提交过的暂停（canRetry=false）不能自动重试，单独给暖色，避免和可重试的灰色暂停混淆
    private var needsReview: Bool { segment.state == .paused && !segment.canRetry }

    private var colors: [Color] {
        let neutral = Theme.slate
        switch segment.state {
        case .pending: return segment.isNext ? [Theme.indigo, Theme.violet] : [Color(red: 0.17, green: 0.18, blue: 0.21), Color(red: 0.11, green: 0.12, blue: 0.14)]
        case .active: return [Theme.indigo, Theme.violet]
        case .done: return [Theme.green, Theme.teal]
        case .failed: return [Theme.orange, Theme.rose]
        case .paused, .cancelled: return needsReview ? [Theme.amber, Theme.orange] : [neutral.opacity(0.90), neutral.opacity(0.65)]
        }
    }

    private var status: String {
        switch segment.state {
        case .pending: return segment.isNext ? "下一群" : "待执行"
        case .active: return "发送中"
        case .done: return segment.detail ?? "已核对完成"
        case .failed: return "待核对"
        case .paused: return needsReview ? "已拦截 · 需核对" : "已拦截"
        case .cancelled: return "已取消"
        }
    }

    private var symbol: String {
        switch segment.state {
        case .pending: return segment.isNext ? "arrow.right.circle.fill" : "clock"
        case .active: return "paperplane.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var helpText: String {
        let detail = segment.detail.map { " · \($0)" } ?? ""
        let reason = segment.reason.map { "\n原因：\($0)" } ?? ""
        let review = needsReview ? "\n该任务此前已尝试提交，不能自动重试；请到「发送记录」页核对。" : ""
        // 可重试块的点击说明并入这里，保证无论嵌套层级如何悬停提示都完整
        let retry = (segment.canRetry || segment.needsReview || segment.state == .paused) && !segment.isSummary
            ? "\n点击核对，选择发送或不发送" : ""
        return "\(segment.title) · \(status)\(detail)\(reason)\(review)\(retry)"
    }

    private var width: CGFloat { segment.isSummary ? 84 : 72 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 17, style: .continuous) }

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 1)
            Text(segment.state == .pending ? segment.title : status)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(width: width, height: 46)
        .background {
            shape
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(segment.state == .pending ? 0.12 : 0.38), .clear],
                                              startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape.fill(LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
                .shadow(color: colors[0].opacity(segment.state == .pending ? 0.12 : 0.30), radius: 6, x: 0, y: 4)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.7))
        .opacity(isEnabled ? 1 : 0.45)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }
}

// MARK: - 整体进度条
private struct OverallProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if fraction > 0 {
                    Capsule()
                        .fill(Theme.indigo)
                        .frame(width: proxy.size.width * CGFloat(fraction))
                }
            }
        }
        .frame(height: 8)
        .accessibilityLabel("发送进度")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - 紧凑版（首页 hero 卡片）
struct DispatchProgress3DCompact: View {
    var segments: [ProgressSegment]
    var doneCount: Int
    var totalCount: Int
    var queueRunning: Bool = false    // 队列是否已启动；未启动时明确说「等待启动」而不是「正在发送」
    var compactTint: Color = .white   // 深色背景上用白

    private var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, Double(doneCount) / Double(totalCount))
    }

    // 此卡只显示状态概况；具体下一群由队列页的 queueCandidate 决定。
    // 未确认结果保留提示；主状态优先展示仍在运行或等待的群。
    private var currentTitle: String? {
        segments.first(where: { $0.state == .active })?.title
            ?? segments.first(where: { $0.state == .pending })?.title
            ?? segments.first(where: { $0.needsReview })?.title
            ?? segments.first(where: { $0.state == .paused })?.title
            ?? segments.last(where: { $0.state == .done })?.title
    }

    private var headline: String {
        if fraction >= 1 { return "本计划已全部完成 · \(totalCount) 群" }
        if let active = segments.first(where: { $0.state == .active })?.title {
            return queueRunning ? "正在发送 · \(active)" : "等待继续 · \(active)（队列未启动）"
        }
        let pendingCount = segments.filter { $0.state == .pending }.count
        if pendingCount > 0 {
            return queueRunning ? "队列运行中 · \(pendingCount) 群待执行" : "队列未启动 · \(pendingCount) 群待执行"
        }
        if let review = segments.first(where: { $0.needsReview }) {
            // 汇总段的 title 已经是「还有 N 群 · M 群待核对」，再套一层「待核对 ·」会重复，直接用它。
            return review.isSummary ? review.title : "待核对 · \(review.title)"
        }
        let pausedCount = segments.filter { $0.state == .paused }.count
        if pausedCount > 0 { return "\(pausedCount) 群已拦截" }
        return "当前没有待执行任务"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if currentTitle != nil {
                    Image(systemName: segments.contains(where: { $0.state == .active }) ? "paperplane.fill" : (queueRunning ? "bolt.fill" : "clock.badge.exclamationmark"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(compactTint.opacity(0.9))
                    Text(verbatim: headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(compactTint)
                        .lineLimit(1)
                } else {
                    Text("暂无发送任务")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(compactTint.opacity(0.85))
                }
                Spacer(minLength: 6)
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(compactTint)
            }
            CompactTrack(fraction: fraction)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60, alignment: .top)
        .clipped()
    }
}

// 紧凑版轨道（深色背景可读）
private struct CompactTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                if fraction > 0 {
                    Capsule()
                        .fill(Theme.green)
                        .frame(width: proxy.size.width * CGFloat(fraction))
                }
            }
        }
        .frame(height: 8)
        .accessibilityLabel("发送进度")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - 便捷统计
extension DispatchProgressMapper {
    /// 已完成（verified/manual）数量
    static func doneCount(from deliveries: [Delivery]) -> Int {
        deliveries.filter { ["verified", "manual"].contains($0.status) }.count
    }
}
