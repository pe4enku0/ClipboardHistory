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
                case 0: WelcomeStep()
                case 1: HotKeyStep(prefs: prefs)
                case 2: PermissionStep(permissions: permissions)
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
                Spacer()
                if model.step > 0 {
                    Button("Назад") { model.step -= 1 }
                        .controlSize(.large)
                }
                Button(model.step == lastStep ? "Начать" : "Далее") {
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
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("История буфера").font(.system(size: 26, weight: .bold))
            Text("Всё, что вы копируете, — всегда под рукой.\nКак Win+V в Windows, только для Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "doc.on.clipboard", title: "Вся история",
                           text: "Текст, картинки, ссылки и файлы — с форматированием")
                FeatureRow(symbol: "face.smiling", title: "Эмодзи и символы",
                           text: "Эмодзи, каомодзи и спецсимволы в том же окне")
                FeatureRow(symbol: "pin", title: "Закрепление",
                           text: "Важное не потеряется и не удалится при очистке")
            }
            .padding(.top, 14)
        }
    }
}

private struct HotKeyStep: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 20) {
            Text("Одно сочетание клавиш").font(.title2.bold())
            KeyCaps(combo: prefs.hotKey)
            Text("Нажмите его в любом приложении — окно с историей откроется рядом с курсором. Стрелками выберите запись и нажмите ↩.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack {
                Text("Другое сочетание:").foregroundStyle(.secondary)
                ShortcutRecorder(prefs: prefs)
            }
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var permissions: PermissionState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: permissions.accessibility ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 52))
                .foregroundStyle(permissions.accessibility ? Color.green : Color.accentColor)
            Text("Разрешите автовставку").font(.title2.bold())
            Text("Чтобы выбранная запись сразу вставлялась в текст, включите приложение в «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ».")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if permissions.accessibility {
                Label("Доступ разрешён", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Открыть настройки") { permissions.request() }
                    .controlSize(.large)
                Text("Можно пропустить — тогда запись будет просто копироваться, а вставить её можно через ⌘V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            Label("История хранится только на этом Mac и никуда не отправляется.", systemImage: "lock.fill")
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
            Text("Всё готово!").font(.title2.bold())
            HStack(spacing: 6) {
                Text("Значок")
                Image(nsImage: MenuBarIcon.image(paused: false))
                Text("живёт в строке меню вверху экрана.")
            }
            .foregroundStyle(.secondary)
            Text("Через него можно открыть настройки или поставить запись на паузу.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Toggle("Запускать при входе в систему", isOn: $prefs.launchAtLogin)
                .toggleStyle(.switch)
                .padding(.top, 8)
        }
    }
}
