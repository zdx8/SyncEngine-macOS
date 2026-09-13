import AppKit

/// 接管主窗口的关闭行为。
///
/// ## 为什么必须转发而不是直接替换
///
/// SwiftUI 的 `WindowGroup` 窗口**已经有 delegate 了**（实测类名 `AppKitWindowController`），
/// 并不是 nil。所以：
///
/// 1. 不能用「delegate == nil 才挂」这种守卫 —— 那样拦截永远挂不上
/// 2. 覆写后必须把未处理的消息**转发**给原 delegate，否则 AppKit 会因为
///    「本对象不响应」而静默跳过全部可选回调，把 SwiftUI 的窗口管理整个打断
/// 3. `NSWindow.delegate` 是**弱引用**，必须自己强引用原 delegate，
///    否则它会被立刻回收，转发链断掉
///
/// ## 为什么用结构判定而不是窗口标题
///
/// `WindowGroup(" ")` 的标题可能就是个空格，还会随系统本地化变化。
/// 改为按结构判断，并排除面板与工作表 —— 否则会把 SwiftUI 的 `.sheet`
/// 也挂上拦截，导致"新建任务"表单关不掉。
final class CloseInterceptor: NSObject, NSWindowDelegate {

    static let shared = CloseInterceptor()

    private var forwardee: NSWindowDelegate?
    private weak var attachedWindow: NSWindow?

    private override init() { super.init() }

    /// 找到主窗口并挂上拦截。可重复调用，已挂则跳过。
    static func attachToMainWindowIfNeeded() {
        guard let window = NSApp.windows.first(where: isMainWindowCandidate) else { return }
        shared.attach(to: window)
    }

    private static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        // 排除：面板（如 NSOpenPanel）、工作表（sheet）、没有内容控制器的窗口
        !(window is NSPanel)
            && !window.isSheet
            && window.sheetParent == nil
            && window.contentViewController != nil
            && window.styleMask.contains(.titled)
    }

    func attach(to window: NSWindow) {
        guard attachedWindow !== window else { return }
        // 无条件重设 forwardee —— 不要写成「新窗口有 delegate 才更新」。
        // 那样在切换窗口时会把上一个窗口的 delegate 一直留着，
        // 之后所有转发都送给一个无关的对象。单窗口下看不出来，
        // 一旦将来支持多窗口就会变成"某个窗口的关闭行为莫名其妙"。
        forwardee = (window.delegate !== self) ? window.delegate : nil
        window.delegate = self
        attachedWindow = window
    }

    // MARK: 转发

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardee?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        guard !super.responds(to: selector) else { return nil }
        return (forwardee?.responds(to: selector) ?? false) ? forwardee : nil
    }

    // MARK: 拦截

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch CloseBehavior.from(UserDefaults.standard.string(forKey: PreferenceKey.closeBehavior)) {
        case .quit:
            // 交回原 delegate 决定，保持 SwiftUI 自己的收尾逻辑
            return forwardee?.windowShouldClose?(sender) ?? true

        case .minimizeToMenuBar:
            // 返回 false 阻止关闭；窗口只是隐藏，进程与菜单栏项都留在原地。
            //
            // 注意不要用 orderOut 之外的方式"假装关闭"—— 保持窗口实例存活，
            // 用户从菜单栏再打开时才能恢复原来的滚动位置与选中项。
            sender.orderOut(nil)
            return false
        }
    }
}
