import Foundation

/// 外观**切换过程**的复现钩子（诊断用）。
///
/// ## 为什么需要它
///
/// 本机没有辅助功能权限（UI 脚本报 -10004），所以"在运行中点选外观模式"这个动作
/// 无法从外部触发。而**切换过程**与"以某模式启动"是两条不同的代码路径：
///
/// * 静态生效：`applicationDidFinishLaunching` → `AppearanceController.apply`
/// * 运行中切换：设置页 Picker → `AppModel.setAppearance` → `AppearanceController.apply`
///   ＋ SwiftUI 侧 `.preferredColorScheme` 的**重新求值**
///
/// 实测静态那条路是正确的（以「跟随系统」启动、系统为深色时整窗一致）。
/// 所以问题只可能在第二条路，而它必须能在运行中触发一次切换才谈得上复现与回归。
///
/// 这个钩子走的就是第二条路：直接调 `AppModel.setAppearance` ——
/// 与用户在设置页点选**完全同一个入口**，不复制任何逻辑。
///
/// ## 用法
///
/// 前提：先把偏好设成**浅色**，并留出足够时间让它落盘，再启动（否则读到的可能是旧值，
/// 观察到的初始状态就不是你以为的那个）：
///
/// ```bash
/// defaults write com.syncengine.desktop AppAppearance light && sleep 2
/// dist/sync-engine.app/Contents/MacOS/sync-engine --appearance-transition-test
/// ```
///
/// 序列：等 4 秒（让初始状态安定）→ 切到「跟随系统」→ 等 6 秒 → 结束（进程继续运行）。
/// 每一拍的模型值与偏好都会打到 stdout，便于和截图对齐。
///
/// 注意它**会写入偏好**（与用户点选一样）—— 用完记得把 `AppAppearance` 调回原值。
enum AppearanceTransitionProbe {

    static let flag = "--appearance-transition-test"

    /// 探针日志路径。
    ///
    /// **写文件而不是打 stdout**：GUI 应用被 `open` 启动时 stdout 不可捕获
    /// （直接执行二进制虽然能捕获，但实测那样启动**窗口不一定出现**）。
    /// 写文件让"能起窗口的启动方式"和"能看到日志"两件事兼得。
    static let logPath = "/tmp/syncapp-appearance-probe.log"

    private static func log(_ text: String) {
        let line = "[UIPROBE] \(text)\n"
        print("[UIPROBE] \(text)")
        let url = URL(fileURLWithPath: logPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func runIfRequested(model: AppModel) async {
        guard let index = CommandLine.arguments.firstIndex(of: flag) else { return }

        // 可选：紧跟一个目标模式（light / dark / system），默认 system。
        // 有了它就能双向回归 —— 「切进去」和「切回来」都可能出问题。
        let requested = CommandLine.arguments.count > index + 1
            ? CommandLine.arguments[index + 1]
            : "system"
        let target = AppearanceMode(rawValue: requested) ?? .system

        func pref() -> String {
            UserDefaults.standard.string(forKey: PreferenceKey.appearance) ?? "(nil)"
        }

        log("启动：偏好=\(pref()) 模型=\(model.appearanceMode.rawValue) 目标=\(target.rawValue)")

        // 让开头的渲染安定下来（窗口建立、首帧绘制）再切，
        // 免得把启动瞬态误当成切换结果 —— 这一步不能省。
        try? await Task.sleep(for: .seconds(4))

        log("切换 → \(target.label)")
        model.setAppearance(target)
        log("切换后：偏好=\(pref()) 模型=\(model.appearanceMode.rawValue)")

        try? await Task.sleep(for: .seconds(6))
        log("结束：偏好=\(pref()) 模型=\(model.appearanceMode.rawValue)")
    }
}
