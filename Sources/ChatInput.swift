import AppKit
import ApplicationServices

func axClasses(_ element: AXUIElement) -> Set<String> {
    Set(ax(element, "AXDOMClassList") as? [String] ?? [])
}
func axSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
}

/// Use semantic editor/container metadata, never placeholder text or fixed coordinates.
struct ComposerTraits {
    let app: SupportedApp
    let role: String
    let classes: Set<String>
    let ancestorClasses: Set<String>
    let editable: Bool
    let visible: Bool
    let secure: Bool
    var isComposer: Bool {
        guard editable, visible, !secure else { return false }
        switch app {
        case .orca:
            return role == kAXTextFieldRole && classes.contains("xterm-helper-textarea") && ancestorClasses.contains("pane")
        case .cursor:
            return role == kAXTextAreaRole && classes.contains("ProseMirror") &&
                (classes.contains("ui-prompt-input-editor__input") || ancestorClasses.contains("ui-prompt-input-editor"))
        case .chatgpt:
            return role == kAXTextAreaRole && classes.contains("ProseMirror") &&
                ancestorClasses.contains { $0.hasPrefix("_ComposerLayoutBody_") || $0 == "composer-parent" || $0 == "composer" }
        }
    }
}

enum InputFailure: Error {
    case unsupported, missing, ambiguous, busy, changed, unavailable
    var message: String {
        switch self {
        case .unsupported: return L("Switch to an enabled app to dictate.")
        case .missing: return L("No available chat input found.")
        case .ambiguous: return L("Select the chat input, then try again.")
        case .busy: return L("Return to the chat before dictating.")
        case .changed: return L("Input changed. Try your shortcut again.")
        case .unavailable: return L("Unable to focus the chat input. Click it and try again.")
        }
    }
}

struct InputSelection {
    let application: NSRunningApplication
    let app: AXUIElement
    let window: AXUIElement
    let element: AXUIElement
    let alreadyFocused: Bool
    func stillFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier &&
        axElement(app, kAXFocusedWindowAttribute).map { CFEqual(window, $0) } == true &&
        SupportedApp.accepts(application.bundleIdentifier)
    }
    func snapshot() -> FocusSnapshot? {
        guard stillFrontmost(), let current = axElement(app, kAXFocusedUIElementAttribute), CFEqual(current, element),
              ax(element, kAXEnabledAttribute) as? Bool != false else { return nil }
        return FocusSnapshot.make(pid: application.processIdentifier, app: app, window: window, element: element)
    }
}

