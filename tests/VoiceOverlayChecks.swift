import AppKit
@main struct VoiceOverlayChecks {
 static func main() {
  _ = NSApplication.shared
  let screen = NSRect(x: -1440, y: 200, width: 1440, height: 900)
  let size = NSSize(width: 400, height: 48)
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
  var meter = VoiceMeter()
  for _ in 0..<16000 { meter.append(0) }
  assert(meter.levels.allSatisfy { $0 == 0 }, "Silence must not animate")
  for _ in 0..<800 { meter.append(0.01) }
  let quiet = meter.levels.last!
  for _ in 0..<800 { meter.append(0.1) }
  assert(meter.levels.last! > quiet && quiet > 0)
  for _ in 0..<18400 { meter.append(0) }
  assert(meter.levels.count == 23 && meter.levels.allSatisfy { $0 == 0 })
  for _ in 0..<800 { meter.append(.nan) }
  assert(meter.levels.allSatisfy { $0.isFinite })
  for level: Float in [0, 0, 0.003, 0.008, 0.02, 0.04, 0.08, 0.04, 0.01, 0.004, 0, 0, 0.002, 0.006, 0.015, 0.06, 0.1, 0.05, 0.02, 0.006, 0.002, 0, 0] {
   for _ in 0..<800 { meter.append(level) }
  }
  app.refreshVoice(); app.voiceWave.levels = meter.levels
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  let view=app.panel.contentView!; view.layoutSubtreeIfNeeded()
  let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
  view.cacheDisplay(in:view.bounds,to:bitmap)
  assert(app.panel.frame.size == size)
  assert(!app.panel.hasShadow)
  assert((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01, "Capsule corners must be transparent")
  assert((bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh/2)?.alphaComponent ?? 0) > 0.9)
  try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/orcaudio-voice.png"))
  app.phase = .starting; app.requestID = "cancel-start"
  app.cancel()
  assert(app.phase == .idle && app.recorder.url == nil && app.requestID != "cancel-start")
  app.hidePanel()
  print("PASS: anchor avoids text, screen edges, multi-display coordinates, non-key overlay, startup cancellation")
 }
}
