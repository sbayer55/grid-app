import Foundation

/// Structural edits: deleting or inserting whole rows or columns of a sheet. The other cells
/// move to close or make the gap, so every formula that addresses the sheet is rewritten to
/// keep pointing at the same data.

/// What was taken out of or put into a sheet. Rows are spreadsheet row numbers (2 = first data
/// row, since row 1 holds the column names); columns are 0-based indices. An insert names the
/// row or column the new ones go in front of.
enum StructuralEdit: Equatable {
    case deleteRows(Set<Int>)
    case deleteColumns(Set<Int>)
    case insertRows(before: Int, count: Int)
    case insertColumns(before: Int, count: Int)
}

extension Formula {
    /// Rewrites `formula` after `edit` was applied to the sheet called `sheetName`.
    /// `inEditedSheet` says whether the formula lives in that sheet, which decides whether its
    /// unqualified references are affected; `Name!A1` references are matched by name.
    ///
    /// References past the gap shift, a reference to a deleted cell becomes `#REF!`, and a range
    /// shrinks to what is left of it (`#REF!` once nothing is). After an insert, references at
    /// or past the new rows or columns shift, so a range that spans them grows to take them in.
    /// Unlike a paste, `$` anchors shift too: the cell they name has moved.
    static func adjusted(_ formula: String, for edit: StructuralEdit, sheetName: String, inEditedSheet: Bool) -> String {
        let chars = Array(formula)
        var out = ""
        var i = 0
        /// Sheet named by a `Name!` / `'Name'!` qualifier that the next reference belongs to.
        var qualifier: String?
        func upcoming(_ from: Int) -> (char: Character, index: Int)? {
            var j = from
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count ? (chars[j], j) : nil
        }
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" || c == "." }
        func applies() -> Bool {
            if let q = qualifier { return q.caseInsensitiveCompare(sheetName) == .orderedSame }
            return inEditedSheet
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {                       // string literal or quoted sheet name
                var body = ""
                out.append(c); i += 1
                while i < chars.count, chars[i] != c { body.append(chars[i]); out.append(chars[i]); i += 1 }
                if i < chars.count { out.append(c); i += 1 }
                if c == "'", upcoming(i)?.char == "!" { qualifier = body }
                continue
            }
            if c.isNumber || c == "." {                      // numeric literal
                while i < chars.count, chars[i].isNumber || chars[i] == "." { out.append(chars[i]); i += 1 }
                continue
            }
            guard c.isLetter || c == "_" || c == "$" else { out.append(c); i += 1; continue }
            let afterHash = out.last == "#"                  // the REF of an existing `#REF!`
            var word = ""
            while i < chars.count, isWordChar(chars[i]) { word.append(chars[i]); i += 1 }
            let next = upcoming(i)
            if next?.char == "(" || afterHash { out += word; qualifier = nil; continue }
            if next?.char == "!" { out += word; qualifier = word; continue }

            // A range: read the other end now so both ends are adjusted as one.
            if next?.char == ":", let colon = next?.index, let start = upcoming(colon + 1), isWordChar(start.char), !start.char.isNumber {
                var j = start.index, second = ""
                while j < chars.count, isWordChar(chars[j]) { second.append(chars[j]); j += 1 }
                if let a = Reference(word), let b = Reference(second), (a.row == nil) == (b.row == nil) {
                    out += applies() ? adjustedRange(a, b, for: edit) : word + ":" + second
                    i = j; qualifier = nil
                    continue
                }
            }
            if let ref = Reference(word), ref.row != nil, applies() {
                out += adjustedCell(ref, for: edit)
            } else {
                out += word
            }
            qualifier = nil
        }
        return out
    }

    /// `A1`, `$A1`, `A$1`, `$A$1`, or a bare column (`A`, `$A`) as found in `A:C`.
    private struct Reference {
        var col: Int
        var row: Int?
        var colFixed = false, rowFixed = false

        init?(_ word: String) {
            var rest = Substring(word)
            if rest.hasPrefix("$") { colFixed = true; rest.removeFirst() }
            let letters = rest.prefix { $0.isLetter && $0.isASCII }
            rest = rest.dropFirst(letters.count)
            guard (1...3).contains(letters.count), let c = Sheet.columnIndex(fromLetters: letters.uppercased()) else { return nil }
            col = c
            if rest.hasPrefix("$") { rowFixed = true; rest.removeFirst() }
            if rest.isEmpty { guard !rowFixed else { return nil }; return }
            guard rest.allSatisfy({ $0.isASCII && $0.isNumber }), let r = Int(rest), r >= 1 else { return nil }
            row = r
        }

        var text: String {
            (colFixed ? "$" : "") + Sheet.columnLetter(col) + (row.map { (rowFixed ? "$" : "") + String($0) } ?? "")
        }
    }

    /// Index of `n` once the `removed` indices below it are gone. Nil if `n` itself was removed.
    private static func closedUp(_ n: Int, removed: Set<Int>) -> Int? {
        removed.contains(n) ? nil : n - removed.filter { $0 < n }.count
    }

