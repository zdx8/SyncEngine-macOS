import CryptoKit
import Foundation

/// 内容哈希。
///
/// ## 为什么是 SHA-256 而不是 BLAKE3
///
/// 转向前用的是 BLAKE3，当时的理由是「速度 + 强度 + 分块」。
/// 但那个选择是在**跨五端**的前提下做的——Rust 侧能方便地引入 BLAKE3 实现。
///
/// 平台收敛到 macOS、引擎改写为 Swift 后，权衡变了：
///
/// - CryptoKit 的 SHA-256 在 Apple Silicon 上**有硬件加速**，
///   吞吐高于任何纯软件的 BLAKE3 实现
/// - 它是系统实现，**不需要引入任何第三方代码**——少一个依赖、少一处维护风险
/// - 对「内容指纹」这一用途，SHA-256 的强度完全够用：
///   这里不存在长度扩展攻击的场景（不是 MAC，不是签名）
///
/// 代价是索引中的哈希格式变了。当前尚无已持久化的索引数据，无迁移负担。
///
/// ## 必须流式，不能整文件读入
///
/// 同步对象可能是数十 GB 的磁盘映像。整文件读入内存会直接把应用拖垮，
/// 而这恰恰是最需要被同步的那类文件。
public enum ContentHasher {

    /// 读取缓冲区大小。
    ///
    /// 64 KiB 是吞吐与内存占用的折中：更小会因系统调用次数拖慢大文件，
    /// 更大对小文件无益、只会抬高峰值占用。
    /// 注意真正决定小文件场景吞吐的是**每个文件一次 open/read/close 的开销**，
    /// 不是这个值。
    public static let chunkSize = 64 * 1024

    /// 计算文件的 SHA-256，返回 64 字符小写十六进制。
    ///
    /// 流式读取：内存占用与文件大小无关，恒定在一个缓冲区。
    public static func sha256(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            // read(upToCount:) 返回 nil 或空 Data 表示到达末尾
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    /// 计算一段内存的 SHA-256。
    ///
    /// 用于引擎自检：把结果与已知向量比对，可一次性验证
    /// 「哈希实现 + 调用路径」都正确。
    public static func sha256(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// `SHA256.Digest` → 小写十六进制字符串。
    ///
    /// 用 `String(format: "%02x")` 而不是自定义查表：前者语义明确、
    /// 且不依赖调用方传入正确的宽度。
    static func hexString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
