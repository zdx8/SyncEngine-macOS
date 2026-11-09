import Foundation

/// 本地文件系统驱动。
///
/// 同时被两处使用：
///   1. 目标端就是本地目录的任务
///   2. **SMB 挂载之后** —— 网络共享一旦挂上，对进程而言就是一个普通目录，
///      再写一套 SMB 专用读写毫无意义，还会引入第二份实现随时间漂移的风险
///
/// 这个"挂载后复用"的设计是 SMB 支持只需要两百行的根本原因。
public struct LocalFileDriver: StorageDriver {

    public let rootPath: String
    /// 根目录内的基准子目录（相对 rootPath）。
    public let subpath: String

    public init(rootPath: String, subpath: String = "") {
        self.rootPath = rootPath
        self.subpath = subpath
    }

    /// 实际操作的根 = rootPath + subpath。
    private var basePath: String {
        guard !subpath.isEmpty else { return rootPath }
        return (rootPath as NSString).appendingPathComponent(subpath)
    }

    /// 实际用于枚举与读写的根（已解开软链）。
    ///
    /// ## 为什么必须解开
    ///
    /// Foundation 的 URL 版目录枚举**不跟随末端的软链**：
    /// 对指向目录的软链调用 `contentsOfDirectory(at:)` 会抛
    /// `NSFileReadUnknownError(256)`，而 `opendir(3)` 对同一路径完全正常。
    ///
    /// 这不是罕见情形 —— 用户把同步基点设成 `~/Desktop` 的别名、
    /// 外接盘在 `/Volumes` 下的链接、`/var` 与 `/tmp` 这类系统软链都会命中。
    /// 不解开的后果是**静默的空结果**："扫描完成，0 个文件"，
    /// 而目录里明明有东西 —— 比报错更难查。
    private var effectiveRoot: URL {
        // `standardizedFileURL` 这一步不能省。macOS 上"解析软链"有两套口径：
        //   * `resolvingSymlinksInPath()` 保留 `/var` 前缀（Foundation 的历史行为）
        //   * `contentsOfDirectory` 内部用真正的 realpath，返回 `/private/var/...`
        // 两者混用会让子项路径与基准对不上前缀，`relativePath` 于是退化成绝对路径。
        // 标准化会把 `/private/var` 归一成 `/var`，两边就一致了。
        URL(fileURLWithPath: basePath).resolvingSymlinksInPath().standardizedFileURL
    }

    public var endpoint: StorageEndpoint {
        // LocalFileDriver 可能被 SMB 复用，此时 endpoint 由 SMBDriver 自己合成，
        // 这里的值只在"目标就是本地目录"时被使用。
        (try? StorageEndpoint(kind: .local, address: rootPath, subpath: subpath))
            ?? StorageEndpoint(uncheckedKind: .local, address: rootPath, subpath: subpath)
    }

    // MARK: 路径解析（含逃逸防护）

    /// 把相对路径解析为绝对路径，并确认它没有越出根目录。
    ///
    /// ## 两道检查都不能省
    ///
    /// 1. **词法检查**：`standardizedFileURL` 会消掉 `..`，先挡住
    ///    `../../etc/passwd` 这类直接构造的路径。
    /// 2. **软链检查**：只做词法检查挡不住软链 ——
    ///    根目录里放一个指向 `/Users/other` 的软链，`list` 返回的路径
    ///    词法上完全正常，但顺着它读写就跑到根目录外去了。
    ///    所以还要把**目标自身**（取不到时退回到它的父目录）解析软链后再比一次。
    ///
    /// 第 2 条按项目约定：校验目标自身，而不是只校验父目录。
    func resolve(_ relativePath: String) throws -> URL {
        let rootURL = effectiveRoot
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 根自身直接放行，不做逃逸检查。
        //
        // 这不只是"省一次计算"：macOS 上 `NSTemporaryDirectory()` 返回的
        // `/var/folders/...` 与系统里的 `/tmp`、`/var` 一样带软链，
        // 于是"根的父目录"解析后可能落在根之外，检查必然误判成逃逸 ——
        // 表现为**任何**以软链形式给出的根目录都用不了。
        // 而"根在不在根里"是个恒真的问题，本就不该问。
        if trimmed.isEmpty { return rootURL }

        let target = rootURL.appendingPathComponent(trimmed).standardizedFileURL

        guard Self.isContained(target, in: rootURL) else {
            throw StorageDriverError.pathEscapesRoot(relativePath)
        }

        // 目标通常还不存在（上传场景），此时 resolvingSymlinksInPath 只会
        // 解析到最近的存在祖先。所以再单独校验父目录解析后的位置。
        // 比较前两侧都标准化，理由见 `effectiveRoot` 的说明。
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = target.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(resolvedTarget, in: rootURL),
              Self.isContained(resolvedParent, in: rootURL) else {
            throw StorageDriverError.pathEscapesRoot(relativePath)
        }

        return target
    }

