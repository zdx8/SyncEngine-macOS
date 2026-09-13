import Foundation
import XCTest

@testable import SyncEngine

/// WebDAV 驱动的端到端测试。
///
/// **这些测试真的走 HTTP。** 服务端是本机进程内的 `MiniWebDAVServer`，
/// 后端是真实磁盘。所以它们能抓住协议层面的错误（尾斜杠、207 与 propstat
/// 分组、href 的百分号编码、认证往返），而这些恰恰是 mock 测试永远抓不到的。
final class WebDAVDriverTests: XCTestCase {

    private var scratch: URL!
    private var serverRoot: URL!
    private var server: MiniWebDAVServer!
    private var secondary: MiniWebDAVServer?

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-webdav-tests-\(UUID().uuidString)")
        scratch = base.appendingPathComponent("scratch")
        serverRoot = base.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverRoot, withIntermediateDirectories: true)

        server = try MiniWebDAVServer(root: serverRoot)
        try await server.start()
    }

    override func tearDown() async throws {
        server?.stop()
        secondary?.stop()
        secondary = nil
        if let scratch, let url = scratch.deletingLastPathComponent().path as String? {
            try? FileManager.default.removeItem(atPath: url)
        }
        try await super.tearDown()
    }

    // MARK: 夹具

    private func makeDriver(
        credentials: StorageCredentials = StorageCredentials(user: "tester", password: "secret"),
        subpath: String = "",
        port: UInt16? = nil,
        requireAuth: Bool = true
    ) throws -> (any StorageDriver, MiniWebDAVServer) {
        let target = port == nil ? server! : secondary!
        let endpoint = try StorageEndpoint(
            kind: .webdav,
            address: "http://127.0.0.1:\(target.port)/dav",
            subpath: subpath
        )
        return (WebDAVDriver(endpoint: endpoint, credentials: credentials), target)
    }

    private func writeLocalFile(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    /// 含二进制、中文与换行的负载 —— 单纯文本会让编码问题隐形。
    private var trickyPayload: [UInt8] {
        var bytes = Array("同步工具 · UTF-8 内容校验\n".utf8)
        bytes.append(contentsOf: (0..<256).map { UInt8($0) })
        return bytes
    }

    // MARK: 连接探测

    func testProbeAgainstRealServer() async throws {
        let (driver, _) = try makeDriver()
        let probe = try await driver.probe()

        XCTAssertEqual(probe.kind, .webdav)
        XCTAssertEqual(probe.rootEntryCount, 0, "空目录应报告 0 个条目")
        XCTAssertEqual(probe.isWritable, true, "服务端声明了 write 权限，应判定为可写")
        XCTAssertEqual(probe.fileSystemType, nil, "WebDAV 没有本地文件系统类型")
        XCTAssertNotNil(probe.serverInfo)
        XCTAssertTrue(
            probe.serverInfo?.contains("MiniWebDAV") == true,
            "应读到服务端标识，实际：\(probe.serverInfo ?? "nil")"
        )
        XCTAssertTrue(probe.resolvedLocation.hasSuffix("/dav/"),
                      "集合的 URL 必须以斜杠结尾，实际：\(probe.resolvedLocation)")
    }

    func testProbeWithWrongCredentialsReportsUnauthorized() async throws {
        let (driver, _) = try makeDriver(
            credentials: StorageCredentials(user: "tester", password: "wrong-password"))
        do {
            _ = try await driver.probe()
            XCTFail("错误密码必须报错")
        } catch let error as StorageDriverError {
            guard case .unauthorized = error else {
                return XCTFail("应报 unauthorized，实际：\(error)")
            }
        }
    }

    func testAnonymousProbeWorksWhenServerAllowsGuest() async throws {
        // 另起一个不需要认证的服务端，验证"访客访问"这条路径。
        let guestRoot = scratch.appendingPathComponent("guest-server")
        try FileManager.default.createDirectory(at: guestRoot, withIntermediateDirectories: true)
        var configuration = MiniWebDAVServer.Configuration()
        configuration.requireAuth = false
        let guest = try MiniWebDAVServer(root: guestRoot, configuration: configuration)
        try await guest.start()
        secondary = guest

        let endpoint = try StorageEndpoint(
            kind: .webdav, address: "http://127.0.0.1:\(guest.port)/dav")
        let driver = WebDAVDriver(endpoint: endpoint, credentials: .anonymous)

        let probe = try await driver.probe()
        XCTAssertEqual(probe.rootEntryCount, 0)
        XCTAssertTrue(guest.handledMethods.contains("PROPFIND"))
    }

    func testProbeOnMissingCollectionReportsNotFound() async throws {
        let (driver, _) = try makeDriver(subpath: "does-not-exist")
        do {
            _ = try await driver.probe()
            XCTFail("不存在的集合应当报错")
        } catch let error as StorageDriverError {
            guard case .notFound = error else {
                return XCTFail("应报 notFound，实际：\(error)")
            }
        }
    }

    // MARK: 建目录与列目录

    func testMakeDirectoryCreatesNestedCollections() async throws {
        let (driver, server) = try makeDriver()
        // MKCOL 不像 mkdir -p，父集合不存在会直接失败 —— 驱动必须逐级创建。
        try await driver.makeDirectory(relativePath: "a/b/c")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: serverRoot.appendingPathComponent("a/b/c").path))
        XCTAssertTrue(server.handledMethods.contains("MKCOL"))

        let entries = try await driver.list(relativePath: "a")
        XCTAssertEqual(entries.map(\.name), ["b"])
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testMakeDirectoryIsIdempotent() async throws {
        let (driver, _) = try makeDriver()
        try await driver.makeDirectory(relativePath: "once")
        // 已存在必须视为成功（服务端会回 405），否则重跑同步会直接失败。
        try await driver.makeDirectory(relativePath: "once")
    }

    func testListReportsChildrenWithTypesAndSizes() async throws {
        let (driver, _) = try makeDriver()
        try await driver.makeDirectory(relativePath: "dir")
        let payload = trickyPayload
        let local = try writeLocalFile("listed.bin", bytes: payload)
        try await driver.upload(from: local, to: "listed.bin")

        let entries = try await driver.list(relativePath: "")
        XCTAssertEqual(entries.count, 2, "应恰好看到目录与文件各一，实际：\(entries.map(\.name))")

        // 目录在前
        XCTAssertEqual(entries[0].name, "dir")
        XCTAssertTrue(entries[0].isDirectory)

        XCTAssertEqual(entries[1].name, "listed.bin")
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].size, Int64(payload.count), "文件大小必须与服务端一致")
        XCTAssertNotNil(entries[1].modified, "服务端给了 getlastmodified，应能解析出时间")

        // 关键：集合自身不能被列进自己的子项里，否则条目数永远多 1。
        XCTAssertFalse(entries.contains { $0.name.isEmpty || $0.name == "dav" })
    }

    // MARK: 上传下载往返

    func testUploadDownloadRoundTripPreservesBytes() async throws {
        let (driver, server) = try makeDriver()
        let payload = trickyPayload
        let local = try writeLocalFile("round-trip.bin", bytes: payload)

        try await driver.upload(from: local, to: "nested/deep/round-trip.bin")

        // 父集合同样应被自动创建 —— 与本地驱动的行为保持一致。
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: serverRoot.appendingPathComponent("nested/deep/round-trip.bin").path))
        XCTAssertTrue(server.handledMethods.contains("PUT"))

        let restored = scratch.appendingPathComponent("restored.bin")
        try await driver.download(relativePath: "nested/deep/round-trip.bin", to: restored)

        // 用内容哈希而不是逐字节比较：把"字节是否一致"变成一个明确的结论。
        XCTAssertEqual(
            try ContentHasher.sha256(ofFileAt: restored.path),
            try ContentHasher.sha256(ofFileAt: local.path),
            "往返后哈希必须一致"
        )
        XCTAssertTrue(server.handledMethods.contains("GET"))
    }

    func testUploadOverwritesExistingFile() async throws {
        let (driver, _) = try makeDriver()
        let first = try writeLocalFile("v1.bin", bytes: Array("第一版".utf8))
        let second = try writeLocalFile("v2.bin", bytes: Array("第二版内容更长".utf8))

        try await driver.upload(from: first, to: "same.bin")
        try await driver.upload(from: second, to: "same.bin")

        let onServer = serverRoot.appendingPathComponent("same.bin")
        XCTAssertEqual(
            try Data(contentsOf: onServer),
            Data("第二版内容更长".utf8),
            "第二次上传必须覆盖第一次"
        )
    }

    func testDownloadMissingFileReportsNotFound() async throws {
        let (driver, _) = try makeDriver()
        do {
            try await driver.download(
                relativePath: "nope.bin", to: scratch.appendingPathComponent("x.bin"))
            XCTFail("下载不存在的文件必须报错")
        } catch let error as StorageDriverError {
            guard case .notFound = error else {
                return XCTFail("应报 notFound，实际：\(error)")
            }
        }
    }

    func testChineseAndSpaceFilenamesRoundTrip() async throws {
        // 文件名含中文与空格时，href 的百分号编码是必然出错的点，
        // 而且只有当文件名真的是中文时才会暴露。
        let (driver, _) = try makeDriver()
        let name = "报告 2026 年第 一 季度.bin"
        let payload = trickyPayload
        let local = try writeLocalFile("cn.bin", bytes: payload)

        try await driver.upload(from: local, to: name)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: serverRoot.appendingPathComponent(name).path),
            "服务端应收到与原始文件名一致的路径")

        let entries = try await driver.list(relativePath: "")
        XCTAssertEqual(entries.map(\.name), [name])

        let restored = scratch.appendingPathComponent("cn-restored.bin")
        try await driver.download(relativePath: name, to: restored)
        XCTAssertEqual(
            try ContentHasher.sha256(ofFileAt: restored.path),
            try ContentHasher.sha256(ofFileAt: local.path)
        )
    }

    // MARK: 删除

    func testRecursiveRemoveDeletesNestedContent() async throws {
        let (driver, server) = try makeDriver()
        try await driver.makeDirectory(relativePath: "tree/leaf")
        let local = try writeLocalFile("f.bin", bytes: trickyPayload)
        try await driver.upload(from: local, to: "tree/leaf/f.bin")
        try await driver.upload(from: local, to: "tree/top.bin")

        try await driver.remove(relativePath: "tree", recursive: true)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: serverRoot.appendingPathComponent("tree").path))
        XCTAssertTrue(server.handledMethods.contains("DELETE"))
    }

    func testNonRecursiveRemoveRefusesNonEmptyCollection() async throws {
        let (driver, _) = try makeDriver()
        try await driver.makeDirectory(relativePath: "keep")
        let local = try writeLocalFile("k.bin", bytes: trickyPayload)
        try await driver.upload(from: local, to: "keep/k.bin")

        do {
            try await driver.remove(relativePath: "keep", recursive: false)
            XCTFail("非空集合的非递归删除必须报错")
        } catch {
            // 报错时内容必须原样还在 —— 静默递归删除是数据丢失最常见的形式。
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: serverRoot.appendingPathComponent("keep/k.bin").path),
                "报错时绝不能已经删掉内容"
            )
        }
    }

    func testRemoveIsIdempotentForMissingPath() async throws {
        let (driver, _) = try makeDriver()
        // 已经不存在时删除应当成功，否则断点重跑会持续失败。
        try await driver.remove(relativePath: "never-existed", recursive: false)
    }

    func testRemoveRefusesRootItself() async throws {
        let (driver, _) = try makeDriver()
        do {
            try await driver.remove(relativePath: "", recursive: true)
            XCTFail("删除根集合必须被拒绝")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: serverRoot.path))
        }
    }

    // MARK: 子目录作为基准

    func testSubpathBecomesTheBaseLocation() async throws {
        try FileManager.default.createDirectory(
            at: serverRoot.appendingPathComponent("scope/inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: serverRoot.appendingPathComponent("outside.txt"))

        let (driver, _) = try makeDriver(subpath: "scope/inner")
        let probe = try await driver.probe()
        XCTAssertEqual(probe.rootEntryCount, 0, "基准目录是 inner，不该看到外面的内容")

        let local = try writeLocalFile("in.bin", bytes: trickyPayload)
        try await driver.upload(from: local, to: "in.bin")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: serverRoot.appendingPathComponent("scope/inner/in.bin").path))
    }

    // MARK: 协议正确性

    func testDriverUsesExpectedHTTPVerbs() async throws {
        let (driver, server) = try makeDriver()
        try await driver.makeDirectory(relativePath: "d")
        let local = try writeLocalFile("v.bin", bytes: trickyPayload)
        try await driver.upload(from: local, to: "d/v.bin")
        _ = try await driver.list(relativePath: "d")
        try await driver.remove(relativePath: "d/v.bin", recursive: false)

        let methods = Set(server.handledMethods)
        XCTAssertTrue(methods.contains("MKCOL"), "建目录必须用 MKCOL")
        XCTAssertTrue(methods.contains("PUT"), "上传必须用 PUT")
        XCTAssertTrue(methods.contains("PROPFIND"), "列目录必须用 PROPFIND")
        XCTAssertTrue(methods.contains("DELETE"), "删除必须用 DELETE")
        XCTAssertFalse(methods.contains("POST"), "不该出现 POST —— 那不是 WebDAV 的动词")
    }

    // MARK: 解析器（命名空间无关性）

    func testParserHandlesUppercasePrefix() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/dav/</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let responses = try WebDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses.count, 1)
        XCTAssertTrue(responses[0].isCollection)
        XCTAssertEqual(responses[0].href, "/dav/")
    }

    func testParserHandlesDefaultNamespaceWithoutPrefix() throws {
        // 默认命名空间写法下元素名没有前缀。按 `d:xxx` 硬匹配的解析器会全军覆没。
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:">
        <response>
          <href>/dav/</href>
          <propstat>
            <prop><resourcetype><collection/></resourcetype></prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        <response>
          <href>/dav/a.txt</href>
          <propstat>
            <prop><resourcetype/><getcontentlength>5</getcontentlength></prop>
            <status>HTTP/1.1 200 OK</status>
          </propstat>
        </response>
        </multistatus>
        """
        let responses = try WebDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses.count, 2)
        XCTAssertTrue(responses[0].isCollection)
        XCTAssertFalse(responses[1].isCollection)
        XCTAssertEqual(responses[1].contentLength, 5)
    }

    func testParserIgnoresFailedPropstatBranch() throws {
        // `<status>` 出现在 `<prop>` 之后，所以必须先把属性攒起来再按 status 决定取舍。
        // 边读边写会让失败分支的空值覆盖成功分支的真实值 —— 表现为"文件大小全是 0"。
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:href>/dav/b.txt</D:href>
          <D:propstat>
            <D:prop><D:getcontentlength>7</D:getcontentlength></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
          <D:propstat>
            <D:prop><D:getetag/></D:prop>
            <D:status>HTTP/1.1 404 Not Found</D:status>
          </D:propstat>
        </D:response>
        </D:multistatus>
        """
        let responses = try WebDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0].contentLength, 7, "成功分支的大小不能被失败分支覆盖")
    }

    func testParserReadsPrivileges() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
        <D:response>
          <D:href>/dav/</D:href>
          <D:propstat>
            <D:prop>
              <D:current-user-privilege-set>
                <D:privilege><D:read/></D:privilege>
                <D:privilege><D:write-content/></D:privilege>
              </D:current-user-privilege-set>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        </D:multistatus>
        """
        let responses = try WebDAVMultiStatusParser.parse(Data(xml.utf8))
        XCTAssertEqual(responses[0].privileges, ["read", "write-content"])
    }

    func testParserThrowsOnMalformedXML() {
        XCTAssertThrowsError(
            try WebDAVMultiStatusParser.parse(Data("<multistatus><response".utf8))
        ) { error in
            guard case StorageDriverError.malformedResponse = error else {
                return XCTFail("应报 malformedResponse，实际：\(error)")
            }
        }
    }
}
