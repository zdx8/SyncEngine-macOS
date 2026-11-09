import Foundation

/// 跨并发域传递值的安全盒子。
///
/// 为什么需要它：在 `Task` 里给外部作用域的 `var` 赋值，会被 Swift 判为
/// 「并发可变捕获」（`mutation of captured var in concurrently-executing code`），
/// 因为编译器无法证明访问是串行的。
///
/// 用一个内部由 `NSLock` 保护的引用类型承接，语义上就把这件事说清楚了：
/// 值的读写是加锁的，因此 `@unchecked Sendable` 是安全的
/// （`@unchecked` 表示"我为此负责"，正因如此必须真的加锁，不能只是贴个标签绕过检查）。
final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
