import AppKit
import ApplicationServices

// 只读取样：给 QQ 群里“文字+图片”草稿拍一张辅助功能快照，用来找图片专属的正向信号。
// 全程不点击、不按键、不写任何 AX 值，也不改草稿。用法：
//   swiftc -O Tools/AXComposerSample.swift -o build/ax-composer-sample && ./build/ax-composer-sample "群名"
// 不带参数时取样当前打开的会话。
import Foundation

let wantTitle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.qq").first else {
    print("QQ 未运行"); exit(2)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
// 只是让 Electron 把控件树暴露出来，与 App 自身的 enableContentTree 相同，不改变界面
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetMessagingTimeout(root, 3)

func val(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
    return v
}
func s(_ e: AXUIElement, _ a: String) -> String { val(e, a) as? String ?? "" }
func role(_ e: AXUIElement) -> String { s(e, kAXRoleAttribute) }
func kids(_ e: AXUIElement) -> [AXUIElement] { val(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func cls(_ e: AXUIElement) -> [String] { val(e, "AXDOMClassList") as? [String] ?? [] }
func parent(_ e: AXUIElement) -> AXUIElement? {
    guard let raw = val(e, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(raw, to: AXUIElement.self)
}
func flat(_ e: AXUIElement, _ limit: Int = 4500) -> [AXUIElement] {
    var q = [e]; var i = 0
    while i < q.count && q.count < limit { q.append(contentsOf: kids(q[i]).prefix(limit - q.count)); i += 1 }
    return q
}
func frameOf(_ e: AXUIElement) -> CGRect? {
    guard let pv = val(e, kAXPositionAttribute), let sv = val(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero; var z = CGSize.zero
    AXValueGetValue(unsafeBitCast(pv, to: AXValue.self), .cgPoint, &p)
    AXValueGetValue(unsafeBitCast(sv, to: AXValue.self), .cgSize, &z)
    return CGRect(origin: p, size: z)
}
func esc(_ x: String, _ n: Int = 70) -> String {
    var out = ""
    for u in x.unicodeScalars {
        if u.value == 0xfffc { out += "[FFFC]" } else if u == "\n" { out += "\\n" } else { out.unicodeScalars.append(u) }
    }
    return String(out.prefix(n))
}
guard let windows = val(root, kAXWindowsAttribute) as? [AXUIElement] else { exit(3) }
var picked: AXUIElement? = nil
for w in windows {
    for e in flat(w) where role(e) == kAXTextAreaRole {
        let d = s(e, kAXDescriptionAttribute)
        if wantTitle.isEmpty || d == wantTitle { picked = e; break }
    }
    if picked != nil { break }
}
guard let editor = picked else {
    print("没找到输入框\(wantTitle.isEmpty ? "" : "（会话「\(wantTitle)」）")；请先在 QQ 里打开那条“文字+图片”草稿所在会话。")
    exit(4)
}
let value = s(editor, kAXValueAttribute)
let chars = (val(editor, "AXNumberOfCharacters") as? Int) ?? -1
let trimmed = value.filter { !$0.isNewline && !$0.isWhitespace }
print("=== 只读快照 ===")
print("会话标注 AXDescription = \"\(esc(s(editor, kAXDescriptionAttribute), 40))\"")
print("输入框 class = \(cls(editor).joined(separator: "|"))")
print("AXValue 长度=\(value.count) 去空白=\(trimmed.count) 字符数=\(chars) U+FFFC=\(value.filter { $0 == "\u{fffc}" }.count)")
print("AXValue 开头 = \"\(esc(value, 60))\"")
let tail = String(value.suffix(40))
print("AXValue 结尾 = \"\(esc(tail, 60))\"")
print("--- 输入框子树（含 DOM class）---")
func walk(_ e: AXUIElement, _ d: Int) {
    guard d < 10 else { return }
    let pad = String(repeating: "  ", count: d)
    let f = frameOf(e).map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "?"
    print("\(pad)\(role(e)) cls=\(cls(e).joined(separator: "|")) \(f) value=\"\(esc(s(e, kAXValueAttribute), 34))\" desc=\"\(esc(s(e, kAXDescriptionAttribute), 22))\"")
    for c in kids(e) { walk(c, d + 1) }
}
walk(editor, 0)
print("--- 输入区块（往上找带工具栏的那一层）---")
var cur: AXUIElement = editor
for lvl in 0..<4 {
    guard let p = parent(cur) else { break }
    let branches = kids(p)
    if branches.contains(where: { role($0) == "AXToolbar" }) {
        print("层级\(lvl) class=\(cls(p).joined(separator: "|"))")
        for (i, b) in branches.enumerated() {
            let f = flat(b, 400)
            let classes = Set(f.flatMap { cls($0) }).sorted()
            print("  branch[\(i)] \(role(b)) cls=\(cls(b).joined(separator: "|")) nodes=\(f.count) images=\(f.filter { role($0) == kAXImageRole }.count) buttons=\(f.filter { role($0) == kAXButtonRole }.count)")
            print("     classes=\(classes.prefix(24))")
        }
        break
    }
    cur = p
}
print("只读结束：未点击、未按键、未修改草稿。")
