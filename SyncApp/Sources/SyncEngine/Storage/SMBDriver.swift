import Foundation

/// SMB / 文件共享驱动。
///
/// ## 实现路线：交给系统挂载，之后当本地目录用
///
/// macOS 自带的 SMB 客户端（`mnt-smbfs`）由 NetFS 框架驱动，就是访达
/// "连接服务器"用的那套。它处理了协商版本、NTLM/Kerberos 认证、
/// 各种服务端方言差异 —— 这些自己实现必然是几千行且长期有兼容性坑。
///
/// 所以本驱动的策略是：**把共享挂上，然后所有读写都走挂载点**，
/// 复用 `LocalFileDriver`。这样 SMB 支持的成本压到了两百行以内，
/// 而且读写语义与本地目录天然一致（不会出现"本地能传、SMB 传不了"的偏差）。
///
/// 代价是依赖系统挂载栈的行为（见 `NetworkVolume.swift` 记录的两个实测坑）。
public struct SMBDriver: StorageDriver {

    public let endpoint: StorageEndpoint
    public let credentials: StorageCredentials
    /// 挂载超时（秒）。可注入是为了让测试能用一个很短的值。
    public let mountTimeout: TimeInterval

    public init(
        endpoint: StorageEndpoint,
        credentials: StorageCredentials,
        mountTimeout: TimeInterval = NetworkVolumeMounter.defaultTimeout
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.mountTimeout = mountTimeout
    }

    // MARK: 挂载

    /// 确保共享已挂载，返回挂载点路径。
    func ensureMountPoint() async throws -> String {
        guard endpoint.kind == .smb else {
            throw StorageDriverError.notConfigured("SMBDriver 收到的端点类型是 \(endpoint.kind.rawValue)")
        }
        guard let host = endpoint.smbHost, !host.isEmpty, let share = endpoint.smbShare else {
            throw StorageDriverError.notConfigured("地址缺少主机或共享名：\(endpoint.address)")
        }
        return try await SMBMountCoordinator.shared.mountPoint(
            host: host,
            share: share,
            endpoint: endpoint,
            credentials: credentials,
            timeout: mountTimeout
        )
    }

    /// 挂载点 + 子目录，之后所有操作都落在这个目录上。
    private func localDriver(mountPoint: String) -> LocalFileDriver {
        LocalFileDriver(rootPath: mountPoint, subpath: endpoint.subpath)
    }

    // MARK: StorageDriver

    public func probe() async throws -> StorageProbe {
        let clock = MonotonicStopwatch()
        let mountPoint = try await ensureMountPoint()
        let probe = try await localDriver(mountPoint: mountPoint).probe()

        var notes = probe.notes
        notes.insert("共享挂载于 \(mountPoint)", at: 0)
        if credentials.isAnonymous {
            notes.append("当前以访客身份连接。若共享需要账号，请填写用户名与密码。")
        }
        if endpoint.subpath.isEmpty {
            notes.append("未指定子目录：将以共享根目录为同步基点。")
        }

        return StorageProbe(
            kind: .smb,
            endpointDescription: endpoint.displayText,
            resolvedLocation: probe.resolvedLocation,
            fileSystemType: probe.fileSystemType,
            isWritable: probe.isWritable,
            rootEntryCount: probe.rootEntryCount,
            serverInfo: mountPoint,
            notes: notes,
            elapsedSeconds: clock.elapsed
        )
    }

    public func list(relativePath: String) async throws -> [RemoteEntry] {
        let mountPoint = try await ensureMountPoint()
        return try await localDriver(mountPoint: mountPoint).list(relativePath: relativePath)
    }

    public func makeDirectory(relativePath: String) async throws {
        let mountPoint = try await ensureMountPoint()
        try await localDriver(mountPoint: mountPoint).makeDirectory(relativePath: relativePath)
    }

    public func upload(from localURL: URL, to relativePath: String) async throws {
        let mountPoint = try await ensureMountPoint()
        try await localDriver(mountPoint: mountPoint).upload(from: localURL, to: relativePath)
    }

