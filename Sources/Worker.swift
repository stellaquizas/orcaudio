import Foundation

final class Worker {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let readQueue = DispatchQueue(label: "dictation.worker.read")
    private var generation = UUID()
    var activeBytes: Int64?
    var cacheBytes: Int64?
    var metricsDate: Date?
    var loaded = false
    var lastUsed = Date()
    var onMessage: (([String: Any]) -> Void)?
    let root: URL
    init(root: URL) { self.root = root }

    func send(_ request: [String: Any]) throws {
        if process?.isRunning != true { try launch() }
        lastUsed = Date()
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input?.write(contentsOf: data)
    }

    private func launch() throws {
        guard FileManager.default.fileExists(atPath: Runtime.python(root: root).path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit/download.json").path) else {
            throw DictationError(L("No model installed. Choose Download in Settings."))
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)(deny network*)", Runtime.python(root: root).path, "-u", Runtime.script("worker.py", root: root).path]
        p.currentDirectoryURL = root
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        p.environment = Runtime.environment(root: root, offline: true)
        let token = UUID(); generation = token
        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.loaded = false; self.activeBytes = nil; self.cacheBytes = nil; self.metricsDate = nil
                self.onMessage?(["type": "error", "code": "worker_exited", "exit_status": process.terminationStatus])
            }
        }
        loaded = false
        try p.run()
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let reader = stdout.fileHandleForReading
        readQueue.async { [weak self] in
            var pending = Data()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let end = pending.firstIndex(of: 10) {
                    let line = pending[..<end]; pending.removeSubrange(...end)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        if object["type"] as? String == "metrics" {
                            self.activeBytes = object["active_bytes"] as? Int64
                            self.cacheBytes = object["cache_bytes"] as? Int64
                            self.metricsDate = Date()
                            return // Telemetry must not reset the 10-minute idle timer.
                        }
                        if object["state"] as? String == "loaded" { self.loaded = true }
                        self.lastUsed = Date()
                        self.onMessage?(object)
                    }
                }
            }
        }
    }

    func shutdown() {
        generation = UUID(); loaded = false; activeBytes = nil; cacheBytes = nil; metricsDate = nil
        try? input?.close(); input = nil
        let old = process
        if old?.isRunning == true {
            old?.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if let old, old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        process = nil; output = nil
    }
    deinit { shutdown() }
}
