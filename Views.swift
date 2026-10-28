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
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Button { state.tab = tab } label: {
                        TabIcon(tab: tab)
                            .frame(width: 44, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(state.tab == tab ? Color.primary.opacity(0.12) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
                Spacer()
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
        .frame(width: 380, height: 480)
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
        case .symbols: Image(systemName: "omega")
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
                    LazyVStack(spacing: 4) {
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
        HStack(alignment: .top, spacing: 8) {
            preview.frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    if hovering || item.pinned {
                        Button(action: onPin) {
                            Image(systemName: item.pinned ? "pin.fill" : "pin")
                        }
                        .help(item.pinned ? "Открепить" : "Закрепить")
                    }
                    if hovering {
                        Button(action: onDelete) { Image(systemName: "xmark") }
                            .help("Удалить")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                if index < 9 {
                    Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(hovering ? 0.09 : 0.045))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .image:
            if let data = item.thumbnail, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Изображение").foregroundStyle(.secondary)
            }
        case .files:
            HStack(spacing: 8) {
                if let path = item.paths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                Text(item.text).font(.system(size: 12.5)).lineLimit(3)
            }
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12.5))
                .lineLimit(4)
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
