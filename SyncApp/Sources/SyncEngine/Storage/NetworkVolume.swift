import CNetFS
import CoreFoundation
import Darwin
import Foundation

// ───────────────────────────────────────────────────── 已挂载的网络卷 --

/// 一个已挂载的卷（来自 `getmntinfo`）。
public struct MountedVolume: Sendable, Hashable {
    /// 挂载来源，SMB 下形如 `//user@host/share`
    public let source: String
    /// 挂载点绝对路径
    public let mountPoint: String
    /// `smbfs` / `afpfs` / `nfs` / `apfs` …
    public let fileSystemType: String
    public let isReadOnly: Bool
}

// ───────────────────────────────────────────────────── 挂载错误 --

/// 挂载失败的原因。
///
/// NetFS 的错误码有两套语义（正数 errno / 负数 OSStatus），且一部分 OSStatus
/// 值直接对应"人话"级别的失败原因。这里把它们翻译成可判定的枚举，
/// 而不是把裸数字抛到界面上 —— 用户看不懂 `-6602`，也无法据此采取行动。
public enum VolumeMountError: LocalizedError, Sendable {
    case invalidAddress(String)
    case needsInteraction(String)
    case authenticationFailed(String)
    case hostUnreachable(String)
    case shareNotFound(String)
    case alreadyMountedElsewhere(String)
    case timedOut(seconds: Double)
    case cancelled
    case mountRejected(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let detail):
            return "地址无效：\(detail)"
        case .needsInteraction(let detail):
            return "需要身份验证：\(detail)"
        case .authenticationFailed(let detail):
            return "认证失败：\(detail)（请检查用户名与密码）"
        case .hostUnreachable(let host):
            return "无法连接服务器：\(host)"
        case .shareNotFound(let share):
            return "共享不存在或无权访问：\(share)"
        case .alreadyMountedElsewhere(let point):
            return "该共享已挂载在 \(point)"
        case .timedOut(let seconds):
            return "挂载超时（\(Int(seconds)) 秒）"
        case .cancelled:
            return "挂载已取消"
        case .mountRejected(let code):
            return "挂载被拒绝（系统错误码 \(code)）"
        }
    }
}

// ───────────────────────────────────────────────────── NetFS 封装 --

/// macOS 网络卷挂载（NetFS 框架）。
///
/// ## 为什么用 NetFS 而不是 `mount_smbfs`
///
/// `mount_smbfs` 把密码放在命令行参数里，会在 `ps` 输出中短暂可见 ——
/// 对一个要长期持有 NAS 凭据的工具来说不可接受。NetFS 是访达"连接服务器"
/// 走的同一套 API，凭据通过参数传递、不进进程参数表。
///
/// ## 两个必须记住的实测行为
///
/// 1. **`NetFSMountURLSync` 会阻塞且无超时**。实测对不可达地址调用它会一直
///    不返回，还会拉起 `NetAuthAgent`（系统认证代理）。因此本文件只提供
///    异步挂载 + 主动取消的路径，让调用方能施加超时。
/// 2. **`kNAUIOptionNoUI` 必须设**。不设的话缺凭据时系统会弹认证对话框；
///    对一个后台同步任务来说，弹窗等于永久挂起。
public enum NetworkVolumeMounter {

    /// 默认超时。
    ///
    /// 取值考虑：局域网内 SMB 协商通常 < 1 秒；30 秒足以覆盖慢速链路与
    /// 需要 Kerberos 票据的场景，又不至于让界面等待过久。
    public static let defaultTimeout: TimeInterval = 30

    // MARK: 已挂载卷的枚举

