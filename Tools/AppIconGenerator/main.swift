import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
let icns = resources.appendingPathComponent("AppIcon.icns")
let source = resources.appendingPathComponent("AppIconSource.png")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let base: NSImage
if let sourceImage = NSImage(contentsOf: source) {
    base = resize(sourceImage, to: NSSize(width: 1024, height: 1024))
} else {
    base = drawIcon(size: 1024)
}
let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in entries {
    let image = resize(base, to: NSSize(width: size, height: size))
    try writePNG(image, to: iconset.appendingPathComponent(name))
}
try writePNG(base, to: resources.appendingPathComponent("AppIconPreview.png"))

try writeICNS(
    chunks: [
        ("icp4", iconset.appendingPathComponent("icon_16x16.png")),
        ("icp5", iconset.appendingPathComponent("icon_32x32.png")),
        ("icp6", iconset.appendingPathComponent("icon_32x32@2x.png")),
        ("ic07", iconset.appendingPathComponent("icon_128x128.png")),
        ("ic08", iconset.appendingPathComponent("icon_256x256.png")),
        ("ic09", iconset.appendingPathComponent("icon_512x512.png")),
        ("ic10", iconset.appendingPathComponent("icon_512x512@2x.png")),
    ],
    to: icns
)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor(red: 0.005, green: 0.008, blue: 0.014, alpha: 1).setFill()
    NSBezierPath(rect: rect).fill()

    let radius = size * 0.215
    let background = rounded(rect.insetBy(dx: size * 0.035, dy: size * 0.035), radius: radius)
    NSGradient(colors: [
        NSColor(red: 0.015, green: 0.020, blue: 0.032, alpha: 1),
        NSColor(red: 0.035, green: 0.055, blue: 0.085, alpha: 1),
        NSColor(red: 0.005, green: 0.008, blue: 0.014, alpha: 1),
    ])?.draw(in: background, angle: 135)

    drawInnerGlow(in: rect, size: size)
    drawMeterArc(center: CGPoint(x: size * 0.50, y: size * 0.50), size: size)
    drawCodeMark(size: size)
    drawStatusLights(size: size)
    drawHighlights(size: size)

    return image
}

func drawInnerGlow(in rect: NSRect, size: CGFloat) {
    let glowRect = rect.insetBy(dx: size * 0.16, dy: size * 0.16)
    let glow = NSBezierPath(ovalIn: glowRect)
    NSGradient(colors: [
        NSColor(red: 0.00, green: 0.95, blue: 0.65, alpha: 0.26),
        NSColor(red: 0.00, green: 0.32, blue: 0.45, alpha: 0.05),
        NSColor.clear,
    ])?.draw(in: glow, relativeCenterPosition: NSPoint(x: -0.18, y: 0.18))

    let core = rounded(rect.insetBy(dx: size * 0.24, dy: size * 0.24), radius: size * 0.12)
    NSGradient(colors: [
        NSColor(red: 0.08, green: 0.12, blue: 0.16, alpha: 0.86),
        NSColor(red: 0.02, green: 0.03, blue: 0.045, alpha: 0.94),
    ])?.draw(in: core, angle: 115)
}

func drawMeterArc(center: CGPoint, size: CGFloat) {
    let segmentCount = 32
    let radius = size * 0.335
    for index in 0..<segmentCount {
        let start = CGFloat(218) - CGFloat(index) * 250 / CGFloat(segmentCount)
        let end = start - 5.5
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        path.lineWidth = size * 0.026
        path.lineCapStyle = .round
        let active = index < 24
        let color: NSColor
        if active {
            let t = CGFloat(index) / CGFloat(segmentCount)
            color = NSColor(
                red: 0.06 + 0.26 * t,
                green: 0.88 - 0.16 * t,
                blue: 0.62 - 0.48 * t,
                alpha: 0.92
            )
        } else {
            color = NSColor(red: 0.30, green: 0.35, blue: 0.40, alpha: 0.25)
        }
        color.setStroke()
        path.stroke()
    }
}

