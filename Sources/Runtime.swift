import Foundation

struct Runtime {
    static var bundled: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("Runtime")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("bin/python3.11").path) ? url : nil
    }
    static func python(root: URL) -> URL { bundled?.appendingPathComponent("bin/python3.11") ?? root.appendingPathComponent(".venv/bin/python") }
    static func script(_ name: String, root: URL) -> URL { bundled == nil ? root.appendingPathComponent(name) : Bundle.main.resourceURL!.appendingPathComponent("Scripts/" + name) }
    static var dataRoot: URL {
        if let development = Bundle.main.object(forInfoDictionaryKey: "DictationProjectRoot") as? String { return URL(fileURLWithPath: development) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orcaudio")
    }
    static func environment(root: URL, offline: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
        env["ORCAUDIO_DATA_ROOT"] = root.path
        env["PYTHONNOUSERSITE"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HOME"] = root.appendingPathComponent(".hf").path
        env["HF_HUB_OFFLINE"] = offline ? "1" : "0"
        env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["HF_HUB_DISABLE_XET"] = "1" // Keep a single resumable download, no separate chunk cache.
        return env
    }
}
