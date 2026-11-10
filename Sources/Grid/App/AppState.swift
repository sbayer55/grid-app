import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Anchor for the column menu, in canvas-viewport points.
struct ColumnMenuState: Equatable {
    var cardID: UUID
    var sheetID: UUID
    var column: Int
    var anchor: CGPoint
    /// Whether the filter values flyout is out.
    var showFilter = false
}

/// The row-number menu. `row` is a display row; `anchor` is in canvas-viewport points.
struct RowMenuState: Equatable {
    var cardID: UUID
    var sheetID: UUID
    var row: Int
    var anchor: CGPoint
}

struct Toast: Equatable { var text: String; var id = UUID() }

/// All UI state and every mutation of the workbook. Views observe it; the canvas
/// NSView redraws when it changes. Mutations go through `mutate` so undo is free.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var workbook: Workbook
    @Published var theme = Theme.load()
    @Published var canvasIndex = 0
    @Published var selection: Selection?
    @Published var columnMenu: ColumnMenuState?
    @Published var rowMenu: RowMenuState?
    @Published var selectedCardID: UUID?
    /// The pivot or chart currently filling the canvas area, if any. Not saved, not undoable.
    @Published var fullscreenCardID: UUID?
    @Published var paletteOpen = false
    @Published var paletteQuery = ""
    @Published var paletteIndex = 0
    @Published var toast: Toast?
    @Published var fileURL: URL?
    @Published var dirty = false
    @Published var viewportSize = CGSize(width: 1200, height: 700)

    let undoManager = UndoManager()
    /// Fired when the canvas should begin editing the focused cell (from menu commands).
    let beginEditRequest = PassthroughSubject<String?, Never>()
    /// Fired to move keyboard focus back to the canvas (after closing the palette).
    let focusCanvasRequest = PassthroughSubject<Void, Never>()
    /// Fired after a programmatic pan/zoom change (fit, zoom buttons) so the canvas animates to it.
    let animateViewportRequest = PassthroughSubject<Void, Never>()

    init() {
        let url = AppState.lastFileURL
        if let url = url, let wb = try? XLSXReader.read(from: url) {
            workbook = wb; fileURL = url
        } else {
            workbook = SampleData.workbook()
        }
    }

    // MARK: Derived

    var canvas: Canvas {
        get { workbook.canvases.indices.contains(canvasIndex) ? workbook.canvases[canvasIndex] : Canvas(name: "Empty") }
    }
    var gridCard: Card? { canvas.gridCard }
    var gridSheet: Sheet? {
        guard let card = gridCard, case .grid(let id) = card.kind else { return nil }
        return workbook.sheet(id)
    }
    func sheet(for cardID: UUID) -> Sheet? {
        guard let card = canvas.cards.first(where: { $0.id == cardID }) else { return nil }
        switch card.kind {
        case .grid(let id): return workbook.sheet(id)
        case .pivot(let cfg): return workbook.sheet(cfg.sheetID)
        case .chart(let cfg): return workbook.sheet(cfg.sheetID)
        }
    }
    var selectedSheet: Sheet? { selection.flatMap { sheet(for: $0.cardID) } }
    var selectedCard: Card? { selectedCardID.flatMap { id in canvas.cards.first { $0.id == id } } }

    /// The view filling the canvas; nil once its card is gone or another canvas is showing.
    var fullscreenCard: Card? { fullscreenCardID.flatMap { id in canvas.cards.first { $0.id == id && !$0.kind.isGrid } } }

    var title: String { (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".xlsx" }

    // MARK: Mutation + undo

    func mutate(_ name: String, _ body: (inout Workbook) -> Void) {
        let before = workbook
        body(&workbook)
        guard workbook != before else { return }
        dirty = true
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(before, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Runs inside `undo()` / `redo()` (always on the main thread), so the inverse registered
    /// here lands on the opposite stack. Hopping through a Task would make it a fresh undo.
    private func restore(_ wb: Workbook, name: String) {
        let current = workbook
        workbook = wb
        dirty = true
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(current, name: name) }
        }
        undoManager.setActionName(name)
        clampSelection()
    }

    /// Mutates the current canvas without touching undo (pan/zoom, card drags).
    func updateCanvas(_ body: (inout Canvas) -> Void) {
        guard workbook.canvases.indices.contains(canvasIndex) else { return }
        body(&workbook.canvases[canvasIndex])
    }

    func updateSheet(_ id: UUID, _ name: String, _ body: (inout Sheet) -> Void) {
        mutate(name) { wb in
            guard let i = wb.sheetIndex(id) else { return }
            body(&wb.sheets[i])
        }
        clampSelection()
    }

    func updateCard(_ id: UUID, _ name: String, _ body: (inout Card) -> Void) {
        mutate(name) { wb in
            guard let ci = wb.canvases.indices.first(where: { wb.canvases[$0].cards.contains { $0.id == id } }),
                  let i = wb.canvases[ci].cards.firstIndex(where: { $0.id == id }) else { return }
            body(&wb.canvases[ci].cards[i])
        }
    }

    func show(_ text: String) {
        let t = Toast(text: text)
        toast = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.toast == t { self?.toast = nil }
        }
    }

    // MARK: Selection

    func closeMenus() { columnMenu = nil; rowMenu = nil }

    func select(card: UUID, row: Int, col: Int, extend: Bool) {
        closeMenus()
        if extend, var s = selection, s.cardID == card { s.focus = CellRef(row: row, col: col); s.span = .cells; selection = s }
        else { selection = Selection(cardID: card, anchor: CellRef(row: row, col: col), focus: CellRef(row: row, col: col)) }
    }

    /// Selects a whole display row; `extend` grows an existing row selection to it.
    func selectRows(card: UUID, row: Int, extend: Bool) {
        guard let sheet = sheet(for: card) else { return }
        let lastCol = max(0, sheet.columns.count - 1)
        let from = extend && selection?.cardID == card && selection?.span == .rows ? selection!.anchor.row : row
        selection = Selection(cardID: card, anchor: CellRef(row: from, col: 0), focus: CellRef(row: row, col: lastCol), span: .rows)
        selectedCardID = nil
    }

    /// Selects a whole column; `extend` grows an existing column selection to it.
    func selectColumns(card: UUID, column: Int, extend: Bool) {
        guard let sheet = sheet(for: card) else { return }
        let lastRow = max(0, workbook.visibleRows(of: sheet).count - 1)
        let from = extend && selection?.cardID == card && selection?.span == .columns ? selection!.anchor.col : column
        selection = Selection(cardID: card, anchor: CellRef(row: 0, col: from), focus: CellRef(row: lastRow, col: column), span: .columns)
        selectedCardID = nil
    }

    func moveSelection(dRow: Int, dCol: Int, extend: Bool) {
        guard var s = selection, let sheet = sheet(for: s.cardID) else { return }
        let rows = workbook.visibleRows(of: sheet).count
        var target = extend ? s.focus : s.anchor
        // Whole rows only grow by rows and whole columns by columns; a plain move goes back to cells.
        let dRow = extend && s.span == .columns ? 0 : dRow, dCol = extend && s.span == .rows ? 0 : dCol
        target.row = max(0, min(rows - 1, target.row + dRow))
        target.col = max(0, min(sheet.columns.count - 1, target.col + dCol))
        if extend { s.focus = target } else { s.anchor = target; s.focus = target; s.span = .cells }
        selection = s
        closeMenus()
    }

    func clampSelection() {
        guard var s = selection, let sheet = sheet(for: s.cardID) else { selection = nil; return }
        let rows = max(0, workbook.visibleRows(of: sheet).count - 1), cols = max(0, sheet.columns.count - 1)
        s.anchor.row = min(s.anchor.row, rows); s.focus.row = min(s.focus.row, rows)
        s.anchor.col = min(s.anchor.col, cols); s.focus.col = min(s.focus.col, cols)
        // Whole rows and columns keep reaching edge to edge as the sheet grows or shrinks.
        if s.span == .rows { s.anchor.col = 0; s.focus.col = cols }
        if s.span == .columns { s.anchor.row = 0; s.focus.row = rows }
        selection = s
    }

    /// Sheet row index behind a display row of the selected card.
    func sourceRow(cardID: UUID, displayRow: Int) -> Int? {
        guard let sheet = sheet(for: cardID) else { return nil }
        let rows = workbook.visibleRows(of: sheet)
        return rows.indices.contains(displayRow) ? rows[displayRow].sourceIndex : nil
    }

    // MARK: Cell edits

    func setCell(cardID: UUID, displayRow: Int, col: Int, text: String) {
        guard let sheet = sheet(for: cardID), let r = sourceRow(cardID: cardID, displayRow: displayRow), col < sheet.columns.count else { return }
        let value = CellFormatter.parse(text, column: sheet.columns[col])
        updateSheet(sheet.id, "Edit Cell") { s in s.rows[r][col] = value }
    }

    func clearSelection(actionName: String = "Clear Cells") {
        guard let s = selection, let sheet = sheet(for: s.cardID) else { return }
        let rows = workbook.visibleRows(of: sheet)
        updateSheet(sheet.id, actionName) { sh in
            for r in s.minRow...s.maxRow where rows.indices.contains(r) {
                for c in s.minCol...s.maxCol where c < sh.columns.count { sh.rows[rows[r].sourceIndex][c] = .empty }
            }
        }
    }

    // MARK: Clipboard

    /// Grid's own pasteboard type: a JSON `CellClip` with raw values and formulas.
    static let cellsPasteboardType = NSPasteboard.PasteboardType("app.grid.cells")
    static let csvPasteboardType = NSPasteboard.PasteboardType("public.comma-separated-values-text")

    /// The selection, when it sits on a sheet card (view cards have nothing to copy).
    private var gridSelection: (selection: Selection, sheet: Sheet)? {
        guard fullscreenCard == nil,   // the grid is hidden behind a full screen view
              let s = selection, let card = canvas.cards.first(where: { $0.id == s.cardID }), card.kind.isGrid,
              let sheet = sheet(for: s.cardID) else { return nil }
        return (s, sheet)
    }
    var canCopy: Bool { gridSelection != nil }

    func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        gridSelection != nil && pasteboard.availableType(from: [AppState.cellsPasteboardType, AppState.csvPasteboardType, .string]) != nil
    }

    /// Writes the selection as Grid cells, CSV and tab-separated plain text.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard = .general, cut: Bool = false) -> Bool {
        guard let (s, sheet) = gridSelection,
              var clip = workbook.clip(sheetID: sheet.id, rows: s.minRow...s.maxRow, cols: s.minCol...s.maxCol) else { return false }
        clip.isCut = cut
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(clip) { pasteboard.setData(data, forType: AppState.cellsPasteboardType) }
        pasteboard.setString(Delimited.encode(clip.texts, delimiter: ","), forType: AppState.csvPasteboardType)
        pasteboard.setString(Delimited.encode(clip.texts, delimiter: "\t"), forType: .string)
        show("\(cut ? "cut" : "copied") \(clip.rowCount)×\(clip.colCount)")
        return true
    }

    func cutSelection(to pasteboard: NSPasteboard = .general) {
        guard copySelection(to: pasteboard, cut: true) else { return }
        clearSelection(actionName: "Cut")
    }

    /// What a paste would insert: Grid's own cells if present, else CSV, else sniffed plain text.
    static func pasteContent(from pasteboard: NSPasteboard) -> PasteContent? {
        if let data = pasteboard.data(forType: cellsPasteboardType), let clip = try? JSONDecoder().decode(CellClip.self, from: data) {
            return .clip(clip)
        }
        if let csv = pasteboard.string(forType: csvPasteboardType), !csv.isEmpty { return .text(Delimited.decode(csv, delimiter: ",")) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return .text(Delimited.sniff(text)) }
        return nil
    }

    func paste(from pasteboard: NSPasteboard = .general) {
        guard let (s, sheet) = gridSelection, let content = AppState.pasteContent(from: pasteboard) else { return }
        var pasted: CellRange?
        mutate("Paste") { wb in
            pasted = wb.paste(content, sheetID: sheet.id, displayRow: s.minRow, col: s.minCol,
                              fillRows: s.maxRow - s.minRow + 1, fillCols: s.maxCol - s.minCol + 1)
        }
        guard let r = pasted else { return }
        selection = Selection(cardID: s.cardID, anchor: CellRef(row: r.rows.lowerBound, col: r.cols.lowerBound),
                              focus: CellRef(row: r.rows.upperBound, col: r.cols.upperBound))
        clampSelection()
        show("pasted \(r.rows.count)×\(r.cols.count)")
    }

    func appendRow() {
        guard let sheet = gridSheet else { return }
        updateSheet(sheet.id, "Add Row") { $0.appendRow() }
    }

    func appendColumn() {
        guard let sheet = gridSheet else { return }
        updateSheet(sheet.id, "Add Column") { $0.appendColumn() }
    }

    // MARK: Columns: sort / pin / type / align / filter

    func sort(sheetID: UUID, column: Int, ascending: Bool, additive: Bool = false) {
        updateSheet(sheetID, "Sort") { s in
            if additive { s.sorts.removeAll { $0.column == column }; s.sorts.append(SortKey(column: column, ascending: ascending)) }
            else { s.sorts = [SortKey(column: column, ascending: ascending)] }
        }
    }
    func clearSort(sheetID: UUID) { updateSheet(sheetID, "Clear Sort") { $0.sorts = [] } }

    func togglePin(sheetID: UUID, throughColumn c: Int) {
        updateSheet(sheetID, "Pin Columns") { s in s.pinnedColumns = s.pinnedColumns == c + 1 ? 0 : c + 1 }
    }
    func setPins(sheetID: UUID, rows: Int?, columns: Int?) {
        updateSheet(sheetID, "Pin") { s in
            if let r = rows { s.pinnedRows = r }
            if let c = columns { s.pinnedColumns = c }
        }
    }

    func setType(sheetID: UUID, column: Int, type: ColumnType) {
        if type == .date || type == .check { show("\(type.rawValue) type: cells keep their values; display only") }
        updateSheet(sheetID, "Column Type") { $0.columns[column].type = type }
    }
    func setAlignment(sheetID: UUID, column: Int, alignment: CellAlignment) {
        updateSheet(sheetID, "Align") { $0.columns[column].alignment = alignment }
    }
    func setDecimals(sheetID: UUID, column: Int, decimals: Int) {
        updateSheet(sheetID, "Decimals") { $0.columns[column].decimals = decimals }
    }
    func fitColumnWidth(sheetID: UUID, column: Int) {
        guard let sheet = workbook.sheet(sheetID) else { return }
        let col = sheet.columns[column]
        let rows = workbook.evaluatedRows(of: sheet)
        let longest = max(col.name.count, rows.map { CellFormatter.display($0[column], column: col).count }.max() ?? 0)
        updateSheet(sheetID, "Fit Width") { $0.columns[column].width = max(50, min(360, CGFloat(longest) * 7.3 + 18)) }
    }
    func toggleColorByValue(sheetID: UUID, column: Int) {
        updateSheet(sheetID, "Color by Value") { $0.columns[column].colorByValue.toggle() }
    }

    func toggleFilterValue(sheetID: UUID, column: Int, value: String) {
        guard let sheet = workbook.sheet(sheetID) else { return }
        let all = workbook.distinctValues(sheet: sheet, column: column).map { $0.value }
        updateSheet(sheetID, "Filter") { s in
            var current = (s.filter?.column == column ? s.filter?.values : nil) ?? all
            if current.contains(value) { current.removeAll { $0 == value } } else { current.append(value) }
            s.filter = current.count == all.count ? nil : ValueFilter(column: column, values: current)
        }
    }
    func clearFilter(sheetID: UUID) { updateSheet(sheetID, "Clear Filter") { $0.filter = nil } }

    /// Selects the column (or extends a column selection to it) and opens its menu;
    /// `showFilter` opens it with the filter values flyout already out.
    func openColumnMenu(cardID: UUID, column: Int, anchor: CGPoint, extend: Bool = false, showFilter: Bool = false) {
        guard let sheet = sheet(for: cardID) else { return }
        if columnMenu?.column == column, columnMenu?.cardID == cardID, !extend, !showFilter { closeMenus(); return }
        selectColumns(card: cardID, column: column, extend: extend)
        rowMenu = nil
        columnMenu = ColumnMenuState(cardID: cardID, sheetID: sheet.id, column: column, anchor: anchor, showFilter: showFilter)
    }

    /// Selects the row (or extends a row selection to it) and opens the row menu beside it.
    func openRowMenu(cardID: UUID, row: Int, anchor: CGPoint, extend: Bool = false) {
        guard let sheet = sheet(for: cardID) else { return }
        if rowMenu?.row == row, rowMenu?.cardID == cardID, !extend { rowMenu = nil; return }
        selectRows(card: cardID, row: row, extend: extend)
        closeMenus()
        rowMenu = RowMenuState(cardID: cardID, sheetID: sheet.id, row: row, anchor: anchor)
    }

    // MARK: Inserting and deleting rows and columns

    /// The selection when it is whole rows or whole columns of the sheet card.
    private func structuralSelection(_ span: SelectionSpan) -> (selection: Selection, sheet: Sheet)? {
        guard let (s, sheet) = gridSelection, s.span == span else { return nil }
        return (s, sheet)
    }
    var canDeleteRows: Bool { structuralSelection(.rows) != nil }
    var canDeleteColumns: Bool { structuralSelection(.columns).map { $0.selection.maxCol - $0.selection.minCol + 1 < $0.sheet.columns.count } ?? false }

    /// ⌘⌫: removes the selected whole rows or columns. False when the selection is plain cells.
    @discardableResult
    func deleteSelection() -> Bool {
        switch selection?.span {
        case .rows?: deleteSelectedRows(); return true
        case .columns?: deleteSelectedColumns(); return true
        default: return false
        }
    }

    var canInsertRows: Bool { structuralSelection(.rows) != nil }
    var canInsertColumns: Bool { structuralSelection(.columns) != nil }

    /// Adds an empty row above the first selected row or below the last one.
    func insertRow(below: Bool) {
        guard let (s, sheet) = structuralSelection(.rows) else { return }
        let visible = workbook.visibleRows(of: sheet)
        let edge = below ? s.maxRow : s.minRow
        guard visible.indices.contains(edge) else { return }
        let at = visible[edge].sourceIndex + (below ? 1 : 0)
        closeMenus()
        mutate("Insert Row") { wb in wb.insertRows(sheetID: sheet.id, at: at) }
        // Select the new row where it is shown. An empty row can be sorted elsewhere or filtered out.
        let shown = workbook.sheet(sheet.id).flatMap { workbook.visibleRows(of: $0).firstIndex { $0.sourceIndex == at } }
        if let r = shown {
            selection = Selection(cardID: s.cardID, anchor: CellRef(row: r, col: 0), focus: CellRef(row: r, col: 0), span: .rows)
        }
        clampSelection()
        if shown == nil { show("row inserted — hidden by the filter on this sheet") }
        else if shown != (below ? s.maxRow + 1 : s.minRow) { show("row inserted — the sort moved it to row \(shown! + 2)") }
        else { show("inserted row \(shown! + 2)") }
    }

    /// Adds an empty text column left of the first selected column or right of the last one.
    func insertColumn(right: Bool) {
        guard let (s, sheet) = structuralSelection(.columns) else { return }
        let at = right ? min(s.maxCol, sheet.columns.count - 1) + 1 : s.minCol
        closeMenus()
        var names: [String]?
        mutate("Insert Column") { wb in names = wb.insertColumns(sheetID: sheet.id, at: at) }
        guard let name = names?.first else { return }
        selection = Selection(cardID: s.cardID, anchor: CellRef(row: 0, col: at), focus: CellRef(row: 0, col: at), span: .columns)
        clampSelection()
        show("inserted \(name) at \(Sheet.columnLetter(at))")
    }

    func deleteSelectedRows() {
        guard let (s, sheet) = structuralSelection(.rows) else { return }
        let visible = workbook.visibleRows(of: sheet)
        let doomed = Set((s.minRow...s.maxRow).compactMap { visible.indices.contains($0) ? visible[$0].sourceIndex : nil })
        guard !doomed.isEmpty else { return }
        closeMenus()
        mutate(doomed.count == 1 ? "Delete Row" : "Delete Rows") { wb in wb.deleteRows(sheetID: sheet.id, sourceRows: doomed) }
        // Land on the row that slid into the gap.
        if workbook.sheet(sheet.id).map({ workbook.visibleRows(of: $0).isEmpty }) ?? true { selection = nil }
        else { selection = Selection(cardID: s.cardID, anchor: CellRef(row: s.minRow, col: 0), focus: CellRef(row: s.minRow, col: 0), span: .rows); clampSelection() }
        show("deleted \(doomed.count) row\(doomed.count == 1 ? "" : "s")")
    }

    func deleteSelectedColumns() {
        guard let (s, sheet) = structuralSelection(.columns) else { return }
        let doomed = Set(s.minCol...min(s.maxCol, sheet.columns.count - 1))
        guard doomed.count < sheet.columns.count else { show("a sheet keeps at least one column"); return }
        closeMenus()
        var result: Workbook.ColumnDeletion?
        mutate(doomed.count == 1 ? "Delete Column" : "Delete Columns") { wb in result = wb.deleteColumns(sheetID: sheet.id, columns: doomed) }
        guard let r = result else { return }
        if selectedCard == nil { selectedCardID = nil }
        if fullscreenCard == nil { fullscreenCardID = nil }
        selection = Selection(cardID: s.cardID, anchor: CellRef(row: 0, col: s.minCol), focus: CellRef(row: 0, col: s.minCol), span: .columns)
        clampSelection()
        let what = r.names.count == 1 ? r.names[0] : "\(r.names.count) columns"
        show("deleted \(what)" + (r.removedViews > 0 ? " · removed \(r.removedViews) view\(r.removedViews == 1 ? "" : "s") built on \(r.names.count == 1 ? "it" : "them")" : ""))
    }

    // MARK: Views

    func insertView(_ kind: String) {
        guard let gridCard = gridCard, let sheet = gridSheet else { return }
        let textCols = sheet.columns.filter { $0.type == .text && !$0.formulaTemplateIsSet }
        var rowField = textCols.first(where: { $0.name == "Region" })?.name ?? textCols.first?.name ?? sheet.columns.first?.name ?? "A"
        var valueField = sheet.columns.first(where: { $0.type == .currency })?.name ?? sheet.columns.first(where: { $0.type.isNumeric })?.name ?? rowField
        if let s = selection, s.cardID == gridCard.id, s.minCol < sheet.columns.count {
            let picked = sheet.columns[s.minCol...min(s.maxCol, sheet.columns.count - 1)]
            if let t = picked.first(where: { $0.type == .text }) { rowField = t.name }
            if let n = picked.first(where: { $0.type.isNumeric }) { valueField = n.name }
        }
        let cardKind: CardKind = kind == "pivot"
            ? .pivot(PivotConfig(sheetID: sheet.id, rowField: rowField, valueField: valueField))
            : .chart(ChartConfig(sheetID: sheet.id, type: .bar, xField: rowField, yField: valueField))
        let gridWidth = Layout.gridSize(sheet: sheet, workbook: workbook).width
        let y = canvas.cards.filter { !$0.kind.isGrid }.map { $0.origin.y + 260 }.max() ?? gridCard.origin.y
        let card = Card(kind: cardKind, origin: CGPoint(x: gridCard.origin.x + gridWidth + 48, y: y))
        mutate("Insert \(kind)") { wb in wb.canvases[self.canvasIndex].cards.append(card) }
        selectedCardID = card.id
        closeMenus()
        paletteOpen = false
        show("\(kind) inserted — formula-backed, live")
    }

    func removeCard(_ id: UUID) {
        mutate("Remove View") { wb in wb.canvases[self.canvasIndex].cards.removeAll { $0.id == id && !$0.kind.isGrid } }
        if selectedCardID == id { selectedCardID = nil }
        if fullscreenCardID == id { fullscreenCardID = nil }
    }

    /// Makes a view fill the canvas area (not the screen), or puts it back on the canvas.
    func toggleFullscreen(_ id: UUID) {
        if fullscreenCard?.id == id { fullscreenCardID = nil; return }
        guard let card = canvas.cards.first(where: { $0.id == id }), !card.kind.isGrid else { return }
        closeMenus()
        if selectedCardID != id { selectedCardID = nil }   // another view's panel would cover this one
        fullscreenCardID = id
    }

    func duplicateCard(_ id: UUID) {
        guard let card = canvas.cards.first(where: { $0.id == id }), !card.kind.isGrid else { return }
        var copy = card; copy.id = UUID(); copy.origin.x += 30; copy.origin.y += 30
        mutate("Duplicate View") { wb in wb.canvases[self.canvasIndex].cards.append(copy) }
        selectedCardID = copy.id
    }

    func updatePivot(_ id: UUID, _ body: (inout PivotConfig) -> Void) {
        updateCard(id, "Edit Pivot") { card in if case .pivot(var cfg) = card.kind { body(&cfg); card.kind = .pivot(cfg) } }
    }
    func updateChart(_ id: UUID, _ body: (inout ChartConfig) -> Void) {
        updateCard(id, "Edit Chart") { card in if case .chart(var cfg) = card.kind { body(&cfg); card.kind = .chart(cfg) } }
    }
    func moveCard(_ id: UUID, to origin: CGPoint) {
        updateCanvas { c in if let i = c.cards.firstIndex(where: { $0.id == id }) { c.cards[i].origin = origin } }
        dirty = true
    }

    // MARK: Canvases

    func pickCanvas(_ i: Int) {
        guard workbook.canvases.indices.contains(i), i != canvasIndex else { return }
        selection = nil; closeMenus(); selectedCardID = nil; fullscreenCardID = nil
        canvasIndex = i
    }

    /// Moves `delta` canvases left (negative) or right, wrapping at either end.
    func stepCanvas(_ delta: Int) {
        let n = workbook.canvases.count
        guard n > 1 else { return }
        pickCanvas(((canvasIndex + delta) % n + n) % n)
    }

    func newCanvas() {
        var sheet = Sheet(name: "Sheet \(workbook.sheets.count + 1)", columns: [Column(name: "A", type: .text, width: 120), Column(name: "B", type: .number, width: 90), Column(name: "C", type: .number, width: 90)], rows: [])
        sheet.pinnedColumns = 0
        for _ in 0..<3 { sheet.appendRow() }
        let canvas = Canvas(name: sheet.name, cards: [Card(kind: .grid(sheetID: sheet.id), origin: .zero)])
        mutate("New Canvas") { wb in wb.sheets.append(sheet); wb.canvases.append(canvas) }
        pickCanvas(workbook.canvases.count - 1)
    }

    func renameCanvas(_ i: Int, to name: String) {
        guard workbook.canvases.indices.contains(i), !name.isEmpty else { return }
        mutate("Rename") { wb in
            let old = wb.canvases[i].name
            wb.canvases[i].name = name
            if let card = wb.canvases[i].gridCard, case .grid(let id) = card.kind, let si = wb.sheetIndex(id), wb.sheets[si].name == old {
                wb.sheets[si].name = name
            }
        }
    }

    // MARK: Viewport

    func zoom(to z: CGFloat, around point: CGPoint? = nil) {
        let z = max(0.35, min(2.5, z))
        let p = point ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        updateCanvas { c in
            let k = z / c.zoom
            c.pan = CGPoint(x: p.x - (p.x - c.pan.x) * k, y: p.y - (p.y - c.pan.y) * k)
            c.zoom = z
        }
        if point == nil { animateViewportRequest.send() }
    }

    func fit() {
        let bounds = Layout.contentBounds(canvas: canvas, workbook: workbook)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pad: CGFloat = 48
        let panelReserve: CGFloat = selectedCardID != nil ? 340 : 0
        let z = max(0.35, min(1.25, (viewportSize.width - panelReserve - 2 * pad) / bounds.width, (viewportSize.height - 2 * pad) / bounds.height))
        updateCanvas { c in
            c.zoom = z
            c.pan = CGPoint(x: pad + ((viewportSize.width - panelReserve) - 2 * pad - bounds.width * z) / 2 - bounds.minX * z,
                            y: pad + (viewportSize.height - 2 * pad - bounds.height * z) / 2 - bounds.minY * z)
        }
        animateViewportRequest.send()
    }

    // MARK: Files

    static var lastFileURL: URL? {
        get { UserDefaults.standard.url(forKey: "lastFile") }
        set { UserDefaults.standard.set(newValue, forKey: "lastFile") }
    }

    func newWorkbook() {
        workbook = Workbook.empty; fileURL = nil; dirty = false; canvasIndex = 0; selection = nil; selectedCardID = nil
        undoManager.removeAllActions()
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            workbook = try XLSXReader.read(from: url)
            fileURL = url; dirty = false; canvasIndex = 0; selection = nil; selectedCardID = nil
            undoManager.removeAllActions()
            AppState.lastFileURL = url
            show("opened \(url.lastPathComponent) · \(workbook.sheets.count) sheets")
        } catch {
            show("couldn't open \(url.lastPathComponent): \(error)")
        }
    }

    func save() {
        if let url = fileURL { save(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    private func save(to url: URL) {
        do {
            try XLSXWriter.write(workbook, to: url)
            fileURL = url; dirty = false
            AppState.lastFileURL = url
            show("saved \(url.lastPathComponent) — views stored as values + metadata")
        } catch {
            show("save failed: \(error)")
        }
    }

    func loadSample() {
        workbook = SampleData.workbook(); fileURL = nil; dirty = false; canvasIndex = 0; selection = nil; selectedCardID = nil
        undoManager.removeAllActions()
    }
}

private extension Column {
    var formulaTemplateIsSet: Bool { formulaTemplate != nil }
}
