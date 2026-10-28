import AppKit
import SwiftUI

final class OnboardingModel: ObservableObject {
    @Published var step = 0
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var permissions: PermissionState
    let finish: () -> Void
    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: WelcomeStep(prefs: prefs)
                case 1: HotKeyStep(prefs: prefs)
                case 2: PermissionStep(prefs: prefs, permissions: permissions)
                default: DoneStep(prefs: prefs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Circle()
                            .fill(i == model.step ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 7, height: 7)
                    }
                }
                if model.step == 0 {
                    Picker("", selection: $prefs.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 12)
                }
                Spacer()
                if model.step > 0 {
                    Button(tr("Назад", "Back")) { model.step -= 1 }
                        .controlSize(.large)
                }
                Button(model.step == lastStep ? tr("Начать", "Get Started") : tr("Далее", "Continue")) {
                    if model.step == lastStep { finish() } else { model.step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 560, height: 480)
        .background(VisualEffect(material: .underWindowBackground))
    }
}

private struct WelcomeStep: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text(tr("История буфера", "Clipboard History")).font(.system(size: 26, weight: .bold))
            Text(tr("Всё, что вы копируете, — всегда под рукой.\nКак Win+V в Windows, только для Mac.",
                    "Everything you copy, always at hand.\nLike Win+V on Windows, made for Mac."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "doc.on.clipboard", title: tr("Вся история", "Full history"),
                           text: tr("Текст, картинки, ссылки и файлы — с форматированием",
                                    "Text, images, links and files, formatting included"))
                FeatureRow(symbol: "camera.viewfinder", title: tr("Скриншоты сразу в буфер", "Screenshots ready to paste"),
                           text: tr("Сделали снимок — вставляйте через ⌘V", "Take a screenshot, then just press ⌘V"))
                FeatureRow(symbol: "face.smiling", title: tr("Эмодзи и символы", "Emoji and symbols"),
                           text: tr("Эмодзи, каомодзи и спецсимволы в том же окне",
                                    "Emoji, kaomoji and special characters in the same window"))
            }
            .padding(.top, 14)
        }
    }
}

private struct HotKeyStep: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 20) {
            Text(tr("Одно сочетание клавиш", "One shortcut")).font(.title2.bold())
            KeyCaps(combo: prefs.hotKey)
            Text(tr("Нажмите его в любом приложении — окно с историей откроется рядом с курсором. Стрелками выберите запись и нажмите ↩.",
                    "Press it in any app and your history opens next to the cursor. Pick an item with the arrow keys and press ↩."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack {
                Text(tr("Другое сочетание:", "Use another:")).foregroundStyle(.secondary)
                ShortcutRecorder(prefs: prefs)
            }
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var permissions: PermissionState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: permissions.accessibility ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 52))
                .foregroundStyle(permissions.accessibility ? Color.green : Color.accentColor)
            Text(tr("Разрешите автовставку", "Allow auto-paste")).font(.title2.bold())
            Text(tr("Чтобы выбранная запись сразу вставлялась в текст, включите приложение в «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ».",
                    "To paste the chosen item right into your text, turn the app on in System Settings → Privacy & Security → Accessibility."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if permissions.accessibility {
                Label(tr("Доступ разрешён", "Access granted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(tr("Открыть настройки", "Open System Settings")) { permissions.request() }
                    .controlSize(.large)
                Text(tr("Можно пропустить — тогда запись будет просто копироваться, а вставить её можно через ⌘V.",
                        "You can skip this: items will just be copied, and you paste them with ⌘V."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            Label(tr("История хранится только на этом Mac и никуда не отправляется.",
                     "Your history stays on this Mac and is never sent anywhere."), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(tr("Всё готово!", "You’re all set!")).font(.title2.bold())
            HStack(spacing: 6) {
                Text(tr("Значок", "The"))
                Image(nsImage: MenuBarIcon.image(paused: false))
                Text(tr("живёт в строке меню вверху экрана.", "icon lives in the menu bar at the top of the screen."))
            }
            .foregroundStyle(.secondary)
            Text(tr("Через него можно открыть настройки или поставить запись на паузу. А если нажать на само приложение, откроется история.",
                    "Use it to open settings or pause recording. Opening the app itself shows your history."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Toggle(tr("Запускать при входе в систему", "Open at login"), isOn: $prefs.launchAtLogin)
                .toggleStyle(.switch)
                .padding(.top, 8)
        }
    }
}
