import AVFoundation
import AVKit
import AppKit
import RecorderCore
import SwiftUI

/// Second pass over a recording: fix what was misheard, cut parts, add notes and shapes, add a section, copy again.
final class EditorController: NSWindowController {
    let dir: URL
    private let model: EditorModel

    init(dir: URL, app: AppController) throws {
        self.dir = dir
        model = EditorModel(project: try ProjectStore.load(dir), dir: dir, app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = dir.lastPathComponent
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        model.controller = self
        Task { @MainActor in await model.rebuild() }
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    @MainActor func reload() async {
        if let p = try? ProjectStore.load(dir) { model.project = p }
        await model.rebuild()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor final class EditorModel: ObservableObject {
    @Published var project: Project
    @Published var time = 0.0
    @Published var markIn: Double?
    @Published var markOut: Double?
    @Published var tool: MarkShape?
    @Published var busy = false
    let player = AVPlayer()
    let dir: URL
    weak var app: AppController?
    weak var controller: EditorController?
    private var history: [Project] = []
    private var observer: Any?

    init(project: Project, dir: URL, app: AppController) {
        self.project = project
        self.dir = dir
        self.app = app
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
    }

    var duration: Double { max(project.duration, 0.1) }
    var aspect: CGFloat {
        guard let s = project.clips.first?.screen, s.height > 0 else { return 16 / 10 }
        return CGFloat(s.width) / CGFloat(s.height)
    }

    var rows: [Row] {
        var out: [Row] = []
        for e in project.events {
            guard let t = project.outputTime(clipID: e.clipID, t: e.t) else { continue }
            out.append(Row(id: e.id, t: t, kind: e.kind, overlay: false))
        }
        for o in project.overlays {
            if let t = project.outputTime(clipID: o.clipID, t: o.t) { out.append(Row(id: o.id, t: t, kind: .draw, overlay: true)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    struct Row: Identifiable { let id: UUID; let t: Double; let kind: TimelineKind; let overlay: Bool }

    func rebuild() async {
        do {
            let tl = try await Exporter.timeline(project, in: dir, burnOverlays: false)
            let item = AVPlayerItem(asset: tl.composition)
            item.videoComposition = tl.video
            let keep = time
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: min(keep, project.duration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } catch {
            player.replaceCurrentItem(with: nil)
        }
    }

    func seek(_ t: Double) {
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() { if player.rate == 0 { player.play() } else { player.pause() } }

    /// Every change goes through here: saved at once, and ⌘Z walks back.
    func change(rebuilds: Bool = false, _ edit: (inout Project) -> Void) {
        history.append(project)
        edit(&project)
        try? ProjectStore.save(project, to: dir)
        if rebuilds { Task { await rebuild() } }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        project = last
        try? ProjectStore.save(project, to: dir)
        Task { await rebuild() }
    }

    func cutMarked() {
        guard let a = markIn, let b = markOut else { return }
        change(rebuilds: true) { $0.cut(from: a, to: b) }
        markIn = nil
        markOut = nil
    }

    func addNote() {
        guard let text = ask("Note at \(Report.stamp(time))"), let at = project.sourceTime(output: time) else { return }
        change { $0.events.append(Event(clipID: at.clipID, t: at.t, kind: .note, text: text)) }
    }

    func addOverlay(_ shape: MarkShape, rect: NormRect, flipX: Bool, flipY: Bool) {
        guard let at = project.sourceTime(output: time) else { return }
        var text: String?
        if shape == .text {
            guard let typed = ask("Text to show at \(Report.stamp(time))") else { return }
            text = typed
        }
        change { $0.overlays.append(Overlay(clipID: at.clipID, t: at.t, shape: shape, rect: rect, flipX: flipX, flipY: flipY, text: text)) }
        tool = nil
    }

    func remove(_ row: Row) {
        change {
            if row.overlay { $0.overlays.removeAll { $0.id == row.id } } else { $0.events.removeAll { $0.id == row.id } }
        }
    }

    func text(for row: Row) -> Binding<String> {
        Binding(get: { [weak self] in
            self?.project.events.first { $0.id == row.id }?.text ?? ""
        }, set: { [weak self] new in
            self?.change { p in
                if let i = p.events.firstIndex(where: { $0.id == row.id }) { p.events[i].text = new }
            }
        })
    }

    func label(_ row: Row) -> String {
        if row.overlay {
            guard let o = project.overlays.first(where: { $0.id == row.id }) else { return "" }
            return o.shape == .text ? "shows \"\(o.text ?? "")\"" : "added \(o.shape.rawValue)"
        }
        guard let e = project.events.first(where: { $0.id == row.id }) else { return "" }
        switch e.kind {
        case .click: return "click\(e.app.map { " in \($0)" } ?? "")"
        case .app: return "switched to \(e.app ?? "")"
        case .draw: return e.shape == .mark ? "marked a spot" : "drew a \(e.shape?.rawValue ?? "shape")"
        default: return e.text ?? ""
        }
    }

    func copy() {
        guard let app else { return }
        busy = true
        player.pause()
        Task {
            do {
                try await app.deliver(project, in: dir)
                controller?.close()
            } catch {
                _ = ask("Could not finish: \(error.localizedDescription)", input: false)
            }
            busy = false
        }
    }

    func addSection() {
        player.pause()
        if let c = controller { app?.recordSection(for: c) }
    }

    private func ask(_ title: String, input: Bool = true) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        if input { alert.addButton(withTitle: "Cancel") }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if input { alert.accessoryView = field }
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return input && text.isEmpty ? nil : text
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {}
}

/// Shows the editor's shapes at the playhead and takes new ones while a tool is active.
private struct OverlayCanvas: View {
    @ObservedObject var model: EditorModel
    @State private var from: CGPoint?
    @State private var to: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(visible) { o in
                    OverlayShape(overlay: o).stroke(Color.red, lineWidth: 3)
                    if o.shape == .text {
                        Text(o.text ?? "").bold().foregroundStyle(.white).padding(4).background(Color.red)
                            .position(x: (o.rect.x + 0.08) * geo.size.width, y: (o.rect.y + 0.02) * geo.size.height)
                    }
                }
                if let from, let to, let tool = model.tool {
                    OverlayShape(overlay: Overlay(clipID: "", t: 0, shape: tool, rect: norm(from, to, geo.size), flipX: to.x < from.x, flipY: to.y < from.y))
                        .stroke(Color.red, lineWidth: 3)
                }
                if model.tool != nil {
                    Color.white.opacity(0.001).gesture(DragGesture(minimumDistance: 0).onChanged {
                        from = $0.startLocation
                        to = $0.location
                    }.onEnded { v in
                        defer { from = nil; to = nil }
                        guard let tool = model.tool else { return }
                        var rect = norm(v.startLocation, v.location, geo.size)
                        if rect.w < 0.01 { rect.w = 0.12 }
                        if rect.h < 0.01 { rect.h = 0.08 }
                        model.addOverlay(tool, rect: rect, flipX: v.location.x < v.startLocation.x, flipY: v.location.y < v.startLocation.y)
                    })
                }
            }
        }
    }

    private var visible: [Overlay] {
        model.project.overlays.filter { o in
            guard let t = model.project.outputTime(clipID: o.clipID, t: o.t) else { return false }
            return model.time >= t && model.time < t + o.duration
        }
    }

    private func norm(_ a: CGPoint, _ b: CGPoint, _ s: CGSize) -> NormRect {
        NormRect(x: min(a.x, b.x) / s.width, y: min(a.y, b.y) / s.height, w: abs(a.x - b.x) / s.width, h: abs(a.y - b.y) / s.height)
    }
}

private struct OverlayShape: SwiftUI.Shape {
    let overlay: Overlay

    func path(in r: CGRect) -> Path {
        guard overlay.shape != .text else { return Path() }
        let rect = CGRect(x: overlay.rect.x * r.width, y: overlay.rect.y * r.height, width: overlay.rect.w * r.width, height: overlay.rect.h * r.height)
        return Path(OverlayArt.path(overlay, rect: rect, head: 18))
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HSplitView {
            VStack(spacing: 10) {
                ZStack {
                    PlayerSurface(player: model.player)
                    OverlayCanvas(model: model)
                }
                .aspectRatio(model.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                timeline
                controls
            }
            .padding(12)
            .frame(minWidth: 800)
            list.frame(minWidth: 300, idealWidth: 360)
        }
        .frame(minWidth: 1100, minHeight: 620)
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                    if let a = model.markIn, let b = model.markOut {
                        Rectangle().fill(Color.red.opacity(0.35))
                            .frame(width: abs(b - a) / model.duration * w)
                            .offset(x: min(a, b) / model.duration * w)
                    }
                    ForEach(model.rows) { r in
                        Rectangle().fill(tint(r.kind)).frame(width: 2, height: r.kind == .said ? 10 : 18)
                            .offset(x: r.t / model.duration * w)
                    }
                    Rectangle().fill(Color.primary).frame(width: 2).offset(x: model.time / model.duration * w)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(min(max(0, $0.location.x / w), 1) * model.duration) })
            }
            .frame(height: 30)
            HStack {
                Text(Report.stamp(model.time)).monospacedDigit()
                Spacer()
                Text(Report.stamp(model.project.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func tint(_ k: TimelineKind) -> Color {
        switch k {
        case .said: return .blue
        case .draw, .note: return .red
        case .click: return .orange
        case .app: return .green
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlay) { Image(systemName: "playpause.fill") }.keyboardShortcut(.space, modifiers: [])
            Divider().frame(height: 18)
            Button("Cut from here") { model.markIn = model.time }
            Button("to here") { model.markOut = model.time }
            Button("Cut it", action: model.cutMarked).disabled(model.markIn == nil || model.markOut == nil)
            Divider().frame(height: 18)
            Picker("", selection: $model.tool) {
                Text("Add…").tag(MarkShape?.none)
                Text("Rectangle").tag(MarkShape?.some(.rectangle))
                Text("Circle").tag(MarkShape?.some(.circle))
                Text("Arrow").tag(MarkShape?.some(.arrow))
                Text("Text").tag(MarkShape?.some(.text))
            }
            .labelsHidden()
            .frame(width: 110)
            Button("Note", action: model.addNote)
            Button("Record more", action: model.addSection)
            Button("Undo", action: model.undo).keyboardShortcut("z")
            Spacer()
            Button(model.busy ? "Working…" : "Copy for T3", action: model.copy)
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Button(Report.stamp(row.t)) { model.seek(row.t) }
                            .buttonStyle(.plain)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if !row.overlay, row.kind == .said || row.kind == .note {
                            TextField("", text: model.text(for: row), axis: .vertical).textFieldStyle(.plain)
                        } else {
                            Text(model.label(row)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { model.remove(row) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Remove this line")
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                }
            }
        }
    }
}
