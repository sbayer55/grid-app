import Foundation

/// Tab- or comma-separated text with RFC 4180 quoting: a field is quoted when it holds the
/// delimiter, a quote or a line break, and quotes inside it are doubled. This is what Excel,
/// Numbers and Sheets put on the pasteboard, and what `.csv` files contain.
enum Delimited {
    static func encode(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains { $0 == delimiter || $0 == "\"" || $0.isNewline }
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(delimiter))
        }.joined(separator: "\n")
    }

    /// Rows may come back ragged; a trailing line break does not add an empty row.
    static func decode(_ text: String, delimiter: Character) -> [[String]] {
        // Unicode scalars, not Characters: "\r\n" is a single Character in Swift.
        let scalars = Array(text.unicodeScalars)
        let delim = delimiter.unicodeScalars.first!
        var rows: [[String]] = [], row: [String] = [], field = String.UnicodeScalarView()
        var quoted = false, fieldStarted = false
        var i = 0
        func endField() { row.append(String(field)); field = String.UnicodeScalarView(); fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < scalars.count {
            let c = scalars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append(c); i += 1 }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && !fieldStarted {
                quoted = true; fieldStarted = true
            } else if c == delim {
                endField()
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c); fieldStarted = true
            }
            i += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Plain text of unknown origin. A tab anywhere means TSV. Without tabs, two or more lines
    /// that all split into the same number (≥ 2) of comma-separated fields are CSV. Anything
    /// else is one cell per line, so a sentence with a comma in it stays in one cell.
    static func sniff(_ text: String) -> [[String]] {
        if text.contains("\t") { return decode(text, delimiter: "\t") }
        let csv = decode(text, delimiter: ",")
        if csv.count >= 2, let width = csv.first?.count, width >= 2, csv.allSatisfy({ $0.count == width }) { return csv }
        return decode(text, delimiter: "\t")
    }
}

/// A copied rectangle of cells as Grid itself round-trips it: raw values (formulas intact)
/// plus where each one came from, so a paste can shift relative references.
struct CellClip: Codable, Equatable {
    /// Raw cell values, row-major and rectangular.
    var cells: [[CellValue]]
    /// Evaluated, unformatted text of the same cells: what other apps receive.
    var texts: [[String]]
    /// Index in `sheet.rows` of each clip row (display order need not be sheet order).
    var sourceRows: [Int]
    var originCol: Int
    /// Cut cells move: their formulas are pasted as written.
    var isCut = false

    var rowCount: Int { cells.count }
    var colCount: Int { cells.first?.count ?? 0 }
}

enum PasteContent: Equatable {
    case clip(CellClip)
    case text([[String]])

    var rowCount: Int {
        switch self {
        case .clip(let c): return c.rowCount
        case .text(let t): return t.count
        }
    }
    var colCount: Int {
        switch self {
        case .clip(let c): return c.colCount
        case .text(let t): return t.map(\.count).max() ?? 0
        }
    }
}

/// A rectangle in display coordinates.
struct CellRange: Equatable {
    var rows: ClosedRange<Int>
    var cols: ClosedRange<Int>
}

extension Workbook {
    /// Copies a rectangle of display rows (after filter and sort) from a sheet.
    func clip(sheetID: UUID, rows: ClosedRange<Int>, cols: ClosedRange<Int>) -> CellClip? {
        guard let sheet = sheet(sheetID) else { return nil }
        let visible = visibleRows(of: sheet)
        let rows = rows.clamped(to: 0...max(0, visible.count - 1)), cols = cols.clamped(to: 0...max(0, sheet.columns.count - 1))
        guard !visible.isEmpty, !sheet.columns.isEmpty else { return nil }
        var clip = CellClip(cells: [], texts: [], sourceRows: [], originCol: cols.lowerBound)
        for r in rows {
            let v = visible[r]
            clip.cells.append(cols.map { sheet.rows[v.sourceIndex][$0] })
            clip.texts.append(cols.map { CellFormatter.plainText(v.values[$0]) })
            clip.sourceRows.append(v.sourceIndex)
        }
        return clip
    }

    /// Pastes at a display cell and returns the display rectangle that was written.
    ///
    /// - A single copied cell fills `fillRows × fillCols` (the selection).
    /// - A block that runs past the last row or column grows the sheet; new rows get their
    ///   column formula templates before the pasted values land on top.
    /// - Text is parsed by each destination column's type. Clip formulas have their relative
    ///   references shifted by the distance moved, unless the clip was cut.
    @discardableResult
    mutating func paste(_ content: PasteContent, sheetID: UUID, displayRow: Int, col: Int, fillRows: Int = 1, fillCols: Int = 1) -> CellRange? {
        guard let si = sheetIndex(sheetID), displayRow >= 0, col >= 0 else { return nil }
        let srcRows = content.rowCount, srcCols = content.colCount
        guard srcRows > 0, srcCols > 0 else { return nil }
        let single = srcRows == 1 && srcCols == 1
        let height = single ? max(1, fillRows) : srcRows, width = single ? max(1, fillCols) : srcCols

        // Resolve display rows to sheet rows before anything moves.
        let visible = visibleRows(of: sheets[si])
        guard displayRow <= visible.count else { return nil }
        var targets: [Int] = []
        for i in 0..<height {
            if displayRow + i < visible.count { targets.append(visible[displayRow + i].sourceIndex) }
            else { targets.append(sheets[si].rows.count); sheets[si].appendRow() }
        }
        while sheets[si].columns.count < col + width { sheets[si].appendColumn() }

        for i in 0..<height {
            for j in 0..<width {
                let r = targets[i], c = col + j
                let (si0, sj0) = single ? (0, 0) : (i, j)
                switch content {
                case .text(let rows):
                    guard sj0 < rows[si0].count else { continue }   // ragged row: leave the cell alone
                    sheets[si].rows[r][c] = CellFormatter.parse(rows[si0][sj0], column: sheets[si].columns[c])
                case .clip(let clip):
                    var value = clip.cells[si0][sj0]
                    if case .formula(let f) = value, !clip.isCut {
                        value = .formula(Formula.shifted(f, dRow: r - clip.sourceRows[si0], dCol: c - (clip.originCol + sj0)))
                    }
                    sheets[si].rows[r][c] = value
                }
            }
        }
        return CellRange(rows: displayRow...(displayRow + height - 1), cols: col...(col + width - 1))
    }
}
