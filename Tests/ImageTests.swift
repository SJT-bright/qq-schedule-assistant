import AppKit
import ImageIO

@main
struct ImageTests {
    @MainActor static func main() async throws {
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

        // MARK: - 发送前置校验（2-02 / 2-19 接线后的口径）
        func message(_ url: URL, image: Bool) -> String? {
            // 返回 nil 表示「校验放行」；返回字符串表示驱动会在这里抛错、本次发送中止并转需关注。
            guard image else { return nil }
            do { try ImageAttachment.validateReadable(at: url); return nil }
            catch { return error.localizedDescription }
        }
        // ① 正常可发送的图片必须仍然放行，收紧不能造成误拒（png 在前面的用例里已被移进素材库）
        guard message(second, image: true) == nil, message(db.url(for: asset), image: true) == nil else { throw AppError("正常图片被前置校验误拒") }
        // ② 读不到的文件（损坏/不存在）必须挡在粘贴之前
        guard let broken = message(bad, image: true), broken.contains("损坏.png") else { throw AppError("损坏图片未被前置校验挡住") }
        let missing = root.appendingPathComponent("已删除的配图.png")
        guard let vanished = message(missing, image: true), vanished.contains("已删除的配图.png") else { throw AppError("缺失图片未被前置校验挡住") }
        // ③ 多帧动图：前置校验与真正解码用的是同一判据（帧数≠1）
        let gif = root.appendingPathComponent("动图.gif")
        let gifFrames = writeMultiFrameGIF(to: gif, source: second)
        probe("gif frames=\(gifFrames) msg=\(message(gif, image: true) ?? "放行")")
        guard let animated = message(gif, image: true), animated.contains("多帧") else { throw AppError("多帧动图未被前置校验挡住") }
        var gifPayloadRejected = false
        do { _ = try ImageAttachment.tiff(at: gif) } catch { gifPayloadRejected = true }
        guard gifPayloadRejected else { throw AppError("多帧动图竟能通过载荷解码") }
        // ④ 像素超限：按文件头判定，恰好 1 亿像素放行，超一点或单边异常都拒
        guard !ImageAttachment.exceedsDecodableLimit(width:10_000,height:10_000),
              ImageAttachment.exceedsDecodableLimit(width:10_001,height:10_000),
              ImageAttachment.exceedsDecodableLimit(width:65_536,height:2),
              ImageAttachment.exceedsDecodableLimit(width:0,height:10),
              ImageAttachment.exceedsDecodableLimit(width:-1,height:-1) else { throw AppError("像素上限边界判定错误") }
        let huge = root.appendingPathComponent("超大像素.png")
        try FileManager.default.copyItem(at: second, to: huge)
        try rewritePNGDimensions(at: huge, width: 20_000, height: 10_000)   // 2 亿像素，文件本身仍然很小
        probe("huge msg=\(message(huge, image: true) ?? "放行")")
        guard let overLimit = message(huge, image: true), overLimit.contains("超大像素.png") else { throw AppError("超限像素图片未被前置校验挡住") }
        // 超限是「挡在解码之前」，不是「先铺开再说」；tiffPayload 那一次也必须同样拒，且文案一致
        var hugePayloadRejected: String? = nil
        do { _ = try await ImageAttachment.tiffPayload(at: huge) } catch { hugePayloadRejected = error.localizedDescription }
        guard hugePayloadRejected == overLimit else { throw AppError("超限图片竟完成载荷解码，或两处文案不一致：\(hugePayloadRejected ?? "放行")") }
        // 界面侧（缩略图/预览）不抛错，返回 nil 画占位图标
        guard ImageAttachment.thumbnail(at: huge) == nil, ImageAttachment.largePreview(at: huge) == nil else { throw AppError("超限图片预览未降级") }
        // ⑤ 上限以内的大图照常可发，只是载荷长边被夹住（不误拒 8000×6000 这一档）
        let wide = root.appendingPathComponent("长条配图.png")
        try writeBitmap(width: 4_200, height: 80, to: wide)   // 33.6 万像素：放行，但长边超过 4096
        guard ImageAttachment.exceedsDecodableLimit(width: 4_200, height: 80) == false,
              message(wide, image: true) == nil else { throw AppError("超限以内的大图被误拒") }
        let capped = try ImageAttachment.tiff(at: wide)
        guard let cappedImage = NSBitmapImageRep(data: capped),
              max(cappedImage.pixelsWide, cappedImage.pixelsHigh) == ImageAttachment.maxPayloadPixelSize,
              cappedImage.pixelsWide == ImageAttachment.maxPayloadPixelSize else { throw AppError("载荷长边未被夹到 4096") }
        // ⑥ 驱动改用的异步载荷通道与同步解码逐字节一致（异步化不改变交给 QQ/微信的内容）
        let payload = try await ImageAttachment.tiffPayload(at: wide)
        guard payload == capped else { throw AppError("tiffPayload 与 tiff 载荷不一致") }
        var badPayload: String? = nil
        do { _ = try await ImageAttachment.tiffPayload(at: bad) } catch { badPayload = error.localizedDescription }
        guard let badPayload, badPayload.contains("损坏.png") else { throw AppError("驱动侧异步载荷未拒绝损坏图片") }
        // ⑦ WeChatDriver 补上的 if a.isImage：普通文件不能按图片校验
        let note = root.appendingPathComponent("随附说明.txt")
        try Data("普通文件，不是图片".utf8).write(to: note)
        let noteAsset = try db.importAsset(note)
        let imageAsset = try db.importAsset(second)
        guard !noteAsset.isImage, imageAsset.isImage else { throw AppError("素材图片/普通文件分类错误") }
        // 加了过滤的口径：图文混合任务里普通文件被跳过，图片照常校验，整体放行
        var filtered: String? = nil
        for a in [imageAsset, noteAsset] {
            guard filtered == nil else { continue }
            filtered = message(db.url(for: a), image: a.isImage)
        }
        guard filtered == nil else { throw AppError("带 if a.isImage 的前置校验误拒普通文件任务：\(filtered ?? "")") }
        // 缺过滤的旧写法（WeChatDriver 原状）：普通文件会被当图片拒掉，报「图片无法读取」
        guard message(db.url(for: noteAsset), image: true) != nil else { throw AppError("未复现「缺 if a.isImage」时的普通文件误报") }
        let clipboardPayload = try await ImageAttachment.clipboardPayload(at: second)
        guard let tiffRep = NSBitmapImageRep(data: clipboardPayload.tiff), let pngRep = NSBitmapImageRep(data: clipboardPayload.png),
              tiffRep.pixelsWide == pngRep.pixelsWide, tiffRep.pixelsHigh == pngRep.pixelsHigh,
              pngRep.pixelsWide == 24, pngRep.pixelsHigh == 16 else { throw AppError("双格式后台载荷不一致") }
        let privateBoard = NSPasteboard(name: .init("qq-flow-clipboardPayload-\(UUID().uuidString)"))
        defer { privateBoard.releaseGlobally() }
        privateBoard.clearContents()
        guard privateBoard.setData(clipboardPayload.tiff, forType: .tiff), privateBoard.setData(clipboardPayload.png, forType: .png),
              privateBoard.data(forType: .tiff) == clipboardPayload.tiff, privateBoard.data(forType: .png) == clipboardPayload.png else {
            throw AppError("双格式私有剪贴板回读失败")
        }
        let versionBeforeFailure = privateBoard.changeCount
        var conversionRejected = false
        do { _ = try await ImageAttachment.clipboardPayload(at: bad) } catch { conversionRejected = true }
        guard conversionRejected, privateBoard.changeCount == versionBeforeFailure else { throw AppError("坏图片转换不应动剪贴板") }
        let cancelledPayload = Task { try await ImageAttachment.clipboardPayload(at: second) }
        cancelledPayload.cancel()
        var cancellationRejected = false
        do { _ = try await cancelledPayload.value } catch is CancellationError { cancellationRejected = true }
        guard cancellationRejected, privateBoard.changeCount == versionBeforeFailure else { throw AppError("已取消的图片准备不应继续贴图") }
        print("33 image/clipboard checks passed. No QQ messages sent.")
    }
}

