import Foundation
import Network

/// 测试服务端自身的错误。
///
/// 刻意不复用引擎的 `StorageDriverError`：这个服务端是"被测对象的对立面"，
/// 复用被测方的类型会让"服务端起不来"和"驱动有问题"这两类失败混在一起，
/// 排查时分不清到底是谁的错。
struct MiniWebDAVError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 测试用的最小 WebDAV 服务端。
///
/// ## 为什么值得写这个
///
/// 驱动层的验证有两种做法：把 `URLSession` 换成 mock 去断言"我发了什么请求"，
/// 或者真的起一个服务端、真的走一遍 HTTP。前者只能在**我以为的协议**上验证，
/// 而协议细节（尾斜杠、207、href 编码、propstat 分组）恰恰是最容易想错的地方。
///
/// 所以这里用 `Network` 框架起一个真实的服务端，用真实磁盘做后端 ——
/// 不需要任何第三方依赖，也不需要外网。整个 WebDAV 往返（MKCOL / PUT / GET /
/// PROPFIND / DELETE）都在本机真实发生。
///
/// 刻意用 `D:`（大写）作为 XML 前缀，而不是惯例的 `d:`：
/// 前缀只是命名空间的别名，按拼接后名字匹配的解析器会在这里失败。
final class MiniWebDAVServer: @unchecked Sendable {

    struct Configuration {
        var user = "tester"
        var password = "secret"
        var requireAuth = true
        /// 需要认证时，是否返回 `WWW-Authenticate`（模拟 Digest/NTLM 服务端）。
        /// 关掉它可以验证"预先发送 Basic"这条路径确实起作用。
        var sendChallenge = true
    }

    /// 服务端挂载前缀。固定成 `/dav` 是为了让测试里能验证"地址含路径"这种情况。
    static let mountPrefix = "/dav"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mini-webdav-server")
    private let config: Configuration
    /// 服务端后端目录。真实磁盘，PUT 会真的落文件。
    let root: URL

    private let lock = NSLock()
    private var recordedMethods: [String] = []

    private(set) var port: UInt16 = 0

