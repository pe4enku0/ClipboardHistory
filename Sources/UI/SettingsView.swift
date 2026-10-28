import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let settingsSize = CGSize(width: 520, height: 400)

struct GeneralSettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker(tr("Язык", "Language"), selection: $prefs.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Toggle(tr("Запускать при входе в систему", "Open at login"), isOn: $prefs.launchAtLogin)
            }
            Section(tr("Горячая клавиша", "Shortcut")) {
                LabeledContent(tr("Открыть историю", "Open history")) { ShortcutRecorder(prefs: prefs) }
            }
            Section {
                Picker(tr("Оформление", "Style"), selection: $prefs.panelStyle) {
                    ForEach(PanelStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!PanelStyle.glassAvailable)
                Picker(tr("Показывать окно", "Show window"), selection: $prefs.panelPosition) {
                    ForEach(PanelPosition.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(tr("Окно", "Window"))
            } footer: {
                if !PanelStyle.glassAvailable {
                    Text(tr("Liquid Glass доступен на macOS 26 и новее.", "Liquid Glass needs macOS 26 or later."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsSize.width, height: settingsSize.height)
    }
}

struct HistorySettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var store: ClipStore

    var body: some View {
        Form {
            Section {
                Picker(tr("Хранить записей", "Keep items"), selection: $prefs.historyLimit) {
                    ForEach([25, 50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker(tr("Удалять записи старше", "Remove items older than"), selection: $prefs.retentionDays) {
                    Text(tr("Никогда", "Never")).tag(0)
                    Text(tr("1 дня", "1 day")).tag(1)
                    Text(tr("7 дней", "7 days")).tag(7)
                    Text(tr("30 дней", "30 days")).tag(30)
                }
                Toggle(tr("Сохранять картинки", "Save images"), isOn: $prefs.saveImages)
            } footer: {
                Text(tr("Закреплённые записи не удаляются автоматически.", "Pinned items are never removed automatically."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(tr("Пауза записи", "Pause recording"), isOn: $prefs.paused)
                LabeledContent(tr("Сейчас в истории", "Items in history")) { Text("\(store.items.count)") }
                Button(tr("Очистить историю…", "Clear History…"), role: .destructive, action: confirmClear)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsSize.width, height: settingsSize.height)
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = tr("Очистить историю?", "Clear history?")
        alert.informativeText = tr("Закреплённые записи останутся.", "Pinned items will stay.")
        alert.addButton(withTitle: tr("Очистить", "Clear"))
        alert.addButton(withTitle: tr("Отмена", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }
}

struct AutoClipboardSettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $prefs.autoScreenshots) {
                    settingLabel(tr("Скриншоты", "Screenshots"), "camera.viewfinder", .indigo,
                                 tr("⌘⇧3, ⌘⇧4 и ⌘⇧5", "⌘⇧3, ⌘⇧4 and ⌘⇧5"))
                }
                Toggle(isOn: $prefs.instantScreenshots) {
                    settingLabel(tr("Сохранять скриншот сразу", "Save screenshots instantly"), "bolt.fill", .yellow,
                                 tr("Без миниатюры в углу: ⌘V работает через секунду, а не через 5",
                                    "No thumbnail in the corner: ⌘V works in a second instead of 5"))
                }
                .disabled(!prefs.autoScreenshots)
                Toggle(isOn: $prefs.screenshotFeedback) {
                    settingLabel(tr("Вспышка и превью", "Flash and preview"), "sparkles", .orange,
                                 tr("Карточка в углу с кнопкой «Изменить»", "A card in the corner with an Edit button"))
                }
                .disabled(!prefs.autoScreenshots)
                Toggle(isOn: $prefs.autoRecordings) {
                    settingLabel(tr("Записи экрана", "Screen recordings"), "record.circle", .red,
                                 tr("Видео из ⌘⇧5", "Videos from ⌘⇧5"))
                }
                Toggle(isOn: $prefs.autoDownloads) {
                    settingLabel(tr("Новые загрузки", "New downloads"), "arrow.down.circle", .green,
                                 tr("Файлы из папки «Загрузки»", "Files in your Downloads folder"))
                }
            } header: {
                Text(tr("Сразу в буфер", "Straight to the clipboard"))
            } footer: {
                Text(tr("Новый файл сразу можно вставить через ⌘V. Сам файл остаётся там, где его сохранила macOS.",
                        "A new file is ready to paste with ⌘V right away. The file itself stays where macOS saved it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $prefs.recognizeText) {
                    settingLabel(tr("Распознавать текст на картинках", "Recognize text in images"), "text.viewfinder", .blue,
                                 tr("Поиск по тексту и вставка текстом. Работает без интернета.",
                                    "Search by text and paste it as text. Works offline."))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsSize.width, height: settingsSize.height)
    }
}

struct PrivacySettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var permissions: PermissionState

    var body: some View {
        Form {
            Section {
                HStack {
                    Label(permissions.accessibility ? tr("Доступ разрешён", "Access granted") : tr("Нет доступа", "No access"),
                          systemImage: permissions.accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissions.accessibility ? Color.green : Color.orange)
                    Spacer()
                    if !permissions.accessibility {
                        Button(tr("Разрешить…", "Allow…")) { permissions.request() }
                    }
                }
            } header: {
                Text(tr("Автовставка", "Auto-paste"))
            } footer: {
                Text(tr("Нужна, чтобы выбранное сразу вставлялось в текст. Без неё запись только копируется в буфер.",
                        "Lets the chosen item be pasted right into your text. Without it, items are only copied."))
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
                        .help(tr("Убрать из списка", "Remove from list"))
                    }
                }
                Button(tr("Добавить приложение…", "Add App…"), action: addApp)
            } header: {
                Text(tr("Не сохранять из приложений", "Ignore these apps"))
            } footer: {
                Text(tr("Пароли из менеджеров паролей не сохраняются никогда.", "Passwords from password managers are never saved."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsSize.width, height: settingsSize.height)
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
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(tr("История буфера", "Clipboard History")).font(.title2.bold())
            Text(tr("Версия", "Version") + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
                .foregroundStyle(.secondary)
            Text(tr("Всё, что вы копируете, — под рукой.\nКак Win+V в Windows, только для Mac.",
                    "Everything you copy, always at hand.\nLike Win+V on Windows, made for Mac."))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Text(tr("История хранится только на этом Mac и никуда не отправляется.",
                    "Your history stays on this Mac and is never sent anywhere."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(width: settingsSize.width, height: settingsSize.height)
    }
}

private func settingLabel(_ title: String, _ symbol: String, _ tint: Color, _ detail: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
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
        add(tr("Основные", "General"), "gearshape", GeneralSettingsView(prefs: prefs))
        add(tr("История", "History"), "clock.arrow.circlepath", HistorySettingsView(prefs: prefs, store: store))
        add(tr("Авто-буфер", "Auto-copy"), "camera.viewfinder", AutoClipboardSettingsView(prefs: prefs))
        add(tr("Конфиденциальность", "Privacy"), "hand.raised", PrivacySettingsView(prefs: prefs, permissions: permissions))
        add(tr("О программе", "About"), "info.circle", AboutSettingsView(prefs: prefs))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
