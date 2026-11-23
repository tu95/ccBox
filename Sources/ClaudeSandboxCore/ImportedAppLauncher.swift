import Foundation

struct PreparedImportedApp: Sendable {
    let bundleURL: URL
    let executableURL: URL
    let isChromiumBased: Bool
    let isChrome: Bool
}

func resolveBundleExecutable(at bundleURL: URL) -> URL? {
    let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let executableName = dict["CFBundleExecutable"] as? String,
          !executableName.isEmpty else {
        return nil
    }
    let executable = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
    return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
}

func resolveBundleIdentifier(at bundleURL: URL) -> String? {
    let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }
    return dict["CFBundleIdentifier"] as? String
}

func isChromeBundle(_ bundleURL: URL) -> Bool {
    if let bundleID = resolveBundleIdentifier(at: bundleURL)?.lowercased(),
       bundleID.hasPrefix("com.google.chrome") {
        return true
    }
    return bundleURL.lastPathComponent.lowercased().contains("google chrome")
}

func isChromeImportedApp(_ app: SandboxImportedApp) -> Bool {
    let url = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
    if isChromeBundle(url) { return true }
    let lower = app.name.lowercased()
    return lower == "google chrome" || lower.hasPrefix("google chrome ")
}

func isChromiumOrElectronApp(_ bundleURL: URL) -> Bool {
    let fm = FileManager.default
    let markers = [
        "Contents/Frameworks/Electron Framework.framework",
        "Contents/Frameworks/Google Chrome Framework.framework",
        "Contents/Frameworks/Chromium Embedded Framework.framework",
        "Contents/Resources/app.asar"
    ]
    return markers.contains { fm.fileExists(atPath: bundleURL.appendingPathComponent($0).path) }
}

func coboxURLHookDylibURL() -> URL? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("libCoboxURLHook.dylib"),
          FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    return url
}

private let hookEntitlementsPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
</dict>
</plist>
"""

private func ensureHookableSignature(for executableURL: URL, targetDir: URL) {
    let marker = targetDir.appendingPathComponent(".cobox-url-hook-v1")
    if FileManager.default.fileExists(atPath: marker.path) { return }
    let entitlementsURL = targetDir.appendingPathComponent(".cobox-hook-entitlements.plist")
    defer { try? FileManager.default.removeItem(at: entitlementsURL) }
    guard (try? writePrivate(Data(hookEntitlementsPlist.utf8), to: entitlementsURL)) != nil else { return }
    let result = try? runTool(
        "/usr/bin/codesign",
        arguments: ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, executableURL.path]
    )
    if result?.status == 0 {
        try? writePrivate(Data("1\n".utf8), to: marker)
    }
}

func prepareImportedAppBundle(_ app: SandboxImportedApp, storeRoot: URL) async throws -> PreparedImportedApp {
    let source = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
    let targetDir = storeRoot.appendingPathComponent("Runtime/ImportedApps/\(app.id.uuidString)", isDirectory: true)
    let targetBundle = targetDir.appendingPathComponent(source.lastPathComponent, isDirectory: true)

    if let existingExecutable = resolveBundleExecutable(at: targetBundle) {
        let isChrome = isChromeBundle(targetBundle)
        if !isChrome {
            await Task.detached { ensureHookableSignature(for: existingExecutable, targetDir: targetDir) }.value
        }
        return PreparedImportedApp(
            bundleURL: targetBundle,
            executableURL: existingExecutable,
            isChromiumBased: isChromiumOrElectronApp(targetBundle),
            isChrome: isChrome
        )
    }
    guard resolveBundleExecutable(at: source) != nil else {
        throw SandboxFailure("找不到 \(app.name) 的可执行文件，请确认原应用仍存在。")
    }
    try makePrivateDirectory(targetDir)
    let staging = targetDir.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
    let copied = await Task.detached {
        let result = try? runTool("/usr/bin/ditto", arguments: [source.path, staging.path])
        return result?.status == 0
    }.value
    guard copied else {
        try? FileManager.default.removeItem(at: staging)
        throw SandboxFailure("复制 \(app.name) 到沙箱目录失败。")
    }
    do {
        try FileManager.default.moveItem(at: staging, to: targetBundle)
    } catch {
        try? FileManager.default.removeItem(at: staging)
        if resolveBundleExecutable(at: targetBundle) == nil {
            throw SandboxFailure("安装复制版 \(app.name) 失败：\(error.localizedDescription)")
        }
    }
    guard let executable = resolveBundleExecutable(at: targetBundle) else {
        throw SandboxFailure("无法解析 \(app.name) 的启动入口。")
    }
    let isChrome = isChromeBundle(targetBundle)
    if !isChrome {
        await Task.detached { ensureHookableSignature(for: executable, targetDir: targetDir) }.value
    }
    return PreparedImportedApp(
        bundleURL: targetBundle,
        executableURL: executable,
        isChromiumBased: isChromiumOrElectronApp(targetBundle),
        isChrome: isChrome
    )
}
