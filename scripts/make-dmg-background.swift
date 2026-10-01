// Renders the DevStack installer background at 1x and 2x.
//
// Usage: swift scripts/make-dmg-background.swift VERSION ONE_X_PNG TWO_X_PNG
//
// Combine the two renders into the HiDPI TIFF that packaging embeds:
//   tiffutil -cathidpicheck one-x.png two-x@2x.png -out Packaging/dmg-background.tiff
//
// The window is 660x420 points; icon centres are (165, 200) and (495, 200),
// matching the layout scripts/write-dmg-dsstore.py writes. Finder always draws
// icon labels in black when a custom background picture is set, so each label
// sits on a light plate to stay readable against the dark artwork.
import AppKit

let arguments = CommandLine.arguments
let version = arguments.count > 1 ? arguments[1] : ""
let oneXPath = arguments.count > 2 ? arguments[2] : "dmg-background.png"
let twoXPath = arguments.count > 3 ? arguments[3] : "dmg-background@2x.png"

let points = NSSize(width: 660, height: 420)

func drawDesign() {
    guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

    // Background gradient.
    let colors = [
        NSColor(calibratedRed: 0.145, green: 0.145, blue: 0.165, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.085, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: points.height), end: CGPoint(x: 0, y: 0), options: [])

    // Soft accent glow behind the title.
    let glowColors = [
        NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.16).cgColor,
        NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.0).cgColor,
    ]
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: points.width / 2, y: points.height - 40), startRadius: 0,
                               endCenter: CGPoint(x: points.width / 2, y: points.height - 40), endRadius: 260, options: [])

    func drawCentered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.boundingRect(with: NSSize(width: points.width, height: 200), options: [.usesLineFragmentOrigin])
        string.draw(at: NSPoint(x: (points.width - bounds.width) / 2, y: points.height - top - bounds.height))
    }

    // Light plates behind the Finder labels: Finder draws those in black even
    // over a dark picture, so they need a bright backing to stay readable.
    // Finder places the labels 317 points below the window's top edge, and the
    // image starts 32.5 points down (title bar), so the plates centre at 284.5.
    func drawLabelPlate(centerX: CGFloat) {
        let width: CGFloat = 150
        let height: CGFloat = 30
        let centerY = points.height - 284.5
        let rect = NSRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                          color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 0.96).setFill()
        path.fill()
        context.restoreGState()
    }

    drawCentered("DevStack", font: .systemFont(ofSize: 34, weight: .bold), color: NSColor(calibratedWhite: 0.97, alpha: 1), top: 42)
    drawCentered("Drag DevStack into Applications to install",
                 font: .systemFont(ofSize: 14, weight: .regular), color: NSColor(calibratedWhite: 0.72, alpha: 1), top: 90)

    drawLabelPlate(centerX: 165)
    drawLabelPlate(centerX: 495)

    // Install arrow between the two icon slots (y = 200 from the top).
    let arrowY = points.height - 200
    let accent = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 0.9)
    accent.setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 258, y: arrowY))
    arrow.line(to: NSPoint(x: 386, y: arrowY))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 376, y: arrowY + 9))
    head.line(to: NSPoint(x: 392, y: arrowY))
    head.line(to: NSPoint(x: 376, y: arrowY - 9))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let caption = version.isEmpty ? "Apple Silicon · macOS 27+" : "Version \(version) · Apple Silicon · macOS 27+"
    drawCentered(caption, font: .systemFont(ofSize: 11, weight: .regular), color: NSColor(calibratedWhite: 0.55, alpha: 1), top: 372)
}

func render(scale: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(points.width) * scale,
                                     pixelsHigh: Int(points.height) * scale,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { exit(1) }
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    drawDesign()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

writePNG(render(scale: 1), to: oneXPath)
writePNG(render(scale: 2), to: twoXPath)
