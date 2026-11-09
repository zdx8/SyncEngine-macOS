import Foundation

// ───────────────────────────────────────────────────────────── 种类 --

/// 目标端存储类型。
///
/// 只有三种，且都是 macOS 上**不需要任何第三方库**就能访问的：
/// 本地文件系统、经系统挂载的 SMB、以及 URLSession 直接支持的 WebDAV。
/// 这也是"仅 macOS + 零第三方依赖"这条项目约束的直接体现（见技术方案 2.3）。
public enum StorageKind: String, CaseIterable, Sendable, Identifiable {
    case local
    case smb
    case webdav

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: return "本地目录"
        case .smb: return "SMB / 文件共享"
        case .webdav: return "WebDAV"
        }
    }

    /// 地址输入框的占位提示。
    public var addressPlaceholder: String {
        switch self {
        case .local: return "/Users/you/Documents"
        case .smb: return "smb://nas.local/Share"
        case .webdav: return "https://nas.local:5006/dav"
        }
    }

    /// 是否需要账号密码。
    public var requiresCredentials: Bool { self != .local }

    /// 是否支持"允许自签名证书"。
    ///
    /// 只有 WebDAV 需要：群晖、威联通这类 NAS 的 WebDAV 默认用自签证书，
    /// 不给出这个开关，用户会卡在"连不上"而不知道原因。
    /// SMB 走系统挂载栈，证书问题由系统处理，不归我们管。
    public var supportsInsecureTLS: Bool { self == .webdav }
}

// ─────────────────────────────────────────────────────────── 地址 --

/// 地址解析失败的原因。
public enum StorageAddressError: LocalizedError, Sendable {
    case empty
    case missingScheme(String)
    case unsupportedScheme(String)
    case missingHost(String)
    case missingShare(String)
    case notAbsolutePath(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "地址不能为空"
        case .missingScheme(let text):
            return "无法识别的地址：\(text)"
        case .unsupportedScheme(let scheme):
            return "不支持的协议：\(scheme)（SMB 用 smb://，WebDAV 用 http:// 或 https://）"
        case .missingHost(let text):
            return "地址缺少服务器名：\(text)"
        case .missingShare(let text):
            return "地址缺少共享名：\(text)（应形如 smb://服务器/共享）"
        case .notAbsolutePath(let path):
            return "本地目录必须是绝对路径：\(path)"
        }
    }
}

/// 一个目标端位置。
///
/// ## 为什么地址要规范化后再存
///
/// 用户会以各种形式输入同一个位置：`nas/Share`、`smb://nas/Share`、
/// `smb://nas/Share/`。如果原样保存，Keychain 的凭据键、已挂载卷的匹配、
/// 界面上的显示就会各自为政 —— 出现"同一个共享存了三份密码，改了其中一份
/// 另外两个还在用旧的"这类问题。所以**进入系统的第一件事就是规范化**。
public struct StorageEndpoint: Sendable, Hashable {
    public let kind: StorageKind
    /// 规范化后的地址。
    ///
    /// - `local`：绝对路径，`~` 已展开，无尾随斜杠
    /// - `smb`：`smb://主机[:端口]/共享`
    /// - `webdav`：`http(s)://主机[:端口]/路径`，路径保留但去掉尾随斜杠
    public let address: String
    /// 端点内部的相对子目录（可以是多级，如 `a/b`）。
    ///
    /// 与 `address` 分开而不是拼成一个字符串：子目录对 SMB 是挂载点下的路径、
    /// 对 WebDAV 是集合路径，两者的拼接规则不同，混在一起早晚出错。
    public let subpath: String

    public init(kind: StorageKind, address: String, subpath: String = "") throws {
        let normalizedAddress = try Self.normalize(kind: kind, raw: address)
        self.kind = kind
        self.address = normalizedAddress
        self.subpath = Self.normalizeSubpath(subpath)
    }

    /// 界面与日志里用的展示文本。
    public var displayText: String {
        subpath.isEmpty ? address : "\(address)/\(subpath)"
    }

    /// 跳过规范化直接构造。
    ///
    /// 只给驱动内部使用：`LocalFileDriver` 拿到的路径**已经**规范化过
    /// （来自 `StorageEndpoint` 或系统返回的挂载点），再规范一次纯属多余，
    /// 而且当路径恰好还不存在时规范化可能抛错，让一个本可工作的驱动构造失败。
    init(uncheckedKind kind: StorageKind, address: String, subpath: String) {
        self.kind = kind
        self.address = address
        self.subpath = subpath
    }

    // MARK: 规范化

    private static func normalize(kind: StorageKind, raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StorageAddressError.empty }

