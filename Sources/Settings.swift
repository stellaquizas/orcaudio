import AppKit

private final class SettingsDocumentView: NSView { override var isFlipped: Bool { true } }
private final class SettingsClipView: NSClipView { override var isFlipped: Bool { true } }

private func caption(_ text: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    return label
}

private func vertical(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    return stack
}

private func row(_ title: String, _ controls: [NSView]) -> NSStackView {
    let label = caption(title, size: 13)
    label.widthAnchor.constraint(equalToConstant: 150).isActive = true
    let stack = NSStackView(views: [label] + controls)
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 10
    stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    return stack
}

private func card(_ title: String, symbol: String, views: [NSView]) -> NSView {
    let heading = caption(title, size: 13); heading.font = .systemFont(ofSize: 13, weight: .semibold)
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
    let header = NSStackView(views: [icon, heading]); header.spacing = 8
    let stack = vertical([header] + views, spacing: 10)
    let box = NSBox(); box.boxType = .custom
    box.borderColor = .separatorColor; box.borderWidth = 0.5; box.cornerRadius = 12
    box.fillColor = .controlBackgroundColor; box.contentViewMargins = .zero
    let content = NSView(); box.contentView = content
    stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -15)
    ])
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return box
}

extension AppDelegate {
    func createSettings() {
        let window = settings ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 895), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let first = settings == nil
        settings = window; window.isReleasedWhenClosed = false
        window.title = "Orcaudio — \(L("設定"))"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor

