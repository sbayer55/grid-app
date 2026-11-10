import Foundation

/// A small spreadsheet formula engine: arithmetic, comparisons, cell references,
/// ranges, cross-sheet references (`Orders!F2`, `'My Sheet'!A1:A9`) and a handful of
/// functions (SUM, AVERAGE/AVG, COUNT, MIN, MAX, ABS, ROUND, IF, AND, OR, NOT, LEN, CONCAT).
///
/// Values are resolved through a `Resolver` so the engine knows nothing about the
/// workbook layout; `Workbook.evaluator()` builds one.
enum FormulaValue: Equatable {
    case number(Double)
    case text(String)
    case bool(Bool)
    case empty
    case range([FormulaValue])
    case error(String)

    var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .text(let s): return Double(s.replacingOccurrences(of: ",", with: ""))
        default: return nil
        }
    }
    var asText: String {
        switch self {
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .empty: return ""
        case .range: return "#RANGE"
        case .error(let e): return e
        }
    }
    var asBool: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .text(let s): return !s.isEmpty
        default: return false
        }
    }
    /// Flattens ranges into scalar values (empties dropped) for aggregate functions.
    var flattened: [FormulaValue] {
        switch self {
        case .range(let vs): return vs.flatMap { $0.flattened }
        case .empty: return []
        default: return [self]
        }
    }
    var cellValue: CellValue {
        switch self {
        case .number(let n): return .number(n)
        case .text(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .empty: return .empty
        case .range: return .text("#RANGE")
        case .error(let e): return .text(e)
        }
    }
}

struct CellCoordinate: Hashable {
    var sheet: String?   // nil = current sheet
    var col: Int         // 0-based
    var row: Int         // 1-based spreadsheet row (1 = header)
}

struct Resolver {
    /// Raw value of a cell (may itself be a formula — the engine recurses).
    var cell: (CellCoordinate) -> CellValue
    /// Row count of a sheet (for open-ended ranges like `F:F`).
    var rowCount: (String?) -> Int
}

final class FormulaEngine {
    private let resolver: Resolver
    private let maxDepth = 48

    init(resolver: Resolver) { self.resolver = resolver }

    /// Evaluates a cell value in the context of `sheet`, following formulas.
    func value(of cell: CellValue, in sheet: String?, depth: Int = 0) -> FormulaValue {
        switch cell {
        case .empty: return .empty
        case .text(let s): return .text(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .formula(let f): return evaluate(f, in: sheet, depth: depth + 1)
        }
    }

    func evaluate(_ formula: String, in sheet: String?, depth: Int = 0) -> FormulaValue {
        if depth > maxDepth { return .error("#CYCLE") }
        var src = formula
        if src.hasPrefix("=") { src.removeFirst() }
        do {
            var lexer = Lexer(src)
            let tokens = try lexer.tokenize()
            var p = Parser(tokens: tokens, engine: self, sheet: sheet, depth: depth)
            let v = try p.parseExpression()
            if p.pos < p.tokens.count { return .error("#SYNTAX") }
            return v
        } catch let e as FormulaError {
            return .error(e.code)
        } catch {
            return .error("#ERR")
        }
    }

    fileprivate func cellValue(_ c: CellCoordinate, depth: Int) -> FormulaValue {
        value(of: resolver.cell(c), in: c.sheet, depth: depth)
    }
    fileprivate func rowCount(_ sheet: String?) -> Int { resolver.rowCount(sheet) }
}

enum FormulaError: Error {
    case syntax, ref, name, value, div0
    var code: String {
        switch self {
        case .syntax: return "#SYNTAX"
        case .ref: return "#REF!"
        case .name: return "#NAME?"
        case .value: return "#VALUE!"
        case .div0: return "#DIV/0!"
        }
    }
}

// MARK: - Lexer

fileprivate enum Token: Equatable {
    case number(Double)
    case string(String)
    case ident(String)
    case quotedSheet(String)
    case op(String)
    case lparen, rparen, comma, colon, bang
}

fileprivate struct Lexer {
    let chars: [Character]
    var i = 0
    init(_ s: String) { chars = Array(s) }

    mutating func tokenize() throws -> [Token] {
        var out: [Token] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "%" { i += 1; out.append(.number((Double(s) ?? 0) / 100)); continue }
                guard let n = Double(s) else { throw FormulaError.syntax }
                out.append(.number(n)); continue
            }
            if c == "\"" {
                i += 1; var s = ""
                while i < chars.count, chars[i] != "\"" { s.append(chars[i]); i += 1 }
                i += 1; out.append(.string(s)); continue
            }
            if c == "'" {
                i += 1; var s = ""
                while i < chars.count, chars[i] != "'" { s.append(chars[i]); i += 1 }
                i += 1; out.append(.quotedSheet(s)); continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var s = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" || chars[i] == "." { s.append(chars[i]); i += 1 }
                out.append(.ident(s)); continue
            }
            i += 1
            switch c {
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case ",": out.append(.comma)
            case ":": out.append(.colon)
            case "!": out.append(.bang)
            case "+", "-", "*", "/", "^", "&", "=": out.append(.op(String(c)))
            case "<":
                if i < chars.count, chars[i] == "=" { i += 1; out.append(.op("<=")) }
                else if i < chars.count, chars[i] == ">" { i += 1; out.append(.op("<>")) }
                else { out.append(.op("<")) }
            case ">":
                if i < chars.count, chars[i] == "=" { i += 1; out.append(.op(">=")) } else { out.append(.op(">")) }
            default: throw FormulaError.syntax
            }
        }
        return out
    }
}

