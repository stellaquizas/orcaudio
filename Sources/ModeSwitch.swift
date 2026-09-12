import AppKit
import ApplicationServices

/// Intercept only the enabled desktop apps. Replayed events carry a private marker,
/// so a forwarded Cursor chord can never recursively trigger Orcaudio.
final class ModeShortcut {
    static let marker: Int64 = 0x4F5243414D4F4445
    var onPress: ((pid_t) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    static func matches(key: Int64, flags: CGEventFlags) -> Bool {
        key == 48 && flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]) == .maskShift
    }
    static func accepts(_ bundle: String?) -> Bool {
        SupportedApp.accepts(bundle) && [.cursor, .chatgpt].contains(SupportedApp.identify(bundle))
    }
    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<ModeShortcut>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                owner.held = false
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == ModeShortcut.marker { return Unmanaged.passUnretained(event) }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp, key == 48, owner.held { owner.held = false; return nil }
            guard type == .keyDown, ModeShortcut.matches(key: key, flags: event.flags),
                  let front = NSWorkspace.shared.frontmostApplication, ModeShortcut.accepts(front.bundleIdentifier) else { return Unmanaged.passUnretained(event) }
            owner.held = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                let pid = front.processIdentifier
                DispatchQueue.main.async { owner.onPress?(pid) }
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    static func forward(to pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: down)
            event?.flags = .maskShift; event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.postToPid(pid)
        }
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; held = false
    }
    deinit { stop() }
}

final class ModeSwitcher {
    var onStatus: ((String) -> Void)?
    private(set) var busy = false
    private var generation = 0
    private var monitor: Any?
    private var activation: NSObjectProtocol?
    private var selection: InputSelection?
    private var saved: FocusSnapshot?

