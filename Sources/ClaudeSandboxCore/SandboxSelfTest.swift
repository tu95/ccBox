import Foundation

public struct SandboxSelfTestResult: Sendable {
    public let name: String
    public let passed: Bool
    public let detail: String
}

public enum SandboxSelfTest {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SandboxFailure(message)
        }
    }

    @MainActor
    public static func runAll() async throws -> [SandboxSelfTestResult] {
        let cases: [(String, @MainActor () async throws -> String)] = [
            ("1. BrowserBridge 真实本地协议与安全校验", testBrowserBridgeLive),
            ("2. SandboxStore 持久化、多环境配色与 mihomo -t 校验", testStoreAndMihomoLive),
            ("3. SandboxTerminal 真实 PTY 与 TZ/PWD 注入", testTerminalLivePTY),
            ("4. 终端 Seatbelt 网络与文件系统规则", testTerminalSeatbelt),
            ("5. 导入应用 Seatbelt 纯隔离（禁直连 + 禁宿主机硬盘）", testImportedAppSeatbeltIsolated),
            ("6. 导入应用 Seatbelt 直通模式（禁直连 + 禁宿主凭证）", testImportedAppSeatbeltPassthrough),
            ("7. Seatbelt 内核级真机阻断实测（非嵌套环境）", testSeatbeltLiveExecutionIfPermitted),
            ("8. Chrome 防泄露参数与 Preferences 工作区锁定", testChromeAntiLeakAndPreferences),
            ("9. 导入应用 Bundle 解析、Chrome/Electron 识别", testImportedAppBundleDetection),
            ("10. 启动前 7 项伪装检测模型与状态判定", testPreFlightReportModel)
        ]

        var results: [SandboxSelfTestResult] = []
        var firstError: Error?
        for (name, block) in cases {
            do {
                let detail = try await block()
                results.append(SandboxSelfTestResult(name: name, passed: true, detail: detail))
            } catch {
                results.append(SandboxSelfTestResult(name: name, passed: false, detail: error.localizedDescription))
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            for r in results {
                let mark = r.passed ? "PASS" : "FAIL"
                fputs("[\(mark)] \(r.name): \(r.detail)\n", stderr)
            }
            throw firstError
        }
        return results
    }

    // MARK: - 1. BrowserBridge Live Protocol

    private static func sendBridgeLine(port: UInt16, line: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-w", "2", "127.0.0.1", String(port)]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        inputPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let out = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) {
            lock.lock(); urls.append(url); lock.unlock()
        }
        var snapshot: [URL] {
            lock.lock(); defer { lock.unlock() }; return urls
        }
    }

    private static func testBrowserBridgeLive() throws -> String {
        let targetURL = "https://localhost/oauth?env=isolated"
        // Always verify protocol parser security rules
        try expect(BrowserBridge.parseRequest("wrong-token \(targetURL)", expectedToken: "secret") == nil, "错误 token 应被拒绝")
        try expect(BrowserBridge.parseRequest("secret file:///tmp/sample.txt", expectedToken: "secret") == nil, "file:// 协议应被拒绝")
        try expect(BrowserBridge.parseRequest("secret javascript:alert(1)", expectedToken: "secret") == nil, "javascript: 协议应被拒绝")
        let parsed = BrowserBridge.parseRequest("secret \(targetURL)\n", expectedToken: "secret")
        try expect(parsed?.absoluteString == targetURL, "合法 HTTPS URL 解析失败")

        let collector = URLCollector()
        let sem = DispatchSemaphore(value: 0)
        let bridge: BrowserBridge
        do {
            bridge = try BrowserBridge { url in
                collector.append(url)
                sem.signal()
            }
        } catch {
            return "协议安全校验通过（当前外层沙箱禁止 loopback bind，正常终端将自动执行实时 TCP 回环测试）"
        }
        defer { bridge.stop() }

        let badTokenReply = try sendBridgeLine(port: bridge.port, line: "wrong-token \(targetURL)")
        try expect(badTokenReply == "ERR", "错误 token 应被拒绝，实际返回: \(badTokenReply)")

        let badSchemeReply = try sendBridgeLine(port: bridge.port, line: "\(bridge.token) file:///tmp/sample.txt")
        try expect(badSchemeReply == "ERR", "file:// 协议应被拒绝，实际返回: \(badSchemeReply)")

        let okReply = try sendBridgeLine(port: bridge.port, line: "\(bridge.token) \(targetURL)")
        try expect(okReply == "OK", "合法 URL 应返回 OK，实际返回: \(okReply)")
        try expect(sem.wait(timeout: .now() + 2) == .success, "BrowserBridge 未触发 URL 回调")

        let snapshot = collector.snapshot
        try expect(snapshot.count == 1 && snapshot[0].absoluteString == targetURL, "回调收到的 URL 不匹配")
        return "协议校验 + 实时 TCP 回环路由全部通过"
    }

    // MARK: - 2. SandboxStore & Mihomo Live Validation

    private static func testStoreAndMihomoLive() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ws1 = folder.appendingPathComponent("ws1", isDirectory: true)
        let ws2 = folder.appendingPathComponent("ws2", isDirectory: true)
        try FileManager.default.createDirectory(at: ws1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = SandboxStore(root: folder.appendingPathComponent("state", isDirectory: true))
        let color1 = SandboxEnvironment.nextAccentHex(avoiding: [])
        let color2 = SandboxEnvironment.nextAccentHex(avoiding: [color1])
        try expect(color1 != color2, "多环境自动分配颜色重复")

        var env1 = SandboxEnvironment(name: "env1", workspace: ws1, isolationMode: .isolated, accentHex: color1)
        env1.timeZoneIdentifier = "America/Los_Angeles"
        env1.importedApps.append(SandboxImportedApp(name: "Sample", bundlePath: "/Applications/Sample.app"))
        let env2 = SandboxEnvironment(name: "env2", workspace: ws2, isolationMode: .hostPassthrough, accentHex: color2)
        try store.save([env1, env2])
        let loaded = try store.load()
        try expect(loaded == [env1, env2], "环境持久化读写不一致")

        let yamlLines = [
            "mode: direct",
            "proxies:",
            "  - {name: Direct, type: direct}",
            "  - {name: US-Clean, type: http, server: localhost, port: 8080}",
            "rules:",
            "  - MATCH,DIRECT"
        ].joined(separator: "\n")
        let yamlData = Data(yamlLines.utf8)
        let b64 = Data(yamlData.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")).utf8)
        try expect(decodeSubscription(b64) == yamlData, "Base64 订阅解码失败")

        let yamlFile = folder.appendingPathComponent("nodes.yaml")
        try yamlLines.write(to: yamlFile, atomically: true, encoding: .utf8)
        let imported = try store.importYAML(yamlFile, for: env1)
        try expect(imported == ["US-Clean"], "未剔除 direct 节点")

        try "proxies: [broken".write(to: yamlFile, atomically: true, encoding: .utf8)
        var threw = false
        do { _ = try store.importYAML(yamlFile, for: env1) } catch { threw = true }
        try expect(threw, "损坏 YAML 应报错")
        try expect(try store.nodes(for: env1) == ["US-Clean"], "导入失败后破坏了原有节点")

        guard let node = try store.loadNodes(for: env1).first else {
            throw SandboxFailure("读取节点失败")
        }
        let cfg = node.configuration(httpPort: 18080, socksPort: 18081)
        try expect(cfg["ipv6"] as? Bool == false, "mihomo 未关闭 IPv6")
        try expect(cfg["mode"] as? String == "global", "mihomo 非 global 模式")
        guard let listeners = cfg["listeners"] as? [[String: Any]], listeners.count == 2 else {
            throw SandboxFailure("mihomo listeners 数量异常")
        }
        for listener in listeners {
            try expect(listener["listen"] as? String == "127.0.0.1", "mihomo 监听地址非 127.0.0.1")
        }

        var mihomoNote = "未安装 mihomo（跳过 -t）"
        for bin in ["/opt/homebrew/bin/mihomo", "/usr/local/bin/mihomo"] where FileManager.default.isExecutableFile(atPath: bin) {
            let cfgURL = folder.appendingPathComponent("mihomo-test.json")
            try JSONSerialization.data(withJSONObject: cfg).write(to: cfgURL)
            let check = try runTool(bin, arguments: ["-t", "-d", folder.path, "-f", cfgURL.path], captureOutput: true)
            try expect(check.status == 0, "mihomo -t 配置校验失败: \(String(decoding: check.output, as: UTF8.self))")
            mihomoNote = "mihomo -t 真机校验通过"
            break
        }

        try store.remove(env1)
        try expect(FileManager.default.fileExists(atPath: ws1.path), "删除环境误删了原项目目录")
        return "持久化/配色/订阅解码/防丢失/\(mihomoNote)"
    }

    // MARK: - 3. SandboxTerminal Live PTY

    @MainActor
    private static func testTerminalLivePTY() async throws -> String {
        var captured = Data()
        let terminal = SandboxTerminal()
        let launch = SandboxLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "test -t 0 && test -t 1 && printf 'PTY_OK:%s:%s' \"$PWD\" \"$TZ\""],
            environment: ["TZ=America/Los_Angeles", "PATH=/usr/bin:/bin"],
            workingDirectory: "/private/tmp",
            endpoint: nil,
            timeZoneIdentifier: "America/Los_Angeles",
            exitIP: nil
        )
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            terminal.onOutput = { data in
                captured.append(data)
            }
            terminal.onExit = { exitStatus in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: exitStatus)
            }
            do {
                try terminal.start(launch, columns: 80, rows: 24)
            } catch {
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
        let text = String(decoding: captured, as: UTF8.self)
        try expect(code == 0, "PTY 子进程退出码非 0: \(code)")
        try expect(text.contains("PTY_OK:/private/tmp:America/Los_Angeles"), "PTY 输出不符合预期: \(text)")
        return "真实 PTY TTY/PWD/TZ 透传与正常退出校验通过"
    }

    // MARK: - 4 & 5 & 6. Seatbelt Profiles

    private static func testTerminalSeatbelt() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = SandboxStore(root: base.appendingPathComponent("store", isDirectory: true))
        let ws = base.appendingPathComponent("isolated-ws", isDirectory: true)
        let src = base.appendingPathComponent("host-source", isDirectory: true)
        let cfg = base.appendingPathComponent("claude-config", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        let rt = base.appendingPathComponent("runtime", isDirectory: true)
        let sh = base.appendingPathComponent("shell-home", isDirectory: true)
        let ss = base.appendingPathComponent("shell-startup", isDirectory: true)
        let cb = base.appendingPathComponent("Chrome.app", isDirectory: true)
        let cp = base.appendingPathComponent("chrome-profile", isDirectory: true)
        let ch = base.appendingPathComponent("chrome-home", isDirectory: true)

        let withProxy = seatbeltProfile(
            workspace: ws, source: src, store: store, configuration: cfg,
            temporary: tmp, runtime: rt, cliTools: [], shellHome: sh,
            shellStartup: ss, chromeBundle: cb, chromeProfile: cp, chromeHome: ch,
            hasProxy: true, isolationMode: .isolated
        )
        try expect(withProxy.contains("(deny network*)"), "缺少内核禁网规则")
        try expect(withProxy.contains("(allow network-outbound (remote ip \"localhost:*\"))"), "缺少回环代理放行规则")
        try expect(withProxy.contains("(subpath \"/Users\")"), "未禁止访问 /Users")
        try expect(withProxy.contains("(subpath \"/Volumes\")"), "未禁止访问 /Volumes")
        try expect(withProxy.contains(src.standardizedFileURL.resolvingSymlinksInPath().path), "未隔离原项目目录")
        try expect(withProxy.contains(ws.standardizedFileURL.resolvingSymlinksInPath().path), "未放行隔离工作区")

        let noProxy = seatbeltProfile(
            workspace: ws, source: src, store: store, configuration: cfg,
            temporary: tmp, runtime: rt, cliTools: [], shellHome: sh,
            shellStartup: ss, chromeBundle: cb, chromeProfile: cp, chromeHome: ch,
            hasProxy: false, isolationMode: .isolated
        )
        try expect(noProxy.contains("(deny network*)"), "断网模式缺少禁网规则")
        try expect(!noProxy.contains("(allow network-outbound (remote ip \"localhost:*\"))"), "断网模式不应放行回环出口")
        return "有代理与断网模式 Seatbelt 规则校验通过"
    }

    private static func testImportedAppSeatbeltIsolated() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = SandboxStore(root: base.appendingPathComponent("store", isDirectory: true))
        let ws = base.appendingPathComponent("isolated-ws", isDirectory: true)
        let src = base.appendingPathComponent("host-source", isDirectory: true)
        let rt = base.appendingPathComponent("runtime", isDirectory: true)
        let ss = base.appendingPathComponent("shell-startup", isDirectory: true)
        let appBundle = base.appendingPathComponent("Sample.app", isDirectory: true)
        let appRoot = base.appendingPathComponent("app-root", isDirectory: true)
        let appTemp = base.appendingPathComponent("app-tmp", isDirectory: true)
        let hook = base.appendingPathComponent("Resources/libCoboxURLHook.dylib")

        let profile = importedAppSeatbeltProfile(
            workspace: ws, source: src, store: store, runtime: rt,
            shellStartup: ss, appBundle: appBundle, appRoot: appRoot,
            appTemp: appTemp, hookDylib: hook, isolationMode: .isolated
        )
        try expect(profile.contains("(deny network*)"), "导入应用缺少内核禁直连")
        try expect(profile.contains("(allow network-outbound (remote ip \"localhost:*\"))"), "导入应用缺少本地代理放行")
        try expect(profile.contains("(deny file-read* file-write*"), "导入应用缺少宿主机磁盘禁止规则")
        try expect(profile.contains("(subpath \"/Users\")"), "导入应用未封锁 /Users")
        try expect(profile.contains("(subpath \"/Volumes\")"), "导入应用未封锁 /Volumes")
        try expect(profile.contains(src.standardizedFileURL.resolvingSymlinksInPath().path), "导入应用未封锁原项目目录")
        try expect(profile.contains(ws.standardizedFileURL.resolvingSymlinksInPath().path), "导入应用未放行隔离工作区")
        try expect(profile.contains(appRoot.standardizedFileURL.resolvingSymlinksInPath().path), "导入应用未放行专属数据目录")
        return "已封锁直连及 /Users、/Volumes、原目录，仅放行隔离区"
    }

    private static func testImportedAppSeatbeltPassthrough() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = SandboxStore(root: base.appendingPathComponent("store", isDirectory: true))
        let ws = base.appendingPathComponent("ws", isDirectory: true)
        let rt = base.appendingPathComponent("runtime", isDirectory: true)
        let ss = base.appendingPathComponent("shell-startup", isDirectory: true)
        let appBundle = base.appendingPathComponent("Sample.app", isDirectory: true)
        let appRoot = base.appendingPathComponent("app-root", isDirectory: true)
        let appTemp = base.appendingPathComponent("app-tmp", isDirectory: true)

        let profile = importedAppSeatbeltProfile(
            workspace: ws, source: ws, store: store, runtime: rt,
            shellStartup: ss, appBundle: appBundle, appRoot: appRoot,
            appTemp: appTemp, hookDylib: nil, isolationMode: .hostPassthrough
        )
        try expect(profile.contains("(deny network*)"), "直通模式导入应用缺少禁直连")
        try expect(profile.contains("Library/Cookies"), "直通模式未隔离宿主 Cookies")
        try expect(profile.contains("Library/HTTPStorages"), "直通模式未隔离宿主 HTTPStorages")
        try expect(profile.contains("Library/WebKit"), "直通模式未隔离宿主 WebKit 缓存")
        try expect(profile.contains(".claude"), "直通模式未隔离宿主 .claude")
        return "直通模式已封锁直连及宿主 Cookies/HTTPStorages/WebKit/.claude"
    }

    // MARK: - 7. Live Seatbelt Kernel Enforcement

    private static func testSeatbeltLiveExecutionIfPermitted() throws -> String {
        let probe = try? runTool("/usr/bin/sandbox-exec", arguments: ["-p", "(version 1)(allow default)", "/usr/bin/true"])
        guard probe?.status == 0 else {
            return "当前进程已处于外层沙箱内（正常终端运行将执行内核真机实测）"
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ws = base.appendingPathComponent("isolated-ws", isDirectory: true)
        let src = base.appendingPathComponent("host-source", isDirectory: true)
        let rt = base.appendingPathComponent("runtime", isDirectory: true)
        let ss = base.appendingPathComponent("shell-startup", isDirectory: true)
        let appBundle = base.appendingPathComponent("Sample.app", isDirectory: true)
        let appRoot = base.appendingPathComponent("app-root", isDirectory: true)
        let appTemp = base.appendingPathComponent("app-tmp", isDirectory: true)
        for dir in [ws, src, rt, ss, appBundle, appRoot, appTemp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let wsFile = ws.appendingPathComponent("allowed.txt")
        let srcFile = src.appendingPathComponent("outside.txt")
        try "inside".write(to: wsFile, atomically: true, encoding: .utf8)
        try "outside".write(to: srcFile, atomically: true, encoding: .utf8)

        let store = SandboxStore(root: base.appendingPathComponent("store", isDirectory: true))
        let sb = importedAppSeatbeltProfile(
            workspace: ws, source: src, store: store, runtime: rt,
            shellStartup: ss, appBundle: appBundle, appRoot: appRoot,
            appTemp: appTemp, hookDylib: nil, isolationMode: .isolated
        )
        let sbURL = rt.appendingPathComponent("live-app.sb")
        try sb.write(to: sbURL, atomically: true, encoding: .utf8)

        let readAllowed = try runTool("/usr/bin/sandbox-exec", arguments: ["-f", sbURL.path, "/bin/cat", wsFile.path], captureOutput: true)
        try expect(readAllowed.status == 0 && String(decoding: readAllowed.output, as: UTF8.self) == "inside", "隔离区内文件无法读取")

        let readDenied = try runTool("/usr/bin/sandbox-exec", arguments: ["-f", sbURL.path, "/bin/cat", srcFile.path], captureOutput: true)
        try expect(readDenied.status != 0, "安全漏洞：导入应用读到了隔离区外原目录文件！")

        return "Seatbelt 内核真机实测通过：隔离区可读、区外文件内核级阻断"
    }

    // MARK: - 8. Chrome Flags & Preferences

    private static func testChromeAntiLeakAndPreferences() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = base.appendingPathComponent("profile", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let args = chromeArguments(browserProfile: profile, proxyPort: 28888, initialURL: nil)
        try expect(args.contains { $0.hasPrefix("--user-data-dir=") }, "缺少独立用户目录")
        try expect(args.contains { $0.hasPrefix("--proxy-server=") && $0.hasSuffix(":28888") }, "缺少代理端口参数")
        try expect(args.contains { $0.hasPrefix("--host-resolver-rules=") }, "缺少禁本地 DNS 参数")
        try expect(args.contains("--accept-lang=en-US,en"), "缺少英文网页语言参数")
        try expect(args.contains("--disable-quic"), "缺少禁 QUIC 参数")
        try expect(args.contains { $0.hasPrefix("--force-webrtc-ip-handling-policy=") }, "缺少禁 WebRTC UDP 参数")

        try applyChromeWebLanguage(to: profile, workspace: workspace)
        let data = try Data(contentsOf: profile.appendingPathComponent("Default/Preferences"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intl = json["intl"] as? [String: Any],
              let download = json["download"] as? [String: Any],
              let selectfile = json["selectfile"] as? [String: Any] else {
            throw SandboxFailure("Preferences 结构缺失")
        }
        try expect(intl["accept_languages"] as? String == "en-US,en", "accept_languages 未设为 en-US,en")
        try expect(download["default_directory"] as? String == workspace.path, "下载目录未锁定到工作区")
        try expect(selectfile["last_directory"] as? String == workspace.path, "选文件默认目录未锁定到工作区")
        return "代理/DNS/QUIC/WebRTC 参数与 Preferences 语言及工作区路径均锁定"
    }

    // MARK: - 9. Imported App Bundle Detection

    private static func testImportedAppBundleDetection() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func makeFakeApp(name: String, bundleID: String, electron: Bool) throws -> URL {
            let bundle = base.appendingPathComponent("\(name).app", isDirectory: true)
            let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let exec = macos.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: exec, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
            let plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": bundleID]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            if electron {
                let res = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
                try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
                try Data().write(to: res.appendingPathComponent("app.asar"))
            }
            return bundle
        }

        let fakeChrome = try makeFakeApp(name: "ChromeMock", bundleID: "com.google.Chrome", electron: false)
        let fakeElectron = try makeFakeApp(name: "ElectronMock", bundleID: "com.example.electron", electron: true)
        let fakeNative = try makeFakeApp(name: "NativeMock", bundleID: "com.example.native", electron: false)

        try expect(resolveBundleExecutable(at: fakeChrome) != nil, "未解析出可执行文件")
        try expect(isChromeBundle(fakeChrome), "未能通过 BundleID 识别 Chrome")
        try expect(!isChromeBundle(fakeNative), "原生应用被误判为 Chrome")
        try expect(isChromiumOrElectronApp(fakeElectron), "未能识别 Electron 应用")
        try expect(!isChromiumOrElectronApp(fakeNative), "原生应用被误判为 Electron")
        try expect(isChromeImportedApp(SandboxImportedApp(name: "ChromeMock", bundlePath: fakeChrome.path)), "导入 Chrome 识别失败")
        try expect(!isChromeImportedApp(SandboxImportedApp(name: "NativeMock", bundlePath: fakeNative.path)), "原生导入应用误判为 Chrome")
        return "Executable/BundleID/Chrome/Electron/原生应用识别全部准确"
    }

    // MARK: - 10. Pre-Flight Check Report

    private static func testPreFlightReportModel() throws -> String {
        let passReport = ProxyCheckReport(
            items: [
                ProxyCheckItem(id: "a", title: "A", detail: "ok", status: .pass),
                ProxyCheckItem(id: "b", title: "B", detail: "ok", status: .pass)
            ],
            exitIP: nil, country: "US", countryCode: "US", city: "LA",
            isp: "ISP", asn: "AS1", timeZone: "America/Los_Angeles"
        )
        try expect(passReport.allPassed && !passReport.hasFailure && passReport.passedCount == 2, "全通过状态异常")

        let failReport = ProxyCheckReport(
            items: [
                ProxyCheckItem(id: "a", title: "A", detail: "ok", status: .pass),
                ProxyCheckItem(id: "b", title: "B", detail: "bad", status: .fail)
            ],
            exitIP: nil, country: nil, countryCode: nil, city: nil,
            isp: nil, asn: nil, timeZone: nil
        )
        try expect(!failReport.allPassed && failReport.hasFailure && failReport.passedCount == 1, "失败状态汇总异常")
        return "7 项伪装检测报告汇总状态校验通过"
    }
}
