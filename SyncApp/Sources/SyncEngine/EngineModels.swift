import Foundation

// ────────────────────────────────────────────────────────────────── 条目 --

/// 扫描结果中的单个文件条目。
///
/// 值类型且 `Sendable`：引擎要在并发任务之间传递这些条目，
/// 用 struct 而不是 class 可以从类型上排除共享可变状态的整类问题。
public struct ScanEntry: Sendable, Hashable, Identifiable {
    /// 绝对路径
    public let path: String
    /// 相对扫描根的路径，供界面展示
    public let relativePath: String
    public let size: Int64
    /// 修改时间。取不到为 nil。
    ///
    /// **不要用它做变更判定** —— 外接盘可能是 FAT/exFAT（精度 2 秒），
    /// 时钟也可能漂移。变更仲裁一律用 `contentHash`，mtime 只用于缩小候选范围。
    public let modified: Date?
    /// SHA-256 十六进制小写；未计算或读取失败为 nil。
    public let contentHash: String?

    public var id: String { path }

    public init(
        path: String,
        relativePath: String,
        size: Int64,
        modified: Date?,
        contentHash: String?
    ) {
        self.path = path
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.contentHash = contentHash
    }
}

// ────────────────────────────────────────────────────────────────── 结果 --

/// 一次目录扫描的结果。
///
/// **语义要点：** 所有计数（`fileCount` / `hashedCount` / `totalBytes` …）都是**全量**的，
/// 只有 `entries` 会被 `maxEntries` 截断（此时 `truncated` 为 true）。
///
/// 这条语义很关键：性能基线要的是「扫完整个目录树」的真实耗时。
/// 若统计数字也随 `maxEntries` 截断，量到的就变成「扫前 N 个」的耗时，毫无意义。
public struct ScanResult: Sendable {
    public let root: String
    public let fileCount: Int
    public let directoryCount: Int
    public let totalBytes: Int64
    /// 实际完成哈希的文件数
    public let hashedCount: Int
    /// 文件存在但读取失败（权限、被占用等）
    public let hashErrors: Int
    /// 目录或条目读取失败
    public let readErrors: Int
    /// 跳过的软链接数（引擎一律不跟随软链接）
    public let symlinksSkipped: Int
    public let maxDepth: Int

    /// 遍历耗时（秒）
    public let walkSeconds: Double
    /// 哈希耗时（秒）
    public let hashSeconds: Double
    /// 端到端耗时（秒）
    public let elapsedSeconds: Double

    /// `entries` 是否被截断
    public let truncated: Bool
    /// 按体积降序的条目子集
    public let entries: [ScanEntry]

    public init(
        root: String,
        fileCount: Int,
        directoryCount: Int,
        totalBytes: Int64,
        hashedCount: Int,
        hashErrors: Int,
        readErrors: Int,
        symlinksSkipped: Int,
        maxDepth: Int,
        walkSeconds: Double,
        hashSeconds: Double,
        elapsedSeconds: Double,
        truncated: Bool,
        entries: [ScanEntry]
    ) {
        self.root = root
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalBytes = totalBytes
        self.hashedCount = hashedCount
        self.hashErrors = hashErrors
        self.readErrors = readErrors
        self.symlinksSkipped = symlinksSkipped
        self.maxDepth = maxDepth
        self.walkSeconds = walkSeconds
        self.hashSeconds = hashSeconds
        self.elapsedSeconds = elapsedSeconds
        self.truncated = truncated
        self.entries = entries
    }

    /// 平均吞吐（MB/s）。端到端耗时过小或字节数为 0 时返回 nil ——
    /// 避免除零，也避免给出荒谬的天文数字。
    public var throughputMBps: Double? {
        guard elapsedSeconds > 0.0005, totalBytes > 0 else { return nil }
        return (Double(totalBytes) / 1_048_576.0) / elapsedSeconds
    }

    /// 哈希阶段的吞吐（MB/s）。哈希是主要瓶颈，这个数字比整体吞吐更有参考价值。
    public var hashThroughputMBps: Double? {
        guard hashSeconds > 0.0005, totalBytes > 0 else { return nil }
        return (Double(totalBytes) / 1_048_576.0) / hashSeconds
    }
}

// ────────────────────────────────────────────────────────────────── 选项 --

public struct ScanOptions: Sendable {
    /// 是否计算内容哈希。关闭后扫描只做目录遍历与 stat。
    public var computeHash: Bool

    /// `entries` 数组的上限。**只影响展示用的条目数**，统计与哈希始终覆盖全部文件。
    public var maxEntries: Int

    /// 并发哈希的任务数。0 表示按 CPU 核心数自动决定。
    ///
    /// 之所以要可配置：哈希是 IO 密集而非 CPU 密集（瓶颈是每文件一次
    /// open/read/close 的系统调用），并发数开得过大反而会因磁盘寻道竞争而变慢。
    /// 机械硬盘上这个值应当显著小于核心数。
    public var maxConcurrentHashes: Int

    public init(
        computeHash: Bool = true,
        maxEntries: Int = 500,
        maxConcurrentHashes: Int = 0
    ) {
        self.computeHash = computeHash
        self.maxEntries = maxEntries
        self.maxConcurrentHashes = maxConcurrentHashes
    }
}

// ───────────────────────────────────────────────────────────────────── 错误 --

public enum SyncEngineError: LocalizedError {
    case pathDoesNotExist(String)
    case notADirectory(String)
    case pathNotReadable(String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .pathDoesNotExist(let p):
            return "路径不存在：\(p)"
        case .notADirectory(let p):
            return "路径不是目录：\(p)"
        case .pathNotReadable(let p, let e):
            return "目录无法读取：\(p)（\(e.localizedDescription)）"
        }
    }
}

// ───────────────────────────────────────────────────────────────── 引擎信息 --

/// 引擎自述信息。
///
/// 界面上常驻展示这份信息是刻意的：它让「引擎是否正常」成为可见的运行时事实，
/// 而不是等到某个功能失败才被发现。
public struct EngineInfo: Sendable {
    public let version: String
    /// 形如 `macOS 27.0 (arm64)`
    public let platform: String
    /// `debug` / `release`
    public let buildConfig: String
    public let hashAlgorithm: String
    /// 参与并发哈希的核心数
    public let hashConcurrency: Int

    public init(
        version: String,
        platform: String,
        buildConfig: String,
        hashAlgorithm: String,
        hashConcurrency: Int
    ) {
        self.version = version
        self.platform = platform
        self.buildConfig = buildConfig
        self.hashAlgorithm = hashAlgorithm
        self.hashConcurrency = hashConcurrency
    }
}

// ───────────────────────────────────────────────────────── 格式化辅助（界面共用）--

public enum ByteFormatter {
    /// 把字节数格式化为人类可读形式。
    public static func string(fromBytes bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024.0
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        // 用字符串插值而不是 String(format: "%@")：后者依赖 Swift String 到
        // NSString 的桥接，在格式化字符串里混用容易出意外。
        return "\(number) \(units[index])"
    }

    /// 把秒数格式化为人类可读形式。
    public static func string(fromSeconds seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        let minutes = Int(seconds) / 60
        return "\(minutes) 分 \(Int(seconds) % 60) 秒"
    }
}
