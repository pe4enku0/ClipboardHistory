import AppKit
import CoreImage
import ImageIO
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, pen, highlighter, text, blur, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .blur: return "square.grid.3x3.fill"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .arrow: return tr("Стрелка", "Arrow")
        case .rectangle: return tr("Рамка", "Rectangle")
        case .pen: return tr("Карандаш", "Pen")
        case .highlighter: return tr("Маркер", "Highlighter")
        case .text: return tr("Текст", "Text")
        case .blur: return tr("Размытие — скрыть данные", "Blur — hide private info")
        case .crop: return tr("Обрезка", "Crop")
        }
    }
}

struct Annotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case pen([CGPoint], highlighter: Bool)
        case text(String, CGPoint)
        case blur(CGRect)
        case crop(CGRect)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    var width: CGFloat  // line width, or font size for text

    var cropRect: CGRect? {
        if case .crop(let rect) = kind { return rect }
        return nil
    }
}

struct TextDraft {
    var point: CGPoint
    var text = ""
}

// All geometry is in image pixels with a top-left origin, both on screen and when exporting
final class EditorModel: ObservableObject {
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    let image: CGImage
    let sourceURL: URL?
    private let pixelated: CGImage?

    @Published var annotations: [Annotation] = []
    @Published var redoStack: [Annotation] = []
    @Published var draft: Annotation?
    @Published var textDraft: TextDraft?
    @Published var tool = EditorTool.arrow
    @Published var color = NSColor.systemRed
    @Published var sizeIndex = 1

    init?(data: Data, sourceURL: URL?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.image = image
        self.sourceURL = sourceURL
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        // Blocks at least 12 px wide, so text in small pictures can't be read back through the pixelation
        filter?.setValue(max(max(CGFloat(image.width), CGFloat(image.height)) / 70, 12), forKey: kCIInputScaleKey)
        pixelated = filter?.outputImage.flatMap { CIContext().createCGImage($0, from: input.extent) }
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var unit: CGFloat { max(imageSize.width, imageSize.height) / 500 }
    var lineWidth: CGFloat { unit * [1.2, 2.2, 4][sizeIndex] }
    var fontSize: CGFloat { unit * [7, 10, 15][sizeIndex] }
    var canUndo: Bool { !annotations.isEmpty || textDraft != nil }
    var hidesPrivateInfo: Bool {
        annotations.contains { if case .blur = $0.kind { return true } else { return false } }
    }

    func select(_ newTool: EditorTool) {
        commitText()
        tool = newTool
    }

    // MARK: Gestures

    func dragChanged(start: CGPoint, current: CGPoint) {
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        let kind: Annotation.Kind
        switch tool {
        case .arrow: kind = .arrow(start, current)
        case .rectangle: kind = .rectangle(rect)
        case .blur: kind = .blur(rect)
        case .crop: kind = .crop(rect)
        case .pen, .highlighter:
            if case .pen(let points, let highlighter)? = draft?.kind {
                kind = .pen(points + [current], highlighter: highlighter)
            } else {
                kind = .pen([start, current], highlighter: tool == .highlighter)
            }
        case .text:
            return
        }
        draft = Annotation(kind: kind, color: color, width: tool == .highlighter ? lineWidth * 5 : lineWidth)
    }

    func dragEnded(at point: CGPoint) {
        if tool == .text {
            commitText()
            textDraft = TextDraft(point: point)
            return
        }
        guard let finished = draft else { return }
        draft = nil
        guard isMeaningful(finished) else { return }
        annotations.append(finished)
        redoStack.removeAll()
    }

    func commitText() {
        guard let draftText = textDraft else { return }
        textDraft = nil
        let text = draftText.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        annotations.append(Annotation(kind: .text(text, draftText.point), color: color, width: fontSize))
        redoStack.removeAll()
    }

    func undo() {
        if textDraft != nil {
            textDraft = nil
        } else if let last = annotations.popLast() {
            redoStack.append(last)
        }
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) > unit * 3
        case .rectangle(let r), .blur(let r): return r.width > unit * 2 && r.height > unit * 2
        case .crop(let r): return r.width > unit * 6 && r.height > unit * 6
        case .pen(let points, _): return points.count > 1
        case .text: return true
        }
    }

    // MARK: Rendering

    func render(in cg: CGContext, preview: Bool) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        Self.draw(image, in: bounds, cg)
        var items = annotations
        if preview, let draft { items.append(draft) }
        for item in items { draw(item, in: cg) }

        // Crop is applied on export; on screen the area outside it is dimmed
        if preview, let crop = items.last(where: { $0.cropRect != nil })?.cropRect {
            cg.saveGState()
            cg.addRect(bounds)
            cg.addRect(crop)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            cg.fillPath(using: .evenOdd)
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(unit)
            cg.stroke(crop)
            cg.restoreGState()
        }
    }

    private func draw(_ item: Annotation, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(item.color.cgColor)
        cg.setFillColor(item.color.cgColor)
        cg.setLineWidth(item.width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        let shadow = NSColor.black.withAlphaComponent(0.35).cgColor

        switch item.kind {
        case .arrow(let from, let to):
            cg.setShadow(offset: .zero, blur: unit * 2, color: shadow)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = item.width * 4.5
            let spread = CGFloat.pi / 7
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            cg.move(to: from)
            cg.addLine(to: base)
            cg.strokePath()
            cg.move(to: to)
            cg.addLine(to: CGPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
            cg.addLine(to: CGPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
            cg.closePath()
            cg.fillPath()
        case .rectangle(let rect):
            cg.setShadow(offset: .zero, blur: unit * 2, color: shadow)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: item.width * 1.5, cornerHeight: item.width * 1.5, transform: nil))
            cg.strokePath()
        case .pen(let points, let highlighter):
            guard let first = points.first else { return }
            if highlighter {
                cg.setBlendMode(.multiply)
                cg.setStrokeColor(item.color.withAlphaComponent(0.45).cgColor)
            } else {
                cg.setShadow(offset: .zero, blur: unit, color: shadow)
            }
            cg.move(to: first)
            for point in points.dropFirst() { cg.addLine(to: point) }
            cg.strokePath()
        case .text(let string, let point):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            textShadow.shadowBlurRadius = item.width / 6
            (string as NSString).draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: item.width, weight: .bold),
                .foregroundColor: item.color,
                .shadow: textShadow,
            ])
            NSGraphicsContext.restoreGraphicsState()
        case .blur(let rect):
            guard let pixelated else { return }
            cg.clip(to: rect)
            Self.draw(pixelated, in: CGRect(origin: .zero, size: imageSize), cg)
        case .crop:
            break
        }
    }

    // CGContext.draw expects a bottom-left origin, so flip locally
    private static func draw(_ image: CGImage, in rect: CGRect, _ cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: 0, y: rect.minY + rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: rect)
        cg.restoreGState()
    }

    func exportPNG() -> Data? {
        commitText()
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: imageSize.height)
        cg.scaleBy(x: 1, y: -1)
        render(in: cg, preview: false)
        guard var result = cg.makeImage() else { return nil }
        if let crop = annotations.last(where: { $0.cropRect != nil })?.cropRect?
            .integral.intersection(CGRect(origin: .zero, size: imageSize)),
           !crop.isEmpty, let cropped = result.cropping(to: crop) {
            result = cropped
        }
        return NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
    }
}

