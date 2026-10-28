import AppKit
import SwiftUI

enum PanelTab: Int, CaseIterable {
    case clipboard, emoji, kaomoji, symbols

    var title: String { ["Буфер обмена", "Эмодзи", "Каомодзи", "Символы"][rawValue] }
    var searchPrompt: String {
        ["Поиск в истории", "Поиск по-английски: heart, cat, fire…", "Поиск",
         "Поиск по-английски: arrow, euro, alpha…"][rawValue]
    }
    var columns: Int { [1, 8, 2, 8][rawValue] }
}

struct PickSection: Identifiable {
    let id: Int
    let title: String?
    let start: Int  // index of the first value across all sections, for keyboard selection
    let values: [String]
}

final class PanelState: ObservableObject {
    @Published var tab = PanelTab.clipboard { didSet { query = "" } }
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var hoveredID: UUID?
    @Published var hoveredPick: Int?

    func filterClips(_ items: [ClipItem]) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    func pickSections() -> [PickSection] {
        let all = PickerData.entries(for: tab)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let found = all.filter { $0.name.contains(q) || $0.value.contains(q) }.map(\.value)
            return [PickSection(id: 0, title: nil, start: 0, values: found)]
        }
        let recent = Recents.list(for: tab)
        var sections: [PickSection] = []
        if !recent.isEmpty {
            sections.append(PickSection(id: 0, title: "Недавние", start: 0, values: recent))
        }
        sections.append(PickSection(id: 1, title: recent.isEmpty ? nil : "Все", start: recent.count,
                                    values: all.map(\.value)))
        return sections
    }

    func flatPicks() -> [String] { pickSections().flatMap(\.values) }
}

struct PanelActions {
    let paste: (ClipItem, Bool) -> Void  // item, as plain text
    let insert: (String) -> Void
    let openSettings: () -> Void
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    @ObservedObject var prefs: Preferences
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(PanelTab.allCases, id: \.self) { tab in
                        let selected = state.tab == tab
                        Button { state.tab = tab } label: {
                            TabIcon(tab: tab)
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                .frame(width: 40, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                        .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1, y: 0.5)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tab.title)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))

                Spacer()
                Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Настройки")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack {
                Text(state.tab.title).font(.headline)
                Spacer()
                if state.tab == .clipboard {
                    Button("Очистить всё") { store.clearUnpinned() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(store.items.allSatisfy(\.pinned))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if prefs.paused && state.tab == .clipboard {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                    Text("Запись на паузе")
                    Spacer()
                    Button("Возобновить") { prefs.paused = false }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(state.tab.searchPrompt, text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)

            Group {
                if state.tab == .clipboard {
                    ClipboardList(store: store, state: state, paste: actions.paste)
                } else {
                    PickerGrid(state: state, insert: actions.insert)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            Text(state.tab == .clipboard
                 ? "↵ вставить · ⇧↵ без форматирования · ⌘P закрепить · ⌘⌫ удалить"
                 : "Стрелки — выбор · ↵ вставить · ⇥ следующая вкладка")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 380, height: 500)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}

struct TabIcon: View {
    let tab: PanelTab

    var body: some View {
        switch tab {
        case .clipboard: Image(systemName: "list.clipboard")
        case .emoji: Image(systemName: "face.smiling")
        case .kaomoji: Text(";-)").font(.system(size: 12, weight: .semibold))
        case .symbols: Text("Ω").font(.system(size: 15, weight: .medium))
        }
    }
}

// MARK: - Clipboard tab

struct ClipboardList: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    let paste: (ClipItem, Bool) -> Void

    var body: some View {
        let items = state.filterClips(store.items)
        if items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clipboard").font(.largeTitle).foregroundStyle(.tertiary)
                Text(store.items.isEmpty ? "Скопируйте что-нибудь —\nоно появится здесь" : "Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index, selected: index == state.selection,
                                    hovering: state.hoveredID == item.id,
                                    onPin: { store.togglePin(item) },
                                    onDelete: { store.remove(item) })
                                .id(item.id)
                                .onHover { inside in
                                    if inside {
                                        state.hoveredID = item.id
                                    } else if state.hoveredID == item.id {
                                        state.hoveredID = nil
                                    }
                                }
                                .onTapGesture { paste(item, false) }
                                .contextMenu {
                                    Button("Вставить") { paste(item, false) }
                                    if item.kind != .image {
                                        Button("Вставить как простой текст") { paste(item, true) }
                                    }
                                    Button(item.pinned ? "Открепить" : "Закрепить") { store.togglePin(item) }
                                    Divider()
                                    Button("Удалить") { store.remove(item) }
                                }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: state.selection) {
                    if items.indices.contains(state.selection) {
                        proxy.scrollTo(items[state.selection].id)
                    }
                }
            }
        }
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let hovering: Bool
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let badge = item.badge
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: badge.symbol)
                Text(badge.title)
                Text("·")
                Text(TimeLabel.string(for: item.date))
                if let id = item.sourceBundleID, let icon = AppIcons.icon(bundleID: id) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .help(item.sourceAppName ?? "")
                }
                Spacer(minLength: 4)
                if hovering {
                    Button(action: onPin) { Image(systemName: item.pinned ? "pin.slash" : "pin") }
                        .help(item.pinned ? "Открепить" : "Закрепить")
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .help("Удалить")
                } else {
                    if item.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(Color.accentColor)
                    }
                    if index < 9 {
                        Text("⌘\(index + 1)").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)

            preview(badge)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovering ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var trimmed: String { item.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private func preview(_ badge: ContentBadge) -> some View {
        switch badge {
        case .image:
            if let data = item.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: 220, maxHeight: 100, alignment: .leading)
            } else {
                Text("Изображение").foregroundStyle(.secondary)
            }
        case .file:
            HStack(spacing: 8) {
                if let path = item.paths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                Text(item.text).font(.system(size: 13)).lineLimit(3)
            }
        case .color(let color):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: color))
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
                Text(trimmed).font(.system(size: 13, design: .monospaced))
            }
        case .link:
            Text(trimmed)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
                .truncationMode(.middle)
        case .code:
            Text(trimmed).font(.system(size: 11.5, design: .monospaced)).lineLimit(5)
        case .text:
            Text(trimmed).font(.system(size: 13)).lineLimit(4)
        }
    }
}

// MARK: - Emoji / kaomoji / symbols tabs

struct PickerGrid: View {
    @ObservedObject var state: PanelState
    let insert: (String) -> Void

    var body: some View {
        let sections = state.pickSections()
        let tab = state.tab
        let fontSize: CGFloat = tab == .emoji ? 22 : tab == .symbols ? 18 : 13
        if sections.allSatisfy({ $0.values.isEmpty }) {
            VStack {
                Spacer()
                Text("Ничего не найдено").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: tab.columns),
                                      spacing: 4) {
                                ForEach(Array(section.values.enumerated()), id: \.offset) { offset, value in
                                    let index = section.start + offset
                                    Text(value)
                                        .font(.system(size: fontSize))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .frame(maxWidth: .infinity, minHeight: tab == .kaomoji ? 32 : 38)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(
                                            index == state.selection ? Color.accentColor.opacity(0.3)
                                                : Color.primary.opacity(state.hoveredPick == index ? 0.09 : 0)))
                                        .contentShape(Rectangle())
                                        .id(index)
                                        .onHover { inside in
                                            if inside {
                                                state.hoveredPick = index
                                            } else if state.hoveredPick == index {
                                                state.hoveredPick = nil
                                            }
                                        }
                                        .onTapGesture { insert(value) }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
            }
        }
    }
}
