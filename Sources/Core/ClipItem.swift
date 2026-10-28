import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipItem: Codable, Identifiable {
    enum Kind: String, Codable { case text, image, files }
    // Set when the app itself put a new file on the clipboard
    enum Origin: String, Codable { case screenshot, recording, download }

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
    var origin: Origin?
    var ocrText: String?
    var imageWidth: Int?
    var imageHeight: Int?
    // Every type of every pasteboard item, so formatting, images and files paste back exactly
    var representations: [[String: Data]]
}

extension ClipItem {
    // Kept when a copy is too large to store in full
    private static let standardTypes: Set<String> = Set([
        NSPasteboard.PasteboardType.string, .rtf, .rtfd, .html, .png, .tiff, .fileURL, .URL, .pdf,
    ].map(\.rawValue))
    private static let maxBytes = 30_000_000
    static let screenshotAppID = "com.apple.screenshot.launcher"

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
            // A single picture gets a real preview instead of a generic file icon
            if fileURLs.count == 1, Self.isImageFile(fileURLs[0]), let image = NSImage(contentsOf: fileURLs[0]) {
                thumbnail = image.thumbnailPNG(maxSide: 360)
                (imageWidth, imageHeight) = (image.pixelSize?.width, image.pixelSize?.height)
            }
        } else if let string = Self.plainText(from: pb),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .text
            text = string
            digest = Self.hash(Data(("t" + string).utf8))
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            kind = .image
            text = ""
            thumbnail = image.thumbnailPNG(maxSide: 360)
            (imageWidth, imageHeight) = (image.pixelSize?.width, image.pixelSize?.height)
            digest = Self.hash(tiff)
        } else {
            return nil
        }
        sourceBundleID = source?.bundleIdentifier
        sourceAppName = source?.localizedName
        representations = reps
    }

    // A file that just appeared on disk: pasted as the file itself, and as a picture where that makes sense
    init?(file url: URL, origin: Origin) {
        var rep: [String: Data] = [NSPasteboard.PasteboardType.fileURL.rawValue: Data(url.absoluteString.utf8)]
        var image: NSImage?
        if Self.isImageFile(url), let loaded = NSImage(contentsOf: url) {
            image = loaded
            if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
                rep[NSPasteboard.PasteboardType.png.rawValue] = data
            } else if let tiff = loaded.tiffRepresentation {
                rep[NSPasteboard.PasteboardType.tiff.rawValue] = tiff
            }
        }
        kind = origin == .screenshot && image != nil ? .image : .files
        text = url.lastPathComponent
        paths = [url.path]
        thumbnail = image?.thumbnailPNG(maxSide: 360)
        (imageWidth, imageHeight) = (image?.pixelSize?.width, image?.pixelSize?.height)
        digest = Self.hash(Data(("f" + url.path).utf8))
        if origin != .download {
            sourceBundleID = Self.screenshotAppID
            sourceAppName = tr("Снимок экрана", "Screenshot")
        }
        self.origin = origin
        representations = [rep]
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
        switch origin {
        case .screenshot: return .screenshot
        case .recording: return .recording
        case .download: return .download
        case nil: break
        }
        switch kind {
        case .image: return .image
        case .files: return .file
        case .text: return ContentBadge.detect(text)
        }
    }

    // Full-size picture for text recognition
    var imageData: Data? {
        representations.lazy.compactMap {
            $0[NSPasteboard.PasteboardType.png.rawValue] ?? $0[NSPasteboard.PasteboardType.tiff.rawValue]
        }.first
    }

    // A picture the screenshot editor can open: copied image data, or a single image file
    var editableImageData: Data? {
        if kind == .image { return imageData }
        guard let paths, paths.count == 1 else { return nil }
        let url = URL(fileURLWithPath: paths[0])
        return Self.isImageFile(url) ? try? Data(contentsOf: url) : nil
    }

    var canEdit: Bool {
        kind == .image || (paths?.count == 1 && Self.isImageFile(URL(fileURLWithPath: paths![0])))
    }

    var dimensions: String? {
        guard let imageWidth, let imageHeight else { return nil }
        return "\(imageWidth) × \(imageHeight)"
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    // Some apps put only rich text on the pasteboard
    private static func plainText(from pb: NSPasteboard) -> String? {
        if let string = pb.string(forType: .string) { return string }
        if let data = pb.data(forType: .rtf) { return NSAttributedString(rtf: data, documentAttributes: nil)?.string }
        if let data = pb.data(forType: .rtfd) { return NSAttributedString(rtfd: data, documentAttributes: nil)?.string }
        if let data = pb.data(forType: .html) { return text(fromHTML: String(decoding: data, as: UTF8.self)) }
        return nil
    }

    // Not NSAttributedString(html:): that runs WebKit, which fetches remote images and styles the copied HTML points to
    static func text(fromHTML html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1\s*>|<!--.*?-->"#, with: "",
                                          options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|li|tr|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = decodeNumericEntities(s).replacingOccurrences(of: "&amp;", with: "&")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let numericEntity = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});"#)

    private static func decodeNumericEntities(_ s: String) -> String {
        guard let numericEntity else { return s }
        var result = ""
        var last = s.startIndex
        for match in numericEntity.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(match.range, in: s), let code = Range(match.range(at: 1), in: s) else { continue }
            let digits = s[code]
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            result += s[last..<whole.lowerBound]
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(s[whole])
            last = whole.upperBound
        }
        return result + s[last...]
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
    case text, link, image, file, code, screenshot, recording, download
    case color(NSColor)

    var title: String {
        switch self {
        case .text: return tr("Текст", "Text")
        case .link: return tr("Ссылка", "Link")
        case .image: return tr("Картинка", "Image")
        case .file: return tr("Файл", "File")
        case .code: return tr("Код", "Code")
        case .color: return tr("Цвет", "Color")
        case .screenshot: return tr("Снимок экрана", "Screenshot")
        case .recording: return tr("Запись экрана", "Screen recording")
        case .download: return tr("Загрузка", "Download")
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
        case .screenshot: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .download: return "arrow.down.circle"
        }
    }

    // Tile colors in the spirit of iOS Settings icons
    var tint: Color {
        switch self {
        case .text: return .gray
        case .link: return .blue
        case .image: return .teal
        case .file: return .orange
        case .code: return .purple
        case .color: return .pink
        case .screenshot: return .indigo
        case .recording: return .red
        case .download: return .green
        }
    }

    var isMedia: Bool {
        switch self {
        case .image, .screenshot: return true
        default: return false
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

    var pixelSize: (width: Int, height: Int)? {
        if let rep = representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return size.width > 0 ? (Int(size.width), Int(size.height)) : nil
    }
}
