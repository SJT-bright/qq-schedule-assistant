import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - 一体化发送内容模型

/// 一体化发送框里的一张图片（拖入或粘贴），先落到临时文件再走现有 importFiles 流程
struct UnifiedImage: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let fileURL: URL
}

/// 一体化发送框的完整内容：文字（含链接）+ 图片
struct UnifiedContent {
    var text = ""
    var images: [UnifiedImage] = []

    /// 用 NSDataDetector 从文本中识别 http/https 链接
    var detectedLinks: [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { $0.url }
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }
}

// MARK: - 剪贴板收集

enum UnifiedPasteCollector {
    /// 读取系统剪贴板：文本、文件 URL、位图图片，一次性全部取出
    static func readPasteboard(_ pasteboard: NSPasteboard = .general) -> UnifiedContent {
        var content = UnifiedContent()

        // 1) 文本（含链接，原样保留）
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
           let joined = strings.first, !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.text = joined.replacingOccurrences(of: "\u{fffc}", with: "")
        }

        // 2) 文件 URL（拖拽/拷贝的图片或文件）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                let normalized = url.standardizedFileURL
                content.images.append(UnifiedImage(name: normalized.lastPathComponent, fileURL: normalized))
            }
        }

        // 3) 位图图片（截图 / 网页复制），写 PNG 临时文件
        if content.images.isEmpty {
            var bitmaps: [NSImage] = []
            if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
                bitmaps.append(contentsOf: images)
            } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                bitmaps.append(contentsOf: [NSImage(data: data)].compactMap { $0 })
            }
            for image in bitmaps {
                if let url = writePNG(image) {
                    content.images.append(UnifiedImage(name: url.lastPathComponent, fileURL: url))
                }
            }
        }

        // 4) 只有链接 URL 的场景（从浏览器地址栏拷贝）
        if content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.images.isEmpty,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL] {
            let links = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
            if !links.isEmpty { content.text = links.map(\.absoluteString).joined(separator: "\n") }
        }

        return content
    }

    /// 把位图写成 PNG 临时文件；随后由 importAsset 拷入素材库
    static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // 按内容命名：同一张图重复 ⌘V 得到同一个路径，框内按 path 去重才真的生效，
        // 素材库的「sha256 + 同名复用」也才用得上（随机时间戳名会绕开它，产出两份同图，5-14）。
        let digest = SHA256.hash(data: png).prefix(6).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("剪贴板-\(digest).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do { try png.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

// MARK: - 一体化发送框视图

struct UnifiedComposerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 返回 true 表示导入成功（一体化框随即清空）；false 保留内容供用户重试
    var workspaceID: String? = nil
    var onImport: (UnifiedContent) -> Bool

    @State private var text = ""
    @State private var images: [UnifiedImage] = []
    @State private var dropTargeted = false
    @State private var importPulse = false
    @State private var cmdVMonitor: Any?
    /// 进程级「当前 ⌘V 监视器」。句柄只放在实例 `@State` 里时，SwiftUI 换 identity 时
    /// 不保证旧实例的 `onDisappear` 早于新实例的 `onAppear`，两个监视器会同时挂着，
    /// 一次 ⌘V 触发两次 `pasteFromClipboard()`，而 `merge` 对文字是追加 → 文案整段重复（5-24）。
    private static var activeMonitor: Any?

    private var content: UnifiedContent { UnifiedContent(text: text, images: images) }
    private var links: [URL] { content.detectedLinks }

    var body: some View {
        DepthSurface(radius: 20, padding: 18, accent: Theme.indigo) {
            VStack(alignment: .leading, spacing: 12) {
                header
                composerBox
                if !links.isEmpty { linkChips }
                if !images.isEmpty { imageChips }
                actionRow
            }
        }
        .onAppear {
            if let workspaceID, let space = store.workspaces.first(where: { $0.id == workspaceID }) {
                text = space.stagingText
                images = space.stagingFiles.map { path in let url = store.db.root.appendingPathComponent(path); return UnifiedImage(name: url.lastPathComponent, fileURL: url) }
            }
            installCmdVMonitor()
        }
        .onChange(of: text) { _, value in if let workspaceID { store.saveStaging(workspaceID: workspaceID, text: value) } }
        .onChange(of: images) { _, value in if let workspaceID { store.saveStaging(workspaceID: workspaceID, files: value.map(\.fileURL)) } }
        .onDisappear { removeCmdVMonitor() }
    }

    /// 新建发送页内：焦点不在任何文本输入框时，⌘V 直接触发「一键粘贴导入」
    private func installCmdVMonitor() {
        guard cmdVMonitor == nil else { return }
        // 先把上一个实例留下的监视器摘掉，保证同一时刻全进程只有一个 ⌘V 监听
        if let previous = UnifiedComposerView.activeMonitor as AnyObject? { NSEvent.removeMonitor(previous) }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            guard !UnifiedComposerView.textEditingHasFocus() else { return event }
            pasteFromClipboard()
            return nil
        }
        cmdVMonitor = monitor
        UnifiedComposerView.activeMonitor = monitor
    }

    private func removeCmdVMonitor() {
        guard let monitor = cmdVMonitor as AnyObject? else { return }
        cmdVMonitor = nil
        NSEvent.removeMonitor(monitor)
        // 只有还轮到自己时才腾空进程级句柄：新实例此刻可能已经装好了它自己的
        if UnifiedComposerView.activeMonitor as AnyObject? === monitor { UnifiedComposerView.activeMonitor = nil }
    }

    /// 当前键窗口的第一响应者是否为文本编辑控件（TextEditor / 输入框）
    static func textEditingHasFocus() -> Bool {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder else { return false }
        return responder is NSTextView   // NSTextField 编辑态的第一响应者也是 NSTextView（field editor）
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 9) {
            SectionLabel(title: "导入暂存区", symbol: "tray.full.fill", tint: Theme.indigo,
                         trailing: "\(images.count) 图 · \(links.count) 链接")
            Spacer()
            CopyButton("复制文字") { try ClipboardCopy.text(text) }.disabled(text.isEmpty)
        }
    }

    // MARK: 主输入区（一体化大框）

    private var composerBox: some View {
        let boxShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 148)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            if text.isEmpty {
                Text("把要发的内容一次性放进来：\n· 直接打字、粘贴文案（可含链接）\n· 点「⌘V 一键粘贴导入」或直接按 ⌘V，图片和文字一起进\n· 把图片、文件、链接拖进这个框")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
        }
        .background(Surface(scheme).inset)
        .clipShape(boxShape)
        .overlay {
            boxShape.strokeBorder(dropTargeted ? Theme.indigo.opacity(0.55) : Surface(scheme).hairline,
                                  lineWidth: dropTargeted ? 1.6 : 1)
        }
        .overlay {
            if dropTargeted {
                boxShape.fill(Theme.indigo.opacity(scheme == .dark ? 0.14 : 0.06))
                boxShape.strokeBorder(Theme.indigo.opacity(0.7), lineWidth: 2)
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.indigo)
                        .shadow(color: Theme.indigo.opacity(0.5), radius: 4)
                    Text("松手导入 · 文字 / 链接 / 图片一起进来")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dropTargeted)
    }

    // MARK: 链接标签行

    private var linkChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                ForEach(links, id: \.absoluteString) { url in
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 9, weight: .bold))
                        Text(shortLink(url))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { removeLink(url) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(GhostPressButtonStyle())
                        .quietHover(lift: 1.5, scale: 1.04)
                        .help("从文案中删除这行链接")
                    }
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(colors: [Theme.blue.opacity(scheme == .dark ? 0.28 : 0.14),
                                                Theme.blue.opacity(scheme == .dark ? 0.12 : 0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.14 : 0.45), Theme.blue.opacity(0.16)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 0.7)
                    )
                    .shadow(color: Theme.blue.opacity(0.12), radius: 3, x: 0, y: 1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 图片标签行

    private var imageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                ForEach(images) { image in
                    HStack(spacing: 7) {
                        Group {
                            if let ns = ImageAttachment.thumbnail(at: image.fileURL) {
                                Image(nsImage: ns).resizable().scaledToFill()
                            } else {
                                ZStack { Theme.cool; Image(systemName: "doc.fill").font(.system(size: 14)).foregroundStyle(.white) }
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(image.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(image.fileURL.pathExtension.uppercased())
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        CopyButton("复制图片") { try ClipboardCopy.file(image.fileURL,isImage:true) }
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                                images.removeAll { $0.id == image.id }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(GhostPressButtonStyle())
                        .quietHover(lift: 1.5, scale: 1.04)
                        .help("移除这张图片")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Surface(scheme).card.opacity(0.85), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Surface(scheme).hairline.opacity(0.7), lineWidth: 0.9))
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 操作行

    private var actionRow: some View {
        HStack(spacing: 9) {
            Button { pasteFromClipboard() } label: {
                Label("⌘V 一键粘贴导入", systemImage: "doc.on.clipboard.fill")
            }
            .buttonStyle(DepthButtonStyle(gradient: Theme.cool, tint: Theme.teal))
            .disabled(store.busy)
            .help("读取剪贴板里的文字和图片，一起放进这个框；在输入框没有焦点时直接按 ⌘V 也可以")

            Button { browseImages() } label: { Label("从访达选图", systemImage: "photo.badge.plus") }
                .buttonStyle(SoftButtonStyle(tint: Theme.teal))
                .disabled(store.busy)

            Spacer()

            if !content.isEmpty {
                Button("清空") {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                        text = ""; images = []
                    }
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.slate))
            }

            Button { importContent() } label: { Label("应用到本次发送", systemImage: "square.and.arrow.down") }
                .buttonStyle(DepthButtonStyle())
                .disabled(content.isEmpty || store.busy)
                .opacity(content.isEmpty ? 0.45 : 1)
                .scaleEffect(importPulse ? 0.96 : 1)
                .shadow(color: importPulse ? Theme.teal.opacity(0.5) : .clear, radius: 8)
        }
    }

    // MARK: 交互逻辑

    private func pasteFromClipboard() {
        let collected = UnifiedPasteCollector.readPasteboard()
        guard !collected.isEmpty else { store.step = "剪贴板里没有可导入的文字或图片"; return }
        merge(collected)
    }

    private func merge(_ collected: UnifiedContent) {
        let existing = Set(images.map(\.fileURL.path))
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) {
            if !collected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let merged = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = merged.isEmpty ? collected.text : merged + "\n" + collected.text
            }
            for image in collected.images where !existing.contains(image.fileURL.path) {
                images.append(image)
            }
        }
        var parts: [String] = []
        if !images.isEmpty { parts.append("\(images.count) 张图") }
        let linkCount = content.detectedLinks.count
        if linkCount > 0 { parts.append("\(linkCount) 条链接") }
        let wordCount = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if wordCount > 0 { parts.append("\(wordCount) 字文案") }
        store.step = parts.isEmpty ? "内容已放入一体化发送框" : "已放入 " + parts.joined(separator: "、") + "；点击「应用到本次发送」"
    }

    private func browseImages() {
        let panel = NSOpenPanel()
        panel.title = "添加图片"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            let urls = panel.urls.map { UnifiedImage(name: $0.lastPathComponent, fileURL: $0) }
            merge(UnifiedContent(text: "", images: urls))
        }
    }

    private func importContent() {
        guard !content.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7)) { importPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { importPulse = false }
        let ok = onImport(content)
        guard ok else { return }   // 失败保留内容，用户修正后可重试
        // 成功后自动清空，避免重复导入同一批内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) {
                text = ""; images = []
            }
        }
    }

    private func removeLink(_ url: URL) {
        let target = url.absoluteString
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard line.contains(target) else { kept.append(line); continue }
            let replaced = line.replacingOccurrences(of: target, with: "")
            // 删除链接后仍有内容则保留该行；只剩空白则整行去掉
            if !replaced.trimmingCharacters(in: .whitespaces).isEmpty { kept.append(replaced) }
        }
        text = kept.joined(separator: "\n")
    }

    private func shortLink(_ url: URL) -> String {
        let s = url.absoluteString
        guard s.count > 42 else { return s }
        return s.prefix(24) + "…" + s.suffix(12)
    }

    // MARK: 拖拽处理

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = DispatchQueue(label: "unified.drop.collector")
        var textParts: [String] = []
        var imageItems: [UnifiedImage] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    collector.async {
                        defer { group.leave() }
                        if let url = item as? URL {
                            imageItems.append(UnifiedImage(name: url.lastPathComponent, fileURL: url))
                        } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            imageItems.append(UnifiedImage(name: url.lastPathComponent, fileURL: url))
                        }
                    }
                }
                continue
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                group.enter()
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    collector.async {
                        defer { group.leave() }
                        if let image = object as? NSImage, let url = UnifiedPasteCollector.writePNG(image) {
                            imageItems.append(UnifiedImage(name: url.lastPathComponent, fileURL: url))
                        }
                    }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    collector.async {
                        defer { group.leave() }
                        if let url = item as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            textParts.append(url.absoluteString)
                        }
                    }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    collector.async {
                        defer { group.leave() }
                        if let s = item as? String { textParts.append(s) }
                        else if let data = item as? Data, let s = String(data: data, encoding: .utf8) { textParts.append(s) }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let collected = UnifiedContent(text: textParts.joined(separator: "\n"), images: imageItems)
            guard !collected.isEmpty else { return }
            merge(collected)
        }
        return true
    }
}

