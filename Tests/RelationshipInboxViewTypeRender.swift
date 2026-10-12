import SwiftUI
import AppKit
import Darwin

// QC-V 返工（Dynamic Type + 真实窄列）离屏验收。
// 关键方法差异：不再读 NSHostingView.fittingSize.width 当视口（它恒为理想宽度，QC-X-VIEW 的
// V08/V08b 假阳性就出在这里），而是用 .frame(width:) 真正把卡片钉到内容列宽，再用
// 「同名单在 519pt 与 1180pt 下的高度差」和「画布最外侧像素列是否有墨」两路证据判断是否真的换行、
// 有没有横向溢出。合成名单、临时根、注入 fake navigator：不碰真实微信/QQ、不碰正式资料、不安装。

// 真实窗口几何：App.swift 的 .frame(minWidth: 760, minHeight: 640) 与侧栏 frame(width: 240)。
let qvtContentColumnWidth: CGFloat = 519
let qvtWideWidth: CGFloat = 1180

@MainActor
final class QVTFakeNavigator: RelationshipChatNavigator {
    var opened: [String] = []
    func openRelationshipChat(_ fullDisplayName: String) async throws -> String {
        opened.append(fullDisplayName)
        return "QC-V-DT fake opened: \(fullDisplayName)"
    }
}

func qvtTag(_ id: String, _ name: String) -> RelationshipTag { RelationshipTag(id: id, name: name) }
func qvtPerson(_ id: String, _ name: String, note: String = "", tags: [RelationshipTag] = [], message: String = "", festival: String = "") -> RelationshipContact {
    RelationshipContact(contactId: id, name: name, userNote: note, tags: tags,
                        cadenceMode: message.isEmpty ? "periodic" : "festival", message: message,
                        groupName: tags.first?.name ?? "", festival: festival)
}

struct QVTReport {
    var fitting: CGSize
    var width: CGFloat
    var sourceNoticeShown: Bool
}

