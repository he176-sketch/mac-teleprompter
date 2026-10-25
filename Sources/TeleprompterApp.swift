import AppKit
import AVFoundation
import Speech

final class SpeechEngine: NSObject {
    var onTranscript: ((String, String) -> Void)?
    var onStatus: ((String) -> Void)?
    var contextualStrings: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskID = UUID().uuidString
    private var wantsRunning = false

    var isRunning: Bool { audioEngine.isRunning }

    func start() {
        wantsRunning = true
        guard !audioEngine.isRunning else { return }
        guard let recognizer else {
            onStatus?("中文语音识别不可用")
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.wantsRunning else { return }
                guard status == .authorized else {
                    self.onStatus?("需要允许麦克风和语音识别权限")
                    return
                }
                guard recognizer.isAvailable else {
                    self.onStatus?("语音识别服务暂不可用")
                    return
                }
                self.beginRecognition(with: recognizer)
            }
        }
    }

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        clearEngine(cancelTask: true)
        taskID = UUID().uuidString
        let recognitionTaskID = taskID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        // Keep the same on-device path as the phone implementation when the
        // Chinese model is available. It avoids sending the microphone stream
        // away from the Mac and has lower latency for this workflow.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            onStatus?("正在听（本地识别）")
        } else {
            onStatus?("正在听（系统语音识别）")
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.taskID == recognitionTaskID else { return }
            if let result {
                self.onTranscript?(result.bestTranscription.formattedString, recognitionTaskID)
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.taskID == recognitionTaskID else { return }
                    self.clearEngine(cancelTask: false)
                    if self.wantsRunning {
                        self.onStatus?("等待下一段语音…")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            guard let self, self.wantsRunning else { return }
                            self.start()
                        }
                    } else {
                        self.onStatus?("识别停止：\(error.localizedDescription)")
                    }
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onStatus?("麦克风启动失败：\(error.localizedDescription)")
            stop(cancelTask: true)
        }
    }

    func stop(cancelTask: Bool = true) {
        wantsRunning = false
        clearEngine(cancelTask: cancelTask)
    }

    private func clearEngine(cancelTask: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if cancelTask {
            taskID = UUID().uuidString
            task?.cancel()
        }
        task = nil
        request = nil
    }
}

