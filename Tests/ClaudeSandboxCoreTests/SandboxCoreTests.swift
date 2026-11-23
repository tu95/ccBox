import XCTest
@testable import ClaudeSandboxCore

final class SandboxCoreTests: XCTestCase {
    func testImportRemovesDirectAndPreservesPriorNodesAfterFailedImport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = SandboxStore(root: folder.appendingPathComponent("state"))
        let environment = SandboxEnvironment(name: "test", workspace: folder.appendingPathComponent("repo"))
        let yaml = folder.appendingPathComponent("nodes.yaml")
        try """
        mode: direct
        proxies:
          - {name: Direct, type: direct}
          - {name: Example, type: http, server: 192.0.2.18, port: 3128}
        rules:
          - MATCH,DIRECT
        """.write(to: yaml, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.importYAML(yaml, for: environment), ["Example"])

        let node = try XCTUnwrap(store.loadNodes(for: environment).first)
        let generated = node.configuration(httpPort: 12345, socksPort: 12346)
        let listener = try XCTUnwrap((generated["listeners"] as? [[String: Any]])?.first)
        XCTAssertEqual(listener["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(listener["port"] as? Int, 12345)
        XCTAssertEqual(generated["mode"] as? String, "global")
        XCTAssertEqual((generated["listeners"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((generated["proxy-groups"] as? [[String: Any]])?.count, 1)
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/mihomo") {
            let config = folder.appendingPathComponent("proxy.json")
            try JSONSerialization.data(withJSONObject: generated).write(to: config)
            let result = try runTool("/opt/homebrew/bin/mihomo", arguments: ["-t", "-d", folder.path, "-f", config.path])
            XCTAssertEqual(result.status, 0)
        }

        try "proxies: [broken".write(to: yaml, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.importYAML(yaml, for: environment))
        XCTAssertEqual(try store.nodes(for: environment), ["Example"])
    }

    func testTimeZonePersistsAndEnvironmentRemovalPreservesWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = SandboxStore(root: folder.appendingPathComponent("state"))
        var environment = SandboxEnvironment(name: "env", workspace: workspace)
        XCTAssertNil(environment.timeZoneIdentifier)
        environment.timeZoneIdentifier = "Asia/Shanghai"
        try store.save([environment])
        XCTAssertEqual(try store.load(), [environment])
        try store.remove(environment)
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testRuntimeVersionRequired() {
        XCTAssertFalse(supportsRuntimeVersion(Data("0.0.82\n".utf8)))
        XCTAssertTrue(supportsRuntimeVersion(Data("0.0.83\n".utf8)))
        XCTAssertTrue(supportsRuntimeVersion(Data("0.1.1\n".utf8)))
        XCTAssertFalse(supportsRuntimeVersion(Data("anything\n".utf8)))
    }

    func testPlainAndEncodedYAMLSubscription() {
        let yaml = Data("proxies:\n  - {name: Example, type: http, server: 192.0.2.18, port: 3128}\n".utf8)
        let wrapped = Data("\n\(yaml.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))\n".utf8)
        XCTAssertEqual(decodeSubscription(yaml), yaml)
        XCTAssertEqual(decodeSubscription(wrapped), yaml)
    }

    func testLiveSubscriptionImport() async throws {
        guard let source = ProcessInfo.processInfo.environment["CLAUDE_SANDBOX_TEST_SUBSCRIPTION_URL"],
              let url = URL(string: source) else {
            throw XCTSkip("Set CLAUDE_SANDBOX_TEST_SUBSCRIPTION_URL to a test Clash subscription")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SandboxStore(root: folder.appendingPathComponent("state"))
        let environment = SandboxEnvironment(name: "Subscription", workspace: folder)
        let names = try await store.importSubscription(url, for: environment)
        XCTAssertEqual(names, ["Test node"])
        XCTAssertEqual(try store.nodes(for: environment), names)
    }

    @MainActor
    func testLiveSeatbeltRequiresProxyAndAppliesTimeZone() async throws {
        guard let proxyPort = ProcessInfo.processInfo.environment["CLAUDE_SANDBOX_TEST_PROXY_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Set CLAUDE_SANDBOX_TEST_PROXY_PORT to an HTTP proxy on 127.0.0.1")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = SandboxStore(root: folder.appendingPathComponent("state"))
        let runner = SandboxRunner(store: store)
        defer { runner.stop() }
        var configuration = SandboxEnvironment(name: "Live", workspace: workspace)
        configuration.node = "Loopback test"
        configuration.timeZoneIdentifier = "UTC"
        let yaml = folder.appendingPathComponent("nodes.yaml")
        try """
        proxies:
          - {name: Loopback test, type: http, server: 127.0.0.1, port: \(proxyPort)}
        """.write(to: yaml, atomically: true, encoding: .utf8)
        _ = try store.importYAML(yaml, for: configuration)
        let launch = try await runner.start(configuration)
        let environment = Dictionary(uniqueKeysWithValues: launch.environment.compactMap { entry -> (String, String)? in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })

        func throughSeatbelt(_ command: [String]) throws -> ToolResult {
            try runTool(launch.executable, arguments: Array(launch.arguments.prefix(3)) + command,
                        environment: environment, captureOutput: true)
        }
        let output = try throughSeatbelt(["/bin/sh", "-c", "printf '%s' \"$TZ\""])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(String(decoding: output.output, as: UTF8.self), "UTC")
        let request = ["/usr/bin/curl", "-q", "--silent", "--max-time", "6", "--output", "/dev/null"]
        let url = "https://api.anthropic.com/"
        XCTAssertEqual(try throughSeatbelt(request + [url]).status, 0)
        XCTAssertNotEqual(try throughSeatbelt(request + ["--noproxy", "*", url]).status, 0)

        let isolate = try throughSeatbelt(["/bin/cat", store.directory(for: configuration).appendingPathComponent("nodes.json").path])
        XCTAssertNotEqual(isolate.status, 0)
        XCTAssertNotEqual(try throughSeatbelt(request + ["--fail", "https://example.com/"]).status, 0)

        let terminal = SandboxTerminal()
        let received = expectation(description: "Interactive zsh executed the command")
        var terminalOutput = Data()
        var ranCommand = false
        terminal.onOutput = { bytes in
            terminalOutput.append(bytes)
            let output = String(decoding: terminalOutput, as: UTF8.self)
            if !ranCommand, output.contains("sandbox-ready:UTC") {
                ranCommand = true
                received.fulfill()
            }
        }
        try terminal.start(launch, columns: 90, rows: 30)
        terminal.write(Data("printf 'sandbox-ready:%s\\n' \"$TZ\"\n".utf8))
        await fulfillment(of: [received], timeout: 8)
        terminal.stop()
        XCTAssertTrue(ranCommand, "Startup output: \(String(decoding: terminalOutput.suffix(1_500), as: UTF8.self))")
        let claude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        if FileManager.default.isExecutableFile(atPath: claude.path) {
            XCTAssertEqual(try throughSeatbelt(["/bin/zsh", "-fc", "claude --version"]).status, 0)
        }

        let savedPolicy = folder.appendingPathComponent("closed-policy.json")
        try FileManager.default.copyItem(atPath: launch.arguments[1], toPath: savedPolicy.path)
        runner.stop()
        var status: Int32 = 0
        for _ in 0..<3 {
            status = try runTool(launch.executable, arguments: ["--settings", savedPolicy.path, "--"] + request + [url],
                                 environment: environment.filter { $0.key != "TMPDIR" }).status
            if status != 0 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNotEqual(status, 0)

        let exit = try await runner.inspectExit(configuration)
        XCTAssertNotNil(exit.ip)
        XCTAssertNotNil(exit.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)))
    }

    @MainActor
    func testOfflineShellUsesSeatbeltWithoutProxy() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw XCTSkip("sandbox-exec is unavailable") }
        let probe = try? runTool("/usr/bin/sandbox-exec", arguments: ["-p", "(version 1)(allow default)", "/usr/bin/true"])
        guard probe?.status == 0 else {
            throw XCTSkip("Nested sandbox-exec is blocked by outer sandbox environment")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = folder.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "original".write(to: workspace.appendingPathComponent("project.txt"), atomically: true, encoding: .utf8)
        let store = SandboxStore(root: folder.appendingPathComponent("state"))
        let runner = SandboxRunner(store: store)
        defer { runner.stop() }
        let environment = SandboxEnvironment(name: "Offline", workspace: workspace)
        let homeDirectory = store.directory(for: environment).appendingPathComponent("home", isDirectory: true)
        try makePrivateDirectory(homeDirectory)
        try """
        precmd() { PROMPT='%n@%m %d '; RPROMPT='%d' }
        """.write(to: homeDirectory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let launch = try await runner.start(environment)
        XCTAssertEqual(launch.workingDirectory, store.isolatedWorkspace(for: environment).path)
        XCTAssertNil(launch.endpoint)
        let profile = try String(contentsOfFile: launch.arguments[1], encoding: .utf8)
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertFalse(profile.contains("(allow network-outbound (remote ip \"localhost:*\"))"))

        let terminal = SandboxTerminal()
        let exited = expectation(description: "Interactive shell exited")
        var output = Data()
        terminal.onOutput = { output.append($0) }
        terminal.onExit = { status in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }
        try terminal.start(launch, columns: 100, rows: 30)
        let command = #"pwd; (cd ~ && pwd); test "${psvar[127]}" = /workspace && test -z "$RPROMPT" && git config --global sandbox.probe works && test -f "$HOME/.gitconfig" && test "$(pwd)" = "$PWD" && test "$(pwd -P)" = "$(cd "$1" 2>/dev/null && pwd -P)" && test "$(cat project.txt)" = original && ! cat "$2/project.txt" 2>/dev/null && printf copied > project.txt && exit 0"#
        let workspacePath = launch.workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
        let sourcePath = workspace.path.replacingOccurrences(of: "'", with: "'\\''")
        terminal.write(Data("set -- '\(workspacePath)' '\(sourcePath)'; \(command); exit 1\n".utf8))
        await fulfillment(of: [exited], timeout: 8)
        let terminalText = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(terminalText.contains("\r\n/workspace\r\n/home\r\n"), terminalText)
        let home = try XCTUnwrap(launch.arguments.dropLast().last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.gitconfig"),
                      String(decoding: output, as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("project.txt"), encoding: .utf8), "original")
        runner.stop()
        let reopened = try await runner.start(environment)
        XCTAssertEqual(try String(contentsOfFile: reopened.workingDirectory + "/project.txt", encoding: .utf8), "copied")
    }

    @MainActor
    func testTerminalStartsProgramWithWorkingDirectoryAndTimeZone() async throws {
        let terminal = SandboxTerminal()
        let exited = expectation(description: "PTY command exited")
        var output = Data()
        terminal.onOutput = { output.append($0) }
        terminal.onExit = { status in
            XCTAssertEqual(status, 0)
            exited.fulfill()
        }
        let launch = SandboxLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "test -t 0 && test -t 1 && printf '%s %s' \"$PWD\" \"$TZ\""],
            environment: ["TZ=Asia/Shanghai", "PATH=/usr/bin:/bin"],
            workingDirectory: "/private/tmp", endpoint: "", timeZoneIdentifier: "Asia/Shanghai", exitIP: nil
        )
        try terminal.start(launch, columns: 80, rows: 24)
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("/private/tmp Asia/Shanghai"))
    }