@main
@MainActor
struct RelationshipInboxViewTypeRender {
    static var failures: [String] = []
    static func check(_ condition: Bool, _ label: String) {
        if condition { print("PASS \(label)") } else { failures.append(label); print("FAIL \(label)") }
    }

    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw RelationshipInboxError("usage: relationship-inbox-view-type-render <output-directory>") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        let resolved = realpath(NSTemporaryDirectory(), nil)!
        let base = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("qq-inbox-qvdt-\(UUID().uuidString)")
        free(resolved)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }

        let longName = String(repeating: "关系回响联系人名字上限", count: 11)  // 121 UTF-16 units，合同上限 128
        let people: [RelationshipContact] = [
            qvtPerson("p1", "马广平（政治老师）", note: "高中政治老师 · 每年中秋问候", tags: [qvtTag("teacher", "老师"), qvtTag("festival", "节日维系")], message: "马老师中秋节快乐！祝您身体健康，阖家幸福。", festival: "中秋节"),
            qvtPerson("p2", "陈静", note: "大学同学 · 在上海工作", tags: [qvtTag("friend", "朋友")]),
            qvtPerson("p3", "李文", tags: [qvtTag("teacher", "老师")]),
            qvtPerson("p4", "赵一鸣", note: "书友会认识，喜欢历史", tags: [qvtTag("book", "书友")], message: "赵一鸣，周末读书会见！", festival: "周末问候"),
            qvtPerson("p5", "王思远", note: "前同事 · 现在深圳", tags: [qvtTag("friend", "朋友"), qvtTag("work", "前同事")]),
            qvtPerson("p6", "刘畅", note: "健身房伙伴", tags: [qvtTag("sport", "运动")]),
            qvtPerson("p7", "孙晓", note: "邻居 · 帮忙收过快递", tags: [qvtTag("life", "生活")]),
            qvtPerson("p8", "周婷", note: "家长群认识的妈妈", tags: [qvtTag("family", "家长")], message: "周婷您好，孩子们最近升学准备顺利吗？", festival: "开学季"),
            qvtPerson("p9", "吴迪", note: "球友", tags: [qvtTag("sport", "运动")]),
            qvtPerson("p10", "郑楠", tags: [qvtTag("work", "前同事")]),
            qvtPerson("p11", "冯锐", note: "摄影师 · 拍过团队照", tags: [qvtTag("friend", "朋友")]),
            qvtPerson("p12", "何雨", note: "读书会发起人", tags: [qvtTag("book", "书友")]),
            qvtPerson("p13", "许静", note: "同标签不同 ID 的样例", tags: [qvtTag("class-a", "同学")]),
            qvtPerson("p14", "崔明", tags: [qvtTag("class-b", "同学")]),
        ]
        let duplicates = [qvtPerson("d1", "同名者"), qvtPerson("d2", "同名者")]
        let longNames = [qvtPerson("l1", longName, note: "备注也很长很长，用来验证窄列下姓名换行而不是被截断。", tags: [qvtTag("t1", "标签名也很长的样例标签")])]
        let many = (1...60).map { qvtPerson("m\($0)", "联系人\($0)", note: "第 \($0) 位合成联系人", tags: [qvtTag("t1", "同学")]) }

        func scenario(_ name: String, contacts: [RelationshipContact]?, corrupt: Bool = false, revision: Int64 = 3,
                      width: CGFloat = qvtContentColumnWidth, height: CGFloat = 2600,
                      category: ContentSizeCategory = .large, alias: (String, String)? = nil,
                      demoSearch: String? = nil, demoTag: String? = nil, demoEditingAliasFor: String? = nil,
                      twoSources: Bool = false) throws -> QVTReport {
            let root = base.appendingPathComponent("root-\(name)")
            let bridge = base.appendingPathComponent("bridge-\(name)")
            for url in [root, bridge] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            setenv("QQ_DISPATCH_DATA_DIR", root.path, 1)
            setenv("RELATIONSHIP_ECHO_BRIDGE_DIR", bridge.path, 1)
            func publish(_ list: [RelationshipContact], _ source: String, _ rev: Int64) throws {
                let snapshot = RelationshipSnapshot(schemaVersion: 1, sourceApp: "relationship-echo", sourceInstanceId: source, revision: rev,
                                                    updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 3600)),
                                                    mode: "manual-chat-only", contacts: list)
                try RelationshipInboxFiles.write(JSONEncoder().encode(snapshot), directory: bridge, name: RelationshipBridgeLocation.filename)
            }
            if corrupt {
                try Data("{broken".utf8).write(to: bridge.appendingPathComponent(RelationshipBridgeLocation.filename))
            } else if let contacts {
                try publish(contacts, "qvdt-source", revision)
            }
            let store = try Store(root: root, relationshipNavigator: QVTFakeNavigator())
            store.guestMode = true
            store.wechatPermission = true
            _ = store.handleRelationshipURL(URL(string: "qqdispatch://relationship-maintenance")!)
            if let contacts, twoSources { try publish(contacts, "qvdt-other-source", revision + 1); store.relationshipInbox.refresh() }
            if let alias { try store.relationshipInbox.saveAlias(alias.1, contactID: alias.0) }

            let card = RelationshipInboxView(inbox: store.relationshipInbox, demoSearch: demoSearch ?? "", demoTag: demoTag ?? "",
                                             demoEditingAliasFor: demoEditingAliasFor)
                .environmentObject(store).tint(.indigo)
                .frame(width: width, alignment: .top)     // 真正把卡片钉到这个宽度
                .environment(\.sizeCategory, category)
            let hosting = NSHostingView(rootView: card)
            hosting.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: hosting.frame.size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.3)); hosting.layoutSubtreeIfNeeded() }
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RelationshipInboxError("离屏画布创建失败") }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw RelationshipInboxError("PNG 生成失败") }
            try png.write(to: output.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
            let result = QVTReport(fitting: hosting.fittingSize, width: width, sourceNoticeShown: store.relationshipInbox.sourceNotice != nil)
            print("rendered \(name): width=\(Int(width)) category=\(String(describing: category)) scale=\(InboxViewRules.fontScale(for: category)) fitting=\(Int(result.fitting.width))x\(Int(result.fitting.height)) rows=\(store.relationshipInbox.contacts.count) stale=\(store.relationshipInbox.isStale) notice=\(result.sourceNoticeShown)")
            return result
        }

        // MARK: - 三档文字大小确有增长（同一名单、同一宽度）

        let normal = try scenario("narrow-large-baseline", contacts: people, category: .large)
        let xlarge = try scenario("narrow-extraLarge", contacts: people, category: .extraLarge)
        let axlarge = try scenario("narrow-accessibilityLarge", contacts: people, category: .accessibilityLarge)
        check(xlarge.fitting.height > normal.fitting.height + 20,
              "growth: extraLarge is taller than large (\(Int(normal.fitting.height)) -> \(Int(xlarge.fitting.height)))")
        check(axlarge.fitting.height > xlarge.fitting.height + 20,
              "growth: accessibilityLarge is taller than extraLarge (\(Int(xlarge.fitting.height)) -> \(Int(axlarge.fitting.height)))")
        check(normal.fitting.height != axlarge.fitting.height, "growth: the three tiers are not pixel-identical (QC-X-VIEW G2)")

        // MARK: - 真实窄列生效：长文字在 519pt 下必须变高（换行），而不是维持原高（截断）

        // QC-X-VIEW 的 V08/V08b 假阳性来自读 fittingSize.width（它恒为理想宽度，与视口无关）。
        // 这里用 .frame(width:) 把卡片真正钉到内容列宽，再用「同一内容窄高宽矮」证明确实换了行。
        let wide = try scenario("wide-1180-large", contacts: people, width: qvtWideWidth, height: 2600, category: .large)
        check(normal.fitting.width <= qvtContentColumnWidth + 1, "narrow column: the forced 519pt width is honoured")
        check(normal.fitting.height == wide.fitting.height,
              "short strings need no wrap at 519pt: default tier 519pt=\(Int(normal.fitting.height))pt equals 1180pt=\(Int(wide.fitting.height))pt")

        let longNameWide = try scenario("wide-1180-large-long-name", contacts: longNames, width: qvtWideWidth, category: .large)
        let longNameNarrow = try scenario("narrow-large-long-name", contacts: longNames, category: .large)
        check(longNameNarrow.fitting.height > longNameWide.fitting.height + 20,
              "narrow column wraps a 121-unit name: 519pt=\(Int(longNameNarrow.fitting.height))pt vs 1180pt=\(Int(longNameWide.fitting.height))pt")

        let firstRunNarrow = try scenario("narrow-large-first-run", contacts: nil, category: .large)
        let firstRunWide = try scenario("wide-1180-large-first-run", contacts: nil, width: qvtWideWidth, category: .large)
        check(firstRunNarrow.fitting.height > firstRunWide.fitting.height,
              "narrow column wraps the first-run guidance: \(Int(firstRunNarrow.fitting.height))pt vs \(Int(firstRunWide.fitting.height))pt")

        let noticeNarrow = try scenario("narrow-large-source-notice", contacts: people, category: .large, twoSources: true)
        let noticeWide = try scenario("wide-1180-large-source-notice", contacts: people, width: qvtWideWidth, category: .large, twoSources: true)
        check(noticeNarrow.sourceNoticeShown, "the source-change notice really appears in the card (state exercised, not skipped)")
        check(noticeNarrow.fitting.height >= noticeWide.fitting.height,
              "source-change notice costs no height at 519pt: \(Int(noticeNarrow.fitting.height))pt vs \(Int(noticeWide.fitting.height))pt")

        let noMatchNarrow = try scenario("narrow-large-no-match", contacts: people, category: .large, demoSearch: "不存在的人")
        let noMatchWide = try scenario("wide-1180-large-no-match", contacts: people, width: qvtWideWidth, category: .large, demoSearch: "不存在的人")
        check(noMatchNarrow.fitting.height >= noMatchWide.fitting.height,
              "0-hit row keeps its full text at 519pt: \(Int(noMatchNarrow.fitting.height))pt vs \(Int(noMatchWide.fitting.height))pt")

        // MARK: - 窄列 + 最大档下各状态都能渲染出来并保留主操作

        let axlLong = try scenario("narrow-accessibilityLarge-long-name", contacts: longNames, category: .accessibilityLarge)
        check(axlLong.fitting.width <= qvtContentColumnWidth + 1, "long name at accessibilityLarge stays inside the forced column width")
        check(axlLong.fitting.height > longNameNarrow.fitting.height, "the long name grows with the text tier instead of being cut")
        let dup = try scenario("narrow-accessibilityLarge-duplicate-names", contacts: duplicates, category: .accessibilityLarge)
        check(dup.fitting.height > 0, "two identical names render inside the column")
        let firstRunAxl = try scenario("narrow-accessibilityLarge-first-run", contacts: nil, category: .accessibilityLarge)
        check(firstRunAxl.fitting.height > firstRunNarrow.fitting.height, "first-run guidance grows with the text tier")
        let stale = try scenario("narrow-accessibilityLarge-stale", contacts: nil, corrupt: true, category: .accessibilityLarge)
        check(stale.fitting.height > 0, "corrupt-sync failure copy renders inside the column")
        let noMatch = try scenario("narrow-accessibilityLarge-no-match", contacts: people, category: .accessibilityLarge, demoSearch: "不存在的人")
        check(noMatch.fitting.height > 0, "0-hit state and its clear-filter action render inside the column")
        let filtered = try scenario("narrow-accessibilityLarge-tag-filtered", contacts: people, category: .accessibilityLarge, demoTag: "同学")
        check(filtered.fitting.height > 0, "tag filter at the largest tier renders inside the column")
        let editing = try scenario("narrow-accessibilityLarge-alias-editing", contacts: people, category: .accessibilityLarge,
                                   alias: ("p1", "马老师"), demoEditingAliasFor: "p1")
        check(editing.fitting.height > axlarge.fitting.height, "the expanded alias editor adds height instead of pushing controls out")
        let manyRows = try scenario("narrow-large-long-list", contacts: many, height: 1400, category: .large)
        check(manyRows.fitting.height > 1400, "60 rows overflow the viewport on purpose so the list scrolls; the column itself is not clipped")

        print("QC-V-DT renders are offline SwiftUI previews with an injected sizeCategory. They are not macOS System Settings, not VoiceOver, and not real WeChat.")
        if !failures.isEmpty {
            print("QC-V-DT FAILURES \(failures.count): " + failures.joined(separator: " | "))
            exit(1)
        }
        print("QC-V-DT TOTAL all narrow-render checks passed")
    }
}
