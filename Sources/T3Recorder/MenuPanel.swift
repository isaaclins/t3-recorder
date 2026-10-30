import AppKit
import Combine
import RecorderCore
import SwiftUI

struct RecentRecording: Hashable, Identifiable {
    let dir: URL
    let title: String
    let length: String
    var id: URL { dir }
}

/// What the panel shows. The app fills it in; the panel only sends back which item was chosen.
final class PanelModel: ObservableObject {
    enum Phase { case idle, recording, working }
    enum Page { case main, settings }
    enum Shortcut { case start, mark }

    enum Item: Hashable {
        case toggleRecording, markMode, settings, quit, back
        case edit(RecentRecording), copy(RecentRecording), copyWithVideo(RecentRecording)
        case change(Shortcut), startAtLogin, allowAccessibility, showFolder, tour, checkForUpdates
    }

    @Published var phase = Phase.idle
    @Published var status = ""
    @Published var time = 0.0
    @Published var markMode = false
    @Published var recents: [RecentRecording] = []
    @Published var startKeys = ""
    @Published var markKeys = ""
    @Published var canTakeClicks = true
    @Published var startsAtLogin = false
    @Published var updatesAvailable = false
    @Published var page = Page.main
    @Published var focus: Item?
    @Published var capturing: Shortcut?
    var perform: (Item) -> Void = { _ in }

    var version: String { Updates.version }

    /// Rows top to bottom, each row left to right: the arrow keys walk this.
    var grid: [[Item]] {
        switch page {
        case .main:
            var rows: [[Item]] = []
            if phase != .working { rows.append([.toggleRecording]) }
            if phase == .recording { rows.append([.markMode]) }
            if phase == .idle { rows += recents.map { [.edit($0), .copy($0), .copyWithVideo($0)] } }
            return rows + [[.settings, .quit]]
        case .settings:
            var rows: [[Item]] = [[.back]]
            if phase == .idle { rows += [[.change(.start)], [.change(.mark)]] }
            rows.append([.startAtLogin])
            if !canTakeClicks { rows.append([.allowAccessibility]) }
            rows += [[.showFolder], [.tour]]
            if updatesAvailable { rows.append([.checkForUpdates]) }
            return rows
        }
    }

    func firstFocus() { focus = grid.first?.first }

    func choose(_ item: Item) {
        switch item {
        case .settings: go(.settings)
        case .back: go(.main)
        default: perform(item)
        }
        // A choice can take its row away, such as the mark row when the recording ends.
        if let focus, !grid.joined().contains(focus) { firstFocus() }
    }

    func go(_ new: Page) {
        page = new
        firstFocus()
    }

    func moveVertically(_ step: Int) {
        let rows = grid
        guard let at = position(in: rows) else { return firstFocus() }
        let row = rows[(at.row + step + rows.count) % rows.count]
        focus = row[min(at.column, row.count - 1)]
    }

    func moveSideways(_ step: Int) {
        let rows = grid
        guard let at = position(in: rows) else { return firstFocus() }
        let column = at.column + step
        if rows[at.row].indices.contains(column) { focus = rows[at.row][column] }
    }

    /// Tab walks every item in reading order, the way it does in a form.
    func tab(_ step: Int) {
        let all = Array(grid.joined())
        guard let focus, let i = all.firstIndex(of: focus) else { return firstFocus() }
        self.focus = all[(i + step + all.count) % all.count]
    }

    private func position(in rows: [[Item]]) -> (row: Int, column: Int)? {
        guard let focus else { return nil }
        for (r, row) in rows.enumerated() {
            if let c = row.firstIndex(of: focus) { return (r, c) }
        }
        return nil
    }
}

/// Borderless, and it takes the keyboard without pulling focus away from the app being shown.
final class MenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

