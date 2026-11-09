// 关闭行为探针。
//
// 用途：验证 CloseInterceptor 的决策逻辑与 delegate 转发是否真的生效。
//
// 为什么不写进单元测试：CloseInterceptor 位于可执行目标里，
// 而 SwiftPM 的测试目标目前只依赖引擎库。这里改用**编译真实源码 + 一个 main.swift**
// 的方式 —— 好处是验的是真实实现，而不是 mock。
//
// 为什么用 windowShouldClose 而不是去点关闭按钮：点击需要「辅助功能」权限，
// 而 windowShouldClose 正是关闭按钮最终会走到的那个方法。
//
// 用法：
//   swiftc -O -o /tmp/probe Scripts/probe_close.swift \
//     Sources/SyncApp/Support/Appearance.swift Sources/SyncApp/Support/CloseInterceptor.swift
//   /tmp/probe

import AppKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

// NSWindow 的创建要求 AppKit 已初始化
_ = NSApplication.shared

var failures = 0

func check(_ label: String, _ actual: Bool, _ expected: Bool) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("[PROBE] \(ok ? "PASS" : "FAIL")  \(label)")
    print("[PROBE]        期望 \(expected)，实际 \(actual)")
}

func makeWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
}

/// 用来验证"转发"的替身 delegate：它的 windowShouldClose 返回 false。
final class StubDelegate: NSObject, NSWindowDelegate {
    var closeCallCount = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeCallCount += 1
        return false
    }
}

let interceptor = CloseInterceptor.shared

// ── 用例 1：最小化到菜单栏 → 应当阻止关闭
UserDefaults.standard.set(CloseBehavior.minimizeToMenuBar.rawValue,
                          forKey: PreferenceKey.closeBehavior)
let w1 = makeWindow()
interceptor.attach(to: w1)
check("最小化模式：阻止窗口关闭", interceptor.windowShouldClose(w1), false)
check("最小化模式：窗口被移出屏幕", !w1.isVisible, true)

// ── 用例 2：退出软件 + 无原 delegate → 应当允许关闭
UserDefaults.standard.set(CloseBehavior.quit.rawValue, forKey: PreferenceKey.closeBehavior)
let w2 = makeWindow()
interceptor.attach(to: w2)
check("退出模式：允许窗口关闭", interceptor.windowShouldClose(w2), true)

// ── 用例 3：退出软件 + 有原 delegate 且它拒绝 → 应转发，得到 false
//
// 这条是核心：SwiftUI 的 WindowGroup 窗口本来就有 delegate，
// 覆写后若不转发，AppKit 会因为"本对象不响应"而静默跳过可选回调，
// 把 SwiftUI 自己的窗口管理打断。这条用例专门守住转发没被破坏。
let w3 = makeWindow()
let stub = StubDelegate()
w3.delegate = stub
interceptor.attach(to: w3)
check("退出模式：转发给原 delegate（它拒绝 → false）",
      interceptor.windowShouldClose(w3), false)
check("退出模式：原 delegate 确实被调用到", stub.closeCallCount == 1, true)

// ── 用例 4：转发链不能被弱引用回收
//
// NSWindow.delegate 是弱引用，如果拦截器不强引用原 delegate，
// 它会被立刻回收，转发链断掉 —— 而且只在特定时序下才暴露。
check("原 delegate 仍存活（未被弱引用回收）", w3.delegate === interceptor, true)
check("拦截器保住了原 delegate", stub.closeCallCount >= 1, true)

// ── 用例 5：偏好值归一化
check("未知偏好值回落到默认（最小化）",
      CloseBehavior.from("something-weird") == .minimizeToMenuBar, true)
check("未知外观值回落到默认（跟随系统）",
      AppearanceMode.from(nil) == .system, true)

// ── 用例 6：外观切换方向
check("跟随系统 + 当前深色 → 切到浅色",
      AppearanceMode.system.toggled(currentlyDark: true) == .light, true)
check("跟随系统 + 当前浅色 → 切到深色",
      AppearanceMode.system.toggled(currentlyDark: false) == .dark, true)

print("[PROBE] ------------------------------------------")
if failures == 0 {
    print("[PROBE] 全部通过")
    exit(0)
}
print("[PROBE] 失败 \(failures) 项")
exit(1)
