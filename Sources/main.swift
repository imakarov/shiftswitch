// ShiftSwitch — tap Shift once to retype the last word in the other keyboard layout.
// Single-file AppKit menu bar app. No auto-switching, no network, no dictionaries.

import AppKit
import Carbon
import ServiceManagement

// MARK: - Constants

private let kMarker: Int64 = 0x5348_4657          // tags our own synthetic events ("SHFW")
private let kReplay: Int64 = 0x5348_5250          // tags user keys held back during a conversion and replayed
private let kShiftL = CGKeyCode(kVK_Shift), kShiftR = CGKeyCode(kVK_RightShift)
private let kBackspace = CGKeyCode(kVK_Delete), kSpace = CGKeyCode(kVK_Space)
private let kMaxWord = 128

private let kSite = URL(string: "https://imakarov.us/product-shiftswitch.html")!
private let kRepo = URL(string: "https://github.com/imakarov/shiftswitch")!
private let kSponsor = URL(string: "https://github.com/sponsors/imakarov")!

/// Russian UI when the system prefers Russian, English otherwise.
private let isRU = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
private func L(_ ru: String, _ en: String) -> String { isRU ? ru : en }

/// Opt-in diagnostics (`defaults write us.imakarov.shiftswitch debugLog -bool YES`) → ~/Library/Logs/ShiftSwitch.log.
/// Timings and counts only — never typed characters.
private let debugLog = UserDefaults.standard.bool(forKey: "debugLog")
private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ShiftSwitch.log")
private func log(_ msg: @autoclosure () -> String) {
    guard debugLog else { return }
    let line = "\(Date().formatted(.iso8601)) \(msg())\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

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

    /// A real copy of the layout's key map: the CFData belongs to the input source and must not outlive it.
    static func data(_ s: TISInputSource) -> Data? {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cf = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
        return Data(bytes: CFDataGetBytePtr(cf), count: CFDataGetLength(cf))
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

    /// Character → the key (and Shift state) that types it in a layout. Main row wins over the keypad.
    static func charMap(_ layout: Data) -> [Character: Stroke] {
        var m: [Character: Stroke] = [:]
        for shift in [false, true] {
            for k in 0..<128 {
                let s = Stroke(key: CGKeyCode(k), shift: shift, caps: false)
                let str = translate(s, layout)
                if str.count == 1, isPrintable(str), let ch = str.first, m[ch] == nil { m[ch] = s }
            }
        }
        return m
    }

    /// Retypes already-written text as if its keys had been pressed in the other layout. The source layout is the
    /// one whose keys produce more of the text's letters (Latin → English, Cyrillic → Russian); characters that
    /// aren't on the source layout (digits on other keys, emoji, newlines…) are kept as they are.
    static func convertText(_ text: String, _ a: (TISInputSource, Data), _ b: (TISInputSource, Data))
        -> (text: String, target: TISInputSource, targetData: Data) {
        let ma = charMap(a.1), mb = charMap(b.1)
        let score = { (m: [Character: Stroke]) in text.filter { $0.isLetter && m[$0] != nil }.count }
        let (srcMap, dst) = score(ma) >= score(mb) ? (ma, b) : (mb, a)
        let out = String(text.map { ch -> String in
            guard let st = srcMap[ch] else { return String(ch) }
            let t = translate(st, dst.1)
            return t.isEmpty ? String(ch) : t
        }.joined())
        return (out, dst.0, dst.1)
    }

    /// Return, Tab, Esc, arrows, Home/End, F-keys… translate to control or private-use (0xF7xx) characters.
    static func isPrintable(_ str: String) -> Bool {
        guard let u = str.unicodeScalars.first else { return false }
        return ![.control, .privateUse].contains(u.properties.generalCategory)
    }
}

// MARK: - Selected text (Accessibility)

private enum Selection {
    static let maxLength = 2000
    /// Terminals: selection there is not editable text; never retype into it.
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm"]
    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static var manualAX: Set<pid_t> = []

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// The selected text of the focused editable field in the frontmost app, or nil when there is none — or when
    /// the app doesn't tell (then we fall back to the last word). Call off the main thread: AX can block.
    enum Probe { case text(String), none, opaque(AXUIElement) }

    /// What the frontmost app says about its selection: the text, "no selection", or `opaque` — it exposes no
    /// accessibility tree for its content at all (e.g. the ChatGPT app), so we can't tell from here.
    static func probe() -> Probe {
        guard let front = NSWorkspace.shared.frontmostApplication,
              !terminals.contains(front.bundleIdentifier ?? "") else { return .none }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let sel = current() { return .text(sel) }
        return attr(app, kAXFocusedUIElementAttribute) == nil ? .opaque(app) : .none
    }

    /// Fallback for opaque apps: press "<App> → Services → ShiftSwitch: Convert Layout" through the menu bar,
    /// which apps keep accessible. The app then hands its selection to our service over a private pasteboard
    /// and replaces it with what we return; with nothing selected the service is simply not called. No
    /// clipboard, no key shortcut. Returns false if the item isn't there. Blocks: call off the main thread.
    static func pressService(in app: AXUIElement) -> Bool {
        func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func items(_ menuOwner: AXUIElement) -> [AXUIElement] { children(menuOwner).flatMap(children) }
        guard let bar = attr(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
            log("service: no menu bar"); return false
        }
        let top = children(bar as! AXUIElement)
        guard top.count > 1 else { log("service: empty menu bar"); return false }
        // The Services submenu is localized ("Services", "Службы", "Dienste"…): find it by our item inside, in any
        // submenu of the app menu (top[0] is the Apple menu). The item only exists while text is selected.
        let ours = items(top[1]).lazy.flatMap(items).first { attr($0, kAXTitleAttribute) as? String == serviceTitle }
        guard let ours else { log("service: item not in the app menu (no selection, or service disabled)"); return false }
        let r = AXUIElementPerformAction(ours, kAXPressAction as CFString)
        log("service: pressed, AX result \(r.rawValue)")
        return r == .success
    }
    static let serviceTitle = "ShiftSwitch: Convert Layout"

    static func current() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              !terminals.contains(front.bundleIdentifier ?? "") else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium/Electron build their accessibility tree only when asked to, and WebKit answers the very first
        // query of a page lazily: on the first look at a process, ask for the tree and retry once.
        if !manualAX.contains(front.processIdentifier) {
            manualAX.insert(front.processIdentifier)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let sel = selected(in: app) { return sel }
            usleep(150_000)
        }
        return selected(in: app)
    }

    private static func selected(in app: AXUIElement) -> String? {
        guard let f = attr(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        guard let sel = attr(el, kAXSelectedTextAttribute) as? String, !sel.isEmpty, sel.count <= maxLength else { return nil }
        // Only editable text: retyping over a selection on a plain web page would fire the site's key shortcuts.
        let role = attr(el, kAXRoleAttribute) as? String ?? ""
        guard editableRoles.contains(role) || attr(el, "AXEditableAncestor") != nil else { return nil }
        return sel
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
    private var held: [(CGKeyCode, CGEventFlags)] = []   // real keys typed during a conversion, replayed after it
    // Last converted selection (what we typed, what was there), so an immediate second tap undoes it.
    // Any key or click forgets it.
    private var undo: (typed: String, original: String)?
    private var servicePending = false
    private let postQueue = DispatchQueue(label: "shiftswitch.post", qos: .userInteractive)
    private let selectionQueue = DispatchQueue(label: "shiftswitch.ax", qos: .userInteractive)

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
                ? Unmanaged.passUnretained(event) : nil
        }, userInfo: me) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// Returns false to swallow the event.
    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // macOS disables slow taps; turn it back on
            log("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            shiftCandidate = false
            reset()
            return true
        }
        let tag = e.getIntegerValueField(.eventSourceUserData)
        if tag == kMarker { return true }
        if type == .flagsChanged { onFlags(e); return true }
        if !busy || tag == kReplay { undo = nil }   // the user typed or clicked after a selection conversion
        // Keys typed while we erase and retype would land in the middle of the word: hold them, replay after.
        if type == .keyDown && busy && tag != kReplay {
            held.append((CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode)), e.flags))
            return false
        }
        shiftCandidate = false              // Shift+letter = capital, Shift+click = selection: not a tap
        if type == .keyDown { onKey(e) } else { reset() }   // mouse click moved the caret
        return true
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
                convert()                   // synchronously: from here on, typed keys are held back
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
        if buf.isEmpty, let u = undo {
            // Second tap right after a selection conversion: put the original text back.
            undo = nil
            busy = true
            guard let data = Layouts.data(target) else { busy = false; return }
            replaceText(erase: u.typed.count, with: u.original, target: target, data: data, remember: nil)
            return
        }
        if buf.isEmpty {
            // Nothing typed since the caret last moved. Selecting text always moves it (click, Shift+arrows, ⌘A),
            // so a selection now is the user's — convert it. A "selection" while the buffer is non-empty is inline
            // autocomplete and is ignored: the typed word wins.
            busy = true
            let noSelection = {
                self.expectedID = targetID
                TISSelectInputSource(target)       // no selection: just switch the layout
                self.replayHeld()
            }
            selectionQueue.async {
                switch Selection.probe() {
                case .text(let sel):
                    DispatchQueue.main.async { if !self.convertSelection(sel) { noSelection() } }
                case .opaque(let app):
                    log("selection: app exposes no accessibility tree, trying the service")
                    DispatchQueue.main.async { self.servicePending = true }
                    let pressed = Selection.pressService(in: app)
                    // The service call (if there is a selection) arrives on main; otherwise give up shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + (pressed ? 0.4 : 0)) {
                        guard self.servicePending else { return }
                        self.servicePending = false
                        noSelection()
                    }
                case .none:
                    DispatchQueue.main.async { noSelection() }
                }
            }
            return
        }
        expectedID = targetID
        let strokes = buf
        guard let layout = Layouts.data(target) else { return }
        // A trailing dead key is shown as a pending accent; one Backspace cancels it too.
        let erase = strokes.filter(\.onScreen).count + (strokes.last?.onScreen == false ? 1 : 0)
        // Key code + its Unicode string for the target layout. Keys that are dead in the target layout are sent
        // as pure Unicode (key code 0 with a string) so the app doesn't start an accent composition.
        let typed: [(CGKeyCode, CGEventFlags, String)] = strokes.map {
            (Layouts.isDeadKey($0, layout) ? 0 : $0.key, $0.shift ? .maskShift : [], Layouts.translate($0, layout))
        }
        busy = true
        deadState = 0
        let t0 = ProcessInfo.processInfo.systemUptime
        TISSelectInputSource(target)
        waitForLayout(targetID, tries: 20) {
            let t1 = ProcessInfo.processInfo.systemUptime
            self.postQueue.async {
                let src = CGEventSource(stateID: .privateState)
                for _ in 0..<erase { Self.post(src, kBackspace, [], nil) }
                for (key, flags, str) in typed { Self.post(src, key, flags, str) }
                let t2 = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    log(String(format: "convert: %d keys, erase %d, layout wait %.0f ms, retype %.0f ms, held %d",
                               strokes.count, erase, (t1 - t0) * 1000, (t2 - t1) * 1000, self.held.count))
                    self.replayHeld()
                }
            }
        }
    }

    /// Re-post held keys in order (plain key codes: they type in the new layout), then end the conversion.
    /// Keys typed during the replay are held too and go out in the next round, so order is always preserved.
    private func replayHeld() {
        guard !held.isEmpty else { busy = false; return }
        let batch = held
        held.removeAll()
        postQueue.async {
            let src = CGEventSource(stateID: .privateState)
            for (key, flags) in batch {
                for down in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
                    ev.flags = flags
                    ev.setIntegerValueField(.eventSourceUserData, value: kReplay)
                    ev.post(tap: .cghidEventTap)
                    usleep(1_500)
                }
            }
            DispatchQueue.main.async { self.replayHeld() }
        }
    }

    /// Retype the selection in the other layout (typing replaces a selection in any editor — no clipboard), then
    /// select the result again so another tap converts it back. Returns false if there is nothing to change.
    private func convertSelection(_ text: String) -> Bool {
        guard let other = Layouts.other(previous: previousID),
              let curData = Layouts.data(Layouts.current()), let otherData = Layouts.data(other) else { return false }
        let r = Layouts.convertText(text, (Layouts.current(), curData), (other, otherData))
        guard r.text != text else { return false }
        // Typing replaces the selection; the caret ends up after the new text, ready to keep typing.
        replaceText(erase: 0, with: r.text, target: r.target, data: r.targetData, remember: text)
        return true
    }

    /// Switch to `target`, erase `erase` characters, type `text` (Unicode events; line breaks as Shift+Return so
    /// chats don't send). `remember` = the text being replaced, kept for an undo by the next tap.
    private func replaceText(erase: Int, with text: String, target: TISInputSource, data: Data, remember: String?) {
        let dstMap = Layouts.charMap(data)
        let typed: [(CGKeyCode, CGEventFlags, String?)] = text.map { ch in
            if ch == "\n" || ch == "\r\n" || ch == "\r" { return (CGKeyCode(kVK_Return), .maskShift, nil) }
            guard let st = dstMap[ch], !Layouts.isDeadKey(st, data) else { return (0, [], String(ch)) }
            return (st.key, st.shift ? .maskShift : [], String(ch))
        }
        let targetID = Layouts.id(target)
        expectedID = targetID
        reset()
        let t0 = ProcessInfo.processInfo.systemUptime
        TISSelectInputSource(target)
        waitForLayout(targetID, tries: 20) {
            self.postQueue.async {
                let src = CGEventSource(stateID: .privateState)
                for _ in 0..<erase { Self.post(src, kBackspace, [], nil) }
                for (key, flags, str) in typed { Self.post(src, key, flags, str) }
                let t1 = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    log(String(format: "text: erase %d, type %d, %.0f ms, held %d", erase, typed.count, (t1 - t0) * 1000, self.held.count))
                    if let remember { self.undo = (text, remember) }
                    self.replayHeld()   // replayed keys clear `undo` again, as any typing does
                }
            }
        }
    }

    /// "ShiftSwitch: Convert Layout" service: the app gave us its selection; return it converted — the app
    /// replaces the selection itself. Works from the Services menu too, not only via our Shift fallback.
    func serviceConvert(_ text: String) -> String? {
        let fromTap = servicePending
        servicePending = false
        defer { if fromTap { replayHeld() } }
        guard let other = Layouts.other(previous: previousID),
              let curData = Layouts.data(Layouts.current()), let otherData = Layouts.data(other) else { return nil }
        let r = Layouts.convertText(text, (Layouts.current(), curData), (other, otherData))
        guard r.text != text else { return nil }
        expectedID = Layouts.id(r.target)
        reset()
        TISSelectInputSource(r.target)
        // No undo record here: we can't see whether the app really replaced its selection (Chromium may hand us a
        // selection that was collapsed a moment ago and then insert nothing), and undo erases with Backspace.
        log("service: \(text.count) chars")
        return r.text
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

/// NSServices entry point (see NSServices in Info.plist).
private final class ServiceProvider: NSObject {
    let engine: Engine
    init(_ engine: Engine) { self.engine = engine }

    @objc func convertLayout(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), let out = engine.serviceConvert(text) else { return }
        pboard.clearContents()
        pboard.setString(out, forType: .string)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = Engine()
    private var item: NSStatusItem!
    private var timer: Timer?
    private var shownSymbol = ""
    private let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: L("Включено", "Enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: L("Запускать при входе", "Launch at Login"), action: #selector(toggleLogin),
                                       keyEquivalent: "")

    private lazy var services = ServiceProvider(engine)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
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
        menu.addItem(withTitle: L("Разрешения…", "Permissions…"), action: #selector(openAX),
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
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }   // adds us to Input Monitoring + prompts
        // Poll: start the tap once permission is granted; keep the icon in sync with Secure Input.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 1
        tick()
    }

    private enum State { case noAccess, noInputMonitoring, secureInput, disabled, active }

    private var state: State {
        if !engine.tapActive { return .noAccess }
        if !CGPreflightListenEventAccess() { return .noInputMonitoring }   // without it keyDowns never reach the tap
        if SecureInput.isOn { return .secureInput }
        return engine.enabled ? .active : .disabled
    }

    private func tick() {
        if !engine.tapActive && AXIsProcessTrusted() { engine.start() }
        let symbol = switch state {
        case .noAccess, .noInputMonitoring: "exclamationmark.triangle"
        case .secureInput: "lock.fill"
        case .disabled: "shiftkey.disabled"
        case .active: "shiftkey"
        }
        guard symbol != shownSymbol else { return }
        shownSymbol = symbol
        item.button?.image = symbol.hasPrefix("shiftkey")
            ? Self.shiftKeyIcon(alpha: state == .active ? 1 : 0.35)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: "ShiftSwitch")
        item.button?.image?.isTemplate = true
    }

    /// Menu bar glyph matching the app icon: a keycap outline with a Shift arrow (template, adapts to light/dark).
    private static func shiftKeyIcon(alpha: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.withAlphaComponent(alpha).set()
            let cap = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 15), xRadius: 4, yRadius: 4)
            cap.lineWidth = 1.5
            cap.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 13.5))
            arrow.line(to: NSPoint(x: 13.5, y: 9))
            arrow.line(to: NSPoint(x: 11, y: 9))
            arrow.line(to: NSPoint(x: 11, y: 5))
            arrow.line(to: NSPoint(x: 7, y: 5))
            arrow.line(to: NSPoint(x: 7, y: 9))
            arrow.line(to: NSPoint(x: 4.5, y: 9))
            arrow.close()
            arrow.lineWidth = 1.3
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        status.title = switch state {
        case .noAccess: L("Нет доступа Accessibility", "No Accessibility permission")
        case .noInputMonitoring: L("Нет доступа «Мониторинг ввода»", "No Input Monitoring permission")
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
        let pane = state == .noInputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
