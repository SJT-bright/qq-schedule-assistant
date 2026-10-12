import Foundation

@main
struct QQTransitionTests {
    @MainActor
    static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw AppError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        let stale = AppError("失效句柄", axErrorCode: -25202)
        let busy = AppError("QQ 忙", axErrorCode: -25204)
        var reads = 0, checks = 0, resets = 0, stable = 0
        // 模拟成功一拍后整树替换，再要求两拍完整读取；不能把失效前的半次绑定算进去。
        try await QQTransitionRead.wait(message: "timeout", seconds: 1,
            beforeRead: { checks += 1 }, pause: {}, onTransient: { stable = 0; resets += 1 }) {
            reads += 1
            if reads == 2 { throw stale }
            if reads == 3 { throw busy }
            stable += 1
            return stable == 2
        }
        try check(reads == 5 && stable == 2 && resets == 2, "失效与无响应后重新读两拍才能绑定")
        try check(checks == reads, "每次重读前都必须重新检查前台和取消")
        for error in [AppError("已有草稿"), AppError("已离开会话"), AppError("未授权", axErrorCode: -25211)] {
            var calls = 0
            do {
                try await QQTransitionRead.wait(message: "timeout", seconds: 1,
                    beforeRead: {}, pause: {}) { calls += 1; throw error }
                throw AppError("FAIL: 应立即拒绝")
            } catch let actual as AppError {
                try check(calls == 1 && actual.message == error.message, "非临时错误立即停止：\(error.message)")
            }
        }
        var readAfterForegroundFailure = false
        do {
            try await QQTransitionRead.wait(message: "timeout", seconds: 1,
                beforeRead: { throw AppError("第三方抢前台") }, pause: {}) {
                readAfterForegroundFailure = true; return true
            }
        } catch let error as AppError {
            try check(!readAfterForegroundFailure && error.message == "第三方抢前台", "前台检查失败不能借重试继续")
        }
        let start = Date()
        var failingReads = 0
        do {
            try await QQTransitionRead.wait(message: "timeout", seconds: 0.04,
                beforeRead: {}, pause: { try await Task.sleep(nanoseconds: 10_000_000) }) {
                failingReads += 1; throw stale
            }
        } catch let error as AppError {
            try check(error.axErrorCode == -25202 && failingReads > 1 && Date().timeIntervalSince(start) < 1,
                      "持续失效有期限并保留实际错误码")
        }
        do {
            try await QQTransitionRead.wait(message: "正常读取但未就绪", seconds: 0,
                beforeRead: {}, pause: {}) { false }
        } catch let error as AppError {
            try check(error.message == "正常读取但未就绪" && error.axErrorCode == nil, "未就绪与读取失败分别报错")
        }
        let cancelled = Task { @MainActor in
            try await QQTransitionRead.wait(message: "timeout", seconds: 5,
                beforeRead: {}, pause: { try await Task.sleep(nanoseconds: 10_000_000) }) { throw busy }
        }
        cancelled.cancel()
        do { try await cancelled.value; throw AppError("FAIL: 取消应中断") }
        catch is CancellationError { try check(true, "取消中断重读，不等到期限") }
        let actualTitle = "中国石油大学克拉玛依校区2026级新生交流群"
        let windows: [ForegroundAnomaly.WindowRow] = [
            .init(ownerPID: 3, layer: 25, width: 600, height: 500),
            .init(ownerPID: 2, layer: 0, width: 800, height: 600),
            .init(ownerPID: 1, layer: 0, width: 800, height: 600)
        ]
        try check(ForegroundHandoff.firstNormalWindowPID(rows: windows, regularPIDs: [1, 2, 3]) == 2,
                  "ZCode 浮动通知不冒充普通应用前台")
        try check(ForegroundHandoff.firstNormalWindowPID(rows: [windows[0], windows[2], windows[1]], regularPIDs: [1, 2, 3]) == 1,
                  "第三方普通窗口抢前台仍能识别")
        try check(ConversationMatch.identityBound(candidates: [actualTitle], title: actualTitle), "搜索词可缩写，绑定第一条结果实际标题")
        try check(!ConversationMatch.identityBound(candidates: [actualTitle + "二群"], title: actualTitle), "进入后换到相似群仍不通过绑定")
        var imageReads = 0, imageForegroundChecks = 0
        let samples: [Result<Bool, AppError>] = [.success(true), .failure(stale), .success(true), .success(false),
                                                .success(true), .failure(busy), .success(true), .success(true)]
        try await QQTransitionRead.waitForStable(message: "图片未进入", seconds: 1,
            beforeRead: { imageForegroundChecks += 1 }, pause: {}) {
            defer { imageReads += 1 }
            return try samples[imageReads].get()
        }
        try check(imageReads == 8 && imageForegroundChecks == 8, "图片确认：失效、缺图和无响应打断连续两拍，重新检查前台")
        var imageChecksAfterPause = 0
        do {
            try await QQTransitionRead.waitForStable(message: "图片未进入", seconds: 1,
                beforeRead: { throw AppError("已停止") }, pause: {}) { imageChecksAfterPause += 1; return true }
            throw AppError("FAIL: 暂停必须停止")
        } catch let error as AppError {
            try check(error.message == "已停止" && imageChecksAfterPause == 0, "图片等待：暂停不能继续读、重复贴图或发送")
        }
        for (name, text, images, expectedImages) in [
            ("等待后图片被删", "计划正文", Optional(0), 1),
            ("额外图片", "计划正文", Optional(2), 1),
            ("图片读数缺失", "计划正文", Optional<Int>.none, 1),
            ("等待后正文被改", "别的正文", Optional(1), 1),
            ("空正文缺纯图片", "", Optional(0), 1)
        ] {
            var checkpoint = 0
            let intended = name == "空正文缺纯图片" ? "" : "计划正文"
            do {
                // 模拟之前图文已经确认，基线等待之后发生变化；新闸门必须挡在持久化提交之前。
                try await Task.sleep(nanoseconds: 1)
                try QQDraftPreflight.validate(text: text, expectedText: intended, images: images, expectedImages: expectedImages)
                checkpoint += 1
            } catch is AppError { }
            try check(checkpoint == 0, "提交前闸门：\(name)不写 submitted，不下发送指令")
        }
        try QQDraftPreflight.validate(text: "计\n划\u{200b}正文\u{fffc}", expectedText: "计划正文", images: 1, expectedImages: 1)
        try check(true, "正文和图片匹配可提交，仍兼容 QQ 换行与内联对象")
        try QQDraftPreflight.validate(text: "", expectedText: "", images: 1, expectedImages: 1)
        try check(true, "纯图片草稿一张时可以提交")
        var emptyRejected = false
        do { try QQDraftPreflight.validate(text: "", expectedText: "", images: 0, expectedImages: 0) }
        catch { emptyRejected = true }
        try check(emptyRejected, "彻底空草稿不能提交")
        try QQDraftPreflight.validate(text: "", expectedText: "", images: 0, expectedImages: 0, requireNonEmpty: false)
        try check(true, "纯图片计划第一张粘贴前允许空构造态")
        try QQDraftPreflight.validate(text: "\u{fffc}", expectedText: "", images: 1, expectedImages: 1, requireNonEmpty: false)
        try check(true, "纯图片计划追加第二张前保留第一张")
        try QQDraftPreflight.validateConstruction(text: "", expectedText: "", images: 0, confirmedImages: 0, pasteCommands: 0, toleratePending: false)
        try check(true, "构造态第一张允许空，但提交态仍拒绝")
        for count in [0, 1] {
            try QQDraftPreflight.validateConstruction(text: "计划正文", expectedText: "计划正文", images: count,
                                                       confirmedImages: 0, pasteCommands: 1, toleratePending: true)
            try check(true, "只填草稿的首张延迟出现（\(count)张）不拦住追加第二张")
        }
        for (count, tolerant) in [(2, true), (1, false)] {
            var stopped = false
            do { try QQDraftPreflight.validateConstruction(text: "计划正文", expectedText: "计划正文", images: count,
                                                           confirmedImages: 0, pasteCommands: 1, toleratePending: tolerant) }
            catch { stopped = true }
            try check(stopped, "额外图片或自动发送未确认图片不能借草稿容忍继续")
        }
        try check(QQControlTree.prunesChildren(role: "AXTextArea", description: "陈旧名称", classes: ["ProseMirror", "ExEditor-qq-msg-editor"]),
                  "控件身份扫描不遍历正在重建的 QQ 正文子树")
        try check(!QQControlTree.prunesChildren(role: "AXTextArea", description: "", classes: ["ProseMirror"])
                  && !QQControlTree.prunesChildren(role: "AXGroup", description: "", classes: ["ProseMirror", "ExEditor-qq-msg-editor"]),
                  "未知输入框和兄弟容器仍完整扫描，不降低唯一性")
        try check(QQControlTree.prunesChildren(role: "AXList", description: "群成员列表", classes: []), "成员列表不参与会话身份扫描")
        try check(!QQControlTree.prunesChildren(role: "AXSheet", description: "消息列表", classes: [])
                  && !QQControlTree.prunesChildren(role: "AXDialog", description: "会话列表", classes: []), "仅有role的弹窗也不能被列表名裁剪")
        try check(PausePoint.shouldPoll(at: PausePoint.nodeStride), "提交临界段开始前真正处理排队暂停")
        let searchWindow = CGRect(x: 540, y: 284, width: 868, height: 640)
        let compactSearch = CGRect(x: 582, y: 340, width: 60, height: 20)
        try check(QQSearchLayout.matchesAnchor(CGRect(x: 582, y: 340, width: 248, height: 20),
                                               anchor: compactSearch, window: searchWindow),
                  "搜索展开改变宽度后仍能重取原位置的匿名输入框")
        for (name, frame) in [
            ("另一个顶部输入框", CGRect(x: 900, y: 340, width: 60, height: 20)),
            ("下方聊天编辑器", CGRect(x: 582, y: 740, width: 500, height: 120)),
            ("超出窗口的输入框", CGRect(x: 582, y: 340, width: 900, height: 20)),
            ("搜索区域整体移位", CGRect(x: 582, y: 360, width: 248, height: 20)),
            ("不可见输入框", CGRect(x: 582, y: 340, width: 0, height: 20))
        ] {
            try check(!QQSearchLayout.matchesAnchor(frame, anchor: compactSearch, window: searchWindow),
                      "搜索锚定拒绝：\(name)")
        }
        try check(!QQSearchLayout.matchesAnchor(compactSearch, anchor: compactSearch, window: nil),
                  "未知搜索窗口不能借匿名框位置通过")
        print("QQ transition: \(passed) checks passed")
    }
}
