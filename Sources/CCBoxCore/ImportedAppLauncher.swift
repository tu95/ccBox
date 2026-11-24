import Foundation
import Security

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

private let requiredHookEntitlements: [String: Any] = [
    "com.apple.security.cs.allow-dyld-environment-variables": true,
    "com.apple.security.cs.disable-library-validation": true,
    "com.apple.security.cs.allow-unsigned-executable-memory": true,
    "com.apple.security.cs.allow-jit": true
]

/// Entitlements that require a real Apple Developer TeamID / provisioning profile
/// and will cause AMFI to SIGKILL an ad-hoc signed binary if retained.
private func isRestrictedEntitlementKey(_ key: String) -> Bool {
    if key == "aps-environment"
        || key == "application-identifier"
        || key == "com.apple.application-identifier"
        || key == "keychain-access-groups"
        || key == "com.apple.security.application-groups"
        || key == "com.apple.security.app-sandbox"
        || key == "com.apple.security.inherit" {
        return true
    }
    let restrictedPrefixes = [
        "com.apple.developer.",
        "com.apple.private.",
        "com.apple.security.temporary-exception.",
        "com.apple.security.exception."
    ]
    return restrictedPrefixes.contains { key.hasPrefix($0) }
}

func mergeHookEntitlements(originalPlistData: Data?) -> Data? {
    var merged: [String: Any] = [:]
    if let originalPlistData,
       let raw = try? PropertyListSerialization.propertyList(from: originalPlistData, format: nil) as? [String: Any] {
        for (key, value) in raw where !isRestrictedEntitlementKey(key) {
            merged[key] = value
        }
    }
    for (key, value) in requiredHookEntitlements {
        merged[key] = value
    }
    return try? PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0)
}

private func extractOriginalEntitlements(for executableURL: URL) -> Data? {
    guard let result = try? runTool(
        "/usr/bin/codesign",
        arguments: ["-d", "--entitlements", ":-", executableURL.path],
        captureOutput: true
    ), result.status == 0, !result.output.isEmpty else {
        return nil
    }
    return result.output
}

private func ensureHookableSignature(for executableURL: URL, targetDir: URL) {
    let marker = targetDir.appendingPathComponent(".cobox-url-hook-v2")
    if FileManager.default.fileExists(atPath: marker.path) { return }
    let entitlementsURL = targetDir.appendingPathComponent(".cobox-hook-entitlements.plist")
    defer { try? FileManager.default.removeItem(at: entitlementsURL) }
    let originalEntitlements = extractOriginalEntitlements(for: executableURL)
    guard let mergedData = mergeHookEntitlements(originalPlistData: originalEntitlements),
          (try? writePrivate(mergedData, to: entitlementsURL)) != nil else {
        return
    }
    let result = try? runTool(
        "/usr/bin/codesign",
        arguments: ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, executableURL.path]
    )
    if result?.status == 0 {
        try? writePrivate(Data("2\n".utf8), to: marker)
    }
}

private let legacyIsolatedKeychainPassword = "ccbox-isolated-keychain"

func isolatedKeychainSecretURL(at appHome: URL) -> URL {
    appHome.appendingPathComponent("Library/Keychains/.keychain-secret")
}

private func generateRandomKeychainPassword() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status == errSecSuccess {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
}

func loadOrCreateIsolatedKeychainPassword(at appHome: URL, keychainExists: Bool) throws -> String {
    let secretURL = isolatedKeychainSecretURL(at: appHome)
    if let data = try? Data(contentsOf: secretURL) {
        let existing = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            return existing
        }
    }
    // Preserve compatibility with pre-existing isolated keychains created before per-env secrets.
    let password = keychainExists ? legacyIsolatedKeychainPassword : generateRandomKeychainPassword()
    try writePrivate(Data((password + "\n").utf8), to: secretURL)
    return password
}

/// Pre-creates and unlocks a dedicated file-based `login.keychain-db` inside the
/// imported app's isolated `HOME` with a per-environment random secret stored in
/// a `0600` file, without polluting the host user's keychain search list or
/// calling authorization-triggering APIs (such as `SecKeychainSetSettings`).
@discardableResult
func ensureIsolatedLoginKeychain(at appHome: URL) -> Bool {
    let keychainsDir = appHome.appendingPathComponent("Library/Keychains", isDirectory: true)
    do {
        try makePrivateDirectory(keychainsDir)
    } catch {
        return false
    }
    let keychainURL = keychainsDir.appendingPathComponent("login.keychain-db")
    let keychainExists = FileManager.default.fileExists(atPath: keychainURL.path)
    guard let password = try? loadOrCreateIsolatedKeychainPassword(at: appHome, keychainExists: keychainExists) else {
        return false
    }

    // Never allow Security.framework to pop up a modal keychain password dialog.
    var previousUIAllowed = DarwinBoolean(true)
    let hasUIState = SecKeychainGetUserInteractionAllowed(&previousUIAllowed) == errSecSuccess
    _ = SecKeychainSetUserInteractionAllowed(false)
    defer {
        if hasUIState {
            _ = SecKeychainSetUserInteractionAllowed(previousUIAllowed.boolValue)
        }
    }

    // Snapshot the user's current keychain search list so we can restore it if needed.
    var originalSearchList: CFArray?
    let hasOriginalList = SecKeychainCopySearchList(&originalSearchList) == errSecSuccess

    var keychain: SecKeychain?
    let status: OSStatus
    if keychainExists {
        status = SecKeychainOpen(keychainURL.path, &keychain)
    } else {
        status = password.withCString { cstr in
            SecKeychainCreate(
                keychainURL.path,
                UInt32(strlen(cstr)),
                cstr,
                false,
                nil,
                &keychain
            )
        }
    }

    if hasOriginalList, let list = originalSearchList {
        _ = SecKeychainSetSearchList(list)
    }

    guard status == errSecSuccess, let kc = keychain else {
        return false
    }

    // Only unlock — never call SecKeychainSetSettings/SecKeychainChangePassword,
    // which can trigger system authorization prompts on locked keychains.
    let unlockStatus: OSStatus = password.withCString { cstr in
        SecKeychainUnlock(kc, UInt32(strlen(cstr)), cstr, true)
    }
    return unlockStatus == errSecSuccess
}

