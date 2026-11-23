import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClaudeSandboxCore

enum SandboxLaunchTarget {
    case session
    case terminal
    case chrome
    case imported(SandboxImportedApp)
}

@MainActor
final class EnvironmentSession {
    let id: UUID
    let runner: SandboxRunner
    let terminal = SandboxTerminal()
    var launch: SandboxLaunch?
    var isRunning: Bool { launch != nil }
    var isTerminalRunning = false
    var hasTerminalTab = false
    var showsTerminal = false
    var isStarting = false
    var isProxyRunning = false
    var isProxyStarting = false
    var isChromeRunning = false
    var isChromeStarting = false
    var runningAppIDs: Set<UUID> = []
    var startingAppIDs: Set<UUID> = []
    var proxyState = "未启动"
    var resolvedTimeZone = "自动"
    var exitIP: String?
    var inspectedExit: SandboxExit?
    var checkReport: ProxyCheckReport?
    var isInspectingExit = false
    var terminalColumns: UInt16 = 100
    var terminalRows: UInt16 = 30

    init(id: UUID, store: SandboxStore, timeZone: String?) {
        self.id = id
        self.runner = SandboxRunner(store: store)
        self.resolvedTimeZone = timeZone ?? "自动"
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var environments: [SandboxEnvironment] = []
    @Published var selectedID: UUID?
    @Published var nodes: [String] = []
    @Published var isImporting = false
    @Published var importingAppName: String?
    @Published var errorMessage: String?
    @Published var notice: String?

    let store: SandboxStore
    let networkFilter = NetworkFilterManager()
    private var sessions: [UUID: EnvironmentSession] = [:]
    private let borderOverlay = WindowBorderOverlayManager()
    private var terminateObserver: NSObjectProtocol?
    private var demoPending: Bool

    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        let demoRoot = demo ? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("claude-sandbox-demo-\(UUID().uuidString)", isDirectory: true) : nil
        store = SandboxStore(root: demoRoot?.appendingPathComponent("state", isDirectory: true))
        demoPending = demo
        networkFilter.onChange = { [weak self] in self?.objectWillChange.send() }
        Task {
            await networkFilter.refresh()
            synchronizeNetworkFilter()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAll()
            }
        }
        do {
            if let demoRoot {
                let workspace = demoRoot.appendingPathComponent("workspace", isDirectory: true)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                environments = [SandboxEnvironment(name: "临时沙箱演示", workspace: workspace)]
            } else {
                environments = try store.load()
            }
            for env in environments {
                _ = session(for: env)
            }
            selectedID = environments.first?.id
            refreshNodes()
        } catch {
            errorMessage = "读取环境失败：\(error.localizedDescription)"
        }
    }

    private func session(for environment: SandboxEnvironment) -> EnvironmentSession {
        if let existing = sessions[environment.id] { return existing }
        let created = EnvironmentSession(id: environment.id, store: store, timeZone: environment.timeZoneIdentifier)
        let id = environment.id
        created.terminal.onExit = { [weak self, weak created] code in
            guard let self, let created else { return }
            created.isTerminalRunning = false
            guard created.isRunning else { return }
            if self.selectedID == id {
                self.notice = "沙箱 shell 已退出（\(code)）"
            }
            self.objectWillChange.send()
        }
        created.runner.onProxyExit = { [weak self, weak created] in
            guard let self, let created else { return }
            if let pid = created.runner.browserProcessIdentifier { self.borderOverlay.unregister(pid: pid) }
            for pid in created.runner.runningImportedAppPIDs { self.borderOverlay.unregister(pid: pid) }
            created.terminal.stop()
            created.launch = nil
            created.isProxyRunning = false
            created.isChromeRunning = false
            created.runningAppIDs.removeAll()
            created.startingAppIDs.removeAll()
            created.proxyState = "代理异常退出"
            self.objectWillChange.send()
        }
        created.runner.onBrowserStart = { [weak self, weak created] pid in
            guard let self, let created else { return }
            created.isChromeRunning = true
            created.isChromeStarting = false
            self.borderOverlay.register(pid: pid, accentHex: environment.resolvedAccentHex)
            self.objectWillChange.send()
        }
        created.runner.onBrowserExit = { [weak self, weak created] pid, status in
            guard let self, let created else { return }
            created.isChromeRunning = false
            created.isChromeStarting = false
            self.borderOverlay.unregister(pid: pid)
            if status != 0 {
                if self.selectedID == id {
                    self.notice = nil
                }
                self.errorMessage = "隔离版 Chrome 已异常退出（退出码 \(status)）。"
            }
            self.objectWillChange.send()
        }
        created.runner.onAppStart = { [weak self, weak created] appID, pid in
            guard let self, let created else { return }
            created.runningAppIDs.insert(appID)
            created.startingAppIDs.remove(appID)
            self.borderOverlay.register(pid: pid, accentHex: environment.resolvedAccentHex)
            self.objectWillChange.send()
        }
        created.runner.onAppExit = { [weak self, weak created] appID, pid, status in
            guard let self, let created else { return }
            created.runningAppIDs.remove(appID)
            created.startingAppIDs.remove(appID)
            self.borderOverlay.unregister(pid: pid)
            if status != 0, let app = self.environments.first(where: { $0.id == id })?.importedApps.first(where: { $0.id == appID }) {
                self.errorMessage = "\(app.name) 已异常退出（退出码 \(status)）。"
            }
            self.objectWillChange.send()
        }
        created.runner.onNetworkFilterApplicationsChanged = { [weak self] in
            self?.synchronizeNetworkFilter()
        }
        sessions[id] = created
        return created
    }

    private var activeSession: EnvironmentSession? {
        guard let selected else { return nil }
        return session(for: selected)
    }

    var allTerminals: [UUID: SandboxTerminal] {
        sessions.mapValues(\.terminal)
    }

    func isEnvironmentRunning(_ id: UUID) -> Bool {
        sessions[id]?.isRunning == true
    }

    func isEnvironmentChromeRunning(_ id: UUID) -> Bool {
        sessions[id]?.isChromeRunning == true
    }

    var isRunning: Bool { activeSession?.isRunning ?? false }
    var isTerminalRunning: Bool { activeSession?.isTerminalRunning ?? false }
    var hasTerminalTab: Bool { activeSession?.hasTerminalTab ?? false }
    var showsTerminal: Bool { activeSession?.showsTerminal ?? false }

    func showApps(closingTerminalTab: Bool = false) {
        activeSession?.showsTerminal = false
        if closingTerminalTab { activeSession?.hasTerminalTab = false }
        objectWillChange.send()
    }

    func showTerminal() {
        activeSession?.hasTerminalTab = true
        activeSession?.showsTerminal = true
        objectWillChange.send()
    }
    var isStarting: Bool { activeSession?.isStarting ?? false }
    var isProxyRunning: Bool { activeSession?.isProxyRunning ?? false }
    var isProxyStarting: Bool { activeSession?.isProxyStarting ?? false }
    var isChromeRunning: Bool { activeSession?.isChromeRunning ?? false }
    var isChromeStarting: Bool { activeSession?.isChromeStarting ?? false }
    var proxyState: String { activeSession?.proxyState ?? "未启动" }
    var resolvedTimeZone: String { activeSession?.resolvedTimeZone ?? (selected?.timeZoneIdentifier ?? "自动") }
    var exitIP: String? { activeSession?.exitIP }
    var inspectedExit: SandboxExit? { activeSession?.inspectedExit }
    var checkReport: ProxyCheckReport? { activeSession?.checkReport }
    var isInspectingExit: Bool { activeSession?.isInspectingExit ?? false }

    func updateTerminalSize(for id: UUID, columns: UInt16, rows: UInt16) {
        sessions[id]?.terminalColumns = columns
        sessions[id]?.terminalRows = rows
    }

    func startDemoIfNeeded() {
        guard demoPending else { return }
        demoPending = false
        showTerminal()
        start(.terminal)
    }

    var selected: SandboxEnvironment? {
        environments.first { $0.id == selectedID }
    }

    func select(_ environment: SandboxEnvironment) {
        selectedID = environment.id
        _ = session(for: environment)
        notice = nil
        refreshNodes()
        objectWillChange.send()
    }

    func refreshNodes() {
        guard let selected else { nodes = []; return }
        do { nodes = try store.nodes(for: selected) }
        catch { nodes = []; errorMessage = "读取可用节点失败：\(error.localizedDescription)" }
    }

    func addEnvironment(name: String, workspace: URL, isolationMode: SandboxIsolationMode) {
        let accent = SandboxEnvironment.nextAccentHex(avoiding: environments.map(\.resolvedAccentHex))
        let environment = SandboxEnvironment(
            name: name, workspace: workspace, isolationMode: isolationMode, accentHex: accent
        )
        do {
            var updated = environments
            updated.append(environment)
            try store.save(updated)
            environments = updated
            _ = session(for: environment)
            select(environment)
            notice = "环境已添加（\(isolationMode.displayName)）"
        } catch { errorMessage = "保存环境失败：\(error.localizedDescription)" }
    }

    func removeSelected() {
        guard let selected else { return }
        let current = session(for: selected)
        guard !current.isRunning, !current.isStarting, !current.isProxyRunning, !current.isProxyStarting else {
            errorMessage = "请先停止该环境的沙箱和代理再移除。"
            return
        }
        do {
            try store.remove(selected)
            sessions.removeValue(forKey: selected.id)
            environments = try store.load()
            selectedID = environments.first?.id
            refreshNodes()
            objectWillChange.send()
        } catch { errorMessage = "删除环境失败：\(error.localizedDescription)" }
    }

    func setNode(_ node: String?) {
        guard let selected else { return }
        let current = session(for: selected)
        guard !current.isProxyRunning, !current.isProxyStarting, !current.isRunning, !current.isStarting else { return }
        var updatedEnv = selected
        guard updatedEnv.node != node else { return }
        updatedEnv.node = node
        current.inspectedExit = nil
        current.checkReport = nil
        current.exitIP = nil
        guard let index = environments.firstIndex(where: { $0.id == updatedEnv.id }) else { return }
        var updated = environments
        updated[index] = updatedEnv
        do { try store.save(updated); environments = updated; objectWillChange.send() }
        catch { errorMessage = "保存节点设置失败：\(error.localizedDescription)" }
    }

    func setTimeZone(_ identifier: String?) {
        guard var selected else { return }
        selected.timeZoneIdentifier = identifier
        let current = session(for: selected)
        if !current.isRunning {
            current.resolvedTimeZone = identifier ?? "自动"
        }
        guard let index = environments.firstIndex(where: { $0.id == selected.id }) else { return }
        var updated = environments
        updated[index] = selected
        do { try store.save(updated); environments = updated; objectWillChange.send() }
        catch { errorMessage = "保存时区设置失败：\(error.localizedDescription)" }
    }

    func importYAML(_ url: URL) {
        guard let selected else { return }
        do {
            let imported = try store.importYAML(url, for: selected)
            applyImportedNodes(imported, for: selected, format: "YAML")
        } catch { errorMessage = "导入 YAML 失败：\(error.localizedDescription)" }
    }

    func importSubscription(_ urlString: String) {
        guard let selected, !isImporting else { return }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            errorMessage = "请输入完整的 HTTP 或 HTTPS 订阅链接。"
            return
        }
        isImporting = true
        Task {
            do {
                let imported = try await store.importSubscription(url, for: selected)
                applyImportedNodes(imported, for: selected, format: "订阅")
            } catch let failure as SandboxFailure {
                errorMessage = failure.message
            } catch {
                // Subscription URLs can contain credentials. Keep them out of alerts and logs.
                errorMessage = "订阅导入失败。请检查链接、网络和订阅内容后重试。"
            }
            isImporting = false
        }
    }

    private func applyImportedNodes(_ imported: [String], for environment: SandboxEnvironment, format: String) {
        do {
            let current = session(for: environment)
            current.inspectedExit = nil
            current.checkReport = nil
            current.exitIP = nil
            let freshNodes = try store.nodes(for: environment)
            if selectedID == environment.id {
                nodes = freshNodes
            }
            var updated = environments
            if let index = updated.firstIndex(where: { $0.id == environment.id }) {
                let oldNode = updated[index].node
                if imported.count == 1 {
                    updated[index].node = imported[0]
                } else if let oldNode, !freshNodes.contains(oldNode) {
                    updated[index].node = nil
                }
                if updated[index].node != oldNode {
                    try store.save(updated)
                    environments = updated
                }
            }
            notice = "已导入\(format)，识别到 \(imported.count) 个节点"
            objectWillChange.send()
        } catch { errorMessage = "导入完成，但读取节点列表失败：\(error.localizedDescription)" }
    }

    func inspectExit() {
        guard let selected else { return }
        let current = session(for: selected)
        guard !current.isRunning, !current.isStarting, !current.isProxyRunning, !current.isProxyStarting, !current.isInspectingExit else { return }
        current.isInspectingExit = true
        current.inspectedExit = nil
        current.checkReport = nil
        objectWillChange.send()
        Task {
            do {
                let exit = try await current.runner.inspectExit(selected)
                current.inspectedExit = exit
                current.checkReport = exit.checkReport
            } catch { errorMessage = "出口检测失败：\(error.localizedDescription)" }
            current.isInspectingExit = false
            objectWillChange.send()
        }
    }

    func startProxy() {
        guard let selected, selected.node != nil else { return }
        let current = session(for: selected)
        guard !current.isProxyRunning, !current.isProxyStarting,
              !current.isRunning, !current.isStarting, !isImporting, !current.isInspectingExit else { return }
        current.isProxyStarting = true
        current.proxyState = "正在启动 mihomo…"
        objectWillChange.send()
        Task {
            do {
                let report = try await current.runner.startProxyOnly(selected)
                current.checkReport = report
                current.isProxyRunning = true
                current.proxyState = "代理已启动 · \(selected.node ?? "节点")"
                if selectedID == selected.id {
                    notice = "代理已启动。现在可以打开沙箱应用。"
                }
            } catch {
                current.runner.stop()
                current.isProxyRunning = false
                current.proxyState = "代理启动失败"
                errorMessage = "代理启动失败：\(error.localizedDescription)"
            }
            current.isProxyStarting = false
            objectWillChange.send()
        }
    }

    func stopProxy() {
        guard let selected else { return }
        let current = session(for: selected)
        guard !current.isRunning, !current.isStarting, !current.isProxyStarting else { return }
        current.runner.stopProxyOnly()
        current.isProxyRunning = false
        current.proxyState = "代理已停止"
        objectWillChange.send()
    }

    func stopChrome() {
        guard let selected else { return }
        let current = session(for: selected)
        if let pid = current.runner.browserProcessIdentifier {
            borderOverlay.unregister(pid: pid)
        }
        current.runner.stopChrome()
        current.isChromeRunning = false
        objectWillChange.send()
    }

    func start(_ target: SandboxLaunchTarget = .session) {
        guard let selected else { return }
        let current = session(for: selected)

        switch target {
        case .session, .terminal:
            break
        case .chrome:
            if let pid = current.runner.browserProcessIdentifier {
                NSRunningApplication(processIdentifier: pid)?.activate()
                return
            }
            guard !current.isChromeStarting else { return }
        case .imported(let app):
            if let pid = current.runner.appProcessIdentifier(for: app.id) {
                NSRunningApplication(processIdentifier: pid)?.activate()
                return
            }
            guard !current.startingAppIDs.contains(app.id) else { return }
        }
        guard !current.isStarting, !current.isProxyStarting, !isImporting, !current.isInspectingExit else { return }

        switch target {
        case .session, .terminal:
            break
        case .chrome, .imported:
            guard selected.node != nil else {
                errorMessage = "请先在左侧导入并选择代理节点，再打开沙箱应用。"
                return
            }
        }

        let needsSession = !current.isRunning
        if needsSession {
            current.isStarting = true
            current.inspectedExit = nil
            current.checkReport = nil
            current.exitIP = nil
            current.proxyState = selected.node == nil ? "正在启动 Seatbelt…" : "正在启动 mihomo 并检测代理环境…"
        }
        switch target {
        case .session, .terminal: break
        case .chrome: current.isChromeStarting = true
        case .imported(let app): current.startingAppIDs.insert(app.id)
        }
        objectWillChange.send()

        Task {
            defer {
                switch target {
                case .session, .terminal: break
                case .chrome: current.isChromeStarting = false
                case .imported(let app): current.startingAppIDs.remove(app.id)
                }
                objectWillChange.send()
            }

            if needsSession {
                do {
                    let launch = try await current.runner.start(selected)
                    current.launch = launch
                    current.isProxyRunning = launch.endpoint != nil
                    current.resolvedTimeZone = launch.timeZoneIdentifier
                    current.exitIP = launch.exitIP
                    current.checkReport = launch.checkReport
                    if let endpoint = launch.endpoint {
                        let ipText = launch.exitIP.map { " · 出口 \($0)" } ?? ""
                        let fallback = selected.timeZoneIdentifier == nil && launch.exitIP == nil ? " · 时区暂用本机值" : ""
                        current.proxyState = "Seatbelt · mihomo \(endpoint) · \(launch.timeZoneIdentifier)\(ipText)\(fallback)"
                    } else {
                        current.proxyState = "Seatbelt · 已断网"
                    }
                } catch {
                    current.runner.stop()
                    current.isProxyRunning = false
                    current.proxyState = "启动失败"
                    if !(error is CancellationError) {
                        errorMessage = "启动沙箱失败：\(error.localizedDescription)"
                    }
                }
                current.isStarting = false
                objectWillChange.send()
            }

            guard let launch = current.launch else { return }
            do {
                switch target {
                case .session:
                    break
                case .terminal:
                    guard !current.isTerminalRunning else { return }
                    try current.terminal.start(launch, columns: current.terminalColumns, rows: current.terminalRows)
                    current.isTerminalRunning = true
                case .chrome:
                    try await current.runner.startChrome()
                case .imported(let app):
                    try await current.runner.startImportedApp(app)
                }
                if selectedID == selected.id { notice = nil }
            } catch is CancellationError {
                return
            } catch {
                let name: String
                switch target {
                case .session: name = "沙箱"
                case .terminal: name = "终端"
                case .chrome: name = "Chrome"
                case .imported(let app): name = app.name
                }
                errorMessage = "启动 \(name) 失败：\(error.localizedDescription)"
            }
        }
    }

    func toggleNetworkFilter() {
        guard !networkFilter.status.isBusy else { return }
        Task {
            do {
                if networkFilter.status == .active {
                    try await networkFilter.disable()
                } else {
                    await networkFilter.updateApplications(sessions.values.flatMap(\.runner.networkFilterApplications))
                    try await networkFilter.enable()
                    synchronizeNetworkFilter()
                }
                notice = networkFilter.status == .active
                    ? "系统网络防护已接管 CCBox 应用直连拦截"
                    : "系统网络防护已关闭，Seatbelt 仍然有效"
            } catch {
                errorMessage = "系统网络防护操作失败：\(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    private func synchronizeNetworkFilter() {
        let applications = sessions.values.flatMap(\.runner.networkFilterApplications)
        Task { await networkFilter.updateApplications(applications) }
    }

    func isAppRunning(_ appID: UUID) -> Bool {
        activeSession?.runningAppIDs.contains(appID) == true
    }

    func isAppStarting(_ appID: UUID) -> Bool {
        activeSession?.startingAppIDs.contains(appID) == true
    }

    func importApp(_ url: URL, for environmentID: UUID) {
        guard !isImporting, let index = environments.firstIndex(where: { $0.id == environmentID }) else { return }
        let environment = environments[index]
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard standardized.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: standardized), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            errorMessage = "请选择包含有效可执行文件的 macOS .app。"
            return
        }
        if bundle.bundleIdentifier == "com.google.Chrome" {
            notice = "可以直接使用首页的 Chrome 入口"
            return
        }
        if environment.importedApps.contains(where: {
            $0.bundlePath == standardized.path || $0.sourceBundlePath == standardized.path
        }) {
            notice = "该应用已在当前环境列表中"
            return
        }
        let appName = standardized.deletingPathExtension().lastPathComponent
        let store = self.store
        isImporting = true
        importingAppName = appName
        notice = "正在完整复制应用「\(appName)」到当前环境…"
        Task {
            var copiedApp: SandboxImportedApp?
            var saved = false
            defer {
                if let copiedApp, !saved {
                    store.removeImportedAppCopy(copiedApp, for: environment)
                }
                isImporting = false
                importingAppName = nil
            }
            do {
                let copied = try await Task.detached {
                    try store.importApp(at: standardized, for: environment)
                }.value
                copiedApp = copied
                guard let currentIndex = environments.firstIndex(where: { $0.id == environmentID }) else { return }
                var current = environments[currentIndex]
                if current.importedApps.contains(where: {
                    $0.bundlePath == standardized.path || $0.sourceBundlePath == standardized.path
                }) {
                    notice = "该应用已在当前环境列表中"
                    return
                }
                current.importedApps.append(copied)
                var updated = environments
                updated[currentIndex] = current
                try store.save(updated)
                environments = updated
                session(for: current).runner.updateImportedApps(current.importedApps)
                saved = true
                notice = "已完整复制并导入应用「\(appName)」，原应用卸载后仍可运行"
                objectWillChange.send()
            } catch {
                errorMessage = "导入应用失败：\(error.localizedDescription)"
            }
        }
    }

    func removeImportedApp(_ app: SandboxImportedApp) {
        guard var selected, !isAppStarting(app.id) else { return }
        selected.importedApps.removeAll { $0.id == app.id }
        guard let index = environments.firstIndex(where: { $0.id == selected.id }) else { return }
        var updated = environments
        updated[index] = selected
        do {
            try store.save(updated)
            stopImportedApp(app)
            store.removeImportedAppCopy(app, for: selected)
            environments = updated
            session(for: selected).runner.updateImportedApps(selected.importedApps)
        } catch {
            errorMessage = "移除应用失败：\(error.localizedDescription)"
        }
    }

    func stopImportedApp(_ app: SandboxImportedApp) {
        guard let selected else { return }
        let current = session(for: selected)
        if let pid = current.runner.appProcessIdentifier(for: app.id) {
            borderOverlay.unregister(pid: pid)
        }
        current.runner.stopImportedApp(app.id)
        current.runningAppIDs.remove(app.id)
        current.startingAppIDs.remove(app.id)
        objectWillChange.send()
    }

    func stop() {
        guard let selected else { return }
        let current = session(for: selected)
        if let pid = current.runner.browserProcessIdentifier {
            borderOverlay.unregister(pid: pid)
        }
        for pid in current.runner.runningImportedAppPIDs {
            borderOverlay.unregister(pid: pid)
        }
        current.terminal.stop()
        current.runner.stop()
        current.launch = nil
        current.isProxyRunning = false
        current.isChromeRunning = false
        current.runningAppIDs.removeAll()
        current.startingAppIDs.removeAll()
        current.proxyState = "已停止"
        objectWillChange.send()
    }

    func stopAll() {
        borderOverlay.stopAll()
        for current in sessions.values {
            current.terminal.stop()
            current.runner.stop()
            current.launch = nil
            current.isProxyRunning = false
            current.isChromeRunning = false
            current.runningAppIDs.removeAll()
            current.startingAppIDs.removeAll()
            current.proxyState = "已停止"
        }
        objectWillChange.send()
    }
}

