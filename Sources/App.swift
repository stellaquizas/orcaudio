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
    let orcaAccessibility = OrcaAccessibility()
    var shortcut = Shortcut.load()
    var phase = Phase.idle { didSet { if oldValue != phase && tick != nil { scheduleTick() } } }
    var requestID = UUID().uuidString
    var focus: FocusGuard?
    var lastResult = ""
    var stateText = L("Ready")
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
    let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let statusLabel = NSTextField(wrappingLabelWithString: L("Ready"))
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let resultLabel = NSTextField(wrappingLabelWithString: "")
    let meter = NSLevelIndicator()
    let voiceWave = VoiceWave()
    var voiceAnchor: VoiceAnchor?
    let voiceSubtitle = NSTextField(labelWithString: "")
    let modelLabel = NSTextField(labelWithString: "")
    let modelSpinner = NSProgressIndicator()
    let modelRow = NSStackView()
    let stopButton = NSButton(title: L("Stop"), target: nil, action: nil)
    let copyButton = NSButton(title: L("Copy"), target: nil, action: nil)
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
    private var accessibilityWasTrusted = false
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
        orcaAccessibility.start()
        setupPanel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = brandIcon
        statusItem.button?.toolTip = "Orcaudio · \(shortcut.label)"
        statusMenu.delegate = self; statusMenu.autoenablesItems = false; statusItem.menu = statusMenu
        hotKey.onPress = { [weak self] in self?.toggle() }
        shortcutOK = hotKey.register(shortcut)
        if !shortcutOK { stateText = L("Shortcut unavailable. Choose another in Settings.") }
        worker.onMessage = { [weak self] message in self?.receive(message) }
        recorder.onDeviceChange = { [weak self] in
            guard self?.phase == .recording else { return }
            self?.cancel(message: L("Microphone interrupted. Recording cancelled."))
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
        orcaAccessibility.stop()
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
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = VoiceCapsuleSurface()
        effect.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = effect
        voiceWave.translatesAutoresizingMaskIntoConstraints = false
        voiceWave.widthAnchor.constraint(equalToConstant: 116).isActive = true
        voiceWave.heightAnchor.constraint(equalToConstant: 26).isActive = true
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        statusLabel.maximumNumberOfLines = 2; statusLabel.lineBreakMode = .byTruncatingTail
        voiceSubtitle.font = .systemFont(ofSize: 9.5); voiceSubtitle.textColor = .secondaryLabelColor
        voiceSubtitle.lineBreakMode = .byTruncatingTail
        let words = NSStackView(views: [statusLabel, voiceSubtitle]); words.orientation = .vertical; words.alignment = .leading; words.spacing = 2
        words.widthAnchor.constraint(equalToConstant: 192).isActive = true
        for label in [statusLabel, voiceSubtitle] { label.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true }
        stopButton.target = self; stopButton.action = #selector(toggle)
        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: L("Stop"))
        stopButton.imagePosition = .imageOnly; stopButton.isBordered = false
        copyButton.target = self; copyButton.action = #selector(copyResult)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copy"))
        copyButton.imagePosition = .imageOnly; copyButton.isBordered = false
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Cancel"))!, target: self, action: #selector(dismissVoice))
        dismiss.isBordered = false; panelDismissButton = dismiss
        let controls = NSStackView(views: [stopButton, copyButton, dismiss]); controls.spacing = 8
        let stack = NSStackView(views: [voiceWave, words, controls]); stack.spacing = 8; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -12), stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
    }
    @objc func dismissVoice() { if phase == .idle { hidePanel() } else { cancel() } }
    func refreshVoice() {
        let active = phase == .starting || phase == .recording || phase == .transcribing
        voiceWave.mode = phase == .recording ? .listening : active ? .thinking : .ready
        voiceWave.levels = recorder.waveform
        voiceWave.setAnimating(active && phase != .recording && panel.isVisible)
        stopButton.isHidden = phase != .recording
        copyButton.isHidden = phase != .idle || lastResult.isEmpty
        panelDismissButton?.toolTip = phase == .idle ? L("Dismiss") : L("Cancel")
        if phase == .recording {
            voiceSubtitle.stringValue = !worker.loaded ? String(format: L("Loading %.1f s · %@"), Date().timeIntervalSince(modelLoadStarted), L("you can keep speaking")) : "Orcaudio · \(shortcut.label) · Esc"
        } else if phase == .transcribing {
            voiceSubtitle.stringValue = String(format: L("Waiting %.1f s · Escape to cancel"), Date().timeIntervalSince(stopped))
        } else if phase == .starting { voiceSubtitle.stringValue = "Orcaudio · Esc" }
        else { voiceSubtitle.stringValue = lastResult.isEmpty ? "Orcaudio" : L("Review your text before sending") }
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
            display(L("Select an input in Orca first."))
            return
        }
        guard modelAvailable else { showSettings(); return }
        guard AXIsProcessTrusted() else { showSettings(); display(L("Allow Accessibility, then try your shortcut again.")); return }
        guard globalMonitor != nil else { display(L("Unable to monitor focus. Restart Orcaudio.")); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording()
        case .notDetermined:
            phase = .permission
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.phase == .permission else { return }
                    self.phase = .idle
                    self.display(allowed ? L("Microphone allowed. Return to Orca and try again.") : L("Allow microphone access in Settings."))
                    self.refreshPermissions()
                }
            }
        default: showSettings(); display(L("Allow microphone access in Settings."))
        }
    }

    func beginRecording(guardObject: FocusGuard = FocusGuard()) {
        requestID = UUID().uuidString
        focus = guardObject
        guard guardObject.snapshot != nil else {
            guardObject.stop(); focus = nil
            display(L("Orca input is not ready. Click the input and try your shortcut again."))
            return
        }
        // Any later mouse/key/focus change makes this result manual-copy only.
        guardObject.onInvalidate = { [weak self] in self?.detailLabel.stringValue = L("Focus changed · copy the result when ready") }
        voiceAnchor = VoiceAnchor.capture(guardObject.snapshot)
        lastResult = ""; resultLabel.stringValue = ""
        phase = .starting; display(L("Opening microphone"))
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
            display(L("Listening"))
            detailLabel.stringValue = "\(name) · \(L("Escape to cancel"))"
            if focus?.invalidated == true { detailLabel.stringValue = L("Input not verified · copy the result when ready") }
        } catch { cancel(message: uiError(error, fallback: "Unable to start recording. Check microphone access and available disk space.")) }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        stopped = Date()
        let error = recorder.stop()
        if let error { cancel(message: error); return }
        guard let url = recorder.url else { cancel(message: L("Recording not found.")); return }
        phase = .transcribing; display(worker.loaded ? L("Transcribing") : L("Loading speech model"))
        do { try worker.send(["op": "transcribe", "id": requestID, "path": url.path, "language": UserDefaults.standard.string(forKey: "language") ?? "auto"]) }
        catch { cancel(message: uiError(error, fallback: "Transcription failed. Please try again.")) }
    }

    func receive(_ message: [String: Any]) {
        let type = message["type"] as? String
        let ident = message["id"] as? String
        guard phase == .recording || phase == .transcribing else { return }
        guard ident == nil || ident == "" || ident == requestID else { return }
        if type == "error" { cancel(message: workerErrorMessage(message)); return }
        if type == "status" {
            if phase == .transcribing {
                let state = message["state"] as? String
                display(state == "loading" ? L("Loading speech model") : L("Transcribing"))
            }
            updateModelIndicator()
        }
        if type == "result", phase == .transcribing,
           (message["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cancel(message: L("Transcription failed.")); return }
        if type == "result", phase == .transcribing, let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastResult = text; resultLabel.stringValue = text; recorder.cleanup()
            let elapsed = Date().timeIntervalSince(stopped)
            detailLabel.stringValue = String(format: L("Ready in %.2f s · review before sending"), elapsed)
            let currentID = requestID
            guard let focus, focus.canPaste else {
                self.focus?.stop(); self.focus = nil; phase = .idle
                display(L("Your text is ready. Select Copy.")); return
            }
            phase = .pasting
            pasteResult(text, guard: focus) { [weak self] message in
                guard let self, self.requestID == currentID else { return }
                self.focus?.stop(); self.focus = nil; self.phase = .idle; self.display(message)
            }
        }
    }

    @objc func cancelAction() { cancel() }
    func cancel(message: String = L("Cancelled. Nothing pasted.")) {
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
        if board.setString(lastResult, forType: .string) { display(L("Copied. Paste whenever you are ready.")) }
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
            let instruction = phase == .recording ? L("you can keep speaking") : L("audio captured, please wait")
            modelLabel.stringValue = String(format: L("Loading %.1f s · %@"), elapsed, instruction)
        } else {
            modelLabel.stringValue = L("✓ Model ready")
        }
    }
    func update() {
        refreshVoice()
        updateModelIndicator()
        copyButton.isEnabled = !lastResult.isEmpty
        stopButton.isHidden = phase != .recording
        if phase == .recording {
            meter.doubleValue = min(1, recorder.level * 8)
            statusLabel.stringValue = String(format: L("Listening · %.0f s"), Date().timeIntervalSince(started))
            if recorder.hasCaptureFailure { cancel(message: L("No microphone data. Check your input device.")); return }
            if !recorder.isDeviceAlive { cancel(message: L("Microphone disconnected. Recording cancelled.")); return }
            if Date().timeIntervalSince(started) >= 120 { stopRecording() }
        } else { meter.doubleValue = 0 }
        if phase == .transcribing, Date().timeIntervalSince(stopped) > 180 { cancel(message: L("Transcription timed out. Please try again.")); return }
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
        let modelState = NSMenuItem(title: worker.loaded ? L("Model ready") : L("Model asleep · loads when you start"), action: nil, keyEquivalent: "")
        modelState.isEnabled = false; statusMenu.addItem(modelState)
        item(phase == .recording ? L("Stop recording") : L("Start recording in Orca"), #selector(toggle), enabled: phase == .idle || phase == .recording)
        item(L("Cancel"), #selector(cancelAction), enabled: phase == .starting || phase == .recording || phase == .transcribing)
        statusMenu.addItem(.separator())
        item(L("Settings…"), #selector(showSettings))
        item(L("Unload model from memory"), #selector(unload), enabled: phase == .idle)
        item(String(format: L("Delete model (%@)…"), modelSize()), #selector(deleteModel), enabled: phase == .idle && !downloader.active)
        statusMenu.addItem(.separator()); item(L("Quit Orcaudio"), #selector(quit))
    }
    @objc func unload() { guard phase == .idle else { return }; worker.shutdown(); display(L("Model unloaded. It will load on your next recording.")); }
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
        let alert = NSAlert(); alert.messageText = String(format: L("Delete the local model (%@)?"), modelSize())
        alert.informativeText = L("This removes the only local model copy. It will not download automatically. To restore it, download it manually in Settings.")
        alert.addButton(withTitle: L("Cancel")); alert.addButton(withTitle: L("Delete model"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        worker.shutdown()
        do { try FileManager.default.removeItem(at: root.appendingPathComponent("models/Qwen3-ASR-1.7B-8bit")); display(L("Model deleted.")); refreshDownload(); modelSizeLabel?.stringValue = modelSize(); refreshPermissions() }
        catch { display(uiError(error, fallback: "Unable to delete the model. Check folder permissions.")) }
    }

    @objc func showSettings() {
        focus?.invalidate()
        if settings == nil { createSettings() }
        refreshDevices(); refreshPermissions(); refreshDownload(); modelSizeLabel?.stringValue = modelSize()
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func refreshDevices() {
        guard let popup = microphonePopup else { return }
        popup.removeAllItems(); popup.addItem(withTitle: L("System default"))
        popup.lastItem?.representedObject = ""
        for device in inputDevices() { popup.addItem(withTitle: device.name); popup.lastItem?.representedObject = device.uid }
        let selected = UserDefaults.standard.string(forKey: "inputUID") ?? ""
        if let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { popup.selectItem(at: index) }
        else { popup.addItem(withTitle: L("Selected device is disconnected")); popup.lastItem?.representedObject = selected; popup.selectItem(at: popup.numberOfItems - 1) }
    }
    @objc func selectDevice(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.selectedItem?.representedObject as? String ?? "", forKey: "inputUID") }
    @objc func selectLanguage(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "Cantonese" : "auto", forKey: "language") }
    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let access = AXIsProcessTrusted()
        if access && !accessibilityWasTrusted { orcaAccessibility.start() }
        accessibilityWasTrusted = access
        microphoneStatus?.stringValue = mic ? L("Allowed") : L("Not allowed")
        accessibilityStatus?.stringValue = access ? L("Allowed") : L("Not allowed")
        microphoneStatus?.textColor = mic ? .systemGreen : .secondaryLabelColor
        accessibilityStatus?.textColor = access ? .systemGreen : .secondaryLabelColor
        microphoneAccessButton?.title = mic ? L("Manage") : L("Allow")
        accessibilityAccessButton?.title = access ? L("Manage") : L("Allow")
        if !worker.loaded && phase != .recording && phase != .transcribing {
            gpuMemoryLabel?.stringValue = L("Unloaded · 0 MB")
        } else if let active = worker.activeBytes, let cache = worker.cacheBytes,
                  let sampled = worker.metricsDate, Date().timeIntervalSince(sampled) < 5 {
            gpuMemoryLabel?.stringValue = String(format: L("Active %.2f GB · cache %.0f MB"), Double(active) / 1e9, Double(cache) / 1e6)
        } else { gpuMemoryLabel?.stringValue = L("Waiting for measurement…") }
        let present = FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("download.json").path)
        modelStatusLabel?.stringValue = !present ? L("Not downloaded") : worker.loaded ? L("Model ready") : (phase == .recording || phase == .transcribing) ? L("Loading") : L("Downloaded · asleep")
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
