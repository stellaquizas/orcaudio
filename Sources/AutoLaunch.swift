import AppKit

struct AutoLaunch {
    static let label = "local.stellacheng.orcaudio.watcher"
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orcaudio/Launcher")
    static let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var enabled: Bool { FileManager.default.fileExists(atPath: plist.path) }
    @discardableResult private static func launchctl(_ args: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
    static func setEnabled(_ enabled: Bool) throws {
        let service = "gui/\(getuid())/\(label)"
        if !enabled {
            _ = try launchctl(["bootout", service])
            if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            return
        }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("OrcaWatcher"), FileManager.default.fileExists(atPath: bundled.path) else { throw DictationError(L("Launch helper missing. Reinstall Orcaudio.")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("OrcaWatcher")
        let candidate = directory.appendingPathComponent("OrcaWatcher.new")
        try? FileManager.default.removeItem(at: candidate)
        try FileManager.default.copyItem(at: bundled, to: candidate)
        _ = try launchctl(["bootout", service])
        if FileManager.default.fileExists(atPath: helper.path) { try FileManager.default.removeItem(at: helper) }
        try FileManager.default.moveItem(at: candidate, to: helper)
        let bookmark = directory.appendingPathComponent("app.bookmark")
        try Bundle.main.bundleURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).write(to: bookmark, options: .atomic)
        let job: [String: Any] = ["Label": label, "ProgramArguments": [helper.path, bookmark.path], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        _ = try launchctl(["enable", service])
        guard try launchctl(["bootstrap", "gui/\(getuid())", plist.path]) == 0 else {
            try? FileManager.default.removeItem(at: plist)
            throw DictationError(L("Could not enable automatic launch. Please try again."))
        }
    }
}
