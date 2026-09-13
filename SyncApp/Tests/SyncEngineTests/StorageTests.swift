import Foundation
import XCTest

@testable import SyncEngine

/// 存储层的单元测试。
///
/// 关注点与 `EngineTests` 一致：**断言结构性不变量，而不是环境相关的数值**。
/// 例如"路径逃逸必须被拒绝"在任何机器上都必须成立，
/// 而"上传 10 MB 耗时小于 1 秒"则随磁盘与网络变化。
final class StorageTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-storage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - 地址解析与规范化

    func testSMBAddressAcceptsBareHostAndShare() throws {
        // 用户不会记得写协议头，裸写必须能用。
        let endpoint = try StorageEndpoint(kind: .smb, address: "nas.local/Share")
        XCTAssertEqual(endpoint.address, "smb://nas.local/Share")
    }

    func testSMBAddressDropsDefaultPortAndTrailingSlash() throws {
        // 同一个位置的不同写法必须收敛成一个值，否则 Keychain 里会出现多份凭据。
        let withPort = try StorageEndpoint(kind: .smb, address: "smb://nas.local:445/Share")
        let withoutPort = try StorageEndpoint(kind: .smb, address: "smb://nas.local/Share/")
        XCTAssertEqual(withPort.address, withoutPort.address)
        XCTAssertEqual(withPort.address, "smb://nas.local/Share")
    }

    func testSMBAddressKeepsNonDefaultPort() throws {
        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://nas.local:1445/Share")
        XCTAssertEqual(endpoint.address, "smb://nas.local:1445/Share")
    }

    func testSMBAddressRejectsMissingShare() {
        XCTAssertThrowsError(try StorageEndpoint(kind: .smb, address: "smb://nas.local")) { error in
            XCTAssertTrue(error is StorageAddressError, "应抛出地址错误，实际：\(error)")
        }
    }

    func testSMBAddressRejectsWrongScheme() {
        XCTAssertThrowsError(try StorageEndpoint(kind: .smb, address: "https://nas.local/Share"))
    }

    func testWebDAVAddressDefaultsToHTTPSForBareHost() throws {
        // 裸主机名默认 https：明文是少数派，默认值应当更安全。
        let endpoint = try StorageEndpoint(kind: .webdav, address: "nas.local:5006/dav")
        XCTAssertEqual(endpoint.address, "https://nas.local:5006/dav")
    }

    func testWebDAVAddressPreservesExplicitHTTP() throws {
        let endpoint = try StorageEndpoint(kind: .webdav, address: "http://nas.local/dav/")
        XCTAssertEqual(endpoint.address, "http://nas.local/dav")
    }

    func testLocalAddressExpandsTilde() throws {
        let endpoint = try StorageEndpoint(kind: .local, address: "~/Documents")
        XCTAssertFalse(endpoint.address.contains("~"), "~ 必须被展开，否则引擎会得到不存在的路径")
        XCTAssertTrue(endpoint.address.hasPrefix("/"))
    }

    func testLocalAddressRejectsRelativePath() {
        XCTAssertThrowsError(try StorageEndpoint(kind: .local, address: "relative/path"))
    }

    func testEmptyAddressRejectedForEveryKind() {
        for kind in StorageKind.allCases {
            XCTAssertThrowsError(try StorageEndpoint(kind: kind, address: "   "))
        }
    }

    func testSubpathIsNormalized() throws {
        let endpoint = try StorageEndpoint(kind: .smb, address: "nas/Share", subpath: "/a//b/c/")
        XCTAssertEqual(endpoint.subpath, "a/b/c")
        XCTAssertEqual(endpoint.displayText, "smb://nas/Share/a/b/c")
    }

    func testSMBHostAndShareExtraction() throws {
        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://nas.local:1445/My Share")
        XCTAssertEqual(endpoint.smbHost, "nas.local")
        XCTAssertEqual(endpoint.smbShare, "My Share")
    }

    // MARK: - 本地驱动：路径逃逸防护

    func testLocalDriverRejectsParentTraversal() async throws {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        XCTAssertThrowsError(try driver.resolve("../../etc/passwd")) { error in
            guard case StorageDriverError.pathEscapesRoot = error else {
                return XCTFail("应拒绝路径逃逸，实际：\(error)")
            }
        }
    }

    /// 只做词法检查挡不住软链 —— 这是最容易漏的一条。
    func testLocalDriverRejectsSymlinkEscape() async throws {
        let root = tempRoot.appendingPathComponent("root")
        let outside = tempRoot.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(
            to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        // 根目录里一个指向外部的软链
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let driver = LocalFileDriver(rootPath: root.path)

        // 词法上 "link/secret.txt" 完全正常，但顺着它读写就跑到根目录外了。
        XCTAssertThrowsError(try driver.resolve("link/secret.txt")) { error in
            guard case StorageDriverError.pathEscapesRoot = error else {
                return XCTFail("软链逃逸必须被拒绝，实际：\(error)")
            }
        }

        // 列表里它仍然是一个普通条目（不跟随），但不能被访问
        let entries = try await driver.list(relativePath: "")
        XCTAssertTrue(entries.contains { $0.name == "link" })
    }

    func testLocalDriverRejectsSymlinkedRootItself() async throws {
        // 根目录是软链指向外部目录时，根内的相对路径应当被正常允许 ——
        // 因为"根"就是那个外部目录，不是逃逸。这里验证不会误伤。
        let outside = tempRoot.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(
            to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let linkRoot = tempRoot.appendingPathComponent("linkroot")
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: outside)

        let driver = LocalFileDriver(rootPath: linkRoot.path)
        let entries = try await driver.list(relativePath: "")
        XCTAssertTrue(entries.contains { $0.name == "f.txt" }, "根目录内的正常文件不应被误拒")
    }

    // MARK: - 本地驱动：读写往返

    func testLocalDriverUploadDownloadRoundTripPreservesBytes() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("src")
        let targetRoot = tempRoot.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        // 内容含二进制与中文，跨编码都能验证
        var payload = Data("同步工具内容校验 · hello\n".utf8)
        payload.append(Data((0..<256).map { UInt8($0) }))
        let file = sourceRoot.appendingPathComponent("payload.bin")
        try payload.write(to: file)

        let driver = LocalFileDriver(rootPath: targetRoot.path)
        try await driver.upload(from: file, to: "sub/dir/payload.bin")

        // 多级父目录应被自动创建 —— 否则"上传到新子目录"会失败。
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetRoot.appendingPathComponent("sub/dir/payload.bin").path)
        )

        let restored = tempRoot.appendingPathComponent("restored.bin")
        try await driver.download(relativePath: "sub/dir/payload.bin", to: restored)

        XCTAssertEqual(
            try ContentHasher.sha256(ofFileAt: restored.path),
            try ContentHasher.sha256(ofFileAt: file.path),
            "往返后内容哈希必须一致"
        )
    }

    func testLocalDriverUploadOverwritesExistingFine() async throws {
        let sourceRoot = tempRoot.appendingPathComponent("src2")
        let targetRoot = tempRoot.appendingPathComponent("dst2")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let driver = LocalFileDriver(rootPath: targetRoot.path)
        let first = sourceRoot.appendingPathComponent("a.txt")
        try "第一版".write(to: first, atomically: true, encoding: .utf8)
        try await driver.upload(from: first, to: "a.txt")

        let second = sourceRoot.appendingPathComponent("b.txt")
        try "第二版内容更长一些".write(to: second, atomically: true, encoding: .utf8)
        try await driver.upload(from: second, to: "a.txt")

        let text = try String(contentsOf: targetRoot.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(text, "第二版内容更长一些")
    }

    func testLocalDriverRefusesRecursiveRemoveOfNonEmptyDirectory() async throws {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        let dir = tempRoot.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "重要数据".write(
            to: dir.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)

        // 非递归删除非空目录必须报错，且**内容不能被删掉**。
        do {
            try await driver.remove(relativePath: "keep", recursive: false)
            XCTFail("非空目录的非递归删除应当报错")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("important.txt").path),
                "报错时绝不能已经删掉了内容")
        }

        try await driver.remove(relativePath: "keep", recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testLocalDriverRefusesToRemoveRootItself() async throws {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        do {
            try await driver.remove(relativePath: "", recursive: true)
            XCTFail("删除根目录必须被拒绝")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))
        }
    }

    func testLocalDriverListPutsDirectoriesFirst() async throws {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("zdir"), withIntermediateDirectories: true)
        try "a".write(to: tempRoot.appendingPathComponent("afile.txt"), atomically: true, encoding: .utf8)

        let entries = try await driver.list(relativePath: "")
        XCTAssertEqual(entries.first?.name, "zdir", "目录应排在前，与访达一致")
        XCTAssertTrue(entries.first?.isDirectory == true)
    }

    func testLocalDriverProbeReportsFileSystemAndWritability() async throws {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        let probe = try await driver.probe()
        XCTAssertEqual(probe.kind, .local)
        XCTAssertNotNil(probe.fileSystemType)
        XCTAssertEqual(probe.isWritable, true)
        XCTAssertEqual(probe.rootEntryCount, 0)
    }

    func testLocalDriverProbeThrowsForMissingDirectory() async {
        let driver = LocalFileDriver(rootPath: tempRoot.appendingPathComponent("nope").path)
        do {
            _ = try await driver.probe()
            XCTFail("不存在的目录应当报错")
        } catch {
            guard case StorageDriverError.notFound = error else {
                return XCTFail("应报 notFound，实际：\(error)")
            }
        }
    }

    func testLocalDriverListThrowsForMissingDirectory() async {
        let driver = LocalFileDriver(rootPath: tempRoot.path)
        do {
            _ = try await driver.list(relativePath: "definitely-missing")
            XCTFail("不存在的目录应当报错")
        } catch {
            guard case StorageDriverError.notFound = error else {
                return XCTFail("应报 notFound，实际：\(error)")
            }
        }
    }

    // MARK: - 驱动工厂

    func testFactoryReturnsMatchingDriverForEachKind() throws {
        let local = StorageDriverFactory.make(
            endpoint: try StorageEndpoint(kind: .local, address: tempRoot.path),
            credentials: .anonymous
        )
        XCTAssertTrue(local is LocalFileDriver)

        let smb = StorageDriverFactory.make(
            endpoint: try StorageEndpoint(kind: .smb, address: "nas/Share"),
            credentials: .anonymous
        )
        XCTAssertTrue(smb is SMBDriver)

        let webdav = StorageDriverFactory.make(
            endpoint: try StorageEndpoint(kind: .webdav, address: "https://nas.local/dav"),
            credentials: .anonymous
        )
        XCTAssertTrue(webdav is WebDAVDriver)
    }

    // MARK: - 凭据存储

    func testCredentialStoreRoundTrip() throws {
        // 用 .invalid 域名，绝不触碰真实端点的记录。
        let endpoint = try StorageEndpoint(kind: .smb, address: "smb://keychain-test.invalid/Share")
        defer { try? CredentialStore.delete(for: endpoint) }

        XCTAssertNil(try CredentialStore.load(for: endpoint), "测试前不应存在记录")

        let credentials = StorageCredentials(user: "tester", password: "p@ss:word/含中文", allowInsecureTLS: true)
        try CredentialStore.save(credentials, for: endpoint)
        XCTAssertEqual(try CredentialStore.load(for: endpoint), credentials)

        // 覆盖写：同一位置只应有一条记录
        let updated = StorageCredentials(user: "tester2", password: "new", allowInsecureTLS: false)
        try CredentialStore.save(updated, for: endpoint)
        XCTAssertEqual(try CredentialStore.load(for: endpoint), updated)

        try CredentialStore.delete(for: endpoint)
        XCTAssertNil(try CredentialStore.load(for: endpoint))
    }

    func testCredentialStoreTreatsEquivalentAddressesAsSameRecord() throws {
        // 同一位置的两种写法必须落到同一条记录，否则用户会遇到
        // "改了密码但另一个任务还在用旧的"。
        let a = try StorageEndpoint(kind: .smb, address: "smb://keychain-eq.invalid/Share")
        let b = try StorageEndpoint(kind: .smb, address: "keychain-eq.invalid/Share/")
        defer {
            try? CredentialStore.delete(for: a)
            try? CredentialStore.delete(for: b)
        }
        try CredentialStore.save(StorageCredentials(user: "u", password: "p"), for: a)
        XCTAssertEqual(try CredentialStore.load(for: b)?.user, "u")
    }

    // MARK: - 日期与状态码解析

    func testHTTPDateParsing() {
        let date = WebDAVMultiStatusParser.parseHTTPDate("Wed, 21 Oct 2015 07:28:00 GMT")
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        XCTAssertEqual(calendar.component(.year, from: date!), 2015)
        XCTAssertEqual(calendar.component(.hour, from: date!), 7)
    }

    func testHTTPDateParsingRejectsGarbage() {
        XCTAssertNil(WebDAVMultiStatusParser.parseHTTPDate("not a date"))
        XCTAssertNil(WebDAVMultiStatusParser.parseHTTPDate(""))
    }

    func testStatusLineCodeExtraction() {
        XCTAssertEqual(WebDAVMultiStatusParser.statusCode(from: "HTTP/1.1 200 OK"), 200)
        XCTAssertEqual(WebDAVMultiStatusParser.statusCode(from: "HTTP/1.1 423 Locked"), 423)
        XCTAssertEqual(WebDAVMultiStatusParser.statusCode(from: "HTTP/2 404 Not Found"), 404)
        XCTAssertNil(WebDAVMultiStatusParser.statusCode(from: "garbage"))
    }
}
