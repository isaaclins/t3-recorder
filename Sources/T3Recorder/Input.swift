import AppKit
import Carbon.HIToolbox

/// Global shortcuts without any permission prompt.
final class HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var refs: [UInt32: EventHotKeyRef] = [:]

    func set(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.install()
        remove(id: id)
        Self.handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x5433_5243, id: id)
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs[id] = ref }
    }

    func remove(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let handler = HotKeys.handlers[id.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String in
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// Sees every click during a recording and leaves it alone, until mark mode is on: then clicks and drags are taken away from
/// the app underneath and become highlights. Taking clicks needs the Accessibility permission; without it clicks are only logged.
final class ClickWatcher {
    enum Action { case click(CGPoint), markBegan(CGPoint), markMoved(CGPoint), markEnded(CGPoint) }

    var markMode = false
    /// Points that stay clickable in mark mode: the toolbar.
    var keepsClicks: ((CGPoint) -> Bool)?
    var onAction: ((Action) -> Void)?
    var canTakeClicks: Bool { tap != nil }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallback: Any?
    private var dragging = false

    func start() {
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            let me = Unmanaged<ClickWatcher>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me)
        if let tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            Log.info("no Accessibility permission: clicks are logged, mark mode is off")
            fallback = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                guard let cg = e.cgEvent else { return }
                self?.onAction?(.click(cg.location))
            }
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let fallback { NSEvent.removeMonitor(fallback) }
        tap = nil
        source = nil
        fallback = nil
        dragging = false
        markMode = false
    }

    /// Runs on the main thread (the tap sits on the main run loop). True when the event must not reach the app underneath.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let p = event.location
        // A drag started before mark mode was turned off still has to end here, or the app would get a stray mouse-up.
        if dragging {
            if type == .leftMouseDragged { onAction?(.markMoved(p)) }
            if type == .leftMouseUp {
                dragging = false
                onAction?(.markEnded(p))
            }
            return true
        }
        if markMode, keepsClicks?(p) != true {
            if type == .leftMouseDown {
                dragging = true
                onAction?(.markBegan(p))
            }
            return true
        }
        if type == .leftMouseDown || type == .rightMouseDown { onAction?(.click(p)) }
        return false
    }
}

/// The app and window under a point, in global top-left coordinates. Names come with the Screen Recording permission.
enum WindowLookup {
    static func at(_ p: CGPoint) -> (app: String, window: String)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != mine,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) else { continue }
            return (w[kCGWindowOwnerName as String] as? String ?? "", w[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }
}
