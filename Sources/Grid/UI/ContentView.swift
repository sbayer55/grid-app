import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    // Last measured menu heights; the first guess only matters for the frame a menu first appears in.
    @State private var columnMenuHeight: CGFloat = 480
    @State private var filterMenuHeight: CGFloat = 340
    @State private var rowMenuHeight: CGFloat = 140

    var body: some View {
        let theme = state.theme
        ZStack {
            WindowBackground(theme: theme)

            VStack(spacing: 0) {
                TabBarView()
                Rectangle().fill(theme.text.swiftUI.opacity(0.08)).frame(height: 1)
                ZStack(alignment: .topLeading) {
                    CanvasRepresentable(state: state)
                    overlays
                }
                .clipped()
                Rectangle().fill(theme.text.swiftUI.opacity(0.08)).frame(height: 1)
                StatusBarView()
            }
            .ignoresSafeArea(.container, edges: .top)   // tabs share the title bar row with the traffic lights

            if state.paletteOpen {
                CommandPaletteView()
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .background(WindowConfigurator(title: state.title + (state.dirty ? " — edited" : "")))
        .foregroundStyle(theme.text.swiftUI)
        .font(Theme.uiFont(12))
        .animation(.easeOut(duration: 0.18), value: state.paletteOpen)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.selectedCardID)
        .animation(.easeOut(duration: 0.16), value: state.columnMenu)
        .animation(.easeOut(duration: 0.16), value: state.rowMenu)
        .preferredColorScheme(.dark)
    }

    /// Room for a menu between the top and bottom of the canvas area, less an 8pt margin each side.
    private var maxMenuHeight: CGFloat { max(120, state.viewportSize.height - 16) }

    private var overlays: some View {
        ZStack(alignment: .topLeading) {
            if let m = state.columnMenu {
                // Menus stay inside the canvas area: their measured size clamps where they open,
                // and one taller than the area is capped to it and scrolls.
                let x = max(8, min(m.anchor.x, state.viewportSize.width - ColumnMenuView.width - 16))
                let y = max(8, min(m.anchor.y, state.viewportSize.height - columnMenuHeight - 8))
                ColumnMenuView(menu: m, maxHeight: maxMenuHeight)
                    .readHeight { columnMenuHeight = $0 }
                    .placed(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                    .zIndex(20)
                if m.showFilter {
                    // The flyout opens to the right of the menu, or to the left when there is no room.
                    let gap: CGFloat = 6
                    let fitsRight = x + ColumnMenuView.width + gap + FilterValuesView.width + 8 <= state.viewportSize.width
                    FilterValuesView(menu: m, maxHeight: maxMenuHeight)
                        .readHeight { filterMenuHeight = $0 }
                        .placed(x: max(8, fitsRight ? x + ColumnMenuView.width + gap : x - gap - FilterValuesView.width),
                                y: max(8, min(y + 44, state.viewportSize.height - filterMenuHeight - 8)))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: fitsRight ? .topLeading : .topTrailing)))
                        .zIndex(21)
                }
            }
            if let m = state.rowMenu {
                RowMenuView(menu: m, maxHeight: maxMenuHeight)
                    .readHeight { rowMenuHeight = $0 }
                    .placed(x: max(8, min(m.anchor.x, state.viewportSize.width - RowMenuView.width - 16)),
                            y: max(8, min(m.anchor.y, state.viewportSize.height - rowMenuHeight - 8)))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                    .zIndex(20)
            }
            if let card = state.selectedCard {
                ViewPanelView(card: card)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(25)
            }
            if let toast = state.toast {
                ToastView(text: toast.text)
                    .id(toast.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 52)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(30)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.toast)
    }
}

// MARK: - Window chrome

