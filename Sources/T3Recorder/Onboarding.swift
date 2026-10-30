import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Starting at login, which macOS keeps track of itself.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("start at login: \(error)")
        }
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, shortcuts, screen, microphone, accessibility, login, speech, done }
    enum Practice: Hashable { case start, mark, draw }
    enum Speech: Equatable { case waiting, working(Double, String), ready, failed }

    @Published private(set) var step: Step
    @Published var movingForward = true
    @Published var practiced: Set<Practice> = []
    @Published var screenAllowed = false
    @Published var micAllowed = false
    @Published var accessibilityAllowed = false
    @Published var startsAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var askedForScreen = false
    @Published var speech = Speech.waiting
    var startKeys = ""
    var markKeys = ""
    let drawKeys = "⌃⌥D"
    var onStep: (Step) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var fetchSpeech: () -> Void = {}

    init(step: Step) {
        self.step = step
        refresh()
    }

    /// Called every second: nothing tells us when a switch is flipped in System Settings.
    func refresh() {
        set(\.screenAllowed, CGPreflightScreenCaptureAccess())
        set(\.micAllowed, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        set(\.accessibilityAllowed, AXIsProcessTrusted())
        set(\.startsAtLogin, LoginItem.isOn)
        set(\.loginNeedsApproval, LoginItem.needsApproval)
    }

    private func set(_ key: ReferenceWritableKeyPath<OnboardingModel, Bool>, _ value: Bool) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func show(_ new: Step) {
        movingForward = new.rawValue >= step.rawValue
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { step = new }
        onStep(new)
        if new == .speech, speech == .waiting || speech == .failed { fetchSpeech() }
    }

    func next() {
        if let after = Step(rawValue: step.rawValue + 1) { show(after) } else { onFinish() }
    }

    func back() {
        if let before = Step(rawValue: step.rawValue - 1) { show(before) }
    }

    func pressed(_ key: Practice) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { _ = practiced.insert(key) }
    }

    /// Whether the step's own job is done, which decides between "Continue" and "Skip for now".
    var stepDone: Bool {
        switch step {
        case .shortcuts: return practiced.count == 3
        case .screen: return screenAllowed
        case .microphone: return micAllowed
        case .accessibility: return accessibilityAllowed
        default: return true
        }
    }

    func askForScreen() {
        askedForScreen = true
        if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
    }

    func askForMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh() } }
        } else {
            openPrivacy("Privacy_Microphone")
        }
    }

    func askForAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// The first launch: what the app does, its keys, its permissions one at a time, and the speech model.
