import AppKit
import ImageIO
import SwiftUI

// A flash over the captured area and a card with a preview, so it's obvious the screenshot is on the clipboard
final class ScreenshotFeedback {
    var onEdit: ((URL) -> Void)?
    private var toast: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var flashWindows: [NSWindow] = []

    func show(file: URL) {
        flash(Self.captureRect(of: file))
        showToast(for: file)
    }

    // screencapture stores the captured area as [x, y, width, height] in points, top-left origin
    static func captureRect(of file: URL) -> NSRect? {
        let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [NSNumber],
              values.count == 4 else { return nil }
        let r = values.map { CGFloat($0.doubleValue) }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r[0], y: primaryHeight - r[1] - r[3], width: r[2], height: r[3])
    }

    private func flash(_ rect: NSRect?) {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = rect ?? mouseScreen?.frame else { return }
        // A soft glowing outline around the captured area instead of a full white flash
        let glow: CGFloat = 14
        let window = NSWindow(contentRect: frame.insetBy(dx: -glow, dy: -glow), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        let outline = CALayer()
        outline.frame = view.bounds.insetBy(dx: glow, dy: glow)
        outline.cornerRadius = rect == nil ? 0 : 4
        outline.borderWidth = 2
        outline.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        outline.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        outline.shadowColor = NSColor.white.cgColor
        outline.shadowOpacity = 1
        outline.shadowRadius = 7
        outline.shadowOffset = .zero
        view.layer?.addSublayer(outline)
        window.contentView = view
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.orderFrontRegardless()
        flashWindows.append(window)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.flashWindows.removeAll { $0 === window }
        })
    }

    private func showToast(for file: URL) {
        hideToast(animated: false)
        guard let thumbnail = Self.thumbnail(of: file) else { return }
        let view = ScreenshotToast(
            image: thumbnail, file: file,
            onEdit: { [weak self] in
                self?.hideToast(animated: false)
                self?.onEdit?(file)
            },
            onClose: { [weak self] in self?.hideToast(animated: true) },
            onHover: { [weak self] inside in
                if inside { self?.hideWork?.cancel() } else { self?.scheduleHide() }
            })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        // The view's own 20pt shadow padding already keeps the card off the screen edges
        let target = NSRect(x: visible.maxX - size.width, y: visible.minY, width: size.width, height: size.height)
        panel.setFrame(target.offsetBy(dx: 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        toast = panel
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideToast(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideToast(animated: Bool) {
        hideWork?.cancel()
        guard let panel = toast else { return }
        toast = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // Decoding just a small thumbnail keeps the card instant even for 5K screenshots
    static func thumbnail(of file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 400,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct ScreenshotToast: View {
    let image: NSImage
    let file: URL
    let onEdit: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
                .onTapGesture(perform: onEdit)
                .help(tr("Нажмите, чтобы изменить, или перетащите в другое приложение",
                         "Click to edit, or drag into another app"))

            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Скриншот скопирован", "Screenshot copied"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("⌘V — вставить", "Press ⌘V to paste"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(action: onEdit) {
                    Label(tr("Изменить", "Edit"), systemImage: "pencil.tip.crop.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 330)
        .modifier(PanelBackground(style: Preferences.shared.panelStyle))
        .onHover(perform: onHover)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(20)  // room for the shadow; the window's own shadow would outline its square corners
    }
}
