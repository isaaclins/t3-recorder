import AppKit
import RecorderCore

/// Transparent sheet over the recorded screen. Everything on it lands in the video.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(screen: NSScreen, view: NSView) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: false)
    }
}

final class OverlayView: NSView {
    struct Drawn { var shape: MarkShape; var points: [CGPoint]; var text: String? }

    private static let red = NSColor(calibratedRed: 1, green: 0.17, blue: 0.2, alpha: 1)
    private var drawn: [Drawn] = []
    private var current: Drawn?
    private var field: NSTextField?
    private var markLayer: CAShapeLayer?
    private var markStart: CGPoint?
    var tool: MarkShape? { didSet { toolChanged() } }
    var onDrawn: ((Drawn, Double) -> Void)?
    var onUndo: (() -> Void)?
    var onToolChanged: ((MarkShape?) -> Void)?
    private var startedAt = 0.0
    var now: () -> Double = { 0 }
    /// Yellow rim while mark mode is on, so it is obvious the mouse is not doing its usual job. It shows in the video too.
    var markMode = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private func toolChanged() {
        window?.ignoresMouseEvents = tool == nil
        if tool != nil { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(self) } else { commitText() }
        onToolChanged?(tool)
    }

    override func resetCursorRects() { if tool != nil { addCursorRect(bounds, cursor: .crosshair) } }

    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "p": tool = .pen
        case "r": tool = .rectangle
        case "o": tool = .circle
        case "a": tool = .arrow
        case "t": tool = .text
        case "z": undo()
        case "c": clear()
        default:
            if e.keyCode == 53 { tool = nil } else { super.keyDown(with: e) }
        }
    }

    func undo() {
        guard drawn.popLast() != nil else { return }
        onUndo?()
        needsDisplay = true
    }

    func clear() {
        drawn = []
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard let tool else { return }
        let p = convert(e.locationInWindow, from: nil)
        startedAt = now()
        if tool == .text { commitText(); beginText(at: p); return }
        current = Drawn(shape: tool, points: [p])
    }

    override func mouseDragged(with e: NSEvent) {
        guard var c = current else { return }
        let p = convert(e.locationInWindow, from: nil)
        if c.shape == .pen { c.points.append(p) } else { c.points = [c.points[0], p] }
        current = c
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = current else { return }
        current = nil
        guard c.points.count > 1 else { return }
        drawn.append(c)
        onDrawn?(c, startedAt)
        needsDisplay = true
    }

    private func beginText(at p: CGPoint) {
        let f = NSTextField(frame: NSRect(x: p.x, y: p.y, width: 420, height: 34))
        f.font = .boldSystemFont(ofSize: 22)
        f.textColor = .white
        f.backgroundColor = Self.red
        f.isBordered = false
        f.focusRingType = .none
        f.target = self
        f.action = #selector(textDone)
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
    }

    @objc private func textDone() {
        commitText()
        window?.makeFirstResponder(self)
    }

    private func commitText() {
        guard let f = field else { return }
        field = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespaces)
        let origin = f.frame.origin
        f.removeFromSuperview()
        guard !text.isEmpty else { return }
        let d = Drawn(shape: .text, points: [origin, CGPoint(x: origin.x + 200, y: origin.y + 34)], text: text)
        drawn.append(d)
        onDrawn?(d, startedAt)
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        for d in drawn + (current.map { [$0] } ?? []) { render(d) }
        if markMode {
            NSColor.systemYellow.set()
            let rim = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            rim.lineWidth = 6
            rim.stroke()
        }
    }

    private func render(_ d: Drawn) {
        Self.red.set()
        guard let a = d.points.first, let b = d.points.last else { return }
        let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch d.shape {
        case .pen:
            path.move(to: a)
            d.points.dropFirst().forEach { path.line(to: $0) }
        case .rectangle: path.appendRect(rect)
        case .circle: path.appendOval(in: rect)
        case .arrow:
            let cg = CGMutablePath()
            OverlayArt.addArrow(cg, from: a, to: b, head: 22)
            path.append(NSBezierPath(cgPath: cg))
        case .text:
            let label = NSAttributedString(string: " \(d.text ?? "") ", attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white, .backgroundColor: Self.red])
            label.draw(at: a)
            return
        case .mark: return
        }
        path.stroke()
    }

    // Mark mode: a click pulses a highlight on the spot, a drag frames an area. Both fade on their own, the video keeps them.
    func markBegan(at p: CGPoint) {
        markStart = p
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.systemYellow.withAlphaComponent(0.28).cgColor
        layer.strokeColor = NSColor.systemYellow.cgColor
        layer.lineWidth = 4
        layer.path = CGPath(ellipseIn: CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68), transform: nil)
        wantsLayer = true
        self.layer?.addSublayer(layer)
        layer.frame = bounds
        markLayer = layer
    }

    func markMoved(to p: CGPoint) {
        guard let start = markStart, hypot(p.x - start.x, p.y - start.y) > 8 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayer?.path = CGPath(rect: Self.rect(start, p), transform: nil)
        CATransaction.commit()
    }

    /// Returns the marked area, in view coordinates.
    func markEnded(at p: CGPoint) -> (rect: CGRect, dragged: Bool)? {
        guard let start = markStart, let layer = markLayer else { return nil }
        markStart = nil
        markLayer = nil
        let dragged = hypot(p.x - start.x, p.y - start.y) > 8
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 2.5
        fade.duration = 0.5
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { layer.removeFromSuperlayer() }
        return (dragged ? Self.rect(start, p) : CGRect(x: start.x - 34, y: start.y - 34, width: 68, height: 68), dragged)
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Small floating bar with the timer and drawing tools. It is left out of the recording.
final class ToolBar: NSObject {
    let panel: NSPanel
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var buttons: [(MarkShape?, NSButton)] = []
    private var markButton: NSButton!
    var onTool: ((MarkShape?) -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onStop: (() -> Void)?
    var onMark: (() -> Void)?

    init(screen: NSScreen) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false

        let blur = NSVisualEffectView(frame: panel.contentView!.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.autoresizingMask = [.width, .height]
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        row.frame = blur.bounds
        row.autoresizingMask = [.width, .height]
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .systemRed
        row.addArrangedSubview(timeLabel)
        markButton = button("highlighter", "Mark mode: clicks and drags become highlights", #selector(markPressed))
        markButton.setButtonType(.toggle)
        row.addArrangedSubview(markButton)
        let tools: [(MarkShape?, String, String)] = [(nil, "cursorarrow", "Normal mouse (Esc)"), (.pen, "pencil.tip", "Pen (P)"), (.rectangle, "rectangle", "Rectangle (R)"),
                                                 (.circle, "circle", "Circle (O)"), (.arrow, "arrow.up.right", "Arrow (A)"), (.text, "textformat", "Text (T)")]
        for (shape, symbol, tip) in tools {
            let b = button(symbol, tip, #selector(toolPressed))
            b.setButtonType(.toggle)
            b.tag = buttons.count
            buttons.append((shape, b))
            row.addArrangedSubview(b)
        }
        row.addArrangedSubview(button("arrow.uturn.backward", "Undo (Z)", #selector(undoPressed)))
        row.addArrangedSubview(button("trash", "Clear (C)", #selector(clearPressed)))
        row.addArrangedSubview(button("stop.circle.fill", "Stop", #selector(stopPressed)))
        blur.addSubview(row)
        panel.contentView!.addSubview(blur)
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.maxY - 52))
        select(nil)
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    func select(_ tool: MarkShape?) { for (shape, b) in buttons { b.state = shape == tool ? .on : .off; b.contentTintColor = shape == tool ? .systemRed : nil } }
    func showMarkMode(_ on: Bool) {
        markButton.state = on ? .on : .off
        markButton.contentTintColor = on ? .systemYellow : nil
    }

    func setTime(_ t: Double) { timeLabel.stringValue = Report.stamp(t) }
    @objc private func toolPressed(_ b: NSButton) { onTool?(buttons[b.tag].0) }
    @objc private func markPressed() { onMark?() }
    @objc private func undoPressed() { onUndo?() }
    @objc private func clearPressed() { onClear?() }
    @objc private func stopPressed() { onStop?() }
}

/// Short message in the corner, optionally with buttons.
final class Toast {
    struct Action {
        var title: String
        var run: () -> Void
    }

    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private var actions: [Action] = []
    var windowNumber: Int? { panel?.windowNumber }
    /// Hidden from every recording; only the self test turns this off to photograph it.
    var hiddenFromCapture = true

    func show(_ text: String, buttons: [Action] = [], seconds: Double? = nil) {
        panel?.close()
        hide?.cancel()
        actions = buttons
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let buttonWidth: CGFloat = 100
        let width = 256 + CGFloat(max(1, buttons.count)) * buttonWidth, height: CGFloat = 56
        let p = NSPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - width - 16, y: screen.visibleFrame.maxY - height - 12, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.sharingType = hiddenFromCapture ? .none : .readOnly
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let blur = NSVisualEffectView(frame: p.contentView!.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 14, y: 8, width: width - 28 - CGFloat(buttons.count) * buttonWidth, height: 40)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        blur.addSubview(label)
        for (i, action) in buttons.enumerated() {
            let b = NSButton(title: action.title, target: self, action: #selector(pressed))
            b.bezelStyle = .rounded
            b.tag = i
            b.frame = NSRect(x: width - 8 - CGFloat(buttons.count - i) * buttonWidth, y: 14, width: buttonWidth - 4, height: 28)
            blur.addSubview(b)
        }
        p.contentView!.addSubview(blur)
        p.orderFrontRegardless()
        panel = p
        if let seconds {
            let w = DispatchWorkItem { [weak self] in self?.panel?.close() }
            hide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
    }

    @objc private func pressed(_ b: NSButton) {
        panel?.close()
        actions[b.tag].run()
    }
}
