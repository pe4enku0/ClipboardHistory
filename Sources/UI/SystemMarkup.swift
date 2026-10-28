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
    private var resizeHandles: ResizeHandles?

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
        // Dragging the editor's own edges never reaches AppKit (the remote content takes the drag),
        // but setting its frame works, so invisible handles around it do the resizing
        let handles = ResizeHandles(around: remote, minSize: NSSize(width: 640, height: 420))
        resizeHandles = handles
        let layout = {
            for (window, margin) in margins {
                window.setFrame(remote.frame.insetBy(dx: -margin, dy: -margin), display: true)
            }
            handles.layout()
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
        resizeHandles?.remove()
        resizeHandles = nil
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

// Thin, nearly invisible windows along the edges and corners of another window that resize it when dragged
final class ResizeHandles {
    enum Edge: CaseIterable { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }

    private let window: NSWindow
    private let minSize: NSSize
    private var handles: [(Edge, NSWindow)] = []
    private static let thickness: CGFloat = 10

    init(around window: NSWindow, minSize: NSSize) {
        self.window = window
        self.minSize = minSize
        for edge in Edge.allCases {
            let handle = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            handle.isOpaque = false
            // Fully clear pixels let clicks fall through to the window below, so keep a trace of alpha
            handle.backgroundColor = NSColor.black.withAlphaComponent(0.002)
            handle.hasShadow = false
            handle.isReleasedWhenClosed = false
            handle.contentView = ResizeHandleView(edge: edge, frame: { [weak window] in window?.frame ?? .zero }) {
                [weak self] start, dx, dy in self?.resize(from: start, edge: edge, dx: dx, dy: dy)
            }
            window.addChildWindow(handle, ordered: .above)
            handles.append((edge, handle))
        }
        layout()
    }

    func layout() {
        let r = window.frame, t = Self.thickness
        for (edge, handle) in handles {
            let frame: NSRect
            switch edge {
            case .left: frame = NSRect(x: r.minX - t / 2, y: r.minY + t, width: t, height: r.height - 2 * t)
            case .right: frame = NSRect(x: r.maxX - t / 2, y: r.minY + t, width: t, height: r.height - 2 * t)
            case .bottom: frame = NSRect(x: r.minX + t, y: r.minY - t / 2, width: r.width - 2 * t, height: t)
            case .top: frame = NSRect(x: r.minX + t, y: r.maxY - t / 2, width: r.width - 2 * t, height: t)
            case .topLeft: frame = NSRect(x: r.minX - t, y: r.maxY - t, width: 2 * t, height: 2 * t)
            case .topRight: frame = NSRect(x: r.maxX - t, y: r.maxY - t, width: 2 * t, height: 2 * t)
            case .bottomLeft: frame = NSRect(x: r.minX - t, y: r.minY - t, width: 2 * t, height: 2 * t)
            case .bottomRight: frame = NSRect(x: r.maxX - t, y: r.minY - t, width: 2 * t, height: 2 * t)
            }
            handle.setFrame(frame, display: false)
        }
    }

    func remove() {
        for (_, handle) in handles {
            window.removeChildWindow(handle)
            handle.orderOut(nil)
        }
        handles = []
    }

    private func resize(from start: NSRect, edge: Edge, dx: CGFloat, dy: CGFloat) {
        var frame = start
        if [.left, .topLeft, .bottomLeft].contains(edge) {
            frame.size.width = max(minSize.width, start.width - dx)
            frame.origin.x = start.maxX - frame.width
        }
        if [.right, .topRight, .bottomRight].contains(edge) {
            frame.size.width = max(minSize.width, start.width + dx)
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(edge) {
            frame.size.height = max(minSize.height, start.height - dy)
            frame.origin.y = start.maxY - frame.height
        }
        if [.top, .topLeft, .topRight].contains(edge) {
            frame.size.height = max(minSize.height, start.height + dy)
        }
        window.setFrame(frame, display: true)
    }
}

private final class ResizeHandleView: NSView {
    private let edge: ResizeHandles.Edge
    private let currentFrame: () -> NSRect
    private let onDrag: (NSRect, CGFloat, CGFloat) -> Void
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(edge: ResizeHandles.Edge, frame: @escaping () -> NSRect, onDrag: @escaping (NSRect, CGFloat, CGFloat) -> Void) {
        self.edge = edge
        self.currentFrame = frame
        self.onDrag = onDrag
        super.init(frame: .zero)
        // Cursor rects only work in the key window; a tracking area works in any window
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = currentFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        onDrag(startFrame, mouse.x - startMouse.x, mouse.y - startMouse.y)
        cursor.set()
    }

    private var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}
