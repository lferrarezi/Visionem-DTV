import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("assets/Visionem.iconset", isDirectory: true)
let icns = root.appendingPathComponent("assets/Visionem.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.13, alpha: 1).setFill()
    rect.fill()

    let inset = CGFloat(size) * 0.095
    let body = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                            xRadius: CGFloat(size) * 0.16,
                            yRadius: CGFloat(size) * 0.16)
    NSColor(calibratedRed: 0.02, green: 0.19, blue: 0.24, alpha: 1).setFill()
    body.fill()

    let screen = NSBezierPath(roundedRect: NSRect(x: CGFloat(size) * 0.19,
                                                 y: CGFloat(size) * 0.29,
                                                 width: CGFloat(size) * 0.62,
                                                 height: CGFloat(size) * 0.42),
                              xRadius: CGFloat(size) * 0.045,
                              yRadius: CGFloat(size) * 0.045)
    NSColor(calibratedRed: 0.07, green: 0.46, blue: 0.52, alpha: 1).setFill()
    screen.fill()

    let glow = NSBezierPath(ovalIn: NSRect(x: CGFloat(size) * 0.33,
                                          y: CGFloat(size) * 0.40,
                                          width: CGFloat(size) * 0.34,
                                          height: CGFloat(size) * 0.18))
    NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.20, alpha: 0.92).setFill()
    glow.fill()

    let mast = NSBezierPath()
    mast.move(to: NSPoint(x: CGFloat(size) * 0.50, y: CGFloat(size) * 0.72))
    mast.line(to: NSPoint(x: CGFloat(size) * 0.50, y: CGFloat(size) * 0.84))
    mast.lineWidth = max(2, CGFloat(size) * 0.018)
    NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
    mast.stroke()

    let left = NSBezierPath()
    left.move(to: NSPoint(x: CGFloat(size) * 0.50, y: CGFloat(size) * 0.82))
    left.line(to: NSPoint(x: CGFloat(size) * 0.34, y: CGFloat(size) * 0.93))
    left.lineWidth = max(2, CGFloat(size) * 0.018)
    left.stroke()

    let right = NSBezierPath()
    right.move(to: NSPoint(x: CGFloat(size) * 0.50, y: CGFloat(size) * 0.82))
    right.line(to: NSPoint(x: CGFloat(size) * 0.66, y: CGFloat(size) * 0.93))
    right.lineWidth = max(2, CGFloat(size) * 0.018)
    right.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(size) * 0.13, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let text = "BR"
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (CGFloat(size) - textSize.width) / 2,
                          y: CGFloat(size) * 0.145),
              withAttributes: attrs)

    image.unlockFocus()
    return image
}

for (name, size) in sizes {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not render \(name)")
    }
    try data.write(to: iconset.appendingPathComponent(name), options: [.atomic])
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    fatalError("iconutil failed")
}

try? FileManager.default.removeItem(at: iconset)
print(icns.path)
