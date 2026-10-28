import AppKit
import SwiftUI

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// Stacked cards, matching the app icon; template so macOS tints it for light/dark menu bars
enum MenuBarIcon {
    static func image(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: NSRect(x: 6.3, y: 4.8, width: 9.5, height: 11.5), xRadius: 2.2, yRadius: 2.2)
            back.lineWidth = 1.4
            back.stroke()

            // Knock out the overlap so the front card sits on top
            let front = NSRect(x: 2.2, y: 1.7, width: 9.5, height: 11.5)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: front.insetBy(dx: -1.3, dy: -1.3), xRadius: 3.3, yRadius: 3.3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let frontPath = NSBezierPath(roundedRect: front, xRadius: 2.2, yRadius: 2.2)
            frontPath.lineWidth = 1.4
            frontPath.stroke()

            if paused {
                for x in [5.0, 7.6] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 4.6, width: 1.6, height: 5.6), xRadius: 0.8, yRadius: 0.8).fill()
                }
            } else {
                for (y, width) in [(9.4, 5.4), (6.6, 4.0), (3.8, 4.8)] {
                    NSBezierPath(roundedRect: NSRect(x: 4.2, y: y, width: width, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

enum TimeLabel {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(for date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else { return tr("только что", "just now") }
        formatter.locale = L10n.locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct KeyCaps: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .frame(minWidth: 54, minHeight: 54)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.25), radius: 0, y: 2)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.15)))
            }
        }
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shortcut recorder

final class ShortcutRecorderModel: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func toggle(onRecord: @escaping (KeyCombo) -> Void) {
        if recording { stop() } else { start(onRecord) }
    }

    private func start(_ onRecord: @escaping (KeyCombo) -> Void) {
        recording = true
        // Lets the current shortcut be pressed without it opening the panel
        Preferences.shared.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == 53 { // Escape
                self?.stop()
            } else if let combo = KeyCombo(event: event) {
                onRecord(combo)
                self?.stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Preferences.shared.isRecordingShortcut = false
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct ShortcutRecorder: View {
    @ObservedObject var prefs: Preferences
    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggle { prefs.hotKey = $0 } } label: {
                Text(model.recording ? tr("Нажмите сочетание…", "Press shortcut…") : prefs.hotKey.display)
                    .frame(minWidth: 130)
                    .foregroundStyle(model.recording ? Color.accentColor : Color.primary)
            }
            .help(model.recording ? tr("Esc — отмена", "Esc to cancel") : tr("Нажмите, чтобы изменить", "Click to change"))
            if prefs.hotKey != .defaultCombo && !model.recording {
                Button(tr("Сбросить", "Reset")) { prefs.hotKey = .defaultCombo }
                    .buttonStyle(.link)
            }
        }
    }
}
