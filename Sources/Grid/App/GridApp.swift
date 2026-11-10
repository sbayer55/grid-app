import SwiftUI
import AppKit

/// Keeps the one main window reachable: switching to Grid (⌘Tab, Dock click) always brings it forward,
/// even if it was minimized or closed. The workbook lives in `AppState.shared`, so a re-shown window loses nothing.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `WindowConfigurator` once the SwiftUI window exists.
    static var mainWindow: NSWindow?

    func applicationDidBecomeActive(_ notification: Notification) { Self.showMainWindow() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return false   // we re-show the existing window; don't let the scene open a second one
    }

    static func showMainWindow() {
        guard NSApp.modalWindow == nil,
              let w = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        if !w.isVisible || !w.isKeyWindow, w.attachedSheet == nil { w.makeKeyAndOrderFront(nil) }
    }
}

@main
struct GridApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workbook") { state.newWorkbook() }.keyboardShortcut("n", modifiers: .command)
                Button("Open…") { state.open() }.keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save") { state.save() }.keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { state.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Load Sample Workbook") { state.loadSample() }
            }
            CommandMenu("Data") {
                Button("Sort Ascending") { sortSelected(ascending: true) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Sort Descending") { sortSelected(ascending: false) }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("Clear Sorting") { if let s = state.selectedSheet ?? state.gridSheet { state.clearSort(sheetID: s.id) } }
                Divider()
                Button("Insert Pivot from Selection") { state.insertView("pivot") }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Insert Chart from Selection") { state.insertView("chart") }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Filter Column by Values…") { filterSelected() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Append Row") { state.appendRow() }.keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Append Column") { state.appendColumn() }
            }
            CommandMenu("Go") {
                ForEach(Array(state.workbook.canvases.enumerated()), id: \.element.id) { i, c in
                    if i < 9 {
                        Button("\(i + 1) · \(c.name)") { state.pickCanvas(i) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    } else {
                        Button("\(i + 1) · \(c.name)") { state.pickCanvas(i) }
                    }
                }
                Divider()
                Button("New Canvas") { state.newCanvas() }.keyboardShortcut("t", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Commands…") { state.togglePalette() }.keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Fit Everything") { state.fit() }.keyboardShortcut("0", modifiers: .command)
                Button("Zoom In") { state.zoom(to: state.canvas.zoom * 1.2) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { state.zoom(to: state.canvas.zoom / 1.2) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { state.zoom(to: 1) }
                Divider()
                Button("Reload Theme") { state.theme = Theme.load(); state.show("theme: \(state.theme.name)") }
            }
        }
    }

    private func sortSelected(ascending: Bool) {
        guard let s = state.selection, let sheet = state.sheet(for: s.cardID) else { return }
        state.sort(sheetID: sheet.id, column: s.anchor.col, ascending: ascending)
    }

    private func filterSelected() {
        guard let s = state.selection else { return }
        state.openColumnMenu(cardID: s.cardID, column: s.anchor.col, anchor: CGPoint(x: 240, y: 60))
    }
}
