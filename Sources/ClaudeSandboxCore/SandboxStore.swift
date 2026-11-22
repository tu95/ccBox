import Foundation

public enum SandboxIsolationMode: String, Codable, CaseIterable, Sendable {
    case isolated
    case hostPassthrough

    public var displayName: String {
        switch self {
        case .isolated: return "纯隔离"
        case .hostPassthrough: return "本机直通"
        }
    }

    public var summary: String {
        switch self {
        case .isolated: return "复制项目副本、独立 HOME 与文件强隔离"
        case .hostPassthrough: return "网络与 Claude 账号强隔离，直接读写原目录并复用本机 Shell/工具"
        }
    }
}

public struct SandboxImportedApp: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var bundlePath: String

    public init(id: UUID = UUID(), name: String, bundlePath: String) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
    }
}

public struct SandboxEnvironment: Codable, Identifiable, Equatable {
    public static let palette: [String] = [
        "#EF4444", // 红
        "#3B82F6", // 蓝
        "#10B981", // 绿
        "#F59E0B", // 琥珀
        "#8B5CF6", // 紫
        "#EC4899", // 粉
        "#06B6D4", // 青
        "#F97316"  // 橙
    ]

    public let id: UUID
    public var name: String
    public var workspace: URL
    public var node: String?
    public var timeZoneIdentifier: String?
    public var isolationMode: SandboxIsolationMode
    public var accentHex: String?
    public var importedApps: [SandboxImportedApp]

    public init(
        name: String,
        workspace: URL,
        isolationMode: SandboxIsolationMode = .isolated,
        accentHex: String? = nil,
        importedApps: [SandboxImportedApp] = []
    ) {
        self.id = UUID()
        self.name = name
        self.workspace = workspace
        self.isolationMode = isolationMode
        self.accentHex = accentHex
        self.importedApps = importedApps
    }

    public var resolvedAccentHex: String {
        if let accentHex, !accentHex.isEmpty { return accentHex }
        let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.palette[abs(hash) % Self.palette.count]
    }

    public static func nextAccentHex(avoiding used: [String]) -> String {
        let normalized = Set(used.map { $0.uppercased() })
        if let unused = palette.first(where: { !normalized.contains($0.uppercased()) }) {
            return unused
        }
        return palette[used.count % palette.count]
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workspace, node, timeZoneIdentifier, isolationMode, accentHex, importedApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        workspace = try container.decode(URL.self, forKey: .workspace)
        node = try container.decodeIfPresent(String.self, forKey: .node)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        isolationMode = try container.decodeIfPresent(SandboxIsolationMode.self, forKey: .isolationMode) ?? .isolated
        accentHex = try container.decodeIfPresent(String.self, forKey: .accentHex)
        importedApps = try container.decodeIfPresent([SandboxImportedApp].self, forKey: .importedApps) ?? []
    }
}

public struct SandboxFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SandboxStore: Sendable {
    let root: URL
    private var files: FileManager { .default }

