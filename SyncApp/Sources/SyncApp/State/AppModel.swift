import Foundation
import Observation
import SwiftUI
import SyncEngine

/// 应用级状态。
///
/// 刻意只用 Observation 而不引入状态管理框架：当前状态规模（任务列表 + 日志 + 设置）
/// 用 `@Observable` 完全够用，引入第三方框架的收益抵不上它的概念负担与依赖风险。
/// 等到出现复杂的跨页派生计算时再考虑。
///
/// 标 `@MainActor` 是整个并发策略的支点：**界面状态只在主线程读写**，
/// 引擎的重活（扫描 + 哈希）在 `SyncEngine.scan` 内部并发执行，
/// 两者之间只通过 `await` 一次性交接结果。这样就不存在
/// "后台线程改 DTO 导致界面错乱"这类问题。
@Observable
@MainActor
final class AppModel {

    // ── 引擎
    private(set) var engineInfo: EngineInfo?
    private(set) var engineError: String?
    private(set) var selfCheck: SelfCheckReport?

    // ── 数据
    var tasks: [SyncTask] = []
    private(set) var logs: [LogEntry] = []

    // ── 设置
    var computeHash: Bool = true
    var maxEntries: Int = 500

    /// 外观模式。持久化在 UserDefaults，启动时读回。
    private(set) var appearanceMode: AppearanceMode

    /// 系统当前的明暗。
    ///
    /// 「跟随系统」要解析成具体外观（理由见 `AppearanceMode` 的说明），
    /// 所以这个值必须被**缓存**并且**随系统变化更新** ——
    /// 直接读 UserDefaults 的话 SwiftUI 不会知道它变了，界面就不会重绘。
    /// 更新入口是 `startObservingSystemAppearance()`。
    private(set) var systemIsDark: Bool

    /// 实际生效的配色方案（永远是具体的浅/深）。界面一律读它。
    var effectiveColorScheme: ColorScheme {
        appearanceMode.colorScheme(systemIsDark: systemIsDark)
    }

    /// 关闭主窗口时的行为。
    private(set) var closeBehavior: CloseBehavior

    init() {
        let defaults = UserDefaults.standard
        appearanceMode = AppearanceMode.from(defaults.string(forKey: PreferenceKey.appearance))
        systemIsDark = AppearanceMode.systemIsDark(defaults)
        closeBehavior = CloseBehavior.from(defaults.string(forKey: PreferenceKey.closeBehavior))
    }

    /// 日志上限。日志是内存里的环形缓冲，不设上限会在长时间运行时无限增长。
    private let logLimit = 2000

    private var hasInitialized = false

    // MARK: - 初始化

    func initializeIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true

