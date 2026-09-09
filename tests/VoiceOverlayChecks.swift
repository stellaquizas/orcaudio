import AppKit
@main struct VoiceOverlayChecks {
 static func main() {
  _ = NSApplication.shared
  let screen = NSRect(x: -1440, y: 200, width: 1440, height: 900)
  let size = NSSize(width: 360, height: 68)
  for target in [NSRect(x: -1000,y: 450,width: 300,height: 80), NSRect(x: -40,y: 1040,width: 20,height: 20), NSRect(x: -1440,y: 200,width: 1,height: 20)] {
   let point = VoiceAnchor(target: target,screen: screen).origin(size: size)
   assert(screen.contains(NSRect(origin: point,size: size)))
   assert(!NSRect(origin: point,size: size).intersects(target))
  }
  assert(cocoaRect(CGRect(x: 20,y: -300,width: 100,height: 30),primaryHeight: 900).minY == 1170)
  let app = AppDelegate(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  app.setupPanel()
  assert(!app.panel.canBecomeKey && !app.panel.canBecomeMain)
  UserDefaults.standard.set("en",forKey:"uiLanguage")
  app.phase = .recording; app.worker.loaded = true
  app.statusLabel.stringValue = "Listening · 12 s"
  app.refreshVoice(); app.voiceWave.level = 0.08; app.voiceWave.setAnimating(true)
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  let view=app.panel.contentView!; view.layoutSubtreeIfNeeded()
  let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
  view.cacheDisplay(in:view.bounds,to:bitmap)
  try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/orcaudio-voice.png"))
  app.phase = .starting; app.requestID = "cancel-start"
  app.cancel()
  assert(app.phase == .idle && app.recorder.url == nil && app.requestID != "cancel-start")
  app.hidePanel()
  print("PASS: anchor avoids text, screen edges, multi-display coordinates, non-key overlay, startup cancellation")
 }
}
