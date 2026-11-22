import Foundation

struct PreparedImportedApp: Sendable {
    let bundleURL: URL
    let executableURL: URL
    let isChromiumBased: Bool
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

func prepareImportedAppBundle(_ app: SandboxImportedApp, storeRoot: URL) async throws -> PreparedImportedApp {
    let source = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
    let targetDir = storeRoot.appendingPathComponent("Runtime/ImportedApps/\(app.id.uuidString)", isDirectory: true)
    let targetBundle = targetDir.appendingPathComponent(source.lastPathComponent, isDirectory: true)

    if let existingExecutable = resolveBundleExecutable(at: targetBundle) {
        return PreparedImportedApp(
            bundleURL: targetBundle,
            executableURL: existingExecutable,
            isChromiumBased: isChromiumOrElectronApp(targetBundle)
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
    return PreparedImportedApp(
        bundleURL: targetBundle,
        executableURL: executable,
        isChromiumBased: isChromiumOrElectronApp(targetBundle)
    )
}
