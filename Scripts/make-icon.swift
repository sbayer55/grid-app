// Draws the Grid app icon and writes a 1024×1024 PNG.  Usage: swift Scripts/make-icon.swift out.png
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)! }
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// macOS icon plate: 824pt square centred in the 1024 canvas.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = rounded(plate, 186)

// Drop shadow + body (Catppuccin Mocha base → crust).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(platePath); ctx.setFillColor(rgb(0x1e1e2e)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2a2a40), rgb(0x11111b)]), start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
ctx.restoreGState()

// Gradient ring (mauve → blue), like the app's card borders.
let ring: CGFloat = 14
ctx.saveGState()
ctx.addPath(platePath); ctx.addPath(rounded(plate.insetBy(dx: ring, dy: ring), 186 - ring)); ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([rgb(0xcba6f7), rgb(0x89b4fa)]), start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
ctx.restoreGState()

// 3×3 cells: a header row, body cells, and one selected cell.
let inset: CGFloat = 138, gap: CGFloat = 30, n = 3
let area = plate.insetBy(dx: inset, dy: inset)
let cell = (area.width - gap * CGFloat(n - 1)) / CGFloat(n)
for row in 0..<n {
    for col in 0..<n {
        let r = CGRect(x: area.minX + CGFloat(col) * (cell + gap), y: area.maxY - cell - CGFloat(row) * (cell + gap), width: cell, height: cell)
        let path = rounded(r, 36)
        if row == 1 && col == 1 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xcba6f7, 0.75))
            ctx.addPath(path); ctx.setFillColor(rgb(0xcba6f7)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(gradient([rgb(0xdcc0ff), rgb(0xb48cf2)]), start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
            ctx.restoreGState()
        } else {
            ctx.addPath(path)
            ctx.setFillColor(row == 0 ? rgb(0x7f849c, 0.75) : rgb(0x45475a, 0.9))
            ctx.fillPath()
        }
    }
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