func drawCodeMark(size: CGFloat) {
    let stroke = size * 0.064
    let emerald = NSColor(red: 0.20, green: 0.98, blue: 0.72, alpha: 1)
    let cyan = NSColor(red: 0.34, green: 0.86, blue: 1.00, alpha: 0.90)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowColor = emerald.withAlphaComponent(0.58)
    shadow.shadowOffset = .zero
    shadow.set()

    let left = NSBezierPath()
    left.lineWidth = stroke
    left.lineCapStyle = .round
    left.lineJoinStyle = .round
    left.move(to: CGPoint(x: size * 0.42, y: size * 0.66))
    left.line(to: CGPoint(x: size * 0.27, y: size * 0.50))
    left.line(to: CGPoint(x: size * 0.42, y: size * 0.34))
    cyan.setStroke()
    left.stroke()

    let slash = NSBezierPath()
    slash.lineWidth = stroke * 0.92
    slash.lineCapStyle = .round
    slash.move(to: CGPoint(x: size * 0.59, y: size * 0.70))
    slash.line(to: CGPoint(x: size * 0.43, y: size * 0.30))
    emerald.setStroke()
    slash.stroke()

    let right = NSBezierPath()
    right.lineWidth = stroke
    right.lineCapStyle = .round
    right.lineJoinStyle = .round
    right.move(to: CGPoint(x: size * 0.58, y: size * 0.66))
    right.line(to: CGPoint(x: size * 0.73, y: size * 0.50))
    right.line(to: CGPoint(x: size * 0.58, y: size * 0.34))
    emerald.withAlphaComponent(0.96).setStroke()
    right.stroke()
}

func drawStatusLights(size: CGFloat) {
    let colors = [
        NSColor(red: 0.13, green: 0.82, blue: 0.36, alpha: 1),
        NSColor(red: 0.95, green: 0.70, blue: 0.18, alpha: 1),
        NSColor(red: 0.88, green: 0.22, blue: 0.20, alpha: 1),
    ]
    let diameter = size * 0.037
    let spacing = size * 0.055
    let startX = size * 0.5 - spacing
    let y = size * 0.205
    for (index, color) in colors.enumerated() {
        let rect = NSRect(x: startX + CGFloat(index) * spacing, y: y, width: diameter, height: diameter)
        let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -diameter * 0.55, dy: -diameter * 0.55))
        color.withAlphaComponent(0.20).setFill()
        halo.fill()
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

func drawHighlights(size: CGFloat) {
    let top = NSBezierPath()
    top.move(to: CGPoint(x: size * 0.24, y: size * 0.76))
    top.curve(
        to: CGPoint(x: size * 0.76, y: size * 0.78),
        controlPoint1: CGPoint(x: size * 0.38, y: size * 0.86),
        controlPoint2: CGPoint(x: size * 0.62, y: size * 0.87)
    )
    top.lineWidth = size * 0.010
    NSColor.white.withAlphaComponent(0.18).setStroke()
    top.stroke()

    let rim = rounded(NSRect(x: size * 0.035, y: size * 0.035, width: size * 0.93, height: size * 0.93), radius: size * 0.215)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    rim.lineWidth = size * 0.006
    rim.stroke()
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func resize(_ image: NSImage, to size: NSSize) -> NSImage {
    let result = NSImage(size: size)
    result.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    result.unlockFocus()
    return result
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIconGenerator", code: 1)
    }
    try png.write(to: url)
}

func writeICNS(chunks: [(String, URL)], to url: URL) throws {
    var body = Data()
    for (type, pngURL) in chunks {
        let png = try Data(contentsOf: pngURL)
        guard let typeData = type.data(using: .ascii), typeData.count == 4 else {
            throw NSError(domain: "AppIconGenerator", code: 2)
        }
        body.append(typeData)
        appendUInt32BE(UInt32(png.count + 8), to: &body)
        body.append(png)
    }

    var result = Data("icns".utf8)
    appendUInt32BE(UInt32(body.count + 8), to: &result)
    result.append(body)
    try result.write(to: url)
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}
