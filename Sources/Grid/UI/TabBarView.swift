import SwiftUI

/// Canvas tabs: `1 · Orders`, `2 · Inventory`… plus "+" and the ⌘K button.
/// Leaves room on the left for the macOS traffic lights.
struct TabBarView: View {
    @EnvironmentObject var state: AppState
    @State private var renaming: Int? = nil
    @State private var renameText = ""
    /// Matches the unified-compact title bar so the tabs sit on the traffic-light row.
    static let height: CGFloat = 38

    var body: some View {
        let theme = state.theme
        HStack(spacing: 8) {
            Spacer().frame(width: 64)
            ForEach(Array(state.workbook.canvases.enumerated()), id: \.element.id) { i, canvas in
                if renaming == i {
                    TextField("name", text: $renameText, onCommit: { state.renameCanvas(i, to: renameText); renaming = nil })
                        .textFieldStyle(.plain)
                        .font(Theme.uiFont(11, weight: .semibold))
                        .frame(width: 120, height: 26)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(theme.surface0.swiftUI))
                        .overlay(Capsule().stroke(theme.accent.swiftUI, lineWidth: 1))
                        .onExitCommand { renaming = nil }
                } else {
                    Button { state.pickCanvas(i) } label: {
                        Text("\(i + 1) · \(canvas.name)")
                            .font(Theme.uiFont(11, weight: i == state.canvasIndex ? .bold : .semibold))
                            .foregroundStyle(i == state.canvasIndex ? theme.crust.swiftUI : theme.text.swiftUI)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(i == state.canvasIndex ? theme.accent.swiftUI : theme.surface0.swiftUI.opacity(0.5)))
                            .overlay(Capsule().stroke(i == state.canvasIndex ? Color.clear : theme.lavender.swiftUI.opacity(0.22), lineWidth: 1))
                            .shadow(color: i == state.canvasIndex ? theme.accent.swiftUI.opacity(0.45) : .clear, radius: 8)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { renameText = canvas.name; renaming = i }
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { renameText = canvas.name; renaming = i })
                }
            }
            Button { state.newCanvas() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.subtext.swiftUI)
                    .frame(width: 26, height: 26)
                    .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(theme.lavender.swiftUI.opacity(0.35)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("New canvas (⌘T)")

            Text(state.title)
                .font(Theme.uiFont(11))
                .foregroundStyle(theme.subtext.swiftUI)
                .padding(.leading, 6)
            Text(state.dirty ? "edited" : "saved")
                .font(Theme.uiFont(11))
                .foregroundStyle(theme.text.swiftUI)

            Spacer()

            Text(headline)
                .font(Theme.uiFont(10.5))
                .foregroundStyle(theme.subtext.swiftUI)
            Button { state.togglePalette() } label: {
                HStack(spacing: 8) {
                    Text("run").font(Theme.uiFont(11, weight: .semibold)).foregroundStyle(theme.accent.swiftUI)
                    KeyCap("⌘K")
                }
                .padding(.leading, 10).padding(.trailing, 3)
                .frame(height: 24)
                .background(Capsule().fill(theme.accent.swiftUI.opacity(0.1)))
                .overlay(Capsule().stroke(theme.accent.swiftUI.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: TabBarView.height)
        .animation(.easeOut(duration: 0.2), value: state.canvasIndex)
    }

    private var headline: String {
        if state.selectedCardID != nil { return "editing a view — panel floats over the canvas" }
        if state.selection != nil { return "selection → pivot ⌘⇧P · chart ⌘⇧C · filter ⌘⇧L" }
        return "canvas \(state.canvasIndex + 1) · \(state.canvas.cards.count - 1) views"
    }
}

/// Bottom status bar: sheet facts on the left, formula readout and selection stats on the right.
struct StatusBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let theme = state.theme
        HStack(spacing: 16) {
            if let sheet = state.gridSheet {
                dot(theme.accent, "\(sheet.name) · \(state.workbook.visibleRows(of: sheet).count) rows")
                dot(theme.blue, pinText(sheet))
                dot(theme.yellow, sortText(sheet))
            }
            dot(theme.teal, "\(state.canvas.cards.filter { !$0.kind.isGrid }.count) views")
            Spacer()
            Text(formulaText).foregroundStyle(theme.text.swiftUI)
            Text("│").foregroundStyle(theme.surface1.swiftUI)
            Text(stats)
            Text("│").foregroundStyle(theme.surface1.swiftUI)
            HStack(spacing: 4) { KeyCap("⌘"); KeyCap("K"); Text("run") }
        }
        .font(Theme.uiFont(11))
        .foregroundStyle(theme.subtext.swiftUI)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private func dot(_ color: NSColor, _ text: String) -> some View {
        HStack(spacing: 6) { Circle().fill(color.swiftUI).frame(width: 6, height: 6); Text(text) }
    }

    private func pinText(_ s: Sheet) -> String {
        var t: [String] = []
        if s.pinnedRows > 0 { t.append("row 1") }
        if s.pinnedColumns > 0 { t.append("cols A:" + Sheet.columnLetter(s.pinnedColumns - 1)) }
        return t.isEmpty ? "nothing pinned" : "pinned " + t.joined(separator: " · ")
    }

    private func sortText(_ s: Sheet) -> String {
        s.sorts.isEmpty ? "no sort" : "sort " + s.sorts.map { s.columns[$0.column].name + ($0.ascending ? " ↑" : " ↓") }.joined(separator: ", ")
    }

    private var formulaText: String {
        guard let sel = state.selection, let sheet = state.sheet(for: sel.cardID) else { return "" }
        let rows = state.workbook.visibleRows(of: sheet)
        guard rows.indices.contains(sel.anchor.row), sel.anchor.col < sheet.columns.count else { return "" }
        let ref = Sheet.columnLetter(sel.anchor.col) + String(sel.anchor.row + 2)
        let raw = sheet.rows[rows[sel.anchor.row].sourceIndex][sel.anchor.col]
        let shown = CellFormatter.display(rows[sel.anchor.row].values[sel.anchor.col], column: sheet.columns[sel.anchor.col])
        if case .formula(let f) = raw { return "\(ref) \(f) → \(shown)" }
        return "\(ref) → \(shown.isEmpty ? "(empty)" : shown)"
    }

    private var stats: String {
        guard let sel = state.selection, let sheet = state.sheet(for: sel.cardID) else { return "select cells for sum · avg · count" }
        let rows = state.workbook.visibleRows(of: sheet)
        var nums: [Double] = [], count = 0
        for r in sel.minRow...sel.maxRow where rows.indices.contains(r) {
            for c in sel.minCol...sel.maxCol where c < sheet.columns.count {
                let v = rows[r].values[c]
                if !v.isEmpty { count += 1 }
                if sheet.columns[c].type.isNumeric, let n = CellFormatter.number(v) { nums.append(n) }
            }
        }
        guard !nums.isEmpty else { return "cnt \(count)" }
        var col = sheet.columns[sel.anchor.col]
        if col.type == .percent { col.decimals = max(col.decimals, 1) }
        let sum = nums.reduce(0, +)
        let sumCol: Column = { var c = col; if c.type == .percent { c.type = .number; c.decimals = 2 }; return c }()
        return "sum \(CellFormatter.display(.number(sum), column: sumCol)) · avg \(CellFormatter.display(.number(sum / Double(nums.count)), column: col)) · cnt \(count)"
    }
}
