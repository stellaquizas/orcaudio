import AppKit
@main struct SettingsChecks {
 static func main() {
  _ = NSApplication.shared
  let defaults = UserDefaults.standard
  defaults.removeObject(forKey: "uiLanguage")
  assert(L("Ready") == "Ready", "English must be the default")
  defaults.set("Cantonese", forKey: "language")
  defaults.set("test-device", forKey: "inputUID")
  let delegate = AppDelegate(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  delegate.lastResult = "唔好改 README.md"
  delegate.createSettings()
  assert(delegate.appCheckboxes.count == 3)
  assert(delegate.appCheckboxes[.chatgpt]?.title == "ChatGPT")
  assert(delegate.launchCheckbox?.title == "Launch with enabled apps")
  assert(delegate.modelDiskBytes() > 2_400_000_000 && delegate.modelDiskBytes() < 3_000_000_000)
  assert(delegate.downloadButton?.isEnabled == false)
  let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fresh = AppDelegate(root: empty)
  fresh.createSettings()
  assert(!fresh.modelAvailable && fresh.modelDiskBytes() == 0)
  assert(fresh.downloadButton?.title == "Download" && fresh.downloadButton?.isEnabled == true)
  assert(!fresh.downloader.active, "Opening Settings must never download")
  fresh.settings?.setContentSize(NSSize(width: 700, height: 550))
  fresh.settings?.contentView?.layoutSubtreeIfNeeded()
  let scroll = fresh.settings!.contentView as! NSScrollView
  assert(scroll.documentView!.frame.height > scroll.contentSize.height, "Small screens must scroll")
  assert(scroll.documentView!.isFlipped && scroll.contentView.isFlipped, "Settings should align at the top")
  assert(fresh.modelStatusLabel?.stringValue == "Not downloaded")
  let selector = NSPopUpButton(); selector.addItems(withTitles: ["English", "繁體中文"])
  selector.selectItem(at: 1); delegate.selectUILanguage(selector)
  assert(delegate.settings?.title == "Orcaudio — 設定")
  assert(L("Ready") == "準備就緒")
  selector.selectItem(at: 0); delegate.selectUILanguage(selector)
  assert(delegate.settings?.title == "Orcaudio — Settings")
  assert(defaults.string(forKey: "language") == "Cantonese")
  assert(defaults.string(forKey: "inputUID") == "test-device")
  assert(delegate.lastResult.isEmpty, "Dismissing the result must discard its in-memory text")
  delegate.rebuildMenu()
  assert(!delegate.statusMenu.items.contains { $0.title == "Copy last result" || $0.title == "Show last result" })
  assert(delegate.gpuMemoryLabel?.stringValue == "Unloaded · 0 MB")
  print("PASS: English default, live bilingual settings, speech/device preferences, result disposal, removed history actions, actual model size")
 }
}
