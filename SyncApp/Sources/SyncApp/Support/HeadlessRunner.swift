import AppKit
import Foundation
import SyncEngine

/// 无界面自检。
///
/// ## 为什么要有它
///
/// 单元测试（`swift test`）验证的是引擎源码；而这里跑的是**打包后真正交付的那个二进制**。
/// 两者覆盖的路径不同：打包可能漏掉文件、签名可能失效、链接可能缺框架。
/// 用交付产物本身跑一遍，才能证明"用户拿到的这个东西是能工作的"。
///
/// 用法：
/// ```
/// sync-engine.app/Contents/MacOS/sync-engine --selfcheck [待扫描目录]
/// ```
/// 退出码 0 表示全部通过。
///
/// ## 为什么不用 dispatchMain()
///
/// 实测结论：用 `Task { } + dispatchMain()` 驱动时，`@MainActor` 函数体内
/// 甚至 `MainActor.run { }` 内部，`Thread.isMainThread` **恒为 false**。
/// 于是任何 `NSWindow` / `NSHostingView` 的创建都会直接抛
/// `NSInternalInconsistencyException: NSWindow should only be instantiated on the main thread`，
/// 而用 `DispatchQueue.main.sync` 补救会**彻底死锁** —— 因为主队列根本没被排空。
///
/// 根因是 `dispatchMain()` 让主线程停在 `dispatch_main()` 里，
/// Swift 运行时的 MainActor 执行器拿不到主队列。
///
/// 正确做法是**自己泵主 RunLoop**：主队列与 MainActor 都会被正常服务。
enum HeadlessRunner {

