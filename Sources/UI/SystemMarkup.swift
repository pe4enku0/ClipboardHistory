import AppKit
import UniformTypeIdentifiers

// The same Markup editor macOS opens from the screenshot thumbnail, reached through its sharing service
final class SystemMarkup: NSObject, NSSharingServiceDelegate {
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private var service: NSSharingService?
    private var file: URL?
    private var originalDate: Date?
    private var onFinish: ((Data) -> Void)?

    static var isAvailable: Bool { NSSharingService(named: serviceName) != nil }

    func open(_ file: URL, onFinish: @escaping (Data) -> Void) -> Bool {
        guard let service = NSSharingService(named: Self.serviceName), service.canPerform(withItems: [file]) else {
            return false
        }
        service.delegate = self
        self.service = service
        self.file = file
        self.onFinish = onFinish
        originalDate = Self.modificationDate(of: file)
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [file])
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        resolveImage(from: items) { [weak self] data in
            if let data { self?.onFinish?(data) }
            self?.reset()
        }
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        reset()
    }

    // Depending on the macOS version the edited picture comes back as a file, image, data or item
    // provider, or the file is simply edited in place
    private func resolveImage(from items: [Any], completion: @escaping (Data?) -> Void) {
        for item in items {
            if let url = item as? URL, let data = try? Data(contentsOf: url) { return completion(data) }
            if let data = item as? Data { return completion(data) }
            if let image = item as? NSImage { return completion(image.tiffRepresentation) }
            if let provider = item as? NSItemProvider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    DispatchQueue.main.async { completion(data) }
                }
                return
            }
        }
        guard let file, Self.modificationDate(of: file) != originalDate else { return completion(nil) }
        completion(try? Data(contentsOf: file))
    }

    private func reset() {
        service = nil
        file = nil
        onFinish = nil
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // Pictures that only exist in the history get a temporary file to edit
    static func temporaryFile(for data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardHistory/Markup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(tr("Картинка", "Image") + " \(Int(Date().timeIntervalSince1970)).png")
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        return (try? png.write(to: url)) == nil ? nil : url
    }
}
