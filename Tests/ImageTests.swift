import AppKit

@main
struct ImageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qqdispatch-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:24,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let blue = NSColor(deviceRed:0.1,green:0.3,blue:0.8,alpha:1)
        for x in 0..<24 { for y in 0..<16 { bitmap.setColor(blue,atX:x,y:y) } }
        let png = root.appendingPathComponent("中文 配图.png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:png)
        let second = root.appendingPathComponent("第二张.png")
        try FileManager.default.copyItem(at:png,to:second)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([png as NSURL,second as NSURL,png as NSURL])
        guard try DroppedImages.urls(from:pasteboard) == [png,second] else { throw AppError("多图片拖入顺序或去重失败") }
        let data = try ImageAttachment.tiff(at:png)
        guard let result = NSBitmapImageRep(data:data), result.pixelsWide == 24, result.pixelsHigh == 16 else { throw AppError("图片转换尺寸错误") }
        guard ImageAttachment.thumbnail(at:png) != nil else { throw AppError("缩略图读取失败") }
        let db = try Database(root:root.appendingPathComponent("library"))
        let asset = try db.importAsset(png)
        try FileManager.default.removeItem(at:png)
        guard try ImageAttachment.tiff(at:db.url(for:asset)) == data else { throw AppError("原图移走后转换不一致") }
        let bad = root.appendingPathComponent("损坏.png")
        try Data("not an image".utf8).write(to:bad)
        pasteboard.clearContents(); pasteboard.writeObjects([second as NSURL,bad as NSURL])
        var mixedRejected = false
        do { _ = try DroppedImages.urls(from:pasteboard) } catch { mixedRejected = true }
        guard mixedRejected else { throw AppError("混合无效拖入应整体拒绝") }
        pasteboard.clearContents(); pasteboard.writeObjects([root as NSURL])
        var folderRejected = false
        do { _ = try DroppedImages.urls(from:pasteboard) } catch { folderRejected = true }
        guard folderRejected else { throw AppError("目录拖入未拒绝") }
        pasteboard.clearContents(); pasteboard.setString("https://example.com/image.png",forType:.string)
        var linkRejected = false
        do { _ = try DroppedImages.urls(from:pasteboard) } catch { linkRejected = true }
        guard linkRejected else { throw AppError("远程链接拖入未拒绝") }
        var rejected = false
        do { _ = try ImageAttachment.tiff(at:bad) } catch { rejected = true }
        guard rejected else { throw AppError("损坏图片未拒绝") }
        guard ImageAttachment.thumbnail(at:bad) == nil else { throw AppError("损坏图片预览未降级") }
        let original = "中文 🚀\n完整文案 https://example.com/?a=1&b=2"
        try ClipboardCopy.text(original,to:pasteboard)
        guard pasteboard.string(forType:.string) == original else { throw AppError("复制文字不完整") }
        do { try ClipboardCopy.file(bad,isImage:true,to:pasteboard) } catch {}
        guard pasteboard.string(forType:.string) == original else { throw AppError("无效图片清空了剪贴板") }
        try ClipboardCopy.file(second,isImage:true,to:pasteboard)
        guard let copiedData = pasteboard.data(forType:.tiff), let copiedImage = NSBitmapImageRep(data:copiedData), copiedImage.pixelsWide == 24, copiedImage.pixelsHigh == 16, pasteboard.data(forType:.png) != nil, pasteboard.string(forType:.fileURL) == nil else { throw AppError("未复制图片本身") }
        try ClipboardCopy.file(bad,isImage:false,to:pasteboard)
        guard pasteboard.string(forType:.fileURL) == bad.absoluteString else { throw AppError("文件复制失败") }
        print("13 image/clipboard checks passed. No QQ messages sent.")
    }
}
