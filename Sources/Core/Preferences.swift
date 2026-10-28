import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int  // Carbon flags, as RegisterEventHotKey expects

    static let defaultCombo = KeyCombo(keyCode: kVK_ANSI_V, modifiers: optionKey)

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods = 0
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.command) { mods |= cmdKey }
        let key = Int(event.keyCode)
        guard Self.keyNames[key] != nil else { return nil }
        // Bare letters would break normal typing; function keys can be used alone
        guard mods & (cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(key) else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    var parts: [String] {
        var result: [String] = []
        if modifiers & controlKey != 0 { result.append("⌃") }
        if modifiers & optionKey != 0 { result.append("⌥") }
        if modifiers & shiftKey != 0 { result.append("⇧") }
        if modifiers & cmdKey != 0 { result.append("⌘") }
        result.append(Self.keyNames[keyCode] ?? "?")
        return result
    }

    var display: String { parts.joined() }

    // For showing the shortcut next to a menu item
    var menuKeyEquivalent: String? {
        guard let name = Self.keyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    // Key codes are layout independent, so names are taken from the US layout
    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-",
        kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`", kVK_ANSI_Backslash: "\\",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

enum PanelPosition: String, CaseIterable, Identifiable {
    case caret, mouse, center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caret: return tr("У текстового курсора", "At the text cursor")
        case .mouse: return tr("У указателя мыши", "At the mouse pointer")
        case .center: return tr("По центру экрана", "Center of the screen")
        }
    }
}

enum PanelStyle: String, CaseIterable, Identifiable {
    case classic, glass

    var id: String { rawValue }
    var title: String { self == .classic ? tr("Классический", "Classic") : "Liquid Glass" }

    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true } else { return false }
    }
}

struct ExcludedApp: Codable, Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var hotKey: KeyCombo { didSet { Self.store(hotKey, "hotKey") } }
    @Published var panelPosition: PanelPosition {
        didSet { UserDefaults.standard.set(panelPosition.rawValue, forKey: "panelPosition") }
    }
    @Published var historyLimit: Int { didSet { UserDefaults.standard.set(historyLimit, forKey: "historyLimit") } }
    @Published var retentionDays: Int { didSet { UserDefaults.standard.set(retentionDays, forKey: "retentionDays") } }
    @Published var saveImages: Bool { didSet { UserDefaults.standard.set(saveImages, forKey: "saveImages") } }
    @Published var paused: Bool { didSet { UserDefaults.standard.set(paused, forKey: "paused") } }
    @Published var excludedApps: [ExcludedApp] { didSet { Self.store(excludedApps, "excludedApps") } }
    @Published var onboardingDone: Bool { didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var launchAtLogin: Bool { didSet { updateLoginItem() } }
    @Published var language: AppLanguage { didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") } }
    @Published var panelStyle: PanelStyle { didSet { UserDefaults.standard.set(panelStyle.rawValue, forKey: "panelStyle") } }
    @Published var autoScreenshots: Bool { didSet { UserDefaults.standard.set(autoScreenshots, forKey: "autoScreenshots") } }
    @Published var autoRecordings: Bool { didSet { UserDefaults.standard.set(autoRecordings, forKey: "autoRecordings") } }
    @Published var autoDownloads: Bool { didSet { UserDefaults.standard.set(autoDownloads, forKey: "autoDownloads") } }
    @Published var recognizeText: Bool { didSet { UserDefaults.standard.set(recognizeText, forKey: "recognizeText") } }
    @Published var isRecordingShortcut = false

    var excludedBundleIDs: Set<String> { Set(excludedApps.map(\.bundleID)) }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "historyLimit": 50, "retentionDays": 0, "saveImages": true, "panelPosition": PanelPosition.caret.rawValue,
            "autoScreenshots": true, "autoRecordings": true, "autoDownloads": true, "recognizeText": true,
        ])
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        panelStyle = PanelStyle(rawValue: defaults.string(forKey: "panelStyle") ?? "") ?? .classic
        autoScreenshots = defaults.bool(forKey: "autoScreenshots")
        autoRecordings = defaults.bool(forKey: "autoRecordings")
        autoDownloads = defaults.bool(forKey: "autoDownloads")
        recognizeText = defaults.bool(forKey: "recognizeText")
        hotKey = Self.load("hotKey") ?? .defaultCombo
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: "panelPosition") ?? "") ?? .caret
        historyLimit = defaults.integer(forKey: "historyLimit")
        retentionDays = defaults.integer(forKey: "retentionDays")
        saveImages = defaults.bool(forKey: "saveImages")
        paused = defaults.bool(forKey: "paused")
        excludedApps = Self.load("excludedApps") ?? []
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard launchAtLogin != enabled else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Не удалось изменить автозапуск", "Couldn’t change the login item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            DispatchQueue.main.async { self.launchAtLogin = enabled }
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

// Accessibility can be granted at any time in System Settings, so keep checking
final class PermissionState: ObservableObject {
    static let shared = PermissionState()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let trusted = AXIsProcessTrusted()
            if self?.accessibility != trusted { self?.accessibility = trusted }
        }
    }

    func request() {
        // The prompt adds the app to the list in System Settings, then the user only flips the switch
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