struct MainView: View {
    @StateObject private var model = DashboardModel()
    @State private var showingAddEnvironment = false
    @State private var showingYAMLImporter = false
    @State private var showingSubscriptionImport = false
    @State private var showingRemoveConfirmation = false
    @State private var showingCheckPopover = false
    @State private var noProxyStart: NoProxyStart?
    @State private var showingNoProxyConfirmation = false

    private struct NoProxyStart {
        let environmentID: UUID
        let target: SandboxLaunchTarget
    }

    private var launchBlocked: Bool {
        model.isStarting || model.isProxyStarting || model.isImporting || model.isInspectingExit
    }
    @State private var scrollToLatestRequest = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane.frame(width: 296)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                if model.hasTerminalTab {
                    workspaceTabs
                    Divider()
                }
                ZStack {
                    applicationsPane
                        .opacity(model.showsTerminal ? 0 : 1)
                        .allowsHitTesting(!model.showsTerminal)
                        .accessibilityHidden(model.showsTerminal)
                    terminalPane
                        .opacity(model.showsTerminal ? 1 : 0)
                        .allowsHitTesting(model.showsTerminal)
                        .accessibilityHidden(!model.showsTerminal)
                }
            }
        }
        .background(Color(red: 0.055, green: 0.065, blue: 0.08))
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showingYAMLImporter, allowedContentTypes: [.yaml, .plainText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let accessed = url.startAccessingSecurityScopedResource()
                model.importYAML(url)
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
        }
        .sheet(isPresented: $showingAddEnvironment) {
            AddEnvironmentSheet { name, workspace, isolationMode in
                model.addEnvironment(name: name, workspace: workspace, isolationMode: isolationMode)
            }
        }
        .sheet(isPresented: $showingSubscriptionImport) {
            SubscriptionImportSheet { url in model.importSubscription(url) }
        }
        .alert("操作提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("移除此环境？", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            Button(model.selected?.isolationMode == .hostPassthrough ? "删除环境配置" : "删除环境及沙箱副本", role: .destructive) {
                model.removeSelected()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(model.selected?.isolationMode == .hostPassthrough
                 ? "将删除环境配置、节点、独立的 Claude/Chrome 会话数据。你选的原项目目录完全保留。"
                 : "将删除环境配置、节点和沙箱内的项目副本。你选的原项目会保留。")
        }
        .confirmationDialog("当前未启用代理", isPresented: $showingNoProxyConfirmation, titleVisibility: .visible) {
            Button("仍要无代理启动（断网）", role: .destructive) {
                if let request = noProxyStart, request.environmentID == model.selectedID {
                    model.start(request.target)
                }
                noProxyStart = nil
            }
            Button("取消", role: .cancel) { noProxyStart = nil }
        } message: {
            Text("当前环境尚未选择代理节点。继续启动后，终端将处于断网状态。Chrome 和导入的应用需要代理节点才能启动。")
        }
        .onDisappear { model.stopAll() }
        .task { model.startDemoIfNeeded() }
    }

    private func triggerStart(_ target: SandboxLaunchTarget = .session) {
        guard let environment = model.selected else { return }
        if environment.node == nil && !model.isRunning {
            noProxyStart = NoProxyStart(environmentID: environment.id, target: target)
            showingNoProxyConfirmation = true
        } else {
            model.start(target)
        }
    }

    private func openApplicationPicker() {
        guard let environmentID = model.selectedID else { return }
        let panel = NSOpenPanel()
        panel.title = "导入应用"
        panel.prompt = "导入"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importApp(url, for: environmentID)
        }
    }

    // MARK: - Right Workspace

    private var topBar: some View {
        HStack(spacing: 12) {
            if let selected = model.selected {
                HStack(spacing: 9) {
                    Circle()
                        .fill(Color(hex: selected.resolvedAccentHex))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(selected.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(selected.isolationMode.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(selected.isolationMode == .hostPassthrough ? Color.orange.opacity(0.18) : Color.cyan.opacity(0.16))
                                .foregroundStyle(selected.isolationMode == .hostPassthrough ? Color.orange : Color.cyan)
                                .clipShape(Capsule())
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([selected.workspace])
                        } label: {
                            Text(selected.isolationMode == .hostPassthrough ? selected.workspace.path : "/workspace  ←  \(selected.workspace.lastPathComponent)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示原项目目录")
                    }
                }
            } else {
                Text("选择或新建工作环境").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let report = model.checkReport {
                checkReportBadge(report)
            }

            networkFilterButton
            statusPill

            Button {
                model.isRunning ? model.stop() : triggerStart()
            } label: {
                Label(
                    model.isStarting ? "启动中…" : (model.isRunning ? "停止会话" : "启动沙箱"),
                    systemImage: model.isRunning ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? Color(red: 0.72, green: 0.25, blue: 0.25) : Color(red: 0.14, green: 0.50, blue: 0.78))
            .disabled(model.selected == nil || launchBlocked)
            .accessibilityIdentifier("startSandboxButton")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Color(red: 0.065, green: 0.075, blue: 0.095))
    }

    private var networkFilterButton: some View {
        let active = model.networkFilter.status == .active
        let failed: Bool
        if case .failed = model.networkFilter.status { failed = true } else { failed = false }
        let color: Color = active ? .green : (failed ? .red : .secondary)
        return Button {
            model.toggleNetworkFilter()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: active ? "shield.checkered" : "shield")
                Text(active ? "防护已启用" : (failed ? "防护异常" : "系统防护"))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.networkFilter.status.isBusy)
        .help(model.networkFilter.status.title)
        .accessibilityIdentifier("networkFilterButton")
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? Color.green : (model.isStarting ? Color.orange : Color.gray.opacity(0.6)))
                .frame(width: 7, height: 7)
            Text(compactStatusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.isRunning ? .white.opacity(0.85) : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045))
        .clipShape(Capsule())
    }

    private var compactStatusText: String {
        if model.isStarting { return "启动与检测中…" }
        if !model.isRunning { return model.selected?.node == nil ? "未选节点" : "未启动" }
        if !model.isProxyRunning { return "已断网" }
        if let ip = model.exitIP {
            return "\(ip) · \(model.resolvedTimeZone)"
        }
        return "代理就绪 · \(model.resolvedTimeZone)"
    }

    private func checkReportBadge(_ report: ProxyCheckReport) -> some View {
        let badgeColor: Color = report.allPassed ? .green : (report.hasFailure ? .red : .orange)
        let iconName = report.allPassed ? "checkmark.shield.fill" : (report.hasFailure ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
        let titleText = report.allPassed
            ? "环境检测通过 \(report.passedCount)/\(report.totalCount)"
            : (report.hasFailure ? "检测异常 \(report.passedCount)/\(report.totalCount)" : "环境检测 \(report.passedCount)/\(report.totalCount)")
        return Button {
            showingCheckPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(titleText)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badgeColor.opacity(0.14))
            .overlay(Capsule().stroke(badgeColor.opacity(0.35), lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("点击查看完整代理环境检测报告")
        .popover(isPresented: $showingCheckPopover, arrowEdge: .bottom) {
            ProxyCheckPopoverView(report: report)
        }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 6) {
            Button {
                model.showApps()
            } label: {
                Label("应用", systemImage: "square.grid.2x2")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(!model.showsTerminal ? Color.white.opacity(0.10) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("applicationsTab")

            HStack(spacing: 8) {
                Button {
                    model.showTerminal()
                } label: {
                    Label("终端", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminalTab")

                Button {
                    model.showApps(closingTerminalTab: true)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭标签页，终端继续在后台运行")
                .accessibilityLabel("关闭终端标签页")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.showsTerminal ? Color.white.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(red: 0.065, green: 0.075, blue: 0.095))
    }

    private var applicationsPane: some View {
        Group {
            if let environment = model.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("应用").font(.system(size: 23, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 164), spacing: 14)], alignment: .leading, spacing: 14) {
                            appTile("终端", running: model.isTerminalRunning, identifier: "terminalAppButton") {
                                model.showTerminal()
                                if !model.isTerminalRunning && !launchBlocked { triggerStart(.terminal) }
                            } icon: {
                                Image(systemName: "terminal")
                                    .font(.system(size: 27, weight: .medium))
                                    .foregroundStyle(.cyan)
                                    .frame(width: 48, height: 48)
                            }

                            appTile("Chrome", running: model.isChromeRunning, starting: model.isChromeStarting,
                                    identifier: "toggleChromeButton") {
                                model.start(.chrome)
                            } icon: {
                                bundleIcon(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")?.path,
                                           fallback: "globe")
                            }
                            .disabled(model.isChromeStarting || (launchBlocked && !model.isChromeRunning))
                            .contextMenu {
                                if model.isChromeRunning {
                                    Button("关闭 Chrome") { model.stopChrome() }
                                }
                            }

                            ForEach(environment.importedApps) { app in
                                let running = model.isAppRunning(app.id)
                                let starting = model.isAppStarting(app.id)
                                appTile(app.name, running: running, starting: starting, identifier: app.id.uuidString) {
                                    model.start(.imported(app))
                                } icon: {
                                    bundleIcon(app.bundlePath)
                                }
                                .disabled(starting || (launchBlocked && !running))
                                .contextMenu {
                                    if running {
                                        Button("关闭应用") { model.stopImportedApp(app) }
                                    }
                                    Button("从环境移除", role: .destructive) { model.removeImportedApp(app) }
                                        .disabled(starting)
                                }
                            }

                            appTile("导入应用", identifier: "importAppButton", action: openApplicationPicker) {
                                Image(systemName: "plus")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, height: 48)
                            }
                            .disabled(model.isImporting)
                        }
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Text("还没有工作环境").font(.system(size: 15, weight: .semibold))
                    Button {
                        showingAddEnvironment = true
                    } label: {
                        Label("新建工作环境", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appTile<Icon: View>(
        _ title: String, running: Bool = false, starting: Bool = false, identifier: String,
        action: @escaping () -> Void, @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 102)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)))
            .overlay(alignment: .topTrailing) {
                if starting {
                    ProgressView().controlSize(.small).padding(8)
                } else if running {
                    Circle().fill(Color.green).frame(width: 6, height: 6).padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(starting ? "启动中" : (running ? "运行中" : ""))
    }

    @ViewBuilder
    private func bundleIcon(_ path: String?, fallback: String = "app") -> some View {
        if let path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().scaledToFit().frame(width: 48, height: 48)
        } else {
            Image(systemName: fallback).font(.system(size: 27)).frame(width: 48, height: 48)
        }
    }

    private var terminalPane: some View {
        VStack(spacing: 0) {
            NativeTerminalView(
                environmentID: model.showsTerminal ? model.selectedID : nil,
                terminals: model.allTerminals,
                validEnvironmentIDs: Set(model.environments.map(\.id)),
                sessionActive: model.showsTerminal && model.isRunning && model.isTerminalRunning,
                scrollToLatestRequest: scrollToLatestRequest
            ) { id, columns, rows in
                model.updateTerminalSize(for: id, columns: columns, rows: rows)
            }
            .background(Color(red: 0.035, green: 0.04, blue: 0.05))
            .overlay {
                if model.showsTerminal && (!model.isRunning || !model.isTerminalRunning) {
                    VStack(spacing: 12) {
                        if model.isStarting {
                            ProgressView()
                            Text("正在启动沙箱会话").font(.system(size: 13, weight: .medium))
                        } else {
                            Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(.cyan)
                            Button("启动终端") { triggerStart(.terminal) }
                                .buttonStyle(.borderedProminent)
                                .disabled(launchBlocked)
                        }
                    }
                    .padding(26)
                    .background(Color(red: 0.06, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            HStack(spacing: 12) {
                Text("macOS Seatbelt · xterm.js")
                Text("·")
                Text(model.selected?.node.map { "节点：\($0)" } ?? "未选节点（断网）")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isRunning && model.isTerminalRunning {
                    Button("回到底部") { scrollToLatestRequest += 1 }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.42))
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(Color(red: 0.06, green: 0.07, blue: 0.088))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left Sidebar

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("ccbox")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button { showingAddEnvironment = true } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.88))
                .disabled(model.isImporting)
                .help("新建工作环境")
                .accessibilityIdentifier("addEnvironmentButton")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    environmentListSection

                    if model.selected != nil {
                        proxyAndNetworkSection
                        environmentFooterSection
                    }

                    if let notice = model.notice {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green.opacity(0.85))
                                .font(.system(size: 11))
                            Text(notice)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.green.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.068, green: 0.078, blue: 0.098))
    }

    private var environmentListSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("工作环境")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if model.environments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("暂无环境").font(.system(size: 11.5, weight: .medium))
                    Text("点击右上角「新建」添加你的项目目录。").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                VStack(spacing: 4) {
                    ForEach(model.environments) { environment in
                        let isSelected = model.selectedID == environment.id
                        let running = model.isEnvironmentRunning(environment.id)
                        let chromeOpen = model.isEnvironmentChromeRunning(environment.id)
                        Button { model.select(environment) } label: {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(Color(hex: environment.resolvedAccentHex))
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(environment.name)
                                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                            .lineLimit(1)
                                        Text(environment.isolationMode == .hostPassthrough ? "直通" : "隔离")
                                            .font(.system(size: 8.5, weight: .semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                                            .background(environment.isolationMode == .hostPassthrough ? Color.orange.opacity(0.16) : Color.cyan.opacity(0.14))
                                            .foregroundStyle(environment.isolationMode == .hostPassthrough ? Color.orange : Color.cyan)
                                            .clipShape(Capsule())
                                    }
                                    Text(environment.workspace.path)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                if chromeOpen {
                                    Image(systemName: "globe")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(hex: environment.resolvedAccentHex))
                                }
                                if running {
                                    Circle().fill(Color.green).frame(width: 6.5, height: 6.5)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.white.opacity(0.09) : Color.white.opacity(0.02))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color(hex: environment.resolvedAccentHex).opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var proxyAndNetworkSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("代理与时区")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 11) {
                // Step 1: Import nodes
                HStack(spacing: 7) {
                    Button { showingSubscriptionImport = true } label: {
                        Label("导入订阅", systemImage: "link")
                            .font(.system(size: 10.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(model.nodes.isEmpty ? Color.cyan.opacity(0.16) : Color.white.opacity(0.05))
                            .foregroundStyle(model.nodes.isEmpty ? Color.cyan : .white.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isImporting || model.isRunning || model.isStarting || model.isProxyRunning)
                    .accessibilityIdentifier("importSubscriptionButton")

                    Button { showingYAMLImporter = true } label: {
                        Label("导入 YAML", systemImage: "doc.badge.arrow.down")
                            .font(.system(size: 10.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.05))
                            .foregroundStyle(.white.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isImporting || model.isRunning || model.isStarting || model.isProxyRunning)
                    .accessibilityIdentifier("importYAMLButton")
                }

                if model.isImporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.importingAppName.map { "正在完整复制应用「\($0)」…" } ?? "正在导入节点…")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                Divider().overlay(Color.white.opacity(0.07))

                // Step 2: Select node & inspect exit
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("代理节点", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button { model.refreshNodes() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("重新扫描节点")
                        .disabled(model.isImporting)
                    }

                    HStack(spacing: 6) {
                        NodeSelector(selection: Binding(get: { model.selected?.node }, set: { model.setNode($0) }), nodes: model.nodes)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .disabled(model.isRunning || model.isStarting || model.isProxyRunning || model.isProxyStarting)

                        Button { model.inspectExit() } label: {
                            if model.isInspectingExit {
                                ProgressView().controlSize(.small).frame(width: 48, height: 24)
                            } else {
                                Text("测出口")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                            }
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(model.selected?.node == nil || model.isRunning || model.isStarting || model.isProxyRunning || model.isInspectingExit || model.isImporting)
                        .help("测试当前所选节点的出口 IP、城市和时区")
                        .accessibilityIdentifier("inspectExitButton")
                    }
                }

                if let report = model.checkReport {
                    ProxyCheckSidebarCard(report: report)
                } else if let exit = model.inspectedExit {
                    VStack(alignment: .leading, spacing: 3) {
                        if let ip = exit.ip {
                            Text("出口 IP：\(ip)").font(.system(size: 10, design: .monospaced))
                        }
                        let detail = [exit.city, exit.country, exit.timeZoneIdentifier]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider().overlay(Color.white.opacity(0.07))

                // Step 3: Timezone
                HStack {
                    Label("时区", systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    TimeZoneSelector(selection: Binding(get: { model.selected?.timeZoneIdentifier }, set: { model.setTimeZone($0) }))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.045))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(model.isRunning || model.isStarting)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private var environmentFooterSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("环境设置")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 9) {
                if let selected = model.selected {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10.5)).foregroundStyle(.blue)
                        Text(selected.workspace.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([selected.workspace])
                        } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("在 Finder 中打开目录")
                    }

                    Text(selected.isolationMode.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().overlay(Color.white.opacity(0.07))
                }

                Button(role: .destructive) { showingRemoveConfirmation = true } label: {
                    Label("移除此环境", systemImage: "trash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(model.selected == nil || model.isRunning || model.isStarting || model.isProxyRunning || model.isProxyStarting || model.isImporting || model.isInspectingExit)
                .accessibilityIdentifier("removeEnvironmentButton")
            }
            .padding(12)
            .background(Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct NodeSelector: View {
    @Binding var selection: String?
    let nodes: [String]
    @State private var isPresented = false
    @State private var query = ""

    private var matches: [String] {
        let sorted = nodes.sorted()
        if query.isEmpty {
            let suggested = Array(sorted.prefix(20))
            if let selection { return [selection] + suggested.filter { $0 != selection } }
            return suggested
        }
        let filtered = sorted.filter { $0.localizedCaseInsensitiveContains(query) }
        guard let selection, !filtered.contains(selection) else { return filtered }
        return [selection] + filtered
    }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 5) {
                Text(selection ?? (nodes.isEmpty ? "先导入节点" : "选择节点"))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, design: .monospaced))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(nodes.isEmpty)
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(spacing: 8) {
                TextField("搜索 \(nodes.count) 个节点", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    selection = nil
                    query = ""
                    isPresented = false
                } label: {
                    selectionRow(title: "默认节点", isSelected: selection == nil)
                }.buttonStyle(.plain)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches, id: \.self) { node in
                            Button {
                                selection = node
                                query = ""
                                isPresented = false
                            } label: {
                                selectionRow(title: node, isSelected: selection == node)
                            }.buttonStyle(.plain)
                        }
                        if matches.isEmpty {
                            Text("没有匹配的节点").font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 270, height: 300)
        }
        .accessibilityIdentifier("nodeSelector")
    }

    private func selectionRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if isSelected { Image(systemName: "checkmark").foregroundStyle(.cyan) }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.cyan.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct TimeZoneSelector: View {
    @Binding var selection: String?
    @State private var isPresented = false
    @State private var query = ""

    private var matches: [String] {
        let zones = TimeZone.knownTimeZoneIdentifiers
        let common = ["UTC", "Asia/Shanghai", "Asia/Tokyo", "America/Los_Angeles", "America/New_York", "Europe/London"]
        var candidates = [selection, "UTC"].compactMap { $0 } + common + zones
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }
        if query.isEmpty { return Array(candidates.prefix(common.count + (selection == nil ? 0 : 1))) }
        let filtered = candidates.filter { $0.localizedCaseInsensitiveContains(query) }
        guard let selection, !filtered.contains(selection) else { return filtered }
        return [selection] + filtered
    }

    private var label: String { selection ?? "自动 · 跟随节点" }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 5) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, design: .monospaced))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(spacing: 8) {
                TextField("搜索 IANA 时区", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    selection = nil
                    query = ""
                    isPresented = false
                } label: {
                    selectionRow(title: "自动 · 跟随节点", isSelected: selection == nil)
                }.buttonStyle(.plain)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches, id: \.self) { identifier in
                            Button {
                                selection = identifier
                                query = ""
                                isPresented = false
                            } label: {
                                selectionRow(title: identifier, isSelected: selection == identifier)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 270, height: 300)
        }
        .accessibilityIdentifier("timeZoneSelector")
    }

    private func selectionRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if isSelected { Image(systemName: "checkmark").foregroundStyle(.cyan) }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.cyan.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct SubscriptionImportSheet: View {
    var onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptionURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入订阅").font(.system(size: 17, weight: .semibold))
            Text("粘贴 Clash 或 mihomo 订阅链接。应用只保存解析后的节点。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("https://…", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            HStack {
                Spacer()
                Button("取消") { subscriptionURL = ""; dismiss() }
                Button("导入节点") {
                    let value = subscriptionURL
                    subscriptionURL = ""
                    onImport(value)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private struct AddEnvironmentSheet: View {
    var onAdd: (String, URL, SandboxIsolationMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var workspace: URL?
    @State private var isolationMode: SandboxIsolationMode = .hostPassthrough
    @State private var chooseFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加工作环境").font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                Text("环境名称").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("例如：my-project", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("运行模式").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Picker("运行模式", selection: $isolationMode) {
                    Text("本机直通").tag(SandboxIsolationMode.hostPassthrough)
                    Text("纯隔离").tag(SandboxIsolationMode.isolated)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(isolationMode.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("工作目录").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack {
                    Text(workspace?.path ?? "请选择项目文件夹").font(.system(size: 11, design: .monospaced)).foregroundStyle(workspace == nil ? .secondary : .primary).lineLimit(1)
                    Spacer()
                    Button("选择…") { chooseFolder = true }
                }.padding(10).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    guard let workspace else { return }
                    onAdd(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? workspace.lastPathComponent : name,
                        workspace,
                        isolationMode
                    )
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(workspace == nil)
            }
        }.padding(22).frame(width: 440)
            .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { workspace = urls.first }
            }
    }
}

private extension UTType {
    static let yaml = UTType(filenameExtension: "yaml") ?? .plainText
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            self = .blue
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

