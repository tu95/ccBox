import CCBoxNetworkFilterCore
import Darwin
import Foundation

public struct SandboxLaunch {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let workingDirectory: String
    public let endpoint: String?
    public let timeZoneIdentifier: String
    public let exitIP: String?
    public let checkReport: ProxyCheckReport?

    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String,
        endpoint: String?,
        timeZoneIdentifier: String,
        exitIP: String?,
        checkReport: ProxyCheckReport? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.endpoint = endpoint
        self.timeZoneIdentifier = timeZoneIdentifier
        self.exitIP = exitIP
        self.checkReport = checkReport
    }
}

public struct SandboxExit {
    public let ip: String?
    public let timeZoneIdentifier: String?
    public let country: String?
    public let city: String?
    public let checkReport: ProxyCheckReport?

    public init(
        ip: String?,
        timeZoneIdentifier: String?,
        country: String?,
        city: String?,
        checkReport: ProxyCheckReport? = nil
    ) {
        self.ip = ip
        self.timeZoneIdentifier = timeZoneIdentifier
        self.country = country
        self.city = city
        self.checkReport = checkReport
    }
}

@MainActor
public final class SandboxRunner {
    public var onProxyExit: (() -> Void)?
    public var onBrowserStart: ((pid_t) -> Void)?
    public var onBrowserExit: ((pid_t, Int32) -> Void)?
    public var onAppStart: ((UUID, pid_t) -> Void)?
    public var onAppExit: ((UUID, pid_t, Int32) -> Void)?
    public var onNetworkFilterApplicationsChanged: (() -> Void)?
    public var browserProcessIdentifier: pid_t? { browser?.processIdentifier }
    public func appProcessIdentifier(for appID: UUID) -> pid_t? { importedAppProcesses[appID]?.processIdentifier }
    public var runningImportedAppPIDs: [pid_t] { importedAppProcesses.values.map(\.processIdentifier) }

    private let store: SandboxStore
    private var proxy: Process?
    private var browser: Process?
    private var importedAppProcesses: [UUID: Process] = [:]
    private var importedAppCopying: Set<UUID> = []
    private var browserBridge: BrowserBridge?
    private var browserOpenTask: Task<Void, Never>?
    private var runtime: URL?
    private var sessionID: UUID?
    private var activeEnvironmentID: UUID?
    private var activeEnvironmentFolder: URL?
    private var activeWorkspace: URL?
    private var activeSourceWorkspace: URL?
    private var activeSandboxExec: String?
    private var activeProxyLaunch: ProxyLaunch?
    private var activeSandboxConfig: URL?
    private var activeBrowserProfile: URL?
    private var activeBrowserHome: URL?
    private var activeToolEnvironment: [String: String]?
    private var activeTimeZone: String?
    private var activeEnvironmentName: String?
    private var activeAccentHex: String = "#3B82F6"
    private var activeImportedApps: [SandboxImportedApp] = []
    private var chromePreparation: Task<URL, Error>?
    private var ready = false

    public var networkFilterApplications: [NetworkFilterApplication] {
        guard ready, activeSandboxExec != nil, let environmentID = activeEnvironmentID,
              let proxyLaunch = activeProxyLaunch else { return [] }
        var ports: Set<Int> = [Int(proxyLaunch.httpPort), Int(proxyLaunch.socksPort)]
        if let bridgePort = browserBridge?.port { ports.insert(Int(bridgePort)) }
        var applications = [NetworkFilterApplication(
            bundlePath: store.root.appendingPathComponent("Runtime/Google Chrome.app", isDirectory: true).path,
            allowedLoopbackPorts: ports
        )]
        applications.append(contentsOf: activeImportedApps.map { app in
            let bundle: URL
            if app.sourceBundlePath != nil {
                bundle = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
            } else {
                let stored = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
                bundle = store.root
                    .appendingPathComponent(environmentID.uuidString, isDirectory: true)
                    .appendingPathComponent("ImportedApps/\(app.id.uuidString)/\(stored.lastPathComponent)", isDirectory: true)
            }
            return NetworkFilterApplication(bundlePath: bundle.path, allowedLoopbackPorts: ports)
        })
        return applications
    }

    public func updateImportedApps(_ apps: [SandboxImportedApp]) {
        activeImportedApps = apps
        onNetworkFilterApplicationsChanged?()
    }

    public init(store: SandboxStore) {
        self.store = store
    }

    public func start(_ environment: SandboxEnvironment) async throws -> SandboxLaunch {
        guard sessionID == nil else { throw SandboxFailure("已有环境正在运行。") }
        let source = environment.workspace.standardizedFileURL.resolvingSymlinksInPath()
        let node = try environment.node.map { name in
            guard let node = try store.loadNodes(for: environment).first(where: { $0.name == name }) else {
                throw SandboxFailure("所选节点不可用，请重新选择。")
            }
            return node
        }
        if let identifier = environment.timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            throw SandboxFailure("请选择有效的 IANA 时区。")
        }
        let token = UUID()
        sessionID = token

