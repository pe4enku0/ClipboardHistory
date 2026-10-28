import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// Puts new screenshots, screen recordings and downloads straight onto the clipboard,
// so ⌘V works right away. The files themselves stay where macOS saved them.
final class AutoClipboard {
    private let store: ClipStore
    private let monitor: ClipboardMonitor
    private var watchers: [DirectoryWatcher] = []
    var onScreenshot: ((URL) -> Void)?

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    func restart() {
        watchers = []
        let prefs = Preferences.shared
        let captures = Self.screenshotFolder()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

        var folders: [URL: Bool] = [:]  // folder -> also watch for downloads
        if prefs.autoScreenshots || prefs.autoRecordings { folders[captures.standardizedFileURL] = false }
        if prefs.autoDownloads { folders[downloads.standardizedFileURL] = true }
        for (folder, isDownloads) in folders {
            let watcher = DirectoryWatcher(url: folder) { [weak self] file in
                self?.handle(file, inDownloads: isDownloads)
            }
            if let watcher { watchers.append(watcher) }
        }
    }

    private func handle(_ file: URL, inDownloads: Bool) {
        let prefs = Preferences.shared
        guard !prefs.paused else { return }
        let origin: ClipItem.Origin
        if Self.isScreenCapture(file) {
            let isVideo = UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) ?? false
            guard isVideo ? prefs.autoRecordings : prefs.autoScreenshots else { return }
            origin = isVideo ? .recording : .screenshot
        } else if inDownloads && prefs.autoDownloads {
            origin = .download
        } else {
            return
        }
        // Clipboard first, so ⌘V works immediately; the history entry (thumbnail, size) is built in the background
        Self.writeToPasteboard(file)
        monitor.markOwnChange()
        if origin == .screenshot { onScreenshot?(file) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let item = ClipItem(file: file, origin: origin) else { return }
            DispatchQueue.main.async { self?.store.add(item) }
        }
    }

    private static func writeToPasteboard(_ file: URL) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if file.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: file) {
            item.setData(data, forType: .png)
        } else if ClipItem.isImageFile(file), let tiff = NSImage(contentsOf: file)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    // The screencapture tool tags its files with this attribute, whatever their name or language
    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    // The floating thumbnail in the corner delays saving the file by about 5 seconds
    static var showsFloatingThumbnail: Bool {
        get { UserDefaults(suiteName: "com.apple.screencapture")?.object(forKey: "show-thumbnail") as? Bool ?? true }
        set { UserDefaults(suiteName: "com.apple.screencapture")?.set(newValue, forKey: "show-thumbnail") }
    }

    private static func screenshotFolder() -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}

// Reports files that appear in a folder once they have finished being written
final class DirectoryWatcher {
    private let url: URL
    private let onNewFile: (URL) -> Void
    private var stream: FSEventStreamRef?
    private var seen: Set<String> = []
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    // FSEvents reports each file as it appears; a plain directory vnode watch missed events and lagged
    init?(url: URL, onNewFile: @escaping (URL) -> Void) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        self.onNewFile = onNewFile
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) { watcher.handle(path: list[i], flags: flags[i]) }
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                               | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [self.url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, options) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        let appeared = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
        guard flags & appeared != 0, flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { return }
        let file = URL(fileURLWithPath: path)
        let name = file.lastPathComponent
        // Only files directly in the folder, not in its subfolders
        guard file.deletingLastPathComponent().standardizedFileURL.path == url.path,
              !name.hasPrefix("."), !name.hasPrefix("~"),
              !Self.partialExtensions.contains(file.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: path), !seen.contains(path) else { return }
        seen.insert(path)
        // screencapture moves a finished file into place, so screenshots need no waiting
        if AutoClipboard.isScreenCapture(file) {
            onNewFile(file)
        } else {
            waitUntilWritten(file, lastSize: -1, attempts: 600)
        }
    }

    private func waitUntilWritten(_ file: URL, lastSize: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, attempts > 0,
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int else { return }
            if size > 0 && size == lastSize {
                self.onNewFile(file)
            } else {
                self.waitUntilWritten(file, lastSize: size, attempts: attempts - 1)
            }
        }
    }
}

// On-device text recognition, so screenshots can be searched and pasted as text
enum TextRecognizer {
    static func recognize(_ data: Data, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var result: String?
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ru-RU", "en-US"]
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                result = lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
