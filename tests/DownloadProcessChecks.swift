import Foundation
@main struct DownloadProcessChecks {
 static func wait(_ condition: () -> Bool) {
  let until = Date().addingTimeInterval(5)
  while !condition() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  assert(condition(), "Download subprocess callback timed out")
 }
 static func main() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let executable = root.appendingPathComponent(".venv/bin/python")
  try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  func script(_ body: String) throws {
   try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
   try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }
  let download = ModelDownload(); var finished = false; var error: String?
  download.onFinish = { error = $0; finished = true }
  try script("printf '%s\\n' '{\"type\":\"progress\",\"received\":50,\"total\":100}' '{\"type\":\"complete\"}'\n")
  try download.start(root: root); wait { finished }
  assert(error == nil && download.fraction == 0.5 && !download.active)
  finished = false
  try script("printf '%s\\n' '{\"type\":\"error\",\"message\":\"offline\"}'\nexit 1\n")
  try download.start(root: root); wait { finished }
  assert(error == "offline" && !download.active)
  finished = false
  try script("exec /bin/sleep 3\n")
  try download.start(root: root); download.cancel()
  RunLoop.main.run(until: Date().addingTimeInterval(1.2))
  assert(!download.active && !finished, "Cancellation must ignore stale completion")
  print("PASS: download progress, success, error, cancellation and stale callback guard")
 }
}
