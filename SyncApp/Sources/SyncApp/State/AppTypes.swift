import Foundation
import SyncEngine

// ────────────────────────────────────────────────────────────── 日志 --

enum LogLevel: String, CaseIterable, Sendable {
    case info
    case warning
    case error

    var label: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    /// 固定宽度的标签文本，让日志列表的各列能对齐。
    var tag: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERR "
        }
    }
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    /// 来源：引擎 / 任务 / 界面 / 自检
    let source: String
    let message: String

    var timeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: time)
    }
}

// ─────────────────────────────────────────────────────────── 领域模型 --

/// 同步模式。语义见技术方案 4.1。
enum SyncMode: String, CaseIterable, Identifiable, Sendable {
    case bidirectional
    case uploadOnly
    case downloadOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bidirectional: return "双向同步"
        case .uploadOnly: return "仅上传"
        case .downloadOnly: return "仅下载"
        }
    }

    var detail: String {
        switch self {
        case .bidirectional: return "两端互为镜像；两侧都变则按冲突矩阵裁决"
        case .uploadOnly: return "本地为源，目标端只增不改；本地删除不传播"
        case .downloadOnly: return "目标端为源，本地只增不改"
        }
    }
}

// ─────────────────────────────────────────────────────────── 目标端 --

/// 目标端配置。
///
/// 与 `SyncTask` 的其余字段分开，是因为这一组东西有共同的特殊之处：
/// 它们会被**规范化**（地址）或**存进钥匙串**（用户名/密码/证书策略），
/// 而任务的名称、同步模式之类不会。混在一起容易在某个改任务的地方
/// 顺手写坏地址，或者在某个只该改名称的地方触发一次钥匙串写入。
///
/// 目标类型直接用引擎的 `StorageKind`，不再在界面层定义一套平行的枚举：
/// 两套枚举必然要写一张映射表，而那张表会随时间漂移。
struct TargetConfiguration: Sendable, Hashable {
    var kind: StorageKind = .local
    /// 地址：本地是绝对路径，SMB 是 `smb://主机/共享`，WebDAV 是 `http(s)://…`
    var address: String = ""
    /// 端点内部的相对子目录
    var subpath: String = ""
    /// 用户名。密码**不在这里** —— 它只存在于钥匙串。
    var user: String = ""
    /// 仅 WebDAV 有意义。
    var allowInsecureTLS: Bool = false

    var displayText: String {
        guard !address.isEmpty else { return "(未指定)" }
        return subpath.isEmpty ? address : "\(address)/\(subpath)"
    }

    var credentialSummary: String {
        guard kind.requiresCredentials else { return "" }
        return user.isEmpty ? "访客" : user
    }

    /// 构造规范化端点。地址不合法时抛错，由调用方决定怎么呈现 ——
    /// 在这里吞掉错误会让"地址写错了"表现成"连接失败"，误导排查方向。
    func makeEndpoint() throws -> StorageEndpoint {
        try StorageEndpoint(kind: kind, address: address, subpath: subpath)
    }
}

/// 一个同步任务。
///
/// 当前做到"预览扫描 + 目标端连接"，真正的传输尚未实现
/// （P1 的 Reconciler 与 Transfer 还没写），界面上对此有明确标注。
struct SyncTask: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var sourcePath: String
    var target = TargetConfiguration()
    var mode: SyncMode
    var isEnabled: Bool = true

    // ── 运行期状态（不持久化）

    var preview: ScanResult?
    var isScanning: Bool = false
    var errorMessage: String?
    var lastPreviewAt: Date?

    /// 目标端连接测试结果。来自一次**真实往返**，不是本地校验。
    var targetProbe: StorageProbe?
    var targetProbeError: String?
    var isProbingTarget: Bool = false
    /// 目标端基准目录下的条目（真实往返）
    var targetEntries: [RemoteEntry]?
}

// ─────────────────────────────────────────────────────── 自检结果 --

struct CheckItem: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let passed: Bool
    let detail: String
}

struct SelfCheckReport: Sendable {
    let items: [CheckItem]
    let errorMessage: String?

    var allPassed: Bool {
        errorMessage == nil && !items.isEmpty && items.allSatisfy(\.passed)
    }
}

// ─────────────────────────────────────────────────────── 展示辅助 --

extension StorageKind {
    /// 徽章上用的短标签。
    ///
    /// 与 `label` 分开：`label` 要能独立读（"SMB / 文件共享"），
    /// 而徽章旁边已经有任务名与同步模式，占位紧张。
    var shortLabel: String {
        switch self {
        case .local: return "本地"
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        }
    }

    /// 该类型在设置页里的一句话说明。
    var capabilitySummary: String {
        switch self {
        case .local:
            return "文件系统直连。可读写、可删除，行为完全由 POSIX 权限决定。"
        case .smb:
            return "经系统 NetFS 挂载共享，之后当作本地目录读写 —— "
                + "与访达「连接服务器」走同一套系统栈。"
        case .webdav:
            return "用 URLSession 直接发 PROPFIND / PUT / MKCOL / DELETE，"
                + "不依赖任何第三方 WebDAV 库。"
        }
    }
}
