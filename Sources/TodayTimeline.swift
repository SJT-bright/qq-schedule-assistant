import SwiftUI

// MARK: - 今日时刻表
//
// 这里放三个可复用组件，供总览页与菜单栏弹窗嵌入：
//   1. TodayTimelineView  竖向时间线：按小时分组列出今天的发送任务，一眼看出「今天要发什么」
//   2. MenuTodaySection   菜单栏窄版：标题行 + 最多 5 条今日任务
//   3. ChannelPill        QQ / 微信渠道标签
//
// 视觉全部复用 Theme.swift 的色板与组件，不引入新颜色（微信绿使用 Theme.wechat 即 #07C160）。
// 时间的「今天」边界、小时分组与排序都用 Scheduling.calendar（Asia/Shanghai），
// 与排期引擎完全一致。动画尊重 accessibilityReduceMotion。

/// 「今天 00:00 起」的通用小工具。
enum TodayTimeline {
    /// 已确认发送完成的状态（计入「已发」）
    static let sentStatuses = ["verified", "manual"]
    /// 今天时刻表里仍要看见的未完成状态。已暂停单独算，不并进「待核对」。
    static let attentionStatuses = ["draft", "uncertain", "blocked", "submitted"]
    /// 整体淡化显示的状态（已完成或已取消）
    static let doneStatuses = ["verified", "manual", "cancelled"]

    /// 过滤出今天（Asia/Shanghai 自然日）的任务，并按时间升序排列
    static func todays(_ deliveries: [Delivery], calendar: Calendar = Scheduling.calendar) -> [Delivery] {
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return deliveries.filter { $0.scheduled >= start && $0.scheduled < end }.sorted { $0.scheduled < $1.scheduled }
    }