    private static func isContained(_ target: URL, in root: URL) -> Bool {
        if target.path == root.path { return true }
        return target.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    /// 由绝对路径反推相对路径。
    ///
    /// 名字刻意不叫 `relativePath(for:)`：那会与 `list(relativePath:)` 的
    /// 参数名撞车，调用点变成"把一个 String 当函数调用"的编译错误。
    private func makeRelativePath(for url: URL) -> String {
        // 必须用与枚举同一个根来剥离前缀，且两侧都标准化 ——
        // 否则子项路径（可能是 `/private/var/...`）匹配不上基准（`/var/...`），
        // relativePath 会整片退化成绝对路径。
        let rootPath = effectiveRoot.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return full }
        var rel = String(full.dropFirst(rootPath.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    // MARK: StorageDriver

    public func probe() async throws -> StorageProbe {
        let clock = MonotonicStopwatch()
        let base = try resolve("")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            throw StorageDriverError.notFound(base.path)
        }
        guard isDirectory.boolValue else {
            throw StorageDriverError.notConfigured("\(base.path) 不是目录")
        }

        var notes: [String] = []
        // 根是软链时说清楚实际指向哪里 —— 否则用户看到"可写：否"却不知道
        // 自己在看哪个目录。
        if base.path != URL(fileURLWithPath: basePath).standardizedFileURL.path {
            notes.append("该路径是软链，实际指向 \(base.path)。")
        }
        let fsType = NetworkVolumeMounter.fileSystemType(atPath: base.path)
        if let fsType, fsType != "apfs", fsType != "hfs" {
            notes.append("这是网络卷（\(fsType)）：并发哈希的并行度应调小，"
                + "并发读写会让网络往返互相竞争。")
        }

        let entries = (try? await list(relativePath: "")) ?? []
        let writable = FileManager.default.isWritableFile(atPath: base.path)

        return StorageProbe(
            kind: .local,
            endpointDescription: base.path,
            resolvedLocation: base.path,
            fileSystemType: fsType,
            isWritable: writable,
            rootEntryCount: entries.count,
            serverInfo: nil,
            notes: notes,
            elapsedSeconds: clock.elapsed
        )
    }

    public func list(relativePath: String) async throws -> [RemoteEntry] {
        let directory = try resolve(relativePath)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey,
        ]

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: []
            )
        } catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError {
                throw StorageDriverError.notFound(directory.path)
            }
            if error.code == NSFileReadNoPermissionError {
                throw StorageDriverError.unauthorized(directory.path)
            }
            throw StorageDriverError.underlying(error.localizedDescription)
        }

        var result: [RemoteEntry] = []
        result.reserveCapacity(children.count)
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            // 软链接一律视为普通条目，不跟随 —— 与引擎遍历策略保持一致。
            let isDirectory = (values?.isDirectory ?? false) && (values?.isSymbolicLink != true)
            result.append(
                RemoteEntry(
                    name: child.lastPathComponent,
                    relativePath: makeRelativePath(for: child),
                    isDirectory: isDirectory,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate
                )
            )
        }

        // 目录在前、同类按名字排：与访达一致，用户在界面上找东西时靠的是这个顺序。
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return result
    }

    public func makeDirectory(relativePath: String) async throws {
        guard !relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            return  // 基准目录本身已存在，无事可做
        }
        let target = try resolve(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true
            )
        } catch {
            throw StorageDriverError.underlying(error.localizedDescription)
        }
    }

    public func upload(from localURL: URL, to relativePath: String) async throws {
        let target = try resolve(relativePath)
        let parent = target.deletingLastPathComponent()

        // 先保证父目录存在。WebDAV 那边同样如此，行为要一致 ——
        // 否则"上传"在本地能用、在网络端报错，用户无法理解。
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(".syncapp-\(UUID().uuidString).part")
        do {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.copyItem(at: localURL, to: staging)

            // 先写临时名、再替换。
            //
            // **不能省这一步。** 直接覆盖目标文件时，如果写到一半崩溃或断电，
            // 留在磁盘上的是一个残文件，而它的 mtime 和大小看起来都正常 ——
            // 下一次同步会认为"内容没变"，这个坏文件就永久留在那里了。
            if FileManager.default.fileExists(atPath: target.path) {
                // 优先用交换式的原子替换。
                //
                // 但它底层是 `renamex_np(RENAME_SWAP)`，**smbfs 上未必支持** ——
                // 实测这类"文件系统不支持"的失败只会在挂载到网络卷时才出现，
                // 在本地开发时完全看不到。所以失败必须能降级。
                do {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                } catch {
                    // 降级：删旧再改名。失去原子性，但换来在网络上真的能用。
                    // 断点续传与索引校验会兜住这个窗口（见技术方案 4.3）。
                    try FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: staging, to: target)
                }
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw StorageDriverError.underlying("写入 \(target.path) 失败：\(error.localizedDescription)")
        }
    }

    public func download(relativePath: String, to localURL: URL) async throws {
        let source = try resolve(relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StorageDriverError.notFound(source.path)
        }
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.copyItem(at: source, to: localURL)
        } catch {
            throw StorageDriverError.underlying(error.localizedDescription)
        }
    }

    public func remove(relativePath: String, recursive: Bool) async throws {
        let target = try resolve(relativePath)
        guard target.path != effectiveRoot.path else {
            throw StorageDriverError.unsupported("拒绝删除目标根目录本身")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            return  // 已经不存在，视为成功（幂等）
        }

        if isDirectory.boolValue && !recursive {
            let items = try FileManager.default.contentsOfDirectory(atPath: target.path)
            guard items.isEmpty else {
                // 明确报错而不是默默递归：静默递归删除是数据丢失最常见的形式。
                throw StorageDriverError.unsupported(
                    "\(relativePath) 是非空目录，递归删除未被允许（共 \(items.count) 项）"
                )
            }
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw StorageDriverError.underlying(error.localizedDescription)
        }
    }
}
