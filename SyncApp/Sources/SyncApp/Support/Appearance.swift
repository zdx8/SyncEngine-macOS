import AppKit
import SwiftUI

// ───────────────────────────────────────────────────────── 偏好键 --

/// 偏好设置的键，集中在一处。
///
/// 散落在各处的字符串键是典型的"改了一处忘了另一处"来源，
/// 且拼错不会报错，只会静默读不到值。
enum PreferenceKey {
    static let appearance = "AppAppearance"
    static let closeBehavior = "CloseWindowBehavior"
}

// ───────────────────────────────────────────────────────── 外观 --

/// 外观模式。
///
/// 保留「跟随系统」而不只有浅/深两态：macOS 用户普遍会开自动切换
/// （日落到日出），强制固定会让应用在系统切换时格格不入。
/// 顶部的切换按钮在浅/深之间直接切换，设置页提供三态选择以便回到跟随系统。
///
/// ## 「跟随系统」为什么也要解析成具体外观
///
/// 直觉做法是给它 `nil`（"交给系统决定"），但实测那会在**运行中切换**时出问题：
/// 从「浅色」切到「跟随系统」、系统为深色时，SwiftUI 的**详情列会变成一块空白深色
/// 并一直停留**（标题栏仍浅、侧栏中灰，三处不一致，且不会自我恢复）。
/// 静态启动那条路（一开始就是「跟随系统」）反而是好的，所以这个坑只在切换时出现。
///
/// 因此这里统一解析成**具体**外观：`nil` 这个中间态压根不出现，
/// 切换退化成普通的「浅色 → 深色」，两边都能正常重绘。
/// 系统在日落时自动切换的情况，由 `AppModel` 订阅
/// `AppleInterfaceThemeChangedNotification` 后重新解析（见 `systemIsDark(_:)`）。
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 解析后的具体外观。**不返回 `nil`** —— 理由见类型说明。
    func nsAppearance(systemIsDark: Bool) -> NSAppearance? {
        switch self {
        case .system: return NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 解析后的具体配色方案。**不返回 `nil`**。
    func colorScheme(systemIsDark: Bool) -> ColorScheme {
        switch self {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 系统当前的明暗。
    ///
    /// 读全局域里的 `AppleInterfaceStyle`：值存在且为 `Dark` 即深色，缺失即浅色。
    /// **不能用 `NSApp.effectiveAppearance`** —— 应用自己把外观固定成浅色时，
    /// 那个值反映的是我们的覆盖，而不是系统的设置。
    static func systemIsDark(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// 顶部按钮在浅/深之间切换时用的下一个模式。
    ///
    /// 从「跟随系统」进入时，切到**当前实际外观的反面** ——
    /// 这样点击的效果与用户看到的一致；若固定切到某个方向，
    /// 在系统恰好是深色时点一下会"没变化"，很困惑。
    func toggled(currentlyDark: Bool) -> AppearanceMode {
        switch self {
        case .system: return currentlyDark ? .light : .dark
        case .light: return .dark
        case .dark: return .light
        }
    }

    static func from(_ raw: String?) -> AppearanceMode {
        AppearanceMode(rawValue: raw ?? "") ?? .system
    }
}

// ───────────────────────────────────────────────────────── 配色 --

/// 配色令牌。
enum Palette {

    /// 浅色模式强调色 `#22A322` —— 品牌绿的深一档。
    ///
    /// 品牌色是 `#32CD32`（见 `accentDark` 与 `Scripts/make_icon.swift`），
    /// 但它白底只有 **2.12:1**：作为**小字号文字**（引擎状态、徽标、日志级别
    /// 这些 10–12pt）明显偏低，WCAG 对正文要求 4.5:1、非文字图形要求 3:1。
    ///
    /// 所以浅色模式改用同色系深一档的 `#22A322`：白底 **3.3:1**，
    /// 色相一致、一眼仍是同一个绿，但文字读起来清楚得多。
    ///
    /// 注意这**只影响界面强调色**。应用图标底色仍是品牌色 `#32CD32`
    /// （在 `Scripts/make_icon.swift` 里），两者刻意不联动：
    /// 图标是品牌标识，界面强调色要受可读性约束。
    static let accentLight = Color(.sRGB,
                                   red: 0x22 / 255.0, green: 0xA3 / 255.0, blue: 0x22 / 255.0,
                                   opacity: 1.0)

    /// 深色模式强调色 `#32CD32`（LimeGreen）—— 与图标底色同一个品牌色。
    ///
    /// 深色背景上它的对比度为 **7.9:1**，好看又好读，无需调整。
    /// 因此深色模式与浅色模式是**两个不同的值**：这里不是"品牌色分裂"，
    /// 而是同一个品牌绿在两个背景明度下的两种呈现（详见 `accentLight` 的说明）。
    static let accentDark = Color(.sRGB,
                                  red: 0x32 / 255.0, green: 0xCD / 255.0, blue: 0x32 / 255.0,
                                  opacity: 1.0)

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark : accentLight
    }

    /// 警告色。
    ///
    /// **不能与强调色同色系。** 强调色曾经是淡橙，那时警告色只能用红；
    /// 现在强调色是绿，于是把警告色恢复为**琥珀**——
    /// 这在修正一个真实缺陷：此前警告与错误都是红色，
    /// 日志列表里 WARN 与 ERR 两个标签看起来一模一样。
    ///
    /// 取值 `#B86B08`：白底约 4.1:1、深底约 4.1:1，两种模式下都够用，
    /// 因此不需要按明暗拆成两个值（强调色因为品牌色约束才需要特殊处理）。
    static let warning = Color(.sRGB,
                               red: 0.72, green: 0.42, blue: 0.03,
                               opacity: 1.0)
}

// ───────────────────────────────────────────────────── 关闭窗口行为 --

enum CloseBehavior: String, CaseIterable, Identifiable, Sendable {
    case quit
    case minimizeToMenuBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quit: return "退出软件"
        case .minimizeToMenuBar: return "最小化到菜单栏"
        }
    }

    var detail: String {
        switch self {
        case .quit:
            return "关闭主窗口即结束进程。适合把同步当作随用随开的工具。"
        case .minimizeToMenuBar:
            return "关闭主窗口后应用继续驻留在菜单栏，同步任务不受影响。"
        }
    }

    static func from(_ raw: String?) -> CloseBehavior {
        CloseBehavior(rawValue: raw ?? "") ?? .minimizeToMenuBar
    }
}

// ─────────────────────────────────────────────────── 外观应用器 --

/// 把外观设置应用到 AppKit 层面。
///
/// **两处都要设**：
///   * `.preferredColorScheme(...)` —— 管 SwiftUI 绘制的内容（同时决定窗口标题栏）
///   * `NSApp.appearance` —— 管菜单、`NSOpenPanel` 等**不属于任何窗口**的原生部件
///
/// 只设一处会得到"深色标题栏 + 浅色内容"这类割裂观感，且**不会报任何错**，
/// 只有在实际截图里才看得出来。
enum AppearanceController {

    static func apply(_ mode: AppearanceMode, systemIsDark: Bool) {
        let appearance = mode.nsAppearance(systemIsDark: systemIsDark)

        NSApp.appearance = appearance

        // 已打开的窗口要逐个设置 —— 否则标题栏不会立即重绘，
        // 只有新创建的窗口才会用上 `NSApp.appearance` 的新值。
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
