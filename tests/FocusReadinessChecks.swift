import AppKit
@main struct FocusReadinessChecks {
 static func main() {
  _ = NSApplication.shared
  UserDefaults.standard.set("en",forKey:"uiLanguage")
  let app = AppDelegate(root:URL(fileURLWithPath:FileManager.default.currentDirectoryPath))
  app.setupPanel()
  let missing = FocusGuard(snapshot:nil)
  assert(!missing.canPaste)
  app.beginRecording(guardObject:missing)
  assert(app.phase == .idle && app.recorder.url == nil && !app.worker.loaded)
  assert(app.focus == nil)
  assert(app.stateText == "Unable to focus the chat input. Click it and try again.")
  app.hidePanel()
  print("PASS: unavailable input fails before recording instead of silently producing copy-only results")
 }
}