        do {
            let store = self.store
            let environmentID = environment.id
            let workspace = try await Task.detached {
                try store.prepareWorkspace(for: environmentID, source: source)
            }.value
            try ensureSession(token)
            let tools = try ToolPaths.discover(workspace: workspace, needsProxy: node != nil)
            let launch = try await prepare(
                environment, workspace: workspace, source: source, tools: tools, node: node, token: token
            )
            try ensureSession(token)
            ready = true
            onNetworkFilterApplicationsChanged?()
            return launch
        } catch {
            if sessionID == token { stop() }
            throw error
        }
    }

    public var isProxyRunning: Bool { proxy?.isRunning == true }

    public func startProxyOnly(_ environment: SandboxEnvironment) async throws -> ProxyCheckReport {
        guard sessionID == nil, proxy == nil else { throw SandboxFailure("已有代理或会话正在运行。") }
        guard let node = try store.loadNodes(for: environment).first(where: { $0.name == environment.node }) else {
            throw SandboxFailure("请先导入 YAML 或订阅，并选择一个代理节点。")
        }
        let (mihomo, toolEnvironment) = try ToolPaths.proxyOnly()
        let token = UUID()
        sessionID = token
        do {
            let runDirectory = try makeSessionDirectory()
            runtime = runDirectory
            let launch = try makeProxyLaunch(node: node, runtime: runDirectory)
            try await validateProxy(mihomo, environment: toolEnvironment, launch: launch, runtime: runDirectory)
            try ensureSession(token)
            let process = try startProxy(mihomo, environment: toolEnvironment, launch: launch, runtime: runDirectory)
            let pinnedTimeZone = environment.timeZoneIdentifier
            let report = try await Task.detached { () -> ProxyCheckReport in
                try waitForLocalProxy(ports: [launch.httpPort, launch.socksPort])
                let exitInfo = try? lookupDetailedExit(through: launch)
                let tz = pinnedTimeZone ?? exitInfo?.timezone ?? TimeZone.current.identifier
                return runProxyPreFlightChecks(
                    proxyEndpoint: launch.endpoint,
                    sandboxProfile: nil,
                    sandboxExec: nil,
                    sandboxEnv: nil,
                    resolvedTimeZone: tz,
                    exitInfo: exitInfo
                )
            }.value
            try ensureSession(token)
            guard process.isRunning else { throw SandboxFailure("mihomo 启动后退出了。") }
            activeEnvironmentID = environment.id
            activeProxyLaunch = launch
            ready = true
            sessionID = nil
            return report
        } catch {
            if sessionID == token { stop() }
            throw error
        }
    }

    public func stopProxyOnly() {
        guard sessionID == nil else { return }
        stop()
    }

    public func startChrome(opening initialURL: URL? = nil) async throws {
        guard ready, let token = sessionID, proxy?.isRunning == true,
              let browserProfile = activeBrowserProfile,
              let browserHome = activeBrowserHome,
              let toolEnvironment = activeToolEnvironment,
              let sandboxExec = activeSandboxExec,
              let proxyLaunch = activeProxyLaunch else {
            throw SandboxFailure("请先启动已选择代理节点的沙箱会话。")
        }
        if browser?.isRunning == true {
            if let initialURL {
                try openURLInRunningChrome(initialURL, browserProfile: browserProfile, browserHome: browserHome,
                                           toolEnvironment: toolEnvironment, proxyLaunch: proxyLaunch)
                return
            }
            throw SandboxFailure("Chrome 已在运行。")
        }
        let chromeBinary = try await ensureChromeBinary()
        try ensureSession(token)
        guard proxy?.isRunning == true else { throw SandboxFailure("代理已停止，请重新启动沙箱会话。") }
        if browser?.isRunning == true {
            if let initialURL {
                try openURLInRunningChrome(initialURL, browserProfile: browserProfile, browserHome: browserHome,
                                           toolEnvironment: toolEnvironment, proxyLaunch: proxyLaunch)
            }
            return
        }
        try makePrivateDirectory(browserProfile)
        try makePrivateDirectory(browserHome)
        try applyChromeWebLanguage(to: browserProfile, workspace: activeWorkspace)
        guard let runtime else { throw CancellationError() }
        let browserTemporary = runtime.appendingPathComponent("chrome", isDirectory: true)
        try makePrivateDirectory(browserTemporary)

        let environment = chromeEnvironment(
            base: toolEnvironment, browserHome: browserHome, browserTemporary: browserTemporary,
            proxyLaunch: proxyLaunch, timeZone: activeTimeZone
        )
        let arguments = sandboxChromeArguments(
            browserProfile: browserProfile,
            proxyLaunch: proxyLaunch,
            initialURL: initialURL
        )

        let sandboxProfile = try makeChromeSandboxProfile(
            browserTemporary: browserTemporary, browserProfile: browserProfile,
            browserHome: browserHome, proxyLaunch: proxyLaunch
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", sandboxProfile.path, chromeBinary.path] + arguments
        process.currentDirectoryURL = runtime
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.browser === finished else { return }
                self.browser = nil
                self.onBrowserExit?(finished.processIdentifier, finished.terminationStatus)
            }
        }
        try process.run()
        browser = process
        onBrowserStart?(process.processIdentifier)
    }

    private func makeChromeSandboxProfile(
        browserTemporary: URL, browserProfile: URL, browserHome: URL, proxyLaunch: ProxyLaunch
    ) throws -> URL {
        guard let runtime, let workspace = activeWorkspace, let source = activeSourceWorkspace else {
            throw SandboxFailure("隔离会话尚未准备完成。")
        }
        let shellStartup = runtime.appendingPathComponent("shell-startup", isDirectory: true)
        let chromeBundle = store.root.appendingPathComponent("Runtime/Google Chrome.app", isDirectory: true)
        var allowedLoopbackPorts: Set<Int> = [Int(proxyLaunch.httpPort), Int(proxyLaunch.socksPort)]
        if let browserBridge { allowedLoopbackPorts.insert(Int(browserBridge.port)) }
        let profile = browserTemporary.appendingPathComponent("chrome-sandbox.sb")
        try writePrivate(
            Data(seatbeltProfile(
                workspace: workspace, source: source, store: store, configuration: browserProfile,
                temporary: browserTemporary, runtime: runtime, cliTools: [], shellHome: browserHome,
                shellStartup: shellStartup, chromeBundle: chromeBundle, chromeProfile: browserProfile,
                chromeHome: browserHome, allowedLoopbackPorts: allowedLoopbackPorts
            ).utf8),
            to: profile
        )
        return profile
    }

    private func ensureChromeBinary() async throws -> URL {
        let chromeBundle = store.root.appendingPathComponent("Runtime/Google Chrome.app", isDirectory: true)
        let chromeBinary = chromeBundle.appendingPathComponent("Contents/MacOS/Google Chrome")
        if FileManager.default.isExecutableFile(atPath: chromeBinary.path) {
            return chromeBinary
        }
        if let chromePreparation { return try await chromePreparation.value }
        guard let source = ToolPaths.chromeBundle else {
            throw SandboxFailure("本机未找到 Google Chrome.app。请先安装 Chrome，再重试。")
        }
        let preparation = Task.detached {
            try Self.installChrome(from: source, bundle: chromeBundle, binary: chromeBinary)
        }
        chromePreparation = preparation
        defer { chromePreparation = nil }
        return try await preparation.value
    }

    private nonisolated static func installChrome(from source: URL, bundle chromeBundle: URL, binary chromeBinary: URL) throws -> URL {
        try makePrivateDirectory(chromeBundle.deletingLastPathComponent())
        let staging = chromeBundle.deletingLastPathComponent()
            .appendingPathComponent(".Google Chrome-\(UUID().uuidString).app", isDirectory: true)
        let result = try? runTool("/usr/bin/ditto", arguments: [source.path, staging.path])
        guard result?.status == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw SandboxFailure("复制 Chrome 到沙箱存储目录失败。")
        }
        do { try FileManager.default.moveItem(at: staging, to: chromeBundle) }
        catch {
            try? FileManager.default.removeItem(at: staging)
            if !FileManager.default.isExecutableFile(atPath: chromeBinary.path) {
                throw SandboxFailure("安装复制版 Chrome 失败：\(error.localizedDescription)")
            }
        }
        return chromeBinary
    }

    private func openURLInRunningChrome(
        _ url: URL, browserProfile: URL, browserHome: URL,
        toolEnvironment: [String: String], proxyLaunch: ProxyLaunch
    ) throws {
        guard let runtime else { return }
        let chromeBinary = store.root.appendingPathComponent("Runtime/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chromeBinary.path) else { return }
        let browserTemporary = runtime.appendingPathComponent("chrome", isDirectory: true)
        try makePrivateDirectory(browserTemporary)
        guard let sandboxExec = activeSandboxExec else { throw SandboxFailure("隔离会话尚未准备完成。") }
        let sandboxProfile = try makeChromeSandboxProfile(
            browserTemporary: browserTemporary, browserProfile: browserProfile,
            browserHome: browserHome, proxyLaunch: proxyLaunch
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", sandboxProfile.path, chromeBinary.path]
            + sandboxChromeArguments(browserProfile: browserProfile, proxyLaunch: proxyLaunch, initialURL: url)
        process.currentDirectoryURL = runtime
        process.environment = chromeEnvironment(
            base: toolEnvironment, browserHome: browserHome, browserTemporary: browserTemporary,
            proxyLaunch: proxyLaunch, timeZone: activeTimeZone
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func enqueueBrowserURL(_ url: URL, session token: UUID) {
        guard ready, sessionID == token, proxy?.isRunning == true else { return }
        let previousOpen = browserOpenTask
        browserOpenTask = Task { [weak self] in
            await previousOpen?.value
            guard let self, self.sessionID == token, !Task.isCancelled else { return }
            if let importedChrome = self.activeImportedApps.first(where: isChromeImportedApp) {
                try? await self.startImportedApp(importedChrome, opening: url)
            } else {
                try? await self.startChrome(opening: url)
            }
        }
    }

    public func stopChrome() {
        guard let current = browser else { return }
        browser = nil
        terminate(current)
    }

    public func startImportedApp(_ app: SandboxImportedApp, opening initialURL: URL? = nil) async throws {
        guard ready, let token = sessionID, proxy?.isRunning == true,
              let environmentID = activeEnvironmentID,
              let folder = activeEnvironmentFolder,
              let workspace = activeWorkspace,
              let sourceWorkspace = activeSourceWorkspace,
              let sandboxExec = activeSandboxExec,
              let toolEnvironment = activeToolEnvironment,
              let proxyLaunch = activeProxyLaunch else {
            throw SandboxFailure("请先启动已选择代理节点的沙箱会话。")
        }
        let alreadyRunning = importedAppProcesses[app.id]?.isRunning == true
        if alreadyRunning && initialURL == nil {
            throw SandboxFailure("\(app.name) 已在运行。")
        }
        guard !importedAppCopying.contains(app.id) else {
            throw SandboxFailure("\(app.name) 正在准备中，请稍候。")
        }
        importedAppCopying.insert(app.id)
        defer { importedAppCopying.remove(app.id) }

        let prepared = try await prepareImportedAppBundle(app, environmentID: environmentID, storeRoot: store.root)
        try ensureSession(token)
        guard proxy?.isRunning == true else { throw SandboxFailure("代理已停止，请重新启动沙箱会话。") }
        guard let runtime else { throw CancellationError() }

        let appRoot = folder.appendingPathComponent("apps/\(app.id.uuidString)", isDirectory: true)
        let appHome = appRoot.appendingPathComponent("home", isDirectory: true)
        let appProfile = appRoot.appendingPathComponent("profile", isDirectory: true)
        let appTemp = runtime.appendingPathComponent("apps/\(app.id.uuidString)", isDirectory: true)
        for dir in [appRoot, appHome, appProfile, appTemp] {
            try makePrivateDirectory(dir)
        }

        if prepared.isChrome {
            try applyChromeWebLanguage(to: appProfile, workspace: workspace)
        }

        let hookDylib = prepared.isChrome ? nil : coboxURLHookDylibURL()
        let shellStartup = runtime.appendingPathComponent("shell-startup", isDirectory: true)
        let appSandboxProfile = appTemp.appendingPathComponent("app-sandbox.sb")
        var allowedLoopbackPorts: Set<Int> = [Int(proxyLaunch.httpPort), Int(proxyLaunch.socksPort)]
        if let browserBridge { allowedLoopbackPorts.insert(Int(browserBridge.port)) }
        try writePrivate(
            Data(importedAppSeatbeltProfile(
                workspace: workspace,
                source: sourceWorkspace,
                store: store,
                runtime: runtime,
                shellStartup: shellStartup,
                appBundle: prepared.bundleURL,
                appRoot: appRoot,
                appTemp: appTemp,
                hookDylib: hookDylib,
                allowedLoopbackPorts: allowedLoopbackPorts
            ).utf8),
            to: appSandboxProfile
        )

        if !prepared.isChrome {
            await Task.detached { _ = ensureIsolatedLoginKeychain(at: appHome) }.value
        }

        var environment = chromeEnvironment(
            base: toolEnvironment,
            browserHome: appHome,
            browserTemporary: appTemp,
            proxyLaunch: proxyLaunch,
            timeZone: activeTimeZone
        )
        environment["http_proxy"] = proxyLaunch.endpoint
        environment["https_proxy"] = proxyLaunch.endpoint
        environment["all_proxy"] = "socks5h://127.0.0.1:\(proxyLaunch.socksPort)"
        environment["no_proxy"] = "localhost,127.0.0.1,::1"
        environment["CCBOX_PROXY_HTTP_PORT"] = String(proxyLaunch.httpPort)
        environment["CCBOX_PROXY_SOCKS_PORT"] = String(proxyLaunch.socksPort)
        environment["CCBOX_SANDBOX_WORKSPACE"] = workspace.path
        if !prepared.isChrome {
            let envPrefix = String((activeEnvironmentID ?? token).uuidString.prefix(8)).lowercased()
            let appPrefix = String(app.id.uuidString.prefix(8)).lowercased()
            environment["CCBOX_APP_HOME"] = appHome.path
            environment["CCBOX_ISOLATED_KEYCHAIN"] = appHome.appendingPathComponent("Library/Keychains/login.keychain-db").path
            environment["CCBOX_ISOLATED_KEYCHAIN_SECRET_FILE"] = isolatedKeychainSecretURL(at: appHome).path
            environment["CCBOX_PREFS_NAMESPACE"] = "ccbox.\(envPrefix).\(appPrefix)"
            environment["CCBOX_ALIGN_LOCALE"] = "1"
            environment["LANG"] = "en_US.UTF-8"
            environment["LC_ALL"] = "en_US.UTF-8"
            environment["LC_CTYPE"] = "en_US.UTF-8"
            environment["CCBOX_ALLOWED_PATHS"] = [workspace.path, appRoot.path, appTemp.path].joined(separator: ":")
        }
        if let browserBridge {
            let browserBin = runtime.appendingPathComponent("shell-startup/bin/browser", isDirectory: true)
            environment.merge(browserBridge.variables) { _, value in value }
            environment["BROWSER"] = browserBin.appendingPathComponent("sandbox-browser").path
            environment["PATH"] = browserBin.path + ":" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        }
        if let hookDylib {
            if let existing = environment["DYLD_INSERT_LIBRARIES"], !existing.isEmpty {
                environment["DYLD_INSERT_LIBRARIES"] = "\(hookDylib.path):\(existing)"
            } else {
                environment["DYLD_INSERT_LIBRARIES"] = hookDylib.path
            }
        }

        let appArguments: [String]
        if prepared.isChrome {
            appArguments = sandboxChromeArguments(browserProfile: appProfile, proxyLaunch: proxyLaunch, initialURL: initialURL)
        } else if prepared.isChromiumBased {
            appArguments = ["--no-sandbox", "--use-mock-keychain"] + chromeArguments(browserProfile: appProfile, proxyPort: proxyLaunch.httpPort, initialURL: initialURL)
        } else {
            appArguments = ["-AppleLanguages", "(en-US, en)", "-AppleLocale", "en_US"]
        }

        let launchExecutable = URL(fileURLWithPath: sandboxExec)
        let launchArguments: [String]
        if let hookDylib {
            launchArguments = [
                "-f", appSandboxProfile.path, "/bin/sh", "-c", Self.importedAppBootstrap,
                "ccbox-imported-app", hookDylib.path, prepared.executableURL.path
            ] + appArguments
        } else {
            launchArguments = ["-f", appSandboxProfile.path, prepared.executableURL.path] + appArguments
        }

        if let hookDylib {
            try installNestedAppLaunchers(
                in: prepared.bundleURL, sandboxExec: sandboxExec, profile: appSandboxProfile,
                hookDylib: hookDylib, environment: environment
            )
        }

        if importedAppProcesses[app.id]?.isRunning == true {
            if initialURL != nil, prepared.isChromiumBased {
                let opener = Process()
                opener.executableURL = launchExecutable
                opener.arguments = launchArguments
                opener.currentDirectoryURL = runtime
                opener.environment = environment
                opener.standardInput = FileHandle.nullDevice
                opener.standardOutput = FileHandle.nullDevice
                opener.standardError = FileHandle.nullDevice
                try opener.run()
            }
            return
        }

        let process = Process()
        process.executableURL = launchExecutable
        process.arguments = launchArguments
        process.currentDirectoryURL = runtime
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let appID = app.id
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.importedAppProcesses[appID] === finished else { return }
                self.importedAppProcesses.removeValue(forKey: appID)
                self.onAppExit?(appID, finished.processIdentifier, finished.terminationStatus)
            }
        }
        try process.run()
        importedAppProcesses[app.id] = process
        onAppStart?(app.id, process.processIdentifier)
    }

    private func installNestedAppLaunchers(
        in bundleURL: URL, sandboxExec: String, profile: URL, hookDylib: URL, environment: [String: String]
    ) throws {
        guard let launcher = coboxNestedLauncherURL() else { throw SandboxFailure("缺少嵌套应用启动器。") }
        for executable in nestedAppExecutables(in: bundleURL) {
            let original = executable.appendingPathExtension("ccbox-original")
            if !FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(at: executable, to: original)
            }
            let exports = environment.keys.sorted().map {
                "export \($0)=\(shellArgument(environment[$0] ?? ""))"
            }.joined(separator: "\n")
            let script = """
            #!/bin/sh
            \(exports)
            wrapper="$1"
            shift
            exec \(shellArgument(sandboxExec)) -f \(shellArgument(profile.path)) /bin/sh -c \(shellArgument(Self.importedAppBootstrap)) ccbox-nested \(shellArgument(hookDylib.path)) "$wrapper.ccbox-original" "$@"
            """
            try writeExecutableScript(script, to: executable.appendingPathExtension("ccbox-launch"))

            let staging = executable.appendingPathExtension("ccbox-new")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: launcher, to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.moveItem(at: staging, to: executable)
        }
    }

    public func stopImportedApp(_ appID: UUID) {
        guard let current = importedAppProcesses.removeValue(forKey: appID) else { return }
        terminate(current)
    }

    public func inspectExit(_ environment: SandboxEnvironment) async throws -> SandboxExit {
        guard sessionID == nil else { throw SandboxFailure("已有环境或检测正在运行。") }
        guard let node = try store.loadNodes(for: environment).first(where: { $0.name == environment.node }) else {
            throw SandboxFailure("请先导入并选择一个代理节点。")
        }
        let (mihomo, toolEnvironment) = try ToolPaths.proxyOnly()
        let token = UUID()
        sessionID = token
        defer { if sessionID == token { stop() } }
        let runDirectory = try makeSessionDirectory()
        runtime = runDirectory

        let launch = try makeProxyLaunch(node: node, runtime: runDirectory)
        try await validateProxy(mihomo, environment: toolEnvironment, launch: launch, runtime: runDirectory)
        try ensureSession(token)
        let process = try startProxy(mihomo, environment: toolEnvironment, launch: launch, runtime: runDirectory)
        let pinnedTimeZone = environment.timeZoneIdentifier
        let (location, report) = try await Task.detached { () -> (DetailedExitInfo?, ProxyCheckReport) in
            try waitForLocalProxy(ports: [launch.httpPort, launch.socksPort])
            let info = try? lookupDetailedExit(through: launch)
            let tz = pinnedTimeZone ?? info?.timezone ?? TimeZone.current.identifier
            let report = runProxyPreFlightChecks(
                proxyEndpoint: launch.endpoint,
                sandboxProfile: nil,
                sandboxExec: nil,
                sandboxEnv: nil,
                resolvedTimeZone: tz,
                exitInfo: info
            )
            return (info, report)
        }.value
        try ensureSession(token)
        guard process.isRunning else { throw SandboxFailure("mihomo 已退出，无法检测出口。") }
        guard let location else { throw SandboxFailure("出口检测服务未返回有效结果。") }
        return SandboxExit(ip: location.ip, timeZoneIdentifier: location.timezone,
                           country: location.country, city: location.city, checkReport: report)
    }

    public func stop() {
        let currentBrowser = browser
        let currentApps = Array(importedAppProcesses.values)
        let current = proxy
        let currentBridge = browserBridge
        let sessionDirectory = runtime
        browser = nil
        importedAppProcesses.removeAll()
        proxy = nil
        browserBridge = nil
        browserOpenTask?.cancel()
        browserOpenTask = nil
        runtime = nil
        sessionID = nil
        activeEnvironmentID = nil
        activeEnvironmentFolder = nil
        activeWorkspace = nil
        activeSourceWorkspace = nil
        activeSandboxExec = nil
        activeProxyLaunch = nil
        activeSandboxConfig = nil
        activeBrowserProfile = nil
        activeBrowserHome = nil
        activeToolEnvironment = nil
        activeTimeZone = nil
        activeEnvironmentName = nil
        activeImportedApps = []
        ready = false
        currentBridge?.stop()
        if let currentBrowser { terminate(currentBrowser) }
        for appProcess in currentApps { terminate(appProcess) }
        if let current, current.isRunning {
            terminate(current)
        } else if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        onNetworkFilterApplicationsChanged?()
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func prepare(
        _ environment: SandboxEnvironment, workspace: URL, source: URL, tools: ToolPaths, node: ProxyNode?, token: UUID
    ) async throws -> SandboxLaunch {
        let folder = store.directory(for: environment)
        let shellHome = folder.appendingPathComponent("home", isDirectory: true)
        let configuration = folder.appendingPathComponent("app-config", isDirectory: true)
        let browserProfile = folder.appendingPathComponent("chrome-profile", isDirectory: true)
        let browserHome = folder.appendingPathComponent("chrome-home", isDirectory: true)
        let chromeBundle = store.root.appendingPathComponent("Runtime/Google Chrome.app", isDirectory: true)
        let reusableProxy = activeEnvironmentID == environment.id ? activeProxyLaunch : nil
        let runtime = reusableProxy == nil ? try makeSessionDirectory() : self.runtime!
        self.runtime = runtime
        guard !pathsOverlap(workspace, runtime) else {
            throw SandboxFailure("请选择具体项目目录，避免把临时代理配置纳入工作区。")
        }
        let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
        let shellStartup = runtime.appendingPathComponent("shell-startup", isDirectory: true)
        let shellBin = shellStartup.appendingPathComponent("bin", isDirectory: true)
        let browserBin = shellBin.appendingPathComponent("browser", isDirectory: true)
        for path in [store.root, folder, shellHome, configuration, temporary, browserProfile, browserHome, browserBin] {
            try makePrivateDirectory(path)
        }
        try writePrivate(Data(Self.shellRC.utf8), to: shellStartup.appendingPathComponent(".zshrc"))
        try writeExecutableScript(Self.browserShimScript, to: browserBin.appendingPathComponent("sandbox-browser"))
        try writeExecutableScript(Self.openShimScript, to: browserBin.appendingPathComponent("open"))
        try writeExecutableScript(Self.mktempShimScript, to: shellBin.appendingPathComponent("mktemp"))

        let proxyLaunch = try node.map { node in
            if let reusableProxy { return reusableProxy }
            return try makeProxyLaunch(node: node, runtime: runtime)
        }
        let bridge = try proxyLaunch.map { _ in
            try BrowserBridge { [weak self] url in
                Task { @MainActor [weak self] in
                    self?.enqueueBrowserURL(url, session: token)
                }
            }
        }
        browserBridge?.stop()
        browserBridge = bridge
        var allowedLoopbackPorts = Set<Int>()
        if let proxyLaunch {
            allowedLoopbackPorts = [Int(proxyLaunch.httpPort), Int(proxyLaunch.socksPort)]
        }
        if let bridge { allowedLoopbackPorts.insert(Int(bridge.port)) }
        let sandboxProfile = runtime.appendingPathComponent("sandbox.sb")
        try writePrivate(
            Data(seatbeltProfile(
                workspace: workspace, source: source, store: store, configuration: configuration,
                temporary: temporary, runtime: runtime, cliTools: tools.cliTools, shellHome: shellHome, shellStartup: shellStartup,
                chromeBundle: chromeBundle, chromeProfile: browserProfile, chromeHome: browserHome,
                allowedLoopbackPorts: allowedLoopbackPorts
            ).utf8),
            to: sandboxProfile
        )

        var launchEnvironment = tools.environment
        launchEnvironment["TMPDIR"] = temporary.path
        launchEnvironment["XDG_RUNTIME_DIR"] = temporary.path
        launchEnvironment["BUN_TMPDIR"] = temporary.path
        for variable in try store.additionalTemporaryDirectoryVariables() {
            launchEnvironment[variable] = temporary.path
        }
        let sandboxArguments = ["-f", sandboxProfile.path]
        let checkEnvironment = launchEnvironment
        try await Task.detached {
            let check = try runTool(
                tools.sandboxExec, arguments: sandboxArguments + ["/usr/bin/true"],
                environment: checkEnvironment, captureOutput: true, captureError: true
            )
            guard check.status == 0 else {
                let detail = String(decoding: check.errorOutput + check.output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SandboxFailure("Seatbelt 初始化失败。\(detail.isEmpty ? "请从 macOS Finder 启动应用，或在普通终端运行。" : detail)")
            }
        }.value
        try ensureSession(token)
        let pinnedTimeZone = environment.timeZoneIdentifier
        activeEnvironmentID = environment.id
        activeEnvironmentFolder = folder
        activeWorkspace = workspace
        activeSourceWorkspace = source
        activeSandboxExec = tools.sandboxExec
        activeSandboxConfig = sandboxProfile
        activeBrowserProfile = browserProfile
        activeBrowserHome = browserHome
        activeToolEnvironment = tools.environment
        activeEnvironmentName = environment.name
        activeAccentHex = environment.resolvedAccentHex
        activeImportedApps = environment.importedApps
        var location: DetailedExitInfo?
        var checkReport: ProxyCheckReport?
        if let proxyLaunch, let mihomo = tools.mihomo {
            if let reusableProxy {
                guard proxy?.isRunning == true else { throw SandboxFailure("代理已停止，请重新启动代理。") }
                let checkResult = await Task.detached { () -> (DetailedExitInfo?, ProxyCheckReport) in
                    let info = try? lookupDetailedExit(through: reusableProxy)
                    let tz = pinnedTimeZone ?? info?.timezone ?? TimeZone.current.identifier
                    let report = runProxyPreFlightChecks(
                        proxyEndpoint: reusableProxy.endpoint,
                        sandboxProfile: sandboxProfile,
                        sandboxExec: tools.sandboxExec,
                        sandboxEnv: checkEnvironment,
                        resolvedTimeZone: tz,
                        exitInfo: info
                    )
                    return (info, report)
                }.value
                location = checkResult.0
                checkReport = checkResult.1
            } else {
                try await validateProxy(mihomo, environment: tools.environment, launch: proxyLaunch, runtime: runtime)
                try ensureSession(token)
                let process = try startProxy(mihomo, environment: tools.environment, launch: proxyLaunch, runtime: runtime)
                let checkResult = try await Task.detached { () -> (DetailedExitInfo?, ProxyCheckReport) in
                    try waitForLocalProxy(ports: [proxyLaunch.httpPort, proxyLaunch.socksPort])
                    let info = try? lookupDetailedExit(through: proxyLaunch)
                    let tz = pinnedTimeZone ?? info?.timezone ?? TimeZone.current.identifier
                    let report = runProxyPreFlightChecks(
                        proxyEndpoint: proxyLaunch.endpoint,
                        sandboxProfile: sandboxProfile,
                        sandboxExec: tools.sandboxExec,
                        sandboxEnv: checkEnvironment,
                        resolvedTimeZone: tz,
                        exitInfo: info
                    )
                    return (info, report)
                }.value
                location = checkResult.0
                checkReport = checkResult.1
                try ensureSession(token)
                guard process.isRunning else { throw SandboxFailure("mihomo 已退出，无法启动沙箱会话。") }
            }
            activeProxyLaunch = proxyLaunch
            let socksEndpoint = "socks5h://127.0.0.1:\(proxyLaunch.socksPort)"
            launchEnvironment["HTTP_PROXY"] = proxyLaunch.endpoint
            launchEnvironment["HTTPS_PROXY"] = proxyLaunch.endpoint
            launchEnvironment["ALL_PROXY"] = socksEndpoint
            launchEnvironment["http_proxy"] = proxyLaunch.endpoint
            launchEnvironment["https_proxy"] = proxyLaunch.endpoint
            launchEnvironment["all_proxy"] = socksEndpoint
            launchEnvironment["NO_PROXY"] = "localhost,127.0.0.1,::1"
            launchEnvironment["no_proxy"] = "localhost,127.0.0.1,::1"
            launchEnvironment["CCBOX_HTTP_PROXY"] = proxyLaunch.endpoint
            launchEnvironment["CCBOX_SOCKS_PROXY"] = socksEndpoint

            if let bridge {
                launchEnvironment.merge(bridge.variables) { _, value in value }
            }
        }
        let timeZone = pinnedTimeZone ?? location?.timezone ?? TimeZone.current.identifier
        activeTimeZone = timeZone
        launchEnvironment["TZ"] = timeZone
        let shellArgs = [
            "/bin/sh", "-c", Self.shellBootstrap, "sandbox-shell",
            shellStartup.path, temporary.path, shellHome.path, workspace.path
        ]
        return SandboxLaunch(
            executable: tools.sandboxExec,
            arguments: sandboxArguments + shellArgs,
            environment: launchEnvironment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            workingDirectory: workspace.path,
            endpoint: proxyLaunch?.endpoint,
            timeZoneIdentifier: timeZone,
            exitIP: location?.ip,
            checkReport: checkReport
        )
    }

    // Set user paths after Seatbelt is applied. The host-side runtime keeps its trusted PATH.
    private static let shellBootstrap = """
        export HOME="$3" ZDOTDIR="$1" SHELL=/bin/zsh
        export TMPDIR="$2" TEMP="$2" TMP="$2"
        export CCBOX_BIN="$1/bin"
        export PATH="$CCBOX_BIN/browser:$CCBOX_BIN:$HOME/.local/bin:$HOME/bin:$PATH" GIT_CONFIG_NOSYSTEM=1
        export BROWSER="$CCBOX_BIN/browser/sandbox-browser"
        export NO_PROXY="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,::1"
        export no_proxy="$NO_PROXY"
        export CCBOX_WORKSPACE="$4"
        export CCBOX_TMP="$2"
        cd "$CCBOX_WORKSPACE" || exit 1
        exec /bin/zsh -d -i
        """

    private static let importedAppBootstrap = """
        export DYLD_INSERT_LIBRARIES="$1"
        shift
        exec "$@"
        """

    private static let browserShimScript = #"""
        #!/bin/sh
        url="$1"
        [ -n "$url" ] || exit 1
        if [ -z "$CCBOX_BROWSER_PORT" ] || [ -z "$CCBOX_BROWSER_TOKEN" ]; then
          printf '沙箱未启用代理，无法打开隔离版 Chrome。\n' >&2
          exit 1
        fi
        reply=$(printf '%s %s\n' "$CCBOX_BROWSER_TOKEN" "$url" | /usr/bin/nc -w 2 127.0.0.1 "$CCBOX_BROWSER_PORT" 2>/dev/null)
        [ "$reply" = OK ]
        """#

    private static let openShimScript = #"""
        #!/bin/sh
        opened=0
        status=0
        for arg in "$@"; do
          case "$arg" in
            --args) break ;;
            [hH][tT][tT][pP]://*|[hH][tT][tT][pP][sS]://*)
              opened=1
              "${0%/*}/sandbox-browser" "$arg" || status=1
              ;;
          esac
        done
        [ "$opened" -eq 0 ] || exit "$status"
        exec /usr/bin/open "$@"
        """#

    private static let mktempShimScript = #"""
        #!/bin/sh
        dir="${CCBOX_TMP:-${TMPDIR:-/tmp}}"
        dir="${dir%/}"
        flags=""
        prefix="tmp"
        has_template=0
        has_dir=0
        expect_t=0
        after_dash=0
        for arg in "$@"; do
          if [ "$after_dash" -eq 1 ]; then
            has_template=1
            break
          fi
          if [ "$expect_t" -eq 1 ]; then
            prefix="$arg"
            expect_t=0
            continue
          fi
          case "$arg" in
            --) after_dash=1 ;;
            -t) expect_t=1 ;;
            -t*) prefix="${arg#-t}" ;;
            -p|-p*) has_dir=1; break ;;
            -*) flags="$flags $arg" ;;
            *) has_template=1; break ;;
          esac
        done
        if [ "$has_template" -eq 1 ] || [ "$has_dir" -eq 1 ]; then
          exec /usr/bin/mktemp "$@"
        fi
        exec /usr/bin/mktemp $flags "$dir/${prefix}.XXXXXXXXXX"
        """#

    private static let shellRC = #"""
        export ZDOTDIR="$HOME"
        typeset -gr _sandbox_workspace="${CCBOX_WORKSPACE:A}"
        typeset -gr _sandbox_home="${HOME:A}"
        typeset -gr _sandbox_tmp="${CCBOX_TMP:A}"
        [[ ! -r "$HOME/.zshrc" ]] || source "$HOME/.zshrc"
        export PATH="$CCBOX_BIN/browser:$CCBOX_BIN:$PATH"
        export TMPDIR="$_sandbox_tmp" TEMP="$_sandbox_tmp" TMP="$_sandbox_tmp"
        if [[ -n "$CCBOX_HTTP_PROXY" ]]; then
          export HTTP_PROXY="$CCBOX_HTTP_PROXY" HTTPS_PROXY="$CCBOX_HTTP_PROXY"
          export http_proxy="$CCBOX_HTTP_PROXY" https_proxy="$CCBOX_HTTP_PROXY"
          export ALL_PROXY="$CCBOX_SOCKS_PROXY" all_proxy="$CCBOX_SOCKS_PROXY"
        else
          unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        fi
        export NO_PROXY="localhost,127.0.0.1,::1"
        export no_proxy="$NO_PROXY"
        alias l='ls -lah'
        alias ll='ls -alh'
        alias la='ls -A'

        function cd {
          if (( $# == 1 )); then
            case "$1" in
              ("/workspace"|"/workspace"/*) builtin cd "$_sandbox_workspace${1#/workspace}"; return $? ;;
              ("/home"|"/home"/*) builtin cd "$_sandbox_home${1#/home}"; return $? ;;
              ("/tmp"|"/tmp"/*) builtin cd "$_sandbox_tmp${1#/tmp}"; return $? ;;
            esac
          fi
          builtin cd "$@"
        }

        function _sandbox_display_path {
          local current="${PWD:A}"
          case "$current" in
            ("$_sandbox_workspace"|"$_sandbox_workspace"/*) print -r -- "/workspace${current#$_sandbox_workspace}" ;;
            ("$_sandbox_home"|"$_sandbox_home"/*) print -r -- "/home${current#$_sandbox_home}" ;;
            ("$_sandbox_tmp"|"$_sandbox_tmp"/*) print -r -- "/tmp${current#$_sandbox_tmp}" ;;
            (*) return 1 ;;
          esac
        }

        # Interactive display only. Explicit options and external pwd keep normal semantics.
        function pwd {
          if (( $# == 0 )) && [[ -t 1 ]] && _sandbox_display_path; then return 0; fi
          builtin pwd "$@"
        }

        function _sandbox_prompt {
          local display
          display="$(_sandbox_display_path)" || display="/"
          psvar[127]="${(V)display}"
          PROMPT='sandbox:%127v %# '
          RPROMPT=''
        }
        precmd_functions+=(_sandbox_prompt)
        _sandbox_prompt
        """#

    private func startProxy(_ binary: String, environment: [String: String], launch: ProxyLaunch, runtime: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", runtime.path, "-f", launch.configuration.path]
        process.currentDirectoryURL = runtime
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: runtime) }
                guard let self, self.proxy === finished, self.ready else { return }
                self.onProxyExit?()
                self.stop()
            }
        }
        try process.run()
        proxy = process
        return process
    }

    private func ensureSession(_ token: UUID) throws {
        guard sessionID == token, !Task.isCancelled else { throw CancellationError() }
    }
}

private struct ProxyLaunch: Sendable {
    let httpPort: UInt16
    let socksPort: UInt16
    let endpoint: String
    let configuration: URL
}

private func makeSessionDirectory() throws -> URL {
    // Keep session directory path short so Unix domain sockets fit within Darwin's 103-byte limit.
    var template = Array("/private/tmp/ccbox-session.XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else { throw SandboxFailure("无法创建会话临时目录。") }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

private func makeProxyLaunch(node: ProxyNode, runtime: URL) throws -> ProxyLaunch {
    let httpPort = try chooseLoopbackPort()
    var socksPort = try chooseLoopbackPort()
    while socksPort == httpPort { socksPort = try chooseLoopbackPort() }
    let configuration = runtime.appendingPathComponent("mihomo.json")
    let settings = node.configuration(httpPort: httpPort, socksPort: socksPort)
    try writePrivate(JSONSerialization.data(withJSONObject: settings), to: configuration)
    return ProxyLaunch(httpPort: httpPort, socksPort: socksPort,
                       endpoint: "http://127.0.0.1:\(httpPort)", configuration: configuration)
}

private func validateProxy(_ binary: String, environment: [String: String], launch: ProxyLaunch, runtime: URL) async throws {
    try await Task.detached {
        let result = try runTool(
            binary, arguments: ["-t", "-d", runtime.path, "-f", launch.configuration.path],
            environment: environment
        )
        guard result.status == 0 else {
            throw SandboxFailure("mihomo 无法加载所选节点，请检查协议和参数。")
        }
    }.value
}

private struct ToolPaths: Sendable {
    let cliTools: [String]
    let sandboxExec: String
    let mihomo: String?
    let environment: [String: String]

    static var chromeBundle: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Applications/Google Chrome.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/Google Chrome").path)
        }
    }

    private static var paths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
    }

    private static func executable(_ name: String, workspace: URL?, help: String) throws -> String {
        for folder in paths {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let real = candidate.resolvingSymlinksInPath()
            if let workspace, pathsOverlap(real, workspace) {
                throw SandboxFailure("\(name) 的程序文件位于可写工作区内，请移动到工作区外。")
            }
            return real.path
        }
        throw SandboxFailure(help)
    }

    private static var processEnvironment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = [
            "PATH": paths.joined(separator: ":"), "HOME": home, "TERM": "xterm-256color",
            "COLORTERM": "truecolor", "DISABLE_AUTOUPDATER": "1"
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        return environment
    }

    static func proxyOnly(workspace: URL? = nil) throws -> (String, [String: String]) {
        try (executable("mihomo", workspace: workspace, help: "找不到 mihomo，请先安装 mihomo。"), processEnvironment)
    }

    static func discover(workspace: URL, needsProxy: Bool) throws -> ToolPaths {
        let mihomo = needsProxy ? try proxyOnly(workspace: workspace).0 : nil
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var cliTools = ["\(home)/.local/bin", "\(home)/.npm-global/bin"]
        let developerTools = "/Applications/Xcode.app/Contents"
        if FileManager.default.fileExists(atPath: developerTools) {
            cliTools.append(developerTools)
        }
        let sandboxExec = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExec) else {
            throw SandboxFailure("系统缺少 /usr/bin/sandbox-exec，无法初始化 macOS 沙箱。")
        }
        return ToolPaths(
            cliTools: Array(Set(cliTools)),
            sandboxExec: sandboxExec,
            mihomo: mihomo, environment: processEnvironment
        )
    }
}

func validateWorkspace(_ workspace: URL, store: SandboxStore) throws {
    var isDirectory: ObjCBool = false
    guard workspace.isFileURL,
          FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw SandboxFailure("工作目录不存在，请重新选择项目文件夹。")
    }
    let hostHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    let blocked = [store.root, URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/private/etc"),
                   URL(fileURLWithPath: "/usr"), URL(fileURLWithPath: "/opt/homebrew")]
    guard workspace.path != hostHome, !blocked.contains(where: { pathsOverlap(workspace, $0) }) else {
        throw SandboxFailure("请选择具体项目目录，避开应用数据和系统目录。")
    }
}

private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.pathComponents.starts(with: rhs.pathComponents) || rhs.pathComponents.starts(with: lhs.pathComponents)
}

func supportsRuntimeVersion(_ data: Data) -> Bool {
    let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ".").compactMap { Int($0) }
    return parts.count == 3 && !parts.lexicographicallyPrecedes([0, 0, 83])
}

func chromeArguments(browserProfile: URL, proxyPort: UInt16, initialURL: URL? = nil) -> [String] {
    var arguments = [
        "--user-data-dir=\(browserProfile.path)",
        "--proxy-server=http://127.0.0.1:\(proxyPort)",
        "--proxy-bypass-list=127.0.0.1;localhost;[::1]",
        "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1, EXCLUDE localhost",
        "--accept-lang=en-US,en",
        "--disable-quic",
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        "--no-first-run",
        "--no-default-browser-check"
    ]
    if let initialURL {
        arguments.append(initialURL.absoluteString)
    }
    return arguments
}

func applyChromeWebLanguage(to browserProfile: URL, acceptLanguages: String = "en-US,en", workspace: URL? = nil) throws {
    let defaultProfile = browserProfile.appendingPathComponent("Default", isDirectory: true)
    try makePrivateDirectory(defaultProfile)
    let preferencesURL = defaultProfile.appendingPathComponent("Preferences")
    var preferences: [String: Any] = [:]
    if let existingData = try? Data(contentsOf: preferencesURL),
       let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
        preferences = existing
    }
    var intl = (preferences["intl"] as? [String: Any]) ?? [:]
    intl["accept_languages"] = acceptLanguages
    intl["selected_languages"] = acceptLanguages
    preferences["intl"] = intl
    if let workspace {
        var download = (preferences["download"] as? [String: Any]) ?? [:]
        download["default_directory"] = workspace.path
        preferences["download"] = download
        var selectfile = (preferences["selectfile"] as? [String: Any]) ?? [:]
        selectfile["last_directory"] = workspace.path
        preferences["selectfile"] = selectfile
    }
    let updated = try JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys])
    try writePrivate(updated, to: preferencesURL)
}

private func sandboxChromeArguments(browserProfile: URL, proxyLaunch: ProxyLaunch, initialURL: URL? = nil) -> [String] {
    // The isolated Chrome profile uses Chromium's mock keychain to avoid macOS keychain dialogs.
    ["--use-mock-keychain"] + chromeArguments(browserProfile: browserProfile, proxyPort: proxyLaunch.httpPort, initialURL: initialURL)
}

private func chromeEnvironment(
    base: [String: String], browserHome: URL, browserTemporary: URL,
    proxyLaunch: ProxyLaunch, timeZone: String?
) -> [String: String] {
    var environment = base
    environment["HOME"] = browserHome.path
    environment["CFFIXED_USER_HOME"] = browserHome.path
    environment["TMPDIR"] = browserTemporary.path
    environment["MAC_CHROMIUM_TMPDIR"] = browserTemporary.path
    environment["TZ"] = timeZone ?? TimeZone.current.identifier
    environment["HTTP_PROXY"] = proxyLaunch.endpoint
    environment["HTTPS_PROXY"] = proxyLaunch.endpoint
    environment["ALL_PROXY"] = "socks5h://127.0.0.1:\(proxyLaunch.socksPort)"
    environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
    return environment
}

private func shellArgument(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func writeExecutableScript(_ script: String, to url: URL) throws {
    try writePrivate(Data((script + "\n").utf8), to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

final class BrowserBridge: @unchecked Sendable {
    let port: UInt16
    let token: String
    var variables: [String: String] {
        [
            "CCBOX_BROWSER_PORT": String(port),
            "CCBOX_BROWSER_TOKEN": token
        ]
    }

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "CCBox.browser.bridge", qos: .userInitiated)
    private let lock = NSLock()
    private var stopped = false

    init(onOpenURL: @escaping @Sendable (URL) -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxFailure("无法创建浏览器桥接服务。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                guard Darwin.bind(fd, sockaddr, size) == 0 else { return Int32(-1) }
                return Darwin.getsockname(fd, sockaddr, &size)
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw SandboxFailure("无法监听浏览器桥接端口。")
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: address.sin_port)
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")

        queue.async { [weak self] in
            self?.acceptLoop(onOpenURL: onOpenURL)
        }
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(onOpenURL: @escaping @Sendable (URL) -> Void) {
        while !isStopped() {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD, onOpenURL: onOpenURL)
            }
        }
    }

    static func parseRequest(_ line: String, expectedToken: String) -> URL? {
        let firstLine = line.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == expectedToken,
              let url = URL(string: String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }

    private func handleClient(_ clientFD: Int32, onOpenURL: @escaping @Sendable (URL) -> Void) {
        defer { Darwin.close(clientFD) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = Data()
        while received.count < 4096 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(clientFD, $0.baseAddress, min($0.count, 4096 - received.count)) }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
                if received.contains(0x0A) { break }
            } else {
                break
            }
        }
        let line = String(decoding: received, as: UTF8.self)
        guard let url = Self.parseRequest(line, expectedToken: token) else {
            _ = "ERR\n".withCString { Darwin.write(clientFD, $0, 4) }
            return
        }
        onOpenURL(url)
        _ = "OK\n".withCString { Darwin.write(clientFD, $0, 3) }
    }
}

private func chooseLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SandboxFailure("无法创建本地代理端口。") }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let status = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
            guard bind(descriptor, sockaddr, size) == 0 else { return Int32(-1) }
            return getsockname(descriptor, sockaddr, &size)
        }
    }
    guard status == 0 else { throw SandboxFailure("无法分配本地代理端口。") }
    return UInt16(bigEndian: address.sin_port)
}

private struct ExitLocation: Sendable {
    let ip: String
    let timezone: String
    let country: String?
    let city: String?

    init?(_ data: Data) {
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["error"] as? Bool != true, fields["success"] as? Bool != false,
              let ip = fields["ip"] as? String, isIPAddress(ip),
              let timezone = (fields["timezone"] as? String) ?? (fields["timezone"] as? [String: Any])?["id"] as? String,
              TimeZone(identifier: timezone) != nil else { return nil }
        self.ip = ip
        self.timezone = timezone
        self.country = fields["country_name"] as? String ?? fields["country"] as? String
        self.city = fields["city"] as? String
    }
}

private func isIPAddress(_ value: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1
}

private func proxyRequest(_ options: [String], through proxy: ProxyLaunch) throws -> ToolResult {
    let arguments = [
        "--disable", "--silent", "--noproxy", "", "--proxy", proxy.endpoint,
        "--proto", "=https",
        "--connect-timeout", "7", "--max-time", "12", "--max-filesize", "32768"
    ]
    for _ in 0..<2 {
        let result = try runTool("/usr/bin/curl", arguments: arguments + options,
                                 environment: ["PATH": "/usr/bin:/bin"], captureOutput: true)
        if result.status != 7 { return result }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return try runTool("/usr/bin/curl", arguments: arguments + options,
                       environment: ["PATH": "/usr/bin:/bin"], captureOutput: true)
}

private func waitForLocalProxy(ports: [UInt16]) throws {
    for port in ports { try waitForLocalProxy(port: port) }
}

private func waitForLocalProxy(port: UInt16) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    for _ in 0..<20 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { break }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        close(descriptor)
        if connected { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw SandboxFailure("mihomo 未能启动本地代理。")
}

private func lookupDetailedExit(through proxy: ProxyLaunch) throws -> DetailedExitInfo? {
    for url in ["https://ipwho.is/", "https://ipapi.co/json/"] {
        let response = try proxyRequest(["--fail", url], through: proxy)
        if response.status == 0, let location = DetailedExitInfo(response.output) { return location }
    }
    return nil
}
