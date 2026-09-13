import SwiftUI

/// 应用强调色在视图树里的传递通道。
///
/// ## 为什么不能直接用 `Color.accentColor`
///
/// 这是本轮踩到的一个静默不一致：`Color.accentColor` 在 SwiftUI 里解析为
/// **系统强调色**（`NSColor.controlAccentColor`），它**不理会 `.tint()`**。
/// 于是会出现下面这种结果：
///
/// ```swift
/// VStack { ... }.tint(Palette.accent(for: colorScheme))   // 按钮变成橙色
/// ```
/// ```swift
/// Image(systemName: "cpu").foregroundStyle(.accentColor)  // 但这个图标仍是系统蓝
/// ```
///
/// 两者混在一起时，界面上会同时出现橙与蓝，而且**不会报任何错** ——
/// 只有在实际截图里逐像素看才发现得了。
///
/// 所以这里显式定义一条 `appAccent` 环境值，由根视图注入，
/// 各处一律读它。这样"强调色"只有一个来源。
private struct AppAccentKey: EnvironmentKey {
    static let defaultValue: Color = Palette.accentLight
}

extension EnvironmentValues {
    /// 应用强调色。由根视图按当前明暗注入。
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}