    /// HH:mm 文本（配合等宽数字字体展示）
    static func hhmm(_ date: Date, calendar: Calendar = Scheduling.calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - 渠道标签

/// "qq" → QQ（蓝色，bubble.left.fill）；"wechat" → 微信（微信绿 Theme.wechat，
/// SF Symbols 没有微信图标，用 person.2.fill 代替，与「群与联系人」页的画法一致）。
/// compact = true 时只显示图标 + 短字，适合行内使用。
struct ChannelPill: View {
    var channel: String
    var compact: Bool = false

    private var isWeChat: Bool { channel == SendChannel.wechat }
    private var label: String { isWeChat ? "微信" : "QQ" }
    private var style: (tint: Color, symbol: String) { TagStyle.channel(channel) }

    var body: some View {
        Pill(text: label, tint: style.tint, symbol: style.symbol, compact: compact)
            .accessibilityLabel("\(label)渠道")
    }
}

// MARK: - 今日时刻表（总览页）

/// 竖向时间线，按小时分组展示今天的发送任务。
/// 高度自适应：组件本身不带滚动，直接放进外层 ScrollView / VStack 即可。
struct TodayTimelineView: View {
    var deliveries: [Delivery]
    var running: Bool
    var onRetry: ((String) -> Void)? = nil
    var retryEnabled = true
    /// 宿主按队列引擎口径（`Scheduling.nextCandidate`）算出的「下一群」任务 ID。
    /// 不传时组件只能用兜底口径，见 `fallbackNextID` 的局限性说明。
    var nextDeliveryID: String? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: Surface { Surface(scheme) }
    /// 每访问一次 `Scheduling.calendar` 都会新建一个 Calendar；这里按视图实例缓存一份，
    /// 一次渲染里的多处取时都用它（时区口径仍是 Asia/Shanghai，与排期引擎一致）。
    private let calendar = Scheduling.calendar

    // 时间线圆点要与时间胶囊的竖直中心对齐，这几个常量共同决定对齐位置。
    private let rowVerticalPadding: CGFloat = 6
    private let chipHeight: CGFloat = 20
    private let dotSize: CGFloat = 9
    private var topSegmentHeight: CGFloat { rowVerticalPadding + chipHeight / 2 - dotSize / 2 }

    /// 「下一群」优先用宿主传入的引擎结果；没传时才兜底取今天最早、且确实会被自动派发的那条：
    /// 排除一次性补草稿记录、已提交（submittedAt）与带发送凭据（evidence）的记录。
    /// 兜底不含冷却顺延与 activePlanID 过滤，多计划并发时仍可能错位，所以宿主应当显式传入（4-05）。
    private func nextID(in today: [Delivery]) -> String? {
        nextDeliveryID ?? today.first { $0.status == "queued" && !$0.isOneOff && $0.submittedAt == nil && $0.evidence.isEmpty }?.id
    }

    // 下面几个计数都吃同一份已过滤排序的 today：一次渲染只扫一遍 deliveries（4-20 同类问题）。
    private func sentCount(_ today: [Delivery]) -> Int { today.filter { TodayTimeline.sentStatuses.contains($0.status) }.count }
    /// 还会发出去的：待执行 / 正在处理（草稿与已暂停单独列，已取消与结果未知不计入）
    private func pendingCount(_ today: [Delivery]) -> Int { today.filter { ["queued", "running"].contains($0.status) }.count }
    private func reviewCount(_ today: [Delivery]) -> Int { QueueStartGate.reviewCount(today.map(\.status)) }
    /// 已暂停单独计数，否则某天只剩 blocked 时头部分项加起来对不上「今日 N 条」
    private func pausedCount(_ today: [Delivery]) -> Int { today.filter { $0.status == "blocked" }.count }

    private func hourGroups(_ today: [Delivery]) -> [HourGroup] {
        Dictionary(grouping: today) { calendar.component(.hour, from: $0.scheduled) }
            .map { HourGroup(hour: $0.key, items: $0.value) }
            .sorted { $0.hour < $1.hour }
    }

    private struct HourGroup: Identifiable {
        let hour: Int
        let items: [Delivery]
        var id: Int { hour }
    }

    var body: some View {
        // 每分钟刷新一次：跨天后「今天」的边界与各项计数自动更新
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            // 过滤 + 排序只做一次，下面的分组、头部计数与「下一群」都复用这份结果
            let today = TodayTimeline.todays(deliveries, calendar: calendar)
            let nextGroupID = nextID(in: today)
            VStack(alignment: .leading, spacing: 14) {
                metricsHeader(today)
                if today.isEmpty {
                    EmptyPanel(title: "今天没有安排发送任务",
                               symbol: "calendar.badge.clock",
                               message: "创建计划后，这里会按时间列出今天要发送的每一条任务。",
                               tint: Theme.indigo)
                } else {
                    ForEach(hourGroups(today)) { group in
                        hourSection(group, nextID: nextGroupID)
                    }
                }
            }
        }
    }

    // MARK: 头部指标行：今日 N 条 · 已发 M · 待发 K · 需关注 X

    private func metricsHeader(_ today: [Delivery]) -> some View {
        let sent = sentCount(today)
        let pending = pendingCount(today)
        let review = reviewCount(today)
        let paused = pausedCount(today)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                brandGroup(today)
                metricDot(color: Theme.green, text: "已发 \(sent)")
                metricDot(color: Theme.blue, text: "待发 \(pending)")
                metricDot(color: review > 0 ? Theme.orange : Theme.slate,
                          text: "待核对 \(review)",
                          highlight: review > 0)
                if paused > 0 {
                    metricDot(color: Theme.slate, text: "已拦截 \(paused)")
                }
                if running { runningBadge }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    brandGroup(today)
                    if running { runningBadge }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    metricDot(color: Theme.green, text: "已发 \(sent)")
                    metricDot(color: Theme.blue, text: "待发 \(pending)")
                    metricDot(color: review > 0 ? Theme.orange : Theme.slate,
                              text: "待核对 \(review)",
                              highlight: review > 0)
                    if paused > 0 {
                        metricDot(color: Theme.slate, text: "已拦截 \(paused)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func brandGroup(_ today: [Delivery]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.indigo)
            Text("今日 \(today.count) 条")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
        }
        .fixedSize()
        // 本页其余日期文案走系统时区，这里明确标注时刻表用的时区，避免同一屏两套「今天」（4-06）。
        .help("按北京时间（Asia/Shanghai）的自然日列出，与排期引擎使用同一时区")
    }

    private var runningBadge: some View {
        HStack(spacing: 5) {
            if reduceMotion {
                Circle().fill(Theme.green).frame(width: 8, height: 8)
            } else {
                PulseDot(color: Theme.green, active: true)
            }
            Text("队列运行中")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.green)
        }
        .fixedSize()
    }

    private func metricDot(color: Color, text: String, highlight: Bool = false) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: highlight ? .semibold : .medium))
                .foregroundStyle(highlight ? color : Color.primary.opacity(0.75))
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: 小时分组

    private func hourSection(_ group: HourGroup, nextID: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(group.hour) 时")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Rectangle().fill(s.hairline).frame(height: 1)
            }
            .padding(.bottom, 7)
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, job in
                timelineRow(job, isFirst: index == 0, isLast: index == group.items.count - 1, isNext: job.id == nextID)
            }
        }
    }

    // MARK: 单行（时间线圆点 + 内容卡片）

    private func timelineRow(_ job: Delivery, isFirst: Bool, isLast: Bool, isNext: Bool) -> some View {
        let done = TodayTimeline.doneStatuses.contains(job.status)
        let attention = TodayTimeline.attentionStatuses.contains(job.status)
        let railColor = isNext ? Theme.indigo.opacity(0.45) : s.hairline
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : railColor).frame(width: 2, height: topSegmentHeight)
                Circle().fill(StatusStyle.color(job.status))
                    .frame(width: dotSize, height: dotSize)
                    .overlay(Circle().strokeBorder(s.card, lineWidth: 1.5))
                Rectangle().fill(isLast ? Color.clear : railColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 9)
            rowCard(job, isNext: isNext, done: done, attention: attention)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(TodayTimeline.hhmm(job.scheduled, calendar: calendar))，\(job.channelName == SendChannel.wechat ? "微信" : "QQ")渠道，\(job.recipient)，\(job.statusName)，\(job.assets.count) 个附件")
    }

    private func rowCard(_ job: Delivery, isNext: Bool, done: Bool, attention: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let fill: Color = {
            if isNext { return Theme.indigo.opacity(scheme == .dark ? 0.16 : 0.06) }
            if attention { return Theme.orange.opacity(scheme == .dark ? 0.10 : 0.04) }
            return s.inset.opacity(0.7)
        }()
        return HStack(spacing: 8) {
            timeChip(job.scheduled, isNext: isNext)
            ChannelPill(channel: job.channelName, compact: true)
            Text(job.recipient)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if isNext {
                Pill(text: "下一群", tint: Theme.indigo, symbol: "bolt.fill", variant: .emphasis)
            }
            if job.canRequeue, let onRetry {
                Button { onRetry(job.id) } label: { Label("已拦截 · 去核对", systemImage: "checkmark.seal") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.orange)).disabled(!retryEnabled)
            } else {
            Pill(text: job.statusName, tint: StatusStyle.color(job.status), symbol: StatusStyle.symbol(job.status))
            }
            attachmentChip(job)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, rowVerticalPadding)
        .background(shape.fill(fill))
        .overlay {
            shape.strokeBorder(isNext ? Theme.indigo.opacity(0.45) : s.hairline.opacity(0.7),
                               lineWidth: isNext ? 1.2 : 0.9)
        }
        .overlay(alignment: .leading) {
            if attention {
                UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 15)
                    .fill(Theme.warm)
                    .frame(width: 3)
            }
        }
        .shadow(color: isNext ? Theme.indigo.opacity(scheme == .dark ? 0.40 : 0.18) : Color.clear,
                radius: isNext ? 7 : 0, y: 2)
        .opacity(done ? 0.55 : 1)
    }

    private func timeChip(_ date: Date, isNext: Bool) -> some View {
        Text(TodayTimeline.hhmm(date, calendar: calendar))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isNext ? Theme.indigo : Color.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.75)
            .background(
                LinearGradient(colors: [(isNext ? Theme.indigo : Color.primary).opacity(scheme == .dark ? 0.20 : 0.06),
                                        (isNext ? Theme.indigo : Color.primary).opacity(scheme == .dark ? 0.10 : 0.03)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 58, alignment: .center)
    }

    private func attachmentChip(_ job: Delivery) -> some View {
        let count = job.assets.count
        return HStack(spacing: 3) {
            Image(systemName: "paperclip").font(.system(size: 9, weight: .semibold))
            Text(count > 0 ? "\(count) 个附件" : "无附件")
                .font(.system(size: 10.5))
                .monospacedDigit()
        }
        .foregroundStyle(count > 0 ? Color.primary.opacity(0.55) : Color.primary.opacity(0.30))
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - 今日时刻表（菜单栏窄版）

/// 菜单栏弹窗用：标题行「今日 N 条 · 已发 M」+ 最多 5 条「HH:mm [渠道] 群名 · 状态」，
/// 超出显示「还有 X 条…」，没有任务显示「今天没有安排」。
/// 建议宿主先给 MenuBarExtra 加 .menuBarExtraStyle(.window) 再嵌入，显示效果最佳。
struct MenuTodaySection: View {
    @EnvironmentObject var store: Store

    private let calendar = Scheduling.calendar
    private let maxRows = 5

    /// 「下一群」与「今天」各算一次，菜单每次 store 变化都要重绘，避免反复全量过滤排序。
    private func nextID(in today: [Delivery]) -> String? {
        store.displayedQueueCandidate?.id ?? today.first { $0.status == "queued" && !$0.isOneOff && $0.submittedAt == nil && $0.evidence.isEmpty }?.id
    }

    var body: some View {
        let today = TodayTimeline.todays(store.displayedQueueJobs, calendar: calendar)
        let nextGroupID = nextID(in: today)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.indigo)
                Text("今日 \(today.count) 条 · 已发 \(today.filter { TodayTimeline.sentStatuses.contains($0.status) }.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help("按北京时间（Asia/Shanghai）的自然日列出，与排期引擎使用同一时区")
            if today.isEmpty {
                Text("今天没有安排")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(today.prefix(maxRows))) { job in
                    menuRow(job, isNext: job.id == nextGroupID)
                }
                if today.count > maxRows {
                    Text("还有 \(today.count - maxRows) 条…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func menuRow(_ job: Delivery, isNext: Bool) -> some View {
        HStack(spacing: 6) {
            Text(TodayTimeline.hhmm(job.scheduled, calendar: calendar))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isNext ? Theme.indigo : Color.primary.opacity(0.65))
            ChannelPill(channel: job.channelName, compact: true)
            Text(job.recipient)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .layoutPriority(1)
            Text("·")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.primary.opacity(0.35))
            Text(job.statusName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(StatusStyle.color(job.status))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }
}
