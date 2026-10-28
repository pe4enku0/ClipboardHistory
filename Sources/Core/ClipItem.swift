import AppKit
import CryptoKit

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
    var sourceBundleID: String?
    var sourceAppName: String?
    // Every type of every pasteboard item, so formatting, images and files paste back exactly
    var representations: [[String: Data]]
}

extension ClipItem {
    // Kept when a copy is too large to store in full
    private static let standardTypes: Set<String> = Set([
        NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL, .pdf,
    ].map(\.rawValue))
    private static let maxBytes = 30_000_000

    init?(pasteboard pb: NSPasteboard, source: NSRunningApplication?) {
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
        sourceBundleID = source?.bundleIdentifier
        sourceAppName = source?.localizedName
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

    var badge: ContentBadge {
        switch kind {
        case .image: return .image
        case .files: return .file
        case .text: return ContentBadge.detect(text)
        }
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

// MARK: - Content type shown on each row

enum ContentBadge {
    case text, link, image, file, code
    case color(NSColor)

    var title: String {
        switch self {
        case .text: return "Текст"
        case .link: return "Ссылка"
        case .image: return "Картинка"
        case .file: return "Файл"
        case .code: return "Код"
        case .color: return "Цвет"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "paintpalette"
        }
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func detect(_ raw: String) -> ContentBadge {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let color = parseHexColor(s) { return .color(color) }
        if !s.contains(where: \.isWhitespace),
           let match = linkDetector?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           match.range.length == (s as NSString).length {
            return .link
        }
        if looksLikeCode(s) { return .code }
        return .text
    }

    static func parseHexColor(_ s: String) -> NSColor? {
        guard s.hasPrefix("#") else { return nil }
        let hex = String(s.dropFirst())
        guard [3, 6, 8].contains(hex.count), let v = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        switch hex.count {
        case 3: (r, g, b, a) = ((v >> 8 & 0xF) * 17, (v >> 4 & 0xF) * 17, (v & 0xF) * 17, 255)
        case 6: (r, g, b, a) = (v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF, 255)
        default: (r, g, b, a) = (v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF)
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    private static let codeMarkers = ["{", "}", ";", "=>", "->", "</", "/>", "func ", "def ", "const ", "let ",
                                      "var ", "import ", "return ", "#include", "SELECT ", "print("]

    private static func looksLikeCode(_ s: String) -> Bool {
        codeMarkers.filter { s.contains($0) }.count >= 2
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
