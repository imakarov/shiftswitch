// ShiftSwitch — tap Shift once to retype the last word in the other keyboard layout.
// Single-file AppKit menu bar app. No auto-switching, no network, no dictionaries.

import AppKit
import Carbon
import ServiceManagement

// MARK: - Constants

private let kMarker: Int64 = 0x5348_4657          // tags our own synthetic events ("SHFW")
private let kShiftL = CGKeyCode(kVK_Shift), kShiftR = CGKeyCode(kVK_RightShift)
private let kBackspace = CGKeyCode(kVK_Delete), kSpace = CGKeyCode(kVK_Space)
private let kMaxWord = 128

private let kSite = URL(string: "https://imakarov.us/product-shiftswitch.html")!
private let kRepo = URL(string: "https://github.com/imakarov/shiftswitch")!
private let kSponsor = URL(string: "https://github.com/sponsors/imakarov")!

/// Russian UI when the system prefers Russian, English otherwise.
private let isRU = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
private func L(_ ru: String, _ en: String) -> String { isRU ? ru : en }

// MARK: - Keyboard layouts (TIS / UCKeyTranslate). Main thread only.

private struct Stroke {
    let key: CGKeyCode, shift: Bool, caps: Bool
    var onScreen = true     // false for a dead key (e.g. ' in US-International) that composed into the next char
}

private enum Layouts {
    static func id(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func data(_ s: TISInputSource) -> Data? {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
    }

    static func current() -> TISInputSource { TISCopyCurrentKeyboardInputSource().takeRetainedValue() }

    /// Enabled, selectable layouts that have a key map (skips IMEs, emoji palette, dictation).
    static func enabled() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                      kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue!] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.filter { data($0) != nil }
    }

    /// Target layout: the one used before the current one (so 3+ layouts toggle between the last two,
    /// not cycle), falling back to the next one in the user's list.
    static func other(previous: String?) -> TISInputSource? {
        let all = enabled()
        guard all.count >= 2 else { return nil }
        let cur = id(current())
        if let previous, previous != cur, let p = all.first(where: { id($0) == previous }) { return p }
        let i = all.firstIndex { id($0) == cur } ?? -1
        return all[(i + 1) % all.count]
    }

    /// Character a key produces. With `dead` non-nil, dead keys are processed statefully (empty result =
    /// dead key pending); with nil, a dead key yields its bare accent character.
    static func translate(_ s: Stroke, _ layout: Data, dead: UnsafeMutablePointer<UInt32>? = nil) -> String {
        layout.withUnsafeBytes { raw -> String in
            guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var state = dead?.pointee ?? 0, len = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let mods: UInt32 = (s.shift ? UInt32(shiftKey >> 8) : 0) | (s.caps ? UInt32(alphaLock >> 8) : 0)
            let opts = dead == nil ? OptionBits(kUCKeyTranslateNoDeadKeysMask) : 0
            let st = UCKeyTranslate(ptr, UInt16(s.key), UInt16(kUCKeyActionDown), mods & 0xFF,
                                    UInt32(LMGetKbdType()), opts, &state, chars.count, &len, &chars)
            dead?.pointee = state
            return st == noErr ? String(utf16CodeUnits: chars, count: len) : ""
        }
    }

    static func isDeadKey(_ s: Stroke, _ layout: Data) -> Bool {
        var dead: UInt32 = 0
        return translate(s, layout, dead: &dead).isEmpty && dead != 0
    }

    /// Return, Tab, Esc, arrows, Home/End, F-keys… translate to control or private-use (0xF7xx) characters.
    static func isPrintable(_ str: String) -> Bool {
        guard let u = str.unicodeScalars.first else { return false }
        return ![.control, .privateUse].contains(u.properties.generalCategory)
    }
}

// MARK: - Secure Input diagnostics (the #1 reason layout fixers "don't work in Terminal")

private enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Name of the app currently holding Secure Keyboard Entry, read from the IORegistry.
    static func owner() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        guard let pid = users.lazy.compactMap({ $0["kCGSSessionSecureInputPID"] as? Int }).first(where: { $0 > 0 })
        else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "PID \(pid)"
    }
}

// MARK: - Engine: event tap, word buffer, conversion

