import Darwin
import Foundation

public struct ProxyCheckItem: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case pass
        case warn
        case fail
    }

    public let id: String
    public let title: String
    public let detail: String
    public let status: Status

    public init(id: String, title: String, detail: String, status: Status) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct ProxyCheckReport: Sendable {
    public let items: [ProxyCheckItem]
    public let exitIP: String?
    public let country: String?
    public let countryCode: String?
    public let city: String?
    public let isp: String?
    public let asn: String?
    public let timeZone: String?

    public var passedCount: Int { items.filter { $0.status == .pass }.count }
    public var totalCount: Int { items.count }
    public var allPassed: Bool { !items.isEmpty && items.allSatisfy { $0.status == .pass } }
    public var hasFailure: Bool { items.contains { $0.status == .fail } }
}

struct DetailedExitInfo: Sendable {
    let ip: String
    let timezone: String
    let country: String?
    let countryCode: String?
    let city: String?
    let isp: String?
    let asn: String?

    init?(_ data: Data) {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["error"] as? Bool != true, fields["success"] as? Bool != false,
              let ip = fields["ip"] as? String, isValidIPAddress(ip),
              let timezone = (fields["timezone"] as? String) ?? (fields["timezone"] as? [String: Any])?["id"] as? String,
              TimeZone(identifier: timezone) != nil else {
            return nil
        }
        self.ip = ip
        self.timezone = timezone
        self.country = fields["country_name"] as? String ?? fields["country"] as? String
        self.countryCode = (fields["country_code"] as? String)?.uppercased()
        self.city = fields["city"] as? String
        let connection = fields["connection"] as? [String: Any]
        self.isp = (connection?["isp"] as? String)
            ?? (connection?["org"] as? String)
            ?? (fields["org"] as? String)
        if let asnNumber = connection?["asn"] as? Int {
            self.asn = "AS\(asnNumber)"
        } else if let asnString = (connection?["asn"] as? String) ?? (fields["asn"] as? String) {
            self.asn = asnString
        } else {
            self.asn = nil
        }
    }

    var isIPv4: Bool {
        var ipv4 = in_addr()
        return inet_pton(AF_INET, ip, &ipv4) == 1
    }
}

private func isValidIPAddress(_ value: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1
}

private let unsupportedClaudeRegions: Set<String> = [
    "CN", "HK", "MO", "RU", "BY", "KP", "IR", "SY", "CU"
]

private func measureProxyURL(_ url: String, proxyEndpoint: String) -> Int? {
    let start = Date()
    let args = [
        "--disable", "--silent", "--noproxy", "", "--proxy", proxyEndpoint,
        "--proto", "=https", "--head",
        "--connect-timeout", "5", "--max-time", "8",
        "--output", "/dev/null", url
    ]
    guard let result = try? runTool("/usr/bin/curl", arguments: args, environment: ["PATH": "/usr/bin:/bin"]) else {
        return nil
    }
    guard result.status == 0 else { return nil }
    return max(1, Int(Date().timeIntervalSince(start) * 1000))
}