    static func label(_ element: AXUIElement) -> String {
        let title = ax(element, kAXTitleAttribute) as? String ?? ""
        return title.isEmpty ? (ax(element, kAXDescriptionAttribute) as? String ?? "") : title
    }
    /// Bounded structural reads; never inspect transcript text.
    static func controls(_ root: AXUIElement) -> [AXUIElement]? {
        var pending = [(root, 0)], found: [AXUIElement] = [], count = 0
        let deadline = Date().addingTimeInterval(0.18)
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= 3000, depth <= 60, Date() < deadline else { return nil }
            if ax(node, "AXHidden") as? Bool == true { continue }
            let role = ax(node, kAXRoleAttribute) as? String ?? ""
            if [kAXButtonRole, kAXPopUpButtonRole, kAXMenuItemRole].contains(role) { found.append(node) }
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole].contains(role) { continue }
            for child in ax(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { pending.append((child, depth + 1)) }
        }
        return found
    }
    static func composerRoot(_ input: AXUIElement, kind: SupportedApp) -> AXUIElement? {
        var parent: AXUIElement? = input
        for _ in 0..<12 {
            guard let node = parent else { return nil }
            let classes = axClasses(node)
            if kind == .chatgpt && classes.contains(where: { $0.hasPrefix("_ComposerLayoutBody_") }) { return node }
            if kind == .cursor && classes.contains("ui-prompt-input__container") { return node }
            parent = axElement(node, kAXParentAttribute)
        }
        return nil
    }
    static func isCodex(_ window: AXUIElement) -> Bool {
        controls(window)?.contains { node in
            ax(node, kAXRoleAttribute) as? String == kAXPopUpButtonRole &&
            ["Switch mode, current mode: Codex", "切換模式，目前模式：Codex", "切换模式，当前模式：Codex"].contains(label(node))
        } == true
    }
    static func mode(_ root: AXUIElement, kind: SupportedApp) -> String? {
        guard let nodes = controls(root) else { return nil }
        let labels = Set(nodes.map(label))
        if kind == .cursor {
            for name in ["Plan", "Debug", "Multitask", "Ask"] { if labels.contains("Remove \(name)") { return name } }
            return "Agent"
        }
        if !labels.isDisjoint(with: ["Clear goal", "清除目標", "清除目标"]) { return "Goal" }
        if !labels.isDisjoint(with: ["Plan", "Plan mode", "規劃", "規劃模式", "计划", "计划模式"]) { return "Plan" }
        return "Default"
    }
    static func next(_ mode: String, kind: SupportedApp) -> String? {
        let order = kind == .cursor ? ["Agent", "Plan", "Debug", "Multitask", "Ask"] : ["Default", "Plan", "Goal"]
        guard let index = order.firstIndex(of: mode) else { return nil }
        return order[(index + 1) % order.count]
    }
    func cycle(pid: pid_t) {
        guard !busy, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        guard case .success(let target) = ChatInput.select() else {
            ModeShortcut.forward(to: pid) // Search, menus and dialogs keep ordinary reverse-Tab navigation.
            onStatus?(L("No available chat input found.")); return
        }
        let kind = SupportedApp.identify(target.application.bundleIdentifier)!
        guard kind == .cursor || kind == .chatgpt else { return }
        guard kind != .chatgpt || Self.isCodex(target.window) else {
            ModeShortcut.forward(to: pid); return
        }
        busy = true; generation += 1; selection = target
        let token = generation
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != ModeShortcut.marker else { return }
            if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.intersection([.shift,.control,.option,.command]) == .shift { return }
            self?.cancel()
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }
        if !target.alreadyFocused {
            guard AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { finish(L("Unable to focus the chat input. Click it and try again.")); return }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.busy, self.generation == token else { return }
            guard let snapshot = target.snapshot(), let root = Self.composerRoot(target.element, kind: kind),
                  let current = Self.mode(root, kind: kind), let next = Self.next(current, kind: kind) else {
                self.finish(L("Mode controls unavailable. Use the app's mode menu.")); return
            }
            self.saved = snapshot
            if kind == .chatgpt {
                guard let controls = Self.controls(target.window) else { self.finish(L("Mode controls unavailable. Use the app's mode menu.")); return }
                let goalControls = controls.filter { ["Pause goal", "Resume goal", "Clear goal", "暫停目標", "繼續目標", "清除目標", "暂停目标", "恢复目标", "清除目标"].contains(Self.label($0)) }
                let footer = Self.controls(root) ?? []
                if goalControls.contains(where: { item in !footer.contains(where: { CFEqual(item, $0) }) }) {
                    self.finish(L("Manage the current goal before switching modes.")); return
                }
            }
            if kind == .cursor {
                ModeShortcut.forward(to: pid)
                self.verify(next, kind: kind, token: token)
            } else if current == "Goal" {
                // Only the footer's draft-goal chip, never the running-goal progress row.
                guard let clear = Self.controls(root)?.first(where: { ["Clear goal", "清除目標", "清除目标"].contains(Self.label($0)) }), self.click(clear) else {
                    self.finish(L("Mode controls unavailable. Use the app's mode menu.")); return
                }
                self.verify(next, kind: kind, token: token)
            } else {
                guard let add = Self.controls(root)?.first(where: { ["Add files and more", "新增檔案及更多", "添加文件及更多"].contains(Self.label($0)) }), self.click(add) else {
                    self.finish(L("Mode controls unavailable. Use the app's mode menu.")); return
                }
                self.chooseCodex(next, token: token)
            }
        }
    }
    private func valid() -> Bool {
        guard busy, let selection, let saved, selection.stillFrontmost(),
              ChatInput.textValue(selection.element) == saved.value,
              saved.webArea.flatMap({ ax($0, kAXURLAttribute) }).map({ String(describing: $0) }) == saved.documentURL else { return false }
        return true
    }
    /// ChatGPT's command rows don't execute reliably through AXPress. Click the
    /// current accessible control's verified bounds, never fixed screen coordinates.
    private func click(_ node: AXUIElement, physical: Bool = false) -> Bool {
        guard valid(), ax(node, kAXEnabledAttribute) as? Bool != false,
              let rect = elementRect(node), rect.width > 0, rect.height > 0,
              let window = selection.flatMap({ elementRect($0.window) }), window.contains(rect) else { return false }
        let point = CGPoint(x: rect.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.midY)
        // Hit-test prevents a menu, overlay or stale element from receiving the click.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else { return false }
        var parent = hit, matches = false
        for _ in 0..<8 { guard let item = parent else { break }; if CFEqual(item, node) { matches = true; break }; parent = axElement(item, kAXParentAttribute) }
        guard matches else { return false }
        if !physical { return AXUIElementPerformAction(node, kAXPressAction as CFString) == .success }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: ModeShortcut.marker)
            event?.post(tap: .cghidEventTap)
        }
        return true
    }
    private func chooseCodex(_ next: String, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.busy, self.generation == token else { return }
            guard self.valid(), let selection = self.selection, let nodes = Self.controls(selection.window) else { self.finish(L("Input changed. Try your shortcut again.")); return }
            let prefixes = next == "Plan" ? ["Plan mode Turn plan mode on", "規劃模式 開啟", "计划模式 开启"] : ["Goal Set a goal to keep pursuing", "目標 設定", "目标 设置"]
            let choices = nodes.filter { node in
                ax(node,kAXRoleAttribute) as? String == kAXButtonRole && prefixes.contains(where: { Self.label(node).hasPrefix($0) })
            }
            guard choices.count == 1, self.click(choices[0], physical: true) else { self.finish(L("Mode controls unavailable. Use the app's mode menu.")); return }
            self.verify(next, kind: .chatgpt, token: token)
        }
    }
    private func verify(_ expected: String, kind: SupportedApp, token: Int, retries: Int = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.busy, self.generation == token else { return }
            guard self.valid(), let selection = self.selection, let root = Self.composerRoot(selection.element, kind: kind) else { self.finish(L("Input changed. Try your shortcut again.")); return }
            if Self.mode(root, kind: kind) == expected {
                // Restore focus/range only while the same unchanged draft is still ours.
                if axElement(selection.app, kAXFocusedUIElementAttribute).map({ CFEqual($0, selection.element) }) != true {
                    guard AXUIElementSetAttributeValue(selection.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { self.finish(L("Unable to focus the chat input. Click it and try again.")); return }
                }
                if var range = self.saved?.range, let value = AXValueCreate(.cfRange, &range) { _ = AXUIElementSetAttributeValue(selection.element, kAXSelectedTextRangeAttribute as CFString, value) }
                self.finish("\(expected) · ⇧Tab")
            } else if retries > 0 { self.verify(expected, kind: kind, token: token, retries: retries - 1) }
            else { self.finish(L("Mode change not confirmed. Check the app's mode menu.")) }
        }
    }
    func cancel() { generation += 1; finish(nil) }
    private func finish(_ message: String?) {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }; activation = nil
        busy = false; selection = nil; saved = nil
        if let message { onStatus?(message) }
    }
    deinit { cancel() }
}
