import Foundation

@main
struct CoreTests {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws { guard condition else { throw AppError("FAIL: \(name)") }; passed += 1; print("PASS: \(name)") }
    static func rejects(_ name: String, _ body: () throws -> Void) throws { do { try body() } catch { passed += 1; print("PASS: \(name)"); return }; throw AppError("FAIL: \(name) unexpectedly succeeded") }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qqdispatch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let now = Date(timeIntervalSince1970:1800000000)
        let recipients = (1...8).map{ Recipient(name:"测试群\($0)") }
        let plan = Plan(name:"测试",text:"测试文字",assetIDs:[],recipientIDs:recipients.map(\.id),starts:now.addingTimeInterval(60),days:1,times:[],intervalMinutes:30,mode:"draft")
        let jobs = try Scheduling.expand(plan,recipients:recipients,assets:[],now:now)
        try check(jobs.count == 8,"八群生成八条任务")
        try check(jobs[7].scheduled.timeIntervalSince(jobs[0].scheduled) == 3.5*3600,"每半小时错峰，末群为首群后3.5小时")
        try check(jobs.map(\.recipient) == recipients.map(\.name),"保留名单顺序")
        var renameArchive = Archive(recipients: recipients, assets: [], plans: [plan], deliveries: jobs, settings: Settings(savedText: ""))
        renameArchive.deliveries[0].recipientID = nil // Existing databases have name snapshots only.
        var historical = jobs[0]; historical.id = "history"; historical.status = "verified"; historical.evidence = "receipt"
        renameArchive.deliveries.append(historical)
        var otherChannel = jobs[0]; otherChannel.id = "wechat"; otherChannel.channel = SendChannel.wechat; otherChannel.recipientID = nil
        renameArchive.deliveries.append(otherChannel)
        let resolved = try RecipientRename.resolve(renameArchive.deliveries[0], recipients: recipients)
        let renamed = try RecipientRename.renamed(renameArchive, id: resolved, name: "  正确群名  ")
        try check(renamed.recipients[0].name == "正确群名" && renamed.deliveries[0].recipient == "正确群名", "队列改名同步名单并兼容旧任务")
        try check(renamed.deliveries[0].recipientID == recipients[0].id, "旧任务改名建立稳定关联")
        let renamedAgain = try RecipientRename.renamed(renamed, id: recipients[0].id, name: "再次改名")
        try check(renamedAgain.deliveries[0].recipient == "再次改名", "名单再次改名同步关联任务")
        try check(renamed.deliveries[8].recipient == historical.recipient && renamed.deliveries[8].evidence == "receipt" && renamed.deliveries[9].recipient == otherChannel.recipient, "改名保留历史凭据且不串渠道")
        try check(renamed.deliveries[0].scheduled == jobs[0].scheduled && renamed.deliveries[0].text == jobs[0].text && renamed.deliveries[0].status == jobs[0].status, "改名不改变排期正文与状态")
        try rejects("拒绝空白群名") { _ = try RecipientRename.renamed(renameArchive, id: resolved, name: " ") }
        try rejects("拒绝同渠道重名") { _ = try RecipientRename.renamed(renameArchive, id: resolved, name: recipients[1].name) }
        for status in ["running", "draft", "submitted", "uncertain"] {
            var pending = renameArchive; pending.deliveries[0].status = status
            try rejects("\(status) 任务禁止修改关联群名") { _ = try RecipientRename.renamed(pending, id: resolved, name: "新名") }
        }
        let renameDB = try Database(root: root.appendingPathComponent("rename"))
        try renameDB.save(renamedAgain)
        try check(try renameDB.load("deliveries", as: Delivery.self)[0].recipient == "再次改名" && renameDB.load("recipients", as: Recipient.self)[0].name == "再次改名", "改名同步持久化可重载")
        var sixPlan = plan; sixPlan.recipientIDs = Array(recipients.prefix(6).map(\.id)); sixPlan.mode = "automatic"
        var six = try Scheduling.expand(sixPlan,recipients:recipients,assets:[],now:now)
        try check(six.count == 6 && six[5].scheduled.timeIntervalSince(six[0].scheduled) == 150 * 60,"六群30分钟排期，末群为150分钟后")
        var varied = sixPlan; varied.recipientGaps = [recipients[1].id:60,recipients[3].id:45]
        try check(try Scheduling.offsets(varied) == [0,60,90,135,165,195],"逐群间隔按累计时间生成")
        let variedJobs = try Scheduling.expand(varied,recipients:recipients,assets:[],now:now)
        try check(variedJobs.last!.scheduled.timeIntervalSince(variedJobs.first!.scheduled) == 195*60,"逐群排期总跨度195分钟")
        var fewer = varied; fewer.recipientIDs.remove(at:1)
        try check(try Scheduling.offsets(fewer) == [0,30,75,105,135],"取消群后重新计算跨度，不保留移除群的延迟")
        try rejects("非法逐群间隔拒绝") { var bad = varied; bad.recipientGaps = [recipients[1].id:0]; _ = try Scheduling.offsets(bad) }
        var fullDay = sixPlan; fullDay.starts = Scheduling.calendar.startOfDay(for:now).addingTimeInterval(86400); fullDay.times = stride(from:0,to:24,by:3).map { String(format:"%02d:00",$0) }; fullDay.days = 2
        let fullDayJobs = try Scheduling.expand(fullDay,recipients:recipients,assets:[],now:now)
        try check(fullDayJobs.count == 96,"六群全天八轮两天自动生成96条")
        try check(fullDayJobs.last!.scheduled.timeIntervalSince(fullDayJobs.first!.scheduled) == 47.5*3600,"跨日总跨度47.5小时")
        try rejects("增加群导致全天轮次重叠时拒绝") { var crowded = fullDay; crowded.recipientIDs = recipients.map(\.id); _ = try Scheduling.expand(crowded,recipients:recipients,assets:[],now:now) }
        try check(try Scheduling.times((0..<24).map { String(format:"%02d:00",$0) }.joined(separator:",")).count == 24,"支持24个自定义整点轮次")
        try check(Scheduling.duration(150) == "2 小时 30 分钟" && Scheduling.duration(180) == "3 小时","跨度显示小时与分钟")
        let legacyData = try JSONEncoder().encode(sixPlan)
        try check(try JSONDecoder().decode(Plan.self,from:legacyData).recipientGaps == nil,"旧计划无需逐群字段即可读取")
        let legacySettings = Data("{\"globalGapMinutes\":30,\"savedText\":\"旧文案\"}".utf8)
        try check(try JSONDecoder().decode(Settings.self,from:legacySettings).restorePreviousApp == nil,"旧设置兼容恢复窗口可选字段")
        let firstTime = six[0].scheduled
        for i in 0..<6 {
            let time = firstTime.addingTimeInterval(Double(i * 1800))
            try check(Scheduling.eligible(six,now:time,gap:30,planID:sixPlan.id)?.id == six[i].id,"六群自动推进第\(i+1)条，无需确认")
            six[i].status = "verified"; six[i].submittedAt = time
        }
        try check(Scheduling.eligible(six,now:firstTime.addingTimeInterval(20000),gap:30,planID:sixPlan.id) == nil,"本计划完成后不重发")
        var foreign = jobs[0]; foreign.planID = "another-plan"; foreign.scheduled = now
        try check(Scheduling.eligible([foreign] + jobs,now:now.addingTimeInterval(61),gap:30,planID:plan.id)?.id == jobs[0].id,"只启动所选计划，不启动其他排期")
        foreign.status = "verified"; foreign.submittedAt = now
        try check(Scheduling.eligible([foreign] + jobs,now:now.addingTimeInterval(61),gap:30,planID:plan.id) == nil,"分计划启动仍遵守其他计划发送冷却")
        var daily = plan; daily.starts = Scheduling.calendar.startOfDay(for:now).addingTimeInterval(86400); daily.days = 2; daily.times = ["09:00","14:00","19:00"]
        let dailyJobs = try Scheduling.expand(daily,recipients:recipients,assets:[],now:now)
        try check(dailyJobs.count == 48,"两天三轮八群=48条")
        try check(Scheduling.calendar.component(.hour,from:dailyJobs[0].scheduled) == 9,"排程采用北京时间")
        try rejects("重叠轮次拒绝") { var p = daily; p.times = ["09:00","10:00"]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("重复轮次拒绝") { _ = try Scheduling.times("09:00,09:00") }
        try rejects("错误时间拒绝") { _ = try Scheduling.times("24:60") }
        try rejects("空时间拒绝") { _ = try Scheduling.times("") }
        try rejects("过去日期不集中补发") { var p = plan; p.starts = now.addingTimeInterval(-1000); _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("空收件人拒绝") { var p = plan; p.recipientIDs=[]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("空内容拒绝") { var p=plan;p.text=" "; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("不存在附件拒绝") { var p=plan;p.assetIDs=["missing"]; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try rejects("停用收件人拒绝") { var rs=recipients;rs[0].enabled=false;_ = try Scheduling.expand(plan,recipients:rs,assets:[],now:now) }
        try check(Scheduling.eligible(jobs,now:now,gap:30) == nil,"未到时不发送")
        try check(Scheduling.eligible(jobs,now:now.addingTimeInterval(61),gap:30)?.id == jobs[0].id,"到时只选首条")
        var active=jobs;active[0].status="verified";active[0].started=now
        try check(Scheduling.eligible(active,now:now.addingTimeInterval(100),gap:30) == nil,"全局间隔有效")
        var failed = active; failed[0].status = "blocked"
        try check(Scheduling.lastSendActivity(failed) == nil,"提交前控件失败不占用发送冷却")
        failed[0].submittedAt = now
        try check(Scheduling.lastSendActivity(failed) == now,"存在提交检查点时保留冷却")
        failed[0].status = "cancelled"
        try check(Scheduling.lastSendActivity(failed) == now,"取消任务不能清除已提交冷却")
        for status in ["running","draft","submitted","uncertain"] { var list=jobs;list[0].status=status; try check(Scheduling.eligible(list,now:now.addingTimeInterval(10000),gap:30) == nil,"\(status) 阻止继续发送") }
        active[0].status="cancelled";active[0].started=nil
        try check(Scheduling.eligible(active,now:now.addingTimeInterval(5000),gap:30)?.id == jobs[1].id,"取消任务不会重发")
        for status in ["running", "submitted"] { var list=jobs; list[0].status=status; let recovered=Scheduling.recovered(list); try check(recovered[0].status == "uncertain", "崩溃恢复 \(status) 转待核对"); try check(Scheduling.eligible(recovered,now:now.addingTimeInterval(10000),gap:30) == nil,"重开后不重复发送 \(status)") }
        try rejects("未知模式拒绝") { var p=plan;p.mode="invalid"; _ = try Scheduling.expand(p,recipients:recipients,assets:[],now:now) }
        try check(ComposerContent.isEmpty("\n",descendants:[]),"QQ 空换行属于空草稿")
        try check(ComposerContent.isEmpty("\u{200b}\n",descendants:[ComposerNode(role:"AXGroup"),ComposerNode(role:"AXStaticText",value:"\n")]),"空白段落节点不误判草稿")
        try check(!ComposerContent.isEmpty("正文",descendants:[]),"已有文字必须保留")
        try check(!ComposerContent.isEmpty("\u{fffc}",descendants:[]),"附件占位符不能当成空内容")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXImage")]),"图片节点不能当成空内容")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXGroup",description:"附件.pdf")]),"带文件描述的节点必须保留")
        try check(!ComposerContent.isEmpty("",descendants:[ComposerNode(role:"AXUnknown")]),"未知节点不默认为空草稿")
        try check(ComposerContent.attachmentCount("正文",imageNodes:0) == 0,"纯文字不计为图片")
        try check(ComposerContent.attachmentCount("\u{fffc}\n正文",imageNodes:1) == 1,"图片节点与占位符不重复计数")
        try check(ComposerContent.attachmentCount("\u{fffc}\u{fffc}\n正文",imageNodes:0) == 2,"QQ 只暴露占位符时仍可识别多图")
        try check(ComposerContent.attachmentCount("正文",imageNodes:2) == 2,"QQ 只暴露图片节点时仍可识别多图")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 8, composerImagesNow: 9) == 1,"图片作为输入框同级预览时也能确认进入草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 8, composerImagesNow: 8) == 0,"工具栏已有图标不能误认为新配图")
        // QQ 实测布局：AXTextArea 的父节点只有输入框自己，配图预览条在带「会话」工具栏的那一层
        try check(ComposerRegion.previewLevel(childRoles: [["AXTextArea"],["AXGroup"],["AXGroup","AXGroup","AXToolbar","AXGroup","AXGroup"]]) == 2,"配图预览区取带工具栏的那一层，不是输入框父节点")
        try check(ComposerRegion.previewLevel(childRoles: [["AXTextArea"],["AXGroup"]]) == 0,"认不出工具栏时回落到输入框父节点，不外扩到消息列表")
        try check(ComposerRegion.previewLevel(childRoles: []) == 0,"读不到祖先链时不误报预览区")
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",0),("AXToolbar",11),("AXGroup",1)]) == 1,"工具栏 11 个图标不计入配图")
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",2),("AXToolbar",11)]) == 2,"预览条里的两张图都计入")
        try check(ComposerRegion.previewImageCount(children: []) == 0,"空预览区计 0")
        // 空草稿守卫与配图确认必须同一口径，否则残留图片会被折进基线、跟计划图片一起发出去
        try check(ComposerRegion.previewImageCount(children: [("AXGroup",1),("AXToolbar",11),("AXGroup",0)]) == 1,"预览区里的残留图片要在填写草稿前就被拒绝")
        try check(ComposerRegion.previewImageCount(children: [("AXToolbar",11)]) == 0,"只有工具栏图标时仍算空草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 1, composerImagesNow: 2) == 1,"残留图片一旦被当基线，差值就只看得见本次新粘贴的那张")
        // 结构快照只用于失败时交代现场：节点/按钮/高度变化一律不构成图片证据
        let plainDraft = ComposerSnapshot(images: 0, buttons: 2, nodes: 10, editorHeight: 167)
        let churnedDraft = ComposerSnapshot(images: 0, buttons: 5, nodes: 40, editorHeight: 400)
        try check(plainDraft != churnedDraft,"QQ 异步重渲染确实会让结构数字自己变化")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: plainDraft.images, composerImagesNow: churnedDraft.images) == 0,"结构数字涨了但图片数为 0，仍不得确认图片进草稿")
        try check(ComposerContent.attachmentCount("正文没有占位符", imageNodes: 0) == 0,"没有 AXImage 也没有 U+FFFC 时不得凭空计为图片")
        // 失败现场只如实描述：新增 class 与字符数差值都不参与“能不能发”的判定
        try check(ComposerDiagnostic.newClasses(before: ["ProseMirror","is-empty"], now: ["ProseMirror","image-wrap","q-icon"]) == ["image-wrap","q-icon"],"blocked 记录里列出粘贴后新增的 DOM class")
        try check(ComposerDiagnostic.newClasses(before: ["a","b"], now: ["a","b"]).isEmpty,"没有新增 class 时如实写空，不编造线索")
        try check(ComposerDiagnostic.extraCharacters(textLength: 18, characterCount: 19) == 1,"字符数比正文多 1 时如实报告多出 1")
        try check(ComposerDiagnostic.extraCharacters(textLength: 18, characterCount: 18) == 0,"正文与字符数一致时不算多出内容")
        try check(ComposerDiagnostic.extraCharacters(textLength: 10, characterCount: -1) == 0,"读不到字符数时不编造差值")
        try check(SendGate.blockedByModal(modalPresent: true, sendButtonsOutsideComposer: 0),"有模态容器时绝不触发发送")
        try check(SendGate.blockedByModal(modalPresent: false, sendButtonsOutsideComposer: 1),"输入区之外出现「发送」按钮（如“发送到我的手机”确认框）时不触发发送")
        try check(!SendGate.blockedByModal(modalPresent: false, sendButtonsOutsideComposer: 0),"没有弹窗时才允许发出唯一一条发送指令")
        try check(SendGate.isSendConfirmationButton("发送(1)") && SendGate.isSendConfirmationButton("Send(2)"),"带数量的弹窗发送按钮也必须拦截")
        try check(!SendGate.isSendConfirmationButton("发送到桌面"),"其他带发送字样的工具按钮不能误判为弹窗确认")
        try check(ComposerImageSignal.newImageClasses(before: ["ProseMirror"], now: ["ProseMirror", "editor-el--inline-block"]) == ["editor-el--inline-block"],"实测 QQ 群聊图片缩略图的内联 class 可确认入草稿")
        try check(ComposerImageSignal.newImageClasses(before: ["ProseMirror","q-icon","is-empty"], now: ["ProseMirror","q-icon","msg-image"]) == ["msg-image"],"粘贴后新出现的图片专属 class 才算图片证据")
        try check(ComposerImageSignal.newImageClasses(before: [], now: ["q-svg-icon","expression-panel","sticker-wrapper","avatar"]).isEmpty,"工具栏、表情面板、头像这些本来就有的 class 不算图片证据")
        try check(ComposerImageSignal.newImageClasses(before: ["a"], now: ["a"]).isEmpty,"class 没有新增时不编造图片证据")
        try check(ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: 469, charactersAfter: 470),"正文一字未改而字符数多 1，算内联对象出现")
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: false, charactersBefore: 469, charactersAfter: 500),"正文变了就不算：多出来的可能是文字")
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: 469, charactersAfter: 469),"字符数没变说明没有新的内联对象")
        try check(!ComposerImageSignal.inlineObjectAdded(textUnchanged: true, charactersBefore: -1, charactersAfter: 470),"读不到字符数时不做推断")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 0, composerImagesNow: 1) == 1,"新布局下粘贴一张图即可确认进入草稿")
        try check(ComposerContent.imageCount(editorCount: 0, composerImagesBefore: 0, composerImagesNow: 3) == 3,"新布局下粘贴三张图按张数确认")
        try check(SendAttempt.isSendButtonLabel("发送"),"标题为「发送」的按钮可作为发送入口")
        try check(SendAttempt.isSendButtonLabel(" 发送 "),"发送按钮标题允许首尾空白")
        try check(!SendAttempt.isSendButtonLabel("发送到桌面"),"相邻字样不误认为发送按钮")
        try check(!SendAttempt.isSendButtonLabel("表情"),"工具栏按钮不当作发送按钮")
        try check(SendTrigger.allCases.count == 2,"只有发送按钮与 Return 两种触发手段，没有补发档位")
        try check(SendAttempt.firstTrigger(buttonFound: true) == .sendButton,"能认准按钮时优先点发送按钮")
        try check(SendAttempt.firstTrigger(buttonFound: false) == .returnKey,"认不出按钮时只按一次 Return")
        try check(!SendAttempt.allowsSecondTrigger,"任何核验结果都不解锁第二次发送指令，避免重复发送")
        try check(SendAttempt.describe(attempted: [.sendButton]) == "QQ 发送按钮","待核对记录如实交代发出过的唯一发送指令")
        try check(SendAttempt.describe(attempted: []) == "未触发任何发送指令","未触发时不谎称已发送")
        let source = root.appendingPathComponent("图片 空格 测试.png")
        try Data("file fixture".utf8).write(to:source)
        let dataRoot=root.appendingPathComponent("library")
        let templates = [TextTemplate(text:"第一条标题\n" + String(repeating:"长文案内容。",count:80)),TextTemplate(text:"第二条标题\n第二条正文")]
        try check(templates[0].title == "第一条标题","长文案标题只取第一行")
        try check(templates[0].id != templates[1].id,"每个备选文案独立标识")
        var asset: Asset!
        do {
            let db=try Database(root:dataRoot);asset=try db.importAsset(source)
            var imagePlan = plan; imagePlan.assetIDs = [asset.id]
            let imageJobs = try Scheduling.expand(imagePlan,recipients:recipients,assets:[asset],now:now)
            try check(imageJobs.allSatisfy { $0.assets == [asset] && $0.text == plan.text },"每个群任务包含同一图文快照")
            imagePlan.text = ""
            try check(try Scheduling.expand(imagePlan,recipients:recipients,assets:[asset],now:now).count == 8,"支持纯图片计划")
            try check(FileManager.default.fileExists(atPath:db.url(for:asset).path),"附件复制进持久资料库")
            try check(try Database.digest(source) == asset.sha256,"SHA256 校验")
            try FileManager.default.removeItem(at:source)
            try check(try Database.digest(db.url(for:asset)) == asset.sha256,"原文件删除后素材仍完整")
            var withFile=jobs;withFile[0].assets=[asset]
            var settings = Settings(); settings.textTemplates = templates
            let archive=Archive(recipients:recipients,assets:[asset],plans:[plan],deliveries:withFile,settings:settings)
            try db.save(archive)
            var invalid=archive;invalid.recipients.append(recipients[0])
            try rejects("事务写入失败回滚") { try db.save(invalid) }
            try check(try db.load("recipients",as:Recipient.self).count == 8,"失败后原数据保持完整")
            try check(try db.load("deliveries",as:Delivery.self).count == 8,"发送记录持久化")
            try db.backup(to:root.appendingPathComponent("backup"))
        }
        let reopened=try Database(root:dataRoot)
        try check(try reopened.load("settings",as:Settings.self).first?.textTemplates == templates,"重开数据库保留多条完整长文案")
        try check(try reopened.load("recipients",as:Recipient.self).map(\.name) == recipients.map(\.name),"数据库重开保留顺序")
        try check(try reopened.load("deliveries",as:Delivery.self)[0].assets[0].sha256 == asset.sha256,"任务保存附件快照")
        let backup=try Database(root:root.appendingPathComponent("backup"))
        try check(try backup.load("settings",as:Settings.self).first?.textTemplates == templates,"数据库备份包含全部备选文案")
        try check(try backup.load("plans",as:Plan.self).count == 1,"在线SQLite备份可打开")
        try check(try Database.digest(backup.url(for:asset)) == asset.sha256,"备份包含素材")
        // 渠道字段（QQ / 微信双通道）
        let legacyRecipientJSON = Data("{\"id\":\"x\",\"name\":\"旧群\",\"note\":\"\",\"enabled\":true}".utf8)
        try check(try JSONDecoder().decode(Recipient.self,from:legacyRecipientJSON).channelName == "qq","旧名单无渠道字段默认 QQ")
        var wxRecipients = recipients
        wxRecipients[0].channel = SendChannel.wechat
        var mixed = sixPlan; mixed.recipientIDs = [wxRecipients[0].id, wxRecipients[1].id]
        let mixedJobs = try Scheduling.expand(mixed,recipients:wxRecipients,assets:[],now:now)
        try check(mixedJobs[0].channelName == "wechat" && mixedJobs[1].channelName == "qq","任务继承收件人渠道")
        try check(SendChannel.qq == "qq" && SendChannel.wechat == "wechat","渠道常量")
        // Regression: retire only the legacy pre-execution deadline failure.
        var expired = jobs[0]
        expired.status = "blocked"
        expired.detail = "已错过计划时间超过 15 分钟，不集中补发。请点击重新排期"
        expired.finished = now
        expired.scheduled = now.addingTimeInterval(-86400)
        let recoveredExpired = Scheduling.recovered([expired])[0]
        try check(recoveredExpired.status == "queued" && recoveredExpired.finished == nil, "旧版超时任务恢复待执行")
        try check(recoveredExpired.scheduled == expired.scheduled && recoveredExpired.text == expired.text && recoveredExpired.id == expired.id, "恢复保持排期顺序和消息快照")
        try check(Scheduling.eligible([recoveredExpired], now: now, gap: 30)?.id == expired.id, "过期一天的任务仍可调度，不逐条冻结")
        var attempted = expired; attempted.started = now
        try check(Scheduling.recovered([attempted])[0].status == "blocked", "实际执行过的任务不自动恢复")
        var submittedExpired = expired; submittedExpired.submittedAt = now
        try check(Scheduling.recovered([submittedExpired])[0].status == "blocked", "有提交时间的任务不自动恢复")
        var focused = expired; focused.detail = "步骤：直接聚焦搜索框：测试群\n前台已切换到其他应用，操作暂停"
        try check(Scheduling.recovered([focused])[0].status == "blocked", "前台中断不自动恢复")
        try check(focused.attentionReason == "前台已切换到其他应用，操作暂停", "原因展示实际错误而非执行步骤")
        try check(Scheduling.recovered([recoveredExpired])[0].detail == recoveredExpired.detail, "超时恢复可重复启动且不重复修改")
        var lastSent = jobs[1]; lastSent.status = "verified"; lastSent.submittedAt = now.addingTimeInterval(-60)
        try check(Scheduling.eligible([lastSent, recoveredExpired], now: now, gap: 30) == nil, "恢复过期任务仍遵守全局冷却")
        try check(Scheduling.eligible([lastSent, recoveredExpired], now: now.addingTimeInterval(1740), gap: 30)?.id == expired.id, "冷却结束后恢复任务可执行")
        var paused = jobs[0]; paused.status = "blocked"; paused.started = now; paused.detail = "前台切换"
        let retried = Scheduling.requeued([paused], ids: [paused.id], now: now, gap: 30)[0]
        try check(retried.status == "queued" && retried.started == nil && retried.id == paused.id, "点击暂停重入队，不创建重复任务")
        try check(retried.text == paused.text && retried.recipient == paused.recipient, "重入队保持收件人和内容")
        var risky = paused; risky.submittedAt = now
        try check(Scheduling.requeued([risky], ids: [risky.id], now: now, gap: 30)[0].status == "blocked", "有提交记录的暂停任务不直接重试")
        var unsure = paused; unsure.status = "uncertain"
        try check(Scheduling.requeued([unsure], ids: [unsure.id], now: now, gap: 30)[0].status == "uncertain", "结果待核对任务不直接重试")
        let repeated = Scheduling.requeued([retried], ids: [retried.id], now: now.addingTimeInterval(60), gap: 30)[0]
        try check(repeated.scheduled == retried.scheduled, "重复点击不重复改动已入队任务")
        var addPlan = sixPlan; addPlan.recipientIDs = Array(recipients.prefix(6).map(\.id))
        let extra = try Scheduling.additionalDeliveries(plan: addPlan, recipients: recipients, jobs: six, now: now, gap: 30)
        try check(extra.count == 2, "六群计划从八群名单只追加两群")
        try check(extra[0].scheduled > six.last!.scheduled && extra[1].scheduled.timeIntervalSince(extra[0].scheduled) >= 1800, "扩充排在队尾且保留发送间隔")
        try check(extra.allSatisfy { $0.text == six.last!.text && $0.assets == six.last!.assets && $0.status == "queued" && $0.started == nil && $0.submittedAt == nil }, "追加沿用图文且不继承执行状态")
        try check(try Scheduling.additionalDeliveries(plan: addPlan, recipients: recipients, jobs: six + extra, now: now, gap: 30).isEmpty, "扩充相同群不重复创建任务")
        // 发送顺序：QQ 与微信两套隔离排序
        var channelMix = recipients
        channelMix[0].channel = SendChannel.wechat
        channelMix[2].channel = SendChannel.wechat
        let qqMovedDown = RecipientList.moved(channelMix, id: channelMix[1].id, offset: 1)
        try check(qqMovedDown.map(\.name) == ["测试群1","测试群4","测试群3","测试群2","测试群5","测试群6","测试群7","测试群8"],"同渠道下移只与相邻同渠道成员交换")
        try check(RecipientList.filtered(qqMovedDown, channel: SendChannel.qq).map(\.name) == ["测试群4","测试群2","测试群5","测试群6","测试群7","测试群8"],"QQ 子序列按移动后排序")
        try check(RecipientList.filtered(qqMovedDown, channel: SendChannel.wechat).map(\.name) == ["测试群1","测试群3"],"移动 QQ 成员不影响微信顺序")
        let wxMovedUp = RecipientList.moved(channelMix, id: channelMix[2].id, offset: -1)
        try check(RecipientList.filtered(wxMovedUp, channel: SendChannel.wechat).map(\.name) == ["测试群3","测试群1"],"微信子序列内上移")
        try check(RecipientList.filtered(wxMovedUp, channel: SendChannel.qq).map(\.name) == ["测试群2","测试群4","测试群5","测试群6","测试群7","测试群8"],"移动微信成员不影响 QQ 顺序")
        try check(RecipientList.moved(channelMix, id: channelMix[0].id, offset: -1) == channelMix,"渠道首行上移返回原数组")
        try check(RecipientList.moved(channelMix, id: channelMix[7].id, offset: 1) == channelMix,"渠道末行下移返回原数组")
        try check(RecipientList.moved(channelMix, id: "不存在的 id", offset: 1) == channelMix,"未知 id 返回原数组")
        try check(RecipientList.moved(channelMix, id: channelMix[1].id, offset: 0) == channelMix,"offset 为 0 返回原数组")
        try check(RecipientList.filtered([Recipient(name:"旧群"), channelMix[0]], channel: SendChannel.qq).map(\.name) == ["旧群"],"channel 为 nil 的旧数据按 QQ 归类")
        // 会员纯逻辑：LicenseState 四态边界
        try check(LicenseState.resolve(profile:nil,now:now,lastValidated:nil) == .loggedOut,"无档案即未登录")
        let member = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(3600),daysLeft:1,source:"paid")
        try check(LicenseState.resolve(profile:member,now:now,lastValidated:nil) == .active(member),"到期前为 active，与校验时间无关")
        try check(LicenseState.resolve(profile:member,now:member.paidUntil!,lastValidated:member.paidUntil!) == .grace(member),"到期时刻（不晚于 now）且刚校验过进入宽限")
        let overdue = MembershipProfile(account:"demo@local",planLabel:"月卡",paidUntil:now.addingTimeInterval(-3600),daysLeft:0,source:"paid")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:now.addingTimeInterval(-71*3600)) == .grace(overdue),"过期但 72 小时内校验过为 grace")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:now.addingTimeInterval(-73*3600)) == .expired(overdue),"超过 72 小时未校验为 expired")
        try check(LicenseState.resolve(profile:overdue,now:now,lastValidated:nil) == .expired(overdue),"过期且从无校验时间为 expired")
        try check(LicenseState.resolve(profile:MembershipProfile(account:"a",planLabel:"试用",paidUntil:nil,daysLeft:nil,source:"trial"),now:now,lastValidated:nil).isExpired,"无到期日的档案按过期判定")
        // 会员纯逻辑：MembershipMath.extend
        let futureDue = now.addingTimeInterval(5*86400)
        try check(MembershipMath.extend(from:futureDue,now:now,days:30) == futureDue.addingTimeInterval(30*86400),"未到期续费从到期日顺延 30 天")
        let pastDue = now.addingTimeInterval(-3*86400)
        try check(MembershipMath.extend(from:pastDue,now:now,days:90) == now.addingTimeInterval(90*86400),"已过期续费从当前时间起算 90 天")
        try check(MembershipMath.extend(from:nil,now:now,days:365) == now.addingTimeInterval(365*86400),"无到期日从当前时间起算 365 天")
        // 会员纯逻辑：内置兜底套餐
        try check(PlanCatalog.fallback.count == 3,"兜底套餐共三档")
        try check(PlanCatalog.fallback[0].priceFen == 990 && PlanCatalog.fallback[0].days == 30,"月卡 990 分 / 30 天")
        try check(PlanCatalog.fallback[1].priceFen == 2690 && PlanCatalog.fallback[1].days == 90,"季卡 2690 分 / 90 天")
        try check(PlanCatalog.fallback[2].priceFen == 9900 && PlanCatalog.fallback[2].days == 365,"年卡 9900 分 / 365 天")
        try check(PlanCatalog.fallback.map(\.priceDisplay) == ["¥9.90","¥26.90","¥99"],"会员优惠价显示")
        // 会员档案：snake_case / camelCase 双兼容 + ISO8601
        let snakeJSON = Data("{\"account\":\"u1\",\"plan_label\":\"月卡\",\"paid_until\":\"2026-10-01T08:09:10Z\",\"days_left\":6,\"source\":\"trial\"}".utf8)
        let snakeProfile = try JSONDecoder().decode(MembershipProfile.self,from:snakeJSON)
        try check(snakeProfile.account == "u1" && snakeProfile.planLabel == "月卡" && snakeProfile.source == "trial","会员档案兼容 snake_case 字段")
        try check(snakeProfile.daysLeft == 6 && snakeProfile.paidUntil != nil,"days_left 与 ISO8601 paid_until 解析")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u2\",\"planLabel\":\"年卡\",\"source\":\"paid\"}".utf8)).planLabel == "年卡","会员档案兼容 camelCase 字段")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u3\",\"plan_label\":\"月卡\",\"paid_until\":\"2026-10-01T08:09:10.500Z\"}".utf8)).paidUntil != nil,"带小数秒的 ISO8601 也能解析")
        // 服务端 paid_until 是 Unix 秒数值（0=未开通），必须按 1970 纪元解析
        let unixFixed = 1798458000.0   // 2026-10-01 前后的 Unix 秒
        let unixProfile = try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u4\",\"paid_until\":\(Int(unixFixed)),\"source\":\"paid\"}".utf8))
        try check(unixProfile.paidUntil != nil && abs(unixProfile.paidUntil!.timeIntervalSince1970 - unixFixed) < 1,"服务端 Unix 秒 paid_until 按 1970 纪元解析")
        try check(abs(unixProfile.paidUntil!.timeIntervalSince(Date(timeIntervalSince1970: unixFixed))) < 1,"Unix 秒解析不偏移 31 年")
        try check(try JSONDecoder().decode(MembershipProfile.self,from:Data("{\"account\":\"u5\",\"paid_until\":0}".utf8)).paidUntil == nil,"paid_until=0 视为未开通")
        var memberSettings = Settings(); memberSettings.licenseProfile = member
        try check(try JSONDecoder().decode(Settings.self,from:JSONEncoder().encode(memberSettings)).licenseProfile == member,"会员档案经设置存取保持一致")
        let legacyMemberSettings = try JSONDecoder().decode(Settings.self,from:legacySettings)
        try check(legacyMemberSettings.licenseProfile == nil && legacyMemberSettings.licenseServerURL == nil,"旧设置缺省会员字段可读")
        var scoped = Settings(savedText: "旧文案")
        scoped.textTemplates = [TextTemplate(text: "旧文案")]
        scoped.preferredRecipientIDs = ["g1", "g2"]
        scoped.preferredAssetIDs = ["a1"]
        scoped.prepareWorkspaces(recipientIDs: ["g1", "g2", "g3"])
        try check(scoped.broadcastWorkspaces?.count == 3, "旧数据迁移为默认、推广、通知三个空间")
        try check(scoped.broadcastWorkspaces?.first?.draft.recipientIDs == ["g1", "g2"], "迁移保留旧选群，不自动全选")
        let promotionID = scoped.broadcastWorkspaces![1].id
        let noticeID = scoped.broadcastWorkspaces![2].id
        try scoped.switchWorkspace(promotionID)
        try check(scoped.savedText.isEmpty && scoped.preferredRecipientIDs == [] && scoped.preferredAssetIDs == [], "推广空间不会继承默认空间内容和群")
        scoped.textTemplates = [TextTemplate(text: "推广文案")]
        scoped.broadcastWorkspaces![1].draft.text = "推广文案"
        scoped.broadcastWorkspaces![1].draft.recipientIDs = ["g3"]
        scoped.broadcastWorkspaces![1].draft.assetIDs = ["a2"]
        try scoped.switchWorkspace(noticeID)
        try check(scoped.textTemplates == [] && scoped.preferredRecipientIDs == [], "通知空间不读取推广文案与群")
        try scoped.switchWorkspace(promotionID)
        try check(scoped.savedText == "推广文案" && scoped.preferredRecipientIDs == ["g3"] && scoped.preferredAssetIDs == ["a2"], "切回推广恢复独立图文和群选择")
        scoped.textTemplates![0].text = "尚未切换的修改"
        try scoped.switchWorkspace(promotionID)
        try check(scoped.textTemplates![0].text == "尚未切换的修改", "重复点击当前空间不会覆盖文案修改")
        let restoredSpaces = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(scoped))
        try check(restoredSpaces.activeWorkspaceID == promotionID && restoredSpaces.broadcastWorkspaces![1].draft.recipientIDs == ["g3"], "重启解码保留活动空间和独立草稿")
        try scoped.switchWorkspace("legacy")
        try check(scoped.savedText == "旧文案" && scoped.preferredRecipientIDs == ["g1", "g2"], "切回默认空间保留原内容")
        let ids = scoped.broadcastWorkspaces!.map(\.id)
        scoped.prepareWorkspaces(recipientIDs: [])
        try check(scoped.broadcastWorkspaces!.map(\.id) == ids, "迁移幂等，不重复生成空间")
        try rejects("不存在的空间不可切换") { try scoped.switchWorkspace("missing") }
        var taggedPlan = plan; taggedPlan.workspaceID = promotionID
        let restoredPlan = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(taggedPlan))
        try check(restoredPlan.workspaceID == promotionID, "发送计划持久保存来源空间")
        try check(plan.workspaceID == nil, "旧计划无空间字段时仍兼容")
        let retimed = try Scheduling.retimed(jobs, planID: plan.id, minutes: 10, now: now, globalGap: 5)
        try check(retimed[0].scheduled == jobs[0].scheduled && retimed[1].scheduled.timeIntervalSince(retimed[0].scheduled) == 600, "修改间隔保留未来首条并按10分钟重排")
        var protectedJobs = jobs; protectedJobs[0].status = "verified"; protectedJobs[0].submittedAt = now
        protectedJobs[1].status = "blocked"
        let protectedRetime = try Scheduling.retimed(protectedJobs, planID: plan.id, minutes: 60, now: now, globalGap: 5)
        try check(protectedRetime[0].scheduled == jobs[0].scheduled && protectedRetime[1].status == "blocked", "调整间隔不重发已发任务或恢复暂停任务")
        try check(protectedRetime[2].scheduled >= now.addingTimeInterval(3600), "同计划上次发送后等待新间隔")
        try rejects("拒绝零分钟") { _ = try Scheduling.retimed(jobs, planID: plan.id, minutes: 0, now: now, globalGap: 1) }
        try rejects("低于全局间隔须先调整全局") { _ = try Scheduling.retimed(jobs, planID: plan.id, minutes: 5, now: now, globalGap: 30) }
        var late = jobs; late[0].status = "verified"; late[0].submittedAt = now; late[1].scheduled = now
        try check(Scheduling.eligible(late, now: now.addingTimeInterval(600), gap: 5, intervalByPlan: [plan.id:60]) == nil, "逾期补发仍遵守所设60分钟计划间隔")
        var sourceSettings = Settings(savedText: "旧正文")
        sourceSettings.prepareWorkspaces(recipientIDs: [])
        let liveSource = TextTemplate(text: "旧正文")
        sourceSettings.broadcastWorkspaces?[0].templates = [liveSource]
        var sourcePlan = plan; sourcePlan.workspaceID = "legacy"
        var sourceArchive = Archive(recipients: recipients, assets: [], plans: [sourcePlan], deliveries: jobs, settings: sourceSettings)
        sourceArchive = LiveMessage.linked(sourceArchive)
        try check(sourceArchive.plans[0].textTemplateID == liveSource.id, "旧版单文案计划建立稳定来源")
        sourceArchive.settings.broadcastWorkspaces?[0].templates[0].text = "新正文\n完整链接 https://example.com"
        for (index, status) in ["queued", "blocked", "running", "draft", "submitted", "uncertain", "verified", "manual"].enumerated() { sourceArchive.deliveries[index].status = status }
        let live = LiveMessage.refreshed(sourceArchive)
        try check(live.deliveries[0].text == live.plans[0].text && live.deliveries[1].text == live.plans[0].text, "保存同步待发及可重试任务")
        try check(Array(live.deliveries.dropFirst(2)).allSatisfy { $0.text == plan.text }, "保留正在处理待核对与已发正文")
        try check(live.deliveries.map(\.scheduled) == jobs.map(\.scheduled), "正文更新不更改排期")
        var otherSpace = sourceArchive; otherSpace.plans[0].workspaceID = "unrelated"
        try check(LiveMessage.refreshed(otherSpace).deliveries[0].text == plan.text, "来源同步不跨空间")
        var evidenced = sourceArchive; evidenced.deliveries[0].submittedAt = now; evidenced.deliveries[1].evidence = "receipt"
        try check(LiveMessage.refreshed(evidenced).deliveries[0].text == plan.text && LiveMessage.refreshed(evidenced).deliveries[1].text == plan.text, "已有提交凭据不得覆盖正文")
        var extendPlan = live.plans[0]; extendPlan.recipientIDs = Array(recipients.prefix(7).map(\.id))
        let appended = try Scheduling.additionalDeliveries(plan: extendPlan, recipients: [recipients[7]], jobs: Array(live.deliveries.prefix(7)), now: now, gap: 30)
        try check(appended.first?.text == live.plans[0].text, "新增群从最新计划读取正文而非历史队尾")
        let sourceDB = try Database(root: root.appendingPathComponent("source")); try sourceDB.save(live)
        try check(try sourceDB.load("plans", as: Plan.self)[0].textTemplateID == liveSource.id && sourceDB.load("deliveries", as: Delivery.self)[0].text == live.plans[0].text, "来源与新正文重启后仍保留")
        // 图文模板同步：保存并同步后，草稿配图刷新计划与未发送任务的附件快照
        do {
            let assetA = Asset(id:"asset-a", name:"旧图.png", relativePath:"assets/a/旧图.png", sha256:"a", bytes:1, isImage:true)
            let assetB = Asset(id:"asset-b", name:"新图.png", relativePath:"assets/b/新图.png", sha256:"b", bytes:2, isImage:true)
            var workspace = BroadcastWorkspace(id:"legacy", name:"默认群发")
            workspace.templates = [TextTemplate(text:"测试文字", assetIDs:[assetB.id])]
            var syncDraft = BroadcastDraft(); syncDraft.assetIDs = [assetB.id]
            workspace.draft = syncDraft
            var syncSettings = Settings(savedText: ""); syncSettings.broadcastWorkspaces = [workspace]
            let template = workspace.templates[0]
            var syncPlan = plan; syncPlan.workspaceID = "legacy"; syncPlan.textTemplateID = template.id; syncPlan.assetIDs = [assetA.id]
            var syncJobs = jobs
            syncJobs[0].assets = [assetA]
            var submitted = jobs[1]; submitted.status = "uncertain"; submitted.submittedAt = now; submitted.evidence = "已提交待核对"; submitted.assets = [assetA]
            var archived = jobs[2]; archived.status = "verified"; archived.assets = [assetA]
            syncJobs[1] = submitted; syncJobs[2] = archived
            let input = Archive(recipients:recipients, assets:[assetA, assetB], plans:[syncPlan], deliveries:syncJobs, settings:syncSettings)
            let refreshedArchive = LiveMessage.refreshed(input)
            try check(refreshedArchive.plans[0].assetIDs == [assetB.id], "图文同步刷新计划配图列表")
            try check(refreshedArchive.deliveries[0].assets == [assetB], "图文同步替换未发送任务附件快照")
            try check(refreshedArchive.deliveries[1].assets == [assetA], "已提交待核对任务的附件不被同步改写")
            try check(refreshedArchive.deliveries[2].assets == [assetA] && refreshedArchive.deliveries[2].status == "verified", "已核验历史任务保持原快照")
            var legacyWorkspace = BroadcastWorkspace(id:"legacy", name:"默认群发")
            legacyWorkspace.templates = [TextTemplate(text:"测试文字")]
            var legacySettings = Settings(savedText: ""); legacySettings.broadcastWorkspaces = [legacyWorkspace]
            let legacyInput = Archive(recipients:recipients, assets:[assetA], plans:[syncPlan], deliveries:syncJobs, settings:legacySettings)
            let legacyRefreshed = LiveMessage.refreshed(legacyInput)
            try check(legacyRefreshed.plans[0].assetIDs == [assetA.id] && legacyRefreshed.deliveries[0].assets == [assetA], "旧模板不启用配图同步时保持原快照")
        }
        do {
        // Display and dispatch share one exact cooldown calculation.
        var cooling = jobs
        cooling[0].status = "verified"; cooling[0].submittedAt = now.addingTimeInterval(7.535)
        cooling[1].scheduled = now
        let effective = Scheduling.earliestSendDate(cooling[1], jobs: cooling, gap: 30, intervalByPlan: [plan.id:30])
        try check(abs(effective.timeIntervalSince(now) - 1807.535) < 0.00001, "最早发送按实际提交时间加间隔，不显示过期排期")
        try check(Scheduling.eligible(cooling, now: effective.addingTimeInterval(-0.001), gap: 30, intervalByPlan: [plan.id:30]) == nil, "间隔截止前一毫秒不发送")
        try check(Scheduling.eligible(cooling, now: effective, gap: 30, intervalByPlan: [plan.id:30])?.id == cooling[1].id, "间隔到期即选中下一条")
        try check(Scheduling.nextCandidate(cooling, gap: 30, intervalByPlan: [plan.id:30])?.id == cooling[1].id, "界面下一群与调度候选一致")
        var independent = cooling[1]; independent.id = "other-plan-job"; independent.planID = "other-plan"
        let mixed = cooling + [independent]
        try check(Scheduling.nextCandidate(mixed, gap: 5, intervalByPlan: [plan.id:60])?.id == independent.id, "全局运行时其他已可发送计划不被更长计划冷却挡住")
        try check(Scheduling.nextCandidate(mixed, gap: 5, planID: plan.id, intervalByPlan: [plan.id:60])?.id == cooling[1].id, "指定计划不会跨计划发送")
        for state in ["running", "draft", "submitted", "uncertain"] {
            var held = cooling; held[0].status = state
            try check(Scheduling.eligible(held, now: effective, gap: 30) == nil, "有效时间到期仍保留\(state)防重保护")
        }
        var editable = cooling; editable[1].scheduled = now.addingTimeInterval(3600)
        let shortened = try Scheduling.retimed(editable, planID: plan.id, minutes: 5, now: now.addingTimeInterval(60), globalGap: 5, preserveFutureStart: false)
        let firstShort = shortened.filter { $0.status == "queued" }.min { $0.scheduled < $1.scheduled }!
        try check(abs(firstShort.scheduled.timeIntervalSince(now) - 307.535) < 0.00001, "已开始单轮缩短间隔按实际发送重新计算首条")
        try check(shortened[0].submittedAt == editable[0].submittedAt && shortened[0].scheduled == editable[0].scheduled, "热改间隔保留已发记录")
        let untouchedStart = try Scheduling.retimed(jobs, planID: plan.id, minutes: 5, now: now, globalGap: 5)
        try check(untouchedStart[0].scheduled == jobs[0].scheduled, "未开始计划仍保留未来首条")
        }
        var paced = plan; paced.recipientGaps = [recipients[1].id: 60]
        try check(Scheduling.paceMinutes(paced) == 30 && Scheduling.paceMinutes(plan) == 30, "计划底线取统一间隔，更长的逐群间隔另外保住")
        var lateFirst = jobs[0]
        lateFirst.scheduled = now; lateFirst.status = "verified"; lateFirst.submittedAt = now.addingTimeInterval(50 * 60)
        var lateSecond = jobs[1]
        lateSecond.scheduled = now.addingTimeInterval(60 * 60)
        let lateDue = Scheduling.earliestSendDate(lateSecond, jobs: [lateFirst, lateSecond], gap: 30, intervalByPlan: [plan.id: Scheduling.paceMinutes(paced)])
        try check(abs(lateDue.timeIntervalSince(now) - 80 * 60) < 0.001, "迟到后从实际发送起按当前30分钟间隔计时")
        try check(Scheduling.eligible([lateFirst, lateSecond], now: lateDue.addingTimeInterval(-0.001), gap: 30, intervalByPlan: [plan.id: 30]) == nil, "当前间隔到期前不提前发送")
        try check(Scheduling.eligible([lateFirst, lateSecond], now: lateDue, gap: 30, intervalByPlan: [plan.id: 30])?.id == lateSecond.id, "逐群间隔到点后才选中下一条")
        try check(Scheduling.nextCandidate([lateFirst, lateSecond], gap: 30, intervalByPlan: [plan.id: 30])?.id == lateSecond.id, "下一群与最早发送时间使用同一计算")
        var resumeJobs = [lateFirst, lateSecond]
        var third = lateSecond; third.id = "resume-third"; third.scheduled = now.addingTimeInterval(120 * 60)
        resumeJobs.append(third)
        let restart = now.addingTimeInterval(55 * 60)
        let restarted = Scheduling.restarted(resumeJobs, planID: plan.id, now: restart, gap: 5, intervalByPlan: [plan.id: 5])
        try check(restarted[0].submittedAt == lateFirst.submittedAt && restarted[0].scheduled == lateFirst.scheduled, "重新开始不修改已发记录")
        try check(restarted[1].scheduled == restart && restarted[2].scheduled == restart.addingTimeInterval(300), "暂停后重新开始清除旧排期跨度并采用5分钟")
        var firstNow = restarted; firstNow[1].status = "verified"; firstNow[1].submittedAt = restart.addingTimeInterval(8)
        let nextDue = Scheduling.earliestSendDate(firstNow[2], jobs: firstNow, gap: 5, intervalByPlan: [plan.id: 5])
        try check(nextDue == restart.addingTimeInterval(308), "首群实际提交后再计5分钟，不叠加旧排期")
        var manualSend = jobs[0]
        manualSend.status = "manual"; manualSend.started = nil; manualSend.submittedAt = nil; manualSend.finished = now
        try check(Scheduling.lastSendActivity([manualSend]) == now, "人工确认已发送占用冷却")
        var cancelledEarly = jobs[0]
        cancelledEarly.status = "cancelled"; cancelledEarly.started = now; cancelledEarly.submittedAt = nil
        try check(Scheduling.lastSendActivity([cancelledEarly]) == nil, "取消尚未提交的任务不占用冷却")
        let point = CGPoint(x: 10, y: 10)
        let area = CGRect(x: 0, y: 0, width: 80, height: 80)
        let target = ClickCover.Window(ownerPID: 1, layer: 0, alpha: 1, bounds: area, regular: true, name: "QQ")
        let own = ClickCover.Window(ownerPID: 2, layer: 0, alpha: 1, bounds: area, regular: true, name: "QQ排程助手")
        let overlay = ClickCover.Window(ownerPID: 3, layer: 0, alpha: 1, bounds: area, regular: false, name: "辅助浮层")
        let menu = ClickCover.Window(ownerPID: 4, layer: 25, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 80, height: 24), regular: false, name: "菜单栏")
        let invisible = ClickCover.Window(ownerPID: 2, layer: 0, alpha: 0, bounds: area, regular: true, name: "QQ排程助手")
        let tip = ClickCover.Window(ownerPID: 5, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 20, height: 20), regular: false, name: "提示")
        try check(ClickCover.blocker(at: point, windows: [target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "目标窗口在最前时允许点击")
        try check(ClickCover.blocker(at: point, windows: [own, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "QQ排程助手", "自己的窗口挡住目标时拒绝点击")
        try check(ClickCover.blocker(at: point, windows: [overlay, own], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "辅助浮层", "浮层不能把点击放行到后面的窗口")
        try check(ClickCover.blocker(at: point, windows: [menu, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "菜单栏层级不挡住目标窗口")
        try check(ClickCover.blocker(at: point, windows: [invisible, target], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == nil, "全透明窗口不挡住目标")
        try check(ClickCover.blocker(at: point, windows: [tip, own], targetPID: 1, selfPID: 2, selfName: "QQ排程助手") == "QQ排程助手", "小提示层后面的本程序窗口仍然拒绝点击")
        try check(ConversationMatch.resultTitle(texts: ["群聊", "2026中国石油大学", "2026中国石油大学克拉玛依校区二手群（六）"], query: "2026中国石油大学克拉玛依校区二手群（六）") == "2026中国石油大学克拉玛依校区二手群（六）", "搜索行标题取完整群名而不是高亮片段")
        try check(ConversationMatch.headerMatches(candidates: ["2026中国石油大学克拉玛依校区二手群（六）"], title: "2026中国石油大学克拉玛依校区二手群（六）"), "完整标题可以绑定会话")
        try check(ConversationMatch.headerMatches(candidates: ["2026中国石油大学克拉玛依校区二手群（六）"], title: "2026中国石油大学"), "高亮前缀仍能识别完整标题")
        try check(!ConversationMatch.headerMatches(candidates: ["其他群聊窗口"], title: "群聊"), "群聊标签不能当成会话标题")
        try check(!ConversationMatch.headerMatches(candidates: ["2026中国石油大学交流群"], title: "石油"), "过短片段不能含混匹配另一个群")
        // 输入框的 AXDescription 才是“这个 composer 属于哪个会话”的证据；切换会话时它会滞后于标题栏
        try check(ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "CUPK-二手交易群（四）"),"输入框标注与刚选中的会话一致才允许粘贴/发送")
        try check(ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "【CUPK-二手交易群（四）】5群"),"标注带前后缀仍能认出同一个会话")
        try check(!ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: "中国石油大学克拉玛依校区2026级新生交流群"),"标题栏已切换但输入框仍写着别的会话时判为不匹配")
        try check(!ConversationMatch.composerBelongs(to: "CUPK-二手交易群（四）", description: ""),"读不到输入框标注时按不匹配处理，交给短暂重试后中止")
        try check(!ConversationMatch.composerBelongs(to: "", description: "任意"),"没有绑定会话名时不允许粘贴")
        try check(ConversationMatch.composerBelongs(to: "我的手机", description: "我的手机"),"自己设备会话同样按输入框标注绑定")
        try check(ConversationMatch.exactly("CUPK-二手交易群（四）", "CUPK-二手交易群（四）"),"人工续发要求收件群名逐字相同")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（四）", "CUPK-二手交易群（四）5"),"多一个字都不算同一个会话")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（三）", "CUPK-二手交易群（四）"),"中文数字三与四不得含混匹配")
        try check(!ConversationMatch.exactly("CUPK-二手交易群（四）", ""),"读不到输入框标注时判为不匹配")
        try check(!ConversationMatch.exactly("  ", "CUPK-二手交易群（四）"),"空白标注不算匹配")
        // 一次性草稿任务：只有草稿模式能容忍未确认图片，且不参与排期派发、不得重复开单
        try check(DraftTolerance.toleratesUnconfirmedImage(mode: "draft"),"只填写不发送的草稿任务可以带着未确认图片继续")
        try check(!DraftTolerance.toleratesUnconfirmedImage(mode: "automatic"),"自动发送任务图片确认不了必须停住")
        var oneOffClone = jobs[0]; oneOffClone.id = "one-off-clone"; oneOffClone.mode = "draft"
        oneOffClone.status = "queued"; oneOffClone.oneOff = true; oneOffClone.cloneOf = jobs[1].id
        try check(Scheduling.nextCandidate([oneOffClone], gap: 0) == nil,"一次性草稿任务不会被排期派发选中")
        try check(Scheduling.eligible([oneOffClone], now: Date(timeIntervalSince1970: 2_000_000_000), gap: 0) == nil,"启动队列也不会替它发送")
        var queueWithClone = jobs; queueWithClone[0].status = "verified"; queueWithClone[1].status = "verified"
        try check(Scheduling.nextCandidate(queueWithClone + [oneOffClone], gap: 0)?.id != "one-off-clone","正常任务里也不会被顺手夹带")
        try check(Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [oneOffClone]),"同一来源未出结果前不能再开一张")
        var cloneDone = oneOffClone; cloneDone.status = "verified"
        try check(!Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [cloneDone]),"上一张已出结果，允许再开")
        var abandoned = oneOffClone; abandoned.status = "cancelled"
        try check(!Scheduling.hasUnresolvedClone(of: jobs[1].id, in: [abandoned]),"取消掉的算已处理")
        try check(!Scheduling.hasUnresolvedClone(of: jobs[2].id, in: [oneOffClone]),"别的来源任务不受影响")
        // 旧库里没有 oneOff / cloneOf 这两个新键，必须照样能解码
        let legacyRow = "{\"id\":\"legacy\",\"planID\":\"p\",\"planName\":\"n\",\"recipient\":\"群\",\"text\":\"正文\",\"assets\":[],\"scheduled\":1,\"mode\":\"automatic\",\"status\":\"blocked\",\"detail\":\"旧记录\",\"evidence\":\"\"}"
        let decodedLegacy = try JSONDecoder().decode(Delivery.self, from: Data(legacyRow.utf8))
        try check(!decodedLegacy.isOneOff && decodedLegacy.cloneOf == nil,"旧库记录缺少新字段仍能解码，不会被误判为一次性任务")
        print("\n\(passed) checks passed. No QQ messages sent.")
    }
}
