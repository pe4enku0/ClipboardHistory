// Draws the 1024×1024 app icon: a fan of cards on a blue squircle.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let canvas: CGFloat = 1024
let rgb = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(_ ctx: CGContext) {
    // macOS icon grid: 824pt body centered on a 1024 canvas
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x3A49D8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: rgb, colors: [color(0x6FB1FF), color(0x4A6CF7), color(0x3B3FD6)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])
    ctx.restoreGState()

    let cardSize = CGSize(width: 420, height: 520)

    func card(angle: CGFloat, dx: CGFloat, dy: CGFloat, fill: CGColor, content: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: 512 + dx, y: 500 + dy)
        ctx.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2, width: cardSize.width, height: cardSize.height)
        let path = CGPath(roundedRect: rect, cornerWidth: 56, cornerHeight: 56, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36, color: color(0x101560, 0.35))
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        if content {
            let left = rect.minX + 56
            var top = rect.maxY - 64
            // Title line in the accent color, then body text lines
            let lines: [(width: CGFloat, height: CGFloat, color: CGColor, gap: CGFloat)] = [
                (190, 38, color(0x4A6CF7), 46),
                (308, 24, color(0xC9D3F2), 30),
                (268, 24, color(0xC9D3F2), 30),
                (296, 24, color(0xC9D3F2), 30),
                (196, 24, color(0xC9D3F2), 52),
            ]
            for line in lines {
                let lineRect = CGRect(x: left, y: top - line.height, width: line.width, height: line.height)
                ctx.addPath(CGPath(roundedRect: lineRect, cornerWidth: line.height / 2, cornerHeight: line.height / 2,
                                   transform: nil))
                ctx.setFillColor(line.color)
                ctx.fillPath()
                top -= line.height + line.gap - line.height / 2
            }
            // A small image tile, hinting that pictures are kept too
            let tile = CGRect(x: left, y: rect.minY + 56, width: 150, height: 104)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.clip()
            let sky = CGGradient(colorsSpace: rgb, colors: [color(0xFFB36B), color(0xFF6F91)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(sky, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY),
                                   options: [])
            ctx.setFillColor(color(0xFFFFFF, 0.9))
            ctx.fillEllipse(in: CGRect(x: tile.maxX - 52, y: tile.maxY - 46, width: 26, height: 26))
            ctx.move(to: CGPoint(x: tile.minX, y: tile.minY))
            ctx.addLine(to: CGPoint(x: tile.minX + 56, y: tile.minY + 58))
            ctx.addLine(to: CGPoint(x: tile.minX + 92, y: tile.minY + 28))
            ctx.addLine(to: CGPoint(x: tile.minX + 116, y: tile.minY + 46))
            ctx.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
            ctx.closePath()
            ctx.setFillColor(color(0xFFFFFF, 0.75))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    card(angle: -16, dx: 78, dy: 26, fill: color(0xFFFFFF, 0.45), content: false)
    card(angle: -7, dx: 38, dy: 12, fill: color(0xFFFFFF, 0.72), content: false)
    card(angle: 4, dx: -18, dy: -8, fill: color(0xFFFFFF), content: true)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
drawIcon(NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
