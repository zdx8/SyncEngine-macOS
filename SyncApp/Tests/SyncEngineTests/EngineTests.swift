import Foundation
import XCTest

@testable import SyncEngine

/// 引擎单元测试。
///
/// 测试用例的取舍原则：**断言要验结构性不变量，而不是机器相关的具体数值**。
/// "遍历耗时应该小于 500 ms" 这类断言在不同机器与负载下会随机失败；
/// "遍历耗时不得超过总耗时" 则任何情况下都必须成立，且真的能抓住 bug。
final class EngineTests: XCTestCase {

    // MARK: - 夹具

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int) throws -> URL {
        let url = tempRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0x5A, count: bytes)
        try data.write(to: url)
        return url
    }

    // MARK: - 哈希正确性

    /// NIST 公布的标准测试向量。
    ///
    /// 用官方向量而不是自算的常量：自算只能证明"实现没变过"，
    /// 证明不了"实现是对的"。
    func testSHA256KnownVectors() {
        XCTAssertEqual(
            ContentHasher.sha256(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ContentHasher.sha256(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEmptyFileHashesLikeEmptyInput() throws {
        let url = try write("empty.bin", bytes: 0)
        XCTAssertEqual(
            try ContentHasher.sha256(ofFileAt: url.path),
            ContentHasher.sha256(of: Data())
        )
    }

    /// 流式分块读取必须与一次性计算得到相同结果。
    ///
    /// 刻意让文件跨越多个读取缓冲区，并留下一个不满的尾块 ——
    /// 分块逻辑若在边界处少读或多读一个字节，只有这个尺寸能测出来；
    /// 几百字节的小文件会"碰巧正确"。
    func testChunkedFileHashMatchesOneShot() throws {
        let byteCount = ContentHasher.chunkSize * 2 + 12_345
        let url = tempRoot.appendingPathComponent("large.bin")
        var data = Data(count: byteCount)
        for index in 0..<byteCount {
            data[index] = UInt8(index % 251)
        }
        try data.write(to: url)

        XCTAssertEqual(try ContentHasher.sha256(ofFileAt: url.path),
                       ContentHasher.sha256(of: data))
    }

    // MARK: - 扫描统计

    func testScanReportsFullCountsButCapsEntries() async throws {
        for index in 0..<10 {
            try write("f\(index).txt", bytes: 10 + index)
        }
        try write("sub/deep.txt", bytes: 100)

        let result = try await SyncEngine.scan(
            root: tempRoot.path,
            options: ScanOptions(computeHash: true, maxEntries: 3)
        )

        XCTAssertEqual(result.fileCount, 11, "统计必须是全量，不受 maxEntries 影响")
        XCTAssertEqual(result.entries.count, 3, "条目受 maxEntries 限制")
        XCTAssertEqual(result.hashedCount, 11, "哈希必须覆盖全部文件")
        XCTAssertTrue(result.truncated)
    }

    func testScanCountsBytesExactly() async throws {
        try write("a", bytes: 5)
        try write("b", bytes: 3)
        try write("nested/c", bytes: 2)

        let result = try await SyncEngine.scan(
            root: tempRoot.path,
            options: ScanOptions(computeHash: false, maxEntries: 100)
        )

        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.totalBytes, 10)
        XCTAssertEqual(result.directoryCount, 2, "根目录 + nested")
        XCTAssertEqual(result.hashedCount, 0, "关闭哈希时不应产生任何摘要")
        XCTAssertTrue(result.entries.allSatisfy { $0.contentHash == nil })
        XCTAssertFalse(result.truncated)
    }

    func testEntriesAreSortedBySizeDescending() async throws {
        try write("small.bin", bytes: 10)
        try write("large.bin", bytes: 5_000)
        try write("medium.bin", bytes: 500)

        let result = try await SyncEngine.scan(
            root: tempRoot.path, options: ScanOptions(maxEntries: 100))

        let sizes = result.entries.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "条目应按体积降序")
    }

    /// 软链接必须被跳过且计入 `symlinksSkipped`。
    ///
    /// 跟随软链会带来两个后果：目录环导致遍历不终止；
    /// 同一份内容被重复计入，使"总大小"失真。后者不会报错，只是数字悄悄变错，
    /// 所以必须有断言守住。
    func testScanSkipsSymlinks() async throws {
        let target = try write("real.txt", bytes: 42)
        let link = tempRoot.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: target.path)

        let result = try await SyncEngine.scan(
            root: tempRoot.path, options: ScanOptions(maxEntries: 100))

        XCTAssertEqual(result.fileCount, 1, "只应统计真实文件")
        XCTAssertEqual(result.symlinksSkipped, 1)
        XCTAssertEqual(result.totalBytes, 42)
    }

    /// 指向目录的软链接同样不能跟随。
    ///
    /// 这条单独测，是因为「先判 isSymbolicLink 再判 isDirectory」的顺序很容易写反：
    /// `isDirectory` 会跟随链接，对指向目录的软链返回 true，
    /// 顺序写反就会把整个链接目录当作真实目录展开，而普通文件的用例测不出来。
    func testScanDoesNotFollowDirectorySymlinks() async throws {
        try write("realDir/inner.txt", bytes: 7)
        let link = tempRoot.appendingPathComponent("linkedDir")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: tempRoot.appendingPathComponent("realDir").path)

        let result = try await SyncEngine.scan(
            root: tempRoot.path, options: ScanOptions(maxEntries: 100))

        XCTAssertEqual(result.fileCount, 1, "软链目录不应被展开")
        XCTAssertEqual(result.symlinksSkipped, 1)
    }

    // MARK: - 计时不变量

    /// 分项耗时之和不得超过总耗时。
    ///
    /// 这是**结构性不变量**，不随机器快慢与负载变化，因此不会变成 flaky 测试。
    /// 它抓到的是"计时器被重复累加"这类实现错误 ——
    /// 前期在另一版引擎上真实踩到过：在循环里反复累加累计时长，
    /// 把 37 秒的总耗时记成了「30 分 35 秒遍历」。
    func testTimingComponentsNeverExceedElapsed() async throws {
        for index in 0..<300 {
            try write("f\(String(format: "%03d", index)).bin", bytes: 512 + index)
        }

        let result = try await SyncEngine.scan(
            root: tempRoot.path, options: ScanOptions(maxEntries: 50))

        XCTAssertLessThanOrEqual(result.walkSeconds, result.elapsedSeconds,
                                 "遍历耗时不应超过总耗时")
        XCTAssertLessThanOrEqual(result.hashSeconds, result.elapsedSeconds,
                                 "哈希耗时不应超过总耗时")
        XCTAssertLessThanOrEqual(
            result.walkSeconds + result.hashSeconds,
            result.elapsedSeconds + 0.005,
            "分项之和不应明显超过总耗时（容差 5 ms 用于吸收计时开销）"
        )
    }

    // MARK: - 错误路径

    func testScanThrowsForMissingPath() async {
        let missing = tempRoot.appendingPathComponent("does-not-exist").path
        do {
            _ = try await SyncEngine.scan(root: missing)
            XCTFail("不存在的路径应当抛错")
        } catch let error as SyncEngineError {
            guard case .pathDoesNotExist = error else {
                return XCTFail("期望 pathDoesNotExist，实际 \(error)")
            }
        } catch {
            XCTFail("期望 SyncEngineError，实际 \(error)")
        }
    }

    /// 传入文件而非目录时，必须明确报「不是目录」，
    /// 而不是返回一个空结果 —— 后者会被误读成"这个目录是空的"。
    func testScanThrowsForFileNotDirectory() async throws {
        let file = try write("plain.txt", bytes: 3)
        do {
            _ = try await SyncEngine.scan(root: file.path)
            XCTFail("文件路径应当抛错")
        } catch let error as SyncEngineError {
            guard case .notADirectory = error else {
                return XCTFail("期望 notADirectory，实际 \(error)")
            }
        }
    }

    // MARK: - 引擎自述

    func testScanFollowsSymlinkedRoot() async throws {
        // 用户把同步基点设成一个软链是完全正常的事：访达里的别名、
        // `/tmp`、`/var`、`/Volumes` 下的链接都算。
        //
        // 回归背景：Foundation 的 URL 版目录枚举**不跟随末端软链**
        // （对指向目录的软链抛 NSFileReadUnknownError(256)，而 opendir(3) 正常），
        // 于是扫描软链根目录会返回"成功 + 0 个文件"这种静默的空结果。
        let real = tempRoot.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "a".write(to: real.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: real.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let link = tempRoot.appendingPathComponent("link-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let result = try await SyncEngine.scan(
            root: link.path, options: ScanOptions(computeHash: false))

        XCTAssertEqual(result.fileCount, 2, "根是软链时必须跟随，否则会静默返回 0 个文件")
        XCTAssertEqual(result.readErrors, 0, "不该产生读取错误")
        XCTAssertTrue(
            result.entries.allSatisfy { !$0.relativePath.hasPrefix("/") },
            "相对路径必须是相对的，不能因为基准不一致而退化成绝对路径"
        )
    }

    func testEngineInfoReportsHostPlatform() {
        let info = SyncEngine.info(hashConcurrency: 4)
        XCTAssertTrue(info.platform.contains("macOS"), "应报告宿主平台，实际 \(info.platform)")
        XCTAssertEqual(info.hashConcurrency, 4)
        XCTAssertTrue(info.hashAlgorithm.contains("SHA-256"))
    }

    func testDefaultConcurrencyIsPositive() {
        XCTAssertGreaterThan(SyncEngine.defaultConcurrency, 0)
    }
}
