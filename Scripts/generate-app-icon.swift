import AppKit

let catalog = URL(fileURLWithPath: "LocalTranscription/Assets.xcassets")
let directory = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func render(pixels: Int, mac: Bool, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    precondition(NSGraphicsContext.current != nil)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    let face = mac ? NSRect(x: 88, y: 88, width: 848, height: 848)
                   : NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = NSBezierPath(roundedRect: face, xRadius: mac ? 190 : 0, yRadius: mac ? 190 : 0)
    if mac {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.systemBlue.setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.66, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.18, green: 0.25, blue: 0.88, alpha: 1))!
        .draw(in: background, angle: -75)
    NSGraphicsContext.saveGraphicsState()
    let glyph = NSAffineTransform()
    glyph.translateX(by: face.minX, yBy: face.minY)
    glyph.scale(by: face.width / 1024)
    glyph.concat()
    NSColor.white.setFill()
    for (index, height) in [130.0, 240, 340, 240, 130].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 290 + Double(index) * 96, y: 650 - height / 2,
                                         width: 60, height: height), xRadius: 30, yRadius: 30).fill()
    }
    for (y, width) in [(330.0, 444.0), (235.0, 312.0)] {
        NSBezierPath(roundedRect: NSRect(x: 290, y: y, width: width, height: 44),
                     xRadius: 22, yRadius: 22).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    let output: NSBitmapImageRep
    if mac {
        output = bitmap
    } else {
        let opaque = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                               bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        opaque.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        output = NSBitmapImageRep(cgImage: opaque.makeImage()!)
    }
    let png = output.representation(using: .png, properties: [:])!
    try png.write(to: directory.appendingPathComponent(filename))
    let check = NSBitmapImageRep(data: png)!
    precondition(check.pixelsWide == pixels && check.pixelsHigh == pixels && check.hasAlpha == mac)
    let cornerAlpha = check.colorAt(x: 0, y: 0)!.alphaComponent
    precondition(mac ? cornerAlpha < 0.05 : cornerAlpha == 1)
    precondition(check.colorAt(x: pixels / 2, y: pixels / 2)!.blueComponent > 0.5)
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(size)@\(scale)x.png"
        try render(pixels: size * scale, mac: true, filename: filename)
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try render(pixels: 1024, mac: false, filename: "ios-1024.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appendingPathComponent("Contents.json"))
print("Generated and checked all 11 app icon images in \(directory.path)")