final class TeleprompterWindowController: NSWindowController, NSTextViewDelegate {
    private let speech = SpeechEngine()
    private let rootView = NSView()
    private let scriptView = NSTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "准备就绪")
    private let startButton = NSButton(title: "开始跟读", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.82, minValue: 0.25, maxValue: 1.0, target: nil, action: nil)
    private let fontSlider = NSSlider(value: 30, minValue: 18, maxValue: 64, target: nil, action: nil)
    private let fontLabel = NSTextField(labelWithString: "30")
    private let clickThroughButton = NSButton(title: "穿透", target: nil, action: nil)
    private var follower: ScriptFollower
    private var currentLine = 0
    private var currentMatchRange: NSRange?
    private var clickThrough = false
    private var lastTranscript = ""
    private var pendingLine: Int?
    private var pendingHits = 0

    private let sampleScript = """
    大家好，今天我们来演示一个真正能在电脑上使用的提词器。
    它可以覆盖在浏览器、演示文稿和剪辑软件上面，同时保持窗口透明、置顶和可调节。
    朗读时，提词器会根据识别到的内容寻找稿件位置，并自动滚动到当前句子。
    如果识别暂时不稳定，也可以用按钮暂停，或者使用手动滚动继续录制。
    """

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 820, height: 390)
        let frame = NSRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 480, height: 220)
        panel.alphaValue = 0.82
        follower = ScriptFollower(script: sampleScript)
        super.init(window: panel)

        speech.onTranscript = { [weak self] transcript, taskID in
            DispatchQueue.main.async { self?.handleTranscript(transcript, taskID: taskID) }
        }
        speech.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setStatus(status)
                if status.hasPrefix("识别停止") || status.contains("启动失败") || status.contains("权限") {
                    self.startButton.title = "开始跟读"
                }
            }
        }
        buildInterface()
        scriptView.string = sampleScript
        updateScriptLayout()
        applyHighlight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        window?.orderFrontRegardless()
    }

    func toggleSpeech() {
        if speech.isRunning {
            speech.stop()
            startButton.title = "开始跟读"
            setStatus("已暂停跟读")
        } else {
            // Keep the follower cursor when speech is paused and resumed.
            // A fresh script or a first start already resets these values in
            // the document-change path below.
            if lastTranscript.isEmpty && currentMatchRange == nil {
                currentLine = 0
                follower = ScriptFollower(script: scriptView.string)
            }
            speech.contextualStrings = scriptLines
            speech.start()
            startButton.title = "停止跟读"
            setStatus("等待语音…")
        }
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        window?.ignoresMouseEvents = clickThrough
        clickThroughButton.state = clickThrough ? .on : .off
        setStatus(clickThrough ? "穿透中 · Esc 恢复" : "已关闭鼠标穿透")
    }

    @discardableResult
    func disableClickThroughIfNeeded() -> Bool {
        guard clickThrough else { return false }
        toggleClickThrough()
        return true
    }

    private func buildInterface() {
        guard let window else { return }
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 14
        rootView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        rootView.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        rootView.layer?.borderWidth = 1
        window.contentView = rootView

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(toolbar)

        let title = NSTextField(labelWithString: "电脑提词器")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(title)

        startButton.target = self
        startButton.action = #selector(toggleSpeechAction)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        startButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(startButton)

        let loadButton = NSButton(title: "打开稿件", target: self, action: #selector(openScript))
        loadButton.bezelStyle = .rounded
        loadButton.controlSize = .small
        loadButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(loadButton)

        clickThroughButton.target = self
        clickThroughButton.action = #selector(toggleClickThroughAction)
        clickThroughButton.setButtonType(.toggle)
        clickThroughButton.bezelStyle = .rounded
        clickThroughButton.controlSize = .small
        clickThroughButton.toolTip = "开启后按 Esc 恢复；也可以点击菜单栏“提”关闭穿透或退出。"
        clickThroughButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(clickThroughButton)

        let opacityLabel = NSTextField(labelWithString: "透明")
        opacityLabel.textColor = .white.withAlphaComponent(0.8)
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(opacityLabel)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.controlSize = .small
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(opacitySlider)

        let fontLabelTitle = NSTextField(labelWithString: "字号")
        fontLabelTitle.textColor = .white.withAlphaComponent(0.8)
        fontLabelTitle.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(fontLabelTitle)
        fontSlider.target = self
        fontSlider.action = #selector(fontChanged)
        fontSlider.controlSize = .small
        fontSlider.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(fontSlider)
        fontLabel.textColor = .white.withAlphaComponent(0.8)
        fontLabel.alignment = .right
        fontLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(fontLabel)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .white.withAlphaComponent(0.75)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(statusLabel)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(scrollView)

        scriptView.isEditable = true
        scriptView.isRichText = false
        scriptView.allowsUndo = true
        scriptView.drawsBackground = false
        scriptView.textColor = .white
        scriptView.font = .systemFont(ofSize: 30, weight: .medium)
        scriptView.insertionPointColor = .white
        scriptView.textContainerInset = NSSize(width: 20, height: 16)
        scriptView.delegate = self
        scriptView.isVerticallyResizable = true
        scriptView.isHorizontallyResizable = false
        scriptView.autoresizingMask = [.width]
        scriptView.textContainer?.widthTracksTextView = true
        scrollView.documentView = scriptView

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            title.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            title.widthAnchor.constraint(equalToConstant: 100),
            title.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            startButton.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 16),
            startButton.widthAnchor.constraint(equalToConstant: 80),
            startButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            loadButton.leadingAnchor.constraint(equalTo: startButton.trailingAnchor, constant: 6),
            loadButton.widthAnchor.constraint(equalToConstant: 64),
            loadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            clickThroughButton.leadingAnchor.constraint(equalTo: loadButton.trailingAnchor, constant: 6),
            clickThroughButton.widthAnchor.constraint(equalToConstant: 44),
            clickThroughButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            opacityLabel.leadingAnchor.constraint(equalTo: clickThroughButton.trailingAnchor, constant: 16),
            opacityLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            opacitySlider.leadingAnchor.constraint(equalTo: opacityLabel.trailingAnchor, constant: 4),
            opacitySlider.widthAnchor.constraint(equalToConstant: 50),
            opacitySlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            fontLabelTitle.leadingAnchor.constraint(equalTo: opacitySlider.trailingAnchor, constant: 10),
            fontLabelTitle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            fontSlider.leadingAnchor.constraint(equalTo: fontLabelTitle.trailingAnchor, constant: 4),
            fontSlider.widthAnchor.constraint(equalToConstant: 50),
            fontSlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            fontLabel.leadingAnchor.constraint(equalTo: fontSlider.trailingAnchor, constant: 4),
            fontLabel.widthAnchor.constraint(equalToConstant: 24),
            fontLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: fontLabel.trailingAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(equalToConstant: 120),
            statusLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
    }

    private func updateScriptLayout() {
        guard let layoutManager = scriptView.layoutManager,
              let textContainer = scriptView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let visibleHeight = max(1, scrollView.contentView.bounds.height)
        let visibleWidth = max(1, scrollView.contentView.bounds.width)
        let requiredHeight = ceil(usedRect.maxY + scriptView.textContainerInset.height)
        var frame = scriptView.frame
        frame.size.width = visibleWidth
        frame.size.height = max(visibleHeight, requiredHeight)
        scriptView.setFrameSize(frame.size)
        scrollView.hasVerticalScroller = requiredHeight > visibleHeight + 1
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func toggleSpeechAction() { toggleSpeech() }
    @objc private func toggleClickThroughAction() { toggleClickThrough() }

    @objc private func opacityChanged() {
        window?.alphaValue = CGFloat(opacitySlider.doubleValue)
    }

    @objc private func fontChanged() {
        let size = CGFloat(fontSlider.doubleValue)
        fontLabel.stringValue = String(Int(size))
        scriptView.font = .systemFont(ofSize: size, weight: .medium)
        updateScriptLayout()
        applyHighlight()
    }

    @objc private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self?.scriptView.string = text
            self?.currentLine = 0
            self?.lastTranscript = ""
            self?.pendingLine = nil
            self?.pendingHits = 0
            self?.currentMatchRange = nil
            self?.follower = ScriptFollower(script: text)
            self?.updateScriptLayout()
            self?.applyHighlight()
            self?.setStatus("已载入：\(url.lastPathComponent)")
        }
    }

    func textDidChange(_ notification: Notification) {
        currentLine = 0
        lastTranscript = ""
        pendingLine = nil
        pendingHits = 0
        currentMatchRange = nil
        follower = ScriptFollower(script: scriptView.string)
        updateScriptLayout()
        applyHighlight()
    }

    private func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    private func handleTranscript(_ transcript: String, taskID: String) {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { return }
        guard let update = follower.update(transcript: cleanedTranscript, taskID: taskID) else {
            let preview = String(cleanedTranscript.suffix(12))
            setStatus("识别到：\(preview)")
            return
        }

        lastTranscript = cleanedTranscript
        currentMatchRange = update.matchedUTF16Range
        currentLine = lineIndex(containingUTF16Offset: update.utf16Offset)
        applyHighlight()
        setStatus("跟读：第 \(currentLine + 1) 句 · \(update.kind == "advance" ? "继续" : "已定位")")
    }

    private var scriptLines: [String] {
        scriptView.string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func lineIndex(containingUTF16Offset offset: Int) -> Int {
        let text = scriptView.string as NSString
        let clamped = min(max(0, offset), text.length)
        var lineIndex = 0
        var cursor = 0
        for line in text.components(separatedBy: .newlines) {
            let length = (line as NSString).length
            if clamped <= cursor + length { return lineIndex }
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lineIndex += 1 }
            cursor += length + 1
        }
        return max(0, lineIndex - 1)
    }

    private func applyHighlight() {
        let text = scriptView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard let storage = scriptView.textStorage else { return }
        storage.beginEditing()
        storage.setAttributes([
            .foregroundColor: NSColor.white,
            .font: scriptView.font ?? NSFont.systemFont(ofSize: 30, weight: .medium)
        ], range: fullRange)

        let lines = text.components(separatedBy: .newlines)
        var location = 0
        var nonEmptyIndex = 0
        for line in lines {
            let length = (line as NSString).length
            if length > 0 {
                let range = NSRange(location: location, length: length)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   currentMatchRange == nil, nonEmptyIndex == currentLine {
                    storage.addAttributes([
                        .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.82),
                        .foregroundColor: NSColor.black
                    ], range: range)
                }
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nonEmptyIndex += 1
                }
            }
            location += length + 1
        }
        storage.endEditing()
        updateScriptLayout()

        // The phone follower returns a sentence range, so a long paragraph
        // can visibly advance even when it contains no line breaks.
        if let matchRange = currentMatchRange,
           matchRange.location >= 0,
           NSMaxRange(matchRange) <= fullRange.length {
            storage.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.82),
                .foregroundColor: NSColor.black
            ], range: matchRange)
        }

        if let matchRange = currentMatchRange,
           matchRange.location >= 0,
           NSMaxRange(matchRange) <= fullRange.length {
            scrollToMatch(matchRange)
        } else if currentLine < scriptLines.count {
            var ordinal = 0
            var before = 0
            var currentLength = 1
            var previousBefore: Int?
            for line in lines {
                let lineLength = (line as NSString).length
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if ordinal == currentLine {
                        currentLength = max(1, lineLength)
                        break
                    }
                    previousBefore = before
                    ordinal += 1
                }
                before += lineLength + 1
            }
            // Keep the previous line in the viewport while bringing the new
            // line into view. Scrolling only the current line can make AppKit
            // advance by a full page and hide text the user is still using.
            let visibleStart = previousBefore ?? before
            let visibleEnd = before + currentLength
            scrollToMatch(NSRange(location: visibleStart, length: max(1, visibleEnd - visibleStart)))
        }
    }

    private func scrollToMatch(_ range: NSRange) {
        guard let layoutManager = scriptView.layoutManager,
              let textContainer = scriptView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }

        var matchRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let textOrigin = scriptView.textContainerOrigin
        matchRect.origin.x += textOrigin.x
        matchRect.origin.y += textOrigin.y

        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        let documentHeight = max(visibleHeight, scriptView.bounds.height)
        let maximumY = max(0, documentHeight - visibleHeight)
        // Put the active sentence around 38% from the top, leaving the
        // preceding sentence visible above it instead of jumping a whole page.
        let targetY = min(maximumY, max(0, matchRect.midY - visibleHeight * 0.38))
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: TeleprompterWindowController!
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = TeleprompterWindowController()
        controller.showWindow(nil)
        setupStatusItem()
        setupKeyboardShortcuts()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "提"
        statusItem.button?.toolTip = "电脑提词器：恢复鼠标操作或退出"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示提词器", action: #selector(showPrompt), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "开始/停止跟读", action: #selector(toggleSpeech), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "关闭鼠标穿透（Esc）", action: #selector(disableClickThrough), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func setupKeyboardShortcuts() {
        let recoverOrToggle: (NSEvent) -> Bool = { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                return self?.controller.disableClickThroughIfNeeded() ?? false
            }
            if flags == [.command, .shift] && event.keyCode == 17 { // Command-Shift-T
                if !event.isARepeat { self?.controller.toggleClickThrough() }
                return true
            }
            return false
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if recoverOrToggle(event) { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Only the teleprompter's own events may quit it. Never react to
            // Command-Q sent to the application underneath the overlay.
            if flags.contains(.command) && event.keyCode == 12 { // Command-Q
                self?.quit()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Background shortcuts only recover the overlay. Do not enable
            // click-through when Command-Shift-T is used in a browser.
            if event.keyCode == 53 { self?.controller.disableClickThroughIfNeeded() }
        }
    }

    @objc private func showPrompt() {
        controller.disableClickThroughIfNeeded()
        controller.showWindow(nil)
    }
    @objc private func toggleSpeech() { controller.toggleSpeech() }
    @objc private func disableClickThrough() { controller.disableClickThroughIfNeeded() }
    @objc private func quit() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        controller.window?.close()
        NSApp.terminate(nil)
    }
}

@main
struct TeleprompterMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