private final class Engine {
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }
    var tapActive: Bool { tap != nil }
    private var tap: CFMachPort?
    private var tapThreshold: TimeInterval = 0.3

    // The last word (since whitespace) plus any whitespace typed after it.
    private var buf: [Stroke] = []

    // Shift-tap detection
    private var shiftDown = false
    private var shiftCandidate = false
    private var shiftDownAt: TimeInterval = 0

    private var deadState: UInt32 = 0

    // Layout history (for toggling back) and our own pending switch (to tell it from a manual one).
    private var currentID = Layouts.id(Layouts.current())
    private var currentLayout = Layouts.data(Layouts.current())   // cached: onKey runs on every keystroke
    private var previousID: String?
    private var expectedID: String?

    private var busy = false
    private let postQueue = DispatchQueue(label: "shiftswitch.post", qos: .userInteractive)

    init() {
        UserDefaults.standard.register(defaults: ["enabled": true, "tapThresholdMs": 300])
        tapThreshold = TimeInterval(UserDefaults.standard.integer(forKey: "tapThresholdMs")) / 1000
        buf.reserveCapacity(kMaxWord + 1)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.layoutChanged() }
    }

    func reset() { buf.removeAll(keepingCapacity: true); deadState = 0 }

    private func layoutChanged() {
        let id = Layouts.id(Layouts.current())
        guard id != currentID else { return }
        previousID = currentID
        currentID = id
        currentLayout = Layouts.data(Layouts.current())
        if id == expectedID { expectedID = nil } else { reset() }   // manual switch mid-word: buffer is stale
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, ctx in
            Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // macOS disables slow taps; turn it back on
            shiftCandidate = false
            reset()
            return
        }
        if e.getIntegerValueField(.eventSourceUserData) == kMarker { return }
        if type == .flagsChanged { onFlags(e); return }
        shiftCandidate = false              // Shift+letter = capital, Shift+click = selection: not a tap
        if type == .keyDown { onKey(e) } else { reset() }   // mouse click moved the caret
    }

    private func onFlags(_ e: CGEvent) {
        let key = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags
        let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard key == kShiftL || key == kShiftR else {
            shiftCandidate = false          // any other modifier touched during the press cancels it
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if f.contains(.maskShift) && !shiftDown {
            shiftDown = true
            shiftDownAt = now
            shiftCandidate = f.intersection(others).isEmpty
        } else if !f.contains(.maskShift) && shiftDown {
            shiftDown = false
            if shiftCandidate && enabled && now - shiftDownAt < tapThreshold {
                DispatchQueue.main.async { self.convert() }
            }
            shiftCandidate = false
        } else {
            shiftCandidate = false          // second Shift pressed while first held
        }
    }

    private func onKey(_ e: CGEvent) {
        let key = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
        let f = e.flags
        if !f.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { reset(); return }
        if key == kBackspace {
            deadState = 0
            if buf.popLast() == nil { reset() }
            return
        }
        var s = Stroke(key: key, shift: f.contains(.maskShift), caps: f.contains(.maskAlphaShift))
        // Non-printable keys (Return, Tab, Esc, arrows, Home/End, F-keys) move the caret or commit input.
        guard let layout = currentLayout,
              Layouts.isPrintable(Layouts.translate(s, layout)) else { reset(); return }
        // Track dead-key composition so we know how many characters are really on screen.
        let pendingDead = deadState != 0
        let live = Layouts.translate(s, layout, dead: &deadState)
        if live.isEmpty { s.onScreen = false }
        if pendingDead && live.count > 1 && !buf.isEmpty {   // accent didn't combine: it's on screen by itself
            buf[buf.count - 1].onScreen = true
        }
        if key == kSpace {
            if !buf.isEmpty { buf.append(s) }
        } else {
            if buf.last?.key == kSpace { buf.removeAll(keepingCapacity: true) }   // new word after whitespace
            buf.append(s)
        }
        if buf.count > kMaxWord { reset() }
    }

    /// Erase the last word (+ trailing spaces), switch layout, retype the same keys in the new layout.
    private func convert() {
        guard !busy, let target = Layouts.other(previous: previousID) else { return }
        let targetID = Layouts.id(target)
        expectedID = targetID
        let strokes = buf
        guard !strokes.isEmpty, let layout = Layouts.data(target) else {
            TISSelectInputSource(target)    // nothing typed yet: just switch the layout
            return
        }
        // A trailing dead key is shown as a pending accent; one Backspace cancels it too.
        let erase = strokes.filter(\.onScreen).count + (strokes.last?.onScreen == false ? 1 : 0)
        // Key code + its Unicode string for the target layout. Keys that are dead in the target layout are sent
        // as pure Unicode (key code 0 with a string) so the app doesn't start an accent composition.
        let typed: [(CGKeyCode, CGEventFlags, String)] = strokes.map {
            (Layouts.isDeadKey($0, layout) ? 0 : $0.key, $0.shift ? .maskShift : [], Layouts.translate($0, layout))
        }
        busy = true
        deadState = 0
        TISSelectInputSource(target)
        waitForLayout(targetID, tries: 20) {
            self.postQueue.async {
                let src = CGEventSource(stateID: .privateState)
                for _ in 0..<erase { Self.post(src, kBackspace, [], nil) }
                for (key, flags, str) in typed { Self.post(src, key, flags, str) }
                DispatchQueue.main.async { self.busy = false }
            }
        }
    }

    /// Layout switching is asynchronous: poll (on main, as TIS requires) until it has taken effect, max ~200 ms.
    private func waitForLayout(_ id: String, tries: Int, then work: @escaping () -> Void) {
        if tries == 0 || Layouts.id(Layouts.current()) == id {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.waitForLayout(id, tries: tries - 1, then: work) }
        }
    }

    private static func post(_ src: CGEventSource?, _ key: CGKeyCode, _ flags: CGEventFlags, _ str: String?) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            ev.flags = flags
            if let str {
                var u = Array(str.utf16)
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            }
            ev.setIntegerValueField(.eventSourceUserData, value: kMarker)
            ev.post(tap: .cghidEventTap)
            usleep(1_500)                   // Electron/Chromium drop events that arrive too fast
        }
    }
}

