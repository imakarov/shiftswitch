// Renders the app icon (1024 px master) with CoreGraphics: a keycap with a Shift arrow on a squircle.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle body (Apple grid: 824 px content, 100 px margin), with drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); bodyPath.fill()
ctx.restoreGState()
bodyPath.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.36, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.56, green: 0.25, blue: 0.93, alpha: 1)])!.draw(in: body, angle: -60)

// Keycap: base (darker, gives depth) + top face.
let capBase = NSRect(x: 222, y: 238, width: 580, height: 560)
NSColor(white: 0, alpha: 0.22).setFill()
NSBezierPath(roundedRect: capBase.offsetBy(dx: 0, dy: -26), xRadius: 96, yRadius: 96).fill()
NSColor(srgbRed: 0.88, green: 0.89, blue: 0.95, alpha: 1).setFill()
NSBezierPath(roundedRect: capBase, xRadius: 96, yRadius: 96).fill()
let face = capBase.insetBy(dx: 34, dy: 34).offsetBy(dx: 0, dy: 14)
NSGradient(colors: [.white, NSColor(srgbRed: 0.95, green: 0.95, blue: 0.99, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: face, xRadius: 70, yRadius: 70), angle: -90)

// Shift arrow (outline), centred in the upper part of the face.
let ink = NSColor(srgbRed: 0.36, green: 0.30, blue: 0.95, alpha: 1)
let cx = face.midX, top = face.maxY - 70
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: cx, y: top))
arrow.line(to: NSPoint(x: cx + 150, y: top - 150))
arrow.line(to: NSPoint(x: cx + 70, y: top - 150))
arrow.line(to: NSPoint(x: cx + 70, y: top - 260))
arrow.line(to: NSPoint(x: cx - 70, y: top - 260))
arrow.line(to: NSPoint(x: cx - 70, y: top - 150))
arrow.line(to: NSPoint(x: cx - 150, y: top - 150))
arrow.close()
arrow.lineWidth = 30; arrow.lineJoinStyle = .round
ink.setStroke(); arrow.stroke()

// "A ⇄ Я" legend under the arrow.
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: ink, .paragraphStyle: para, .kern: 4]
("A ⇄ Я" as NSString).draw(in: NSRect(x: face.minX, y: face.minY + 40, width: face.width, height: 120), withAttributes: attrs)

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
