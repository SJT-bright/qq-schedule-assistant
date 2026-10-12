import AppKit
import ImageIO

enum ImageAttachment {
    /// 位图载荷的长边上限：超过就等比降采样后重编码，不超过的仍按原尺寸走（画质不变）。
    /// 不设上限时一张 8000×6000 的原图单次解码就是 ~190MB 内存峰值，还在主线程上（2-19）。
    /// 4096 是「贴图聊天够用、内存可控」的折中；等待预算已按实际 TIFF 载荷字节数计算，
    /// 所以收紧上限只会让预算一起变小，不会像原先那样大图必然超时。
    static let maxPayloadPixelSize = 4096

    /// 源图可解码的硬上限（2-19）：`maxPayloadPixelSize` 只管**解码结果**的尺寸，
    /// 管不住**解码过程**——PNG/TIFF/BMP 这类不能分级解码的格式，ImageIO 会先把整张原图
    /// 铺开再重采样，1 亿像素即 ~400MB 峰值。所以单靠长边上限挡不住亿级输入，这条按
    /// 「只读文件头就能拿到像素数」提前拒掉。上限以下（含 8000×6000 的海报）仍正常降采样发送。
    /// 单边再宽也视为文件头异常，顺带保证下面 `width * height` 不会溢出。
    static let maxSourcePixelCount = 100_000_000
    static let maxSourcePixelEdge = 65_535

    /// 只读文件头即可判定，不解码像素。发送侧据此报错，界面侧（缩略图/预览）据此返回 nil。
    static func exceedsDecodableLimit(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= maxSourcePixelEdge, height <= maxSourcePixelEdge else { return true }
        return width * height > maxSourcePixelCount
    }

    /// 前置校验用的轻量检查：只开文件、数帧、读尺寸，**不解码像素**（2-19 (b)）。
    /// 真正的解码留给确实要写进剪贴板的那一次，避免"每张图先全解码一遍再说要发"。
    static func validateReadable(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let size = pixelSize(of: source) else {
            throw AppError(unreadableMessage(name:url.lastPathComponent))
        }
        guard !exceedsDecodableLimit(width:size.width,height:size.height) else {
            throw AppError(pixelLimitMessage(name:url.lastPathComponent))
        }
    }

    // Decode before touching QQ so an invalid file cannot leave a partially composed message.
    static func tiff(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw AppError(unreadableMessage(name:url.lastPathComponent))
        }
        // 先按文件头的像素数把关，再解码：亿级输入在这里就失败，不会先把原图铺开。
        guard !exceedsDecodableLimit(width:width,height:height) else {
            throw AppError(pixelLimitMessage(name:url.lastPathComponent))
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:min(max(width,height),maxPayloadPixelSize),
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: cgImage).tiffRepresentation else {
            throw AppError(unreadableMessage(name:url.lastPathComponent))
        }
        return data
    }
    /// 把全尺寸解码与重编码挪出主线程（2-19 (a)）：在 @MainActor 上 await，解码在后台队列完成后回主线程。
    /// 驱动侧的 attach/precheck 调用点改用它，界面在多图连发时不再逐张冻住。
    static func tiffPayload(at url: URL) async throws -> Data {
        try await Task.detached(priority:.userInitiated) { try tiff(at:url) }.value
    }
    struct ClipboardPayload {
        let tiff: Data
        let png: Data
    }
    /// QQ 使用的两种格式一次性在后台准备。PNG 编码同样可能耗时，不能回主线程后再编码。
    static func clipboardPayload(at url: URL) async throws -> ClipboardPayload {
        try Task.checkCancellation()
        let payload = try await Task.detached(priority: .userInitiated) {
            let tiff = try tiff(at: url)
            guard let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw AppError("图片剪贴板载荷转换失败：\(url.lastPathComponent)，未粘贴图片")
            }
            return ClipboardPayload(tiff: tiff, png: png)
        }.value
        try Task.checkCancellation()
        return payload
    }
    static func thumbnail(at url: URL) -> NSImage? {
        // 每次布局都重新解码大图会让素材库滚动卡顿；按文件指纹缓存缩略图。
        // 键含 mtime+size：同路径文件被外部替换后落到新键上，不再返回旧图（2-29）；
        // 条目数与总成本都设了上限，素材删除后残留的条目会被自然淘汰，不需要显式回收（4-23）。
        let key = cacheKey(for:url)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        // 缩略图只有 360px，但解码过程照样会把亿级原图铺开，所以这里同样先按文件头把关。
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let size = pixelSize(of: source), !exceedsDecodableLimit(width:size.width,height:size.height),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:360,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage:image,size:.zero)
        thumbnailCache.setObject(result,forKey:key,cost:Int(image.width * image.height * 4))
        return result
    }
    // 预览弹窗用的更大的图，只在打开时解码一次
    static func largePreview(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let size = pixelSize(of: source), !exceedsDecodableLimit(width:size.width,height:size.height),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:1600,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage:image,size:.zero)
    }
    /// 只读文件头取像素尺寸；取不到返回 nil（等同「无法读取」，不做任何解码）。
    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width,height)
    }
    /// 解码结果按「路径 + 大小 + 修改时间」定键，缺属性时退回路径（读不到属性本就解码失败）。
    private static func cacheKey(for url: URL) -> NSString {
        let values = try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let size = values?.fileSize.map(String.init) ?? "-"
        let mtime = values?.contentModificationDate.map { String(Int64($0.timeIntervalSince1970 * 1_000_000)) } ?? "-"
        return "\(url.path)|\(size)|\(mtime)" as NSString
    }
    private static func unreadableMessage(name: String) -> String {
        "图片无法读取或包含多帧：\(name)。配图请使用静态 PNG、JPG、HEIC 等图片；动图请先导出静态图片"
    }
    /// 超上限不是「读不出来」，文案要说清该怎么办（导出到长边以内），也不要让人以为素材库坏了。
    private static func pixelLimitMessage(name: String) -> String {
        "图片像素过大（超过 \(maxSourcePixelCount / 1_000_000) 百万像素），无法安全解码：\(name)。请先导出长边 \(maxPayloadPixelSize) 以内的静态图片再发送"
    }
    private static let thumbnailCache: NSCache<NSString,NSImage> = {
        let cache = NSCache<NSString,NSImage>()
        // 一屏素材约 40 张，300 张留足滚动余量又不再无界增长；成本上限约 32MB 解码位图。
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}

// Prepare payloads before clearing the clipboard so a missing file preserves its contents.
enum ClipboardCopy {
    static func text(_ text: String, to board: NSPasteboard = .general) throws {
        guard !text.isEmpty else { throw AppError("没有可复制的文字") }
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw AppError("复制失败，请重试") }
    }
    static func file(_ url: URL, isImage: Bool, to board: NSPasteboard = .general) throws {
        guard FileManager.default.isReadableFile(atPath:url.path) else { throw AppError("文件不存在或无法读取：\(url.lastPathComponent)") }
        let item = NSPasteboardItem()
        if isImage {
            let data = try ImageAttachment.tiff(at:url)
            item.setData(data, forType:.tiff)
            if let png = NSBitmapImageRep(data:data)?.representation(using:.png,properties:[:]) {
                item.setData(png, forType:.png)
            }
        } else {
            item.setString(url.absoluteString, forType:.fileURL)
        }
        board.clearContents()
        guard board.writeObjects([item]) else { throw AppError("复制失败，请重试") }
    }
}