    init(root: URL, configuration: Configuration = Configuration()) throws {
        self.root = root
        self.config = configuration
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: .any)
    }

    /// 收到过的请求方法（按顺序）。用来断言驱动真的用了对的动词。
    var handledMethods: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedMethods
    }

    // MARK: 生命周期

    func start(timeout: TimeInterval = 5) async throws {
        let gate = ResumeGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resume(.success(()))
            case .failed(let error):
                gate.resume(.failure(error))
            case .cancelled:
                gate.resume(.failure(MiniWebDAVError(message: "监听器被取消")))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        try await gate.wait(timeout: timeout)
        guard let assigned = listener.port?.rawValue, assigned != 0 else {
            throw MiniWebDAVError(message: "服务端未能分配到端口")
        }
        port = assigned
    }

    func stop() {
        listener.cancel()
    }

    var baseURL: String { "http://127.0.0.1:\(port)\(Self.mountPrefix)" }

    // MARK: 连接处理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: [])
    }

    private func receive(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(contentsOf: data) }

            if let request = HTTPRequest.parse(accumulated) {
                let response = self.handle(request)
                connection.send(
                    content: response.serialized(),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }
            // 请求还没收全，继续收。
            self.receive(connection, buffer: accumulated)
        }
    }

    // MARK: 路由

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        lock.lock()
        recordedMethods.append(request.method)
        lock.unlock()

        if config.requireAuth, !isAuthorized(request) {
            var headers: [String: String] = [:]
            if config.sendChallenge {
                headers["WWW-Authenticate"] = "Basic realm=\"mini-webdav\""
            }
            return HTTPResponse(status: 401, headers: headers)
        }

        guard let target = localURL(for: request.target) else {
            return HTTPResponse(status: 400)
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)

        switch request.method {
        case "OPTIONS":
            return HTTPResponse(
                status: 200,
                headers: [
                    "DAV": "1,2",
                    "Allow": "OPTIONS, GET, PUT, DELETE, PROPFIND, MKCOL",
                    "Server": "MiniWebDAV/1.0 (SyncApp tests)",
                ]
            )

        case "PROPFIND":
            guard exists else { return HTTPResponse(status: 404) }
            let depth = Int(request.headers["depth"] ?? "1") ?? 1
            let body = multiStatus(at: target, depth: depth)
            return HTTPResponse(
                status: 207,
                headers: ["Content-Type": "application/xml; charset=utf-8"],
                body: body
            )

        case "GET":
            guard exists, !isDirectory.boolValue else { return HTTPResponse(status: 404) }
            guard let data = try? Data(contentsOf: target) else {
                return HTTPResponse(status: 500)
            }
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: data
            )

        case "PUT":
            guard !isDirectory.boolValue else { return HTTPResponse(status: 405) }
            do {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try request.body.write(to: target)
            } catch {
                return HTTPResponse(status: 500)
            }
            return HTTPResponse(status: exists ? 204 : 201)

        case "MKCOL":
            if exists { return HTTPResponse(status: 405) }
            do {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                return HTTPResponse(status: 500)
            }
            return HTTPResponse(status: 201)

        case "DELETE":
            guard exists else { return HTTPResponse(status: 404) }
            do {
                try fileManager.removeItem(at: target)
            } catch {
                return HTTPResponse(status: 500)
            }
            return HTTPResponse(status: 204)

        default:
            return HTTPResponse(status: 405)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"],
              header.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(header.dropFirst("basic ".count))),
              let pair = String(data: decoded, encoding: .utf8) else {
            return false
        }
        return pair == "\(config.user):\(config.password)"
    }

    /// 把请求路径映射到后端文件。
    private func localURL(for target: String) -> URL? {
        let rawPath = target.split(separator: "?").first.map(String.init) ?? target
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        guard decoded.hasPrefix(Self.mountPrefix) else { return nil }

        var relative = String(decoded.dropFirst(Self.mountPrefix.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        // 测试服务端也要防逃逸，避免测试本身写出测试目录。
        guard !relative.split(separator: "/").contains("..") else { return nil }
        return relative.isEmpty ? root : root.appendingPathComponent(relative)
    }

    // MARK: PROPFIND 响应

    private func multiStatus(at collection: URL, depth: Int) -> Data {
        var items: [URL] = [collection]
        if depth >= 1 {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: collection,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []
            items.append(contentsOf: children.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }

        var xml = #"<?xml version="1.0" encoding="utf-8"?>"# + "\n"
        xml += #"<D:multistatus xmlns:D="DAV:">"# + "\n"
        for item in items {
            xml += responseXML(for: item)
        }
        xml += "</D:multistatus>\n"
        return Data(xml.utf8)
    }

    private func responseXML(for item: URL) -> String {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)

        var props = ""
        if isDirectory.boolValue {
            props += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            let attributes = try? fileManager.attributesOfItem(atPath: item.path)
            let size = (attributes?[.size] as? Int) ?? 0
            props += "<D:resourcetype/>"
            props += "<D:getcontentlength>\(size)</D:getcontentlength>"
        }
        let attributes = try? fileManager.attributesOfItem(atPath: item.path)
        if let modified = attributes?[.modificationDate] as? Date {
            props += "<D:getlastmodified>\(Self.httpDate(modified))</D:getlastmodified>"
        }
        props += """
        <D:current-user-privilege-set>\
        <D:privilege><D:read/></D:privilege>\
        <D:privilege><D:write/></D:privilege>\
        </D:current-user-privilege-set>
        """

        return """
        <D:response>
        <D:href>\(href(for: item, isDirectory: isDirectory.boolValue))</D:href>
        <D:propstat>
        <D:prop>\(props)</D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>

        """
    }

    /// 生成 href：必须是**百分号编码过的绝对路径**。
    ///
    /// 不编码的话，含中文或空格的文件名会让整个 multistatus 变成无法解析的
    /// 或者解析出错误路径的 XML —— 而这一条只有在真实文件名叫中文时才暴露。
    private func href(for item: URL, isDirectory: Bool) -> String {
        let rootPath = root.standardizedFileURL.path
        let full = item.standardizedFileURL.path
        var relative = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full
        while relative.hasPrefix("/") { relative.removeFirst() }

        var path = Self.mountPrefix
        if !relative.isEmpty { path += "/" + relative }
        if isDirectory && !path.hasSuffix("/") { path += "/" }
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

// ───────────────────────────────────────────────── HTTP 语法 --

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    /// 数据不完整时返回 nil，调用方继续收。
    static func parse(_ bytes: [UInt8]) -> HTTPRequest? {
        let separator: [UInt8] = [13, 10, 13, 10]  // \r\n\r\n
        guard let headerEnd = find(separator, in: bytes) else { return nil }

        let headerBytes = Array(bytes[0..<headerEnd])
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd + separator.count
        guard bytes.count >= bodyStart + contentLength else { return nil }

        return HTTPRequest(
            method: String(parts[0]).uppercased(),
            target: String(parts[1]),
            headers: headers,
            body: Data(bytes[bodyStart..<(bodyStart + contentLength)])
        )
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) {
            if Array(bytes[start..<(start + pattern.count)]) == pattern { return start }
        }
        return nil
    }
}

private struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        // 始终显式给出 Content-Length：客户端要靠它判断消息结束。
        head += "Content-Length: \(body.count)\r\n"
        // 一个连接只处理一个请求。测试服务端不做 keep-alive，
        // 省掉连接复用带来的状态管理，也让每个请求的边界绝对清晰。
        head += "Connection: close\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 207: return "Multi-Status"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

/// 让 `start()` 的 continuation 只被恢复一次。
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?

    init() {}

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        // 还没人 await 就先记下结果。
        if pendingResult == nil { pendingResult = result }
        lock.unlock()
    }

    func wait(timeout: TimeInterval) async throws {
        if let pending = takePending() { return try pending.get() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let pending = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func takePending() -> Result<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        let result = pendingResult
        pendingResult = nil
        return result
    }
}
