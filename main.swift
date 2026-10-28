import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Global hotkey (Carbon API needs no extra permissions)

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434C_4950), id: 1) // 'CLIP'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Sending keystrokes to the frontmost app (needs Accessibility)

enum Keystrokes {
    static func commandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Types text directly, so emoji and symbols don't end up in the clipboard history
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var start = 0
        while start < utf16.count {
            var end = min(start + 16, utf16.count)
            if end < utf16.count, UTF16.isLeadSurrogate(utf16[end - 1]) { end -= 1 }
            let chunk = Array(utf16[start..<end])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            start = end
        }
    }

    // Text caret position of the focused field, in Cocoa screen coordinates
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success,
              let bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        // AX uses a top-left origin on the primary screen
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.contains { $0.frame.intersects(flipped) } ? flipped : nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let store = ClipStore()
    let state = PanelState()
    lazy var monitor = ClipboardMonitor(store: store)
    var statusItem: NSStatusItem!
    var panel: KeyPanel!
    var hotKey: HotKey?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.start()
        setupMainMenu()
        setupStatusItem()
        setupPanel()
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: optionKey) { [weak self] in self?.togglePanel() }
        // Auto-paste needs Accessibility; without it items are just copied
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // Hidden Edit menu so ⌘C/⌘V/⌘A work in the search field
    func setupMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "История буфера")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add("Показать историю  ⌥V", #selector(showFromMenu))
        _ = add("Очистить историю", #selector(clearHistory))
        menu.addItem(.separator())
        add("Запускать при входе", #selector(toggleLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        if !AXIsProcessTrusted() {
            _ = add("Разрешить автовставку…", #selector(openAccessibility))
        }
        menu.addItem(.separator())
        _ = add("Выход", #selector(quit), key: "q")
    }

    @objc func showFromMenu() { DispatchQueue.main.async { self.showPanel() } }
    @objc func clearHistory() { store.clearUnpinned() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Panel

    func setupPanel() {
        // Non-activating panel: the app you were typing in stays active, so ⌘V lands there
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    func showPanel() {
        state.tab = .clipboard
        state.selection = 0
        let actions = PanelActions(paste: { [weak self] in self?.paste($0, plainText: $1) },
                                   insert: { [weak self] in self?.insert($0) })
        panel.contentView = NSHostingView(rootView: PanelView(store: store, state: state, actions: actions))

        // Like Windows: open under the text caret, or at the mouse if the app doesn't expose it
        let anchor = Keystrokes.caretRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = NSPoint(x: anchor.minX - 16, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY + 8 { origin.y = anchor.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { hidePanel() }

    // MARK: Keyboard

    private let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                             kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    func handleKey(_ event: NSEvent) -> Bool {
        let key = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case kVK_Escape:
            hidePanel()
            return true
        case kVK_Tab:
            let tabs = PanelTab.allCases
            state.tab = tabs[(state.tab.rawValue + (shift ? tabs.count - 1 : 1)) % tabs.count]
            return true
        default:
            break
        }
        return state.tab == .clipboard ? handleClipboardKey(event) : handlePickerKey(key)
    }

    // Key codes, not characters, so shortcuts work in any keyboard layout
    func handleClipboardKey(_ event: NSEvent) -> Bool {
        let items = state.filterClips(store.items)
        let selected = items.indices.contains(state.selection) ? items[state.selection] : nil
        let cmd = event.modifierFlags.contains(.command)
        let key = Int(event.keyCode)

        switch key {
        case kVK_DownArrow:
            state.selection = min(state.selection + 1, max(items.count - 1, 0))
        case kVK_UpArrow:
            state.selection = max(state.selection - 1, 0)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selected { paste(selected, plainText: event.modifierFlags.contains(.shift)) }
        case kVK_Delete where cmd:
            if let selected {
                store.remove(selected)
                state.selection = min(state.selection, max(items.count - 2, 0))
            }
        case kVK_ANSI_P where cmd:
            if let selected { store.togglePin(selected) }
        default:
            guard cmd, let n = digitKeys.firstIndex(of: key) else { return false }
            if items.indices.contains(n) { paste(items[n], plainText: false) }
        }
        return true
    }

    func handlePickerKey(_ key: Int) -> Bool {
        let picks = state.flatPicks()
        let columns = state.tab.columns
        func move(_ delta: Int) {
            state.selection = min(max(state.selection + delta, 0), max(picks.count - 1, 0))
        }
        switch key {
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_UpArrow: move(-columns)
        case kVK_DownArrow: move(columns)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if picks.indices.contains(state.selection) { insert(picks[state.selection]) }
        default:
            return false
        }
        return true
    }

    // MARK: Actions

    func paste(_ item: ClipItem, plainText: Bool) {
        item.write(to: NSPasteboard.general, plainText: plainText)
        monitor.markOwnChange()
        store.moveToTop(item)
        hidePanel()
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Keystrokes.commandV() }
    }

    func insert(_ value: String) {
        Recents.add(value, for: state.tab)
        hidePanel()
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Keystrokes.type(value) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
