import AppKit

func drawApplicationIcon() throws -> Data {
    let dimension = 1_024
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let background = NSBezierPath(roundedRect: tile, xRadius: 192, yRadius: 192)
    let navy = NSColor(srgbRed: 0.07, green: 0.13, blue: 0.24, alpha: 1)
    let slate = NSColor(srgbRed: 0.12, green: 0.24, blue: 0.39, alpha: 1)
    NSGradient(colors: [slate, navy])?.draw(in: background, angle: -50)
    NSColor.white.withAlphaComponent(0.15).setStroke()
    background.lineWidth = 8
    background.stroke()

    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 241
    let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                           width: 2 * radius, height: 2 * radius))
    NSColor.white.withAlphaComponent(0.21).setStroke()
    track.lineWidth = 66
    track.stroke()

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: 162)
    progress.lineWidth = 66
    progress.lineCapStyle = .round
    NSColor(srgbRed: 0.37, green: 0.94, blue: 0.78, alpha: 1).setStroke()
    progress.stroke()

    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: 627, y: 626))
    needle.lineWidth = 38
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64)).fill()

    guard let image = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return image
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法：swift packaging/make_app_icon.swift 输出.png\n".utf8))
    exit(64)
}
try drawApplicationIcon().write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
