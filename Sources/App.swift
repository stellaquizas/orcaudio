import AppKit
import AVFoundation
import ApplicationServices

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Phase { case idle, permission, starting, recording, transcribing, pasting }
    let root: URL
    let worker: Worker
    let recorder = Recorder()
    let downloader = ModelDownload()
    var downloadButton: NSButton?
    var downloadCancelButton: NSButton?
    var downloadProgress: NSProgressIndicator?
    var downloadLabel: NSTextField?
    var downloadError: String?
    var launchCheckbox: NSButton?
    let hotKey = HotKey()
    var shortcut = Shortcut.load()
    var phase = Phase.idle { didSet { if oldValue != phase && tick != nil { scheduleTick() } } }
    var requestID = UUID().uuidString
    var focus: FocusGuard?
    var lastResult = ""
    var stateText = L("準備就緒")
    var started = Date()
    var stopped = Date()
    var modelLoadStarted = Date()
    private var showingModelSpinner = false
    var tick: Timer?
    private var panelDismissal: DispatchWorkItem?
    var globalMonitor: Any?
    var localMonitor: Any?
    var statusItem: NSStatusItem!
    private lazy var brandIcon: NSImage = {
        let image = NSImage(named: NSImage.Name("MenuBarTemplate")) ?? NSImage(size: NSSize(width: 30, height: 18))
        image.size = NSSize(width: 30, height: 18)
        image.isTemplate = true
        return image
    }()
    let statusMenu = NSMenu()
    let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 68), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let statusLabel = NSTextField(wrappingLabelWithString: L("準備就緒"))
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let resultLabel = NSTextField(wrappingLabelWithString: "")
    let meter = NSLevelIndicator()
    let voiceWave = VoiceWave()
    var voiceAnchor: VoiceAnchor?
    let voiceSubtitle = NSTextField(labelWithString: "")
    let modelLabel = NSTextField(labelWithString: "")
    let modelSpinner = NSProgressIndicator()
    let modelRow = NSStackView()
    let stopButton = NSButton(title: L("停止"), target: nil, action: nil)
    let copyButton = NSButton(title: L("複製"), target: nil, action: nil)
    var settings: NSWindow?
    var microphonePopup: NSPopUpButton?
    var microphoneStatus: NSTextField?
    var accessibilityStatus: NSTextField?
    var microphoneAccessButton: NSButton?
    var accessibilityAccessButton: NSButton?
    var modelStatusLabel: NSTextField?
    var modelSizeLabel: NSTextField?
    var gpuMemoryLabel: NSTextField?
    private var lastSettingsRefresh = Date.distantPast
    var panelCancelButton: NSButton?
    var panelDismissButton: NSButton?
    var shortcutField: ShortcutField?
    var shortcutOK = true

    init(root: URL) { self.root = root; worker = Worker(root: root); super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 { NSApp.terminate(nil); return }
        // Recover only this app's abandoned ephemeral recordings after an abnormal exit.
        let temp = FileManager.default.temporaryDirectory
        for folder in (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? [] {
            if folder.lastPathComponent.hasPrefix("OrcaDictation-") { try? FileManager.default.removeItem(at: folder) }
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        downloader.onChange = { [weak self] in self?.refreshDownload() }
        downloader.onFinish = { [weak self] error in
            guard let self else { return }
            self.downloadError = error; self.refreshDownload()
            self.modelSizeLabel?.stringValue = self.modelSize(); self.refreshPermissions()
        }
        setupPanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = brandIcon
        statusItem.button?.toolTip = "Orcaudio · \(shortcut.label)"
        statusMenu.delegate = self; statusMenu.autoenablesItems = false; statusItem.menu = statusMenu
        hotKey.onPress = { [weak self] in self?.toggle() }
        shortcutOK = hotKey.register(shortcut)
        if !shortcutOK { stateText = L("快捷鍵被佔用，請在設定更改。") }
        worker.onMessage = { [weak self] message in self?.receive(message) }
        recorder.onDeviceChange = { [weak self] in
            guard self?.phase == .recording else { return }
            self?.cancel(message: L("麥克風已中斷或發生收音錯誤；錄音已取消。"))
        }
        recorder.onLimit = { [weak self] in self?.stopRecording() }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.interaction(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.phase != .idle { self.cancel(); return nil }
            if event.window === self.panel { return event }
            if self.phase == .starting || self.phase == .recording || self.phase == .transcribing { self.focus?.invalidate() }
            return event
        }
        scheduleTick()
        rebuildMenu()
        if !UserDefaults.standard.bool(forKey: "shownWelcome") || !shortcutOK {
            UserDefaults.standard.set(true, forKey: "shownWelcome")
            showSettings()
        }
    }

    func scheduleTick() {
        tick?.invalidate()
        let interval: TimeInterval = phase == .idle ? 1 : 0.1
        tick = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        tick?.tolerance = phase == .idle ? 0.2 : 0.02
        RunLoop.main.add(tick!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        downloader.cancel(); worker.shutdown(); recorder.cleanup(); focus?.stop()
        tick?.invalidate()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func interaction(_ event: NSEvent) {
        guard phase == .starting || phase == .recording || phase == .transcribing || phase == .permission else { return }
        if event.type == .keyDown, event.keyCode == 53 { cancel(); return }
        if event.type == .keyDown, shortcut.matches(event) { return }
        focus?.invalidate()
    }

    func setupPanel() {
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true; effect.layer?.cornerRadius = 34; effect.layer?.masksToBounds = true
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor; effect.layer?.borderWidth = 0.7
        panel.contentView = effect
        voiceWave.translatesAutoresizingMaskIntoConstraints = false
        voiceWave.widthAnchor.constraint(equalToConstant: 52).isActive = true
        voiceWave.heightAnchor.constraint(equalToConstant: 38).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.maximumNumberOfLines = 2; statusLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitle.font = .systemFont(ofSize: 10); voiceSubtitle.textColor = .secondaryLabelColor
        voiceSubtitle.lineBreakMode = .byTruncatingTail
        let words = NSStackView(views: [statusLabel, voiceSubtitle]); words.orientation = .vertical; words.alignment = .leading; words.spacing = 3
        words.widthAnchor.constraint(equalToConstant: 205).isActive = true
        for label in [statusLabel, voiceSubtitle] { label.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true }
        stopButton.target = self; stopButton.action = #selector(toggle)
        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: L("停止"))
        stopButton.imagePosition = .imageOnly; stopButton.isBordered = false
        copyButton.target = self; copyButton.action = #selector(copyResult)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("複製"))
        copyButton.imagePosition = .imageOnly; copyButton.isBordered = false
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("取消"))!, target: self, action: #selector(dismissVoice))
        dismiss.isBordered = false; panelDismissButton = dismiss
        let controls = NSStackView(views: [stopButton, copyButton, dismiss]); controls.spacing = 9
        let stack = NSStackView(views: [voiceWave, words, controls]); stack.spacing = 10; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15), stack.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -15), stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
    }
    @objc func dismissVoice() { if phase == .idle { hidePanel() } else { cancel() } }
    func refreshVoice() {
        let active = phase == .starting || phase == .recording || phase == .transcribing
        voiceWave.mode = phase == .recording ? .listening : active ? .thinking : .ready
        voiceWave.level = recorder.level
        voiceWave.setAnimating(active && panel.isVisible)
        stopButton.isHidden = phase != .recording
        copyButton.isHidden = phase != .idle || lastResult.isEmpty
        panelDismissButton?.toolTip = phase == .idle ? L("收起") : L("取消")
        if phase == .recording {
            voiceSubtitle.stringValue = !worker.loaded ? String(format: L("載入模型 %.1f 秒 · %@"), Date().timeIntervalSince(modelLoadStarted), L("可以繼續說話")) : "Orcaudio · \(shortcut.label) · Esc"
        } else if phase == .transcribing {
            voiceSubtitle.stringValue = String(format: L("已等待 %.1f 秒 · Escape 取消"), Date().timeIntervalSince(stopped))
        } else if phase == .starting { voiceSubtitle.stringValue = "Orcaudio · Esc" }
        else { voiceSubtitle.stringValue = lastResult.isEmpty ? "Orcaudio" : L("請檢查文字後再送出") }
        statusLabel.toolTip = stateText
    }
    func showPanel(hideAfter delay: TimeInterval = 2) {
        panelDismissal?.cancel(); panelDismissal = nil
        if voiceAnchor == nil { voiceAnchor = VoiceAnchor.capture(nil) }
        if let anchor = voiceAnchor { panel.setFrameOrigin(anchor.origin(size: panel.frame.size)) }
        panel.orderFrontRegardless()
        refreshVoice()
        if phase == .idle {
            let dismissal = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .idle else { return }
                self.hidePanel()
            }
            panelDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
        }
    }
    func display(_ message: String) { stateText = message; statusLabel.stringValue = message; showPanel() }
    @objc func hidePanel() { panelDismissal?.cancel(); panelDismissal = nil; panel.orderOut(nil); voiceWave.setAnimating(false); voiceAnchor = nil; if phase == .idle { lastResult = ""; resultLabel.stringValue = "" } }

    @objc func toggle() {
        if phase == .starting { cancel(); return }
        if phase == .recording { stopRecording(); return }
        guard phase == .idle else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.stablyai.orca" else {
            display(L("請先在 Orca 點選輸入位置。"))
            return
        }
        guard modelAvailable else { showSettings(); return }
        guard AXIsProcessTrusted() else { showSettings(); display(L("請先授予輔助使用權限。完成後重新按快捷鍵。")); return }
        guard globalMonitor != nil else { display(L("無法監察焦點變更，請重新啟動 app。")); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording()
        case .notDetermined:
            phase = .permission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.phase == .permission else { return }
                    self.phase = .idle
                    self.display(allowed ? L("麥克風已允許；回到 Orca 再按快捷鍵。") : L("麥克風未允許，請到設定開啟。"))
                    self.refreshPermissions()
                }
            }
        default: showSettings(); display(L("麥克風未允許，請到設定開啟。"))
        }
    }

    func beginRecording() {
        requestID = UUID().uuidString
        let guardObject = FocusGuard(); focus = guardObject
        // Any later mouse/key/focus change makes this result manual-copy only.
        guardObject.onInvalidate = { [weak self] in self?.detailLabel.stringValue = L("位置已改變 · 完成後請手動複製") }
        voiceAnchor = VoiceAnchor.capture(guardObject.snapshot)
        lastResult = ""; resultLabel.stringValue = ""
        phase = .starting; display(L("正在準備收音"))
        panel.displayIfNeeded()
        let id = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.phase == .starting, self.requestID == id else { return }
            self.startCapture()
        }
    }
    func startCapture() {
        do {
            modelLoadStarted = Date()
            try worker.send(["op": "load", "id": requestID])
            let name = try recorder.start(uid: UserDefaults.standard.string(forKey: "inputUID") ?? "")
            started = Date(); phase = .recording
            display(L("正在聆聽"))
            detailLabel.stringValue = "\(name) · \(L("Escape 取消"))"
            if focus?.invalidated == true { detailLabel.stringValue = L("無法確認輸入位置 · 完成後請手動複製") }
        } catch { cancel(message: error.localizedDescription) }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        stopped = Date()
        let error = recorder.stop()
        if let error { cancel(message: error); return }
        guard let url = recorder.url else { cancel(message: L("找不到錄音。")); return }
        phase = .transcribing; display(worker.loaded ? L("正在辨識") : L("正在載入模型"))
        do { try worker.send(["op": "transcribe", "id": requestID, "path": url.path, "language": UserDefaults.standard.string(forKey: "language") ?? "auto"]) }
        catch { cancel(message: error.localizedDescription) }
    }

    func receive(_ message: [String: Any]) {
        let type = message["type"] as? String
        let ident = message["id"] as? String
        guard phase == .recording || phase == .transcribing else { return }
        guard ident == nil || ident == "" || ident == requestID else { return }
        if type == "error" { cancel(message: message["message"] as? String ?? L("辨識失敗。")); return }
        if type == "status" {
            if phase == .transcribing {
                let state = message["state"] as? String
                display(state == "loading" ? L("正在載入模型") : L("正在辨識"))
            }
            updateModelIndicator()
        }
        if type == "result", phase == .transcribing,
           (message["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cancel(message: L("辨識失敗。")); return }
        if type == "result", phase == .transcribing, let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastResult = text; resultLabel.stringValue = text; recorder.cleanup()
            let elapsed = Date().timeIntervalSince(stopped)
            detailLabel.stringValue = String(format: L("停止後 %.2f 秒 · 請檢查辨識結果"), elapsed)
            let currentID = requestID
            guard let focus, focus.canPaste else {
                self.focus?.stop(); self.focus = nil; phase = .idle
                display(L("結果已準備好，請按「複製」。")); return
            }
            phase = .pasting
            pasteResult(text, guard: focus) { [weak self] message in
                guard let self, self.requestID == currentID else { return }
                self.focus?.stop(); self.focus = nil; self.phase = .idle; self.display(message)
            }
        }
    }

    @objc func cancelAction() { cancel() }
    func cancel(message: String = L("已取消，沒有貼上文字。")) {
        // A dispatched paste is never retried or retrospectively called cancelled.
        guard phase != .pasting else { return }
        requestID = UUID().uuidString
        worker.shutdown(); recorder.cleanup(); focus?.stop(); focus = nil
        phase = .idle; meter.doubleValue = 0; detailLabel.stringValue = ""
        display(message)
    }
    @objc func copyResult() {
        guard !lastResult.isEmpty else { return }
        let board = NSPasteboard.general; board.clearContents()
        if board.setString(lastResult, forType: .string) { display(L("已複製，請自行貼上。")) }
    }
    func updateModelIndicator() {
        let active = phase == .recording || phase == .transcribing
        let loading = active && !worker.loaded
        modelRow.isHidden = !active
        if loading != showingModelSpinner {
            showingModelSpinner = loading
            if loading { modelSpinner.startAnimation(nil) } else { modelSpinner.stopAnimation(nil) }
        }
        guard active else { return }
        if loading {
            let elapsed = Date().timeIntervalSince(modelLoadStarted)
            let instruction = phase == .recording ? L("可以繼續說話") : L("錄音已保存，請稍候")
            modelLabel.stringValue = String(format: L("載入模型 %.1f 秒 · %@"), elapsed, instruction)
        } else {
            modelLabel.stringValue = L("✓ 模型已就緒")
        }
    }
    func update() {
        refreshVoice()
        updateModelIndicator()
        copyButton.isEnabled = !lastResult.isEmpty
        stopButton.isHidden = phase != .recording
        if phase == .recording {
            meter.doubleValue = min(1, recorder.level * 8)
            statusLabel.stringValue = String(format: L("正在聆聽 · %.0f 秒"), Date().timeIntervalSince(started))
            if recorder.hasCaptureFailure { cancel(message: L("沒有收到麥克風資料，請檢查輸入裝置。")); return }
            if !recorder.isDeviceAlive { cancel(message: L("麥克風已中斷，錄音已取消。")); return }
            if Date().timeIntervalSince(started) >= 120 { stopRecording() }
        } else { meter.doubleValue = 0 }
        if phase == .transcribing, Date().timeIntervalSince(stopped) > 180 { cancel(message: L("辨識逾時，請重新開始。")); return }
        if phase == .idle, worker.loaded, Date().timeIntervalSince(worker.lastUsed) > 600 { worker.shutdown() }
        statusItem.button?.image = brandIcon
        statusItem.button?.contentTintColor = phase == .recording ? .systemRed : nil
        if settings?.isVisible == true && Date().timeIntervalSince(lastSettingsRefresh) >= 1 {
            lastSettingsRefresh = Date(); refreshPermissions(); refreshDownload()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
    func rebuildMenu() {
        statusMenu.removeAllItems()
        func item(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; statusMenu.addItem(item)
        }
        let status = NSMenuItem(title: "Orcaudio · \(shortcut.label)", action: nil, keyEquivalent: ""); status.isEnabled = false; statusMenu.addItem(status)
        let modelState = NSMenuItem(title: worker.loaded ? L("模型已就緒") : L("模型未載入 · 開始錄音時自動載入"), action: nil, keyEquivalent: "")
        modelState.isEnabled = false; statusMenu.addItem(modelState)
        item(phase == .recording ? L("停止錄音") : L("開始錄音（先點選 Orca 輸入區）"), #selector(toggle), enabled: phase == .idle || phase == .recording)
        item(L("取消"), #selector(cancelAction), enabled: phase == .starting || phase == .recording || phase == .transcribing)
        statusMenu.addItem(.separator())
        item(L("設定與權限…"), #selector(showSettings))
        item(L("卸載記憶體中的模型"), #selector(unload), enabled: phase == .idle)
        item(String(format: L("刪除模型（%@）…"), modelSize()), #selector(deleteModel), enabled: phase == .idle && !downloader.active)
        statusMenu.addItem(.separator()); item(L("結束 Orcaudio"), #selector(quit))
    }
    @objc func unload() { guard phase == .idle else { return }; worker.shutdown(); display(L("模型已卸載；下次錄音會重新載入。")); }
    @objc func quit() { NSApp.terminate(nil) }
    var modelAvailable: Bool { FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("download.json").path) }
    var modelDirectory: URL { root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit") }
    func modelDiskBytes() -> Int64 {
        let files = FileManager.default.enumerator(at: modelDirectory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        var bytes: Int64 = 0
        while let path = files?.nextObject() as? URL {
            if let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
    func modelSize() -> String { String(format: "%.3f GB", Double(modelDiskBytes()) / 1_000_000_000) }
    @objc func deleteModel() {
        guard phase == .idle && !downloader.active else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = String(format: L("刪除本機模型（%@）？"), modelSize())
        alert.informativeText = L("模型只存一份。刪除後不會自動重新下載；如要再用，請在設定手動下載。")
        alert.addButton(withTitle: L("取消")); alert.addButton(withTitle: L("刪除模型"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        worker.shutdown()
        do { try FileManager.default.removeItem(at: root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit")); display(L("模型已刪除。")); refreshDownload(); modelSizeLabel?.stringValue = modelSize(); refreshPermissions() }
        catch { display(error.localizedDescription) }
    }

    @objc func showSettings() {
        focus?.invalidate()
        if settings == nil { createSettings() }
        refreshDevices(); refreshPermissions(); refreshDownload(); modelSizeLabel?.stringValue = modelSize()
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func refreshDevices() {
        guard let popup = microphonePopup else { return }
        popup.removeAllItems(); popup.addItem(withTitle: L("跟隨系統預設"))
        popup.lastItem?.representedObject = ""
        for device in inputDevices() { popup.addItem(withTitle: device.name); popup.lastItem?.representedObject = device.uid }
        let selected = UserDefaults.standard.string(forKey: "inputUID") ?? ""
        if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { popup.selectItem(at: index) }
        else { popup.addItem(withTitle: L("已選裝置目前未連接")); popup.lastItem?.representedObject = selected; popup.selectItem(at: popup.numberOfItems - 1) }
    }
    @objc func selectDevice(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.selectedItem?.representedObject as? String ?? "", forKey: "inputUID") }
    @objc func selectLanguage(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "Cantonese" : "auto", forKey: "language") }
    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let access = AXIsProcessTrusted()
        microphoneStatus?.stringValue = mic ? L("已允許") : L("未允許")
        accessibilityStatus?.stringValue = access ? L("已允許") : L("未允許")
        microphoneStatus?.textColor = mic ? .systemGreen : .secondaryLabelColor
        accessibilityStatus?.textColor = access ? .systemGreen : .secondaryLabelColor
        microphoneAccessButton?.title = mic ? L("管理") : L("允許")
        accessibilityAccessButton?.title = access ? L("管理") : L("允許")
        if !worker.loaded && phase != .recording && phase != .transcribing {
            gpuMemoryLabel?.stringValue = L("未載入 · 0 MB")
        } else if let active = worker.activeBytes, let cache = worker.cacheBytes,
                  let sampled = worker.metricsDate, Date().timeIntervalSince(sampled) < 5 {
            gpuMemoryLabel?.stringValue = String(format: L("使用中 %.2f GB · 快取 %.0f MB"), Double(active) / 1e9, Double(cache) / 1e6)
        } else { gpuMemoryLabel?.stringValue = L("等待量度…") }
        let present = FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("download.json").path)
        modelStatusLabel?.stringValue = !present ? L("未下載") : worker.loaded ? L("模型已就緒") : (phase == .recording || phase == .transcribing) ? L("載入中") : L("已下載・閒置中")
    }
    @objc func accessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func microphonePermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.refreshPermissions() } }
        } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
    }
}
