import AppKit
@main struct ChatInputChecks {
 static func main() {
  let suite = "orcaudio.apps.test." + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  assert(SupportedApp.enabled(in: defaults) == [.orca])
  assert(SupportedApp.accepts("com.stablyai.orca", defaults: defaults))
  assert(!SupportedApp.accepts("com.openai.codex", defaults: defaults))
  SupportedApp.save([.chatgpt, .cursor], in: defaults)
  assert(SupportedApp.accepts("com.openai.codex", defaults: defaults))
  assert(SupportedApp.accepts("com.todesktop.230313mzl4w4u92", defaults: defaults))
  assert(!SupportedApp.accepts("com.microsoft.VSCode", defaults: defaults))
  SupportedApp.save([], in: defaults)
  assert(SupportedApp.enabled(in: defaults).isEmpty, "An explicit empty selection must not re-enable Orca")
  defaults.set(["unknown", "orca"], forKey: "supportedApps")
  assert(SupportedApp.enabled(in: defaults) == [.orca])
  func traits(_ app: SupportedApp, _ role: String, _ classes: Set<String>, _ parents: Set<String>, editable: Bool = true, visible: Bool = true, secure: Bool = false) -> Bool {
   ComposerTraits(app: app, role: role, classes: classes, ancestorClasses: parents, editable: editable, visible: visible, secure: secure).isComposer
  }
  assert(traits(.chatgpt,kAXTextAreaRole,["ProseMirror"],["_ComposerLayoutBody_futurehash_1"]))
  assert(traits(.cursor,kAXTextAreaRole,["ProseMirror", "ui-prompt-input-editor__input"],[]))
  assert(traits(.orca,kAXTextFieldRole,["xterm-helper-textarea"],["pane"]))
  assert(!traits(.cursor,kAXTextFieldRole,["xterm-helper-textarea"],["pane"]), "Cursor terminal is not a chat input")
  assert(!traits(.cursor,kAXTextAreaRole,["inputarea"],["monaco-editor"]))
  assert(!traits(.chatgpt,kAXTextFieldRole,[],["search"]))
  assert(!traits(.chatgpt,kAXTextAreaRole,["ProseMirror"],["message-editor"]), "Editing an old message is not the composer")
  for (editable,visible,secure) in [(false,true,false),(true,false,false),(true,true,true)] {
   assert(!traits(.chatgpt,kAXTextAreaRole,["ProseMirror"],["composer"],editable:editable,visible:visible,secure:secure))
  }
  func decision(_ count: Int, focused: Int? = nil, editing: Bool = false, modal: Bool = false, incomplete: Bool = false) -> Result<Int, InputFailure> {
   ChatInput.choose(count: count, focusedIndex: focused, otherEditing: editing, modal: modal, incomplete: incomplete)
  }
  assert(try! decision(1).get() == 0)
  assert(try! decision(2, focused: 1).get() == 1)
  for result in [decision(0), decision(2), decision(1,editing:true), decision(1,focused:0,modal:true), decision(1,focused:0,incomplete:true)] {
   guard case .failure = result else { fatalError("Unsafe target chosen") }
  }
  let paragraphs = ["abc", "中英🐋", "end"]
  assert(ChatInput.logicalRange(CFRange(location: 4, length: 1), paragraphs: paragraphs)?.location == 5)
  assert(ChatInput.logicalRange(CFRange(location: 3, length: 0), paragraphs: paragraphs) == nil)
  assert(ChatInput.logicalRange(CFRange(location: 10, length: 0), paragraphs: paragraphs)?.location == 12)
  let dummy = AXUIElementCreateSystemWide()
  let ambiguous = FocusSnapshot(pid: 0, app: dummy, window: dummy, element: dummy, value: "abc\ndef", range: CFRange(location: 3, length: 0), role: kAXTextAreaRole, description: "", cursorParagraphs: ["abc", "def"])
  assert(ambiguous.expected("x") == nil, "Ambiguous paragraph offsets must not confirm clipboard restoration")
  print("PASS: app selection/migration, empty selection, structural composers, hidden/disabled/secure inputs, search/code/terminal exclusions")
 }
}
