import Foundation

/// One entry in the ⌘K palette.
struct Command: Identifiable {
    let id = UUID()
    var group: String      // data · view · sheet · canvas · file
    var label: String
    var shortcut: String
    var run: () -> Void
}

extension AppState {
    /// Context-aware command list, filtered by the palette query (every whitespace-separated
    /// token must appear in the label).
    func commands(matching query: String) -> [Command] {
        var list: [Command] = []
        func add(_ group: String, _ label: String, _ shortcut: String = "", _ run: @escaping () -> Void) {
            list.append(Command(group: group, label: label, shortcut: shortcut, run: run))
        }
        let sheet = selectedSheet ?? gridSheet
        let selCol = selection?.minCol
        let colName = sheet.flatMap { s in selCol.flatMap { $0 < s.columns.count ? s.columns[$0].name : nil } }

        if let s = sheet, let c = selCol, let name = colName {
            add("data", "sort \(name) ascending", "⌘↑") { self.sort(sheetID: s.id, column: c, ascending: true) }
            add("data", "sort \(name) descending", "⌘↓") { self.sort(sheetID: s.id, column: c, ascending: false) }
            add("data", "add \(name) as next sort key") { self.sort(sheetID: s.id, column: c, ascending: true, additive: true) }
            if s.columns[c].type == .text {
                add("data", "filter \(name) by values…", "⌘⇧L") {
                    if let card = self.selection?.cardID { self.openColumnMenu(cardID: card, column: c, anchor: self.columnMenu?.anchor ?? CGPoint(x: 200, y: 60)) }
                }
            }
            add("sheet", "pin columns through \(Sheet.columnLetter(c))", "⌥P") { self.togglePin(sheetID: s.id, throughColumn: c) }
            for t in ColumnType.allCases { add("sheet", "set \(name) type: \(t.rawValue)") { self.setType(sheetID: s.id, column: c, type: t) } }
            for a in CellAlignment.allCases { add("sheet", "align \(name) \(a.rawValue)") { self.setAlignment(sheetID: s.id, column: c, alignment: a) } }
            add("sheet", "fit \(name) width to content", "⌥W") { self.fitColumnWidth(sheetID: s.id, column: c) }
            add("sheet", "color \(name) by value") { self.toggleColorByValue(sheetID: s.id, column: c) }
        }
        if let s = sheet {
            add("data", "clear sorting") { self.clearSort(sheetID: s.id) }
            add("data", "clear filter") { self.clearFilter(sheetID: s.id) }
            add("sheet", "unpin all") { self.setPins(sheetID: s.id, rows: 0, columns: 0) }
            add("sheet", "pin header row") { self.setPins(sheetID: s.id, rows: 1, columns: nil) }
            add("sheet", "append row", "⌘⇧↩") { self.appendRow() }
            add("sheet", "append column") { self.appendColumn() }
        }
        if canCopy {
            add("sheet", "copy selection", "⌘C") { self.copySelection() }
            add("sheet", "cut selection", "⌘X") { self.cutSelection() }
            add("sheet", "paste", "⌘V") { self.paste() }
        }
        add("view", "insert pivot from selection", "⌘⇧P") { self.insertView("pivot") }
        add("view", "insert chart from selection", "⌘⇧C") { self.insertView("chart") }
        if let id = selectedCardID {
            add("view", "duplicate selected view") { self.duplicateCard(id) }
            add("view", "remove selected view") { self.removeCard(id) }
        }
        for (i, c) in workbook.canvases.enumerated() {
            add("canvas", "go to canvas \(i + 1) · \(c.name)", i < 9 ? "⌘\(i + 1)" : "") { self.pickCanvas(i) }
        }
        add("canvas", "new canvas") { self.newCanvas() }
        add("canvas", "fit everything in view", "⌘0") { self.fit() }
        add("canvas", "zoom to 100%") { self.zoom(to: 1) }
        add("file", "save", "⌘S") { self.save() }
        add("file", "save as…", "⌘⇧S") { self.saveAs() }
        add("file", "open…", "⌘O") { self.open() }
        add("file", "new workbook", "⌘N") { self.newWorkbook() }
        add("file", "load sample workbook") { self.loadSample() }
        add("canvas", "reload theme from ~/.config/grid/theme.json") { self.theme = Theme.load(); self.show("theme: \(self.theme.name)") }

        let tokens = query.lowercased().split(separator: " ").map(String.init)
        let filtered = tokens.isEmpty ? list : list.filter { cmd in tokens.allSatisfy { cmd.label.lowercased().contains($0) } }
        return Array(filtered.prefix(9))
    }

    func runPaletteCommand(at index: Int) {
        let cmds = commands(matching: paletteQuery)
        guard cmds.indices.contains(index) else { return }
        paletteOpen = false
        paletteQuery = ""
        paletteIndex = 0
        cmds[index].run()
        focusCanvasRequest.send()
    }

    func togglePalette() {
        paletteOpen.toggle()
        paletteQuery = ""
        paletteIndex = 0
        columnMenu = nil
        if !paletteOpen { focusCanvasRequest.send() }
    }
}