// MARK: - Menu bar UI

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = Engine()
    private var item: NSStatusItem!
    private var timer: Timer?
    private var shownSymbol = ""
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: L("Включено", "Enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: L("Запускать при входе", "Launch at Login"), action: #selector(toggleLogin),
                                       keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        status.isEnabled = false
        enabledItem.target = self
        loginItem.target = self
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Настройки Accessibility…", "Accessibility Settings…"), action: #selector(openAX),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        for (title, url) in [(L("ShiftSwitch \(version) — imakarov.us", "ShiftSwitch \(version) — imakarov.us"), kSite),
                             (L("Исходный код на GitHub", "Source Code on GitHub"), kRepo),
                             (L("Поддержать проект ♥", "Sponsor ♥"), kSponsor)] {
            let mi = menu.addItem(withTitle: title, action: #selector(openLink(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = url
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.engine.reset() }

        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if trusted { engine.start() }
        // Poll: start the tap once permission is granted; keep the icon in sync with Secure Input.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 1
        tick()
    }

    private enum State { case noAccess, secureInput, disabled, active }

    private var state: State {
        if !engine.tapActive { return .noAccess }
        if SecureInput.isOn { return .secureInput }
        return engine.enabled ? .active : .disabled
    }

    private func tick() {
        if !engine.tapActive && AXIsProcessTrusted() { engine.start() }
        let symbol = switch state {
        case .noAccess: "exclamationmark.triangle"
        case .secureInput: "lock.fill"
        case .disabled: "keyboard.badge.ellipsis"
        case .active: "keyboard"
        }
        guard symbol != shownSymbol else { return }
        shownSymbol = symbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ShiftSwitch")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuWillOpen(_ menu: NSMenu) {
        status.title = switch state {
        case .noAccess: L("Нет доступа Accessibility", "No Accessibility permission")
        case .secureInput: L("Secure Input: \(SecureInput.owner() ?? "?") блокирует ввод",
                             "Secure Input: \(SecureInput.owner() ?? "?") blocks typing")
        case .disabled: L("Выключено", "Disabled")
        case .active: L("Активно — короткий Shift", "Active — tap Shift")
        }
        enabledItem.state = engine.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        engine.enabled.toggle()
        tick()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
