import Foundation

/// WebDAV 驱动。
///
/// ## 为什么 WebDAV 可以零依赖实现
///
/// WebDAV 就是在 HTTP 上加了几个自定义方法（PROPFIND / MKCOL / PUT / GET /
/// DELETE / OPTIONS），而 `URLSession` 允许任意 `httpMethod`。因此不需要任何
/// 第三方库 —— 只需要正确地构造请求、并解析 PROPFIND 的 XML 响应。
///
/// 这一点值得强调：很多同类工具会引入一个 WebDAV 客户端库，实际换来的只是
/// 这几百行代码，却要长期承担供应链风险（见技术方案 2.3）。
///
/// ## 认证
///
/// 两条路并行：
///   * **预先发送 Basic**：省掉一次 401 往返。若服务端其实要 Digest，
///     它会忽略这个头并回 401，我们照样能靠 challenge 流程走通。
///   * **challenge 回调**：处理 Digest / NTLM / 自签名证书。
/// 少任何一条都会在某些 NAS 上装不上。
public struct WebDAVDriver: StorageDriver {

    public let endpoint: StorageEndpoint
    public let credentials: StorageCredentials

    public init(endpoint: StorageEndpoint, credentials: StorageCredentials) {
        self.endpoint = endpoint
        self.credentials = credentials
    }

    // ── 会话：全局共享

    /// 共享一个 URLSession，而不是每次操作新建。
    ///
    /// 每个 `URLSession` 都会带来一条常驻线程与一套连接池；按操作新建会在
    /// 批量同步时迅速堆出几百条线程。凭据不放在会话上，而是**每次请求**通过
    /// `delegate:` 传给对应的 task —— 因为同一个应用里可能有多个 WebDAV 任务，
    /// 各自用不同的账号。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // 资源级超时放宽到 1 小时：大文件上传可能很慢，
        // 用请求级超时会把正常的慢速传输当成失败。
        configuration.timeoutIntervalForResource = 3600
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private var authDelegate: WebDAVAuthentication {
        WebDAVAuthentication(credentials: credentials)
    }

    // ── URL 构造

