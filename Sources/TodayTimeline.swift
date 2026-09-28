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
    /// 需要用户关注的状态（与总览页「待人工处理」口径一致）
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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: Surface { Surface(scheme) }
    private var calendar: Calendar { Scheduling.calendar }

    // 时间线圆点要与时间胶囊的竖直中心对齐，这几个常量共同决定对齐位置。
    private let rowVerticalPadding: CGFloat = 6
    private let chipHeight: CGFloat = 20
    private let dotSize: CGFloat = 9
    private var topSegmentHeight: CGFloat { rowVerticalPadding + chipHeight / 2 - dotSize / 2 }

    private var today: [Delivery] { TodayTimeline.todays(deliveries, calendar: calendar) }
    /// 「下一个待执行」：今天按时间排序后第一条 queued（与队列引擎的取法一致）
    private var nextID: String? { today.first(where: { $0.status == "queued" })?.id }

    private var sentCount: Int { today.filter { TodayTimeline.sentStatuses.contains($0.status) }.count }
    /// 还会发出去的：待执行 / 正在处理 / 草稿 / 已暂停（已取消与结果未知不计入）
    private var pendingCount: Int { today.filter { ["queued", "running"].contains($0.status) }.count }
    private var attentionCount: Int { today.filter { TodayTimeline.attentionStatuses.contains($0.status) }.count }

    private var hourGroups: [HourGroup] {
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
            VStack(alignment: .leading, spacing: 14) {
                metricsHeader
                if today.isEmpty {
                    EmptyPanel(title: "今天没有安排发送任务",
                               symbol: "calendar.badge.clock",
                               message: "创建计划后，这里会按时间列出今天要发送的每一条任务。",
                               tint: Theme.indigo)
                } else {
                    ForEach(hourGroups) { group in
                        hourSection(group)
                    }
                }
            }
        }
    }

    // MARK: 头部指标行：今日 N 条 · 已发 M · 待发 K · 需关注 X

    private var metricsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                brandGroup
                metricDot(color: Theme.green, text: "已发 \(sentCount)")
                metricDot(color: Theme.blue, text: "待发 \(pendingCount)")
                metricDot(color: attentionCount > 0 ? Theme.orange : Theme.slate,
                          text: "需关注 \(attentionCount)",
                          highlight: attentionCount > 0)
                if running { runningBadge }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    brandGroup
                    if running { runningBadge }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    metricDot(color: Theme.green, text: "已发 \(sentCount)")
                    metricDot(color: Theme.blue, text: "待发 \(pendingCount)")
                    metricDot(color: attentionCount > 0 ? Theme.orange : Theme.slate,
                              text: "需关注 \(attentionCount)",
                              highlight: attentionCount > 0)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var brandGroup: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.indigo)
            Text("今日 \(today.count) 条")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
        }
        .fixedSize()
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

    private func hourSection(_ group: HourGroup) -> some View {
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
                timelineRow(job, isFirst: index == 0, isLast: index == group.items.count - 1)
            }
        }
    }

    // MARK: 单行（时间线圆点 + 内容卡片）

    private func timelineRow(_ job: Delivery, isFirst: Bool, isLast: Bool) -> some View {
        let isNext = job.id == nextID
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
                Button { onRetry(job.id) } label: { Label("已暂停 · 重新入队", systemImage: "arrow.clockwise") }
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

    private var calendar: Calendar { Scheduling.calendar }
    private var today: [Delivery] { TodayTimeline.todays(store.deliveries, calendar: calendar) }
    private var sentCount: Int { today.filter { TodayTimeline.sentStatuses.contains($0.status) }.count }
    private var nextID: String? { today.first(where: { $0.status == "queued" })?.id }
    private let maxRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.indigo)
                Text("今日 \(today.count) 条 · 已发 \(sentCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if today.isEmpty {
                Text("今天没有安排")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(today.prefix(maxRows))) { job in
                    menuRow(job)
                }
                if today.count > maxRows {
                    Text("还有 \(today.count - maxRows) 条…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func menuRow(_ job: Delivery) -> some View {
        let isNext = job.id == nextID
        return HStack(spacing: 6) {
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
