import AppKit
import SwiftUI

enum PanelTab: Int, CaseIterable {
    case clipboard, emoji, kaomoji, symbols

    var title: String {
        switch self {
        case .clipboard: return tr("Буфер обмена", "Clipboard")
        case .emoji: return tr("Эмодзи", "Emoji")
        case .kaomoji: return tr("Каомодзи", "Kaomoji")
        case .symbols: return tr("Символы", "Symbols")
        }
    }

    var searchPrompt: String {
        switch self {
        case .clipboard: return tr("Поиск в истории", "Search history")
        case .emoji: return tr("Поиск по-английски: heart, cat…", "Search: heart, cat, fire…")
        case .kaomoji: return tr("Поиск", "Search")
        case .symbols: return tr("Поиск по-английски: arrow, euro…", "Search: arrow, euro, alpha…")
        }
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

    // Pinned items come first, like a "Pinned" section in iOS lists
    func filterClips(_ items: [ClipItem]) -> [ClipItem] {
        let ordered = items.filter(\.pinned) + items.filter { !$0.pinned }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ordered }
        return ordered.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.ocrText?.localizedCaseInsensitiveContains(q) ?? false)
        }
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
            sections.append(PickSection(id: 0, title: tr("Недавние", "Recent"), start: 0, values: recent))
        }
        sections.append(PickSection(id: 1, title: recent.isEmpty ? nil : tr("Все", "All"), start: recent.count,
                                    values: all.map(\.value)))
        return sections
    }

    func flatPicks() -> [String] { pickSections().flatMap(\.values) }
}

