// Renders the 1024×1024 master app icon: usage `swift scripts/make-icon.swift <output.png>`
import AppKit

let side = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Bitmap konnte nicht erstellt werden") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 pt body centered in the 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
color(0x0A0A0C).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0x221D3A), color(0x0B0B0E)])?.draw(in: shape, angle: -90)

// Soft violet glow behind the glyph.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [color(0x8B76FF, 0.35), color(0x8B76FF, 0)])?
    .draw(fromCenter: NSPoint(x: 512, y: 540), radius: 0, toCenter: NSPoint(x: 512, y: 540), radius: 380, options: [])
NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, 0.09).setStroke()
shape.lineWidth = 4
shape.stroke()

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = symbol.size
    let tinted = NSImage(size: size, flipped: false) { rect in
        NSGradient(colors: [color(0xE2DAFF), color(0x8B76FF)])?.draw(in: rect, angle: -60)
        symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    tinted.draw(in: NSRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2, width: size.width, height: size.height))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG-Export fehlgeschlagen") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
