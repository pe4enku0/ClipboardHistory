import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let prefs = Preferences.shared
    let permissions = PermissionState.shared
    let store = ClipStore()
    let state = PanelState()
    lazy var monitor = ClipboardMonitor(store: store)
    lazy var autoClipboard = AutoClipboard(store: store, monitor: monitor)
    let hotKey = HotKey()
    let feedback = ScreenshotFeedback()
    let markup = SystemMarkup()
    var editorWindow: NSWindow?
    // Where to paste when our own app had to be activated (e.g. opened from Finder)
    var previousApp: NSRunningApplication?
    var statusItem: NSStatusItem!
    var panel: KeyPanel!
    var keyMonitor: Any?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var limitsTimer: Timer?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = Self.launchedAsLoginItem()
        store.applyLimits()
        monitor.start()
        autoClipboard.onScreenshot = { [weak self] file in
            if self?.prefs.screenshotFeedback == true { self?.feedback.show(file: file) }
        }
        feedback.onEdit = { [weak self] file in self?.openEditor(data: try? Data(contentsOf: file), sourceURL: file) }
        autoClipboard.restart()
        setupMainMenu()
        setupStatusItem()
        setupPanel()
        hotKey.action = { [weak self] in self?.togglePanel() }
        hotKey.register(prefs.hotKey)
        observePreferences()
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store.applyLimits()
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.previousApp = app }
        }

        if !prefs.onboardingDone {
            showOnboarding()
        } else if !launchedAtLogin {
            showPanel(centered: true)
        }
    }

    // Opening the app again from Finder, Launchpad or Spotlight shows the history
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingWindow == nil { showPanel(centered: true) }
        return false
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // @Published fires before the value is stored, so read the new value from the closure argument
    func observePreferences() {
        prefs.$hotKey.dropFirst().sink { [weak self] in self?.hotKey.register($0) }.store(in: &cancellables)
        prefs.$isRecordingShortcut.dropFirst().sink { [weak self] recording in
            guard let self else { return }
            if recording { self.hotKey.unregister() } else { self.hotKey.register(self.prefs.hotKey) }
        }.store(in: &cancellables)
        prefs.$paused.sink { [weak self] paused in
            self?.statusItem.button?.image = MenuBarIcon.image(paused: paused)
            self?.statusItem.button?.toolTip = paused ? "История буфера — запись на паузе" : "История буфера"
        }.store(in: &cancellables)
        Publishers.Merge(prefs.$historyLimit.dropFirst().map { _ in () }, prefs.$retentionDays.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.store.applyLimits() }
            .store(in: &cancellables)
        Publishers.Merge3(prefs.$autoScreenshots.dropFirst(), prefs.$autoRecordings.dropFirst(), prefs.$autoDownloads.dropFirst())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.autoClipboard.restart() }
            .store(in: &cancellables)
        // Toolbar tab titles are AppKit labels, so rebuild the settings window in the new language
        prefs.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, let window = self.settingsWindow else { return }
            let wasVisible = window.isVisible
            window.close()
            self.settingsWindow = nil
            if wasVisible { self.showSettings() }
        }.store(in: &cancellables)
    }

    // Hidden Edit menu so ⌘C/⌘V/⌘A work in text fields
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
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        let open = add(tr("Открыть историю", "Open History"), #selector(showFromMenu))
        if let key = prefs.hotKey.menuKeyEquivalent {
            open.keyEquivalent = key
            open.keyEquivalentModifierMask = prefs.hotKey.cocoaModifiers
        }
        add(tr("Пауза записи", "Pause Recording"), #selector(togglePause)).state = prefs.paused ? .on : .off
        _ = add(tr("Очистить историю", "Clear History"), #selector(clearHistory))
        menu.addItem(.separator())
        if !permissions.accessibility {
            _ = add(tr("Разрешить автовставку…", "Allow Auto-paste…"), #selector(requestAccessibility))
        }
        _ = add(tr("Настройки…", "Settings…"), #selector(showSettings), key: ",")
        _ = add(tr("О программе", "About"), #selector(showAbout))
        menu.addItem(.separator())
        _ = add(tr("Выход", "Quit"), #selector(quit), key: "q")
    }

    @objc func showFromMenu() { DispatchQueue.main.async { self.showPanel() } }
    @objc func togglePause() { prefs.paused.toggle() }
    @objc func clearHistory() { store.clearUnpinned() }
    @objc func requestAccessibility() { permissions.request() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: tr("История буфера", "Clipboard History"),
            .credits: NSAttributedString(string: tr("Как Win+V в Windows, только для Mac", "Like Win+V on Windows, made for Mac")),
        ])
    }

    // MARK: Windows

    @objc func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(prefs: prefs, store: store, permissions: permissions)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        let view = OnboardingView(model: OnboardingModel(), prefs: prefs, permissions: permissions) { [weak self] in
            self?.prefs.onboardingDone = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Panel

    func setupPanel() {
        // Non-activating panel: the app you were typing in stays active, so ⌘V lands there
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: PanelView.windowSize),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // PanelView draws a shadow that follows its rounded corners
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    func showPanel(centered: Bool = false) {
        state.tab = .clipboard
        state.selection = 0
        let actions = PanelActions(paste: { [weak self] in self?.paste($0, plainText: $1) },
                                   pasteText: { [weak self] in self?.pasteText($0) },
                                   insert: { [weak self] in self?.insert($0) },
                                   edit: { [weak self] in self?.edit($0) },
                                   openSettings: { [weak self] in self?.showSettings() })
        panel.contentView = NSHostingView(rootView: PanelView(store: store, state: state, prefs: prefs, actions: actions))
        let origin = panelOrigin(size: PanelView.size, position: centered ? .center : prefs.panelPosition)
        panel.setFrameOrigin(NSPoint(x: origin.x - PanelView.shadowMargin, y: origin.y - PanelView.shadowMargin))
        panel.makeKeyAndOrderFront(nil)

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    func panelOrigin(size: NSSize, position: PanelPosition) -> NSPoint {
        let mouse = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let anchor: NSRect
        switch position {
        // Like Windows: under the text caret, or at the mouse if the app doesn't expose it
        case .caret: anchor = Keystrokes.caretRect() ?? mouse
        case .mouse, .center: anchor = mouse
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        var origin: NSPoint
        if position == .center {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 60)
        } else {
            origin = NSPoint(x: anchor.minX - 16, y: anchor.minY - size.height - 6)
            if origin.y < visible.minY + 8 { origin.y = anchor.maxY + 6 }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }

    func hidePanel() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { hidePanel() }
    }

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
        case kVK_ANSI_Comma where event.modifierFlags.contains(.command):
            showSettings()
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
            if let selected, event.modifierFlags.contains(.option), let ocr = selected.ocrText {
                pasteText(ocr)
            } else if let selected {
                paste(selected, plainText: event.modifierFlags.contains(.shift))
            }
        case kVK_Delete where cmd:
            if let selected {
                store.remove(selected)
                state.selection = min(state.selection, max(items.count - 2, 0))
            }
        case kVK_ANSI_P where cmd:
            if let selected { store.togglePin(selected) }
        case kVK_ANSI_E where cmd:
            if let selected, selected.canEdit { edit(selected) }
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
        deliver { Keystrokes.commandV() }
    }

    func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        monitor.markOwnChange()
        hidePanel()
        deliver { Keystrokes.commandV() }
    }

    func insert(_ value: String) {
        Recents.add(value, for: state.tab)
        hidePanel()
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            return
        }
        deliver { Keystrokes.type(value) }
    }

    func edit(_ item: ClipItem) {
        openEditor(data: item.editableImageData, sourceURL: item.paths?.first.map { URL(fileURLWithPath: $0) })
    }

    func openEditor(data: Data?, sourceURL: URL?) {
        guard let data else {
            NSSound.beep()
            return
        }
        hidePanel()
        if prefs.editor == .system, openSystemMarkup(data: data, sourceURL: sourceURL) { return }
        guard let model = EditorModel(data: data, sourceURL: sourceURL) else {
            NSSound.beep()
            return
        }
        editorWindow?.close()
        let window = ScreenshotEditor.makeWindow(model: model) { [weak self] png in
            self?.editorWindow?.close()
            self?.editorWindow = nil
            self?.copyEditedImage(png)
        }
        editorWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func openSystemMarkup(data: Data, sourceURL: URL?) -> Bool {
        // Screenshots are edited in place, as macOS does; anything else on a temporary copy
        let isScreenshot = sourceURL.map { FileManager.default.fileExists(atPath: $0.path) && AutoClipboard.isScreenCapture($0) } ?? false
        guard let file = isScreenshot ? sourceURL : SystemMarkup.temporaryFile(for: data) else { return false }
        return markup.open(file) { [weak self] edited in
            let png = NSBitmapImageRep(data: edited)?.representation(using: .png, properties: [:]) ?? edited
            if isScreenshot, png != (try? Data(contentsOf: file)) { try? png.write(to: file) }
            self?.copyEditedImage(png)
        }
    }

    // Not marked as our own change, so the edited picture also lands in the history
    private func copyEditedImage(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        NSApp.hide(nil)  // back to the app you were in, ready for ⌘V
    }

    // If opening the app made it active, hand focus back to the previous app before typing into it
    private func deliver(_ keystrokes: @escaping () -> Void) {
        guard AXIsProcessTrusted() else { return }
        var delay = 0.08
        if NSApp.isActive {
            previousApp?.activate()
            delay = 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: keystrokes)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let flag = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.count > flag + 1 {
    Snapshots.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
