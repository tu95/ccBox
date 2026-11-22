import Foundation

private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

private func sbplString(_ path: String) -> String {
    let escaped = canonicalPath(path)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func sbplSubpaths(_ paths: [String]) -> String {
    Array(Set(paths.map(canonicalPath))).sorted().map { "  (subpath \(sbplString($0)))" }.joined(separator: "\n")
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
