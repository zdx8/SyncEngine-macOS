import SwiftUI
import SyncEngine

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case tasks
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: return "同步任务"
        case .logs: return "同步日志"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: return "arrow.triangle.2.circlepath"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// 主窗口：左侧导航 + 右侧内容。
///
/// 用 `NavigationSplitView` 而非自绘侧栏 —— 它自动处理侧栏折叠、
/// 键盘导航、以及系统外观与强调色的变化。这些细节自绘很难全部做对。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .tasks

    /// 侧栏字号与行距。集中成常量，是为了让"调大/调小"只改一处 ——
    /// 图标与文字分别写死数字时，改一处就会让两者不成比例。
    static let sidebarFontSize: CGFloat = 15
    static let sidebarIconSize: CGFloat = 15

    /// 当前生效的配色方案。**从模型取，不读 `\.colorScheme` 环境值。**
    ///
    /// 两个理由，都是实测踩出来的：
    ///
    /// 1. `\.appAccent` 这类自定义环境值注入到 `NavigationSplitView` 之后，
    ///    侧栏那一列（由 AppKit 的分栏控制器承载）**拿不到**，会退回
    ///    `AppAccentKey.defaultValue`（浅色强调色）—— 深色下侧栏图标因此变成深绿
    ///    `#22A321`，而同一窗口里其它强调色元素是品牌绿 `#32CD32`，两套主题各错一半。
    /// 2. 外观切换的那一瞬，环境值可能与实际渲染不同步。模型值是这一整套外观逻辑的
    ///    唯一来源，读它就不会出现"界面说自己是什么、实际画的是另一个"。
    private var scheme: ColorScheme { model.effectiveColorScheme }

    private var sidebarAccent: Color { Palette.accent(for: scheme) }

    var body: some View {
        NavigationSplitView {
            // 侧栏条目不用 `Label`：`List` 会用**系统强调色**渲染 Label 的图标，
            // 而 `.tint()` 管不到它 —— 结果是在一片自定义强调色里露出几个系统蓝图标。
            // 拆成图标 + 文字并显式着色，颜色就只有一个来源。
            //
            // 字号与行距都显式指定，不吃 `List` 的默认值：默认的侧栏字号偏小
            // （约 13pt）、行距也紧，三个入口缩成一小坨。逐行给 `.padding(.vertical, 6)`
            // 而不是只调字体 —— 只放大文字的话，行与行仍贴在一起，反而更挤。
            List(SidebarItem.allCases, selection: $selection) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: Self.sidebarIconSize))
                        .foregroundStyle(sidebarAccent)
                        .frame(width: 22, alignment: .center)
                    Text(item.title)
                        .font(.system(size: Self.sidebarFontSize))
                }
                .padding(.vertical, 6)
                .tag(item)
            }
            // 字号调大后列宽必须跟着放宽，否则"同步任务"会被截成"同步任…"。
            // 宽度按最长条目（4 个汉字 ≈ 字号 × 4）＋图标＋两处内边距反推。
            .navigationSplitViewColumnWidth(min: 186, ideal: 206, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter()
            }
            .tint(sidebarAccent)
        } detail: {
            // 这里曾有一条常驻的「引擎状态条」（显示版本 · 构建配置 · 哈希并发）。
            // 已按需求移除。工程上的取舍记录在此，免得以后有人当它是漏做：
            // 移除后，**引擎加载失败的可见性下降** —— 界面仍能打开，
            // 但所有操作会失败。现在这条信息只出现在两处：
            //   1. 设置页「引擎」区块（含版本、平台、哈希算法与完整自检结果）
            //   2. 同步日志（引擎初始化成功/失败都会写一条）
            // 若哪天希望"出问题时才提示"，正确做法不是恢复常驻条，
            // 而是**仅在 `model.engineError != nil` 时**插入一条警告条。
            Group {
                switch selection ?? .tasks {
                case .tasks: TasksView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
            // `alignment: .top` 不能省。默认的对齐是 `.center`，而各页的内容
            // 高度是**固有**的（`ContentUnavailableView` 不会撑满），于是整个页面
            // 会被垂直居中 —— 页头「同步任务 0 个」与右上角按钮会浮在窗口正中间，
            // 看起来像布局坏了。实测：修复前页头在 y≈274（窗口高 680）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 强调色统一在这里注入，而不是逐个控件设置 ——
            // 漏设的地方会退回系统强调色，出现两种颜色并存的尴尬。
            .tint(Palette.accent(for: scheme))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    AppearanceToggleButton()
                }
            }
        }
        .navigationTitle("sync-engine")
        // SwiftUI 绘制部分的外观。AppKit 那一半（菜单、面板）由 AppearanceController 负责
        // —— 两处都要设，只设一处会割裂。
        //
        // 传的是**解析后的具体方案**，不传 nil：「跟随系统」在本应用里被解析成
        // 当前系统的那一个（见 AppearanceMode 的说明），nil 那个中间态会让运行中
        // 切换时详情列渲染不出来。
        .preferredColorScheme(model.effectiveColorScheme)
        .tint(Palette.accent(for: scheme))
        // 显式注入强调色。**不能依赖 `Color.accentColor`** ——
        // 它解析的是系统强调色、无视 `.tint()`，会让部分元素保持系统蓝。
        // 详见 AppAccent.swift 的说明。
        .environment(\.appAccent, Palette.accent(for: scheme))
        .task {
            // 把选中项钉在首页 —— **要设两次**。
            //
            // 第一次设是为了"启动即首页"；第二次设是因为它会被改写：
            // 实测同一份二进制多次冷启动，绝大多数落在「同步任务」，
            // 但确实观察到过落在「同步日志」的情况（侧栏高亮与详情页都在第二项）。
            // 时序上像是侧栏（AppKit 承载的 List）在窗口安定下来时把它自己的选中项
            // 推回了绑定，而 `.task` 那次赋值跑在它之前。只设一次的写法会输掉这场竞速。
            //
            // 第二次刻意留出一小段延迟，让侧栏那侧先安定 —— 这样无论谁先谁后，
            // 最终值都是首页，启动页也就是确定的。**启动页不确定会让整套
            // 截图验证失去意义**：两张落在不同页的图无从比较（这个坑已经踩过一次）。
            //
            // 更彻底的做法是从根上消掉这次竞速（例如不让 List 的选中项参与恢复），
            // 但那要改侧栏的数据流；在没定位到确切机制之前，这里选择先保证结果确定。
            selection = .tasks
            try? await Task.sleep(for: .milliseconds(300))
            selection = .tasks
        }
    }
}

