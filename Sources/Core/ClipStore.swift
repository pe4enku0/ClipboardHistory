import AppKit
import CryptoKit

final class ClipStore: ObservableObject {
    @Published var items: [ClipItem] = []
    private let fileURL: URL
    private let legacyURL: URL  // unencrypted history from earlier versions
    private let key = HistoryKey.load()
    private let saveQueue = DispatchQueue(label: "ClipboardHistory.save")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.sealed")
        legacyURL = dir.appendingPathComponent("history.plist")
        if let key, let sealed = try? Data(contentsOf: fileURL),
           let data = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key),
           let saved = try? PropertyListDecoder().decode([ClipItem].self, from: data) {
            items = saved
        } else if let data = try? Data(contentsOf: legacyURL),
                  let saved = try? PropertyListDecoder().decode([ClipItem].self, from: data) {
            items = saved
            save()  // re-written encrypted; the plain file is removed once that succeeds
        }
    }

    // Without the key (keychain access denied) history stays in memory only,
    // so the file on disk is never replaced by something that can't be read back
    func save() {
        guard let key else { return }
        let snapshot = items
        let (url, legacy) = (fileURL, legacyURL)
        saveQueue.async {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(snapshot),
                  let sealed = try? AES.GCM.seal(data, using: key).combined,
                  (try? sealed.write(to: url, options: .atomic)) != nil else { return }
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    func add(_ new: ClipItem) {
        var item = new
        if let i = items.firstIndex(where: { $0.digest == item.digest }) {
            item.pinned = items[i].pinned
            item.ocrText = item.ocrText ?? items[i].ocrText
            items.remove(at: i)
        }
        items.insert(item, at: 0)
        applyLimits()
        save()
        recognizeTextIfNeeded(item)
    }

    private func recognizeTextIfNeeded(_ item: ClipItem) {
        guard Preferences.shared.recognizeText, item.kind == .image, item.ocrText == nil,
              let data = item.imageData else { return }
        TextRecognizer.recognize(data) { [weak self] text in
            guard let self, let text, let i = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[i].ocrText = text
            self.save()
        }
    }

    // Pinned items survive both limits, like on Windows
    func applyLimits() {
        let prefs = Preferences.shared
        let before = items.count
        if prefs.retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(prefs.retentionDays) * 86_400)
            items.removeAll { !$0.pinned && $0.date < cutoff }
        }
        while items.count > prefs.historyLimit, let i = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: i)
        }
        if items.count != before { save() }
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

// MARK: - Encryption key

// History holds whatever was copied, so it is encrypted with a key that lives in the login keychain
enum HistoryKey {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.pe4enku0.ClipboardHistory",
        kSecAttrAccount as String: "history-key",
    ]

    static func load() -> SymmetricKey? {
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map { SymmetricKey(data: $0) }
        case errSecItemNotFound: return create()
        default: return nil  // denied or locked: never replace a key that exists
        }
    }

    private static func create() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        var item = base
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrLabel as String] = "ClipboardHistory"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? key : nil
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

        let prefs = Preferences.shared
        guard !prefs.paused else { return }
        let source = NSWorkspace.shared.frontmostApplication
        if let id = source?.bundleIdentifier, prefs.excludedBundleIDs.contains(id) { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: skipTypes) else { return }

        guard let item = ClipItem(pasteboard: pb, source: source) else { return }
        if item.kind == .image && !prefs.saveImages { return }
        if item.kind == .text && SecretDetector.containsSecret(item.text) { return }
        store.add(item)
    }
}

// API keys, tokens and private keys copied from a terminal, browser or chat carry no password-manager marker
enum SecretDetector {
    private static let pattern = try? NSRegularExpression(pattern: [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"(?<![A-Za-z0-9_-])(?:"#
            + [
                #"sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"#,          // Anthropic, OpenAI
                #"gh[pousr]_[A-Za-z0-9]{30,}"#, #"github_pat_[A-Za-z0-9_]{40,}"#, #"glpat-[A-Za-z0-9_-]{20,}"#,
                #"xox[abprs]-[A-Za-z0-9-]{10,}"#,                   // Slack
                #"(?:AKIA|ASIA)[0-9A-Z]{16}"#,                      // AWS
                #"AIza[0-9A-Za-z_-]{35}"#,                          // Google
                #"(?:sk|rk)_live_[A-Za-z0-9]{20,}"#,                // Stripe
                #"npm_[A-Za-z0-9]{36}"#,
                #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,  // JWT
            ].joined(separator: "|")
            + #")(?![A-Za-z0-9_-])"#,
    ].joined(separator: "|"))

    static func containsSecret(_ text: String) -> Bool {
        let sample = String(text.prefix(200_000))
        return pattern?.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil
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
