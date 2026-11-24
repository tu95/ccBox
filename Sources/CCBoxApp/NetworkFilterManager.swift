import CCBoxNetworkFilterCore
import Foundation
import NetworkExtension
import SystemExtensions

enum NetworkFilterStatus: Equatable {
    case inactive
    case activating
    case awaitingApproval
    case active
    case disabling
    case failed(String)

    var title: String {
        switch self {
        case .inactive: return "系统网络防护"
        case .activating: return "正在激活网络防护…"
        case .awaitingApproval: return "请在系统设置中允许网络扩展"
        case .active: return "系统网络防护已启用"
        case .disabling: return "正在关闭网络防护…"
        case .failed(let message): return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .activating, .awaitingApproval, .disabling: return true
        case .inactive, .active, .failed: return false
        }
    }
}

struct NetworkFilterFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class NetworkFilterManager: NSObject {
    var onChange: (() -> Void)?
    private(set) var status: NetworkFilterStatus = .inactive
    private var applications: [NetworkFilterApplication] = []
    private var activationRequest: OSSystemExtensionRequest?
    private var activationContinuation: CheckedContinuation<Void, Error>?

    private var extensionIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.tu95.ccbox") + ".NetworkFilter"
    }

    private var extensionIsBundled: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(extensionIdentifier).systemExtension", isDirectory: true
        )
        return FileManager.default.fileExists(atPath: url.path)
    }

    func refresh() async {
        do {
            try await loadConfiguration()
            setStatus(NEFilterManager.shared().isEnabled ? .active : .inactive)
        } catch {
            setStatus(.inactive)
        }
    }

    func enable() async throws {
        guard !status.isBusy else { return }
        guard extensionIsBundled else {
            throw NetworkFilterFailure("当前构建未包含网络系统扩展。请配置开发者签名和两份匹配的 provisioning profile 后，按 README 启用 NetworkExtension 构建。")
        }
        do {
            try await loadConfiguration()
            if !NEFilterManager.shared().isEnabled {
                setStatus(.activating)
                try await activateExtension()
            }
            try await saveConfiguration(enabled: true)
            setStatus(.active)
        } catch {
            setStatus(.failed("系统网络防护启用失败：\(error.localizedDescription)"))
            throw error
        }
    }

    func disable() async throws {
        guard status == .active else { return }
        setStatus(.disabling)
        do {
            try await loadConfiguration()
            try await saveConfiguration(enabled: false)
            setStatus(.inactive)
        } catch {
            setStatus(.active)
            throw error
        }
    }

    func updateApplications(_ updated: [NetworkFilterApplication]) async {
        applications = updated
        guard status == .active else { return }
        do {
            try await loadConfiguration()
            try await saveConfiguration(enabled: true)
            setStatus(.active)
        } catch {
            setStatus(.failed("系统网络防护规则更新失败：\(error.localizedDescription)"))
        }
    }

    private func setStatus(_ updated: NetworkFilterStatus) {
        status = updated
        onChange?()
    }

    private func loadConfiguration() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEFilterManager.shared().loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func saveConfiguration(enabled: Bool) async throws {
        let manager = NEFilterManager.shared()
        let configuration = manager.providerConfiguration ?? NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterPackets = false
        configuration.filterDataProviderBundleIdentifier = extensionIdentifier
        configuration.vendorConfiguration = [
            "revision": UUID().uuidString,
            "applications": applications.map { application in
                [
                    "bundlePath": application.bundlePath,
                    "allowedLoopbackPorts": application.allowedLoopbackPorts.sorted()
                ]
            }
        ]
        manager.providerConfiguration = configuration
        manager.localizedDescription = "ccbox 应用直连防护"
        manager.grade = .firewall
        manager.isEnabled = enabled
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func activateExtension() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activationContinuation = continuation
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: extensionIdentifier, queue: .main
            )
            request.delegate = self
            activationRequest = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finishActivation(with result: Result<Void, Error>) {
        let continuation = activationContinuation
        activationContinuation = nil
        activationRequest = nil
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

extension NetworkFilterManager: OSSystemExtensionRequestDelegate {
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated {
            setStatus(.awaitingApproval)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        MainActor.assumeIsolated {
            guard result == .completed else {
                finishActivation(with: .failure(NetworkFilterFailure("系统扩展将在重启后完成激活，请重启 macOS。")))
                return
            }
            finishActivation(with: .success(()))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finishActivation(with: .failure(error))
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
