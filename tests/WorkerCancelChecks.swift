import Foundation
@main struct WorkerCancelChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-worker-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".venv/bin/python"), withDestinationURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".venv/bin/python"))
        let model = root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("download.json"))
        let script = """
        import json,sys,signal,time,os
        def late(*_):
            print(json.dumps({'type':'result','id':'old','text':'must be ignored'}),flush=True)
            sys.exit(0)
        signal.signal(signal.SIGTERM,late)
        print(json.dumps({'type':'ready'}),flush=True)
        for line in sys.stdin:
            print(json.dumps({'type':'status','state':'loaded'}),flush=True)
            time.sleep(60)
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        let worker = Worker(root: root)
        var sawLoaded = false, lateResult = false
        worker.onMessage = { message in
            if message["state"] as? String == "loaded" { sawLoaded = true }
            if message["type"] as? String == "result" { lateResult = true }
        }
        try worker.send(["op":"load","id":"old"])
        let deadline = Date().addingTimeInterval(5)
        while !sawLoaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        assert(sawLoaded && worker.loaded)
        worker.shutdown()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        assert(!worker.loaded && !lateResult)
        print("PASS: cancellation unloads worker and suppresses late results")
    }
}
