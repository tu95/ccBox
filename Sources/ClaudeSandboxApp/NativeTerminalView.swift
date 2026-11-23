import AppKit
import ClaudeSandboxCore
import SwiftUI
import WebKit

struct NativeTerminalView: NSViewRepresentable {
    let environmentID: UUID?
    let terminals: [UUID: SandboxTerminal]
    let validEnvironmentIDs: Set<UUID>
    let sessionActive: Bool
    let scrollToLatestRequest: Int
    let onResize: (UUID, UInt16, UInt16) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResize: onResize)
    }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.035, green: 0.04, blue: 0.05, alpha: 1).cgColor
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.fitActiveTerminal(force: false)
        }
        context.coordinator.container = container
        context.coordinator.sync(
            environmentID: environmentID,
            terminals: terminals,
            validEnvironmentIDs: validEnvironmentIDs,
            sessionActive: sessionActive,
            scrollToLatestRequest: scrollToLatestRequest
        )
        return container
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.sync(
            environmentID: environmentID,
            terminals: terminals,
            validEnvironmentIDs: validEnvironmentIDs,
            sessionActive: sessionActive,
            scrollToLatestRequest: scrollToLatestRequest
        )
    }

    private final class TerminalContainerView: NSView {
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    final class Coordinator: NSObject {
        private final class WebSlot: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
            let id: UUID
            let webView: WKWebView
            let indexURL: URL?
            var ready = false
            var pendingOutput: [Data] = []
            weak var coordinator: Coordinator?

            init(id: UUID, coordinator: Coordinator) {
                self.id = id
                self.coordinator = coordinator
                self.indexURL = Self.terminalIndexURL()

                let config = WKWebViewConfiguration()
                config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
                let controller = WKUserContentController()
                config.userContentController = controller
                let webView = WKWebView(frame: .zero, configuration: config)
                webView.translatesAutoresizingMaskIntoConstraints = false
                webView.setValue(false, forKey: "drawsBackground")
                self.webView = webView
                super.init()

                webView.navigationDelegate = self
                for name in ["terminalReady", "terminalInput", "terminalResize", "terminalCopy", "terminalPaste"] {
                    controller.add(self, name: name)
                }

                if let indexURL {
                    webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
                }
            }

            func webView(
                _ webView: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
            ) {
                if let url = navigationAction.request.url, let indexURL,
                   url.standardizedFileURL == indexURL.standardizedFileURL {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                }
            }

            func teardown() {
                let controller = webView.configuration.userContentController
                for name in ["terminalReady", "terminalInput", "terminalResize", "terminalCopy", "terminalPaste"] {
                    controller.removeScriptMessageHandler(forName: name)
                }
                webView.removeFromSuperview()
            }

            private static func terminalIndexURL() -> URL? {
                if let appBundle = Bundle.main.resourceURL?
                    .appendingPathComponent("ClaudeSandbox_ClaudeSandboxApp.bundle", isDirectory: true),
                   let bundle = Bundle(url: appBundle),
                   let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "xterm") {
                    return url
                }
                return Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "xterm")
            }

            func feed(_ data: Data) {
                guard !data.isEmpty else { return }
                if !ready {
                    pendingOutput.append(data)
                    return
                }
                let encoded = data.base64EncodedString()
                webView.evaluateJavaScript("window.termWrite && window.termWrite('\(encoded)');", completionHandler: nil)
            }

            func flushPending() {
                guard ready, !pendingOutput.isEmpty else { return }
                let merged = pendingOutput.reduce(into: Data()) { $0.append($1) }
                pendingOutput.removeAll()
                feed(merged)
            }

            func fit(force: Bool) {
                guard ready else { return }
                webView.evaluateJavaScript("window.termFit && window.termFit(\(force ? "true" : "false"));", completionHandler: nil)
            }

            func scrollToBottom() {
                guard ready else { return }
                webView.evaluateJavaScript("window.termScrollToBottom && window.termScrollToBottom();", completionHandler: nil)
            }

            func focus() {
                guard ready else { return }
                webView.window?.makeFirstResponder(webView)
                webView.evaluateJavaScript("window.termFocus && window.termFocus();", completionHandler: nil)
            }

            func pasteFromClipboard() {
                guard ready, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
                let encoded = Data(text.utf8).base64EncodedString()
                webView.evaluateJavaScript("window.termPaste && window.termPaste('\(encoded)');", completionHandler: nil)
            }

            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let coordinator else { return }
                switch message.name {
                case "terminalReady":
                    ready = true
                    flushPending()
                    if let body = message.body as? [String: Any],
                       let cols = body["cols"] as? Int,
                       let rows = body["rows"] as? Int {
                        coordinator.handleResize(id: id, cols: cols, rows: rows)
                    }
                    if coordinator.activeEnvironmentID == id, coordinator.sessionActive {
                        fit(force: true)
                        focus()
                    }
                case "terminalInput":
                    if let text = message.body as? String {
                        coordinator.handleInput(id: id, text: text)
                    }
                case "terminalResize":
                    if let body = message.body as? [String: Any],
                       let cols = body["cols"] as? Int,
                       let rows = body["rows"] as? Int {
                        coordinator.handleResize(id: id, cols: cols, rows: rows)
                    }
                case "terminalCopy":
                    if let text = message.body as? String, !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                case "terminalPaste":
                    pasteFromClipboard()
                default:
                    break
                }
            }
        }

        let onResize: (UUID, UInt16, UInt16) -> Void
        weak var container: NSView?
        var sessionActive = false
        var scrollToLatestRequest = 0
        private var slots: [UUID: WebSlot] = [:]
        private var terminals: [UUID: SandboxTerminal] = [:]
        private var boundTerminals: Set<UUID> = []
        fileprivate var activeEnvironmentID: UUID?

        init(onResize: @escaping (UUID, UInt16, UInt16) -> Void) {
            self.onResize = onResize
            super.init()
        }

        func teardown() {
            for slot in slots.values {
                slot.teardown()
            }
            slots.removeAll()
            boundTerminals.removeAll()
        }

        private func slot(for id: UUID) -> WebSlot {
            if let existing = slots[id] { return existing }
            let created = WebSlot(id: id, coordinator: self)
            created.webView.isHidden = id != activeEnvironmentID
            slots[id] = created
            if let container {
                container.addSubview(created.webView)
                NSLayoutConstraint.activate([
                    created.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    created.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    created.webView.topAnchor.constraint(equalTo: container.topAnchor),
                    created.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
                container.layoutSubtreeIfNeeded()
            }
            return created
        }

        func sync(
            environmentID: UUID?,
            terminals: [UUID: SandboxTerminal],
            validEnvironmentIDs: Set<UUID>,
            sessionActive: Bool,
            scrollToLatestRequest: Int
        ) {
            self.terminals = terminals
            for id in Array(slots.keys) where !validEnvironmentIDs.contains(id) {
                slots.removeValue(forKey: id)?.teardown()
                boundTerminals.remove(id)
            }

            for (id, terminal) in terminals where !boundTerminals.contains(id) {
                boundTerminals.insert(id)
                MainActor.assumeIsolated {
                    terminal.onOutput = { [weak self] bytes in
                        self?.receive(bytes, for: id)
                    }
                }
            }

            let switchedEnvironment = activeEnvironmentID != environmentID
            let sessionJustStarted = sessionActive && !self.sessionActive
            activeEnvironmentID = environmentID

            if let environmentID {
                _ = slot(for: environmentID)
                for (id, item) in slots {
                    item.webView.isHidden = (id != environmentID)
                }
            } else {
                for item in slots.values {
                    item.webView.isHidden = true
                }
            }

            let shouldFocus = sessionActive && (sessionJustStarted || switchedEnvironment)
            let shouldScroll = scrollToLatestRequest != self.scrollToLatestRequest
            self.scrollToLatestRequest = scrollToLatestRequest
            self.sessionActive = sessionActive

            if sessionJustStarted || switchedEnvironment {
                fitActiveTerminal(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.fitActiveTerminal(force: true)
                }
            }
            if shouldScroll, let id = activeEnvironmentID {
                slots[id]?.scrollToBottom()
            }
            if shouldFocus, let id = activeEnvironmentID {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionActive, self.activeEnvironmentID == id else { return }
                    self.slots[id]?.focus()
                }
            }
        }

        func fitActiveTerminal(force: Bool) {
            guard let id = activeEnvironmentID else { return }
            slots[id]?.fit(force: force)
        }

        private func receive(_ bytes: Data, for id: UUID) {
            slot(for: id).feed(bytes)
        }

        fileprivate func handleInput(id: UUID, text: String) {
            guard let terminal = terminals[id] else { return }
            MainActor.assumeIsolated {
                terminal.write(Data(text.utf8))
            }
        }

        fileprivate func handleResize(id: UUID, cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            let columns = UInt16(clamping: cols), rowsCount = UInt16(clamping: rows)
            MainActor.assumeIsolated {
                onResize(id, columns, rowsCount)
                terminals[id]?.resize(columns: columns, rows: rowsCount)
            }
        }
    }
}