        switch kind {
        case .local:
            return try normalizeLocalPath(text)
        case .smb:
            return try normalizeSMB(text)
        case .webdav:
            return try normalizeWebDAV(text)
        }
    }

    private static func normalizeLocalPath(_ text: String) throws -> String {
        // 先展开 ~。引擎不依赖 shell，所以自己展开：
        // 用户从终端复制来的路径十有八九带 ~，不展开会得到"路径不存在"。
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw StorageAddressError.notAbsolutePath(text)
        }
        var path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func normalizeSMB(_ text: String) throws -> String {
        // 容忍裸写的 `nas/Share`：用户不会记得加协议头，
        // 而 SMB 是这里唯一有"共享名"的协议，补一个前缀没有歧义。
        let withScheme = text.contains("://") ? text : "smb://\(text)"
        guard let url = URL(string: withScheme) else {
            throw StorageAddressError.unsupportedScheme(withScheme)
        }
        guard let scheme = url.scheme?.lowercased() else {
            throw StorageAddressError.missingScheme(text)
        }
        guard scheme == "smb" else {
            throw StorageAddressError.unsupportedScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw StorageAddressError.missingHost(text)
        }

        let parts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let share = parts.first else {
            throw StorageAddressError.missingShare(text)
        }

        // 端口只在显式写了且非默认时才保留：`smb://nas:445/Share` 与
        // `smb://nas/Share` 是同一个位置，存成两种形式会让凭据键对不上。
        var result = "smb://\(host)"
        if let port = url.port, port != 445 { result += ":\(port)" }
        result += "/\(share)"

        // 共享名之后的部分视为子目录，并入 subpath 由调用方处理 ——
        // 这里只保留共享，避免同一个位置出现两种写法。
        return result
    }

    private static func normalizeWebDAV(_ text: String) throws -> String {
        let withScheme: String
        if text.contains("://") {
            withScheme = text
        } else {
            // 裸主机名默认按 https：WebDAV 里明文 HTTP 是少数，
            // 而这个默认值更安全；用户真要 http，显式写出来即可。
            withScheme = "https://\(text)"
        }
        guard let url = URL(string: withScheme) else {
            throw StorageAddressError.unsupportedScheme(withScheme)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw StorageAddressError.unsupportedScheme(url.scheme ?? withScheme)
        }
        guard let host = url.host, !host.isEmpty else {
            throw StorageAddressError.missingHost(text)
        }

        var result = "\(scheme)://\(host)"
        if let port = url.port { result += ":\(port)" }
        let path = url.path
        if !path.isEmpty && path != "/" {
            // 去掉尾随斜杠。保留的话同一个集合会存成两种形式，
            // 而 PROPFIND 的 href 比对是字符串比较，差一个斜杠就漏项。
            var trimmed = path
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            result += trimmed
        }
        return result
    }

    private static func normalizeSubpath(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    // MARK: 地址内的组成部分（SMB 用）

    /// SMB 共享名。
    public var smbShare: String? {
        guard kind == .smb, let url = URL(string: address) else { return nil }
        return url.path.split(separator: "/").first.map(String.init)
    }

    /// SMB 主机名。
    public var smbHost: String? {
        guard kind == .smb, let url = URL(string: address) else { return nil }
        return url.host
    }
}

// ─────────────────────────────────────────────────────────── 凭据 --

/// 可 `Codable` 是为了整体序列化进 Keychain：密码与用户名一起存，
/// 而不是拆成多个条目 —— 拆开后会出现"用户名更新了密码没更新"的中间态。
public struct StorageCredentials: Sendable, Hashable, Codable {
    public var user: String
    public var password: String
    /// 仅在 `kind == .webdav` 时有意义。
    public var allowInsecureTLS: Bool

    public init(user: String = "", password: String = "", allowInsecureTLS: Bool = false) {
        self.user = user
        self.password = password
        self.allowInsecureTLS = allowInsecureTLS
    }

    /// 匿名（访客）访问。
    ///
    /// SMB 上这是合法的常见配置（群晖的匿名共享），WebDAV 上也有。
    /// 因此**不把"没有用户名"当作配置错误**，而是当作访客访问尝试。
    public var isAnonymous: Bool { user.isEmpty && password.isEmpty }

    public static let anonymous = StorageCredentials()

    /// 用于日志：绝不包含密码。
    public var logDescription: String {
        isAnonymous ? "访客" : "用户 \(user)"
    }
}

// ─────────────────────────────────────────────────────────── 条目 --

/// 目标端的一个条目。
public struct RemoteEntry: Sendable, Hashable, Identifiable {
    public let name: String
    /// 相对于驱动基准路径的路径
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?

    public var id: String { relativePath }