/// 右上角的外观切换按钮。
///
/// 在浅色与深色之间直接切换。若当前是「跟随系统」，
/// 切到**当前实际外观的反面** —— 否则系统恰好是深色时点一下会毫无变化。
///
/// 想要回到「跟随系统」，到设置页选择即可（那里提供三态）。
struct AppearanceToggleButton: View {
    @Environment(AppModel.self) private var model

    /// 用模型值而不是 `\.colorScheme` 环境值判断当前明暗 ——
    /// 两者在正常情况下一致，但外观刚切换的那一瞬环境值可能还没跟上，
    /// 而那正是这个按钮要判断方向的时刻。
    private var isDark: Bool { model.effectiveColorScheme == .dark }

    private var symbol: String {
        isDark ? "sun.max.fill" : "moon.fill"
    }

    private var helpText: String {
        let next = model.appearanceMode.toggled(currentlyDark: isDark)
        return "切换到\(next.label)（当前：\(model.appearanceMode.label)）"
    }

    var body: some View {
        Button {
            model.toggleAppearance(currentlyDark: isDark)
        } label: {
            Label("切换外观", systemImage: symbol)
        }
        .help(helpText)
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let scanning = model.tasks.filter(\.isScanning).count

        HStack(spacing: 6) {
            if scanning > 0 {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("正在扫描 \(scanning) 个")
            } else {
                Image(systemName: "checkmark.circle")
                Text("就绪")
            }
            Spacer()
        }
        // 侧栏条目调到 15pt 之后，这里若仍是 10.5pt，"就绪"会显得像被压扁的
        // 附属文字。跟着上调到 12pt（仍是次级信息，所以比条目小一档）。
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
