import Foundation

/// 单调时钟秒表。
///
/// **为什么不用 `Date()`**：`Date` 取自墙上时钟，会被 NTP 校时、手动改时间、
/// 甚至时区切换影响。用它在耗时上可能得到负数或巨大值，而这些数字是要当作
/// 性能基线来用的，不能有这种不确定性。
///
/// 注意**差值必须先在整数域算完再转 Double**：
/// `uptimeNanoseconds` 运行一年后约 3.15e16，已超过 Double 的精确整数上限（2^53 ≈ 9e15），
/// 先转 Double 再相减会丢精度。
struct MonotonicStopwatch {
    private let start: UInt64
    private var mark: UInt64

    init() {
        let now = DispatchTime.now().uptimeNanoseconds
        self.start = now
        self.mark = now
    }

    /// 距上次调用（或创建）的秒数，并重置标记。
    mutating func lap() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = Double(now &- mark) / 1_000_000_000
        mark = now
        return delta
    }

    /// 距创建的总秒数。
    var elapsed: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }
}

/// 目录扫描引擎。
///
/// 分两个阶段，因为这两阶段的瓶颈成因完全不同：
///
/// | 阶段 | 瓶颈 | 优化方向 |
/// |---|---|---|
/// | 遍历 + stat | 文件**数量** | 减少系统调用次数 |
/// | 内容哈希 | 字节数 + 每文件一次 open/close 的固定开销 | 并发 |
///
/// 把耗时分开统计（`walkSeconds` / `hashSeconds`）而不是只给一个总数，
/// 是为了让性能问题能被归因。前期实测（14 万文件 / 13 GB）显示
/// 遍历仅占约 10%，哈希占 90% —— 这个结论直接决定了优化方向应该放在并发哈希上，
/// 而不是"换一个更快的哈希算法"。
public struct SyncEngine {

    public static let version = "sync-engine 1.0.0"

    // MARK: - 引擎自述

    public static func info(hashConcurrency: Int = 0) -> EngineInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "unknown"
        #endif

        let config: String
        #if DEBUG
        config = "debug"
        #else
        config = "release"
        #endif

