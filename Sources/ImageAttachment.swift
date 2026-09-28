import AppKit
import ImageIO

enum ImageAttachment {
    // Decode before touching QQ so an invalid file cannot leave a partially composed message.
    static func tiff(at url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:max(width,height),
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: cgImage).tiffRepresentation else {
            throw AppError("图片无法读取或包含多帧：\(url.lastPathComponent)。配图请使用静态 PNG、JPG、HEIC 等图片；动图请先导出静态图片")
        }
        return data
    }
    static func thumbnail(at url: URL) -> NSImage? {
        // 每次布局都重新解码大图会让素材库滚动卡顿；按文件路径缓存缩略图
        let key = url.path as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:360,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else { return nil }
        let result = NSImage(cgImage:image,size:.zero)
        thumbnailCache.setObject(result, forKey: key)
        return result
    }
    // 预览弹窗用的更大的图，只在打开时解码一次
    static func largePreview(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:1600,
                kCGImageSourceCreateThumbnailWithTransform:true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage:image,size:.zero)
    }
    private static let thumbnailCache = NSCache<NSString, NSImage>()
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