    var baseURL: URL? {
        var text = endpoint.address
        if !endpoint.subpath.isEmpty { text += "/" + endpoint.subpath }
        // 含中文的地址：`URL(string:)` 会直接返回 nil，必须先百分号编码。
        // 但已编码过的地址不能被二次编码（会变成 %25E5…），所以先试原样。
        if let url = URL(string: text) { return url }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: escaped)
    }

    /// 拼出某个相对路径对应的 URL。
    ///
    /// - Parameter asCollection: 目录必须以 `/` 结尾。**这不是风格问题** ——
    ///   很多服务端用尾斜杠区分"集合"与"成员"，少了它 MKCOL 会建出一个
    ///   同名文件，或者 PROPFIND 返回单条而非子项列表。
    func url(for relativePath: String, asCollection: Bool) -> URL? {
        guard var url = baseURL else { return nil }
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        if asCollection && !url.absoluteString.hasSuffix("/") {
            url.appendPathComponent("")
        }
        return url
    }

    // ── 请求构造

    private func makeRequest(
        method: String,
        url: URL,
        depth: Int? = nil,
        contentType: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let depth { request.setValue("\(depth)", forHTTPHeaderField: "Depth") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        // 预先发送 Basic，省掉一次 401 往返。
        // 明文 HTTP 下密码确实会以 base64 传输 —— 但那本来就会发生
        // （401 后的重试同样如此），所以这不引入新的暴露面。
        if !credentials.isAnonymous, let header = basicAuthHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func basicAuthHeader() -> String? {
        let raw = "\(credentials.user):\(credentials.password)"
        guard let data = raw.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // ── 请求执行
    //
    // 三种调用（普通 / 上传 / 下载）都先过这里，统一把 URLSession 的错误
    // 翻译成可读的 StorageDriverError。集中在一处的理由很实际：
    // 散落各处的 `catch` 里迟早会漏掉某一处，于是同一个原因在不同操作上
    // 给出不同的报错，用户无法据此判断该改什么。

    private func perform(
        _ request: URLRequest, method: String, url: URL
    ) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request, delegate: authDelegate)
        } catch {
            throw Self.translate(error, method: method, url: url)
        }
    }

    private func performUpload(
        _ request: URLRequest, fromFile fileURL: URL, method: String, url: URL
    ) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.upload(
                for: request, fromFile: fileURL, delegate: authDelegate
            )
        } catch {
            throw Self.translate(error, method: method, url: url)
        }
    }

    private func performDownload(
        _ request: URLRequest, method: String, url: URL
    ) async throws -> (URL, URLResponse) {
        do {
            return try await Self.session.download(for: request, delegate: authDelegate)
        } catch {
            throw Self.translate(error, method: method, url: url)
        }
    }

    /// 把 `URLError` 翻译成能指导行动的错误。
    ///
    /// 特别是证书这一族：WebDAV 的默认对手是家里那台 NAS，
    /// 而 NAS 出厂就是自签名证书。只抛一个 `NSURLErrorServerCertificateUntrusted`
    /// 用户根本不知道下一步该干什么，所以这里直接把该开的开关点出来。
    static func translate(_ error: Error, method: String, url: URL) -> StorageDriverError {
        if let driverError = error as? StorageDriverError { return driverError }
        guard let urlError = error as? URLError else {
            return .underlying(error.localizedDescription)
        }
        let host = url.host ?? url.absoluteString
        switch urlError.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .secureConnectionFailed:
            return .underlying(
                "TLS 证书校验未通过（\(host)）。若这是 NAS 的自签名证书，"
                    + "请在任务设置里勾选「允许自签名证书」。"
            )
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .underlying("无法连接服务器：\(host)")
        case .timedOut:
            return .underlying("请求超时：\(method) \(url.absoluteString)")
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .unauthorized(host)
        case .appTransportSecurityRequiresSecureConnection:
            return .underlying(
                "明文 HTTP 被系统传输安全策略拦截：\(url.absoluteString)")
        case .cancelled:
            return .underlying("请求被取消：\(method) \(url.absoluteString)")
        default:
            return .underlying(
                "\(method) \(url.absoluteString) 失败：\(urlError.localizedDescription)")
        }
    }

    private static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
        <d:getetag/>
        <d:current-user-privilege-set/>
      </d:prop>
    </d:propfind>
    """.utf8)

    // ── 响应校验

    private func check(
        _ response: URLResponse,
        method: String,
        url: URL,
        body: Data?,
        accepting: Range<Int>
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StorageDriverError.malformedResponse("\(method) 未返回 HTTP 响应")
        }
        guard accepting.contains(http.statusCode) else {
            let detail = body.flatMap { String(data: $0.prefix(400), encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch http.statusCode {
            case 401, 403:
                throw StorageDriverError.unauthorized(url.host ?? url.absoluteString)
            case 404:
                throw StorageDriverError.notFound(url.path)
            case 405, 501:
                throw StorageDriverError.unsupported("服务端不支持 \(method)（HTTP \(http.statusCode)）")
            default:
                throw StorageDriverError.httpFailure(
                    method: method, status: http.statusCode, url: url.absoluteString, detail: detail
                )
            }
        }
    }

    // ── 列目录

    private func propfind(_ url: URL, depth: Int) async throws -> [WebDAVMultiStatusParser.Response] {
        var request = makeRequest(method: "PROPFIND", url: url, depth: depth)
        request.httpBody = Self.propfindBody
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await perform(request, method: "PROPFIND", url: url)
        // 207 是标准响应；少数老服务端对 depth:0 会回 200。
        try check(response, method: "PROPFIND", url: url, body: data, accepting: 200..<300)
        guard !data.isEmpty else { return [] }
        return try WebDAVMultiStatusParser.parse(data)
    }

    public func list(relativePath: String) async throws -> [RemoteEntry] {
        guard let url = url(for: relativePath, asCollection: true) else {
            throw StorageDriverError.notConfigured("无法构造 URL：\(endpoint.displayText)/\(relativePath)")
        }
        let responses = try await propfind(url, depth: 1)
        // 请求的集合自身也会出现在结果里，必须排除 ——
        // 否则界面上会看到"自己里面还有自己"，且条目数永远多 1。
        let selfPath = normalizedPath(url)

        var entries: [RemoteEntry] = []
        for response in responses {
            guard let hrefPath = normalizedPath(response.href, relativeTo: url) else { continue }
            if hrefPath == selfPath { continue }
            let name = (hrefPath as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            entries.append(
                RemoteEntry(
                    name: name,
                    relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                    isDirectory: response.isCollection,
                    size: response.contentLength ?? 0,
                    modified: response.modified
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    /// 把 URL 或 href 归一化成一个可比较的路径（已百分号解码、无尾斜杠）。
    private func normalizedPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.removingPercentEncoding ?? path
    }

    private func normalizedPath(_ href: String?, relativeTo base: URL) -> String? {
        guard let href, !href.isEmpty else { return nil }
        // href 可能是绝对 URL、绝对路径（/dav/x）或相对路径，三种都要能吃下。
        guard let url = URL(string: href, relativeTo: base) else { return nil }
        return normalizedPath(url)
    }

    // ── 建目录

    public func makeDirectory(relativePath: String) async throws {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }

        // 逐级创建：MKCOL 不像 `mkdir -p`，父集合不存在时直接失败。
        var accumulated: [String] = []
        for component in trimmed.split(separator: "/") {
            accumulated.append(String(component))
            let path = accumulated.joined(separator: "/")
            guard let url = url(for: path, asCollection: true) else {
                throw StorageDriverError.notConfigured(path)
            }
            let request = makeRequest(method: "MKCOL", url: url)
            let (data, response) = try await perform(request, method: "MKCOL", url: url)
            guard let http = response as? HTTPURLResponse else {
                throw StorageDriverError.malformedResponse("MKCOL 未返回 HTTP 响应")
            }
            switch http.statusCode {
            case 200..<300:
                continue
            case 405:
                // 405 = 已存在。这是幂等语义，不算失败。
                continue
            case 401, 403:
                throw StorageDriverError.unauthorized(url.host ?? url.absoluteString)
            case 409:
                throw StorageDriverError.notFound(url.path)
            default:
                let detail = String(data: data.prefix(300), encoding: .utf8)
                throw StorageDriverError.httpFailure(
                    method: "MKCOL", status: http.statusCode,
                    url: url.absoluteString, detail: detail
                )
            }
        }
    }

    /// 保证某条路径的父集合都存在。
    private func ensureCollections(for relativePath: String) async throws {
        let components = relativePath.split(separator: "/").dropLast()
        guard !components.isEmpty else { return }
        var accumulated: [String] = []
        for component in components {
            accumulated.append(String(component))
            try await makeDirectory(relativePath: accumulated.joined(separator: "/"))
        }
    }

    // ── 上传 / 下载

    public func upload(from localURL: URL, to relativePath: String) async throws {
        try await ensureCollections(for: relativePath)
        guard let url = url(for: relativePath, asCollection: false) else {
            throw StorageDriverError.notConfigured(relativePath)
        }
        var request = makeRequest(method: "PUT", url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // 用 fromFile 而不是把内容读进内存：同步工具要处理 GB 级文件，
        // 一次性载入会直接把内存打满。
        let (data, response) = try await performUpload(
            request, fromFile: localURL, method: "PUT", url: url
        )
        try check(response, method: "PUT", url: url, body: data, accepting: 200..<300)
    }

    public func download(relativePath: String, to localURL: URL) async throws {
        guard let url = url(for: relativePath, asCollection: false) else {
            throw StorageDriverError.notConfigured(relativePath)
        }
        let request = makeRequest(method: "GET", url: url)

        let (temporaryURL, response) = try await performDownload(request, method: "GET", url: url)
        do {
            try check(response, method: "GET", url: url, body: nil, accepting: 200..<300)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        // 下载完成后是系统给的临时文件，必须自己搬到目标位置并覆盖。
        // 直接 move 到已存在的目标会失败，所以先删。
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: localURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw StorageDriverError.underlying(error.localizedDescription)
        }
    }

    // ── 删除

    public func remove(relativePath: String, recursive: Bool) async throws {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw StorageDriverError.unsupported("拒绝删除目标根集合本身")
        }

        // 自己递归，而不是指望服务端的 DELETE 能删非空集合。
        // RFC 4918 明确允许服务端对非空集合返回 409/423 ——
        // 依赖它"应该能删"会在不同 NAS 上表现不一致。
        if recursive {
            let entries = (try? await list(relativePath: trimmed)) ?? []
            for entry in entries {
                try await remove(relativePath: entry.relativePath, recursive: true)
            }
        } else {
            let entries = (try? await list(relativePath: trimmed)) ?? []
            guard entries.isEmpty else {
                throw StorageDriverError.unsupported(
                    "\(trimmed) 是非空集合，递归删除未被允许（共 \(entries.count) 项）"
                )
            }
        }

        guard let url = url(for: trimmed, asCollection: false) else {
            throw StorageDriverError.notConfigured(trimmed)
        }
        let request = makeRequest(method: "DELETE", url: url)
        let (data, response) = try await perform(request, method: "DELETE", url: url)

        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return  // 已经不存在，幂等
        }
        try check(response, method: "DELETE", url: url, body: data, accepting: 200..<300)
    }

    // ── 连接探测

    public func probe() async throws -> StorageProbe {
        let clock = MonotonicStopwatch()
        var notes: [String] = []

        guard let base = url(for: "", asCollection: true) else {
            throw StorageDriverError.notConfigured(endpoint.displayText)
        }

        // OPTIONS 拿服务端能力。失败不算致命：部分服务端禁用了 OPTIONS，
        // 而 PROPFIND 才是真正必需的。所以这里只作为补充信息。
        var serverInfo: String?
        do {
            let request = makeRequest(method: "OPTIONS", url: base)
            let (_, response) = try await perform(request, method: "OPTIONS", url: base)
            if let http = response as? HTTPURLResponse {
                var parts: [String] = []
                if let server = http.value(forHTTPHeaderField: "Server") { parts.append(server) }
                if let dav = http.value(forHTTPHeaderField: "DAV") { parts.append("DAV: \(dav)") }
                if let allow = http.value(forHTTPHeaderField: "Allow") {
                    parts.append("Allow: \(allow)")
                }
                if !parts.isEmpty { serverInfo = parts.joined(separator: " · ") }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw StorageDriverError.unauthorized(base.host ?? base.absoluteString)
                }
            }
        } catch let error as StorageDriverError {
            throw error
        } catch {
            notes.append("OPTIONS 请求失败，已忽略：\(error.localizedDescription)")
        }

        if endpoint.address.hasPrefix("http://") {
            notes.append("当前使用明文 HTTP：账号与内容在网络上不加密传输。"
                + "若服务端支持，建议改用 https://。")
        }
        if credentials.allowInsecureTLS {
            notes.append("已允许自签名证书：无法通过证书链确认服务器身份，"
                + "中间人攻击无法被察觉。仅应在可信局域网内使用。")
        }

        let responses = try await propfind(base, depth: 1)
        let selfPath = normalizedPath(base)
        let children = responses.filter {
            normalizedPath($0.href, relativeTo: base).map { $0 != selfPath } ?? false
        }

        let rootResponse = responses.first {
            normalizedPath($0.href, relativeTo: base) == selfPath
        }
        let privileges = rootResponse?.privileges ?? []
        // 有权限集就据实判断；没有就不猜。
        let writable: Bool? = privileges.isEmpty
            ? nil
            : privileges.contains(where: { $0 == "write" || $0 == "write-content" || $0 == "all" })
        if privileges.isEmpty {
            notes.append("服务端未返回 current-user-privilege-set，无法判定是否可写。")
        }

        return StorageProbe(
            kind: .webdav,
            endpointDescription: endpoint.displayText,
            resolvedLocation: base.absoluteString,
            fileSystemType: nil,
            isWritable: writable,
            rootEntryCount: children.count,
            serverInfo: serverInfo,
            notes: notes,
            elapsedSeconds: clock.elapsed
        )
    }
}

// ───────────────────────────────────────────────── 认证回调 --

/// 处理 Basic / Digest / 自签名证书的挑战。
final class WebDAVAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    private let credentials: StorageCredentials

    init(credentials: StorageCredentials) {
        self.credentials = credentials
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodServerTrust {
            // 自签证书。默认拒绝 —— 允许就等于放弃对服务器身份的确认。
            guard credentials.allowInsecureTLS,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodNTLM else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard !credentials.isAnonymous else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 已经失败过一次，说明这份凭据就是错的。
        //
        // 这里刻意返回 `.performDefaultHandling` 而**不是** `.cancelAuthenticationChallenge`：
        // 取消挑战会让整个请求以 `NSURLErrorCancelled(-999)` 结束，
        // 服务端那个带着 `WWW-Authenticate` 的 401 响应就再也拿不到了。
        // 结果是用户看到"已取消"，而不是"密码错误" —— 报错信息丢失了归因。
        // 不重复喂凭据、把原始响应交回来，`check()` 才能翻译出准确的 unauthorized。
        guard challenge.previousFailureCount < 1 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let credential = URLCredential(
            user: credentials.user,
            password: credentials.password,
            persistence: .none
        )
        completionHandler(.useCredential, credential)
    }
}