    static func run(arguments: [String]) -> Never {
        // 输出走管道时默认块缓冲，进程异常终止会丢掉全部日志 ——
        // 而"进程异常终止"恰恰是最需要看到日志的场景。
        setvbuf(stdout, nil, _IONBF, 0)

        let exitCode = SendableBox<Int32>(1)
        let finished = SendableBox(false)

        Task {
            if arguments.contains("--bench") {
                exitCode.value = await runBenchmark(arguments: arguments)
            } else {
                exitCode.value = await execute(arguments: arguments)
            }
            finished.value = true
        }

        while !finished.value {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        exit(exitCode.value)
    }

    // MARK: - 性能基准

    /// 扫描基准，用于量化「并发哈希」是否真的生效。
    ///
    /// 用法：`SyncApp --bench <目录> [并发数]`，并发数省略时用引擎默认值。
    ///
    /// 之所以要能指定并发数：只跑默认值看不出并发有没有起作用 ——
    /// 结果快和慢都无法归因。用 1 与 N 各跑一次做对照，
    /// 「多核是否真的被用上」就变成一个可判定的问题。
    @MainActor
    private static func runBenchmark(arguments: [String]) async -> Int32 {
        let positionals = arguments.filter { !$0.hasPrefix("-") }
            .filter { $0 != arguments.first }  // 去掉 --bench 自身
        let target = positionals.first ?? FileManager.default.currentDirectoryPath
        let concurrency = positionals.count > 1 ? (Int(positionals[1]) ?? 0) : 0

        print("[BENCH] 目录：\(target)")
        print("[BENCH] 并发：\(concurrency > 0 ? "\(concurrency)" : "自动（\(SyncEngine.defaultConcurrency)）")")

        do {
            let result = try await SyncEngine.scan(
                root: target,
                options: ScanOptions(
                    computeHash: true,
                    maxEntries: 1,
                    maxConcurrentHashes: concurrency
                )
            )
            print("[BENCH] 文件 \(result.fileCount) · 目录 \(result.directoryCount) · "
                + ByteFormatter.string(fromBytes: result.totalBytes))
            print("[BENCH] 遍历 \(ByteFormatter.string(fromSeconds: result.walkSeconds))"
                + " · 哈希 \(ByteFormatter.string(fromSeconds: result.hashSeconds))"
                + " · 合计 \(ByteFormatter.string(fromSeconds: result.elapsedSeconds))")
            if let throughput = result.hashThroughputMBps {
                print(String(format: "[BENCH] 哈希吞吐 %.0f MB/s", throughput))
            }
            if result.hashErrors > 0 || result.readErrors > 0 {
                print("[BENCH] 读取失败 \(result.readErrors) · 哈希失败 \(result.hashErrors)")
            }
            return 0
        } catch {
            print("[BENCH] 失败：\(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - 自检内容

    /// 在**同步**上下文里读 `Thread.isMainThread`。
    ///
    /// 为什么不能直接在 async 函数里读：SDK 把它标记为
    /// `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`，因为"当前线程是否是主线程"
    /// 在 async 世界里本就不是一个稳定的问题（挂起点前后可能换线程）。
    ///
    /// 但对本场景它恰好是有意义的：我们已经用 RunLoop 泵住了主线程，
    /// 这里要验证的正是"主 actor 的执行器确实在服务主队列"。
    /// 通过一个非 async 的函数去读，就绕开了那条限制，且语义没有变。
    private static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    /// 标 `@MainActor` 是刻意的，有两个作用：
    ///
    /// 1. 让 `Thread.isMainThread` 断言真的有意义。未标隔离的 async 函数会跑在
    ///    协作线程池上，断言必然为 false，那条"必须在主线程"的检查就形同虚设。
    /// 2. 真实复刻界面路径的调用方式 —— 界面就是从主 actor 调 `SyncEngine.scan` 的。
    ///
    /// 注意 `SyncEngine.scan` 是 nonisolated 的，从主 actor `await` 它时
    /// 会切到通用执行器上运行，因此引擎的重活不会阻塞主线程。
    @MainActor
    private static func execute(arguments: [String]) async -> Int32 {
        var failures = 0

        func report(_ label: String, _ passed: Bool, _ detail: String) {
            let mark = passed ? "PASS" : "FAIL"
            print("[SELFCHECK] \(mark)  \(label)")
            if !detail.isEmpty {
                print("[SELFCHECK]        \(detail)")
            }
            if !passed { failures += 1 }
        }

        print("[SELFCHECK] sync-engine —— 无界面自检")
        print("[SELFCHECK] 二进制：\(CommandLine.arguments[0])")
        print("[SELFCHECK] 主线程：\(isOnMainThread())")

        // 主线程断言：把"必须在主线程"这个前提固化进自检。
        // 将来有人改回 dispatchMain()，会以这条断言失败的形式暴露，
        // 而不是等到某个界面组件创建时崩溃。
        let onMain = isOnMainThread()
        report("运行在主线程", onMain, "Thread.isMainThread == \(onMain)")

        // ── 引擎
        let info = SyncEngine.info()
        print("[SELFCHECK] 引擎：\(info.version) · \(info.platform) · \(info.buildConfig)")
        print("[SELFCHECK] 哈希：\(info.hashAlgorithm) · 并发 \(info.hashConcurrency)")
        report("引擎自述可用", !info.version.isEmpty, info.platform)

        // ── SHA-256 官方向量
        let emptyVector = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let abcVector = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let emptyHash = ContentHasher.sha256(of: Data())
        let abcHash = ContentHasher.sha256(of: Data("abc".utf8))
        report("SHA-256(\"\") 匹配官方向量", emptyHash == emptyVector, emptyHash)
        report("SHA-256(\"abc\") 匹配官方向量", abcHash == abcVector, abcHash)

        // ── 流式文件哈希（跨缓冲区边界）
        do {
            let probe = FileManager.default.temporaryDirectory
                .appendingPathComponent("syncapp-selfcheck-\(UUID().uuidString).bin")
            let byteCount = ContentHasher.chunkSize * 2 + 12_345
            var payload = Data(count: byteCount)
            for index in 0..<byteCount { payload[index] = UInt8(index % 251) }
            try payload.write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }

            let streamed = try ContentHasher.sha256(ofFileAt: probe.path)
            report(
                "流式文件哈希与一次性一致",
                streamed == ContentHasher.sha256(of: payload),
                "\(byteCount) 字节 · \(String(streamed.prefix(24)))…"
            )
        } catch {
            report("流式文件哈希与一次性一致", false, "\(error)")
        }

        // ── 真实目录扫描
        let target = arguments.first(where: { !$0.hasPrefix("-") })
            ?? FileManager.default.currentDirectoryPath
        print("[SELFCHECK] 扫描目标：\(target)")

        do {
            let scan = try await SyncEngine.scan(
                root: target,
                options: ScanOptions(computeHash: true, maxEntries: 20)
            )
            report(
                "目录扫描可用",
                scan.fileCount > 0 && scan.hashedCount == scan.fileCount,
                "\(scan.fileCount) 文件 / \(scan.directoryCount) 目录 / "
                    + "\(ByteFormatter.string(fromBytes: scan.totalBytes)) / 哈希 \(scan.hashedCount) 个"
            )
            report(
                "分项计时之和不超过总耗时",
                scan.walkSeconds + scan.hashSeconds <= scan.elapsedSeconds + 0.005,
                "遍历 \(ByteFormatter.string(fromSeconds: scan.walkSeconds))"
                    + " + 哈希 \(ByteFormatter.string(fromSeconds: scan.hashSeconds))"
                    + " ≤ 合计 \(ByteFormatter.string(fromSeconds: scan.elapsedSeconds))"
            )
            if let throughput = scan.hashThroughputMBps {
                print(String(format: "[SELFCHECK] 哈希吞吐：%.0f MB/s", throughput))
            }
            if !scan.entries.isEmpty {
                let largest = scan.entries[0]
                print("[SELFCHECK] 最大文件：\(largest.relativePath) "
                    + "(\(ByteFormatter.string(fromBytes: largest.size)))")
            }

            // 错误路径：不存在的路径必须明确抛错，而不是返回空结果
            let missing = target + "/definitely-not-here-\(UUID().uuidString)"
            do {
                _ = try await SyncEngine.scan(root: missing)
                report("不存在的路径会抛错", false, "竟然没有抛错")
            } catch {
                report("不存在的路径会抛错", true, "\(error.localizedDescription)")
            }
        } catch {
            report("目录扫描可用", false, "\(error.localizedDescription)")
        }

        // ── 启动状态
        //
        // 这里断言的是"应用启动后的初始数据"，而不是某个函数的返回值。
        // 曾经在启动时播种两个示例任务，现已移除；把这条固化下来的理由很实际：
        // 播种这类代码一旦被重新加上，只有**打开界面**才会发现，
        // 而自检与单元测试都不会报错。
        let launchModel = AppModel()
        launchModel.initializeIfNeeded()
        report(
            "启动时任务列表为空",
            launchModel.tasks.isEmpty,
            "\(launchModel.tasks.count) 个任务（期望 0）"
        )

        // ── 目标端存储
        //
        // 这一组检查刻意都**不需要网络**：自检要能在任何机器上跑出确定结论。
        // 需要网络的部分（真实 SMB 挂载、真实 WebDAV 往返）放在 swift test 里，
        // 由进程内的测试服务端与真实挂载点来覆盖。
        print("[SELFCHECK] 存储：目标端驱动")
        do {
            let smb = try StorageEndpoint(kind: .smb, address: "nas.local/Share/")
            report(
                "SMB 地址规范化",
                smb.address == "smb://nas.local/Share",
                "nas.local/Share/ → \(smb.address)"
            )

            let webdav = try StorageEndpoint(kind: .webdav, address: "nas.local:5006/dav/")
            report(
                "WebDAV 裸主机默认 https 且去掉尾斜杠",
                webdav.address == "https://nas.local:5006/dav",
                webdav.address
            )

            var rejectedMissingShare = false
            do { _ = try StorageEndpoint(kind: .smb, address: "smb://nas.local") }
            catch { rejectedMissingShare = true }
            report("缺少共享名会被拒绝", rejectedMissingShare, "smb://nas.local")

            var rejectedRelativePath = false
            do { _ = try StorageEndpoint(kind: .local, address: "relative/path") }
            catch { rejectedRelativePath = true }
            report("本地目录必须是绝对路径", rejectedRelativePath, "relative/path")
        } catch {
            report("目标端地址解析", false, "\(error.localizedDescription)")
        }

        // NetFS 接线：确认 C 互操作层真的通了（枚举卷、读文件系统类型）
        do {
            let volumes = NetworkVolumeMounter.mountedVolumes()
            report("已挂载卷可枚举", !volumes.isEmpty, "\(volumes.count) 个卷")

            let type = NetworkVolumeMounter.fileSystemType(atPath: NSTemporaryDirectory())
            report("文件系统类型可读", type != nil, type ?? "nil")

            let networkVolumes = volumes.filter {
                ["smbfs", "afpfs", "nfs"].contains($0.fileSystemType)
            }
            let sample = networkVolumes.prefix(3).map(\.mountPoint).joined(separator: ", ")
            print("[SELFCHECK] 网络卷：\(networkVolumes.count) 个"
                + (networkVolumes.isEmpty ? "（无）" : "（\(sample)）"))
        }

        // 钥匙串往返：用它证明凭据确实能存住、读回一致。
        // 地址用 .invalid 域，确保绝不会碰到任何真实服务端的记录。
        do {
            let endpoint = try StorageEndpoint(
                kind: .webdav, address: "https://selfcheck.invalid/dav")
            defer { try? CredentialStore.delete(for: endpoint) }

            let credentials = StorageCredentials(
                user: "selfcheck", password: "p@ss/含中文 · \(UUID().uuidString)",
                allowInsecureTLS: true
            )
            try CredentialStore.save(credentials, for: endpoint)
            let loaded = try CredentialStore.load(for: endpoint)
            report("钥匙串凭据往返一致", loaded == credentials, "用户 \(credentials.user)")
        } catch {
            report("钥匙串凭据往返一致", false, "\(error.localizedDescription)")
        }

        print("[SELFCHECK] ------------------------------------------")
        if failures == 0 {
            print("[SELFCHECK] 全部通过")
            return 0
        }
        print("[SELFCHECK] 失败 \(failures) 项")
        return 1
    }
}