struct WindowBackground: View {
    let theme: Theme
    var body: some View {
        ZStack {
            if theme.blur { VisualEffectView(material: .hudWindow) }
            theme.base.swiftUI.opacity(theme.blur ? theme.windowOpacity : 1)
        }
        .ignoresSafeArea()
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Makes the hosting window transparent with a hidden, full-size title bar.
struct WindowConfigurator: NSViewRepresentable {
    var title: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { configure(v.window) } }
    private func configure(_ window: NSWindow?) {
        guard let w = window else { return }
        AppDelegate.mainWindow = w
        w.isReleasedWhenClosed = false   // closing only hides it; AppDelegate re-shows it on activation
        w.title = title
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isMovableByWindowBackground = false
        // An empty compact toolbar makes the title bar as tall as the tab row, so the traffic lights centre on it.
        if w.toolbar == nil {
            let toolbar = NSToolbar(identifier: "grid.titlebar")
            toolbar.showsBaselineSeparator = false
            w.toolbar = toolbar
        }
        w.toolbarStyle = .unifiedCompact
        w.titlebarSeparatorStyle = .none
        w.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Empty space in the tab row behaves like a native title bar: drag moves the window and a
/// double-click runs the system's title-bar action (zoom unless the user chose otherwise).
/// Sits behind the tabs, so their buttons still take their own clicks.
struct TitleBarDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }   // we drive the drag ourselves
        override func mouseDown(with event: NSEvent) {
            guard let window = window else { return }
            if event.clickCount == 2 {
                switch TitleBarDragArea.doubleClickAction() {
                case .zoom: window.zoom(nil)
                case .minimize: window.miniaturize(nil)
                case .none: break
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    enum DoubleClickAction: Equatable { case zoom, minimize, none }

    /// System Settings → Desktop & Dock → "Double-click a window's title bar to".
    static func doubleClickAction(defaults: UserDefaults = .standard) -> DoubleClickAction {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        default: return .zoom
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) {}
}

// MARK: - Small overlay pieces

extension View {
    /// Puts a floating menu at a point in the canvas area. The menu is offered the whole area
    /// whatever `y` is, so its height depends only on its own cap and not on where it sits.
    func placed(x: CGFloat, y: CGFloat) -> some View {
        padding(.leading, x)
            .offset(y: y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Reports the view's laid-out height, now and whenever it changes.
    func readHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { report(g.size.height) }
                .onChange(of: g.size.height) { _, h in report(h) }
        })
    }
}

/// Fit and zoom, sized to sit at the right end of the status bar.
struct ZoomControls: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let theme = state.theme
        HStack(spacing: 6) {
            Button { state.fit() } label: {
                HStack(spacing: 8) { Text("fit"); KeyCap("⌘0") }
            }
            .buttonStyle(ChipStyle(theme: theme, height: 22))
            HStack(spacing: 0) {
                Button { state.zoom(to: state.canvas.zoom / 1.2) } label: { Image(systemName: "minus").frame(width: 26, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                Text("\(Int((state.canvas.zoom * 100).rounded()))%")
                    .font(Theme.uiFont(11, weight: .semibold)).frame(width: 46)
                Button { state.zoom(to: state.canvas.zoom * 1.2) } label: { Image(systemName: "plus").frame(width: 26, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
            .background(Capsule().fill(theme.mantle.swiftUI.opacity(0.9)))
            .overlay(Capsule().stroke(theme.lavender.swiftUI.opacity(0.22), lineWidth: 1))
        }
        .foregroundStyle(theme.text.swiftUI)
    }
}

struct ToastView: View {
    @EnvironmentObject var state: AppState
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.uiFont(11.5))
            .foregroundStyle(state.theme.bright.swiftUI)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(state.theme.mantle.swiftUI.opacity(0.96)))
            .overlay(Capsule().stroke(state.theme.accent.swiftUI.opacity(0.45), lineWidth: 1))
    }
}

struct KeyCap: View {
    @EnvironmentObject var state: AppState
    let text: String
    var dark = false
    init(_ text: String, dark: Bool = false) { self.text = text; self.dark = dark }
    var body: some View {
        Text(text)
            .font(Theme.uiFont(10, weight: .semibold))
            .foregroundStyle(dark ? state.theme.crust.swiftUI : state.theme.text.swiftUI)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 6).fill(dark ? state.theme.crust.swiftUI.opacity(0.2) : state.theme.surface1.swiftUI.opacity(0.8)))
    }
}

/// Pill button used for chips (run ⌘K, fit, pivot/chart/filter).
struct ChipStyle: ButtonStyle {
    var theme: Theme
    var accent = false
    var height: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.uiFont(11, weight: accent ? .bold : .semibold))
            .foregroundStyle(accent ? theme.crust.swiftUI : theme.text.swiftUI)
            .padding(.leading, 10).padding(.trailing, 4)
            .frame(height: height)
            .background(Capsule().fill(accent ? theme.accent.swiftUI : theme.mantle.swiftUI.opacity(0.96)))
            .overlay(Capsule().stroke(accent ? Color.clear : theme.text.swiftUI.opacity(0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Small rounded toggle-ish button used in menus and the panel.
struct ToolButtonStyle: ButtonStyle {
    var theme: Theme
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.uiFont(11, weight: .semibold))
            .foregroundStyle(on ? theme.bright.swiftUI : theme.text.swiftUI)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.accent.swiftUI.opacity(0.18) : theme.surface0.swiftUI.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? theme.accent.swiftUI : theme.text.swiftUI.opacity(0.12), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Floating card chrome: rounded, gradient ring, blurred dark body.
struct FloatingCard<Content: View>: View {
    @EnvironmentObject var state: AppState
    let width: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        let theme = state.theme
        content
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 13).fill(theme.mantle.swiftUI.opacity(0.94)))
            .background(VisualEffectView(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 13)))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LinearGradient(colors: [theme.accent.swiftUI, theme.blue.swiftUI, theme.teal.swiftUI], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
            .shadow(color: theme.accent.swiftUI.opacity(0.18), radius: 20)
    }
}

struct SectionLabel: View {
    @EnvironmentObject var state: AppState
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.uiFont(10, weight: .bold))
            .tracking(1)
            .foregroundStyle(state.theme.subtext.swiftUI)
            .padding(.top, 10).padding(.bottom, 4)
    }
}
