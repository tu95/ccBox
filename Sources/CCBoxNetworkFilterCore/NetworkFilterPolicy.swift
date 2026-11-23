import Darwin
import Foundation

public struct NetworkFilterApplication: Codable, Equatable, Sendable {
    public let bundlePath: String
    public let allowedLoopbackPorts: Set<Int>

    public init(bundlePath: String, allowedLoopbackPorts: Set<Int>) {
        self.bundlePath = bundlePath
        self.allowedLoopbackPorts = allowedLoopbackPorts
    }
}

public enum NetworkFilterDecision: Equatable, Sendable {
    case allow
    case drop
    case inspectData
}

public struct NetworkFilterPolicy: Equatable, Sendable {
    public let applications: [NetworkFilterApplication]

    public init(applications: [NetworkFilterApplication]) {
        self.applications = applications
    }

    public init?(vendorConfiguration: [String: Any]) {
        guard let definitions = vendorConfiguration["applications"] as? [[String: Any]] else { return nil }
        var parsed: [NetworkFilterApplication] = []
        for definition in definitions {
            guard let bundlePath = definition["bundlePath"] as? String, !bundlePath.isEmpty,
                  let ports = definition["allowedLoopbackPorts"] as? [Int],
                  ports.allSatisfy({ (1...65535).contains($0) }) else { return nil }
            parsed.append(NetworkFilterApplication(
                bundlePath: URL(fileURLWithPath: bundlePath, isDirectory: true).standardizedFileURL.path,
                allowedLoopbackPorts: Set(ports)
            ))
        }
        applications = parsed
    }

    public func decision(executablePath: String?, remoteHost: String?, remotePort: String?) -> NetworkFilterDecision {
        guard let executablePath,
              let application = application(containing: executablePath) else { return .allow }
        guard let remoteHost else { return .inspectData }
        guard Self.isLoopback(remoteHost),
              let remotePort, let port = Int(remotePort),
              application.allowedLoopbackPorts.contains(port) else { return .drop }
        return .allow
    }

    private func application(containing executablePath: String) -> NetworkFilterApplication? {
        let executableComponents = URL(fileURLWithPath: executablePath).standardizedFileURL.pathComponents
        return applications.first { application in
            let bundleComponents = URL(fileURLWithPath: application.bundlePath, isDirectory: true)
                .standardizedFileURL.pathComponents
            return executableComponents.starts(with: bundleComponents)
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        }
    }
}