    /// 列出当前所有已挂载的卷。
    ///
    /// 用途有两处：识别"这个共享已经挂着了，直接用"（省掉一次认证），
    /// 以及判断某个路径是不是网络卷（决定并发哈希的并行度该不该降）。
    public static func mountedVolumes() -> [MountedVolume] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var result: [MountedVolume] = []
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var entry = buffer[index]
            result.append(
                MountedVolume(
                    source: cString(&entry.f_mntfromname),
                    mountPoint: cString(&entry.f_mntonname),
                    fileSystemType: cString(&entry.f_fstypename),
                    isReadOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0
                )
            )
        }
        return result
    }

    /// 某个路径所在卷的文件系统类型（如 `smbfs`）。
    ///
    /// 用 `statfs` 而不是 `URLResourceValues.volumeURLResourceKeys`：
    /// 后者取不到 `f_fstypename`，只能拿到卷名与 UUID，无法判断"是不是网络卷"。
    public static func fileSystemType(atPath path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return cString(&info.f_fstypename)
    }

    /// 查找已经挂载的 SMB 共享。
    ///
    /// 匹配规则刻意宽松：挂载来源里主机名可能是 Bonjour 形式
    /// （`//user@NAS._smb._tcp.local/Share`，且被 URL 转义成 `%E5%BC%A0...`），
    /// 而用户填的是 `nas` 或 `nas.local`。所以只比较**规范化后的主机前缀**与共享名，
    /// 两者都命中才算匹配 —— 宽松到只看共享名会误匹配到另一台机器上的同名共享。
    public static func findMountedSMBShare(host: String, share: String) -> MountedVolume? {
        let wantedHost = normalizeHost(host)
        let wantedShare = share.lowercased()

        return mountedVolumes().first { volume in
            guard volume.fileSystemType == "smbfs" else { return false }
            // 去掉前导 "//"，以及 "user@" 部分与可能出现的 "@" 后缀分隔
            var rest = volume.source
            while rest.hasPrefix("/") { rest.removeFirst() }
            if let at = rest.firstIndex(of: "@") {
                rest = String(rest[rest.index(after: at)...])
            }
            let components = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let sourceHost = components.first.map(String.init) else { return false }
            let sourceShare = components.count > 1
                ? String(components[1]).removingPercentEncoding ?? String(components[1])
                : ""

            return normalizeHost(sourceHost) == wantedHost && sourceShare.lowercased() == wantedShare
        }
    }

    /// 主机名规范化。
    ///
    /// `NAS`、`nas.local`、`nas.` 视为同一台机器；Bonjour 的
    /// `._smb._tcp.local` 后缀也一并去掉 —— 否则用户填 `nas` 就匹配不到
    /// 系统挂载时记录的 `nas._smb._tcp.local`。
    private static func normalizeHost(_ raw: String) -> String {
        var host = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", ".local."] where host.hasSuffix(suffix) {
            host.removeLast(suffix.count)
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    // MARK: 挂载

    /// 异步挂载一个网络卷，并施加超时。
    ///
    /// 返回系统实际使用的挂载点路径列表。
    ///
    /// - Note: 系统可能把挂载点选成 `/Volumes/<共享名>-1`（同名卷已存在时），
    ///   所以**必须**以返回值里的路径为准，不能自己拼 `/Volumes/<共享名>`。
    public static func mount(
        url: URL,
        user: String?,
        password: String?,
        allowLoopback: Bool = false,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> [String] {

        // 抑制认证弹窗。这一条不设，缺凭据时系统会弹框，后台任务将永久挂起。
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        // 不读写用户在访达里保存的偏好：本工具的连接参数只来自自己的配置，
        // 否则会出现"改了自己的密码却因为系统里存着旧偏好而行为不一致"。
        openOptions[kNetFSNoUserPreferencesKey as String] = true
        openOptions[kNetFSForceNewSessionKey as String] = true
        if allowLoopback {
            openOptions[kNetFSAllowLoopbackKey as String] = true
        }

        let mountOptions = NSMutableDictionary()
        // 软挂载：服务器失联时让 IO 报错返回，而不是让进程永久卡在不可中断的等待里。
        mountOptions[kNetFSSoftMountKey as String] = true
        // 让系统自己选挂载点（与访达一致），再从返回值读实际路径。
        mountOptions[kNetFSMountAtMountDirKey as String] = false

        let open = openOptions as CFMutableDictionary
        let mountDict = mountOptions as CFMutableDictionary
        let cfURL = url as CFURL
        let cfUser = user.map { $0 as CFString }
        let cfPassword = password.map { $0 as CFString }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = SingleResume(continuation)
            let queue = DispatchQueue(label: "com.syncengine.netfs.mount")

            var requestID: AsyncRequestID?
            let immediate = NetFSMountURLAsync(
                cfURL,
                nil,
                cfUser,
                cfPassword,
                open,
                mountDict,
                &requestID,
                queue
            ) { status, _, mountPoints in
                if status == 0 {
                    let paths = (mountPoints as? [String]) ?? []
                    gate.succeed(paths)
                } else {
                    gate.fail(translate(status: status, url: url))
                }
            }

            // 立即返回非 0 表示"请求根本没发出去"（参数错误等）；
            // 真正失败是在回调里。两种情况都要处理，否则会悬住。
            if immediate != 0 {
                gate.fail(translate(status: immediate, url: url))
                return
            }

            // 取消句柄先转成 UInt 再交给超时闭包：
            // AsyncRequestID 是 UnsafeMutableRawPointer，不满足 Sendable，
            // 直接捕获会触发并发检查告警。转成整数值传递既保留了"句柄"的语义，
            // 又不引入跨并发域的裸指针（指针本身在 NetFS 内部保活，我们只做取消用）。
            let cancelToken = requestID.map { UInt(bitPattern: $0) }

            queue.asyncAfter(deadline: .now() + timeout) {
                guard gate.isEmpty else { return }
                if let cancelToken, let pointer = UnsafeMutableRawPointer(bitPattern: cancelToken) {
                    // 取消后回调不会再被调用（NetFS 文档明确保证），
                    // 所以超时的 continuation 必须由我们这边恢复。
                    _ = NetFSMountURLCancel(pointer)
                }
                gate.fail(VolumeMountError.timedOut(seconds: timeout))
            }
        }
    }

    // 关于 `NetFSMountURLProbe`：曾想用它做"输入裸主机名时自动判断协议"，
    // 但它的头文件没有标 `CF_RETURNS_RETAINED`，Swift 只能导入成
    // `Unmanaged<CFString>`，所有权全靠猜 —— 猜错要么泄漏要么崩溃。
    // 而它的实现是对多个候选端口并发 TCP 连接后 select，**是阻塞调用**。
    // 为一个可有可无的输入辅助去承担这两样，不划算，故不封装。

    // MARK: 错误码翻译

    /// 把 NetFS 的两套错误码翻译成可判定的原因。
    ///
    /// 正数是 errno，负数是 OSStatus / NetAuth 扩展码。
    /// 具体取值见 SDK 的 `NetFS.h` 注释与 `<NetAuth/NetAuthErrors.h>`。
    private static func translate(status: Int32, url: URL) -> VolumeMountError {
        let host = url.host ?? url.absoluteString
        if status > 0 {
            switch status {
            case EACCES, EPERM:
                return .authenticationFailed(host)
            case ETIMEDOUT:
                return .timedOut(seconds: defaultTimeout)
            case ENOENT:
                return .shareNotFound(url.path)
            case ENOTCONN, ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, ECONNRESET:
                return .hostUnreachable(host)
            default:
                return .mountRejected(code: status)
            }
        }
        switch status {
        case -5045, -5046, -5999:
            // 密码需要修改 / 密码策略不满足 / 账号受限：
            // 都属于"凭据有问题"，但都不该让调用方重试同一份凭据。
            return .authenticationFailed(host)
        case -5998, -6003:
            return .shareNotFound(url.path)
        case -5997, -5996, -6600:
            return .needsInteraction(host)
        case -6602:
            return .authenticationFailed(host)
        case -6004:
            return .authenticationFailed("服务器不支持访客访问")
        case -128:
            return .cancelled
        default:
            return .mountRejected(code: status)
        }
    }

    // MARK: 辅助

    /// 把 C 的定长字符数组读成 String。
    private static func cString<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}

/// 保证 continuation 只被恢复一次。
///
/// 异步挂载有三条恢复路径（成功回调、失败回调、超时），而超时与回调
/// 可能同时发生 —— 对同一个 continuation 恢复两次会直接崩溃。
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?

    init(_ continuation: CheckedContinuation<[String], Error>) {
        self.continuation = continuation
    }

    /// 尚未恢复。
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    func succeed(_ value: [String]) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
