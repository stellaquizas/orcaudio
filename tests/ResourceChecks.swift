import AppKit
@main struct ResourceChecks {
 static func main() throws {
  _ = NSApplication.shared
  UserDefaults.standard.set("en", forKey: "uiLanguage")
  let app = AppDelegate(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  app.createSettings()
  try app.worker.send(["op":"load", "id":"resources"])
  let deadline = Date().addingTimeInterval(30)
  while !app.worker.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  assert(app.worker.loaded)
  let lastUsed = app.worker.lastUsed
  RunLoop.main.run(until: Date().addingTimeInterval(1.5))
  assert(app.worker.activeBytes != nil && app.worker.activeBytes! > 2_000_000_000)
  assert(app.worker.lastUsed == lastUsed, "Memory samples must not keep model alive")
  app.refreshPermissions()
  assert(app.gpuMemoryLabel!.stringValue.contains("Active"))
  print("Measured UI:", app.gpuMemoryLabel!.stringValue)
  app.worker.shutdown(); app.refreshPermissions()
  assert(app.worker.activeBytes == nil && app.gpuMemoryLabel!.stringValue == "Unloaded · 0 MB")
  print("PASS: live MLX memory, telemetry preserves idle expiry, unload clears values")
 }
}