/// Drops down from the menu bar icon. Closes like other menu bar panels: click outside, click the icon, or Esc.
final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    /// Hidden from every recording; only the self test turns this off to photograph it.
    var hiddenFromCapture = true {
        didSet { panel.sharingType = hiddenFromCapture ? .none : .readOnly }
    }
    var onCapture: ((UInt32, UInt32) -> Void)?
    var onCaptureEnded: (() -> Void)?
    var onOpen: ((CGWindowID) -> Void)?
    private static let width: CGFloat = 320
    private let panel: MenuPanel
    private let host: NSHostingView<PanelView>
    private var outsideClicks: Any?
    private var changes: AnyCancellable?
    private weak var button: NSStatusBarButton?

    var isOpen: Bool { panel.isVisible }
    var frame: NSRect? { isOpen ? panel.frame : nil }
    var windowNumber: Int { panel.windowNumber }

    init(button: NSStatusBarButton?) {
        self.button = button
        host = NSHostingView(rootView: PanelView(model: model))
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onKey = { [weak self] in self?.key($0) ?? false }

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask(radius: 14)
        panel.contentView = glass
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        model.page = .main
        model.firstFocus()
        fit()
        panel.makeKeyAndOrderFront(nil)
        button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
        onOpen?(CGWindowID(panel.windowNumber))
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        button?.highlight(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        endCapture()
    }

    func windowDidResignKey(_ note: Notification) { close() }

    /// The self test's keyboard: a real key event, through the same door as a real key press.
    func press(_ keyCode: UInt16) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return }
        panel.sendEvent(e)
    }

    var isKey: Bool { panel.isKeyWindow }

    func endCapture() {
        guard model.capturing != nil else { return }
        model.capturing = nil
        onCaptureEnded?()
    }

    /// True when the panel used the key. Everything else goes on to the window.
    func key(_ e: NSEvent) -> Bool {
        if model.capturing != nil {
            let mods = HotKeys.carbonModifiers(e.modifierFlags)
            if e.keyCode == 53 {
                endCapture()
            } else if mods != 0 {
                onCapture?(UInt32(e.keyCode), mods)
                endCapture()
            }
            return true
        }
        if e.modifierFlags.contains(.command) {
            switch e.charactersIgnoringModifiers {
            case ",": model.go(.settings)
            case "q": model.choose(.quit)
            default: return false
            }
            return true
        }
        switch Int(e.keyCode) {
        case 53:
            if model.page == .settings { model.go(.main) } else { close() }
        case 126: model.moveVertically(-1)
        case 125: model.moveVertically(1)
        case 123: model.moveSideways(-1)
        case 124: model.moveSideways(1)
        case 48: model.tab(e.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76, 49:
            if let focus = model.focus { model.choose(focus) }
        default: return false
        }
        return true
    }

    private func fit() {
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: host.fittingSize.height)
        guard let anchor = button?.window?.frame ?? fallbackAnchor else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let edge = screen?.visibleFrame { x = min(max(x, edge.minX + 8), edge.maxX - size.width - 8) }
        let frame = NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// The icon can be missing from the bar, on a crowded notch display for example.
    private var fallbackAnchor: NSRect? {
        guard let edge = NSScreen.main?.visibleFrame else { return nil }
        return NSRect(x: edge.maxX - 40, y: edge.maxY, width: 24, height: 24)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Group {
            switch model.page {
            case .main: main
            case .settings: settings
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            status.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            if model.phase != .working {
                PrimaryRow(model: model).padding(.horizontal, 10)
            }
            if model.phase == .recording {
                markRow.padding(.horizontal, 6).padding(.top, 6)
            }
            if model.phase == .idle {
                recents.padding(.top, 12)
            }
            Divider().padding(.top, 10)
            HStack(spacing: 2) {
                PanelRow(model: model, item: .settings) { Label("Settings", systemImage: "gearshape") }
                PanelRow(model: model, item: .quit) { Text("Quit").frame(maxWidth: .infinity, alignment: .trailing) }.frame(width: 76)
            }
            .padding(6)
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .idle:
                Text("Ready").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("T3 Recorder").font(.system(size: 12)).foregroundStyle(.secondary)
            case .recording:
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text("Recording").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(Report.stamp(model.time)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(.red)
            case .working:
                ProgressView().controlSize(.small)
                Text(model.status.isEmpty ? "Working on the last recording…" : model.status)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var markRow: some View {
        PanelRow(model: model, item: .markMode) {
            HStack(spacing: 8) {
                Image(systemName: "highlighter").frame(width: 18).foregroundStyle(model.markMode ? .yellow : .secondary)
                Text(model.markMode ? "Mark mode is on" : "Mark mode")
                Spacer()
                KeyCap(model.markKeys)
            }
        }
        .accessibilityValue(model.markMode ? "On" : "Off")
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 2)
            if model.recents.isEmpty {
                Text("Your recordings show up here.").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 6)
            }
            ForEach(model.recents) { RecentRow(model: model, recording: $0) }
        }
        .padding(.horizontal, 0)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelRow(model: model, item: .back) {
                Label("Settings", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold))
            }
            Divider().padding(.vertical, 4)
            if model.phase == .idle {
                shortcutRow("Start and stop", .start, model.startKeys)
                shortcutRow("Mark mode", .mark, model.markKeys)
            } else {
                Text("Shortcuts can be changed once the recording is done.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
            }
            if !model.canTakeClicks {
                PanelRow(model: model, item: .allowAccessibility) { Text("Allow marking clicks (Accessibility)…") }
            }
            PanelRow(model: model, item: .startAtLogin) {
                HStack {
                    Text("Start at login")
                    Spacer()
                    Text(model.startsAtLogin ? "On" : "Off").foregroundStyle(.secondary)
                }
            }
            .accessibilityValue(model.startsAtLogin ? "On" : "Off")
            PanelRow(model: model, item: .showFolder) { Text("Show recordings folder") }
            PanelRow(model: model, item: .tour) { Text("Show the welcome tour") }
            Divider().padding(.vertical, 4)
            if model.updatesAvailable {
                PanelRow(model: model, item: .checkForUpdates) {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        Text("Version \(model.version)").foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Version \(model.version)").font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .padding(6)
    }

    private func shortcutRow(_ title: String, _ shortcut: PanelModel.Shortcut, _ keys: String) -> some View {
        PanelRow(model: model, item: .change(shortcut)) {
            HStack {
                Text(title)
                Spacer()
                if model.capturing == shortcut {
                    Text("Press the keys, Esc cancels").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    KeyCap(keys)
                }
            }
        }
        .accessibilityValue(keys)
        .accessibilityHint("Press to set a new shortcut")
    }
}

/// Start or stop, the one big action of the panel.
private struct PrimaryRow: View {
    @ObservedObject var model: PanelModel
    private var recording: Bool { model.phase == .recording }

    var body: some View {
        Button { model.choose(.toggleRecording) } label: {
            HStack(spacing: 8) {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                Text(recording ? "Stop recording" : "Start recording").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.startKeys).font(.system(size: 12, weight: .medium)).opacity(0.8)
            }
            .foregroundStyle(recording ? Color.primary : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(recording ? Color.primary.opacity(0.1) : Color.red, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if model.focus == .toggleRecording {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(recording ? 0.35 : 0.5), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.focus = .toggleRecording } }
    }
}

/// One recording: the row opens the editor, the two buttons appear with it to copy it again.
private struct RecentRow: View {
    @ObservedObject var model: PanelModel
    let recording: RecentRecording

    private var active: Bool {
        model.focus == .edit(recording) || model.focus == .copy(recording) || model.focus == .copyWithVideo(recording)
    }

    var body: some View {
        HStack(spacing: 4) {
            PanelRow(model: model, item: .edit(recording), highlighted: active) {
                HStack {
                    Text(recording.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(recording.length).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Edit the recording from \(recording.title), \(recording.length) long")
            icon(.copy(recording), "doc.on.doc", "Copy again")
            icon(.copyWithVideo(recording), "film", "Copy again with the video")
        }
        .padding(.horizontal, 6)
    }

    private func icon(_ item: PanelModel.Item, _ symbol: String, _ label: String) -> some View {
        Button { model.choose(item) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(model.focus == item ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .tertiary)
        .opacity(active ? 1 : 0.55)
        .help(label)
        .accessibilityLabel(label)
        .onHover { if $0 { model.focus = item } }
    }
}

/// A line like in a native menu: it lights up under the mouse and under the arrow keys alike.
private struct PanelRow<Content: View>: View {
    @ObservedObject var model: PanelModel
    let item: PanelModel.Item
    var highlighted: Bool?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button { model.choose(item) } label: {
            content()
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background((highlighted ?? (model.focus == item)) ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.focus = item } }
    }
}

private struct KeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