        append(level: .info, source: "应用", message: "启动 · 正在探测同步引擎")
        let info = SyncEngine.info()
        engineInfo = info
        append(
            level: .info,
            source: "引擎",
            message: "已就绪 \(info.version) · \(info.platform) · \(info.buildConfig) · 哈希并发 \(info.hashConcurrency)"
        )
    }

    // MARK: - 日志

    func append(level: LogLevel, source: String, message: String) {
        logs.append(LogEntry(time: Date(), level: level, source: source, message: message))
        if logs.count > logLimit {
            logs.removeFirst(logs.count - logLimit)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - 任务

    func addTask(
        name: String,
        sourcePath: String,
        target: TargetConfiguration,
        mode: SyncMode,
        password: String = ""
    ) {
        let task = SyncTask(
            name: name,
            sourcePath: sourcePath,
            target: target,
            mode: mode
        )
        tasks.append(task)
        saveCredentials(for: task, password: password)
        append(
            level: .info,
            source: "任务",
            message: "新建「\(task.name)」· \(mode.label) · 源 \(shorten(sourcePath))"
                + " → \(target.kind.label) \(target.displayText)"
        )
    }

    func removeTask(_ task: SyncTask) {
        tasks.removeAll { $0.id == task.id }
        // 顺手清掉该目标端的钥匙串记录：留着就是一份没人会再用的凭据，
        // 属于"无主的敏感数据"，越少越好。
        if let endpoint = try? task.target.makeEndpoint() {
            try? CredentialStore.delete(for: endpoint)
        }
        append(level: .info, source: "任务", message: "删除「\(task.name)」")
    }

    func removeTasks(at offsets: IndexSet) {
        let removed = offsets.map { tasks[$0].name }
        tasks.remove(atOffsets: offsets)
        append(level: .info, source: "任务", message: "删除 \(removed.count) 个任务")
    }

    /// 修改已有任务。
    ///
    /// 与 `addTask` 分开而不是共用一个"有 id 就更新"的方法：
    /// 新增与编辑的校验规则与日志文案都不同（比如改名要能看出改了什么），
    /// 合并只会让两边的特例互相干扰。
    func updateTask(
        id: SyncTask.ID,
        name: String,
        sourcePath: String,
        target: TargetConfiguration,
        mode: SyncMode,
        password: String?
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        let before = tasks[index]
        tasks[index].name = name
        tasks[index].sourcePath = sourcePath
        tasks[index].target = target
        tasks[index].mode = mode

        // 源目录变了，之前那次预览的结果就失效了 —— 必须清掉，
        // 否则界面上会显示一份属于旧目录的统计数字，比不显示更糟。
        if before.sourcePath != sourcePath {
            tasks[index].preview = nil
            tasks[index].errorMessage = nil
            tasks[index].lastPreviewAt = nil
        }
        // 同上：目标端改了，旧的连接结论与目录列表就属于另一个位置了。
        if before.target != target {
            tasks[index].targetProbe = nil
            tasks[index].targetProbeError = nil
            tasks[index].targetEntries = nil
        }

        // password 为 nil 表示"用户没动密码框"，此时必须保留钥匙串里已有的值。
        // 只在表单里回填空密码会每次编辑都把密码清掉，用户会莫名其妙连不上。
        if let password {
            saveCredentials(for: tasks[index], password: password)
        }

        var changes: [String] = []
        if before.name != name { changes.append("名称") }
        if before.sourcePath != sourcePath { changes.append("源目录") }
        if before.target.kind != target.kind { changes.append("目标类型") }
        if before.target.address != target.address { changes.append("目标地址") }
        if before.target.subpath != target.subpath { changes.append("目标子目录") }
        if before.target.user != target.user { changes.append("目标账号") }
        if before.target.allowInsecureTLS != target.allowInsecureTLS { changes.append("证书策略") }
        if before.mode != mode { changes.append("同步模式") }

        append(
            level: .info,
            source: "任务",
            message: changes.isEmpty
                ? "修改「\(name)」（内容无变化）"
                : "修改「\(name)」· \(changes.joined(separator: "、"))"
        )
    }

    // MARK: - 目标端连接

    /// 读取某个目标端的凭据。
    ///
    /// 密码只存在于钥匙串，**不放在任务结构里**：任务会出现在日志、
    /// 调试输出、以及将来的配置文件里，密码一旦进去就会到处泄漏。
    func credentials(for target: TargetConfiguration) -> StorageCredentials {
        let stored = (try? target.makeEndpoint())
            .flatMap { try? CredentialStore.load(for: $0) }
        return StorageCredentials(
            user: target.user,
            password: stored?.password ?? "",
            allowInsecureTLS: target.allowInsecureTLS
        )
    }

    func credentials(for task: SyncTask) -> StorageCredentials {
        credentials(for: task.target)
    }

    /// 对任意一份目标端配置做一次真实连接探测。
    ///
    /// 不做任何状态变更、不写日志 —— 这样它既能被任务卡片用（结果写回任务），
    /// 也能被编辑器用（**在任务被创建之前**就能验证配置对不对）。
    /// 之前想只给卡片用，结果编辑器里就没法测了，而"保存前先试一试"
    /// 恰恰是用户最需要它的地方。
    ///
    /// - Parameter password: 非空时用它，为空时回落到钥匙串里已存的密码。
    func probe(
        target: TargetConfiguration,
        password: String = ""
    ) async -> Result<StorageProbe, Error> {
        do {
            let endpoint = try target.makeEndpoint()
            let credentials = password.isEmpty
                ? credentials(for: target)
                : StorageCredentials(
                    user: target.user,
                    password: password,
                    allowInsecureTLS: target.allowInsecureTLS
                )
            let driver = StorageDriverFactory.make(endpoint: endpoint, credentials: credentials)
            return .success(try await driver.probe())
        } catch {
            return .failure(error)
        }
    }

    /// 把凭据写入钥匙串。
    ///
    /// 用户名与密码都为空时**删除**记录而不是存一条空记录 ——
    /// 访客访问是合法配置，不该在钥匙串里留下一个无用的条目。
    func saveCredentials(for task: SyncTask, password: String) {
        guard let endpoint = try? task.target.makeEndpoint() else { return }
        let credentials = StorageCredentials(
            user: task.target.user,
            password: password,
            allowInsecureTLS: task.target.allowInsecureTLS
        )
        do {
            if credentials.isAnonymous {
                try CredentialStore.delete(for: endpoint)
            } else {
                try CredentialStore.save(credentials, for: endpoint)
                append(level: .info, source: "凭据", message: "已保存到系统钥匙串：\(endpoint.displayText)")
            }
        } catch {
            append(level: .warning, source: "凭据", message: "写入钥匙串失败：\(error.localizedDescription)")
        }
    }

    /// 目标端连接测试。
    ///
    /// **这是一次真实往返**：SMB 会真的去挂载（或复用已挂载的卷），
    /// WebDAV 会真的发 PROPFIND。只做本地格式校验的"测试连接"是没有意义的 ——
    /// 用户点它就是为了知道"能不能连上"。
    func testTargetConnection(_ taskID: SyncTask.ID) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard !tasks[index].isProbingTarget else { return }

        let task = tasks[index]
        tasks[index].isProbingTarget = true
        tasks[index].targetProbeError = nil
        tasks[index].targetProbe = nil

        append(
            level: .info,
            source: "目标",
            message: "连接测试「\(task.name)」· \(task.target.kind.label) · \(task.target.displayText)"
                + (task.target.kind.requiresCredentials
                    ? " · \(task.target.user.isEmpty ? "访客" : "用户 \(task.target.user)")"
                    : "")
        )

        do {
            let endpoint = try task.target.makeEndpoint()
            let driver = StorageDriverFactory.make(
                endpoint: endpoint,
                credentials: credentials(for: task)
            )

            let probe = try await driver.probe()

            // 用 id 重新定位：await 期间数组可能已被用户改动，
            // 按下标写回会改到别的任务上。
            guard let current = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[current].isProbingTarget = false
            tasks[current].targetProbe = probe

            append(
                level: .info,
                source: "目标",
                message: "连接成功 · \(probe.resolvedLocation)"
                    + " · \(ByteFormatter.string(fromSeconds: probe.elapsedSeconds))"
            )
            if let serverInfo = probe.serverInfo, !serverInfo.isEmpty {
                append(level: .info, source: "目标", message: "服务端：\(serverInfo)")
            }
            if let count = probe.rootEntryCount {
                append(level: .info, source: "目标", message: "基准目录下 \(count) 个条目")
            }
            if let writable = probe.isWritable {
                append(
                    level: writable ? .info : .warning,
                    source: "目标",
                    message: writable ? "目标端可写" : "目标端只读 —— 同步时无法写入，请检查权限"
                )
            } else {
                append(level: .info, source: "目标", message: "无法判定目标端是否可写（服务端未提供权限信息）")
            }
            for note in probe.notes {
                append(level: .info, source: "目标", message: note)
            }

            // 顺手列一次根目录：这既是给用户看的，也是"驱动真的能读"的证据。
            tasks[current].targetEntries = try? await driver.list(relativePath: "")
        } catch {
            guard let current = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[current].isProbingTarget = false
            tasks[current].targetProbeError = error.localizedDescription
            append(level: .error, source: "目标", message: "连接失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 偏好设置

    func setAppearance(_ mode: AppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKey.appearance)
        AppearanceController.apply(mode, systemIsDark: systemIsDark)
        append(level: .info, source: "设置", message: "外观切换为「\(mode.label)」")
    }

    // MARK: - 系统外观变化

    private var systemAppearanceObserver: NSObjectProtocol?

    /// 订阅系统外观变化（日落/日出自动切换，或用户在系统设置里改）。
    ///
    /// 为什么需要它：我们把「跟随系统」解析成了**具体**外观，于是系统切换时
    /// 系统不会再替我们更新窗口 —— 必须自己重新解析一次。
    /// 这也正是"跟随系统"这个选项存在的意义（见 `AppearanceMode` 的说明），漏了这一步
    /// 它就成了"启动那一刻的系统外观"，而不是真的跟随。
    ///
    /// 用分布式通知 `AppleInterfaceThemeChangedNotification`：它是系统外观变化的
    /// 公开信号（不依赖我们的应用外观覆盖，`NSApp.effectiveAppearance` 做不到这一点）。
    func startObservingSystemAppearance() {
        guard systemAppearanceObserver == nil else { return }
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 通知到达时偏好可能还没落盘，稍等一下再读 —— 立刻读容易读到旧值。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                self?.systemAppearanceDidChange()
            }
        }
    }

    private func systemAppearanceDidChange() {
        let isDark = AppearanceMode.systemIsDark()
        guard isDark != systemIsDark else { return }
        systemIsDark = isDark
        append(
            level: .info, source: "设置",
            message: "系统外观变为\(isDark ? "深色" : "浅色")"
                + (appearanceMode == .system ? "，界面跟随更新" : "（当前为\(appearanceMode.label)，不跟随）")
        )
        // 只在「跟随系统」时需要重新应用；浅/深是固定值，不受系统影响。
        guard appearanceMode == .system else { return }
        AppearanceController.apply(.system, systemIsDark: systemIsDark)
    }

    /// 顶部切换按钮的动作：在浅色与深色之间切换。
    ///
    /// - Parameter currentlyDark: **当前实际生效的外观**是否为深色。
    ///   从「跟随系统」进入时，要切到当前外观的反面 ——
    ///   这样点击的效果与用户看到的画面一致；若固定切到某个方向，
    ///   系统恰好是深色时点一下会"毫无变化"，很困惑。
    func toggleAppearance(currentlyDark: Bool) {
        setAppearance(appearanceMode.toggled(currentlyDark: currentlyDark))
    }

    func setCloseBehavior(_ behavior: CloseBehavior) {
        guard closeBehavior != behavior else { return }
        closeBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: PreferenceKey.closeBehavior)
        append(level: .info, source: "设置", message: "关闭主窗口时：\(behavior.label)")
    }

    // MARK: - 预览扫描

    /// 对任务源目录做一次真实扫描。
    ///
    /// 这是本应用目前唯一真正调用引擎的操作。
    /// 注意 `SyncEngine.scan` 是 async 的，且内部会把哈希并发跑在
    /// 协作线程池上 —— 主线程只在开始时让出、结束时拿回结果，全程不阻塞。
    func previewScan(_ taskID: SyncTask.ID) async {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard !tasks[index].isScanning else { return }

        tasks[index].isScanning = true
        tasks[index].errorMessage = nil
        let sourcePath = tasks[index].sourcePath
        let taskName = tasks[index].name

        append(
            level: .info,
            source: "引擎",
            message: "扫描「\(taskName)」· 源 \(shorten(sourcePath))"
                + (computeHash ? " · 计算 SHA-256" : " · 跳过哈希")
        )

        do {
            let result = try await SyncEngine.scan(
                root: sourcePath,
                options: ScanOptions(computeHash: computeHash, maxEntries: maxEntries)
            )

            // 用 id 重新定位：await 期间数组可能已被用户改动，
            // 按下标写回会改到别的任务上。
            guard let current = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[current].preview = result
            tasks[current].lastPreviewAt = Date()
            tasks[current].isScanning = false

            append(
                level: .info,
                source: "引擎",
                message: "完成 · \(result.fileCount) 文件 / \(result.directoryCount) 目录 / "
                    + "\(ByteFormatter.string(fromBytes: result.totalBytes))"
            )
            append(
                level: .info,
                source: "引擎",
                message: "耗时 · 遍历 \(ByteFormatter.string(fromSeconds: result.walkSeconds))"
                    + " / 哈希 \(ByteFormatter.string(fromSeconds: result.hashSeconds))"
                    + " / 合计 \(ByteFormatter.string(fromSeconds: result.elapsedSeconds))"
            )

            if result.readErrors > 0 || result.hashErrors > 0 {
                append(
                    level: .warning,
                    source: "引擎",
                    message: "有 \(result.readErrors) 项读取失败、\(result.hashErrors) 项哈希失败（多为权限所限）"
                )
            }
            if result.symlinksSkipped > 0 {
                append(
                    level: .info,
                    source: "引擎",
                    message: "跳过 \(result.symlinksSkipped) 个软链接（引擎一律不跟随，避免目录环与重复计数）"
                )
            }
        } catch {
            guard let current = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[current].isScanning = false
            tasks[current].errorMessage = error.localizedDescription
            append(level: .error, source: "引擎", message: "扫描失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 自检

    /// 引擎正确性自检。
    ///
    /// 判据用 **SHA-256 的官方测试向量**。用手算常量比对，能一次性覆盖
    /// 「哈希实现 + 文件分块读取 + 数据传递」整条路径：
    /// 任何一环出错（例如分块边界少读一个字节）都会让摘要不符。
    func runSelfCheck() async {
        selfCheck = nil
        var items: [CheckItem] = []
        var failure: String?

        do {
            let info = SyncEngine.info()
            items.append(CheckItem(
                label: "引擎信息可读",
                passed: true,
                detail: "\(info.version) · \(info.platform) · \(info.hashAlgorithm)"
            ))
            items.append(CheckItem(
                label: "运行平台为 macOS",
                passed: info.platform.contains("macOS"),
                detail: info.platform
            ))

            // SHA-256("") 与 SHA-256("abc") 的 NIST 标准向量
            let emptyVector = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            let abcVector = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

            let emptyHash = ContentHasher.sha256(of: Data())
            items.append(CheckItem(
                label: "SHA-256(\"\") 匹配官方向量",
                passed: emptyHash == emptyVector,
                detail: emptyHash == emptyVector ? String(emptyVector.prefix(32)) + "…" : "得到 \(emptyHash)"
            ))

            let abcHash = ContentHasher.sha256(of: Data("abc".utf8))
            items.append(CheckItem(
                label: "SHA-256(\"abc\") 匹配官方向量",
                passed: abcHash == abcVector,
                detail: abcHash == abcVector ? String(abcVector.prefix(32)) + "…" : "得到 \(abcHash)"
            ))

            // 流式分块：写一个跨多个缓冲区、且尾块不满的文件，
            // 确认分块读取与一次性计算一致。这是文件哈希路径的核心正确性。
            let probe = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-selfcheck-\(UUID().uuidString).bin")
            let byteCount = ContentHasher.chunkSize * 2 + 12_345
            var payload = Data(count: byteCount)
            for index in 0..<byteCount { payload[index] = UInt8(index % 251) }
            try payload.write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }

            let streamed = try ContentHasher.sha256(ofFileAt: probe.path)
            let oneShot = ContentHasher.sha256(of: payload)
            items.append(CheckItem(
                label: "流式文件哈希与一次性一致",
                passed: streamed == oneShot,
                detail: "\(byteCount) 字节 · \(String(streamed.prefix(16)))…"
            ))

            // 真实目录扫描一次，确认异步 + 并发路径可用
            let target = FileManager.default.currentDirectoryPath
            let scan = try await SyncEngine.scan(
                root: target,
                options: ScanOptions(computeHash: true, maxEntries: 20)
            )
            items.append(CheckItem(
                label: "目录扫描可用（含并发哈希）",
                passed: scan.fileCount > 0 && scan.hashedCount == scan.fileCount,
                detail: "\(scan.fileCount) 文件 / \(ByteFormatter.string(fromBytes: scan.totalBytes))"
                    + " / \(ByteFormatter.string(fromSeconds: scan.elapsedSeconds))"
            ))
            items.append(CheckItem(
                label: "分项计时之和不超过总耗时",
                passed: scan.walkSeconds + scan.hashSeconds <= scan.elapsedSeconds + 0.005,
                detail: "遍历 \(ByteFormatter.string(fromSeconds: scan.walkSeconds))"
                    + " + 哈希 \(ByteFormatter.string(fromSeconds: scan.hashSeconds))"
                    + " ≤ 合计 \(ByteFormatter.string(fromSeconds: scan.elapsedSeconds))"
            ))
        } catch {
            failure = error.localizedDescription
        }

        selfCheck = SelfCheckReport(items: items, errorMessage: failure)
        if selfCheck?.allPassed == true {
            append(level: .info, source: "自检", message: "全部通过（\(items.count) 项）")
        } else {
            append(level: .error, source: "自检", message: "存在失败项：\(failure ?? "见详情")")
        }
    }

    // MARK: - 辅助

    private func shorten(_ path: String) -> String {
        let limit = 48
        guard path.count > limit else { return path }
        return "…" + path.suffix(limit - 1)
    }
}