/// A bounded scan of only the front window. An incomplete scan must never choose
/// a candidate: a second editor or modal may be in the unvisited portion.
enum ChatInput {
    static func select() -> Result<InputSelection, InputFailure> {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              SupportedApp.accepts(front.bundleIdentifier), let kind = SupportedApp.identify(front.bundleIdentifier) else { return .failure(.unsupported) }
        OrcaAccessibility.prepare(front)
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window = axElement(app, kAXFocusedWindowAttribute), let windowRect = elementRect(window) else { return .failure(.missing) }
        let focused = axElement(app, kAXFocusedUIElementAttribute)
        var candidates: [AXUIElement] = []
        var modal = false, incomplete = false, count = 0
        let deadline = Date().addingTimeInterval(0.6)
        var pending: [(AXUIElement, Set<String>, Int)] = [(window, [], 0)]
        while let (element, parents, depth) = pending.popLast() {
            count += 1
            if count > 3000 || Date() > deadline || depth > 60 { incomplete = true; break }
            let role = ax(element, kAXRoleAttribute) as? String ?? ""
            let subrole = ax(element, kAXSubroleAttribute) as? String ?? ""
            if ax(element, "AXHidden") as? Bool == true { continue }
            if role == kAXSheetRole || subrole == "AXDialog" || subrole == "AXSystemDialog" || ax(element, "AXModal") as? Bool == true { modal = true }
            let classes = axClasses(element)
            if [kAXTextAreaRole, kAXTextFieldRole].contains(role) {
                let rect = elementRect(element)
                let traits = ComposerTraits(app: kind, role: role, classes: classes, ancestorClasses: parents,
                    editable: ax(element, kAXEnabledAttribute) as? Bool != false && axSettable(element, kAXValueAttribute),
                    visible: rect.map { windowRect.intersects($0) && $0.width > 0 && $0.height > 0 } == true,
                    secure: subrole == kAXSecureTextFieldSubrole)
                if traits.isComposer { candidates.append(element) }
            }
            // Do not inspect message text, only accessibility structure and class tokens.
            if role == kAXStaticTextRole { continue }
            for child in (ax(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed() {
                pending.append((child, parents.union(classes), depth + 1))
            }
        }
        let focusedIndex = focused.flatMap { current in candidates.firstIndex { CFEqual($0, current) } }
        let focusedRole = focused.flatMap { ax($0, kAXRoleAttribute) as? String } ?? ""
        let otherEditing = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXMenuItemRole, kAXMenuRole].contains(focusedRole)
        return choose(count: candidates.count, focusedIndex: focusedIndex, otherEditing: otherEditing, modal: modal, incomplete: incomplete).map { index in
            InputSelection(application: front, app: app, window: window, element: candidates[index], alreadyFocused: focusedIndex == index)
        }
    }
    static func choose(count: Int, focusedIndex: Int?, otherEditing: Bool, modal: Bool, incomplete: Bool) -> Result<Int, InputFailure> {
        guard !modal else { return .failure(.busy) }
        guard !incomplete else { return .failure(.ambiguous) }
        if let focusedIndex, (0..<count).contains(focusedIndex) { return .success(focusedIndex) }
        guard !otherEditing else { return .failure(.busy) }
        guard count == 1 else { return .failure(count == 0 ? .missing : .ambiguous) }
        return .success(0)
    }

    /// Chromium exposes generated placeholder content in AXValue. Detect the empty
    /// editor via structural child classes, without comparing localized strings.
    static func isEmptyEditor(_ element: AXUIElement) -> Bool {
        guard axClasses(element).contains("ProseMirror") else { return false }
        let children = ax(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.count == 1 && !axClasses(children[0]).isDisjoint(with: ["placeholder", "is-editor-empty"])
    }
    static func cursorParagraphs(_ element: AXUIElement) -> [String]? {
        guard axClasses(element).contains("ui-prompt-input-editor__input"), !isEmptyEditor(element) else { return nil }
        let blocks = ax(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard !blocks.isEmpty else { return nil }
        func text(_ node: AXUIElement, depth: Int) -> String? {
            guard depth < 12 else { return nil }
            let role = ax(node, kAXRoleAttribute) as? String
            if role == kAXStaticTextRole { return ax(node, kAXValueAttribute) as? String }
            guard role == kAXGroupRole else { return nil } // Complex attachments: leave paste unverified.
            let children = ax(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
            var result = ""
            for child in children { guard let value = text(child, depth: depth + 1) else { return nil }; result += value }
            return result
        }
        var paragraphs: [String] = []
        for block in blocks {
            guard ax(block, kAXRoleAttribute) as? String == kAXGroupRole, let value = text(block, depth: 0) else { return nil }
            paragraphs.append(value)
        }
        return paragraphs
    }
    static func textValue(_ element: AXUIElement) -> String? {
        if isEmptyEditor(element) { return "" }
        if let paragraphs = cursorParagraphs(element) { return paragraphs.joined(separator: "\n") }
        return ax(element, kAXValueAttribute) as? String
    }
    static func endOffset(_ element: AXUIElement) -> Int? {
        if let paragraphs = cursorParagraphs(element) { return paragraphs.reduce(0) { $0 + ($1 as NSString).length } }
        return textValue(element).map { ($0 as NSString).length }
    }
    // Cursor's AX offsets omit paragraph separators, although AXValue displays spaces.
    // At an ambiguous paragraph boundary we cannot verify a paste, so keep its clipboard.
    static func logicalRange(_ range: CFRange?, paragraphs: [String]) -> CFRange? {
        guard let range else { return nil }
        func offset(_ value: Int) -> Int? {
            var raw = 0, matches: [Int] = []
            for (index, paragraph) in paragraphs.enumerated() {
                let count = (paragraph as NSString).length
                if value >= raw && value <= raw + count { matches.append(value + index) }
                raw += count
            }
            return matches.count == 1 ? matches[0] : nil
        }
        guard let start = offset(range.location), let end = offset(range.location + range.length) else { return nil }
        return CFRange(location: start, length: end - start)
    }
}
