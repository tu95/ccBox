import Darwin
import Foundation

/// Resolves a path to the real kernel vnode path expected by macOS Seatbelt.
/// `URL.resolvingSymlinksInPath()` strips `/private` from `/var`, `/tmp`, `/etc`,
/// which breaks Seatbelt kernel matching; POSIX `realpath(3)` preserves `/private/...`.
func canonicalSeatbeltPath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    if let resolved = realpath(standardized, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // Walk up to the nearest existing ancestor so non-existent leaf paths still resolve symlinks.
    var cursor = URL(fileURLWithPath: standardized)
    var trailing: [String] = []
    while cursor.path != "/" {
        if let resolved = realpath(cursor.path, nil) {
            defer { free(resolved) }
            var result = URL(fileURLWithPath: String(cString: resolved))
            for component in trailing.reversed() {
                result.appendPathComponent(component)
            }
            return result.path
        }
        trailing.append(cursor.lastPathComponent)
        cursor.deleteLastPathComponent()
    }

    for prefix in ["/var", "/tmp", "/etc"] {
        if standardized == prefix || standardized.hasPrefix(prefix + "/") {
            return "/private" + standardized
        }
    }
    return standardized
}

private func sbplString(_ path: String) -> String {
    let escaped = canonicalSeatbeltPath(path)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func sbplSubpaths(_ paths: [String]) -> String {
    Array(Set(paths.map(canonicalSeatbeltPath))).sorted().map { "  (subpath \(sbplString($0)))" }.joined(separator: "\n")
}

private func sbplPathRegex(_ paths: [URL]) -> String {
    let alternatives = Array(Set(paths.map { canonicalSeatbeltPath($0.path) })).sorted()
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")
    return "^(\(alternatives))(/|$)"
}

private func isolatedProfile(
    workspace: URL,
    source: URL,
    store: SandboxStore,
    runtime: URL,
    readWrite: [URL],
    readOnly: [URL],
    allowedLoopbackPorts: Set<Int>
) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    let socketRegex = sbplPathRegex([workspace.deletingLastPathComponent(), runtime])
    var lines = [
        "(version 1)",
        "(allow default)",
        "(deny network*)",
        "(allow system-socket (socket-domain AF_UNIX))",
        "(allow network-bind (local unix-socket (path-regex #\"\(socketRegex)\")))",
        "(allow network-inbound (local unix-socket (path-regex #\"\(socketRegex)\")))",
        "(allow network-outbound (remote unix-socket (path-regex #\"\(socketRegex)\")))",
        "(allow network-bind (local ip \"localhost:*\"))",
        "(allow network-inbound (local ip \"localhost:*\"))"
    ]
    for port in allowedLoopbackPorts.sorted() {
        lines.append("(allow network-outbound (remote ip \"localhost:\(port)\"))")
    }

    let denied = [
        "/Users", "/Volumes", "/Applications", "/private/tmp", "/private/var/tmp", "/private/var/folders",
        home.path, store.root.path, runtime.path, source.path
    ]
    lines.append("(deny file-read* file-write*\n\(sbplSubpaths(denied)))")
    lines.append("(allow file-read-metadata)")
    lines.append("(allow file-read* file-write*\n\(sbplSubpaths(readWrite.map(\.path))))")
    lines.append("(allow file-read*\n\(sbplSubpaths(readOnly.map(\.path))))")
    let hostTemp = canonicalSeatbeltPath(FileManager.default.temporaryDirectory.path)
    let xcrunCache = NSRegularExpression.escapedPattern(for: hostTemp) + "xcrun_db[^/]*$"
    lines.append("(allow file-read* file-write* (path-regex #\"^\(xcrunCache)\"))")
    return lines.joined(separator: "\n") + "\n"
}

func seatbeltProfile(
    workspace: URL, source: URL, store: SandboxStore, configuration: URL, temporary: URL, runtime: URL,
    cliTools: [String], shellHome: URL, shellStartup: URL, chromeBundle: URL, chromeProfile: URL, chromeHome: URL,
    allowedLoopbackPorts: Set<Int>
) -> String {
    isolatedProfile(
        workspace: workspace,
        source: source,
        store: store,
        runtime: runtime,
        readWrite: [workspace, shellHome, configuration, temporary, chromeProfile, chromeHome],
        readOnly: [shellStartup, chromeBundle] + cliTools.map { URL(fileURLWithPath: $0, isDirectory: true) },
        allowedLoopbackPorts: allowedLoopbackPorts
    )
}

func importedAppSeatbeltProfile(
    workspace: URL,
    source: URL,
    store: SandboxStore,
    runtime: URL,
    shellStartup: URL,
    appBundle: URL,
    appRoot: URL,
    appTemp: URL,
    hookDylib: URL?,
    allowedLoopbackPorts: Set<Int>
) -> String {
    var readOnly = [shellStartup, appBundle]
    if let hookDylib {
        readOnly.append(hookDylib.deletingLastPathComponent())
    }
    return isolatedProfile(
        workspace: workspace,
        source: source,
        store: store,
        runtime: runtime,
        readWrite: [workspace, appRoot, appTemp],
        readOnly: readOnly,
        allowedLoopbackPorts: allowedLoopbackPorts
    )
}