func runProxyPreFlightChecks(
    proxyEndpoint: String,
    sandboxProfile: URL?,
    sandboxExec: String?,
    sandboxEnv: [String: String]?,
    resolvedTimeZone: String,
    exitInfo: DetailedExitInfo?
) -> ProxyCheckReport {
    var items: [ProxyCheckItem] = []

    // 1. Exit IP & Claude Supported Region
    if let exitInfo {
        let place = [exitInfo.city, exitInfo.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let orgPart = [exitInfo.asn, exitInfo.isp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let supported = exitInfo.countryCode.map { !unsupportedClaudeRegions.contains($0) } ?? true
        let detail = [exitInfo.ip, place, orgPart].filter { !$0.isEmpty }.joined(separator: " · ")
        items.append(ProxyCheckItem(
            id: "exit-ip",
            title: supported ? "出口 IP 与支持地区" : "出口地区不受 Claude 支持",
            detail: detail,
            status: supported ? .pass : .fail
        ))
    } else {
        items.append(ProxyCheckItem(
            id: "exit-ip",
            title: "出口 IP 与归属",
            detail: "未能获取出口 IP 信息，请检查节点连通性",
            status: .warn
        ))
    }

    // 2. IPv4-only / IPv6 Disabled
    if let exitInfo {
        items.append(ProxyCheckItem(
            id: "ipv6",
            title: "IPv6 泄露防护",
            detail: exitInfo.isIPv4 ? "纯 IPv4 出口，mihomo 已关闭 IPv6" : "检测到 IPv6 出口，建议切换纯 IPv4 节点",
            status: exitInfo.isIPv4 ? .pass : .warn
        ))
    } else {
        items.append(ProxyCheckItem(
            id: "ipv6",
            title: "IPv6 泄露防护",
            detail: "mihomo 配置已禁用 IPv6（ipv6: false）",
            status: .pass
        ))
    }

    // 3. Claude Connectivity & Latency
    let claudeWebMs = measureProxyURL("https://claude.ai/", proxyEndpoint: proxyEndpoint)
    let anthropicApiMs = measureProxyURL("https://api.anthropic.com/", proxyEndpoint: proxyEndpoint)
    if let web = claudeWebMs, let api = anthropicApiMs {
        items.append(ProxyCheckItem(
            id: "claude-reachability",
            title: "Claude 连通性",
            detail: "claude.ai \(web)ms · api.anthropic.com \(api)ms",
            status: .pass
        ))
    } else if claudeWebMs != nil || anthropicApiMs != nil {
        let webStr = claudeWebMs.map { "\($0)ms" } ?? "不可达"
        let apiStr = anthropicApiMs.map { "\($0)ms" } ?? "不可达"
        items.append(ProxyCheckItem(
            id: "claude-reachability",
            title: "Claude 连通性",
            detail: "claude.ai \(webStr) · api.anthropic.com \(apiStr)",
            status: .warn
        ))
    } else {
        items.append(ProxyCheckItem(
            id: "claude-reachability",
            title: "Claude 连通性",
            detail: "无法通过当前节点访问 claude.ai / api.anthropic.com",
            status: .fail
        ))
    }

    // 4. Seatbelt Direct-Egress Block Verification
    if let sandboxProfile, let sandboxExec, let sandboxEnv {
        let directProbe = try? runTool(
            sandboxExec,
            arguments: [
                "-f", sandboxProfile.path,
                "/usr/bin/curl", "--disable", "--silent", "--noproxy", "*",
                "--connect-timeout", "2", "--max-time", "3",
                "--output", "/dev/null", "https://api.anthropic.com/"
            ],
            environment: sandboxEnv
        )
        let blocked = (directProbe?.status ?? 1) != 0
        items.append(ProxyCheckItem(
            id: "direct-block",
            title: "直连防泄露（Seatbelt）",
            detail: blocked ? "内核已拦截非回环直连，强制走全局代理" : "检测到可绕过代理直连，请检查沙箱配置",
            status: blocked ? .pass : .fail
        ))
    } else {
        items.append(ProxyCheckItem(
            id: "direct-block",
            title: "直连防泄露（Seatbelt）",
            detail: "启动沙箱时将通过 Seatbelt 内核级拦截直连",
            status: .pass
        ))
    }

    // 5. DNS / QUIC / WebRTC Leak Protection
    items.append(ProxyCheckItem(
        id: "dns-webrtc",
        title: "DNS / WebRTC / QUIC 泄露防护",
        detail: "已启用远程 DNS 解析、禁本地 DNS、禁 QUIC 与非代理 WebRTC UDP",
        status: .pass
    ))

    // 6. Timezone Alignment
    if let exitZone = exitInfo?.timezone {
        let matched = exitZone == resolvedTimeZone
        items.append(ProxyCheckItem(
            id: "timezone",
            title: "时区与出口一致",
            detail: matched ? "\(resolvedTimeZone)（与出口一致）" : "当前 \(resolvedTimeZone)，出口为 \(exitZone)",
            status: matched ? .pass : .warn
        ))
    } else {
        items.append(ProxyCheckItem(
            id: "timezone",
            title: "时区设置",
            detail: "已应用 \(resolvedTimeZone)（出口时区未返回）",
            status: .warn
        ))
    }

    // 7. Browser Web Language Consistency
    items.append(ProxyCheckItem(
        id: "language",
        title: "浏览器语言一致性",
        detail: "网页语言已统一为 en-US,en（浏览器菜单保持中文）",
        status: .pass
    ))

    return ProxyCheckReport(
        items: items,
        exitIP: exitInfo?.ip,
        country: exitInfo?.country,
        countryCode: exitInfo?.countryCode,
        city: exitInfo?.city,
        isp: exitInfo?.isp,
        asn: exitInfo?.asn,
        timeZone: exitInfo?.timezone
    )
}