    func testMergeHookEntitlementsPreservesSafeAndStripsRestricted() throws {
        let original: [String: Any] = [
            "com.apple.security.device.camera": true,
            "com.apple.security.automation.apple-events": true,
            "aps-environment": "production",
            "keychain-access-groups": ["EQHXZ8M8AV.com.google.GeminiMacOS"],
            "com.apple.security.application-groups": ["group.com.google.gemini"],
            "com.apple.developer.team-identifier": "EQHXZ8M8AV"
        ]
        let originalData = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        let mergedData = try XCTUnwrap(mergeHookEntitlements(originalPlistData: originalData))
        let merged = try XCTUnwrap(PropertyListSerialization.propertyList(from: mergedData, format: nil) as? [String: Any])

        XCTAssertEqual(merged["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertEqual(merged["com.apple.security.automation.apple-events"] as? Bool, true)
        XCTAssertEqual(merged["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool, true)
        XCTAssertEqual(merged["com.apple.security.cs.disable-library-validation"] as? Bool, true)
        XCTAssertEqual(merged["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool, true)
        XCTAssertEqual(merged["com.apple.security.cs.allow-jit"] as? Bool, true)
        XCTAssertNil(merged["aps-environment"])
        XCTAssertNil(merged["keychain-access-groups"])
        XCTAssertNil(merged["com.apple.security.application-groups"])
        XCTAssertNil(merged["com.apple.developer.team-identifier"])
    }

    func testEnsureIsolatedLoginKeychainCreatesAndUnlocksWithoutPollutingSearchList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let keychainPath = folder.appendingPathComponent("Library/Keychains/login.keychain-db").path
        XCTAssertTrue(ensureIsolatedLoginKeychain(at: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keychainPath))
        // Re-opening and unlocking an existing keychain should also succeed cleanly.
        XCTAssertTrue(ensureIsolatedLoginKeychain(at: folder))

        let listResult = try runTool("/usr/bin/security", arguments: ["list-keychains"], captureOutput: true)
        let listOutput = String(decoding: listResult.output, as: UTF8.self)
        XCTAssertFalse(listOutput.contains(keychainPath), "Isolated keychain must not pollute host search list")
    }
}