        return EngineInfo(
            version: version,
            platform: "macOS \(v.majorVersion).\(v.minorVersion) (\(arch))",
            buildConfig: config,
            hashAlgorithm: "SHA-256 (CryptoKit)",
            hashConcurrency: hashConcurrency > 0 ? hashConcurrency : defaultConcurrency
        )
    }

    /// 默认并发度。
    ///
    /// 取 CPU 核心数：哈希本身是 CPU 工作（SHA-256 有硬件加速），
    /// 但每个文件还要经历 open/read/close 的系统调用。
    /// 机械硬盘上这个值应当显著调小——并发寻道会互相拖慢。
    public static var defaultConcurrency: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - 扫描

    /// 递归扫描目录。
    ///
    /// 异步：哈希阶段会并发执行，且这是纯 CPU 与 IO 的长任务
    /// （十万文件级可达数十秒），绝不能在主线程同步执行。
    ///
    /// - Parameters:
    ///   - root: 待扫描的目录（绝对路径，**不展开 `~`**，调用方负责）
    ///   - options: 见 `ScanOptions`
    public static func scan(
        root: String,
        options: ScanOptions = ScanOptions()
    ) async throws -> ScanResult {
        let clock = MonotonicStopwatch()

        // ── 前置校验：这几类错误要在开始遍历前就报出来，
        //    否则会表现为"扫描成功但结果为空"，误导排查方向。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw SyncEngineError.pathDoesNotExist(root)
        }
        guard isDirectory.boolValue else {
            throw SyncEngineError.notADirectory(root)
        }

        let rootURL = URL(fileURLWithPath: root).standardizedFileURL

        // 枚举基准必须解开根目录自身的软链。
        //
        // Foundation 的 URL 版目录枚举**不跟随末端软链**：对指向目录的软链
        // 调用 `contentsOfDirectory(at:)` 会抛 `NSFileReadUnknownError(256)`，
        // 而 `opendir(3)` 对同一路径完全正常。不处理的话，用户把同步基点设成
        // 一个软链（`/tmp`、`/var`、访达里的别名、`/Volumes` 下的链接都算）
        // 就会得到"扫描完成、0 个文件"这种**静默的空结果** —— 比报错难查得多。
        //
        // 相对路径的计算也必须用同一个值，否则前缀匹配失配，
        // `relativePath` 会整片退化成绝对路径。
        let walkRoot = rootURL.resolvingSymlinksInPath()

        // ── 阶段一：遍历
        var walkClock = MonotonicStopwatch()
        let walk = walkTree(rootURL: walkRoot)
        let walkSeconds = walkClock.lap()

        // ── 阶段二：并发哈希
        var hashSeconds: Double = 0
        var hashes: [String?] = Array(repeating: nil, count: walk.files.count)
        var hashErrors = 0

        if options.computeHash, !walk.files.isEmpty {
            var hashClock = MonotonicStopwatch()
            let concurrency = options.maxConcurrentHashes > 0
                ? max(1, options.maxConcurrentHashes)
                : defaultConcurrency

            let results = await hashFilesConcurrently(
                paths: walk.files.map(\.path),
                concurrency: concurrency
            )

            for (index, hash) in results {
                if let hash {
                    hashes[index] = hash
                } else {
                    hashErrors += 1
                }
            }
            hashSeconds = hashClock.lap()
        }

        // ── 组装条目
        let cappedCount = options.maxEntries > 0 ? options.maxEntries : 500
        var entries: [ScanEntry] = []
        entries.reserveCapacity(min(cappedCount, walk.files.count))
        for (index, file) in walk.files.enumerated() where entries.count < cappedCount {
            entries.append(
                ScanEntry(
                    path: file.path,
                    relativePath: file.relative,
                    size: file.size,
                    modified: file.modified,
                    contentHash: hashes[index]
                )
            )
        }
        // 展示子集按体积降序：用户找"什么占了空间"时最关心大文件。
        // 只排被截断后的子集，排序开销与文件总数脱钩。
        entries.sort { $0.size > $1.size }

        return ScanResult(
            root: rootURL.path,
            fileCount: walk.files.count,
            directoryCount: walk.directoryCount,
            totalBytes: walk.totalBytes,
            hashedCount: hashes.compactMap { $0 }.count,
            hashErrors: hashErrors,
            readErrors: walk.readErrors,
            symlinksSkipped: walk.symlinksSkipped,
            maxDepth: walk.maxDepth,
            walkSeconds: walkSeconds,
            hashSeconds: hashSeconds,
            elapsedSeconds: clock.elapsed,
            truncated: walk.files.count > entries.count,
            entries: entries
        )
    }

    // MARK: - 遍历实现

    private struct WalkedFile {
        let path: String
        let relative: String
        let size: Int64
        let modified: Date?
    }

    private struct WalkOutcome {
        var files: [WalkedFile] = []
        var directoryCount = 0
        var totalBytes: Int64 = 0
        var readErrors = 0
        var symlinksSkipped = 0
        var maxDepth = 0
    }

    /// 递归遍历目录树。
    ///
    /// 用**显式栈**而不是递归函数：同步工具面对的是用户目录，
    /// 深层嵌套（以及将来若放宽软链策略后的目录环）都可能把调用栈打爆。
    /// 显式栈的深度上限只受内存约束。
    private static func walkTree(rootURL: URL) -> WalkOutcome {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        var outcome = WalkOutcome()
        // 起点也算一个目录
        var stack: [(url: URL, depth: Int)] = [(rootURL, 0)]
        outcome.directoryCount = 1

        while let (directory, depth) = stack.popLast() {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    // 不跳过隐藏文件：同步工具必须处理它们，
                    // 否则用户会发现"某些文件怎么都同步不过去"。
                    options: []
                )
            } catch {
                // 权限不足等：记为可恢复错误继续，不中断整次扫描。
                // 用户目录里总有扫不动的地方（其他用户的目录、受保护的系统位置）。
                outcome.readErrors += 1
                continue
            }

            for child in children {
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: Set(keys))
                } catch {
                    outcome.readErrors += 1
                    continue
                }

                // 软链接一律不跟随。
                //
                // 跟随会导致两个问题：目录环使遍历永不终止；
                // 同一份内容被多次计入，使"总大小"与文件数失真。
                // 两者都会让用户看到的统计数字直接错掉，所以宁可不跟随。
                //
                // 必须**先**判断 isSymbolicLink：isDirectory 会跟随链接，
                // 对指向目录的软链返回 true，那时再跳过就已经晚了。
                if values.isSymbolicLink == true {
                    outcome.symlinksSkipped += 1
                    continue
                }

                if values.isDirectory == true {
                    outcome.directoryCount += 1
                    let childDepth = depth + 1
                    if childDepth > outcome.maxDepth { outcome.maxDepth = childDepth }
                    stack.append((child, childDepth))
                    continue
                }

                // 只统计常规文件。设备文件 / FIFO / socket 一律跳过：
                // 它们不计入也不报错——计入会让"总大小"失真，
                // 报错则会用噪音淹没真正的读取失败。
                guard values.isRegularFile == true else { continue }

                let size = Int64(values.fileSize ?? 0)
                outcome.files.append(
                    WalkedFile(
                        path: child.path,
                        relative: relativePath(of: child, under: rootURL),
                        size: size,
                        modified: values.contentModificationDate
                    )
                )
                outcome.totalBytes += size
            }
        }

        return outcome
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        // 两侧都标准化，理由见 `scan` 里 `walkRoot` 的说明：
        // 枚举返回的子项路径带的是真正的 realpath（`/private/var/...`），
        // 而 `resolvingSymlinksInPath()` 保留 `/var` 前缀。不归一化就匹配不上，
        // relativePath 会整片退化成绝对路径。
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return full }
        var rel = String(full.dropFirst(rootPath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    // MARK: - 并发哈希

    /// 以**有界并发**计算一批文件的哈希。
    ///
    /// 用「完成一个就补一个」的滑动窗口，而不是「按批分组、每批等齐」：
    /// 分批会在每批末尾等最慢的那个，文件大小分布不均时（同步场景里很常见——
    /// 一堆小文件里夹着几个大文件）尾效应会显著拖慢整体。
    ///
    /// 返回值：(下标, 哈希) 的数组；哈希为 nil 表示该文件读取失败。
    private static func hashFilesConcurrently(
        paths: [String],
        concurrency: Int
    ) async -> [(Int, String?)] {
        guard !paths.isEmpty else { return [] }

        var results: [(Int, String?)] = []
        results.reserveCapacity(paths.count)

        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            let total = paths.count
            let initial = min(concurrency, total)

            for index in 0..<initial {
                let path = paths[index]
                group.addTask { (index, try? ContentHasher.sha256(ofFileAt: path)) }
            }
            next = initial

            while let finished = await group.next() {
                results.append(finished)
                if next < total {
                    let index = next
                    let path = paths[index]
                    group.addTask { (index, try? ContentHasher.sha256(ofFileAt: path)) }
                    next += 1
                }
            }
        }

        return results
    }
}
