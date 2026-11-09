import Foundation

/// 解析 WebDAV 的 `207 Multi-Status` 响应。
///
/// ## 为什么必须处理命名空间
///
/// PROPFIND 的响应里，元素名 `href`、`status`、`collection` 在 DAV 命名空间下，
/// 而有些服务端还会混入自己的扩展属性。按**拼接后的限定名**匹配
/// （比如硬编码找 `d:response`）会在下面这些合法情况下全部失配：
///   * 服务端用 `D:` 而不是 `d:`（前缀只是别名，语义完全相同）
///   * 服务端用默认命名空间 `xmlns="DAV:"`，元素名没有前缀
/// 所以打开 `shouldProcessNamespaces`，按 `namespaceURI + 局部名` 匹配。
///
/// ## 为什么按 propstat 分组再合并
///
/// 一个 `response` 里可以有多个 `propstat`，按成功/失败分组：
/// ```xml
/// <d:response>
///   <d:href>/dav/x</d:href>
///   <d:propstat>
///     <d:prop><d:getcontentlength>12</d:getcontentlength></d:prop>
///     <d:status>HTTP/1.1 200 OK</d:status>
///   </d:propstat>
///   <d:propstat>
///     <d:prop><d:getetag/></d:prop>
///     <d:status>HTTP/1.1 404 Not Found</d:status>   <!-- 这个属性取不到 -->
///   </d:propstat>
/// </d:response>
/// ```
/// 而 `status` 出现在 `prop` **之后**，所以不能边读边判 —— 必须先把一个
/// propstat 的属性攒起来，读到它的 `status` 才知道该不该要。直接边读边写
/// 会把失败分支里的空值覆盖掉成功分支里的真实值，表现为"文件大小全是 0"。
final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {

    struct Response {
        var href: String?
        var isCollection = false
        var contentLength: Int64?
        var modified: Date?
        var etag: String?
        var privileges: Set<String> = []
    }

    private let davNamespace = "DAV:"

    private var responses: [Response] = []
    private var current: Response?

    // 当前 propstat 的暂存区
    private var inPropstat = false
    private var propstatSolved = false
    private var propstatSawStatus = false
    private var propstatLength: Int64?
    private var propstatModified: Date?
    private var propstatETag: String?
    private var propstatIsCollection = false
    private var propstatPrivileges: Set<String> = []

    // 元素上下文
    private var capture: String?
    private var buffer = ""
    private var inResourceType = false
    private var inPrivilegeSet = false
    private var inPrivilege = false

    private var parseError: Error?

    static func parse(_ data: Data) throws -> [Response] {
        let delegate = WebDAVMultiStatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "XML 结构不合法"
            throw StorageDriverError.malformedResponse(reason)
        }
        if let parseError = delegate.parseError { throw parseError }
        return delegate.responses
    }

    /// WebDAV 元素才处理；服务端的扩展命名空间一律忽略。
    private func isDAV(_ namespace: String?) -> Bool {
        namespace == nil || namespace == davNamespace
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        // 打开了命名空间处理，elementName 已是局部名（前缀被剥掉）。
        let local = elementName.lowercased()
        guard isDAV(namespaceURI) else { return }

        switch local {
        case "response":
            current = Response()
            inPropstat = false

        case "propstat":
            inPropstat = true
            propstatSolved = false
            propstatSawStatus = false
            propstatLength = nil
            propstatModified = nil
            propstatETag = nil
            propstatIsCollection = false
            propstatPrivileges = []

        case "status":
            // 只在 propstat 内才关心 status：response 级别也有 status（整体状态码），
            // 混在一起会把整体状态当成属性状态。
            if inPropstat { capture = "status"; buffer = "" }

        case "href":
            // href 在 response 里可能出现多次（响应的 href 与某些扩展里的 href），
            // 只取第一个 —— 它是这个 response 自身的路径。
            if current?.href == nil { capture = "href"; buffer = "" }

        case "resourcetype":
            inResourceType = true

        case "collection":
            if inResourceType { propstatIsCollection = true }

        case "getcontentlength":
            capture = "length"; buffer = ""

        case "getlastmodified":
            capture = "modified"; buffer = ""

        case "getetag":
            capture = "etag"; buffer = ""

        case "current-user-privilege-set":
            inPrivilegeSet = true

        case "privilege":
            inPrivilege = true

        default:
            // 权限名就是 `<privilege>` 里那个元素的名字（write / read / …）。
            if inPrivilegeSet && inPrivilege {
                propstatPrivileges.insert(local)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let local = elementName.lowercased()
        guard isDAV(namespaceURI) else { return }

        switch local {
        case "status":
            if inPropstat {
                propstatSawStatus = true
                // 只认 2xx 的 propstat；404/403 的 propstat 表示这些属性取不到。
                if let code = Self.statusCode(from: buffer), (200..<300).contains(code) {
                    propstatSolved = true
                }
            }

        case "href":
            if capture == "href" {
                current?.href = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case "getcontentlength":
            if capture == "length" {
                propstatLength = Int64(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }

        case "getlastmodified":
            if capture == "modified" {
                propstatModified = Self.parseHTTPDate(
                    buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

        case "getetag":
            if capture == "etag" {
                let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                propstatETag = value.isEmpty ? nil : value
            }

        case "resourcetype":
            inResourceType = false

        case "current-user-privilege-set":
            inPrivilegeSet = false

        case "privilege":
            inPrivilege = false

        case "propstat":
            // 有 status 且不是 2xx → 丢弃这一组属性。
            // 没有 status → 少见但合法，按可用处理（否则属性会被整体丢掉）。
            let usable = propstatSawStatus ? propstatSolved : true
            if usable, var response = current {
                if let propstatLength { response.contentLength = propstatLength }
                if let propstatModified { response.modified = propstatModified }
                if let propstatETag { response.etag = propstatETag }
                if propstatIsCollection { response.isCollection = true }
                response.privileges.formUnion(propstatPrivileges)
                current = response
            }
            inPropstat = false

        case "response":
            if let current, let href = current.href, !href.isEmpty {
                responses.append(current)
            }
            current = nil

        default:
            break
        }

        // 所有分支都已消费完自己需要的文本，这里统一收尾。
        // 不能在 switch 之前重置 —— `status`/`href` 分支要用 buffer。
        capture = nil
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = StorageDriverError.malformedResponse(error.localizedDescription)
    }

    /// 从 `HTTP/1.1 200 OK` 里取出 200。
    ///
    /// 不用 `buffer.contains(" 2")` 这类字符串包含判断：那会把
    /// `HTTP/1.1 423 Locked` 之外的写法也误判，而且一旦服务端把协议写成
    /// `HTTP/1.1` 之外的形态（如 `HTTP/2 200`）就完全失效。
    static func statusCode(from statusLine: String) -> Int? {
        for token in statusLine.split(separator: " ") {
            if token.count == 3, let code = Int(token) { return code }
        }
        return nil
    }

    // MARK: 日期

    /// 解析 HTTP 日期（RFC 1123）。
    ///
    /// `DateFormatter` 不是线程安全的，所以每次新建而不是共用静态实例 ——
    /// 这里解析次数是"每个条目一次"，开销可接受。
    static func parseHTTPDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: text) { return date }

        // 少数服务端给 ISO 8601，多试一种格式比丢掉时间要好。
        let iso = ISO8601DateFormatter()
        return iso.date(from: text)
    }
}
