import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import RecorderCore

/// Menu bar app. The whole loop runs from one key combination: press, show the problem, press again, paste into T3.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, recording, working }

    private var state = State.idle {
        didSet {
            DispatchQueue.main.async {
                self.refreshIcon()
                self.updates.installIfIdle()
            }
        }
    }
    private var config = Config.load()
    private let keys = HotKeys()
    private let toast = Toast()
    private let watcher = ClickWatcher()
    private var statusItem: NSStatusItem!
    private var screenRecorder: ScreenRecorder?
    private var mic: MicRecorder?
    private var overlayPanel: OverlayPanel?
    private var overlayView: OverlayView?
    private var toolBar: ToolBar?
    private var ticker: Timer?
    private var appObserver: NSObjectProtocol?

    private var dir: URL!
    private var clipID = ""
    private var videoName = ""
    private var audioName: String?
    private var events: [Event] = []
    private var displayBounds = CGRect.zero
    private var screenInfo = ScreenInfo(name: "", width: 0, height: 0)
    private var appendingTo: EditorController?
    private var editor: EditorController?
    private var keyCatcher: Any?
    private var markStartedAt = 0.0
    private let updates = Updates()

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: Config.support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Config.recordings, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        registerHotKey()
        watcher.onAction = { [weak self] in self?.clickAction($0) }
        updates.isBusy = { [weak self] in
            guard let self else { return false }
            return self.state != .idle || self.editor?.window?.isVisible == true
        }
        updates.start()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        Log.info("started, shortcut \(shortcutName)")
    }

    private var shortcutName: String { HotKeys.describe(keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers) }

    private var markShortcutName: String { HotKeys.describe(keyCode: config.markHotKeyCode, modifiers: config.markHotKeyModifiers) }

    private func registerHotKey() {
        keys.set(id: 1, keyCode: config.hotKeyCode, modifiers: config.hotKeyModifiers) { [weak self] in self?.toggle() }
    }

    private func refreshIcon() {
        let symbol = state == .recording ? "record.circle.fill" : (state == .working ? "hourglass" : "record.circle")
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "T3 Recorder")
        statusItem?.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, state == .recording ? "Stop recording (\(shortcutName))" : "Start recording (\(shortcutName))", #selector(toggleFromMenu))
        let recent = NSMenu()
        for url in recentRecordings().prefix(8) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            recent.addItem(item)
        }
        let recentItem = NSMenuItem(title: "Edit a recording", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recentItem.isEnabled = recent.numberOfItems > 0
        menu.addItem(recentItem)
        menu.addItem(.separator())
        add(menu, "Change start shortcut (\(shortcutName))…", #selector(changeStartShortcut))
        add(menu, "Change mark mode shortcut (\(markShortcutName))…", #selector(changeMarkShortcut))
        if !AXIsProcessTrusted() { add(menu, "Allow marking clicks (Accessibility)…", #selector(openAccessibility)) }
        add(menu, "Show recordings folder", #selector(showFolder))
        menu.addItem(.separator())
        if updates.isAvailable { add(menu, "Check for updates (\(Updates.version))", #selector(checkForUpdates)) }
        add(menu, "Quit T3 Recorder", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func recentRecordings() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: Config.recordings, includingPropertiesForKeys: nil)) ?? []
        return all.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func checkForUpdates() { updates.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showFolder() { NSWorkspace.shared.open(Config.recordings) }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openEditor(url) }
    }
    @objc private func changeStartShortcut() { catchShortcut { $0.hotKeyCode = $1; $0.hotKeyModifiers = $2 } }
    @objc private func changeMarkShortcut() { catchShortcut { $0.markHotKeyCode = $1; $0.markHotKeyModifiers = $2 } }

    private func catchShortcut(_ store: @escaping (inout Config, UInt32, UInt32) -> Void) {
        toast.show("Press the new shortcut now. Esc cancels.")
        keys.remove(id: 1)
        NSApp.activate(ignoringOtherApps: true)
        keyCatcher = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let mods = HotKeys.carbonModifiers(e.modifierFlags)
            if e.keyCode == 53 || mods != 0 {
                if e.keyCode != 53 {
                    store(&self.config, UInt32(e.keyCode), mods)
                    self.config.save()
                }
                if let c = self.keyCatcher { NSEvent.removeMonitor(c) }
                self.keyCatcher = nil
                self.registerHotKey()
                self.toast.show(e.keyCode == 53 ? "Nothing changed." : "Saved.", seconds: 3)
                return nil
            }
            return e
        }
    }

    private func toggle() {
        switch state {
        case .idle: Task { @MainActor in await self.start() }
        case .recording: Task { @MainActor in await self.stop() }
        case .working: toast.show("Still finishing the last recording.", seconds: 2)
        }
    }

    func recordSection(for editor: EditorController) {
        appendingTo = editor
        editor.window?.orderOut(nil)
        Task { @MainActor in await self.start() }
    }

    @MainActor private func start() async {
        guard state == .idle else { return }
        state = .working
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            toast.show("Allow T3 Recorder under Screen Recording in System Settings, then press the shortcut again.", seconds: 10)
            state = .idle
            appendingTo = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { state = .idle; return }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        displayBounds = CGDisplayBounds(displayID)

        if let appendingTo {
            dir = appendingTo.dir
        } else {
            let id = Project.makeID(Date())
            dir = Config.recordings.appendingPathComponent(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let existing = (try? ProjectStore.load(dir))?.clips.count ?? 0
        clipID = "clip-\(existing + 1)"
        videoName = clipID + ".mov"
        events = []

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let panel = OverlayPanel(screen: screen, view: view)
        let bar = ToolBar(screen: screen)
        overlayView = view
        overlayPanel = panel
        toolBar = bar
        view.now = { [weak self] in self?.now ?? 0 }
        view.onDrawn = { [weak self] d, began in self?.logDrawing(d, began: began) }
        view.onUndo = { [weak self] in
            if let i = self?.events.lastIndex(where: { $0.kind == .draw }) { self?.events.remove(at: i) }
        }
        view.onToolChanged = { [weak self, weak bar] tool in
            bar?.select(tool)
            if tool != nil { self?.setMarkMode(false) }
        }
        bar.onMark = { [weak self] in self?.toggleMarkMode() }
        bar.onTool = { [weak view] in view?.tool = $0 }
        bar.onUndo = { [weak view] in view?.undo() }
        bar.onClear = { [weak view] in view?.clear() }
        bar.onStop = { [weak self] in self?.toggle() }
        panel.orderFrontRegardless()
        bar.panel.orderFrontRegardless()

        let recorder = ScreenRecorder()
        screenRecorder = recorder
        recorder.onFailure = { [weak self] error in
            DispatchQueue.main.async { self?.toast.show("Recording stopped: \(error.localizedDescription)", seconds: 8) }
        }
        let micFile = "\(clipID).m4a"
        let microphone = MicRecorder()
        let haveMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && microphone.start(to: dir.appendingPathComponent(micFile))
        mic = haveMic ? microphone : nil
        audioName = haveMic ? micFile : nil

        do {
            let size = try await recorder.start(displayID: displayID, excluding: [CGWindowID(bar.panel.windowNumber)], to: dir.appendingPathComponent(videoName))
            screenInfo = ScreenInfo(name: screen.localizedName.isEmpty ? "Screen" : screen.localizedName, width: size.width, height: size.height)
        } catch {
            Log.info("start failed: \(error)")
            tearDownCapture()
            state = .idle
            appendingTo = nil
            toast.show("Could not start recording: \(error.localizedDescription)", seconds: 8)
            return
        }

        watcher.keepsClicks = { [weak self] p in self?.barContains(p) ?? false }
        watcher.start()
        if let front = NSWorkspace.shared.frontmostApplication { log(.app, app: front.localizedName) }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.log(.app, app: app?.localizedName) }
        }
        keys.set(id: 2, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)) { [weak view] in
            guard let view else { return }
            view.tool = view.tool == nil ? .pen : nil
        }
        keys.set(id: 3, keyCode: config.markHotKeyCode, modifiers: config.markHotKeyModifiers) { [weak self] in self?.toggleMarkMode() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.toolBar?.setTime(self?.now ?? 0) }
        state = .recording
        if !haveMic { toast.show("Recording without your voice: allow T3 Recorder under Microphone in System Settings.", seconds: 8) }
        Log.info("recording \(dir.lastPathComponent) \(clipID) on \(screenInfo.name)")
    }

    private func toggleMarkMode() { setMarkMode(!watcher.markMode) }

    private func setMarkMode(_ on: Bool) {
        if on, !watcher.canTakeClicks {
            toast.show("Mark mode needs Accessibility: allow T3 Recorder in System Settings, then start a new recording.", seconds: 8)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        if on { overlayView?.tool = nil }
        watcher.markMode = on
        overlayView?.markMode = on
        toolBar?.showMarkMode(on)
    }

    private var now: Double { max(0, CACurrentMediaTime() - (screenRecorder?.startTime ?? CACurrentMediaTime())) }

    private func log(_ kind: TimelineKind, app: String? = nil, window: String? = nil, rect: NormRect? = nil, t: Double? = nil, end: Double? = nil, shape: MarkShape? = nil, text: String? = nil) {
        events.append(Event(clipID: clipID, t: t ?? now, end: end, kind: kind, text: text, shape: shape, rect: rect, app: app, window: window))
    }

    private func normalized(_ p: CGPoint) -> NormRect? {
        guard displayBounds.contains(p) else { return nil }
        return NormRect(x: (p.x - displayBounds.minX) / displayBounds.width, y: (p.y - displayBounds.minY) / displayBounds.height, w: 0, h: 0)
    }

    private func clickAction(_ action: ClickWatcher.Action) {
        guard state == .recording, let view = overlayView else { return }
        let local: (CGPoint) -> CGPoint = { [displayBounds] p in CGPoint(x: p.x - displayBounds.minX, y: p.y - displayBounds.minY) }
        switch action {
        case .click(let p):
            guard view.tool == nil, let rect = normalized(p), !barContains(p) else { return }
            let under = WindowLookup.at(p)
            log(.click, app: under?.app, window: under?.window, rect: rect)
        case .markBegan(let p):
            markStartedAt = now
            view.markBegan(at: local(p))
        case .markMoved(let p): view.markMoved(to: local(p))
        case .markEnded(let p):
            guard let (r, dragged) = view.markEnded(at: local(p)) else { return }
            let rect = NormRect(x: r.minX / displayBounds.width, y: r.minY / displayBounds.height, w: r.width / displayBounds.width, h: r.height / displayBounds.height)
            let under = WindowLookup.at(p)
            log(.draw, app: under?.app, window: under?.window, rect: rect, t: markStartedAt, end: now, shape: dragged ? .rectangle : .mark)
        }
    }

    private func barContains(_ cgPoint: CGPoint) -> Bool {
        guard let frame = toolBar?.panel.frame else { return false }
        return frame.contains(CGPoint(x: cgPoint.x, y: NSScreen.screens[0].frame.height - cgPoint.y))
    }

    private func logDrawing(_ d: OverlayView.Drawn, began: Double) {
        let xs = d.points.map(\.x), ys = d.points.map(\.y)
        let lo = CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0), hi = CGPoint(x: xs.max() ?? 0, y: ys.max() ?? 0)
        let rect = NormRect(x: lo.x / displayBounds.width, y: lo.y / displayBounds.height, w: (hi.x - lo.x) / displayBounds.width, h: (hi.y - lo.y) / displayBounds.height)
        log(.draw, rect: rect, t: began, end: now, shape: d.shape, text: d.text)
    }

    private func tearDownCapture() {
        mic?.stop()
        mic = nil
        ticker?.invalidate()
        ticker = nil
        watcher.stop()
        keys.remove(id: 2)
        keys.remove(id: 3)
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        overlayPanel?.close()
        toolBar?.panel.close()
        overlayPanel = nil
        overlayView = nil
        toolBar = nil
    }

    @MainActor private func stop() async {
        guard state == .recording, let recorder = screenRecorder else { return }
        state = .working
        let videoStart = recorder.startTime
        let audioStart = mic?.startTime ?? videoStart
        tearDownCapture()
        await recorder.stop()
        screenRecorder = nil
        let target = appendingTo
        appendingTo = nil
        let dir = self.dir!
        do {
            toast.show("Finishing…")
            var project = (try? ProjectStore.load(dir)) ?? Project(id: dir.lastPathComponent, createdAt: Date())
            let duration = try await AVURLAsset(url: dir.appendingPathComponent(videoName)).load(.duration).seconds
            let clip = Clip(id: clipID, videoFile: videoName, audioFile: audioName, duration: duration, audioOffset: audioStart - videoStart, screen: screenInfo)
            project.append(clip, events: events + (await spoken(clip, in: dir)))
            try ProjectStore.save(project, to: dir)
            if let target {
                await target.reload()
                state = .idle
                toast.show("Section added.", seconds: 3)
                return
            }
            let stored = project
            try await deliver(stored, in: dir)
        } catch {
            Log.info("finish failed: \(error)")
            toast.show("Saved, but it could not be finished: \(error.localizedDescription)", seconds: 10)
            state = .idle
        }
    }

    /// Voice is optional: a failed transcript must never cost Isaac the recording.
    @MainActor private func spoken(_ clip: Clip, in dir: URL) async -> [Event] {
        guard let audio = clip.audioFile else { return [] }
        do {
            let toast = self.toast
            let words = try await Parakeet.shared.words(in: dir.appendingPathComponent(audio)) { message in
                DispatchQueue.main.async { toast.show(message) }
            }
            return Transcript.lines(words).map {
                Event(clipID: clip.id, t: $0.start + clip.audioOffset, end: $0.end + clip.audioOffset, kind: .said, text: $0.text)
            }
        } catch {
            Log.info("transcript failed: \(error)")
            return [Event(clipID: clip.id, t: 0, kind: .note, text: "Transcription failed; listen to the audio in the video.")]
        }
    }

    /// Render, clipboard. Also what the editor's Copy buttons run.
    @MainActor func deliver(_ project: Project, in dir: URL, withVideo: Bool = false) async throws {
        state = .working
        let toast = self.toast
        let result = try await Exporter.run(project, in: dir, includeVideo: withVideo) { message in
            DispatchQueue.main.async { toast.show(message) }
        }
        Exporter.copyToClipboard(result.files)
        state = .idle
        let edit = Toast.Action(title: "Edit") { [weak self] in self?.openEditor(dir) }
        switch result.video {
        case .leftOut:
            let addVideo = Toast.Action(title: "Add video") { [weak self] in self?.copyAgain(project, in: dir, withVideo: true) }
            toast.show("Copied. Paste it into T3.", buttons: [addVideo, edit], seconds: 12)
        case .attached: toast.show("Copied with the video. Paste it into T3.", buttons: [edit], seconds: 12)
        case .tooBig: toast.show("Copied, without the video: it is over 50 MB.", buttons: [edit], seconds: 12)
        }
        Log.info("delivered \(project.id), \(result.files.count) files")
    }

    func copyAgain(_ project: Project, in dir: URL, withVideo: Bool) {
        guard state == .idle else { return toast.show("Still finishing the last recording.", seconds: 2) }
        Task { @MainActor in
            do {
                try await self.deliver(project, in: dir, withVideo: withVideo)
            } catch {
                Log.info("copy failed: \(error)")
                self.toast.show("Could not copy it: \(error.localizedDescription)", seconds: 8)
                self.state = .idle
            }
        }
    }

    /// The whole loop without hands, for checking a build: real capture, overlay, export and editor; only the mouse is simulated.
    @MainActor func selfTest(screenshot: String) async {
        toast.hiddenFromCapture = false
        await start()
        guard state == .recording else { print("self test: did not start"); exit(1) }
        toolBar?.setTime(1)
        try? await Task.sleep(for: .seconds(1))
        overlayView?.markMode = true
        let c = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        clickAction(.markBegan(c))
        clickAction(.markEnded(c))
        try? await Task.sleep(for: .seconds(1.5))
        let a = CGPoint(x: displayBounds.minX + 200, y: displayBounds.minY + 200), b = CGPoint(x: a.x + 400, y: a.y + 250)
        clickAction(.markBegan(a))
        clickAction(.markMoved(b))
        clickAction(.markEnded(b))
        try? await Task.sleep(for: .seconds(0.3))
        shoot(overlayPanel?.windowNumber, to: screenshot + "-overlay.png")
        shoot(toolBar?.panel.windowNumber, to: screenshot + "-bar.png")
        try? await Task.sleep(for: .seconds(1))
        overlayView?.markMode = false
        clickAction(.click(CGPoint(x: displayBounds.minX + 100, y: displayBounds.maxY - 100)))
        try? await Task.sleep(for: .seconds(1))
        let folder = dir!
        await stop()
        shoot(toast.windowNumber, to: screenshot + "-toast.png")
        print("self test: \(folder.lastPathComponent)\n" + ((try? String(contentsOf: folder.appendingPathComponent("out/report.txt"), encoding: .utf8)) ?? "no report"))
        openEditor(folder)
        try? await Task.sleep(for: .seconds(2.5))
        shoot(editor?.window?.windowNumber, to: screenshot)
        exit(0)
    }

    private func shoot(_ window: Int?, to file: String) {
        guard let window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-o", "-l\(window)", file]
        try? p.run()
        p.waitUntilExit()
    }

    func openEditor(_ dir: URL) {
        do {
            let e = try EditorController(dir: dir, app: self)
            editor = e
            e.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            toast.show("Could not open it: \(error.localizedDescription)", seconds: 6)
        }
    }
}