    public init(root: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = (root ?? support.appendingPathComponent("ClaudeSandbox", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    private var indexURL: URL { root.appendingPathComponent("environments.json") }
    func directory(for environment: SandboxEnvironment) -> URL {
        root.appendingPathComponent(environment.id.uuidString, isDirectory: true)
    }

    public func isolatedWorkspace(for environment: SandboxEnvironment) -> URL {
        directory(for: environment).appendingPathComponent("workspace", isDirectory: true)
    }

    func prepareWorkspace(for environmentID: UUID, source: URL) throws -> URL {
        let folder = root.appendingPathComponent(environmentID.uuidString, isDirectory: true)
        let workspace = folder.appendingPathComponent("workspace", isDirectory: true)
        if files.fileExists(atPath: workspace.path) {
            let attributes = try workspace.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard workspace.resolvingSymlinksInPath().path ==
                    folder.resolvingSymlinksInPath().appendingPathComponent("workspace").path,
                  attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                throw SandboxFailure("隔离工作区路径无效。")
            }
            return workspace
        }
        try validateWorkspace(source, store: self)
        try makePrivateDirectory(folder)
        let staging = folder.appendingPathComponent(".workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        do {
            try files.copyItem(at: source, to: staging)
            try files.moveItem(at: staging, to: workspace)
        } catch {
            throw SandboxFailure("无法复制项目到隔离工作区：\(error.localizedDescription)")
        }
        return workspace
    }

    public func load() throws -> [SandboxEnvironment] {
        guard files.fileExists(atPath: indexURL.path) else { return [] }
        return try JSONDecoder().decode([SandboxEnvironment].self, from: Data(contentsOf: indexURL))
    }

    public func save(_ environments: [SandboxEnvironment]) throws {
        try makePrivateDirectory(root)
        try writePrivate(JSONEncoder().encode(environments), to: indexURL)
    }

    public func nodes(for environment: SandboxEnvironment) throws -> [String] {
        try loadNodes(for: environment).map(\.name)
    }

    public func importYAML(_ url: URL, for environment: SandboxEnvironment) throws -> [String] {
        let definitions = try readNodes(at: url)
        return try storeNodes(definitions, for: environment)
    }

    public func importSubscription(_ url: URL, for environment: SandboxEnvironment) async throws -> [String] {
        guard canDownloadSubscription(url) else {
            throw SandboxFailure("请输入完整的 HTTP 或 HTTPS 订阅链接。")
        }
        let source = try await downloadSubscription(url)
        try Task.checkCancellation()
        let folder = directory(for: environment)
        try makePrivateDirectory(root)
        try makePrivateDirectory(folder)
        let temporary = folder.appendingPathComponent(".subscription-\(UUID().uuidString)")
        defer { try? files.removeItem(at: temporary) }
        try writePrivate(decodeSubscription(source), to: temporary)
        let definitions: [[String: Any]]
        do {
            definitions = try readNodes(at: temporary)
        } catch {
            throw SandboxFailure("订阅未返回可读取的 Clash/mihomo YAML 节点列表，请使用服务商提供的 Clash 订阅链接。")
        }
        return try storeNodes(definitions, for: environment)
    }

    private func readNodes(at url: URL) throws -> [[String: Any]] {
        let appBundle = Bundle.main.resourceURL?
            .appendingPathComponent("ClaudeSandbox_ClaudeSandboxCore.bundle", isDirectory: true)
        let resources = appBundle.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let parser = resources.url(forResource: "ImportNodes", withExtension: "rb") else {
            throw SandboxFailure("找不到 YAML 解析器。")
        }
        let result = try runTool("/usr/bin/ruby", arguments: [parser.path, url.path], captureOutput: true)
        guard result.status == 0,
              let definitions = try JSONSerialization.jsonObject(with: result.output) as? [[String: Any]] else {
            throw SandboxFailure("读取 YAML 失败。请导入带有 proxies 列表的 Clash/mihomo 节点文件，不使用 YAML 别名。")
        }
        return definitions
    }

    private func storeNodes(_ definitions: [[String: Any]], for environment: SandboxEnvironment) throws -> [String] {
        let supported = ProxyNode.supportedTypes
        let nodes = try definitions.compactMap { item -> ProxyNode? in
            guard let type = item["type"] as? String, supported.contains(type) else { return nil }
            return try ProxyNode(item)
        }
        guard !nodes.isEmpty else {
            throw SandboxFailure("YAML 中没有可用的具体节点。请导入本地节点列表。")
        }
        guard Set(nodes.map(\.name)).count == nodes.count else {
            throw SandboxFailure("YAML 有重名节点，请先给节点改成不同的名字。")
        }
        let folder = directory(for: environment)
        try makePrivateDirectory(root)
        try makePrivateDirectory(folder)
        let data = try JSONSerialization.data(withJSONObject: nodes.map(\.settings))
        try writePrivate(data, to: folder.appendingPathComponent("nodes.json"))
        return nodes.map(\.name)
    }

    public func remove(_ environment: SandboxEnvironment) throws {
        let folder = directory(for: environment)
        let remaining = try load().filter { $0.id != environment.id }
        guard files.fileExists(atPath: folder.path) else {
            try save(remaining)
            return
        }
        let removed = root.appendingPathComponent(".removed-\(UUID().uuidString)")
        try files.moveItem(at: folder, to: removed)
        do {
            try save(remaining)
        } catch {
            try? files.moveItem(at: removed, to: folder)
            throw error
        }
        try files.removeItem(at: removed)
    }

    func loadNodes(for environment: SandboxEnvironment) throws -> [ProxyNode] {
        let location = directory(for: environment).appendingPathComponent("nodes.json")
        guard files.fileExists(atPath: location.path) else { return [] }
        let data = try Data(contentsOf: location)
        guard let definitions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SandboxFailure("环境的节点配置无法读取，请重新导入 YAML。")
        }
        return try definitions.map(ProxyNode.init)
    }
}

private let maxSubscriptionSize = 4 * 1024 * 1024

private func canDownloadSubscription(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host, !host.isEmpty else { return false }
    return true
}

private final class SubscriptionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map(canDownloadSubscription) == true
        let downgrade = response.url?.scheme?.lowercased() == "https" && request.url?.scheme?.lowercased() != "https"
        completionHandler(allowed && !downgrade ? request : nil)
    }
}

