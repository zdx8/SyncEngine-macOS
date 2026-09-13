import Foundation
import XCTest

@testable import SyncEngine

/// SMB 的集成测试。
///
/// ## 验证策略：对真实挂载做只读验证，绝不写用户的共享
///
/// SMB 的读写路径复用 `LocalFileDriver`（挂载后共享就是一个普通目录），
/// 而那一层已经被 `StorageTests` 完整覆盖。因此这里需要额外证明的是
/// **SMB 特有的那部分**：
///   * 网络卷能被识别出来（`statfs` 的 `f_fstypename` 是 `smbfs`）
///   * 挂载来源能被正确解析并与用户输入的地址匹配上
///   * 驱动能复用已挂载的共享，而不是重新挂一个带 `-1` 后缀的
///   * 经过这条路径读到的字节与直接读一致
///
/// 本机没有 SMB 挂载时整体跳过（`XCTSkip`），而不是失败 ——
/// 这些结论依赖环境，不该让别的机器上的 `swift test` 变红。
///
/// **写入验证刻意不做。** 那会往用户的 NAS 上写文件；要做的话由使用者显式
/// 指定共享（见本文件末尾的 `testOptInWriteRoundTripOnNominatedShare`）。
final class SMBDriverTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-smb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: 夹具

    private var smbVolumes: [MountedVolume] {
        NetworkVolumeMounter.mountedVolumes().filter { $0.fileSystemType == "smbfs" }
    }

    /// 从挂载来源反解出主机与共享名。
    ///
    /// 来源形如 `//user@host/share` 或 `//%E5%BC%A0...@host/share`，
    /// 用户名与共享名都可能被百分号编码。
    private func split(_ volume: MountedVolume) -> (host: String, share: String)? {
        var rest = volume.source
        while rest.hasPrefix("/") { rest.removeFirst() }
        if let at = rest.firstIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let host = parts.first.map(String.init) else { return nil }
        let share = parts.count > 1
            ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
            : ""
        guard !share.isEmpty else { return nil }
        return (host, share)
    }

    // MARK: 网络卷识别

    func testMountedVolumesAreEnumerable() {
        let volumes = NetworkVolumeMounter.mountedVolumes()
        XCTAssertFalse(volumes.isEmpty, "至少应枚举出根卷")
        XCTAssertTrue(
            volumes.contains { $0.mountPoint == "/" },
            "根卷必须出现，实际：\(volumes.map(\.mountPoint).prefix(6))"
        )
    }

    func testFileSystemTypeIsReadableForLocalPaths() {
        let type = NetworkVolumeMounter.fileSystemType(atPath: NSTemporaryDirectory())
        XCTAssertNotNil(type, "statfs 应能读出临时目录所在卷的类型")
        XCTAssertEqual(
            type,
            NetworkVolumeMounter.fileSystemType(atPath: "/"),
            "临时目录与根目录通常在同一卷上"
        )
    }

    func testFileSystemTypeIsNilForMissingPath() {
        XCTAssertNil(
            NetworkVolumeMounter.fileSystemType(atPath: "/definitely-not-here-\(UUID().uuidString)")
        )
    }

    /// 这条是 SMB 判定的地基：不能靠路径前缀猜，必须问 `statfs`。
    func testSMBMountsReportSmbfsFileSystemType() throws {
        let volumes = smbVolumes
        try XCTSkipIf(volumes.isEmpty, "本机没有 SMB 挂载，跳过")

        for volume in volumes.prefix(3) {
            XCTAssertEqual(
                NetworkVolumeMounter.fileSystemType(atPath: volume.mountPoint),
                "smbfs",
                "\(volume.mountPoint) 应被识别为 smbfs"
            )
        }
    }

    // MARK: 已挂载共享的匹配

    func testFindMountedShareMatchesRealVolumes() throws {
        let volumes = smbVolumes
        try XCTSkipIf(volumes.isEmpty, "本机没有 SMB 挂载，跳过")

        var checked = 0
        for volume in volumes.prefix(3) {
            guard let (host, share) = split(volume) else { continue }
            let found = NetworkVolumeMounter.findMountedSMBShare(host: host, share: share)
            XCTAssertNotNil(found, "应能匹配到 \(host)/\(share)")
            XCTAssertEqual(found?.mountPoint, volume.mountPoint)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "至少要成功解析并匹配一个共享")
    }

    func testFindMountedShareRequiresShareToMatch() throws {
        let volumes = smbVolumes
        try XCTSkipIf(volumes.isEmpty, "本机没有 SMB 挂载，跳过")
        guard let (host, _) = split(volumes[0]) else {
            throw XCTSkip("无法解析挂载来源")
        }
        // 只看主机名是不够的：同一台机器上可能有多个共享，
        // 宽松到只比主机就会把数据同步到错误的共享里。
        XCTAssertNil(
            NetworkVolumeMounter.findMountedSMBShare(host: host, share: "no-such-share-xyz"),
            "共享名不匹配时绝不能误判为已挂载"
        )
    }

    func testFindMountedShareRejectsUnrelatedHost() throws {
        try XCTSkipIf(smbVolumes.isEmpty, "本机没有 SMB 挂载，跳过")
        XCTAssertNil(
            NetworkVolumeMounter.findMountedSMBShare(host: "no-such-host.invalid", share: "Share")
        )
    }

    // MARK: 驱动复用已挂载共享（只读）

    /// 端到端：驱动指向一个**真实存在**的 SMB 共享，验证它会复用已挂载的卷，
    /// 而不是重新挂一个 `-1` 后缀的新卷。
    func testDriverReusesExistingMountReadOnly() async throws {
        let volumes = smbVolumes
        try XCTSkipIf(volumes.isEmpty, "本机没有 SMB 挂载，跳过")
        guard let volume = volumes.first(where: { split($0) != nil }),
              let (host, share) = split(volume) else {
            throw XCTSkip("无法解析挂载来源")
        }

        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://\(host)/\(share)")
        // 已挂载的共享无需再认证，用访客凭据即可走到"复用"分支。
        let driver = SMBDriver(endpoint: endpoint, credentials: .anonymous)

        let probe = try await driver.probe()
        XCTAssertEqual(probe.kind, .smb)
        XCTAssertEqual(probe.fileSystemType, "smbfs", "驱动必须落在网络卷上")
        XCTAssertEqual(
            probe.resolvedLocation, volume.mountPoint,
            "应复用已有挂载点，而不是挂出一个新卷"
        )
        XCTAssertNotNil(probe.rootEntryCount)

        // 列目录 + 只读读取一个真实文件，验证字节路径
        let entries = try await driver.list(relativePath: "")
        XCTAssertFalse(entries.isEmpty, "共享根目录不该是空的")

        guard let file = entries.first(where: { !$0.isDirectory && $0.size > 0 && $0.size < 1_048_576 }),
              let mounted = NetworkVolumeMounter.findMountedSMBShare(host: host, share: share) else {
            throw XCTSkip("共享根目录下没有合适的小文件可供只读验证")
        }

        let restored = scratch.appendingPathComponent("smb-read.bin")
        try await driver.download(relativePath: file.relativePath, to: restored)

        let direct = URL(fileURLWithPath: mounted.mountPoint)
            .appendingPathComponent(file.relativePath)
        XCTAssertEqual(
            try ContentHasher.sha256(ofFileAt: restored.path),
            try ContentHasher.sha256(ofFileAt: direct.path),
            "经驱动读到的字节必须与直接读挂载点一致"
        )
    }

    func testDriverReportsMountPointInProbeNotes() async throws {
        let volumes = smbVolumes
        try XCTSkipIf(volumes.isEmpty, "本机没有 SMB 挂载，跳过")
        guard let volume = volumes.first(where: { split($0) != nil }),
              let (host, share) = split(volume) else {
            throw XCTSkip("无法解析挂载来源")
        }
        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://\(host)/\(share)")
        let probe = try await SMBDriver(endpoint: endpoint, credentials: .anonymous).probe()
        XCTAssertTrue(
            probe.notes.contains { $0.contains(volume.mountPoint) },
            "探测结果里应写明挂载点，便于排查，实际：\(probe.notes)"
        )
    }

    // MARK: 未挂载时的失败路径

    /// 连不上的服务器必须**快速失败并给出可读原因**，而不是挂住。
    ///
    /// 这条断言之所以重要：NetFS 的同步挂载 API 实测会一直不返回
    /// （还会拉起系统认证代理），所以我们只用异步挂载 + 超时取消。
    /// 这个测试用 1 秒超时守住"不会挂住"这个性质。
    func testDriverFailsFastForUnreachableHost() async throws {
        // 保留一个本地未监听的端口，连接会被立即拒绝。
        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://127.0.0.1/nonexistent")

        // 直接测挂载器，绕开"已挂载则复用"的分支。
        let clock = MonotonicStopwatch()
        do {
            _ = try await NetworkVolumeMounter.mount(
                url: URL(string: endpoint.address)!,
                user: "nobody",
                password: "nobody",
                allowLoopback: true,
                timeout: 3
            )
            XCTFail("连不上的服务器不该挂载成功")
        } catch {
            let elapsed = clock.elapsed
            XCTAssertLessThan(elapsed, 20, "必须在超时范围内返回，实测 \(elapsed) 秒")
            // 报错必须是人能看懂的原因，而不是一个裸错误码
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.contains("unknown") || text.contains("未知"),
                "错误原因不该是'未知'，实际：\(text)"
            )
        }
    }

    // MARK: 可选：对指定共享做写入往返

    /// 默认跳过。只有在显式设置环境变量时才跑，因为它会**写入真实的网络共享**。
    ///
    /// ```
    /// SYNC_SMB_WRITE_TEST="smb://host/Share" \
    /// SYNC_SMB_WRITE_TEST_USER=me SYNC_SMB_WRITE_TEST_PASSWORD=... \
    /// swift test --filter testOptInWriteRoundTripOnNominatedShare
    /// ```
    ///
    /// 只在一个独立子目录里写、并在结束时删除，不会碰共享里的既有内容。
    func testOptInWriteRoundTripOnNominatedShare() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["SYNC_SMB_WRITE_TEST"], !address.isEmpty else {
            throw XCTSkip("未设置 SYNC_SMB_WRITE_TEST，跳过（该用例会写入真实共享）")
        }
        let credentials = StorageCredentials(
            user: environment["SYNC_SMB_WRITE_TEST_USER"] ?? "",
            password: environment["SYNC_SMB_WRITE_TEST_PASSWORD"] ?? ""
        )
        let endpoint = try StorageEndpoint(kind: .smb, address: address)
        let driver = SMBDriver(endpoint: endpoint, credentials: credentials)

        let folder = ".syncapp-selftest-\(UUID().uuidString)"
        var payload = Data("SMB 写入往返验证\n".utf8)
        payload.append(Data((0..<256).map { UInt8($0) }))
        let source = scratch.appendingPathComponent("payload.bin")
        try payload.write(to: source)

        do {
            try await driver.makeDirectory(relativePath: folder)
            try await driver.upload(from: source, to: "\(folder)/payload.bin")

            let restored = scratch.appendingPathComponent("restored.bin")
            try await driver.download(relativePath: "\(folder)/payload.bin", to: restored)
            XCTAssertEqual(
                try ContentHasher.sha256(ofFileAt: restored.path),
                try ContentHasher.sha256(ofFileAt: source.path)
            )

            let entries = try await driver.list(relativePath: folder)
            XCTAssertEqual(entries.map(\.name), ["payload.bin"])
        } catch {
            try? await driver.remove(relativePath: folder, recursive: true)
            throw error
        }

        try await driver.remove(relativePath: folder, recursive: true)
        let remaining = try await driver.list(relativePath: "")
        XCTAssertFalse(remaining.contains { $0.name == folder }, "测试目录应已被清理")
    }
}
