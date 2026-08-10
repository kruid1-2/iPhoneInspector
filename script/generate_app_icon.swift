import AppKit
import Foundation

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsURL = rootURL.appendingPathComponent("Assets", isDirectory: true)
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("iPhoneInspector-\(UUID().uuidString).iconset", isDirectory: true)

try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "Icon", code: 1)
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = CGFloat(size) * 0.045
    let backgroundRect = canvas.insetBy(dx: inset, dy: inset)
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: CGFloat(size) * 0.22,
        yRadius: CGFloat(size) * 0.22
    )
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.49, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.76, alpha: 1)
    ])
    gradient?.draw(in: background, angle: -55)

    let phoneRect = NSRect(
        x: CGFloat(size) * 0.27,
        y: CGFloat(size) * 0.18,
        width: CGFloat(size) * 0.37,
        height: CGFloat(size) * 0.65
    )
    let phone = NSBezierPath(
        roundedRect: phoneRect,
        xRadius: CGFloat(size) * 0.065,
        yRadius: CGFloat(size) * 0.065
    )
    NSColor.white.withAlphaComponent(0.96).setStroke()
    phone.lineWidth = CGFloat(size) * 0.047
    phone.stroke()

    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: CGFloat(size) * 0.405, y: CGFloat(size) * 0.765))
    speaker.line(to: NSPoint(x: CGFloat(size) * 0.505, y: CGFloat(size) * 0.765))
    speaker.lineWidth = CGFloat(size) * 0.025
    speaker.lineCapStyle = .round
    speaker.stroke()

    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: CGFloat(size) * 0.31, y: CGFloat(size) * 0.49))
    pulse.line(to: NSPoint(x: CGFloat(size) * 0.38, y: CGFloat(size) * 0.49))
    pulse.line(to: NSPoint(x: CGFloat(size) * 0.42, y: CGFloat(size) * 0.57))
    pulse.line(to: NSPoint(x: CGFloat(size) * 0.47, y: CGFloat(size) * 0.40))
    pulse.line(to: NSPoint(x: CGFloat(size) * 0.52, y: CGFloat(size) * 0.51))
    pulse.line(to: NSPoint(x: CGFloat(size) * 0.60, y: CGFloat(size) * 0.51))
    pulse.lineWidth = CGFloat(size) * 0.026
    pulse.lineJoinStyle = .round
    pulse.lineCapStyle = .round
    pulse.stroke()

    let lensRect = NSRect(
        x: CGFloat(size) * 0.54,
        y: CGFloat(size) * 0.23,
        width: CGFloat(size) * 0.25,
        height: CGFloat(size) * 0.25
    )
    let lens = NSBezierPath(ovalIn: lensRect)
    NSColor.white.setStroke()
    lens.lineWidth = CGFloat(size) * 0.043
    lens.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: CGFloat(size) * 0.745, y: CGFloat(size) * 0.27))
    handle.line(to: NSPoint(x: CGFloat(size) * 0.84, y: CGFloat(size) * 0.17))
    handle.lineWidth = CGFloat(size) * 0.05
    handle.lineCapStyle = .round
    handle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2)
    }
    return png
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024)
]

for (name, size) in variants {
    try renderIcon(size: size).write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    "-o", assetsURL.appendingPathComponent("AppIcon.icns").path,
    iconsetURL.path
]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "Icon", code: Int(process.terminationStatus))
}

print("Generated \(assetsURL.appendingPathComponent("AppIcon.icns").path)")
