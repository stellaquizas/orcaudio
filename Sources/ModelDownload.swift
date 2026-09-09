import Foundation

final class ModelDownload {
    private var process: Process?
    private var generation = UUID()
    var active = false
    var fraction: Double = 0
    var received: Int64 = 0
    var total: Int64 = 0
    var onChange: (() -> Void)?
    var onFinish: ((String?) -> Void)?

    func start(root: URL) throws {
        guard !active else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let p = Process(), pipe = Pipe()
        p.executableURL = Runtime.python(root: root)
        p.arguments = ["-u", Runtime.script("download_model.py", root: root).path]
        p.environment = Runtime.environment(root: root, offline: false)
        p.currentDirectoryURL = root
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        let token = UUID(); generation = token
        try p.run(); process = p; active = true; fraction = 0; received = 0; total = 0; onChange?()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var pending = Data(), completed = false
            var failure: String?
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let index = pending.firstIndex(of: 10) {
                    let line = pending[..<index]; pending.removeSubrange(...index)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if message["type"] as? String == "complete" { completed = true }
                    if message["type"] as? String == "error" { failure = message["message"] as? String }
                    if let received = message["received"] as? Int64, let total = message["total"] as? Int64 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token else { return }
                            self.received = received; self.total = total
                            self.fraction = total > 0 ? Double(received) / Double(total) : 0
                            self.onChange?()
                        }
                    }
                }
            }
            p.waitUntilExit()
            let error = completed && p.terminationStatus == 0 ? nil : (failure ?? L("Download failed. Check your connection and try again."))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.active = false; self.process = nil; self.onChange?(); self.onFinish?(error)
            }
        }
    }
    func cancel() {
        generation = UUID(); let old = process; process = nil; active = false
        if let old, old.isRunning {
            old.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if old.isRunning { kill(old.processIdentifier, SIGKILL) } }
        }
        onChange?()
    }
    deinit { cancel() }
}
