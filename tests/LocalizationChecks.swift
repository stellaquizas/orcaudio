import Foundation
@main struct LocalizationChecks {
 static func main() {
  let defaults = UserDefaults.standard
  defaults.removeObject(forKey: "uiLanguage")
  assert(L("Select an input in Orca first.") == "Select an input in Orca first.")
  defaults.set("en", forKey: "uiLanguage")
  assert(workerErrorMessage(["code":"silence"]) == "No clear audio detected. Nothing pasted.")
  assert(workerErrorMessage(["message":"arbitrary backend text"]) == "Transcription failed. Please try again.")
  let regex = try! NSRegularExpression(pattern: "%[0-9.]*[@df]")
  func placeholders(_ text: String) -> [String] {
   regex.matches(in: text,range: NSRange(text.startIndex...,in:text)).map { (text as NSString).substring(with:$0.range) }
  }
  for (english, chinese) in traditionalChineseStrings {
   assert(!english.isEmpty && !chinese.isEmpty)
   assert(placeholders(english) == placeholders(chinese), english)
  }
  defaults.set("zh-Hant", forKey: "uiLanguage")
  assert(L("Select an input in Orca first.") == "請先在 Orca 點選輸入位置。")
  assert(workerErrorMessage(["code":"silence"]) == "沒有收到清晰聲音，未貼上文字。")
  assert(workerErrorMessage(["code":"worker_exited","exit_status":Int32(9)]).contains("9"))
  assert(uiError(NSError(domain:"test",code:1), fallback:"Unable to delete the model. Check folder permissions.") == "無法刪除模型，請檢查資料夾權限。")
  let sources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
  let calls = try! NSRegularExpression(pattern: #"L\("([^"\\]*)"\)"#)
  for path in try! FileManager.default.contentsOfDirectory(at: sources,includingPropertiesForKeys:nil) where path.pathExtension == "swift" {
   let source = try! String(contentsOf:path,encoding:.utf8)
   for match in calls.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
    let key = (source as NSString).substring(with:match.range(at:1))
    assert(traditionalChineseStrings[key] != nil, "Missing translation: \(key)")
   }
  }
  print("PASS: default English, reported Orca prompt, bilingual worker errors, format placeholders, translation coverage")
 }
}