// MARK: - Parser / evaluator

fileprivate struct Parser {
    let tokens: [Token]
    var pos = 0
    let engine: FormulaEngine
    let sheet: String?
    let depth: Int

    init(tokens: [Token], engine: FormulaEngine, sheet: String?, depth: Int) {
        self.tokens = tokens; self.engine = engine; self.sheet = sheet; self.depth = depth
    }

    var peek: Token? { pos < tokens.count ? tokens[pos] : nil }
    mutating func next() -> Token? { defer { pos += 1 }; return peek }
    mutating func expect(_ t: Token) throws { guard next() == t else { throw FormulaError.syntax } }

    mutating func parseExpression() throws -> FormulaValue { try parseComparison() }

    mutating func parseComparison() throws -> FormulaValue {
        var left = try parseAdditive()
        while case .op(let o)? = peek, ["=", "<>", "<", ">", "<=", ">="].contains(o) {
            pos += 1
            let right = try parseAdditive()
            left = compare(left, right, o)
        }
        return left
    }

    mutating func parseAdditive() throws -> FormulaValue {
        var left = try parseTerm()
        while case .op(let o)? = peek, o == "+" || o == "-" || o == "&" {
            pos += 1
            let right = try parseTerm()
            if o == "&" { left = .text(left.asText + right.asText); continue }
            left = try arith(left, right) { o == "+" ? $0 + $1 : $0 - $1 }
        }
        return left
    }

    mutating func parseTerm() throws -> FormulaValue {
        var left = try parsePower()
        while case .op(let o)? = peek, o == "*" || o == "/" {
            pos += 1
            let right = try parsePower()
            if o == "/" {
                guard let d = right.asNumber, d != 0 else { throw FormulaError.div0 }
            }
            left = try arith(left, right) { o == "*" ? $0 * $1 : $0 / $1 }
        }
        return left
    }

    mutating func parsePower() throws -> FormulaValue {
        var left = try parseUnary()
        while case .op("^")? = peek {
            pos += 1
            let right = try parseUnary()
            left = try arith(left, right) { pow($0, $1) }
        }
        return left
    }

    mutating func parseUnary() throws -> FormulaValue {
        if case .op("-")? = peek { pos += 1; let v = try parseUnary(); guard let n = v.asNumber else { throw FormulaError.value }; return .number(-n) }
        if case .op("+")? = peek { pos += 1; return try parseUnary() }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> FormulaValue {
        guard let t = next() else { throw FormulaError.syntax }
        switch t {
        case .number(let n): return .number(n)
        case .string(let s): return .text(s)
        case .lparen:
            let v = try parseExpression()
            try expect(.rparen)
            return v
        case .quotedSheet(let name):
            try expect(.bang)
            guard case .ident(let ref)? = next() else { throw FormulaError.syntax }
            return try parseReference(ref, sheet: name)
        case .ident(let name):
            if case .bang? = peek {
                pos += 1
                guard case .ident(let ref)? = next() else { throw FormulaError.syntax }
                return try parseReference(ref, sheet: name)
            }
            if case .lparen? = peek {
                pos += 1
                return try parseFunction(name.uppercased())
            }
            if Parser.parseCellRef(name) != nil || Parser.parseColumnRef(name) != nil {
                return try parseReference(name, sheet: sheet)
            }
            switch name.uppercased() {
            case "TRUE": return .bool(true)
            case "FALSE": return .bool(false)
            default: throw FormulaError.name
            }
        default: throw FormulaError.syntax
        }
    }

    /// Handles `A1`, `A1:B9` and `F:F` after the sheet qualifier has been consumed.
    mutating func parseReference(_ first: String, sheet: String?) throws -> FormulaValue {
        if case .colon? = peek {
            pos += 1
            guard case .ident(let second)? = next() else { throw FormulaError.syntax }
            let rows = engine.rowCount(sheet) + 1
            let a: (Int, Int), b: (Int, Int)
            if let c1 = Parser.parseCellRef(first), let c2 = Parser.parseCellRef(second) { a = c1; b = c2 }
            else if let c1 = Parser.parseColumnRef(first), let c2 = Parser.parseColumnRef(second) { a = (c1, 2); b = (c2, rows) }
            else { throw FormulaError.ref }
            var values: [FormulaValue] = []
            for r in min(a.1, b.1)...max(a.1, b.1) {
                for c in min(a.0, b.0)...max(a.0, b.0) {
                    values.append(engine.cellValue(CellCoordinate(sheet: sheet, col: c, row: r), depth: depth))
                }
            }
            return .range(values)
        }
        guard let (c, r) = Parser.parseCellRef(first) else { throw FormulaError.ref }
        return engine.cellValue(CellCoordinate(sheet: sheet, col: c, row: r), depth: depth)
    }

    static func parseCellRef(_ s: String) -> (Int, Int)? {
        let clean = s.replacingOccurrences(of: "$", with: "").uppercased()
        let letters = clean.prefix { $0.isLetter }
        let digits = clean.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let col = Sheet.columnIndex(fromLetters: String(letters)), let row = Int(digits), row >= 1 else { return nil }
        return (col, row)
    }

    static func parseColumnRef(_ s: String) -> Int? {
        let clean = s.replacingOccurrences(of: "$", with: "").uppercased()
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter }), clean.count <= 3 else { return nil }
        return Sheet.columnIndex(fromLetters: clean)
    }

    mutating func parseFunction(_ name: String) throws -> FormulaValue {
        var args: [FormulaValue] = []
        if case .rparen? = peek { pos += 1 } else {
            while true {
                args.append(try parseExpression())
                if case .comma? = peek { pos += 1; continue }
                try expect(.rparen); break
            }
        }
        let nums = args.flatMap { $0.flattened }.compactMap { $0.asNumber }
        switch name {
        case "SUM": return .number(nums.reduce(0, +))
        case "AVERAGE", "AVG": return nums.isEmpty ? .error("#DIV/0!") : .number(nums.reduce(0, +) / Double(nums.count))
        case "COUNT": return .number(Double(nums.count))
        case "COUNTA": return .number(Double(args.flatMap { $0.flattened }.count))
        case "MIN": return .number(nums.min() ?? 0)
        case "MAX": return .number(nums.max() ?? 0)
        case "ABS": guard let n = args.first?.asNumber else { throw FormulaError.value }; return .number(abs(n))
        case "ROUND":
            guard let n = args.first?.asNumber else { throw FormulaError.value }
            let places = args.count > 1 ? (args[1].asNumber ?? 0) : 0
            let f = pow(10, places)
            return .number((n * f).rounded() / f)
        case "IF":
            guard args.count >= 2 else { throw FormulaError.syntax }
            return args[0].asBool ? args[1] : (args.count > 2 ? args[2] : .bool(false))
        case "AND": return .bool(args.allSatisfy { $0.asBool })
        case "OR": return .bool(args.contains { $0.asBool })
        case "NOT": return .bool(!(args.first?.asBool ?? false))
        case "LEN": return .number(Double(args.first?.asText.count ?? 0))
        case "CONCAT", "CONCATENATE": return .text(args.map { $0.asText }.joined())
        case "PIVOT", "CHART": return .text("#VIEW")   // views live on cards, not in cells
        default: throw FormulaError.name
        }
    }

    func arith(_ a: FormulaValue, _ b: FormulaValue, _ f: (Double, Double) -> Double) throws -> FormulaValue {
        if case .error = a { return a }
        if case .error = b { return b }
        guard let x = a.asNumber, let y = b.asNumber else { throw FormulaError.value }
        return .number(f(x, y))
    }

    func compare(_ a: FormulaValue, _ b: FormulaValue, _ op: String) -> FormulaValue {
        if let x = a.asNumber, let y = b.asNumber, !(isText(a) || isText(b)) {
            switch op {
            case "=": return .bool(x == y)
            case "<>": return .bool(x != y)
            case "<": return .bool(x < y)
            case ">": return .bool(x > y)
            case "<=": return .bool(x <= y)
            default: return .bool(x >= y)
            }
        }
        let x = a.asText.lowercased(), y = b.asText.lowercased()
        switch op {
        case "=": return .bool(x == y)
        case "<>": return .bool(x != y)
        case "<": return .bool(x < y)
        case ">": return .bool(x > y)
        case "<=": return .bool(x <= y)
        default: return .bool(x >= y)
        }
    }

    private func isText(_ v: FormulaValue) -> Bool { if case .text = v { return true }; return false }
}

