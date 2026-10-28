import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: $prefs.launchAtLogin)
            }
            Section("Горячая клавиша") {
                LabeledContent("Открыть историю") { ShortcutRecorder(prefs: prefs) }
            }
            Section("Окно") {
                Picker("Показывать окно", selection: $prefs.panelPosition) {
                    ForEach(PanelPosition.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 360)
    }
}

struct HistorySettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var store: ClipStore

    var body: some View {
        Form {
            Section {
                Picker("Хранить записей", selection: $prefs.historyLimit) {
                    ForEach([25, 50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Удалять записи старше", selection: $prefs.retentionDays) {
                    Text("Никогда").tag(0)
                    Text("1 дня").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                }
                Toggle("Сохранять картинки", isOn: $prefs.saveImages)
            } footer: {
                Text("Закреплённые записи не удаляются автоматически.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Пауза записи", isOn: $prefs.paused)
                LabeledContent("Сейчас в истории") { Text("\(store.items.count)") }
                Button("Очистить историю…", role: .destructive, action: confirmClear)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 360)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Очистить историю?"
        alert.informativeText = "Закреплённые записи останутся."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }
}

struct PrivacySettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var permissions: PermissionState

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(permissions.accessibility ? "Доступ разрешён" : "Нет доступа",
                          systemImage: permissions.accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissions.accessibility ? Color.green : Color.orange)
                    Spacer()
                    if !permissions.accessibility {
                        Button("Разрешить…") { permissions.request() }
                    }
                }
            } header: {
                Text("Автовставка")
            } footer: {
                Text("Нужна, чтобы выбранное сразу вставлялось в текст. Без неё запись только копируется в буфер.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(prefs.excludedApps) { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                        Spacer()
                        Button { prefs.excludedApps.removeAll { $0 == app } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Убрать из списка")
                    }
                }
                Button("Добавить приложение…", action: addApp)
            } header: {
                Text("Не сохранять из приложений")
            } footer: {
                Text("Пароли из менеджеров паролей не сохраняются никогда.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 360)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !prefs.excludedBundleIDs.contains(id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            prefs.excludedApps.append(ExcludedApp(bundleID: id, name: name, path: url.path))
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("История буфера").font(.title2.bold())
            Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Всё, что вы копируете, — под рукой.\nКак Win+V в Windows, только для Mac.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Text("История хранится только на этом Mac и никуда не отправляется.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(width: 500, height: 360)
    }
}

enum SettingsWindow {
    static func make(prefs: Preferences, store: ClipStore, permissions: PermissionState) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let item = NSTabViewItem(viewController: NSHostingController(rootView: view))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Основные", "gearshape", GeneralSettingsView(prefs: prefs))
        add("История", "clock.arrow.circlepath", HistorySettingsView(prefs: prefs, store: store))
        add("Конфиденциальность", "hand.raised", PrivacySettingsView(prefs: prefs, permissions: permissions))
        add("О программе", "info.circle", AboutSettingsView())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
