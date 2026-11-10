import SwiftUI

/// The column header menu: sort (multi-key), pin, filter values (in a flyout), type, alignment,
/// decimals, fit width, color by value, insert, delete. This is the entire formatting surface of the app.
struct ColumnMenuView: View {
    @EnvironmentObject var state: AppState
    let menu: ColumnMenuState
    /// Tallest the menu may be; past that its items scroll under the header.
    var maxHeight: CGFloat = .infinity
    static let width: CGFloat = 250

    var body: some View {
        let theme = state.theme
        if let sheet = state.workbook.sheet(menu.sheetID), menu.column < sheet.columns.count {
            let col = sheet.columns[menu.column]
            let c = menu.column
            let sortIndex = sheet.sorts.firstIndex { $0.column == c }
            FloatingCard(width: ColumnMenuView.width) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(Sheet.columnLetter(c)) · \(col.name)").font(Theme.uiFont(12, weight: .bold)).foregroundStyle(theme.bright.swiftUI)
                        Text(col.type.rawValue + (col.formulaTemplate != nil ? " · formula" : "")).font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI)
                        Spacer()
                        Button { state.closeMenus() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22) }
                            .buttonStyle(.plain).foregroundStyle(theme.subtext.swiftUI)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)

                    FitOrScroll(maxHeight: maxHeight - menuHeaderHeight) { VStack(alignment: .leading, spacing: 0) {
                    Group {
                        SectionLabel("Sort").padding(.horizontal, 10)
                        menuItem("ascending", glyph: "↑", on: sortIndex != nil && sheet.sorts[sortIndex!].ascending, shortcut: "⌘↑") { state.sort(sheetID: sheet.id, column: c, ascending: true) }
                        menuItem("descending", glyph: "↓", on: sortIndex != nil && !sheet.sorts[sortIndex!].ascending, shortcut: "⌘↓") { state.sort(sheetID: sheet.id, column: c, ascending: false) }
                        menuItem("add as next sort key", glyph: "+", on: false, shortcut: sortIndex.map { "key \($0 + 1)" } ?? "") { state.sort(sheetID: sheet.id, column: c, ascending: true, additive: true) }
                        menuItem("clear sorting", glyph: "", on: false, shortcut: "", dim: true) { state.clearSort(sheetID: sheet.id) }

                        SectionLabel("Pin").padding(.horizontal, 10)
                        menuItem(sheet.pinnedColumns == c + 1 ? "unpin columns" : "pin columns A:\(Sheet.columnLetter(c))", glyph: "⌖", on: sheet.pinnedColumns == c + 1, shortcut: "⌥P") { state.togglePin(sheetID: sheet.id, throughColumn: c) }
                    }

                    if col.type == .text {
                        let values = state.workbook.distinctValues(sheet: sheet, column: c)
                        if values.count > 1 {
                            let shown = sheet.filter?.column == c ? sheet.filter!.values.count : values.count
                            SectionLabel("Filter").padding(.horizontal, 10)
                            MenuItemRow(label: "filter values", glyph: "⏷", on: menu.showFilter || sheet.filter?.column == c,
                                        shortcut: (shown < values.count ? "\(shown) of \(values.count)  " : "") + "›") {
                                state.columnMenu?.showFilter.toggle()
                            }
                        }
                    }

                    SectionLabel("Type").padding(.horizontal, 10)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                        ForEach(ColumnType.allCases, id: \.self) { t in
                            Button(t.label) { state.setType(sheetID: sheet.id, column: c, type: t) }
                                .buttonStyle(ToolButtonStyle(theme: theme, on: col.type == t))
                        }
                    }
                    .padding(.horizontal, 10)

                    SectionLabel("Align · decimals").padding(.horizontal, 10)
                    HStack(spacing: 5) {
                        HStack(spacing: 0) {
                            ForEach(CellAlignment.allCases, id: \.self) { a in
                                Button(a == .left ? "⇤" : a == .center ? "↔" : "⇥") { state.setAlignment(sheetID: sheet.id, column: c, alignment: a) }
                                    .buttonStyle(ToolButtonStyle(theme: theme, on: col.effectiveAlignment == a))
                            }
                        }
                        HStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { d in
                                Button("\(d)") { state.setDecimals(sheetID: sheet.id, column: c, decimals: d) }
                                    .buttonStyle(ToolButtonStyle(theme: theme, on: col.decimals == d))
                            }
                        }
                    }
                    .padding(.horizontal, 10)

                    Group {
                        menuItem("fit width to content", glyph: "⟷", on: false, shortcut: "⌥W") { state.fitColumnWidth(sheetID: sheet.id, column: c) }
                        menuItem("color by value", glyph: "●", on: col.colorByValue, shortcut: "") { state.toggleColorByValue(sheetID: sheet.id, column: c) }
                        // Both inserts share one row so the menu stays short.
                        HStack(spacing: 5) {
                            Button("← insert left") { state.insertColumn(right: false) }.buttonStyle(ToolButtonStyle(theme: theme))
                            Button("insert right →") { state.insertColumn(right: true) }.buttonStyle(ToolButtonStyle(theme: theme))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        if sheet.columns.count > deleteCount {
                            MenuItemRow(label: deleteCount > 1 ? "delete \(deleteCount) columns" : "delete column", glyph: "×", shortcut: "⌘⌫", danger: true) { state.deleteSelectedColumns() }
                        }
                    }
                    .padding(.top, 8)

                    Text("that's the whole formatting surface — no fonts, sizes or borders")
                        .font(Theme.uiFont(10)).foregroundStyle(theme.subtext.swiftUI)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    } }
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func menuItem(_ label: String, glyph: String, on: Bool, shortcut: String, dim: Bool = false, action: @escaping () -> Void) -> some View {
        MenuItemRow(label: label, glyph: glyph, on: on, shortcut: shortcut, dim: dim, action: action)
    }

    /// How many columns "delete" would take: the whole-column selection when this column is in it.
    private var deleteCount: Int {
        guard let s = state.selection, s.span == .columns, s.cardID == menu.cardID, (s.minCol...s.maxCol).contains(menu.column) else { return 1 }
        return s.maxCol - s.minCol + 1
    }
}

