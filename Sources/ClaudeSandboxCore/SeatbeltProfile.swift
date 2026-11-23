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

func seatbeltProfile(
    workspace: URL, source: URL, store: SandboxStore, configuration: URL, temporary: URL, runtime: URL,
    cliTools: [String], shellHome: URL, shellStartup: URL, chromeBundle: URL, chromeProfile: URL, chromeHome: URL,
    hasProxy: Bool, isolationMode: SandboxIsolationMode
) -> String {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    let home = homeURL.path
    var lines = [
        "(version 1)",
        "(allow default)",
        "(deny network*)",
        "(allow system-socket (socket-domain AF_UNIX))",
        "(allow network-bind (local unix-socket (path-regex #\"^/\")))",
        "(allow network-inbound (local unix-socket (path-regex #\"^/\")))",
        "(allow network-outbound (remote unix-socket (path-regex #\"^/\")))",
        "(allow network-bind (local ip \"*:*\"))",
        "(allow network-inbound (local ip \"*:*\"))"
    ]
    if hasProxy {
        lines.append("(allow network-outbound (remote ip \"localhost:*\"))")
    }

    switch isolationMode {
    case .isolated:
        let denied = ["/Users", "/Volumes", home, store.root.path, runtime.path, source.path]
        let readWrite = [
            workspace.path, shellHome.path, configuration.path, temporary.path,
            chromeProfile.path, chromeHome.path
        ]
        let readOnly = [shellStartup.path, chromeBundle.path] + cliTools
        lines.append("(deny file-read* file-write*\n\(sbplSubpaths(denied)))")
        lines.append("(allow file-read-metadata)")
        lines.append("(allow file-read* file-write*\n\(sbplSubpaths(readWrite)))")
        lines.append("(allow file-read*\n\(sbplSubpaths(readOnly)))")
    case .hostPassthrough:
        let claudeDir = homeURL.appendingPathComponent(".claude").path
        let claudeFile = homeURL.appendingPathComponent(".claude.json").path
        let deniedSubpaths = [claudeDir, store.root.path, runtime.path]
        let readWrite = [
            workspace.path, configuration.path, temporary.path,
            chromeProfile.path, chromeHome.path
        ]
        let readOnly = [shellStartup.path, chromeBundle.path]
        lines.append("(deny file-read* file-write*\n\(sbplSubpaths(deniedSubpaths))\n  (literal \(sbplString(claudeFile))))")
        lines.append("(allow file-read-metadata)")
        lines.append("(allow file-read* file-write*\n\(sbplSubpaths(readWrite)))")
        lines.append("(allow file-read*\n\(sbplSubpaths(readOnly)))")
    }

    return lines.joined(separator: "\n") + "\n"
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
    isolationMode: SandboxIsolationMode
) -> String {
    let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    let home = homeURL.path
    var lines = [
        "(version 1)",
        "(allow default)",
        "(deny network*)",
        "(allow system-socket (socket-domain AF_UNIX))",
        "(allow network-bind (local unix-socket (path-regex #\"^/\")))",
        "(allow network-inbound (local unix-socket (path-regex #\"^/\")))",
        "(allow network-outbound (remote unix-socket (path-regex #\"^/\")))",
        "(allow network-bind (local ip \"*:*\"))",
        "(allow network-inbound (local ip \"*:*\"))",
        "(allow network-outbound (remote ip \"localhost:*\"))"
    ]

    var readOnly = [shellStartup.path, appBundle.path]
    if let hookDylib {
        readOnly.append(hookDylib.deletingLastPathComponent().path)
    }

    switch isolationMode {
    case .isolated:
        let denied = ["/Users", "/Volumes", home, store.root.path, runtime.path, source.path]
        let readWrite = [workspace.path, appRoot.path, appTemp.path]
        lines.append("(deny file-read* file-write*\n\(sbplSubpaths(denied)))")
        lines.append("(allow file-read-metadata)")
        lines.append("(allow file-read* file-write*\n\(sbplSubpaths(readWrite)))")
        lines.append("(allow file-read*\n\(sbplSubpaths(readOnly)))")
    case .hostPassthrough:
        let claudeDir = homeURL.appendingPathComponent(".claude").path
        let claudeFile = homeURL.appendingPathComponent(".claude.json").path
        let hostCookies = homeURL.appendingPathComponent("Library/Cookies").path
        let hostHTTPStorage = homeURL.appendingPathComponent("Library/HTTPStorages").path
        let hostWebKit = homeURL.appendingPathComponent("Library/WebKit").path
        let hostKeychains = homeURL.appendingPathComponent("Library/Keychains").path
        let hostGroupContainers = homeURL.appendingPathComponent("Library/Group Containers").path
        let deniedSubpaths = [
            claudeDir, hostCookies, hostHTTPStorage, hostWebKit,
            hostKeychains, hostGroupContainers, store.root.path, runtime.path
        ]
        let readWrite = [workspace.path, appRoot.path, appTemp.path]
        lines.append("(deny file-read* file-write*\n\(sbplSubpaths(deniedSubpaths))\n  (literal \(sbplString(claudeFile))))")
        lines.append("(allow file-read-metadata)")
        lines.append("(allow file-read* file-write*\n\(sbplSubpaths(readWrite)))")
        lines.append("(allow file-read*\n\(sbplSubpaths(readOnly)))")
    }

    return lines.joined(separator: "\n") + "\n"
}