    public init(
        name: String,
        relativePath: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date?
    ) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

// ─────────────────────────────────────────────────────────── 探测 --

/// 一次连接探测的结果。
///
/// 字段刻意都做成可空或非关键：连接测试的目的是**回答"能不能用"**，
/// 而不是把远端元数据完整搬过来。能答多少答多少，答不了的不编。
public struct StorageProbe: Sendable {
    public let kind: StorageKind
    public let endpointDescription: String
    /// 实际落地访问的路径：本地目录即自身，SMB 是挂载点，WebDAV 是最终 URL
    public let resolvedLocation: String
    /// 文件系统类型（如 `smbfs`、`apfs`）。WebDAV 无此概念。
    public let fileSystemType: String?
    /// 根目录是否可写。取不到为 nil —— 不猜。
    public let isWritable: Bool?
    /// 根目录下的条目数。取不到为 nil。
    public let rootEntryCount: Int?
    /// 服务端标识（WebDAV 的 `Server` 头等），便于排查
    public let serverInfo: String?
    public let notes: [String]
    public let elapsedSeconds: Double
}

// ─────────────────────────────────────────────────────────── 错误 --

public enum StorageDriverError: LocalizedError, Sendable {
    case notConfigured(String)
    case unauthorized(String)
    case notFound(String)
    case httpFailure(method: String, status: Int, url: String, detail: String?)
    case malformedResponse(String)
    case unsupported(String)
    case readOnly(String)
    case pathEscapesRoot(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail):
            return "目标端未配置：\(detail)"
        case .unauthorized(let target):
            return "认证失败：\(target)（请检查用户名与密码）"
        case .notFound(let path):
            return "目标端路径不存在：\(path)"
        case .httpFailure(let method, let status, let url, let detail):
            var text = "\(method) \(url) 返回 HTTP \(status)"
            if let detail, !detail.isEmpty { text += "：\(detail)" }
            return text
        case .malformedResponse(let detail):
            return "服务端响应无法解析：\(detail)"
        case .unsupported(let detail):
            return "该操作不被支持：\(detail)"
        case .readOnly(let path):
            return "目标端只读：\(path)"
        case .pathEscapesRoot(let path):
            return "路径越出目标根目录，已拒绝：\(path)"
        case .underlying(let detail):
            return detail
        }
    }
}

// ─────────────────────────────────────────────────────────── 协议 --

/// 目标端驱动的统一接口。
///
/// 三种存储（本地 / SMB / WebDAV）的实现差异极大 —— 一个是 `FileManager`，
/// 一个是"先挂载成目录再走 FileManager"，一个是 HTTP 上的六个自定义方法。
/// 但**对上层来说它们必须是同一件事**，否则同步逻辑要写三遍，
/// 而且三遍的行为会随时间漂移（改了一处忘了另一处）。
///
/// 所以这一层只暴露"以相对路径为坐标的六个操作"，坐标原点由驱动自己决定。
public protocol StorageDriver: Sendable {
    var endpoint: StorageEndpoint { get }

    /// 连接测试。必须是**真实的一次往返**，不能是本地校验 ——
    /// 否则"测试通过"这个结论毫无意义。
    func probe() async throws -> StorageProbe

    /// 列出某个目录下的一级条目（不递归）。
    func list(relativePath: String) async throws -> [RemoteEntry]

    /// 创建目录（含中间层级）。
    func makeDirectory(relativePath: String) async throws

    /// 上传本地文件到目标端。
    func upload(from localURL: URL, to relativePath: String) async throws

    /// 从目标端下载到本地文件。
    func download(relativePath: String, to localURL: URL) async throws

    /// 删除。
    ///
    /// - Parameter recursive: 目录非空时是否需要递归删除。
    ///   传 false 而目录非空必须**报错而不是静默删掉内容** —— 静默递归是
    ///   数据丢失最常见的形式。
    func remove(relativePath: String, recursive: Bool) async throws
}

public extension StorageDriver {
    /// 判断一个相对路径是否已存在。
    func exists(relativePath: String) async throws -> Bool {
        let parent = (relativePath as NSString).deletingLastPathComponent
        let name = (relativePath as NSString).lastPathComponent
        return try await list(relativePath: parent).contains { $0.name == name }
    }
}

// ─────────────────────────────────────────────────────────── 工厂 --

public enum StorageDriverFactory {
    /// 依据端点类型构造驱动。
    ///
    /// 集中在一处，是为了让"新增一种存储要改哪些地方"有唯一答案。
    public static func make(
        endpoint: StorageEndpoint,
        credentials: StorageCredentials
    ) -> any StorageDriver {
        switch endpoint.kind {
        case .local:
            return LocalFileDriver(rootPath: endpoint.address, subpath: endpoint.subpath)
        case .smb:
            return SMBDriver(endpoint: endpoint, credentials: credentials)
        case .webdav:
            return WebDAVDriver(endpoint: endpoint, credentials: credentials)
        }
    }
}