    private static func adjustedCell(_ ref: Reference, for edit: StructuralEdit) -> String {
        var ref = ref
        switch edit {
        case .deleteRows(let rows):
            guard let r = ref.row.flatMap({ closedUp($0, removed: rows) }) else { return "#REF!" }
            ref.row = r
        case .deleteColumns(let cols):
            guard let c = closedUp(ref.col, removed: cols) else { return "#REF!" }
            ref.col = c
        case .insertRows(let before, let count):
            ref.row = ref.row.map { $0 >= before ? $0 + count : $0 }
        case .insertColumns(let before, let count):
            if ref.col >= before { ref.col += count }
        }
        return ref.text
    }

    /// Both ends of `a:b`. Ends keep their written order; the span shrinks to the surviving
    /// rows or columns inside it.
    private static func adjustedRange(_ a: Reference, _ b: Reference, for edit: StructuralEdit) -> String {
        var a = a, b = b
        /// New (low, high) for the span `x...y` in either order, or nil when all of it was removed.
        func shrink(_ x: Int, _ y: Int, removed: Set<Int>) -> (Int, Int)? {
            let survivors = (min(x, y)...max(x, y)).filter { !removed.contains($0) }
            guard let lo = survivors.first.flatMap({ closedUp($0, removed: removed) }),
                  let hi = survivors.last.flatMap({ closedUp($0, removed: removed) }) else { return nil }
            return x <= y ? (lo, hi) : (hi, lo)
        }
        switch edit {
        case .deleteRows(let rows):
            guard let ra = a.row, let rb = b.row else { break }          // `F:F` has no rows to lose
            guard let (x, y) = shrink(ra, rb, removed: rows) else { return "#REF!" }
            a.row = x; b.row = y
        case .deleteColumns(let cols):
            guard let (x, y) = shrink(a.col, b.col, removed: cols) else { return "#REF!" }
            a.col = x; b.col = y
        case .insertRows(let before, let count):
            a.row = a.row.map { $0 >= before ? $0 + count : $0 }
            b.row = b.row.map { $0 >= before ? $0 + count : $0 }
        case .insertColumns(let before, let count):
            if a.col >= before { a.col += count }
            if b.col >= before { b.col += count }
        }
        return a.text + ":" + b.text
    }
}

extension Workbook {
    /// Applies `edit` to every formula that can see the sheet: its own cells and column
    /// templates, and cells of other sheets that name it.
    private mutating func rewriteFormulas(for edit: StructuralEdit, sheetID: UUID) {
        guard let name = sheet(sheetID)?.name else { return }
        /// Stands in for `{row}` while a template is rewritten.
        let rowToken = "1048576"
        for si in sheets.indices {
            let own = sheets[si].id == sheetID
            for r in sheets[si].rows.indices {
                for c in sheets[si].rows[r].indices {
                    guard case .formula(let f) = sheets[si].rows[r][c] else { continue }
                    let g = Formula.adjusted(f, for: edit, sheetName: name, inEditedSheet: own)
                    if g != f { sheets[si].rows[r][c] = .formula(g) }
                }
            }
            // Templates address "this row", so only a column edit can change them.
            switch edit {
            case .deleteRows, .insertRows: continue
            case .deleteColumns, .insertColumns: break
            }
            for c in sheets[si].columns.indices {
                guard let t = sheets[si].columns[c].formulaTemplate else { continue }
                let concrete = t.replacingOccurrences(of: "{row}", with: rowToken)
                let g = Formula.adjusted(concrete, for: edit, sheetName: name, inEditedSheet: own)
                sheets[si].columns[c].formulaTemplate = g.replacingOccurrences(of: rowToken, with: "{row}")
            }
        }
    }

    /// Removes whole rows (indices into `sheet.rows`) and closes the gap. Returns how many went.
    @discardableResult
    mutating func deleteRows(sheetID: UUID, sourceRows: Set<Int>) -> Int {
        guard let si = sheetIndex(sheetID) else { return 0 }
        let doomed = sourceRows.filter { sheets[si].rows.indices.contains($0) }
        guard !doomed.isEmpty else { return 0 }
        sheets[si].rows = sheets[si].rows.enumerated().filter { !doomed.contains($0.offset) }.map { $0.element }
        rewriteFormulas(for: .deleteRows(Set(doomed.map { $0 + 2 })), sheetID: sheetID)
        return doomed.count
    }

    /// Puts `count` empty rows in front of `sheet.rows[sourceRow]` (or at the end), filling
    /// formula columns from their templates like a newly appended row. Returns false if nothing changed.
    @discardableResult
    mutating func insertRows(sheetID: UUID, at sourceRow: Int, count: Int = 1) -> Bool {
        guard let si = sheetIndex(sheetID), count > 0, (0...sheets[si].rows.count).contains(sourceRow) else { return false }
        // Rewrite first, so the formulas of the new rows are not shifted a second time.
        rewriteFormulas(for: .insertRows(before: sourceRow + 2, count: count), sheetID: sheetID)
        let fresh: [[CellValue]] = (0..<count).map { i in
            sheets[si].columns.map { col in
                col.formulaTemplate.map { .formula($0.replacingOccurrences(of: "{row}", with: String(sourceRow + i + 2))) } ?? .empty
            }
        }
        sheets[si].rows.insert(contentsOf: fresh, at: sourceRow)
        return true
    }

