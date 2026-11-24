import AppKit
import CoreGraphics
import Foundation

@MainActor
final class WindowBorderOverlayManager {
    private struct TrackedProcess {
        let pid: pid_t
        let color: NSColor
    }

    private var tracked: [pid_t: TrackedProcess] = [:]
    private var overlays: [CGWindowID: BorderOverlayWindow] = [:]
    private var timer: Timer?

    func register(pid: pid_t, accentHex: String) {
        tracked[pid] = TrackedProcess(pid: pid, color: NSColor(hex: accentHex))
        ensureTimer()
        refresh()
    }

    func unregister(pid: pid_t) {
        tracked.removeValue(forKey: pid)
        refresh()
        if tracked.isEmpty {
            stopTimer()
        }
    }

    func stopAll() {
        tracked.removeAll()
        stopTimer()
        for window in overlays.values {
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !tracked.isEmpty else {
            for window in overlays.values {
                window.orderOut(nil)
                window.close()
            }
            overlays.removeAll()
            return
        }

        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard primaryHeight > 0 else { return }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let borderWidth: CGFloat = 3.5
        var seenWindowIDs = Set<CGWindowID>()

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let entry = tracked[ownerPID],
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 120, cgRect.height >= 120 else {
                continue
            }

            // Skip tiny or invisible helper windows
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
                continue
            }

            seenWindowIDs.insert(windowNumber)

            let appKitRect = NSRect(
                x: cgRect.origin.x,
                y: primaryHeight - cgRect.origin.y - cgRect.height,
                width: cgRect.width,
                height: cgRect.height
            )
            let frame = appKitRect.insetBy(dx: -borderWidth, dy: -borderWidth)

            let overlay: BorderOverlayWindow
            if let existing = overlays[windowNumber] {
                overlay = existing
            } else {
                overlay = BorderOverlayWindow(borderWidth: borderWidth, color: entry.color)
                overlays[windowNumber] = overlay
            }

            overlay.update(color: entry.color, frame: frame)
            let isFrontmost = (ownerPID == frontmostPID)
            let targetLevel: NSWindow.Level = isFrontmost ? .floating : .normal
            if overlay.level != targetLevel {
                overlay.level = targetLevel
            }
            if isFrontmost {
                overlay.orderFrontRegardless()
            } else {
                overlay.order(.above, relativeTo: Int(windowNumber))
            }
        }

        for id in Array(overlays.keys) where !seenWindowIDs.contains(id) {
            if let stale = overlays.removeValue(forKey: id) {
                stale.orderOut(nil)
                stale.close()
            }
        }
    }
}

private final class BorderOverlayWindow: NSWindow {
    private let borderView: BorderFrameView

    init(borderWidth: CGFloat, color: NSColor) {
        self.borderView = BorderFrameView(borderWidth: borderWidth, color: color)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = borderView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(color: NSColor, frame: NSRect) {
        if self.frame != frame {
            setFrame(frame, display: true)
        }
        borderView.update(color: color)
    }
}

private final class BorderFrameView: NSView {
    private let borderWidth: CGFloat
    private var color: NSColor

    init(borderWidth: CGFloat, color: NSColor) {
        self.borderWidth = borderWidth
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(color: NSColor) {
        guard self.color != color else { return }
        self.color = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let strokeRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let path = NSBezierPath(roundedRect: strokeRect, xRadius: 12, yRadius: 12)
        path.lineWidth = borderWidth
        color.setStroke()
        path.stroke()
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            self.init(srgbRed: 0.93, green: 0.27, blue: 0.27, alpha: 1)
            return
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
