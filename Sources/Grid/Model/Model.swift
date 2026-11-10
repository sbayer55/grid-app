import Foundation
import CoreGraphics

// MARK: - Cells

/// A cell holds a plain value or a formula (stored with its leading "=").
enum CellValue: Equatable, Codable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    case formula(String)

    var isEmpty: Bool { if case .empty = self { return true }; return false }
    var isFormula: Bool { if case .formula = self { return true }; return false }

    /// The text a user sees when they start editing the cell.
    var editText: String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .formula(let f): return f
        }
    }
}

enum ColumnType: String, Codable, CaseIterable {
    case text, number, currency, percent, date, check

    var label: String {
        switch self {
        case .text: return "Aa text"
        case .number: return "# num"
        case .currency: return "$ cur"
        case .percent: return "% pct"
        case .date: return "◷ date"
        case .check: return "☑ check"
        }
    }
    var isNumeric: Bool { self != .text && self != .check }
}

enum CellAlignment: String, Codable, CaseIterable { case left, center, right }

struct Column: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: ColumnType = .text
    var width: CGFloat = 100
    var alignment: CellAlignment? = nil
    var decimals: Int = 0
    /// Color cells by their text value (used for status-like columns).
    var colorByValue: Bool = false
    /// Template for new rows, e.g. "=D{row}*E{row}". `{row}` is the 1-based sheet row.
    var formulaTemplate: String? = nil

    var effectiveAlignment: CellAlignment { alignment ?? (type == .text ? .left : .right) }
}

struct SortKey: Codable, Equatable {
    var column: Int
    var ascending: Bool
}

struct ValueFilter: Codable, Equatable {
    var column: Int
    var values: [String]
}

// MARK: - Sheets

struct Sheet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var columns: [Column]
    /// Data rows. Row index 0 is spreadsheet row 2 — row 1 is the header (column names).
    var rows: [[CellValue]]
    var sorts: [SortKey] = []
    var filter: ValueFilter? = nil
    var pinnedRows: Int = 1
    var pinnedColumns: Int = 1

    func columnIndex(named name: String) -> Int? { columns.firstIndex { $0.name == name } }

    /// A1-style range covering the header and all rows.
    var rangeDescription: String {
        "A1:\(Sheet.columnLetter(max(0, columns.count - 1)))\(rows.count + 1)"
    }

    static func columnLetter(_ index: Int) -> String {
        var i = index + 1, s = ""
        while i > 0 { let r = (i - 1) % 26; s = String(Character(UnicodeScalar(UInt8(65 + r)))) + s; i = (i - 1) / 26 }
        return s
    }

    static func columnIndex(fromLetters s: String) -> Int? {
        var n = 0
        for ch in s.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { return nil }
            n = n * 26 + Int(a - 64)
        }
        return n > 0 ? n - 1 : nil
    }

    mutating func appendRow() {
        let rowNumber = rows.count + 2
        rows.append(columns.map { col in
            if let t = col.formulaTemplate { return .formula(t.replacingOccurrences(of: "{row}", with: String(rowNumber))) }
            return .empty
        })
    }

    mutating func appendColumn() {
        columns.append(Column(name: "Col \(Sheet.columnLetter(columns.count))", type: .text, width: 100))
        for i in rows.indices { rows[i].append(.empty) }
    }
}

// MARK: - Views (pivot / chart)

enum Aggregation: String, Codable, CaseIterable {
    case sum, avg, count
    var label: String { rawValue }
}

struct PivotConfig: Codable, Equatable {
    var sheetID: UUID
    var rowField: String
    var columnField: String? = nil
    var valueField: String
    var aggregation: Aggregation = .sum
    var totals: Bool = true
    var sortByValue: Bool = false
    var respectFilter: Bool = true
}

enum ChartType: String, Codable, CaseIterable {
    case bar, column, stacked
}

struct ChartConfig: Codable, Equatable {
    var sheetID: UUID
    var type: ChartType = .bar
    var xField: String
    var yField: String
    var seriesField: String? = nil
    var valueLabels: Bool = true
    var sortByValue: Bool = true
    var respectFilter: Bool = true
}

enum CardKind: Codable, Equatable {
    case grid(sheetID: UUID)
    case pivot(PivotConfig)
    case chart(ChartConfig)

    var label: String {
        switch self {
        case .grid: return "sheet"
        case .pivot: return "pivot"
        case .chart: return "chart"
        }
    }
    var isGrid: Bool { if case .grid = self { return true }; return false }
}

struct Card: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: CardKind
    var origin: CGPoint
}

// MARK: - Canvases

struct Canvas: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
    var pan: CGPoint = CGPoint(x: 30, y: 24)
    var zoom: CGFloat = 1

    var gridCard: Card? { cards.first { $0.kind.isGrid } }
}

struct Workbook: Codable, Equatable {
    var sheets: [Sheet] = []
    var canvases: [Canvas] = []

    func sheet(_ id: UUID) -> Sheet? { sheets.first { $0.id == id } }
    func sheetIndex(_ id: UUID) -> Int? { sheets.firstIndex { $0.id == id } }
    func sheet(named name: String) -> Sheet? { sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    static var empty: Workbook {
        var wb = Workbook()
        var sheet = Sheet(name: "Sheet 1", columns: [
            Column(name: "A", type: .text, width: 120), Column(name: "B", type: .number, width: 90), Column(name: "C", type: .number, width: 90)
        ], rows: [])
        sheet.pinnedColumns = 0
        for _ in 0..<5 { sheet.appendRow() }
        wb.sheets = [sheet]
        wb.canvases = [Canvas(name: "Sheet 1", cards: [Card(kind: .grid(sheetID: sheet.id), origin: .zero)])]
        return wb
    }
}

// MARK: - Selection

struct CellRef: Equatable, Hashable {
    var row: Int   // display row index (after filter/sort), 0-based
    var col: Int
}

struct Selection: Equatable {
    var cardID: UUID
    var anchor: CellRef
    var focus: CellRef

    var minRow: Int { min(anchor.row, focus.row) }
    var maxRow: Int { max(anchor.row, focus.row) }
    var minCol: Int { min(anchor.col, focus.col) }
    var maxCol: Int { max(anchor.col, focus.col) }
    func contains(_ r: Int, _ c: Int) -> Bool { r >= minRow && r <= maxRow && c >= minCol && c <= maxCol }
}