    public func download(relativePath: String, to localURL: URL) async throws {
        let mountPoint = try await ensureMountPoint()
        try await localDriver(mountPoint: mountPoint).download(relativePath: relativePath, to: localURL)
    }

    public func remove(relativePath: String, recursive: Bool) async throws {
        let mountPoint = try await ensureMountPoint()
        try await localDriver(mountPoint: mountPoint).remove(relativePath: relativePath, recursive: recursive)
    }
}

// ───────────────────────────────────────────── 挂载协调（全局单例） --

/// 挂载协调器。
///
/// 存在的理由是两个具体问题，都不是"为了好看"：
///
/// 1. **重复挂载**。两个同步任务指向同一个共享时，各自去挂载会得到
///    `/Volumes/Share` 与 `/Volumes/Share-1` 两个挂载点，操作的是同一份数据
///    却以为是两个目标。所以按 `主机/共享` 缓存挂载点。
///
/// 2. **并发挂载同一共享**。并发调用 NetFS 挂同一个共享，系统层会出现
///    竞态（一个成功一个失败，或者两个挂载点）。所以把同一 key 的请求
///    合并到同一个 Task 上，而不是各挂各的。
///
/// 用 `actor` 而不是加锁的类：这里的所有状态都必须在同一串行域里访问。
actor SMBMountCoordinator {

    static let shared = SMBMountCoordinator()

    /// `主机/共享` → 挂载点
    private var resolved: [String: String] = [:]
    /// 正在进行的挂载，用于合并并发请求
    private var inFlight: [String: Task<String, Error>] = [:]

    private func key(host: String, share: String) -> String {
        "\(host.lowercased())/\(share.lowercased())"
    }

    func mountPoint(
        host: String,
        share: String,
        endpoint: StorageEndpoint,
        credentials: StorageCredentials,
        timeout: TimeInterval
    ) async throws -> String {
        let cacheKey = key(host: host, share: share)

        // 缓存命中，且挂载点仍然存在（可能被用户在访达里弹出了）。
        if let cached = resolved[cacheKey] {
            if FileManager.default.fileExists(atPath: cached) {
                return cached
            }
            resolved[cacheKey] = nil
        }

        // 已有同 key 的挂载在进行 → 复用，不重复发起。
        if let pending = inFlight[cacheKey] {
            return try await pending.value
        }

        let task = Task<String, Error> {
            try await Self.performMount(
                host: host, share: share, endpoint: endpoint,
                credentials: credentials, timeout: timeout
            )
        }
        inFlight[cacheKey] = task

        do {
            let point = try await task.value
            inFlight[cacheKey] = nil
            resolved[cacheKey] = point
            return point
        } catch {
            inFlight[cacheKey] = nil
            throw error
        }
    }

    /// 让下一次调用重新挂载（断开、或挂载点被外部移除时用）。
    func invalidate(host: String, share: String) {
        resolved[key(host: host, share: share)] = nil
    }

    private static func performMount(
        host: String,
        share: String,
        endpoint: StorageEndpoint,
        credentials: StorageCredentials,
        timeout: TimeInterval
    ) async throws -> String {
        // 先看这个共享是不是已经被系统挂着了。
        // 这一步很关键：用户在访达里已经连上的共享，我们再挂一次会得到
        // 一个带 `-1` 后缀的新挂载点，等于同一份数据出现两个路径。
        if let existing = NetworkVolumeMounter.findMountedSMBShare(host: host, share: share) {
            return existing.mountPoint
        }

        guard let url = URL(string: endpoint.address) else {
            throw VolumeMountError.invalidAddress(endpoint.address)
        }

        let mountPoints = try await NetworkVolumeMounter.mount(
            url: url,
            user: credentials.isAnonymous ? nil : credentials.user,
            password: credentials.isAnonymous ? nil : credentials.password,
            timeout: timeout
        )

        // **必须以系统返回的挂载点为准**，不能自己拼 `/Volumes/<共享名>`：
        // 同名卷已存在时系统会挂到 `/Volumes/<共享名>-1`。
        guard let point = mountPoints.first else {
            throw VolumeMountError.mountRejected(code: 0)
        }
        return point
    }
}
