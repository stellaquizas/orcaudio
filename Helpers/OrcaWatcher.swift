import AppKit

// Launched only after the user enables “Launch with enabled apps”. No microphone or model work.
let workspace = NSWorkspace.shared
let config = URL(fileURLWithPath: CommandLine.arguments[1])
func isEnabled(_ bundle: String?) -> Bool {
    guard let bundle, let data = try? Data(contentsOf: config.deletingLastPathComponent().appendingPathComponent("apps.plist")),
          let bundles = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else { return false }
    return bundles.contains(bundle)
}
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
       isEnabled(app.bundleIdentifier) { launchCompanion() }
}
if workspace.runningApplications.contains(where: { isEnabled($0.bundleIdentifier) }) { launchCompanion() }
RunLoop.main.run()