private func probe(_ text: String) {
    FileHandle.standardError.write(Data("probe \(text)\n".utf8))
}

/// PNG 块 CRC（ISO-3309 / zlib 多项式 0xEDB88320），只用于改写测试图的 IHDR。
private func pngCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return crc ^ 0xFFFF_FFFF
}

/// 只改文件头里的宽高（连同 IHDR 的 CRC），文件本身仍是几 KB —— 用来复现「亿级像素」而不必真的分配 800MB。
private func rewritePNGDimensions(at url: URL, width: Int, height: Int) throws {
    var bytes = [UInt8](try Data(contentsOf: url))
    // 签名 8 + 块长度 4 + "IHDR" 4 + 数据 13（宽4 高4 深度/类型/压缩/过滤/隔行 5）+ CRC 4
    guard bytes.count > 33, String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" else { throw AppError("测试图不是可改头的 PNG") }
    for (offset, value) in [(16, width), (20, height)] {
        bytes[offset] = UInt8((value >> 24) & 0xFF)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
    let crc = pngCRC(bytes[12..<29])
    for i in 0..<4 { bytes[29 + i] = UInt8((crc >> (24 - 8 * i)) & 0xFF) }
    try Data(bytes).write(to: url)
}

/// 写出真实的两帧 GIF，返回回读到的帧数（用例据此确认挡下来的是「多帧」而不是别的失败）。
private func writeMultiFrameGIF(to url: URL, source: URL) -> Int {
    guard let data = try? Data(contentsOf: source),
          let rep = NSBitmapImageRep(data: data), let frame = rep.cgImage,
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil) else { return 0 }
    CGImageDestinationAddImage(dest, frame, nil)
    CGImageDestinationAddImage(dest, frame, nil)
    guard CGImageDestinationFinalize(dest), let check = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
    return CGImageSourceGetCount(check)
}

/// 生成一张「上限以内但长边超过 4096」的 PNG，用来验证正常大图仍可发送、只是载荷被夹住。
private func writeBitmap(width: Int, height: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
          let png = rep.representation(using:.png,properties:[:]) else { throw AppError("无法生成测试位图") }
    try png.write(to:url)
}
