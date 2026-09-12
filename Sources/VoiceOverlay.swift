import AppKit
import ApplicationServices

/// AX screen coordinates use a top-left origin; AppKit uses the primary screen's bottom-left.
func cocoaRect(_ rect: CGRect, primaryHeight: CGFloat) -> NSRect {
    NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}
func elementRect(_ element: AXUIElement) -> NSRect? {
    guard let p = ax(element, kAXPositionAttribute), let s = ax(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          point.x.isFinite, point.y.isFinite, size.width > 0, size.height > 0 else { return nil }
    return cocoaRect(CGRect(origin: point, size: size), primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
}

struct VoiceAnchor {
    let target: NSRect
    let screen: NSRect
    static func capture(_ snapshot: FocusSnapshot?) -> VoiceAnchor {
        let main = NSScreen.main ?? NSScreen.screens[0]
        var target: NSRect?
        if let s = snapshot {
            if var range = s.range, let value = AXValueCreate(.cfRange, &range) {
                var bounds: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(s.element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds) == .success,
                   let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height >= 8, rect.height < 100, rect.width.isFinite, rect.origin.x.isFinite, rect.origin.y.isFinite {
                        target = cocoaRect(rect, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
                    }
                }
            }
            if let candidate = target,
               elementRect(s.window)?.intersects(candidate.insetBy(dx: -1, dy: -1)) != true { target = nil }
            if target == nil, let rect = elementRect(s.element), rect.width >= 100, rect.height >= 20, rect.height < 250 { target = rect }
        }
        if target == nil, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.stablyai.orca" {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.1)
            if let window = axElement(element, kAXFocusedWindowAttribute), let rect = elementRect(window) {
                // Terminal/webview caret bounds may be unavailable. Stay at Orca's lower edge.
                target = NSRect(x: rect.midX, y: rect.minY + 80, width: 1, height: 24)
            }
        }
        let fallback = NSRect(x: main.visibleFrame.midX, y: main.visibleFrame.minY + 100, width: 1, height: 24)
        let resolved = target ?? fallback
        let screen = NSScreen.screens.first { $0.frame.intersects(resolved) } ?? main
        return VoiceAnchor(target: resolved, screen: screen.visibleFrame)
    }
    func origin(size: NSSize) -> NSPoint {
        let inset = screen.insetBy(dx: 12, dy: 12)
        let x = min(max(target.midX - size.width / 2, inset.minX), inset.maxX - size.width)
        let above = target.maxY + 12
        let y = above + size.height <= inset.maxY ? above : target.minY - size.height - 12
        return NSPoint(x: x, y: min(max(y, inset.minY), inset.maxY - size.height))
    }
}

/// Draw only the capsule itself. A behind-window blur can paint rectangular backing
/// outside a layer's cornerRadius, especially over light windows.
final class VoiceCapsuleSurface: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGradient(starting: NSColor(white: 0.18, alpha: 0.98), ending: NSColor(white: 0.11, alpha: 0.98))?.draw(in: shape, angle: 90)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        shape.lineWidth = 0.7; shape.stroke()
    }
}

final class VoiceWave: NSView {
    enum Mode { case listening, thinking, ready }
    var mode = Mode.ready
    var levels = [Double](repeating: 0, count: VoiceMeter.barCount) {
        didSet { needsDisplay = true }
    }
    private var clock: Timer?
    private var time: Double = 0
    func setAnimating(_ active: Bool) {
        guard active != (clock != nil) else { return }
        if active {
            let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.time += 1.0 / 24
                self.needsDisplay = true
            }
            timer.tolerance = 0.008; clock = timer; RunLoop.main.add(timer, forMode: .common)
        } else { clock?.invalidate(); clock = nil; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let t = reduced ? 0 : time
        for index in 0..<VoiceMeter.barCount {
            let i = Double(index)
            let envelope = 1 - abs(i - 11) / 12
            let signal: Double
            switch mode {
            case .listening: signal = levels.indices.contains(index) ? levels[index] : 0
            case .thinking: signal = (0.25 + 0.6 * (sin(t * 4 - i * 0.7) + 1) / 2) * envelope
            case .ready: signal = 0.22 * envelope
            }
            let height = 3 + 21 * signal
            NSColor(white: 0.94, alpha: 0.65 + envelope * 0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2 + i * 5, y: (bounds.height - height) / 2, width: 3, height: height), xRadius: 2, yRadius: 2).fill()
        }
    }
    deinit { clock?.invalidate() }
}