private func downloadSubscription(_ url: URL) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 25
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: SubscriptionRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("mihomo", forHTTPHeaderField: "User-Agent")
    request.setValue("application/yaml, text/yaml, text/plain, */*", forHTTPHeaderField: "Accept")
    do {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SandboxFailure("订阅服务器未成功返回节点，请检查链接或权限。")
        }
        guard http.expectedContentLength <= maxSubscriptionSize else {
            throw SandboxFailure("订阅文件超过 4 MB。")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxSubscriptionSize else { throw SandboxFailure("订阅文件超过 4 MB。") }
            data.append(byte)
        }
        return data
    } catch let failure as SandboxFailure {
        throw failure
    } catch {
        try Task.checkCancellation()
        throw SandboxFailure("下载订阅失败，请检查网络或订阅链接。")
    }
}

func decodeSubscription(_ data: Data) -> Data {
    guard let content = String(data: data, encoding: .utf8) else { return data }
    var base64 = content.filter { !$0.isWhitespace }
        .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64.append("=") }
    guard let decoded = Data(base64Encoded: base64), let yaml = String(data: decoded, encoding: .utf8),
          yaml.contains("proxies:") || yaml.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") else {
        return data
    }
    return decoded
}

struct ProxyNode {
    static let supportedTypes: Set<String> = [
        "http", "socks5", "ss", "ssr", "vmess", "vless", "trojan", "hysteria",
        "hysteria2", "tuic", "anytls", "wireguard", "snell", "mieru", "ssh"
    ]

    let name: String
    let settings: [String: Any]

    init(_ settings: [String: Any]) throws {
        guard let name = settings["name"] as? String, !name.isEmpty,
              name.count <= 256, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let type = settings["type"] as? String, Self.supportedTypes.contains(type),
              let server = settings["server"] as? String, !server.isEmpty,
              let port = settings["port"] as? Int, (1...65535).contains(port) else {
            throw SandboxFailure("节点缺少有效的名称、协议、服务器或端口。")
        }
        guard (settings["dialer-proxy"] as? String ?? "").isEmpty else {
            throw SandboxFailure("节点 \(name) 使用前置代理。请导入可独立连接的节点。")
        }
        self.name = name
        self.settings = settings
    }

    func configuration(httpPort: UInt16, socksPort: UInt16) -> [String: Any] {
        var upstream = settings
        upstream["name"] = "sandbox-upstream"
        return [
            "mode": "global",
            "ipv6": false,
            "allow-lan": false,
            "log-level": "warning",
            "tun": ["enable": false],
            "profile": ["store-selected": false],
            "proxies": [upstream],
            "proxy-groups": [["name": "GLOBAL", "type": "select", "proxies": ["sandbox-upstream"]]],
            "listeners": [[
                "name": "sandbox-http", "type": "http", "listen": "127.0.0.1", "port": Int(httpPort)
            ], [
                "name": "sandbox-socks", "type": "socks", "listen": "127.0.0.1", "port": Int(socksPort)
            ]]
        ]
    }
}

func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
}

func writePrivate(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw SandboxFailure("无法写入私有配置。")
    }
    if rename(temporary.path, url.path) != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

struct ToolResult {
    let status: Int32
    let output: Data
}

func runTool(
    _ executable: String, arguments: [String], environment: [String: String]? = nil,
    captureOutput: Bool = false
) throws -> ToolResult {
    let process = Process()
    let pipe = captureOutput ? Pipe() : nil
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe as Any? ?? FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    return ToolResult(status: process.terminationStatus, output: output)
}
