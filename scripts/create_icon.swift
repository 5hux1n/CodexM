import AppKit
let output = CommandLine.arguments[1]
let fm = FileManager.default
try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.21, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192).fill()
        let colors = [NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.56, alpha: 1), NSColor(calibratedRed: 0.47, green: 0.73, blue: 0.70, alpha: 1), NSColor(calibratedRed: 0.77, green: 0.94, blue: 0.87, alpha: 1)]
        for i in 0..<3 {
            let y = CGFloat(282 + i * 125)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 255, y: y + 100)); path.line(to: NSPoint(x: 512, y: y + 220)); path.line(to: NSPoint(x: 769, y: y + 100)); path.line(to: NSPoint(x: 512, y: y - 20)); path.close()
            colors[i].setFill(); path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let manifest: [String: Any] = ["images": entries, "info": ["author": "CodexM", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