    /// Puts `count` empty text columns in front of column `column` (or at the end), keeping
    /// sort keys, the value filter and pins on the columns they were on. Views are untouched:
    /// they name their fields. Returns the new columns' names, or nil if nothing changed.
    @discardableResult
    mutating func insertColumns(sheetID: UUID, at column: Int, count: Int = 1) -> [String]? {
        guard let si = sheetIndex(sheetID), count > 0, (0...sheets[si].columns.count).contains(column) else { return nil }
        rewriteFormulas(for: .insertColumns(before: column, count: count), sheetID: sheetID)
        var taken = Set(sheets[si].columns.map { $0.name })
        var names: [String] = []
        for i in 0..<count {
            // Named after its letter like an appended column, but never the same as an existing one.
            let base = "Col \(Sheet.columnLetter(column + i))"
            var name = base, n = 2
            while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
            taken.insert(name); names.append(name)
        }
        sheets[si].columns.insert(contentsOf: names.map { Column(name: $0, type: .text, width: 100) }, at: column)
        for r in sheets[si].rows.indices {
            sheets[si].rows[r].insert(contentsOf: Array(repeating: CellValue.empty, count: count), at: min(column, sheets[si].rows[r].count))
        }
        sheets[si].sorts = sheets[si].sorts.map { SortKey(column: $0.column >= column ? $0.column + count : $0.column, ascending: $0.ascending) }
        sheets[si].filter = sheets[si].filter.map { ValueFilter(column: $0.column >= column ? $0.column + count : $0.column, values: $0.values) }
        if column < sheets[si].pinnedColumns { sheets[si].pinnedColumns += count }   // inside the pinned block: it stays pinned
        return names
    }

    struct ColumnDeletion: Equatable {
        var names: [String]
        /// Pivots and charts that were built on a deleted column and went with it.
        var removedViews: Int
    }

    /// Removes whole columns and closes the gap, keeping sort keys, the value filter and pins
    /// pointing at the same columns. Views that lose an optional field keep going without it;
    /// views that lose a field they cannot do without are removed. Nil (and no change) when the
    /// request is empty or would leave the sheet without columns.
    @discardableResult
    mutating func deleteColumns(sheetID: UUID, columns: Set<Int>) -> ColumnDeletion? {
        guard let si = sheetIndex(sheetID) else { return nil }
        let doomed = columns.filter { sheets[si].columns.indices.contains($0) }
        guard !doomed.isEmpty, doomed.count < sheets[si].columns.count else { return nil }
        let names = doomed.sorted().map { sheets[si].columns[$0].name }
        func moved(_ c: Int) -> Int? { doomed.contains(c) ? nil : c - doomed.filter { $0 < c }.count }

        sheets[si].columns = sheets[si].columns.enumerated().filter { !doomed.contains($0.offset) }.map { $0.element }
        for r in sheets[si].rows.indices {
            sheets[si].rows[r] = sheets[si].rows[r].enumerated().filter { !doomed.contains($0.offset) }.map { $0.element }
        }
        sheets[si].sorts = sheets[si].sorts.compactMap { key in moved(key.column).map { SortKey(column: $0, ascending: key.ascending) } }
        sheets[si].filter = sheets[si].filter.flatMap { f in moved(f.column).map { ValueFilter(column: $0, values: f.values) } }
        sheets[si].pinnedColumns -= doomed.filter { $0 < sheets[si].pinnedColumns }.count
        rewriteFormulas(for: .deleteColumns(Set(doomed)), sheetID: sheetID)

        // Views name their fields, so only a name with no column left behind it is lost.
        let remaining = Set(sheets[si].columns.map { $0.name })
        func lost(_ field: String?) -> Bool { field.map { names.contains($0) && !remaining.contains($0) } ?? false }
        var removed = 0
        for ci in canvases.indices {
            canvases[ci].cards = canvases[ci].cards.compactMap { card in
                var card = card
                switch card.kind {
                case .grid: break
                case .pivot(var cfg) where cfg.sheetID == sheetID:
                    if lost(cfg.rowField) || lost(cfg.valueField) { removed += 1; return nil }
                    if lost(cfg.columnField) { cfg.columnField = nil }
                    card.kind = .pivot(cfg)
                case .chart(var cfg) where cfg.sheetID == sheetID:
                    if lost(cfg.xField) || lost(cfg.yField) { removed += 1; return nil }
                    if lost(cfg.seriesField) { cfg.seriesField = nil; if cfg.type == .stacked { cfg.type = .column } }
                    card.kind = .chart(cfg)
                default: break
                }
                return card
            }
        }
        return ColumnDeletion(names: names, removedViews: removed)
    }
}
