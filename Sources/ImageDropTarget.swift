import SwiftUI
import AppKit
import ImageIO

enum DroppedImages {
    static func urls(from pasteboard: NSPasteboard) throws -> [URL] {
        let urls = (pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        guard !urls.isEmpty else { throw AppError("请从访达拖入本机文件") }
        let imageExtensions = ["png","jpg","jpeg","gif","webp","heic","heif","tiff","tif","bmp"]
        var result: [URL] = [], seen = Set<URL>()
        for url in urls {
            let normalized = url.standardizedFileURL
            guard normalized.isFileURL,
                  try normalized.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {
                throw AppError("请拖入本机文件：\(url.lastPathComponent)。此次拖入未导入")
            }
            // 图片仍要求可解码且为单帧；其他常规文件放行，发送前预检会兜底
            if imageExtensions.contains(normalized.pathExtension.lowercased()) {
                guard let source = CGImageSourceCreateWithURL(normalized as CFURL,nil),
                      CGImageSourceGetCount(source) == 1 else {
                    throw AppError("图片无法读取或包含多帧：\(url.lastPathComponent)。此次拖入未导入")
                }
            }
            if seen.insert(normalized).inserted { result.append(normalized) }
        }
        return result
    }
}

struct ImageDropTarget: NSViewRepresentable {
    var hint = "拖入图片或文件，或点击添加"
    var activeHint = "松手导入"
    var onDrop: ([URL]) -> Void
    var onError: (String) -> Void
    var onBrowse: () -> Void
    func makeNSView(context: Context) -> DropSurface {
        let view = DropSurface()
        // 四个回调在首帧就挂好，不能只靠紧随其后的 updateNSView：
        // 首帧内若有拖放到达，performDragOperation 会命中默认空闭包并返回 true，拖入被静默吞掉（2-29）
        view.hint = hint; view.activeHint = activeHint
        view.onDrop = onDrop; view.onError = onError; view.onBrowse = onBrowse
        return view
    }
    func updateNSView(_ view: DropSurface, context: Context) {
        view.hint = hint; view.activeHint = activeHint
        view.onDrop = onDrop; view.onError = onError; view.onBrowse = onBrowse
        view.needsDisplay = true
    }
    final class DropSurface: NSView {
        var hint = "拖入图片或文件，或点击添加"
        var activeHint = "松手导入" { didSet { needsDisplay = true } }
        var onDrop: ([URL]) -> Void = { _ in }
        var onError: (String) -> Void = { _ in }
        var onBrowse: () -> Void = {}
        private var targeted = false { didSet { needsDisplay = true } }
        override init(frame: NSRect) {
            super.init(frame:frame)
            registerForDraggedTypes([.fileURL])
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("拖入图片或文件，或点击添加")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx:1,dy:1)
            let path = NSBezierPath(roundedRect:rect,xRadius:12,yRadius:12)
            (targeted ? NSColor.systemIndigo.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).setFill(); path.fill()
            (targeted ? NSColor.systemIndigo : NSColor.separatorColor).setStroke()
            path.setLineDash([5,4],count:2,phase:0); path.lineWidth = targeted ? 1.5 : 1; path.stroke()
            let title = targeted ? activeHint : hint
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:targeted ? NSColor.systemIndigo : NSColor.secondaryLabelColor]
            let size = title.size(withAttributes:attributes)
            title.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            targeted = sender.draggingPasteboard.types?.contains(.fileURL) == true
            return targeted ? .copy : []
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { targeted ? .copy : [] }
        override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
        override func draggingEnded(_ sender: NSDraggingInfo) { targeted = false }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            targeted = false
            do { onDrop(try DroppedImages.urls(from:sender.draggingPasteboard)); return true }
            catch { onError(error.localizedDescription); return false }
        }
        override func mouseDown(with event: NSEvent) { onBrowse() }
        override func accessibilityPerformPress() -> Bool { onBrowse(); return true }
    }
}
