import AppKit

// Launched only after the user enables “Launch with Orca”. No microphone or model work.
let workspace = NSWorkspace.shared
let config = URL(fileURLWithPath: CommandLine.arguments[1])
func launchCompanion() {
    guard let data = try? Data(contentsOf: config) else { return }
    var stale = false
    guard let app = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
          FileManager.default.fileExists(atPath: app.path) else { return }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.stellacheng.orca-dictation").isEmpty else { return }
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
    workspace.openApplication(at: app, configuration: configuration)
}
let observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
       app.bundleIdentifier == "com.stablyai.orca" { launchCompanion() }
}
if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").isEmpty { launchCompanion() }
RunLoop.main.run()