// Maps between view points and image pixels for an aspect-fit image
private struct FitTransform {
    let scale: CGFloat
    let offset: CGPoint

    init(imageSize: CGSize, viewSize: CGSize, padding: CGFloat) {
        let available = CGSize(width: max(viewSize.width - padding * 2, 1), height: max(viewSize.height - padding * 2, 1))
        scale = min(available.width / imageSize.width, available.height / imageSize.height)
        offset = CGPoint(x: (viewSize.width - imageSize.width * scale) / 2,
                         y: (viewSize.height - imageSize.height * scale) / 2)
    }

    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
}

// MARK: - View

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onDone: (Data) -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let fit = FitTransform(imageSize: model.imageSize, viewSize: geo.size, padding: 24)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        context.withCGContext { cg in
                            cg.translateBy(x: fit.offset.x, y: fit.offset.y)
                            cg.scaleBy(x: fit.scale, y: fit.scale)
                            model.render(in: cg, preview: true)
                        }
                    }
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { model.dragChanged(start: fit.toImage($0.startLocation), current: fit.toImage($0.location)) }
                            .onEnded { model.dragEnded(at: fit.toImage($0.location)) }
                    )
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }

                    if let draft = model.textDraft {
                        let origin = fit.toView(draft.point)
                        TextField(tr("Текст", "Text"), text: textBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: model.fontSize * fit.scale, weight: .bold))
                            .foregroundStyle(Color(nsColor: model.color))
                            .fixedSize()
                            .frame(minWidth: 60, alignment: .leading)
                            .padding(2)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .offset(x: origin.x - 2, y: origin.y - 2)
                            .focused($textFocused)
                            .onSubmit { model.commitText() }
                            .onAppear { DispatchQueue.main.async { textFocused = true } }
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 480)
        .onExitCommand {
            if model.textDraft != nil { model.textDraft = nil } else { NSApp.keyWindow?.performClose(nil) }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.textDraft?.text ?? "" }, set: { model.textDraft?.text = $0 })
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    let selected = model.tool == tool
                    Button { model.select(tool) } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 32, height: 28)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Color.accentColor : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 6) {
                ForEach(EditorModel.palette.indices, id: \.self) { i in
                    let color = EditorModel.palette[i]
                    Button { model.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Button { model.sizeIndex = i } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: [5, 8, 12][i], height: [5, 8, 12][i])
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.sizeIndex == i ? Color.primary.opacity(0.12) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Толщина", "Size"))
                }
            }

            Spacer()

            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .help(tr("Отменить (⌘Z)", "Undo (⌘Z)"))
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.redoStack.isEmpty)
                .help(tr("Повторить (⇧⌘Z)", "Redo (⇧⌘Z)"))
            Button(tr("Сохранить…", "Save…"), action: save)
                .keyboardShortcut("s", modifiers: .command)
            Button(tr("Готово", "Done")) {
                if let png = model.exportPNG() { onDone(png) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help(tr("Скопировать в буфер (⌘↵)", "Copy to clipboard (⌘↵)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VisualEffect(material: .titlebar))
    }

    private func save() {
        guard let png = model.exportPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = model.sourceURL?.deletingPathExtension().lastPathComponent ?? tr("Скриншот", "Screenshot")
        panel.nameFieldStringValue = base + tr(" (изменено)", " (edited)") + ".png"
        panel.directoryURL = model.sourceURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

enum ScreenshotEditor {
    static func makeWindow(model: EditorModel, onDone: @escaping (Data) -> Void) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: EditorView(model: model, onDone: onDone)))
        window.title = model.sourceURL?.lastPathComponent ?? tr("Редактор", "Editor")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // Show the picture at its on-screen size where it fits, otherwise scale it down
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let points = CGSize(width: model.imageSize.width / 2, height: model.imageSize.height / 2)
        let fit = min(1, (visible.width * 0.85 - 48) / points.width, (visible.height * 0.85 - 100) / points.height)
        window.setContentSize(CGSize(width: max(760, points.width * fit + 48), height: max(480, points.height * fit + 100)))
        window.center()
        return window
    }
}