        let icon = NSImageView(image: Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIcon.icns")) } ?? NSImage(contentsOf: root.appendingPathComponent("Assets/AppIcon.png")) ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = caption("Orcaudio", size: 28); name.font = .systemFont(ofSize: 28, weight: .semibold)
        let heading = NSStackView(views: [icon, vertical([name, caption(L("在 Orca 說話，讓想法成為文字。"), size: 13, secondary: true)], spacing: 4)])
        heading.spacing = 15; heading.alignment = .centerY
        heading.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let uiLanguage = NSPopUpButton(); uiLanguage.addItems(withTitles: ["English", "繁體中文"])
        uiLanguage.selectItem(at: usesTraditionalChinese ? 1 : 0)
        uiLanguage.target = self; uiLanguage.action = #selector(selectUILanguage)
        uiLanguage.widthAnchor.constraint(equalToConstant: 300).isActive = true
        uiLanguage.setAccessibilityLabel(L("介面語言"))
        let microphone = NSPopUpButton(); microphone.target = self; microphone.action = #selector(selectDevice)
        microphone.widthAnchor.constraint(equalToConstant: 300).isActive = true
        microphone.setAccessibilityLabel(L("麥克風")); microphonePopup = microphone
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("重新整理麥克風"))!, target: self, action: #selector(refreshDevices))
        refresh.bezelStyle = .roundRect; refresh.toolTip = L("重新整理麥克風")
        let field = ShortcutField(); field.isEditable = false; field.isSelectable = false; field.isBezeled = true
        field.stringValue = shortcut.label; field.alignment = .center; field.font = .systemFont(ofSize: 14, weight: .medium)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        field.toolTip = L("點擊欄位後按下新組合"); field.setAccessibilityLabel(L("快捷鍵"))
        field.onShortcut = { [weak self, weak field] value in
            guard let self else { return }
            if value.key == self.shortcut.key && value.modifiers == self.shortcut.modifiers && self.shortcutOK { field?.stringValue = self.shortcut.label; return }
            guard self.hotKey.register(value) else { field?.stringValue = L("快捷鍵被佔用，請換一組"); return }
            self.shortcut = value; value.save(); self.shortcutOK = true
            field?.stringValue = value.label; self.statusItem?.button?.toolTip = "Orcaudio · \(value.label)"
        }
        shortcutField = field
        let language = NSPopUpButton(); language.addItems(withTitles: [L("自動判定（廣東話＋英文）"), L("指定廣東話")])
        language.selectItem(at: UserDefaults.standard.string(forKey: "language") == "Cantonese" ? 1 : 0)
        language.target = self; language.action = #selector(selectLanguage)
        language.widthAnchor.constraint(equalToConstant: 300).isActive = true; language.setAccessibilityLabel(L("辨識語言"))
        let launch = NSButton(checkboxWithTitle: L("隨 Orca 啟動"), target: self, action: #selector(toggleAutoLaunch))
        launch.state = AutoLaunch.enabled ? .on : .off; launchCheckbox = launch
        let general = card(L("一般設定"), symbol: "slider.horizontal.3", views: [
            row(L("啟動"), [launch]), row(L("介面語言"), [uiLanguage]), row(L("麥克風"), [microphone, refresh]),
            row(L("快捷鍵"), [field]), row(L("辨識語言"), [language]),
            caption(L("介面語言不影響辨識或輸出語言。"), secondary: true)
        ])

        let modelName = caption("Qwen3-ASR 1.7B", size: 17); modelName.font = .systemFont(ofSize: 17, weight: .semibold)
        let quant = caption("MLX · 8-bit", secondary: true)
        let nameRow = NSStackView(views: [modelName, quant]); nameRow.spacing = 12
        let size = caption(modelSize(), size: 13); modelSizeLabel = size
        let status = caption("", size: 13, secondary: true); modelStatusLabel = status
        let stats = NSStackView(views: [caption(L("磁碟佔用"), secondary: true), size, caption("  ·  ", secondary: true), status]); stats.spacing = 8
        let path = caption(modelDirectory.path, size: 11, secondary: true)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular); path.isSelectable = true
        path.maximumNumberOfLines = 2; path.lineBreakMode = .byCharWrapping
        path.setAccessibilityLabel(L("存放位置"))
        let finder = NSButton(title: L("在 Finder 顯示"), target: self, action: #selector(revealModel))
        let copy = NSButton(title: L("複製路徑"), target: self, action: #selector(copyModelPath))
        finder.bezelStyle = .rounded; copy.bezelStyle = .rounded
        let actions = NSStackView(views: [finder, copy]); actions.spacing = 8
        let catalog = NSPopUpButton(); catalog.addItem(withTitle: "Qwen3-ASR 1.7B · 8-bit · ≈ 2.47 GB")
        catalog.setAccessibilityLabel(L("可下載模型"))
        let download = NSButton(title: L("下載模型"), target: self, action: #selector(startModelDownload)); download.bezelStyle = .rounded; downloadButton = download
        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancelModelDownload)); cancel.bezelStyle = .rounded; downloadCancelButton = cancel
        let downloads = NSStackView(views: [catalog, download, cancel]); downloads.spacing = 8
        let progress = NSProgressIndicator(); progress.style = .bar; progress.isIndeterminate = true; progress.minValue = 0; progress.maxValue = 1; downloadProgress = progress
        let downloadText = caption("", size: 11, secondary: true); downloadLabel = downloadText
        let gpu = caption("", size: 12, secondary: true); gpuMemoryLabel = gpu
        let memory = row(L("GPU 記憶體（MLX）"), [gpu])
        let memoryNote = caption(L("統一記憶體用量，非 GPU 運算百分比 · 每秒更新"), size: 11, secondary: true)
        let model = card(L("語音模型"), symbol: "waveform", views: [nameRow, stats, memory, memoryNote, path, actions, caption(L("可下載模型"), secondary: true), downloads, progress, downloadText])

        let micStatus = caption("", size: 12); microphoneStatus = micStatus
        let axStatus = caption("", size: 12); accessibilityStatus = axStatus
        micStatus.widthAnchor.constraint(equalToConstant: 300).isActive = true
        axStatus.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let micButton = NSButton(title: L("允許"), target: self, action: #selector(microphonePermission))
        let axButton = NSButton(title: L("允許"), target: self, action: #selector(accessibilitySettings))
        micButton.bezelStyle = .rounded; axButton.bezelStyle = .rounded
        micButton.setAccessibilityLabel(L("允許麥克風")); axButton.setAccessibilityLabel(L("開啟輔助使用設定"))
        microphoneAccessButton = micButton; accessibilityAccessButton = axButton
        let permissions = card(L("權限"), symbol: "lock.shield", views: [row(L("麥克風"), [micStatus, micButton]), row(L("輔助使用"), [axStatus, axButton])])
        let footer = vertical([caption("Orcaudio · " + L("版本") + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") + " · Apple Silicon", size: 11, secondary: true), caption(L("僅在這部 Mac 辨識，不傳送錄音。"), secondary: true), caption(L("停止後刪除錄音・閒置 10 分鐘釋放模型記憶體"), size: 11, secondary: true)], spacing: 4)
        let stack = vertical([heading, general, model, permissions, footer], spacing: 16)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.contentView = SettingsClipView()
        window.contentView = scroll
        let content = SettingsDocumentView(); content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in [general, model, permissions, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshDevices(); refreshPermissions(); refreshDownload()
        if first {
            let height = min(895, (NSScreen.main?.visibleFrame.height ?? 950) - 65)
            window.setContentSize(NSSize(width: 700, height: height)); window.center()
        }
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
    }

    @objc func selectUILanguage(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "zh-Hant" : "en", forKey: "uiLanguage")
        createSettings()
        stopButton.title = L("停止"); copyButton.title = L("複製")
        panelCancelButton?.title = L("取消"); panelDismissButton?.title = L("收起")
        if phase == .idle { hidePanel(); stateText = L("準備就緒"); statusLabel.stringValue = stateText }
        rebuildMenu()
    }

    @objc func toggleAutoLaunch(_ sender: NSButton) {
        do { try AutoLaunch.setEnabled(sender.state == .on) }
        catch { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
        sender.state = AutoLaunch.enabled ? .on : .off
    }
    @objc func startModelDownload() {
        guard phase == .idle && !modelAvailable && !downloader.active else { return }
        worker.shutdown(); downloadError = nil
        do { try downloader.start(root: root) }
        catch { downloadError = error.localizedDescription; refreshDownload() }
    }
    @objc func cancelModelDownload() { downloader.cancel(); downloadError = nil; refreshDownload() }
    func refreshDownload() {
        downloadButton?.title = modelAvailable ? L("已下載") : L("下載模型")
        downloadButton?.isEnabled = !modelAvailable && !downloader.active && phase == .idle
        downloadCancelButton?.isHidden = !downloader.active
        downloadProgress?.isHidden = !downloader.active
        downloadProgress?.isIndeterminate = downloader.total == 0
        downloadProgress?.doubleValue = downloader.fraction
        if downloader.active {
            downloadProgress?.startAnimation(nil)
            downloadLabel?.stringValue = downloader.total == 0 ? L("正在連接下載服務…") : String(format: L("下載中 %.2f / %.2f GB"), Double(downloader.received) / 1e9, Double(downloader.total) / 1e9)
        } else {
            downloadProgress?.stopAnimation(nil)
            downloadLabel?.stringValue = downloadError == nil ? L("手動下載 · 取消後可續傳 · 不自動重新下載") : L("下載失敗，請檢查網絡後重試。")
            downloadLabel?.toolTip = downloadError
        }
    }

    @objc func revealModel() {
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: modelDirectory.path) ? modelDirectory : root.appendingPathComponent("models")])
    }

    @objc func copyModelPath(_ sender: NSButton) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(modelDirectory.path, forType: .string)
        sender.title = L("已複製路徑")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak sender] in sender?.title = L("複製路徑") }
    }
}
