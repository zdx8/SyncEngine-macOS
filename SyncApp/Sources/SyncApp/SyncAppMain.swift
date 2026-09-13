import AppKit
import SwiftUI
import SyncEngine

// ─────────────────────────────────────────────────────────── 入口 --

/// 应用入口。
///
/// 手工分流而不是依赖编译器生成入口：这样**同一个二进制**既能双击运行，
/// 又能被脚本以 `--selfcheck` 驱动做自动化验证。
/// 若把自检做成独立的可执行文件，验证到的就不是真正交付的那份产物了。
@main
enum SyncAppEntry {
    /// 无界面模式的参数。
    ///
    /// **新增无界面模式时必须加到这张表里**：判断散落在多处很容易漏改，
    /// 而漏改的表现是「GUI 悄悄启动了、命令行一直不返回」——
    /// 因为窗口开在那里等用户操作。这个症状极具误导性，会让人去查引擎，
    /// 而问题其实在参数分流。
    static let headlessFlags = ["--selfcheck", "--bench"]

    static func main() {
        let arguments = CommandLine.arguments
        if headlessFlags.contains(where: { arguments.contains($0) }) {
            HeadlessRunner.run(arguments: Array(arguments.dropFirst()))
            // HeadlessRunner.run 的返回类型是 Never，控制流不会走到这里
        }
        DataSyncApp.main()
    }
}

struct DataSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("sync-engine", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 600)
                .task {
                    model.initializeIfNeeded()
                    // 「跟随系统」被解析成了具体外观，所以系统切换时要自己重新解析一次。
                    model.startObservingSystemAppearance()
                    // 诊断钩子：带 --appearance-transition-test 时复现"运行中切换外观"。
                    // 见 Support/AppearanceTransitionProbe.swift 的说明。
                    await AppearanceTransitionProbe.runIfRequested(model: model)
                }
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            // 去掉系统默认的"新建窗口"菜单项 —— 这是单窗口工具，
            // 多开窗口会让同一份任务列表出现多个互不同步的视图，反而令人困惑。
            CommandGroup(replacing: .newItem) {}
        }

        // 菜单栏常驻项：关闭主窗口后仍能看到状态并唤回窗口。
        // 同步工具是"后台干活"的形态，没有这个入口体验会很别扭。
        MenuBarExtra("sync-engine", systemImage: "arrow.triangle.2.circlepath") {
            MenuBarContent()
                .environment(model)
        }
    }
}

// ─────────────────────────────────────────────────────── 应用委托 --

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从命令行直接启动二进制时，必须显式声明为常规前台应用，
        // 否则进程不会出现在 Dock、也拿不到键盘焦点（表现为"启动了但没反应"）。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 外观：把上次选择的模式应用到 AppKit 层面（菜单、面板等不隶属任何窗口的部件）。
        // SwiftUI 绘制的那一半由根视图的 preferredColorScheme 负责 —— 两处缺一不可。
        //
        // 「跟随系统」也在这里解析成**具体**外观：交给系统（设 nil）会让运行中
        // 从浅色切到跟随系统时的详情列变成空白并卡住，详见 AppearanceMode 的说明。
        AppearanceController.apply(
            AppearanceMode.from(
                UserDefaults.standard.string(forKey: PreferenceKey.appearance)),
            systemIsDark: AppearanceMode.systemIsDark()
        )

        // 接管主窗口的关闭行为 + 关闭窗口状态恢复。
        //
        // 不能在 didFinishLaunching 里直接找窗口 —— 此时 SwiftUI 还没创建它。
        // 改为监听窗口成为 key，那时窗口一定已存在且已挂上 SwiftUI 自己的 delegate。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            // 不恢复窗口状态。
            //
            // macOS 默认会把上次退出时的侧栏选中项、滚动位置等带到下一次启动。
            // 对本应用有两个实际问题：
            //   1. 用户"随手打开"时以为落在首页，实际落在上次那一页；
            //   2. **截图验证变得不可复现** —— 实测同一主题连续启动两次，
            //      截出来的图内容不同（一次在同步任务页、一次在设置页）。
            //      依赖截图的验证手段一旦不可复现，就等于没有验证。
            // 界面状态本来就在内存里、重建成本为零，恢复它没有收益。
            (note.object as? NSWindow)?.isRestorable = false

            CloseInterceptor.attachToMainWindowIfNeeded()
        }
    }

    /// 关闭最后一个窗口后是否退出应用。
    ///
    /// 由设置决定：
    ///   * 「退出软件」→ true，关窗即结束进程
    ///   * 「最小化到菜单栏」→ false，进程与菜单栏项都保留
    ///
    /// 注意这与 `CloseInterceptor.windowShouldClose` 是**两件事**：
    /// 前者决定"窗口该不该关"，这里决定"窗口关掉之后应用要不要退"。
    /// 两种行为都要配套设置，只改一处会出现"窗口关了但进程还在"或者
    /// "拦截了关闭却仍然退出了"这类不一致。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CloseBehavior.from(
            UserDefaults.standard.string(forKey: PreferenceKey.closeBehavior)
        ) == .quit
    }
}

// ─────────────────────────────────────────────────────── 菜单栏内容 --

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .keyboardShortcut("o")

        Divider()

        Text("\(model.tasks.count) 个任务 · \(model.logs.count) 条日志")

        if model.tasks.contains(where: \.isScanning) {
            Text("正在扫描…")
        } else {
            Text("就绪")
        }

        Divider()

        Button("退出 sync-engine") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
