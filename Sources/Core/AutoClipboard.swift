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
        guard let item = ClipItem(file: file, origin: origin) else { return }
        item.write(to: NSPasteboard.general, plainText: false)
        monitor.markOwnChange()
        store.add(item)
    }

    // The screencapture tool tags its files with this attribute, whatever their name or language
    private static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
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
    private var known: Set<String>
    private var source: DispatchSourceFileSystemObject?
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    init?(url: URL, onNewFile: @escaping (URL) -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.url = url
        self.onNewFile = onNewFile
        known = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }

    private func scan() {
        let current = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        let added = current.subtracting(known)
        known = current
        for name in added where !name.hasPrefix(".") && !name.hasPrefix("~") {
            let file = url.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !Self.partialExtensions.contains(file.pathExtension.lowercased()) else { continue }
            waitUntilWritten(file, lastSize: -1, attempts: 120)
        }
    }

    private func waitUntilWritten(_ file: URL, lastSize: Int, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
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
