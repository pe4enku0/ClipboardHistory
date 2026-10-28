import AppKit
import UniformTypeIdentifiers

// The same Markup editor macOS opens from the screenshot thumbnail, reached through its sharing service.
// Without a source window it opens small in the bottom-left corner and can't be resized, so it gets a large
// invisible host window to open over, is centered once it has appeared, and becomes resizable.
final class SystemMarkup: NSObject, NSSharingServiceDelegate {
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private var service: NSSharingService?
    private var file: URL?
    private var originalDate: Date?
    private var onFinish: ((Data) -> Void)?
    private var host: NSWindow?
    private var target = NSRect.zero
    private var resizeObserver: NSObjectProtocol?

    static var isAvailable: Bool { NSSharingService(named: serviceName) != nil }

    func open(_ file: URL, onFinish: @escaping (Data) -> Void) -> Bool {
        guard let service = NSSharingService(named: Self.serviceName), service.canPerform(withItems: [file]) else {
            return false
        }
        reset()
        service.delegate = self
        self.service = service
        self.file = file
        self.onFinish = onFinish
        originalDate = Self.modificationDate(of: file)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        target = visible.insetBy(dx: visible.width * 0.05, dy: visible.height * 0.05)
        let host = NSWindow(contentRect: target, styleMask: .borderless, backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear
        host.ignoresMouseEvents = true
        host.isReleasedWhenClosed = false
        host.orderFrontRegardless()
        self.host = host

        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [file])
        adoptEditorWindow(lastFrame: nil, attempts: 60)
        return true
    }

    // MARK: Window handling

    private func adoptEditorWindow(lastFrame: NSRect?, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let host = self.host, attempts > 0 else { return }
            let remote = host.childWindows?.first { String(describing: type(of: $0)).contains("RemoteWindow") }
            // Wait until the opening animation has finished, so the layout below is measured at rest
            guard let remote, remote.frame == lastFrame else {
                self.adoptEditorWindow(lastFrame: remote?.frame, attempts: attempts - 1)
                return
            }
            self.makeResizable(remote, in: host)
        }
    }

    private func makeResizable(_ remote: NSWindow, in host: NSWindow) {
        // The blur backdrop sits exactly under the editor (as when Markup opens on its own),
        // the shadow window extends around it
        let margins = (host.childWindows ?? []).filter { $0 !== remote }.map { window -> (NSWindow, CGFloat) in
            let isBlur = String(describing: type(of: window)).contains("Blur")
            return (window, isBlur ? 0 : max(0, remote.frame.minX - window.frame.minX))
        }
        // Child windows move with their parent, so moving the host centers the whole editor
        host.setFrameOrigin(NSPoint(x: host.frame.minX + target.midX - remote.frame.midX,
                                    y: host.frame.minY + target.midY - remote.frame.midY))
        remote.styleMask.insert(.resizable)
        remote.minSize = NSSize(width: 640, height: 420)
        let layout = {
            for (window, margin) in margins {
                window.setFrame(remote.frame.insetBy(dx: -margin, dy: -margin), display: true)
            }
        }
        layout()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: remote, queue: .main
        ) { _ in layout() }
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        host
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        target
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

    // MARK: Result

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
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        host?.orderOut(nil)
        host = nil
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
