import AppKit
import ApplicationServices

func ax(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = ax(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func axRange(_ element: AXUIElement) -> CFRange? {
    guard let value = ax(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

struct FocusSnapshot {
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
    let element: AXUIElement
    let value: String?
    let range: CFRange?
    let role: String
    let description: String

    static func capture() -> FocusSnapshot? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.stablyai.orca" else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let window = axElement(app, kAXFocusedWindowAttribute),
              let element = axElement(app, kAXFocusedUIElementAttribute),
              let role = ax(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              ax(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        return FocusSnapshot(pid: front.processIdentifier, app: app, window: window, element: element,
            value: ax(element, kAXValueAttribute) as? String, range: axRange(element), role: role,
            description: ax(element, kAXDescriptionAttribute) as? String ?? "")
    }

    func sameTarget() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let currentWindow = axElement(app, kAXFocusedWindowAttribute), CFEqual(window, currentWindow),
              let currentElement = axElement(app, kAXFocusedUIElementAttribute), CFEqual(element, currentElement) else { return false }
        return true
    }
    func unchanged() -> Bool {
        guard sameTarget(), ax(element, kAXValueAttribute) as? String == value else { return false }
        let currentRange = axRange(element)
        return currentRange?.location == range?.location && currentRange?.length == range?.length
    }
    func expected(_ insertion: String) -> String? {
        guard let value, let range, range.location >= 0, range.length >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: insertion)
    }
}

final class FocusGuard {
    let snapshot: FocusSnapshot?
    private(set) var invalidated = false
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    var onInvalidate: (() -> Void)?

    init() {
        snapshot = FocusSnapshot.capture()
        invalidated = snapshot == nil
        if let s = snapshot {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, pointer in
                guard let pointer else { return }
                let guardObject = Unmanaged<FocusGuard>.fromOpaque(pointer).takeUnretainedValue()
                guardObject.invalidate()
            }
            if AXObserverCreate(s.pid, callback, &observer) == .success, let observer {
                axObserver = observer
                let pointer = Unmanaged.passUnretained(self).toOpaque()
                for notification in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXApplicationDeactivatedNotification] {
                    let status = AXObserverAddNotification(observer, s.app, notification as CFString, pointer)
                    if notification == kAXFocusedUIElementChangedNotification && status != .success { invalidated = true }
                }
                AXObserverAddNotification(observer, s.element, kAXSelectedTextChangedNotification as CFString, pointer)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            } else { invalidated = true }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.snapshot?.unchanged() != true { self.invalidate() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; onInvalidate?()
    }
    var canPaste: Bool { !invalidated && snapshot?.unchanged() == true }
    func stop() {
        timer?.invalidate(); timer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver); self.workspaceObserver = nil }
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
            self.axObserver = nil
        }
    }
    deinit { stop() }
}

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let complete: Bool
    init(_ board: NSPasteboard) {
        let initialChangeCount = board.changeCount
        var complete = true
        items = (board.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
                else { complete = false }
            }
            return data
        }
        self.complete = complete && board.changeCount == initialChangeCount
    }
    func restore(_ board: NSPasteboard) {
        guard complete else { return }
        board.clearContents()
        let objects = items.map { data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, bytes) in data { item.setData(bytes, forType: type) }
            return item
        }
        if !objects.isEmpty { board.writeObjects(objects) }
    }
}

/// One paste attempt. Never emits Return; never retries; never activates Orca.
func pasteResult(_ text: String, guard focus: FocusGuard, completion: @escaping (String) -> Void) {
    guard focus.canPaste, let snapshot = focus.snapshot else {
        completion(L("Input changed. Select Copy to paste manually.")); return
    }
    let board = NSPasteboard.general
    let old = ClipboardSnapshot(board)
    guard focus.canPaste else { completion(L("Input changed. Select Copy to paste manually.")); return }
    board.clearContents()
    guard board.setString(text, forType: .string) else { completion(L("Unable to copy. Please select Copy again.")); return }
    let changeCount = board.changeCount
    guard focus.canPaste, board.changeCount == changeCount else {
        completion(L("Input changed. Your text is on the clipboard.")); return
    }
    focus.stop()
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
        completion(L("Copied. Please paste manually.")); return
    }
    down.flags = .maskCommand; up.flags = .maskCommand
    down.postToPid(snapshot.pid); up.postToPid(snapshot.pid)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        let verified = snapshot.sameTarget() && snapshot.expected(text).map { expected in
            ax(snapshot.element, kAXValueAttribute) as? String == expected
        } == true
        if verified, board.changeCount == changeCount, old.complete {
            old.restore(board)
            completion(L("Pasted. Review your text before sending."))
        } else {
            completion(L("Paste attempted. Check Orca before pasting again."))
        }
    }
}
