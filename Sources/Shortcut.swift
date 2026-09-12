import AppKit
import Carbon

struct Shortcut {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let standard = Shortcut(key: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")
    static func load() -> Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "shortcutKey") != nil else { return .standard }
        return Shortcut(key: UInt32(d.integer(forKey: "shortcutKey")), modifiers: UInt32(d.integer(forKey: "shortcutModifiers")), label: d.string(forKey: "shortcutLabel") ?? L("Custom shortcut"))
    }
    func save() {
        let d = UserDefaults.standard
        d.set(Int(key), forKey: "shortcutKey"); d.set(Int(modifiers), forKey: "shortcutModifiers"); d.set(label, forKey: "shortcutLabel")
    }
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        return event.keyCode == key && Self.carbon(flags) == modifiers
    }
    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        return bits
    }
}

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private var configured: Shortcut?
    private var active = true
    private var activationObserver: NSObjectProtocol?
    var onAvailability: ((Bool) -> Void)?
    func followSupportedApps() {
        syncContext()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.syncContext() }
    }
    func syncContext() {
        let shouldActivate = SupportedApp.accepts(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard active != shouldActivate else { return }
        active = shouldActivate
        if !active { if let ref { UnregisterEventHotKey(ref); self.ref = nil } }
        else if let configured { onAvailability?(register(configured)) }
    }
    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) -> Bool {
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x4F444943, id: 1),
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { return false }
        if let ref { UnregisterEventHotKey(ref) }
        configured = shortcut
        if active { ref = candidate }
        else { if let candidate { UnregisterEventHotKey(candidate) }; ref = nil }
        return true
    }
    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class ShortcutField: NSTextField {
    var onShortcut: ((Shortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = L("Press a shortcut (Escape to cancel)")
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { stringValue = Shortcut.load().label; window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard !flags.intersection([.control, .option, .command]).isEmpty, !event.isARepeat else { NSSound.beep(); return }
        let keyName = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
        let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyName
        onShortcut?(Shortcut(key: UInt32(event.keyCode), modifiers: Shortcut.carbon(flags), label: label))
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}
