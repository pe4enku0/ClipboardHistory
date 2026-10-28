import AppKit
import CryptoKit

// MARK: - Clipboard item

struct ClipItem: Codable, Identifiable {
    enum Kind: String, Codable { case text, image, files }

    var id = UUID()
    var date = Date()
    var pinned = false
    var kind: Kind
    var text: String          // plain text, or file names; used for preview and search
    var paths: [String]?
    var thumbnail: Data?      // small PNG for image previews
    var digest: String        // detects duplicates
    // Every type of every pasteboard item, so formatting, images and files paste back exactly
    var representations: [[String: Data]]
}

extension ClipItem {
    // Kept when a copy is too large to store in full
    private static let standardTypes: Set<String> = [
        NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL, .pdf,
    ].map(\.rawValue).reduce(into: []) { $0.insert($1) }
    private static let maxBytes = 30_000_000

    init?(pasteboard pb: NSPasteboard) {
        guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return nil }
        var reps: [[String: Data]] = pbItems.map { pbItem in
            var dict: [String: Data] = [:]
            for type in pbItem.types where !type.rawValue.hasPrefix("com.apple.pasteboard.promised") {
                if let data = pbItem.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
        if Self.size(of: reps) > Self.maxBytes {
            reps = reps.map { $0.filter { Self.standardTypes.contains($0.key) } }
            guard Self.size(of: reps) <= Self.maxBytes else { return nil }
        }

        let fileURLs = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            let filePaths = fileURLs.map(\.path)
            kind = .files
            paths = filePaths
            text = fileURLs.map(\.lastPathComponent).joined(separator: "\n")
            digest = Self.hash(Data(("f" + filePaths.joined(separator: "\n")).utf8))
        } else if let string = Self.plainText(from: pb),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .text
            text = string
            digest = Self.hash(Data(("t" + string).utf8))
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            kind = .image
            text = ""
            thumbnail = image.thumbnailPNG(maxSide: 360)
            digest = Self.hash(tiff)
        } else {
            return nil
        }
        representations = reps
    }

    func write(to pb: NSPasteboard, plainText: Bool) {
        pb.clearContents()
        if plainText {
            pb.setString(kind == .files ? (paths ?? []).joined(separator: "\n") : text, forType: .string)
            return
        }
        let items = representations.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pb.writeObjects(items)
    }

    // Some apps put only rich text on the pasteboard
    private static func plainText(from pb: NSPasteboard) -> String? {
        if let string = pb.string(forType: .string) { return string }
        if let data = pb.data(forType: .rtf) { return NSAttributedString(rtf: data, documentAttributes: nil)?.string }
        if let data = pb.data(forType: .rtfd) { return NSAttributedString(rtfd: data, documentAttributes: nil)?.string }
        if let data = pb.data(forType: .html) { return NSAttributedString(html: data, documentAttributes: nil)?.string }
        return nil
    }

    private static func size(of reps: [[String: Data]]) -> Int {
        reps.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    func thumbnailPNG(maxSide: CGFloat) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))
        let thumb = NSImage(size: target, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
        guard let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Store

final class ClipStore: ObservableObject {
    @Published var items: [ClipItem] = []
    let maxItems = 50
    private let fileURL: URL
    private let saveQueue = DispatchQueue(label: "ClipboardHistory.save")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.plist")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? PropertyListDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
    }

    func save() {
        let snapshot = items
        let url = fileURL
        saveQueue.async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func add(_ new: ClipItem) {
        var item = new
        if let i = items.firstIndex(where: { $0.digest == item.digest }) {
            item.pinned = items[i].pinned
            items.remove(at: i)
        }
        items.insert(item, at: 0)
        // Pinned items survive trimming, like on Windows
        while items.count > maxItems, let i = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: i)
        }
        save()
    }

    func moveToTop(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var moved = items.remove(at: i)
        moved.date = Date()
        items.insert(moved, at: 0)
        save()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        save()
    }
}

// MARK: - Clipboard polling (macOS has no change notification)

final class ClipboardMonitor {
    private let store: ClipStore
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    // Password managers mark secrets with these types (nspasteboard.org convention)
    private let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    init(store: ClipStore) { self.store = store }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    func markOwnChange() { lastChange = NSPasteboard.general.changeCount }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: skipTypes) else { return }
        if let item = ClipItem(pasteboard: pb) { store.add(item) }
    }
}

// MARK: - Recently inserted emoji / symbols

enum Recents {
    static func list(for tab: PanelTab) -> [String] {
        UserDefaults.standard.stringArray(forKey: "recent.\(tab.rawValue)") ?? []
    }

    static func add(_ value: String, for tab: PanelTab) {
        var list = list(for: tab)
        list.removeAll { $0 == value }
        list.insert(value, at: 0)
        let limit = tab == .kaomoji ? 6 : tab.columns * 2
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: "recent.\(tab.rawValue)")
    }
}
