import AppKit
import SwiftUI

// `ClipboardHistory --snapshots <dir>` renders every screen with sample data into PNGs and exits.
// Used to review the design and as a base for App Store screenshots.
enum Snapshots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = Preferences.shared
        let store = sampleStore()
        let noActions = PanelActions(paste: { _, _ in }, insert: { _ in }, openSettings: {})

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            func save<V: View>(_ file: String, _ size: NSSize, _ view: V) {
                render(view, size: size, appearance: appearance, to: dir.appendingPathComponent("\(file)-\(name).png"))
            }
            let state = PanelState()
            save("panel", NSSize(width: 380, height: 500), PanelView(store: store, state: state, prefs: prefs, actions: noActions))
            let emoji = PanelState()
            emoji.tab = .emoji
            save("panel-emoji", NSSize(width: 380, height: 500), PanelView(store: store, state: emoji, prefs: prefs, actions: noActions))

            for step in 0...3 {
                let model = OnboardingModel()
                model.step = step
                save("onboarding-\(step)", NSSize(width: 560, height: 480),
                     OnboardingView(model: model, prefs: prefs, permissions: .shared) {})
            }
            let settingsSize = NSSize(width: 500, height: 360)
            save("settings-general", settingsSize, GeneralSettingsView(prefs: prefs))
            save("settings-history", settingsSize, HistorySettingsView(prefs: prefs, store: store))
            save("settings-privacy", settingsSize, PrivacySettingsView(prefs: prefs, permissions: .shared))
            save("settings-about", settingsSize, AboutSettingsView())
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    // Never saved: items are only assigned in memory
    private static func sampleStore() -> ClipStore {
        let store = ClipStore()
        func item(_ kind: ClipItem.Kind, _ text: String, minutesAgo: Double, app: String, pinned: Bool = false,
                  paths: [String]? = nil, thumbnail: Data? = nil) -> ClipItem {
            ClipItem(date: Date().addingTimeInterval(-minutesAgo * 60), pinned: pinned, kind: kind, text: text,
                     paths: paths, thumbnail: thumbnail, digest: UUID().uuidString, sourceBundleID: app,
                     sourceAppName: nil, representations: [])
        }
        let picture = NSApp.applicationIconImage.thumbnailPNG(maxSide: 360)
        store.items = [
            item(.text, "Встреча в 15:00 у главного входа. Не забудь ноутбук и зарядку!", minutesAgo: 0.2, app: "com.apple.Notes"),
            item(.text, "https://github.com/pe4enku0/ClipboardHistory", minutesAgo: 3, app: "com.apple.Safari"),
            item(.image, "", minutesAgo: 12, app: "com.apple.Preview", pinned: true, thumbnail: picture),
            item(.text, "#4A6CF7", minutesAgo: 25, app: "com.apple.TextEdit"),
            item(.text, "let total = items.reduce(0) { $0 + $1.price }\nprint(total)", minutesAgo: 48, app: "com.apple.dt.Xcode"),
            item(.files, "Отчёт за октябрь.pdf", minutesAgo: 90, app: "com.apple.finder", paths: ["/tmp/Отчёт за октябрь.pdf"]),
        ]
        return store
    }
}