/// The filter values checklist, as a flyout beside the column menu so the menu itself stays short.
struct FilterValuesView: View {
    @EnvironmentObject var state: AppState
    let menu: ColumnMenuState
    /// Tallest the flyout may be; the value list gives up height first.
    var maxHeight: CGFloat = .infinity
    static let width: CGFloat = 220
    /// Height of everything around the value list: title, divider and the "show all" button.
    private static let chrome: CGFloat = 86

    var body: some View {
        let theme = state.theme
        if let sheet = state.workbook.sheet(menu.sheetID), menu.column < sheet.columns.count {
            let c = menu.column
            let values = state.workbook.distinctValues(sheet: sheet, column: c)
            let active = sheet.filter?.column == c ? sheet.filter!.values : values.map { $0.value }
            FloatingCard(width: FilterValuesView.width) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("filter \(sheet.columns[c].name)").font(Theme.uiFont(12, weight: .bold)).foregroundStyle(theme.bright.swiftUI)
                        Text("\(active.count) of \(values.count)").font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(values, id: \.value) { v in
                                Button { state.toggleFilterValue(sheetID: sheet.id, column: c, value: v.value) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: active.contains(v.value) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(active.contains(v.value) ? theme.accent.swiftUI : theme.subtext.swiftUI)
                                        Text(v.value.isEmpty ? "(empty)" : v.value).foregroundStyle((theme.color(forValue: v.value) ?? theme.text).swiftUI)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(v.count)").foregroundStyle(theme.subtext.swiftUI)
                                    }
                                    .font(Theme.uiFont(12))
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: max(52, min(CGFloat(values.count) * 26 + 8, 268, maxHeight - FilterValuesView.chrome)))
                    Button("show all") { state.clearFilter(sheetID: sheet.id) }
                        .buttonStyle(ToolButtonStyle(theme: theme))
                        .disabled(sheet.filter?.column != c)
                        .opacity(sheet.filter?.column == c ? 1 : 0.45)
                        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
                }
            }
        }
    }
}

