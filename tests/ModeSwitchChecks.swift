import AppKit
@main struct ModeSwitchChecks {
 static func main() {
  assert(ModeShortcut.matches(key: 48, flags: .maskShift))
  assert(ModeShortcut.matches(key: 48, flags: [.maskShift,.maskAlphaShift]))
  for flags: CGEventFlags in [[], .maskCommand, [.maskShift,.maskCommand], [.maskShift,.maskControl], [.maskShift,.maskAlternate]] {
   assert(!ModeShortcut.matches(key: 48, flags: flags))
  }
  assert(!ModeShortcut.matches(key: 49,flags:.maskShift))
  SupportedApp.save([.orca,.cursor,.chatgpt])
  assert(!ModeShortcut.accepts("com.stablyai.orca"))
  assert(!ModeShortcut.accepts("com.apple.Terminal"))
  assert(!ModeShortcut.accepts(nil))
  assert(ModeShortcut.accepts("com.openai.codex"))
  assert(ModeShortcut.accepts("com.todesktop.230313mzl4w4u92"))
  SupportedApp.save([.orca])
  assert(!ModeShortcut.accepts("com.openai.codex"))
  assert(!ModeShortcut.accepts("com.todesktop.230313mzl4w4u92"))
  assert(ModeSwitcher.next("Ask",kind:.cursor)=="Agent")
  assert(ModeSwitcher.next("Debug",kind:.cursor)=="Multitask")
  assert(ModeSwitcher.next("Plan",kind:.chatgpt)=="Goal")
  assert(ModeSwitcher.next("Goal",kind:.chatgpt)=="Default")
  assert(ModeSwitcher.next("Future unknown mode",kind:.chatgpt)==nil)
  print("PASS: exact Shift-Tab chord, enabled desktop scope, mode order and unknown-mode rejection")
 }
}
