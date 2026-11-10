import SwiftUI

/// The column header menu: sort (multi-key), pin, filter values, type, alignment, decimals,
/// fit width, color by value. This is the entire formatting surface of the app.
struct ColumnMenuView: View {
    @EnvironmentObject var state: AppState
    let menu: ColumnMenuState

    var body: some View {
        let theme = state.theme
        if let sheet = state.workbook.sheet(menu.sheetID), menu.column < sheet.columns.count {
            let col = sheet.columns[menu.column]
            let c = menu.column
            let sortIndex = sheet.sorts.firstIndex { $0.column == c }
            FloatingCard(width: 250) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(Sheet.columnLetter(c)) · \(col.name)").font(Theme.uiFont(12, weight: .bold)).foregroundStyle(theme.bright.swiftUI)
                        Text(col.type.rawValue + (col.formulaTemplate != nil ? " · formula" : "")).font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI)
                        Spacer()
                        Button { state.columnMenu = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22) }
                            .buttonStyle(.plain).foregroundStyle(theme.subtext.swiftUI)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)

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
                        if values.count > 1 && values.count <= 12 {
                            SectionLabel("Filter values").padding(.horizontal, 10)
                            let active = sheet.filter?.column == c ? sheet.filter!.values : values.map { $0.value }
                            ForEach(values, id: \.value) { v in
                                Button { state.toggleFilterValue(sheetID: sheet.id, column: c, value: v.value) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: active.contains(v.value) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(active.contains(v.value) ? theme.accent.swiftUI : theme.subtext.swiftUI)
                                        Text(v.value.isEmpty ? "(empty)" : v.value).foregroundStyle((theme.color(forValue: v.value) ?? theme.text).swiftUI)
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
                    }
                    .padding(.top, 8)

                    Text("that's the whole formatting surface — no fonts, sizes or borders")
                        .font(Theme.uiFont(10)).foregroundStyle(theme.subtext.swiftUI)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .padding(.bottom, 2)
            }
        }
    }

    private func menuItem(_ label: String, glyph: String, on: Bool, shortcut: String, dim: Bool = false, action: @escaping () -> Void) -> some View {
        let theme = state.theme
        return Button(action: action) {
            HStack(spacing: 10) {
                Text(glyph).frame(width: 14).foregroundStyle(theme.accent.swiftUI)
                Text(label).foregroundStyle(dim ? theme.subtext.swiftUI : theme.text.swiftUI)
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
