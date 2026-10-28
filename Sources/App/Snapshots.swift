import AppKit
import SwiftUI

// `ClipboardHistory --snapshots <dir>` renders every screen with sample data into PNGs and exits.
// Used to review the design and as a base for App Store screenshots.
enum Snapshots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = Preferences.shared
        let savedLanguage = prefs.language
        defer { prefs.language = savedLanguage }
        let store = sampleStore()
        let noActions = PanelActions(paste: { _, _ in }, pasteText: { _ in }, insert: { _ in }, edit: { _ in },
                                     openSettings: {})

        for language in [AppLanguage.ru, .en] {
            prefs.language = language
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                func save<V: View>(_ file: String, _ size: NSSize, _ view: V) {
                    render(view, size: size, appearance: appearance,
                           to: dir.appendingPathComponent("\(file)-\(language.rawValue)-\(theme).png"))
                }
                save("panel", PanelView.windowSize, PanelView(store: store, state: PanelState(), prefs: prefs, actions: noActions))
                let emoji = PanelState()
                emoji.tab = .emoji
                save("panel-emoji", PanelView.windowSize, PanelView(store: store, state: emoji, prefs: prefs, actions: noActions))

                for step in 0...3 {
                    let model = OnboardingModel()
                    model.step = step
                    save("onboarding-\(step)", NSSize(width: 560, height: 480),
                         OnboardingView(model: model, prefs: prefs, permissions: .shared) {})
                }
                let settingsSize = NSSize(width: 520, height: 400)
                save("settings-general", settingsSize, GeneralSettingsView(prefs: prefs))
                save("settings-history", settingsSize, HistorySettingsView(prefs: prefs, store: store))
                save("settings-auto", settingsSize, AutoClipboardSettingsView(prefs: prefs))
                save("settings-privacy", settingsSize, PrivacySettingsView(prefs: prefs, permissions: .shared))
                save("settings-about", settingsSize, AboutSettingsView(prefs: prefs))

                if let png = pngData(of: NSApp.applicationIconImage, pixels: 1024),
                   let model = EditorModel(data: png, sourceURL: nil) {
                    model.annotations = [
                        Annotation(kind: .arrow(CGPoint(x: 120, y: 900), CGPoint(x: 330, y: 640)), color: .systemRed, width: 9),
                        Annotation(kind: .rectangle(CGRect(x: 600, y: 240, width: 300, height: 200)), color: .systemYellow, width: 9),
                        Annotation(kind: .blur(CGRect(x: 380, y: 330, width: 200, height: 120)), color: .black, width: 1),
                        Annotation(kind: .text(tr("Важно!", "Important!"), CGPoint(x: 120, y: 120)), color: .systemRed, width: 60),
                    ]
                    save("editor", NSSize(width: 900, height: 640), EditorView(model: model, onDone: { _ in }))
                    try? model.exportPNG()?.write(to: dir.appendingPathComponent("editor-export-\(language.rawValue)-\(theme).png"))
                }
                if let image = NSApp.applicationIconImage.thumbnailPNG(maxSide: 400).flatMap(NSImage.init(data:)) {
                    save("toast", NSSize(width: 370, height: 130),
                         ScreenshotToast(image: image, file: URL(fileURLWithPath: "/tmp/x.png"),
                                         onEdit: {}, onClose: {}, onHover: { _ in }))
                }
            }
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

    // NSImage.size of an app icon is in points (often 128), so draw it into an exact pixel size
    private static func pngData(of image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // Never saved: items are only assigned in memory
    private static func sampleStore() -> ClipStore {
        let store = ClipStore(persistent: false)
        func item(_ kind: ClipItem.Kind, _ text: String, minutesAgo: Double, app: String?, pinned: Bool = false,
                  paths: [String]? = nil, thumbnail: Data? = nil, origin: ClipItem.Origin? = nil,
                  ocr: String? = nil, size: (Int, Int)? = nil) -> ClipItem {
            let name = app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            return ClipItem(date: Date().addingTimeInterval(-minutesAgo * 60), pinned: pinned, kind: kind, text: text,
                            paths: paths, thumbnail: thumbnail, digest: UUID().uuidString, sourceBundleID: app,
                            sourceAppName: name, origin: origin, ocrText: ocr, imageWidth: size?.0, imageHeight: size?.1,
                            representations: [])
        }
        let picture = NSApp.applicationIconImage.thumbnailPNG(maxSide: 360)
        store.items = [
            item(.text, "Встреча в 15:00 у главного входа. Не забудь ноутбук и зарядку!", minutesAgo: 0.2, app: "com.apple.Notes"),
            item(.image, "", minutesAgo: 2, app: ClipItem.screenshotAppID, paths: ["/tmp/Screenshot.png"], thumbnail: picture,
                 origin: .screenshot, ocr: "Clipboard History", size: (3420, 2224)),
            item(.text, "https://github.com/pe4enku0/ClipboardHistory", minutesAgo: 3, app: "com.apple.Safari"),
            item(.text, "Адрес доставки: ул. Ленина, 1, кв. 5", minutesAgo: 400, app: "com.apple.Notes", pinned: true),
            item(.text, "#4A6CF7", minutesAgo: 25, app: "com.apple.TextEdit"),
            item(.text, "let total = items.reduce(0) { $0 + $1.price }\nprint(total)", minutesAgo: 48, app: "com.apple.dt.Xcode"),
            item(.files, "Отчёт за октябрь.pdf", minutesAgo: 90, app: nil, paths: ["/tmp/Отчёт за октябрь.pdf"], origin: .download),
        ]
        return store
    }
}