final class OnboardingController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    private var poll: Timer?
    private var finished = false

    init(step: OnboardingModel.Step) {
        model = OnboardingModel(step: step)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("no storyboard") }

    func windowWillClose(_ note: Notification) {
        poll?.invalidate()
        poll = nil
        guard !finished else { return }
        finished = true
        model.onFinish()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: model.movingForward ? 36 : -36)),
                        removal: .opacity.combined(with: .offset(x: model.movingForward ? -36 : 36))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .frame(width: 660, height: 500)
        .background(VisualEffect().ignoresSafeArea())
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome:
            Page(title: "Show the problem instead of describing it", text: "Record your screen and talk. When you stop, a report and screenshots are ready to paste into your agent.") { AppMark(size: 84) }
        case .shortcuts:
            Page(title: "Three keys, try them now", text: "Press each one. Nothing is being recorded yet.") {
                VStack(spacing: 10) {
                    PracticeRow(keys: model.startKeys, text: "Start and stop a recording", done: model.practiced.contains(.start))
                    PracticeRow(keys: model.markKeys, text: "Mark mode, clicks become highlights", done: model.practiced.contains(.mark))
                    PracticeRow(keys: model.drawKeys, text: "Draw on the screen", done: model.practiced.contains(.draw))
                }
                .frame(width: 400)
            }
        case .screen:
            PermissionPage(symbol: "rectangle.dashed.badge.record", title: "Screen Recording", why: "This records the screen you are showing, only between your two key presses. Nothing leaves your Mac until you paste it.",
                           allowed: model.screenAllowed, hint: model.askedForScreen ? "If macOS asks to quit and reopen the app, say yes. This tour carries on from here." : nil, ask: model.askForScreen)
        case .microphone:
            PermissionPage(symbol: "mic", title: "Microphone", why: "Your explanation lands in the report as text. Your voice is turned into text on this Mac and is never sent anywhere.",
                           allowed: model.micAllowed, hint: nil, ask: model.askForMicrophone)
        case .accessibility:
            PermissionPage(symbol: "cursorarrow.rays", title: "Accessibility", why: "Mark mode keeps a click from reaching the app underneath, so you can point at things without pressing them. Without this, clicks are only noted.",
                           allowed: model.accessibilityAllowed, hint: nil, ask: model.askForAccessibility)
        case .login:
            Page(title: "Start at login", text: "The shortcut is always ready, without opening anything first.") {
                VStack(spacing: 10) {
                    Toggle("Start when I log in", isOn: Binding(get: { model.startsAtLogin }, set: {
                        LoginItem.set($0)
                        model.refresh()
                    }))
                    .toggleStyle(.switch)
                    .font(.system(size: 14))
                    .frame(width: 240)
                    if model.loginNeedsApproval {
                        Text("Turn it on under Login Items in System Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        case .speech:
            Page(title: "The speech model", text: "It turns your voice into text on this Mac. It downloads once, about 490 MB.") { speech.frame(width: 340) }
        case .done:
            Page(title: "You're set", text: "When something goes wrong, press \(model.startKeys) and show it. The icon in your menu bar has everything else, and this tour.") { AppMark(size: 64) }
        }
    }

    @ViewBuilder private var speech: some View {
        switch model.speech {
        case .waiting:
            ProgressView().controlSize(.small)
        case .working(let fraction, let text):
            VStack(spacing: 8) {
                ProgressView(value: min(max(fraction, 0), 1))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(.green)
        case .failed:
            VStack(spacing: 8) {
                Text("The download didn't finish. It will try again on your first recording.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again", action: model.fetchSpeech)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Back", action: model.back).buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(model.step == .welcome ? 0 : 1).disabled(model.step == .welcome)
            Spacer()
            HStack(spacing: 7) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                    Circle().fill(s == model.step ? Color.primary : Color.primary.opacity(0.18)).frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            Button(primaryTitle, action: model.next)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(model.stepDone ? .accentColor : .secondary)
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get started"
        case .done: return "Start using it"
        case .speech: return model.speech == .ready ? "Continue" : "Continue, it keeps going"
        default: return model.stepDone ? "Continue" : "Skip for now"
        }
    }
}

private struct Page<Content: View>: View {
    let title: String
    let text: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 22) {
            content()
            VStack(spacing: 8) {
                Text(title).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
                Text(text).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 440)
            }
        }
        .padding(.horizontal, 40)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One permission on its own page: why it is needed, and the live answer from macOS.
private struct PermissionPage: View {
    let symbol: String
    let title: String
    let why: String
    let allowed: Bool
    let hint: String?
    let ask: () -> Void

    var body: some View {
        Page(title: title, text: why) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).frame(width: 84, height: 84)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if allowed {
                    Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(.green)
                } else {
                    Button("Allow \(title)…", action: ask).controlSize(.large).buttonStyle(.borderedProminent)
                }
                if let hint, !allowed { Text(hint).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .frame(height: 64, alignment: .top)
            .offset(y: 80)
            .animation(.easeOut(duration: 0.2), value: allowed)
        }
        .offset(y: -30)
    }
}

private struct PracticeRow: View {
    let keys: String
    let text: String
    let done: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 62, height: 30)
                .background(done ? Color.green.opacity(0.22) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(done ? 1.06 : 1)
            Text(text).font(.system(size: 14))
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).opacity(done ? 1 : 0).accessibilityHidden(!done)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Stands in until the app has its real icon.
private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.36, blue: 0.33), Color(red: 0.86, green: 0.1, blue: 0.2)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: size * 0.07).frame(width: size * 0.56, height: size * 0.56))
            .overlay(Circle().fill(.white).frame(width: size * 0.28, height: size * 0.28))
            .shadow(color: .black.opacity(0.22), radius: size * 0.12, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
