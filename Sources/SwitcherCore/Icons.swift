import AppKit

/// Coloured badges that tell accounts apart in the menu and on launcher apps.
public enum Badge {
    public static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (66, 133, 180), (76, 150, 96), (150, 96, 180), (190, 80, 110),
        (60, 150, 150), (90, 110, 200), (200, 150, 50), (80, 86, 100),
    ]

    public static func color(index: Int) -> NSColor {
        let c = palette[((index % palette.count) + palette.count) % palette.count]
        return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
    }

    /// Assigned once and remembered: a hash of the name would regularly give two profiles
    /// the same colour, and a colour that changes later would defeat the point.
    public static func colorIndex(for id: String, settings: Settings, alive: [String]) -> Int {
        var assigned = settings.colors
        if let known = assigned[id] { return known % palette.count }
        var use = [Int](repeating: 0, count: palette.count)
        for (other, index) in assigned where alive.contains(other) { use[index % palette.count] += 1 }
        var pick = 0
        for i in 1..<use.count where use[i] < use[pick] { pick = i }
        assigned[id] = pick
        settings.set("Colors", assigned)
        return pick
    }

    public static func letter(for label: String) -> String {
        let c = label.first { $0.isLetter || $0.isNumber } ?? label.first ?? "?"
        return String(c).uppercased()
    }

    /// A round avatar for menus: readable at 16 pt, unlike a badge on a shrunken icon.
    public static func avatar(letter: String, color: NSColor, size: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            drawLetter(letter, in: rect, fontSize: size * 0.58)
            return true
        }
    }

    /// Claude's icon with the badge in the corner, for launcher apps. Below 32 px a letter
    /// is an unreadable smudge, so the colour alone does the work there.
    public static func badged(base: NSImage, letter: String?, color: NSColor?, pixels: Int) -> NSBitmapImageRep {
        render(pixels: pixels) { s in
            base.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)
            guard let letter, let color else { return }
            let d = s * 0.44
            let rect = NSRect(x: s - d - s * 0.07, y: s * 0.07, width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -s * 0.025, dy: -s * 0.025)).fill()
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if pixels >= 32 { drawLetter(letter, in: rect, fontSize: d * 0.58) }
        }
    }

    public static func render(pixels: Int, draw: (CGFloat) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func drawLetter(_ letter: String, in rect: NSRect, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
        let width = text.size().width
        // Centre the capital letter itself, not the line box with its descender.
        let baseline = rect.midY - font.capHeight / 2
        text.draw(at: NSPoint(x: rect.midX - width / 2, y: baseline + font.descender))
    }

    /// An .icns built from one drawing, through iconutil.
    public static func writeICNS(to output: URL, render: (Int) -> NSBitmapImageRep) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory.appendingPathComponent("cps-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = render(points * scale).representation(using: .png, properties: [:]) else {
                    throw SwitcherError("could not encode \(name)")
                }
                try png.write(to: iconset.appendingPathComponent(name))
            }
        }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        tool.arguments = ["-c", "icns", "-o", output.path, iconset.path]
        try tool.run()
        tool.waitUntilExit()
        if tool.terminationStatus != 0 { throw SwitcherError("iconutil failed (\(tool.terminationStatus))") }
    }
}

/// The switcher's own icon, the same drawing as docs/images/logo.svg (a 1024 grid): two
/// accounts, the front one wearing the green ring the panel uses for "open". Drawn rather
/// than shipped, so there is no image asset to keep in sync, and nothing borrowed from
/// Claude's branding.
public enum AppIconArt {
    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    public static func render(pixels: Int) -> NSBitmapImageRep {
        Badge.render(pixels: pixels) { s in
            let k = s / 1024
            // SVG coordinates grow downwards, AppKit's upwards.
            func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: (cx - rx) * k, y: s - (cy + ry) * k, width: 2 * rx * k, height: 2 * ry * k))
            }
            func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ fill: NSColor) {
                fill.setFill()
                oval(cx, cy, r, r).fill()
            }
            func person(in cx: CGFloat, _ cy: CGFloat, opacity: CGFloat) {
                NSGraphicsContext.saveGraphicsState()
                oval(cx, cy, 176, 176).addClip()
                NSColor(white: 1, alpha: opacity).setFill()
                oval(cx, cy - 42, 58, 58).fill()
                oval(cx, cy + 112, 112, 86).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
            let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
            NSGradient(starting: color(0xF7F9FC), ending: color(0xD8E0EB))?.draw(in: squircle, angle: -90)
            let edge = NSBezierPath(roundedRect: body.insetBy(dx: k, dy: k), xRadius: 184 * k, yRadius: 184 * k)
            edge.lineWidth = 2 * k
            NSColor(white: 0, alpha: 0.07).setStroke()
            edge.stroke()

            disc(392, 398, 176, color(0xC0566F))
            person(in: 392, 398, opacity: 0.85)
            disc(588, 584, 218, color(0x2EAA5C))
            disc(588, 584, 197, .white)
            disc(588, 584, 176, color(0x3E7FB4))
            person(in: 588, 584, opacity: 0.92)
        }
    }
}

/// The menu bar icon: the logo reduced to one colour. A template image, so macOS tints it
/// for light and dark menu bars and for the highlighted state; the back account is drawn
/// half transparent, which the tint keeps as a lighter shade.
public enum MenuBarIcon {
    public static func image(points: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            let k = rect.width / 18
            func oval(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: (cx - r) * k, y: (cy - r) * k, width: 2 * r * k, height: 2 * r * k))
            }
            let back = oval(6.3, 6.3, 4.8)
            // The gap around the front account is cut out of the back one.
            let cut = oval(11.2, 11.2, 4.6)
            NSGraphicsContext.saveGraphicsState()
            let keep = NSBezierPath(rect: rect)
            keep.append(cut)
            keep.windingRule = .evenOdd
            keep.addClip()
            NSColor.black.withAlphaComponent(0.55).setFill()
            back.fill()
            NSGraphicsContext.restoreGraphicsState()
            let ring = oval(11.2, 11.2, 5.4)
            ring.lineWidth = 1.2 * k
            NSColor.black.setStroke()
            ring.stroke()
            NSColor.black.setFill()
            oval(11.2, 11.2, 3.6).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Claude Profile Switcher"
        return image
    }
}