// MARK: - Workbook integration

extension Workbook {
    /// Builds an engine that resolves references against this workbook.
    func engine() -> FormulaEngine {
        let wb = self
        let resolver = Resolver(
            cell: { coord in
                guard let sheet = coord.sheet.flatMap({ wb.sheet(named: $0) }) ?? wb.sheets.first else { return .empty }
                guard coord.col >= 0, coord.col < sheet.columns.count else { return .empty }
                if coord.row == 1 { return .text(sheet.columns[coord.col].name) }
                let r = coord.row - 2
                guard r >= 0, r < sheet.rows.count else { return .empty }
                return sheet.rows[r][coord.col]
            },
            rowCount: { name in
                let sheet = name.flatMap { wb.sheet(named: $0) } ?? wb.sheets.first
                return sheet?.rows.count ?? 0
            }
        )
        return FormulaEngine(resolver: resolver)
    }

    /// Fully evaluated rows for a sheet (formulas replaced by their results).
    func evaluatedRows(of sheet: Sheet) -> [[CellValue]] {
        let engine = engine()
        return sheet.rows.map { row in
            row.map { cell in cell.isFormula ? engine.value(of: cell, in: sheet.name).cellValue : cell }
        }
    }
}

/// A row as displayed: its index in `sheet.rows` plus the evaluated values.
struct VisibleRow: Equatable {
    var sourceIndex: Int
    var values: [CellValue]
}

extension Workbook {
    /// Evaluated rows after the sheet's filter and sort keys are applied.
    func visibleRows(of sheet: Sheet, respectFilter: Bool = true) -> [VisibleRow] {
        var rows = evaluatedRows(of: sheet).enumerated().map { VisibleRow(sourceIndex: $0.offset, values: $0.element) }
        if respectFilter, let f = sheet.filter, f.column < sheet.columns.count {
            let allowed = Set(f.values)
            rows = rows.filter { allowed.contains(CellFormatter.plainText($0.values[f.column])) }
        }
        for key in sheet.sorts.reversed() where key.column < sheet.columns.count {
            let col = sheet.columns[key.column]
            let less: (CellValue, CellValue) -> Bool = { x, y in
                if col.type == .text {
                    return CellFormatter.plainText(x).localizedStandardCompare(CellFormatter.plainText(y)) == .orderedAscending
                }
                return (CellFormatter.number(x) ?? 0) < (CellFormatter.number(y) ?? 0)
            }
            rows = rows.stableSorted { a, b in
                let x = a.values[key.column], y = b.values[key.column]
                return key.ascending ? less(x, y) : less(y, x)
            }
        }
        return rows
    }
}

extension Array {
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map { $0.element }
    }
}
