import AppKit
import SwiftUI

/// Catppuccin Mocha by default. Override any token with `~/.config/grid/theme.json`,
/// e.g. `{ "accent": "#89b4fa", "animateBorders": false, "blur": true }`.
struct Theme: Equatable {
    var name = "Catppuccin Mocha"
    var crust = NSColor(hex: "#11111b")
    var mantle = NSColor(hex: "#181825")
    var base = NSColor(hex: "#1e1e2e")
    var surface0 = NSColor(hex: "#313244")
    var surface1 = NSColor(hex: "#45475a")
    var surface2 = NSColor(hex: "#585b70")
    var text = NSColor(hex: "#cdd6f4")
    var subtext = NSColor(hex: "#a6adc8")
    var bright = NSColor(hex: "#f5e0ff")
    var accent = NSColor(hex: "#cba6f7")   // mauve
    var blue = NSColor(hex: "#89b4fa")
    var lavender = NSColor(hex: "#b4befe")
    var teal = NSColor(hex: "#94e2d5")
    var green = NSColor(hex: "#a6e3a1")
    var yellow = NSColor(hex: "#f9e2af")
    var peach = NSColor(hex: "#fab387")
    var red = NSColor(hex: "#f38ba8")
    var pink = NSColor(hex: "#f5c2e7")

    var animateBorders = true
    var blur = true
    var windowOpacity: CGFloat = 0.82

    /// Border gradient (conic) stops.
    var borderGradient: [NSColor] { [accent, blue, teal, pink, accent] }
    /// Series palette for charts, in order.
    var series: [NSColor] { [teal, blue, accent, yellow, red, peach, green, pink] }

    /// Semantic colors for well-known status words (conditional formatting by value).
    func color(forValue v: String) -> NSColor? {
        switch v.lowercased() {
        case "shipped", "delivered", "done", "complete", "completed", "active", "ok", "pass", "passed", "yes", "true": return green
        case "pending", "waiting", "in progress", "open", "review", "hold": return yellow
        case "backorder", "failed", "fail", "error", "blocked", "cancelled", "canceled", "no", "false", "overdue": return red
        case "invoiced", "paid", "closed", "archived": return accent
        default: return nil
        }
    }

    static let `default` = Theme()

    /// Loads overrides from ~/.config/grid/theme.json if present.
    static func load() -> Theme {
        var t = Theme()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/grid/theme.json")
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return t }
        func c(_ key: String, _ target: inout NSColor) { if let s = obj[key] as? String { target = NSColor(hex: s) } }
        c("crust", &t.crust); c("mantle", &t.mantle); c("base", &t.base)
        c("surface0", &t.surface0); c("surface1", &t.surface1); c("surface2", &t.surface2)
        c("text", &t.text); c("subtext", &t.subtext); c("bright", &t.bright)
        c("accent", &t.accent); c("blue", &t.blue); c("lavender", &t.lavender); c("teal", &t.teal)
        c("green", &t.green); c("yellow", &t.yellow); c("peach", &t.peach); c("red", &t.red); c("pink", &t.pink)
        if let n = obj["name"] as? String { t.name = n }
        if let b = obj["animateBorders"] as? Bool { t.animateBorders = b }
        if let b = obj["blur"] as? Bool { t.blur = b }
        if let o = obj["windowOpacity"] as? Double { t.windowOpacity = o }
        return t
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255; g = CGFloat((v >> 16) & 0xff) / 255; b = CGFloat((v >> 8) & 0xff) / 255; a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255; g = CGFloat((v >> 8) & 0xff) / 255; b = CGFloat(v & 0xff) / 255; a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func alpha(_ a: CGFloat) -> NSColor { withAlphaComponent(a) }
    var swiftUI: Color { Color(nsColor: self) }
}

extension Theme {
    static let mono = "JetBrainsMono-Regular"

    /// JetBrains Mono if installed, otherwise the system monospaced font.
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // The renderer asks for a font per text run; looking one up by name each time is the
        // single largest cost of a redraw, so resolved fonts are kept.
        let key = FontKey(size: size, weight: weight.rawValue)
        fontLock.lock(); defer { fontLock.unlock() }
        if let f = fontCache[key] { return f }
        if fontCache.count > 64 { fontCache.removeAll() }   // zooming asks for many one-off sizes
        let f = resolveFont(size, weight: weight)
        fontCache[key] = f
        return f
    }

    private struct FontKey: Hashable { let size: CGFloat; let weight: CGFloat }
    private static var fontCache: [FontKey: NSFont] = [:]
    private static let fontLock = NSLock()

    private static func resolveFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return NSFont(name: name, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrainsMono-Regular", size: size) != nil { return .custom("JetBrainsMono-Regular", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
