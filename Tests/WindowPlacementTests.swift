import Foundation

@main struct WindowPlacementTests {
    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AppError(message) }
            passed += 1; print("PASS: \(message)")
        }
        // 本机三个显示器的 AX 可见工作区，含上方和负 X 的显示器。
        let screens = [CGRect(x: 0, y: 39, width: 1800, height: 1070),
                       CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                       CGRect(x: -1920, y: -490, width: 1920, height: 1080)]
        let normal = CGRect(x: 400, y: 200, width: 900, height: 700)
        try check(WindowRestorePlacement.fitted(normal, within: screens) == normal, "可见正常窗口的位置与尺寸不变")
        let broken = CGRect(x: 1116, y: 1084, width: 400, height: 830)
        let repaired = WindowRestorePlacement.fitted(broken, within: screens)
        try check(repaired == CGRect(x: 1116, y: 279, width: 400, height: 830), "本机 QQ 底边外窗口完整回到工作区，保持尺寸")
        try check(repaired.map { screens[0].contains($0) } == true && !screens.contains { $0.contains(CGPoint(x: broken.midX, y: broken.midY)) },
                  "修复前点击中心在所有显示器之外，修复后全部窗口可见")
        let negative = CGRect(x: -1800, y: -400, width: 700, height: 600)
        try check(WindowRestorePlacement.fitted(negative, within: screens) == negative, "负坐标外接显示器上的可见窗口不搬动")
        let removedScreen = CGRect(x: 2500, y: -800, width: 500, height: 700)
        let relocated = WindowRestorePlacement.fitted(removedScreen, within: screens)
        try check(relocated == CGRect(x: 1420, y: -800, width: 500, height: 700), "已移除显示器上的窗口恢复到最近可用显示器")
        let oversized = CGRect(x: 10, y: 50, width: 3000, height: 2000)
        let resized = WindowRestorePlacement.fitted(oversized, within: [screens[0]])
        try check(resized == screens[0], "大于当前工作区的旧尺寸限制到可用范围")
        try check(WindowRestorePlacement.fitted(normal, within: []) == nil, "缺失显示器数据不宣称已恢复")
        try check(WindowRestorePlacement.fitted(CGRect(x: 0, y: 0, width: 0, height: 1), within: screens) == nil, "不可见零尺寸窗口拒绝恢复")
        try check(WindowRestorePlacement.fitted(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1), within: screens) == nil, "无限窗口尺寸不参与坐标计算")
        try check(WindowRestorePlacement.fitted(normal, within: [.null, screens[0]]) == normal, "无效屏幕不污染有效工作区")
        print("Window Placement: \(passed) checks passed; pure geometry, no UI or QQ actions")
    }
}