struct PanelActions {
    let paste: (ClipItem, Bool) -> Void  // item, as plain text
    let pasteText: (String) -> Void
    let insert: (String) -> Void
    let edit: (ClipItem) -> Void
    let openSettings: () -> Void
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    @ObservedObject var prefs: Preferences
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    static let size = NSSize(width: 400, height: 520)
    // Room around the panel for its own shadow; the window's shadow would outline its square corners
    static let shadowMargin: CGFloat = 32
    static var windowSize: NSSize { NSSize(width: size.width + shadowMargin * 2, height: size.height + shadowMargin * 2) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(state.tab.searchPrompt, text: $state.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                    if !state.query.isEmpty {
                        Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))

                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(tr("Настройки", "Settings"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Picker("", selection: $state.tab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    TabIcon(tab: tab).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if prefs.paused && state.tab == .clipboard {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text(tr("Запись на паузе", "Recording is paused"))
                    Spacer()
                    Button(tr("Возобновить", "Resume")) { prefs.paused = false }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            Group {
                if state.tab == .clipboard {
                    ClipboardList(store: store, state: state, actions: actions)
                } else {
                    PickerGrid(state: state, insert: actions.insert)
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.6)
            HStack(spacing: 14) {
                if state.tab == .clipboard {
                    let items = state.filterClips(store.items)
                    let selected = items.indices.contains(state.selection) ? items[state.selection] : nil
                    KeyHint(key: "↵", label: tr("Вставить", "Paste"))
                    if selected?.ocrText != nil {
                        KeyHint(key: "⌥↵", label: tr("Текст с картинки", "Text from image"))
                    } else {
                        KeyHint(key: "⇧↵", label: tr("Без форматирования", "Plain text"))
                    }
                    KeyHint(key: "⌘P", label: tr("Закрепить", "Pin"))
                } else {
                    KeyHint(key: "↵", label: tr("Вставить", "Insert"))
                    KeyHint(key: "⇥", label: tr("Следующая вкладка", "Next tab"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(PanelBackground(style: prefs.panelStyle))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(Self.shadowMargin)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }
}

struct PanelBackground: ViewModifier {
    let style: PanelStyle

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if style == .glass {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                classic(content)
            }
        } else {
            classic(content)
        }
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(VisualEffect())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct TabIcon: View {
    let tab: PanelTab

    var body: some View {
        switch tab {
        case .clipboard: Image(systemName: "list.clipboard")
        case .emoji: Image(systemName: "face.smiling")
        case .kaomoji: Text(";-)")
        case .symbols: Text("Ω")
        }
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.1)))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Clipboard tab

struct ClipboardList: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var state: PanelState
    let actions: PanelActions

    var body: some View {
        let items = state.filterClips(store.items)
        let firstRecent = items.firstIndex { !$0.pinned }
        let hasPinned = items.first?.pinned == true
        if items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                Text(store.items.isEmpty ? tr("История пуста", "No history yet") : tr("Ничего не найдено", "No results"))
                    .font(.system(size: 15, weight: .semibold))
                Text(store.items.isEmpty
                     ? tr("Скопируйте что-нибудь — оно появится здесь", "Copy something and it will show up here")
                     : tr("Попробуйте другой запрос", "Try a different search"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 && hasPinned {
                                SectionHeader(title: tr("Закреплённые", "Pinned"))
                            }
                            if index == firstRecent && hasPinned {
                                SectionHeader(title: tr("Недавние", "Recent"))
                            }
                            row(item, index: index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: state.selection) {
                    if items.indices.contains(state.selection) {
                        proxy.scrollTo(items[state.selection].id)
                    }
                }
            }
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        ClipRow(item: item, index: index, selected: index == state.selection,
                hovering: state.hoveredID == item.id,
                onPin: { store.togglePin(item) },
                onDelete: { store.remove(item) },
                onPasteText: item.ocrText.map { text in { actions.pasteText(text) } },
                onEdit: item.canEdit ? { actions.edit(item) } : nil)
            .id(item.id)
            .onHover { inside in
                if inside {
                    state.hoveredID = item.id
                } else if state.hoveredID == item.id {
                    state.hoveredID = nil
                }
            }
            .onTapGesture { actions.paste(item, false) }
            .contextMenu {
                Button(tr("Вставить", "Paste")) { actions.paste(item, false) }
                if item.kind != .image {
                    Button(tr("Вставить как простой текст", "Paste as Plain Text")) { actions.paste(item, true) }
                }
                if let ocr = item.ocrText {
                    Button(tr("Вставить текст с картинки", "Paste Text from Image")) { actions.pasteText(ocr) }
                }
                if item.canEdit {
                    Button(tr("Изменить…", "Edit…")) { actions.edit(item) }
                }
                if let path = item.paths?.first {
                    Button(tr("Показать в Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button(item.pinned ? tr("Открепить", "Unpin") : tr("Закрепить", "Pin")) { store.togglePin(item) }
                Divider()
                Button(tr("Удалить", "Delete")) { store.remove(item) }
            }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let hovering: Bool
    let onPin: () -> Void
    let onDelete: () -> Void
    let onPasteText: (() -> Void)?
    let onEdit: (() -> Void)?

    var body: some View {
        let badge = item.badge
        HStack(spacing: 10) {
            RowLeading(item: item, badge: badge)

            VStack(alignment: .leading, spacing: 2) {
                title(badge)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(subtitle(badge))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let onPasteText {
                    // Always visible, so recognized text is easy to find
                    Button(action: onPasteText) {
                        Label(tr("Текст", "Text"), systemImage: "text.viewfinder")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
                    }
                    .help(tr("Вставить текст с картинки (⌥↵)", "Paste text from image (⌥↵)"))
                }
                if hovering, let onEdit {
                    Button(action: onEdit) { Image(systemName: "pencil.tip.crop.circle") }
                        .help(tr("Изменить (⌘E)", "Edit (⌘E)"))
                }
                if hovering {
                    Button(action: onPin) { Image(systemName: item.pinned ? "pin.slash" : "pin") }
                        .help(item.pinned ? tr("Открепить", "Unpin") : tr("Закрепить", "Pin"))
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .help(tr("Удалить", "Delete"))
                } else {
                    if item.pinned { Image(systemName: "pin.fill") }
                    if index < 9 {
                        Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded))
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
    }

    private var oneLine: String {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    @ViewBuilder private func title(_ badge: ContentBadge) -> some View {
        switch badge {
        case .code:
            Text(oneLine).font(.system(size: 12, design: .monospaced)).lineLimit(2)
        case .color:
            Text(oneLine.uppercased()).font(.system(size: 13, design: .monospaced))
        case .link:
            Text(oneLine.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
        case .image, .screenshot:
            Text(badge.title).font(.system(size: 13, weight: .medium))
        case .file, .recording, .download:
            Text(item.text.components(separatedBy: "\n").joined(separator: ", "))
                .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
        case .text:
            Text(oneLine).font(.system(size: 13)).lineLimit(2)
        }
    }

    private func subtitle(_ badge: ContentBadge) -> String {
        var parts: [String] = []
        if badge.isMedia {
            if let dimensions = item.dimensions { parts.append(dimensions) }
            if item.ocrText != nil { parts.append(tr("есть текст", "has text")) }
        } else {
            parts.append(badge.title)
        }
        if let app = item.sourceAppName, item.origin == nil { parts.append(app) }
        parts.append(TimeLabel.string(for: item.date))
        return parts.joined(separator: " · ")
    }
}

// Thumbnail, color swatch or an iOS-style type tile, with the source app's icon in the corner
struct RowLeading: View {
    let item: ClipItem
    let badge: ContentBadge

    var body: some View {
        let media = badge.isMedia || item.thumbnail != nil
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = item.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                } else if case .color(let color) = badge {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: color))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                        .frame(width: 32, height: 32)
                } else if let path = item.paths?.first, item.kind == .files {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(badge.tint.gradient))
                }
            }
            if let id = item.sourceBundleID, let icon = AppIcons.icon(bundleID: id) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: 4, y: 4)
                    .help(item.sourceAppName ?? "")
            }
        }
        .frame(width: media ? 56 : 32, height: media ? 40 : 32)
    }
}

// MARK: - Emoji / kaomoji / symbols tabs

struct PickerGrid: View {
    @ObservedObject var state: PanelState
    let insert: (String) -> Void

    var body: some View {
        let sections = state.pickSections()
        let tab = state.tab
        let fontSize: CGFloat = tab == .emoji ? 24 : tab == .symbols ? 18 : 13
        if sections.allSatisfy({ $0.values.isEmpty }) {
            VStack {
                Spacer()
                Text(tr("Ничего не найдено", "No results")).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sections) { section in
                            if let title = section.title { SectionHeader(title: title) }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: tab.columns),
                                      spacing: 2) {
                                ForEach(Array(section.values.enumerated()), id: \.offset) { offset, value in
                                    let index = section.start + offset
                                    Text(value)
                                        .font(.system(size: fontSize))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .foregroundStyle(index == state.selection && tab != .emoji ? Color.white : Color.primary)
                                        .frame(maxWidth: .infinity, minHeight: tab == .kaomoji ? 34 : 40)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(
                                            index == state.selection ? Color.accentColor
                                                : Color.primary.opacity(state.hoveredPick == index ? 0.08 : 0)))
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: state.selection) { proxy.scrollTo(state.selection) }
            }
        }
    }
}