private func importedAppDirectory(environmentID: UUID, appID: UUID, storeRoot: URL) -> URL {
    storeRoot
        .appendingPathComponent(environmentID.uuidString, isDirectory: true)
        .appendingPathComponent("ImportedApps/\(appID.uuidString)", isDirectory: true)
}

private func legacyImportedAppDirectory(appID: UUID, storeRoot: URL) -> URL {
    storeRoot.appendingPathComponent("Runtime/ImportedApps/\(appID.uuidString)", isDirectory: true)
}

private func copyImportedAppBundle(from source: URL, to targetDir: URL) throws -> URL {
    guard resolveBundleExecutable(at: source) != nil else {
        throw SandboxFailure("找不到 \(source.deletingPathExtension().lastPathComponent) 的可执行文件。")
    }
    let targetBundle = targetDir.appendingPathComponent(source.lastPathComponent, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: targetBundle.path) else {
        throw SandboxFailure("应用副本路径已存在但无效，请移除后重新导入。")
    }
    try makePrivateDirectory(targetDir)
    let staging = targetDir.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let result = try runTool("/usr/bin/ditto", arguments: [source.path, staging.path])
    guard result.status == 0 else {
        throw SandboxFailure("完整复制 \(source.lastPathComponent) 到环境目录失败。")
    }
    guard resolveBundleExecutable(at: staging) != nil else {
        throw SandboxFailure("应用副本缺少可执行文件，未导入。")
    }
    try FileManager.default.moveItem(at: staging, to: targetBundle)
    return targetBundle
}

func importAppBundle(at url: URL, environmentID: UUID, storeRoot: URL) throws -> SandboxImportedApp {
    let source = url.standardizedFileURL.resolvingSymlinksInPath()
    let appID = UUID()
    let targetDir = importedAppDirectory(environmentID: environmentID, appID: appID, storeRoot: storeRoot)
    do {
        let copied = try copyImportedAppBundle(from: source, to: targetDir)
        return SandboxImportedApp(
            id: appID,
            name: source.deletingPathExtension().lastPathComponent,
            bundlePath: copied.path,
            sourceBundlePath: source.path
        )
    } catch {
        try? FileManager.default.removeItem(at: targetDir)
        throw error
    }
}

func removeImportedAppCopy(_ app: SandboxImportedApp, environmentID: UUID, storeRoot: URL) {
    let current = importedAppDirectory(environmentID: environmentID, appID: app.id, storeRoot: storeRoot)
    let legacy = legacyImportedAppDirectory(appID: app.id, storeRoot: storeRoot)
    try? FileManager.default.removeItem(at: current)
    try? FileManager.default.removeItem(at: legacy)
}

func prepareImportedAppBundle(
    _ app: SandboxImportedApp, environmentID: UUID, storeRoot: URL
) async throws -> PreparedImportedApp {
    let storedBundle = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
    let targetDir = importedAppDirectory(environmentID: environmentID, appID: app.id, storeRoot: storeRoot)
    let targetBundle = targetDir.appendingPathComponent(storedBundle.lastPathComponent, isDirectory: true)

    if resolveBundleExecutable(at: targetBundle) == nil {
        if app.sourceBundlePath != nil {
            throw SandboxFailure("\(app.name) 的环境副本已丢失，请移除后重新导入。")
        }
        let legacyDir = legacyImportedAppDirectory(appID: app.id, storeRoot: storeRoot)
        let legacyBundle = legacyDir.appendingPathComponent(storedBundle.lastPathComponent, isDirectory: true)
        if resolveBundleExecutable(at: legacyBundle) != nil {
            _ = try copyImportedAppBundle(from: legacyBundle, to: targetDir)
        } else {
            _ = try copyImportedAppBundle(from: storedBundle, to: targetDir)
        }
    }

    guard let executable = resolveBundleExecutable(at: targetBundle) else {
        throw SandboxFailure("无法解析 \(app.name) 副本的启动入口。")
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
