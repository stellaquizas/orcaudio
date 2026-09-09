import AppKit
import ApplicationServices
import Carbon

@main struct NativeChecks {
    static func main() {
        let element = AXUIElementCreateSystemWide()
        let snapshot = FocusSnapshot(pid: 0, app: element, window: element, element: element,
            value: "草稿🧑‍💻end", range: CFRange(location: 2, length: 0), role: kAXTextAreaRole, description: "test")
        assert(snapshot.expected("中英\nSwift") == "草稿中英\nSwift🧑‍💻end")
        let invalid = FocusSnapshot(pid: 0, app: element, window: element, element: element,
            value: "x", range: CFRange(location: 9, length: 1), role: kAXTextFieldRole, description: "test")
        assert(invalid.expected("new") == nil)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setString("原本內容", forType: .string)
        item.setData(Data([0,1,2,255]), forType: NSPasteboard.PasteboardType("test.binary"))
        board.writeObjects([item])
        let old = ClipboardSnapshot(board)
        board.clearContents(); board.setString("辨識結果", forType: .string)
        old.restore(board)
        assert(board.string(forType: .string) == "原本內容")
        assert(board.data(forType: NSPasteboard.PasteboardType("test.binary")) == Data([0,1,2,255]))
        assert(Shortcut.standard.label == "⌃⌥Space")
        let recordingFolder = FileManager.default.temporaryDirectory.appendingPathComponent("OrcaDictation-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        let recording = recordingFolder.appendingPathComponent("recording.wav")
        try! Data([0, 1, 2]).write(to: recording)
        let recorder = Recorder(); recorder.url = recording; recorder.cleanup(); recorder.cleanup()
        assert(!FileManager.default.fileExists(atPath: recordingFolder.path) && recorder.url == nil)
        let devices = inputDevices()
        assert(devices.contains(where: { $0.id == defaultInput() }))
        let first = HotKey(), second = HotKey()
        let probe = Shortcut(key: 90, modifiers: UInt32(controlKey | optionKey | cmdKey), label: "test F20")
        assert(first.register(probe))
        assert(!second.register(probe), "A conflicting shortcut must not replace an existing registration")
        let focus = FocusGuard()
        focus.invalidate()
        let originalCount = NSPasteboard.general.changeCount
        var called = false
        pasteResult("must not paste", guard: focus) { _ in called = true }
        assert(called && NSPasteboard.general.changeCount == originalCount)
        focus.stop()
        print("PASS: Unicode insertion, invalid range, multi-type clipboard restoration, default shortcut, system input lookup")
    }
}