// MARK: - Store 扩展：把一体化内容导入素材库与文案

struct UnifiedImportResult {
    let assetIDs: [String]
    let templateID: String?
    let text: String
}

extension Store {
    /// 把一体化发送框的内容导入：图片进素材库并选中，文字存成文案模板
    @discardableResult
    func applyUnifiedContent(_ content: UnifiedContent,
                             selectAssets: ([String]) -> Void,
                             setText: (String) -> Void) throws -> UnifiedImportResult {
        // 1) 图片：统一走现有 importFiles（内部按 sha256 + 文件名去重）
        // 共享的 error 记的是「最近一次尚未被消解的错误」，不是本次操作的结果：
        // 直接读它会让一条无关的旧错误把成功的导入判成失败（图片已进素材库、文案没写、框不清空，5-05）。
        // 这里把通道腾空，只认 importFiles 这次写进去的内容，随后原样归还旧错误，不让它被本次操作吞掉。
        var importedIDs: [String] = []
        if !content.images.isEmpty {
            let carried = error
            error = nil
            importedIDs = importFiles(content.images.map(\.fileURL))
            let failure = error
            error = carried
            if let failure { throw AppError("图片导入失败：\(failure)") }
            // 成功判据补齐：importFiles 对每个 URL 必然产出一个 id（同图复用也会），
            // 数量对不上却没写错误 = 静默半途，这里如实报错，不能让「应用到本次发送」假装成功。
            guard importedIDs.count == content.images.count else {
                throw AppError("图片导入未完成：期望 \(content.images.count) 张，实际入库 \(importedIDs.count) 张，请重试或改用「从访达选图」")
            }
        }

        // 2) 文字：存成文案模板（已有完全相同的文案就复用，避免文案库被重复导入撑爆）
        var templateID: String?
        let trimmed = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let existing = (settings.textTemplates ?? []).first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
                templateID = existing.id
            } else {
                templateID = try saveTextTemplate(text: content.text)
            }
        }

        // 3) 回调更新新建发送页的选择状态
        selectAssets(importedIDs)
        if !trimmed.isEmpty { setText(trimmed) }

        let reused = templateID != nil && (settings.textTemplates ?? []).contains(where: { $0.id == templateID }) && importedIDs.isEmpty
        step = "一体化导入完成：\(importedIDs.count) 张图、\(trimmed.count) 字文案、\(content.detectedLinks.count) 条链接\(reused ? "（文案与已有模板相同，已复用）" : "")"
        return UnifiedImportResult(assetIDs: importedIDs, templateID: templateID, text: trimmed)
    }
}
