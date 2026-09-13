import Foundation
import Security

/// Keychain 凭据存储。
///
/// ## 为什么必须用 Keychain，而不是自己写个加密文件
///
/// 自己实现"加密存密码"必然要解决密钥放哪 —— 放代码里等于没加密，
/// 放另一个文件里只是把问题往后挪一步。Keychain 是系统提供的、
/// 密钥由 Secure Enclave / 系统钥匙串守护、且访问受代码签名约束的存储。
/// 这个项目从第一天就用它，是因为凭据一旦落到 UserDefaults 或 plist，
/// 后面再改就要处理"用户已经存过的明文密码"这个迁移问题。
///
/// ## 一个端点一条记录
///
/// 记录以 `种类 + 规范化地址` 为键，值里整体带上用户名、密码、
/// 证书策略。这样"这个位置用什么账号连"只有一个答案，
/// 不会出现界面上显示 A 账号、实际用 B 账号连的错位。
public enum CredentialStore {

    /// Keychain 条目的服务名。带 bundle id 前缀，避免与其他应用冲突。
    private static let service = "com.syncengine.desktop.credentials"

    public enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus, String)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status, let operation):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "钥匙串\(operation)失败（\(status)：\(detail)）"
            }
        }
    }

    /// 端点对应的 Keychain 账户名。
    ///
    /// 用规范化后的 `种类|地址`：同一个共享无论用户写成 `smb://nas/Share`
    /// 还是 `nas/Share`，都会落到同一条记录上。
    /// **不含子目录** —— 子目录只是共享内的位置，不影响认证。
    static func account(for endpoint: StorageEndpoint) -> String {
        "\(endpoint.kind.rawValue)|\(endpoint.address)"
    }

    private static func baseQuery(for endpoint: StorageEndpoint) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: endpoint),
        ]
    }

    // MARK: 读

    public static func load(for endpoint: StorageEndpoint) throws -> StorageCredentials? {
        var query = baseQuery(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(StorageCredentials.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status, "读取")
        }
    }

    // MARK: 写

    /// 保存凭据。已存在则整体替换。
    ///
    /// 用"先尝试更新、失败再新增"而不是"先删后加"：
    /// 后者在两次调用之间崩溃会留下"凭据没了"的状态，
    /// 用户会莫名其妙地连不上。
    public static func save(_ credentials: StorageCredentials, for endpoint: StorageEndpoint) throws {
        let payload = try JSONEncoder().encode(credentials)
        let query = baseQuery(for: endpoint)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: payload] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }

        if updateStatus != errSecItemNotFound {
            throw StoreError.unexpectedStatus(updateStatus, "更新")
        }

        var insert = query
        insert[kSecValueData as String] = payload
        // 只在设备解锁后可读：同步任务不需要在锁屏状态下访问凭据。
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.unexpectedStatus(addStatus, "写入")
        }
    }

    // MARK: 删

    public static func delete(for endpoint: StorageEndpoint) throws {
        let status = SecItemDelete(baseQuery(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status, "删除")
        }
    }
}