/// Shows its content at its natural height while that is within `maxHeight`, and scrolls it
/// vertically at `maxHeight` once it is not. Used for the item lists of the floating menus.
struct FitOrScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder let content: Content
    /// The content's own height, measured inside the scroll view.
    @State private var natural: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) { content.readHeight { natural = $0 } }
            .frame(height: natural > 0 ? min(natural, max(60, maxHeight)) : nil)
            .scrollDisabled(natural <= maxHeight)
    }
}

/// Height of a floating menu's fixed title row and bottom padding, which do not scroll.
let menuHeaderHeight: CGFloat = 48

/// One row of a floating menu: glyph, label, right-aligned hint. `danger` is for deletes.
struct MenuItemRow: View {
    @EnvironmentObject var state: AppState
    var label: String
    var glyph: String
    var on = false
    var shortcut = ""
    var dim = false
    var danger = false
    var action: () -> Void

    var body: some View {
        let theme = state.theme
        Button(action: action) {
            HStack(spacing: 10) {
                Text(glyph).frame(width: 14).foregroundStyle(danger ? theme.red.swiftUI : theme.accent.swiftUI)
                Text(label).foregroundStyle(danger ? theme.red.swiftUI : dim ? theme.subtext.swiftUI : theme.text.swiftUI)
                Spacer()
                if !shortcut.isEmpty { Text(shortcut).font(Theme.uiFont(10)).foregroundStyle(theme.subtext.swiftUI) }
            }
            .font(Theme.uiFont(12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.accent.swiftUI.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// The row-number menu: what can be done to whole rows.
struct RowMenuView: View {
    @EnvironmentObject var state: AppState
    let menu: RowMenuState
    /// Tallest the menu may be; past that its items scroll under the header.
    var maxHeight: CGFloat = .infinity
    static let width: CGFloat = 220

    var body: some View {
        let theme = state.theme
        // Spreadsheet numbering: row 1 is the column names, so display row 0 is row 2.
        let range: ClosedRange<Int> = {
            if let s = state.selection, s.span == .rows, s.cardID == menu.cardID { return s.minRow...s.maxRow }
            return menu.row...menu.row
        }()
        let many = range.count > 1
        FloatingCard(width: RowMenuView.width) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(many ? "rows \(range.lowerBound + 2)–\(range.upperBound + 2)" : "row \(range.lowerBound + 2)")
                        .font(Theme.uiFont(12, weight: .bold)).foregroundStyle(theme.bright.swiftUI)
                    if many { Text("\(range.count) rows").font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI) }
                    Spacer()
                    Button { state.rowMenu = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22) }
                        .buttonStyle(.plain).foregroundStyle(theme.subtext.swiftUI)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)
                FitOrScroll(maxHeight: maxHeight - menuHeaderHeight) { VStack(alignment: .leading, spacing: 0) {
                Group {
                    MenuItemRow(label: "insert row above", glyph: "↑") { state.insertRow(below: false) }
                    MenuItemRow(label: "insert row below", glyph: "↓") { state.insertRow(below: true) }
                    MenuItemRow(label: "clear contents", glyph: "⌫", shortcut: "⌫") { state.rowMenu = nil; state.clearSelection() }
                    MenuItemRow(label: many ? "delete \(range.count) rows" : "delete row", glyph: "×", shortcut: "⌘⌫", danger: true) { state.deleteSelectedRows() }
                }
                .padding(.top, 4)
                Text("shift-click or drag row numbers to select more")
                    .font(Theme.uiFont(10)).foregroundStyle(theme.subtext.swiftUI)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                } }
            }
        }
    }
}
