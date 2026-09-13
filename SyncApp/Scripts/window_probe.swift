// 列出指定进程的窗口编号、标题与尺寸，供 screencapture -l 精确截取单个窗口。
//
// 用途：在无「辅助功能」权限的环境下验证界面（AppleScript 操作 System Events
// 需要该权限，会报 -10004）。CGWindowList 走窗口服务器接口，不需要授权。
//
// **按 PID 匹配而不是按名字**：`kCGWindowOwnerName` 返回的是 Info.plist 里的
// CFBundleName（本地化显示名，如"sync-engine"），不是可执行文件名，两者常常不同。
// 用名字匹配会得到"明明在运行却找不到窗口"这种极难定位的结果。
// PID 是唯一且确定的。
//
// 同时输出 `kCGWindowName`（窗口标题）与 `kCGWindowOwnerName`（应用显示名）：
// 这两项由**系统**给出，是验证"标题改成什么了"最可靠的判据 ——
// 读源码只能证明写了什么，证明不了最终显示的是什么。
//
// 用法：xcrun swift Scripts/window_probe.swift <PID>

import CoreGraphics
import Foundation

guard let pidArgument = CommandLine.arguments.dropFirst().first,
      let targetPID = Int(pidArgument) else {
    FileHandle.standardError.write("用法：window_probe <PID>\n".data(using: .utf8)!)
    exit(2)
}

guard
    let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else {
    FileHandle.standardError.write("无法读取窗口列表\n".data(using: .utf8)!)
    exit(1)
}

var found = 0
for window in raw {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int, pid == targetPID else {
        continue
    }
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    var width = 0.0
    var height = 0.0
    if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
        width = bounds["Width"] as? Double ?? 0
        height = bounds["Height"] as? Double ?? 0
    }
    // 只取普通应用窗口（layer 0），排除阴影、工具提示等辅助窗口
    if layer == 0 && width > 200 {
        let title = window[kCGWindowName as String] as? String ?? "(无标题)"
        let owner = window[kCGWindowOwnerName as String] as? String ?? "(未知)"
        print("windowId=\(number) size=\(Int(width))x\(Int(height))"
              + " title=\"\(title)\" owner=\"\(owner)\"")
        found += 1
    }
}

if found == 0 {
    print("PID \(targetPID) 没有可见主窗口")
    exit(2)
}
