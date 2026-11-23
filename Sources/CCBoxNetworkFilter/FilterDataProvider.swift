import CCBoxNetworkFilterCore
import Foundation
import NetworkExtension
import Security

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var revision: String?
    private var policy = NetworkFilterPolicy(applications: [])

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        _ = currentPolicy()
        let loopbackRules = [
            NENetworkRule(
                destinationNetwork: NWHostEndpoint(hostname: "127.0.0.0", port: "0"),
                prefix: 8,
                protocol: .any
            ),
            NENetworkRule(
                destinationNetwork: NWHostEndpoint(hostname: "::1", port: "0"),
                prefix: 128,
                protocol: .any
            )
        ].map { NEFilterRule(networkRule: $0, action: .filterData) }
        apply(NEFilterSettings(rules: loopbackRules, defaultAction: .filterData), completionHandler: completionHandler)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        switch decision(for: flow) {
        case .allow: return .allow()
        case .drop: return .drop()
        case .inspectData:
            return .filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0, filterOutbound: true, peekOutboundBytes: 1)
        }
    }

    override func handleOutboundData(
        from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data
    ) -> NEFilterDataVerdict {
        decision(for: flow) == .allow ? .allow() : .drop()
    }

    private func decision(for flow: NEFilterFlow) -> NetworkFilterDecision {
        guard let socketFlow = flow as? NEFilterSocketFlow else { return .allow }
        let endpoint: (host: String?, port: String?)
        if let remote = socketFlow.remoteEndpoint as? NWHostEndpoint {
            endpoint = (remote.hostname, remote.port)
        } else {
            endpoint = (nil, nil)
        }
        return currentPolicy().decision(
            executablePath: executablePath(for: flow),
            remoteHost: endpoint.host ?? socketFlow.remoteHostname,
            remotePort: endpoint.port
        )
    }

    private func currentPolicy() -> NetworkFilterPolicy {
        let configuration = filterConfiguration.vendorConfiguration
        let currentRevision = configuration?["revision"] as? String
        lock.lock()
        defer { lock.unlock() }
        if currentRevision == revision { return policy }
        if let configuration, let updated = NetworkFilterPolicy(vendorConfiguration: configuration) {
            policy = updated
            revision = currentRevision
        }
        return policy
    }

    private func executablePath(for flow: NEFilterFlow) -> String? {
        var tokens: [Data] = []
        if let token = flow.sourceAppAuditToken { tokens.append(token) }
        if #available(macOS 13.0, *), let token = flow.sourceProcessAuditToken,
           token != flow.sourceAppAuditToken {
            tokens.append(token)
        }
        for token in tokens {
            var code: SecCode?
            let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
                  let code else { continue }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
                  let staticCode else { continue }
            var path: CFURL?
            guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess,
                  let url = path as URL? else { continue }
            return url.standardizedFileURL.path
        }
        return nil
    }
}
