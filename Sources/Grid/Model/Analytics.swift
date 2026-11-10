import Foundation

// MARK: - Formatting

enum CellFormatter {
    static func number(_ v: CellValue) -> Double? {
        switch v {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .text(let s): return Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
        default: return nil
        }
    }

    static func plainText(_ v: CellValue) -> String {
        switch v {
        case .empty: return ""
        case .text(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .formula(let f): return f
        }
    }

    /// Display string for a (fully evaluated) value in a typed column.
    static func display(_ v: CellValue, column: Column) -> String {
        if case .text(let s) = v, s.hasPrefix("#") { return s }   // error codes pass through
        switch column.type {
        case .text: return plainText(v)
        case .check:
            if case .bool(let b) = v { return b ? "☑" : "☐" }
            return plainText(v).isEmpty ? "☐" : "☑"
        case .number:
            guard let n = number(v) else { return plainText(v) }
            return numberString(n, decimals: column.decimals)
        case .currency:
            guard let n = number(v) else { return plainText(v) }
            return (n < 0 ? "-$" : "$") + numberString(abs(n), decimals: column.decimals)
        case .percent:
            guard let n = number(v) else { return plainText(v) }
            return numberString(n * 100, decimals: column.decimals) + "%"
        case .date:
            guard let n = number(v) else { return plainText(v) }
            return dateString(serial: n)
        }
    }

    static func numberString(_ n: Double, decimals: Int) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let f: NumberFormatter
        if let cached = formatters[decimals] { f = cached } else {
            f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
            f.usesGroupingSeparator = true
            formatters[decimals] = f
        }
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// One formatter per decimal count; building one per cell showed up in every redraw.
    private static var formatters: [Int: NumberFormatter] = [:]
    private static let formatterLock = NSLock()

    /// Excel serial date (days since 1899-12-30) → ISO date.
    static func dateString(serial: Double) -> String {
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 1899, month: 12, day: 30).date ?? Date()
        let d = base.addingTimeInterval(serial * 86400)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Parses what a user typed into a cell of a typed column.
    static func parse(_ text: String, column: Column) -> CellValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        if t.hasPrefix("=") { return .formula(t) }
        switch column.type {
        case .text: return .text(t)
        case .check: return .bool(["true", "yes", "1", "x", "☑"].contains(t.lowercased()))
        case .percent:
            let s = t.replacingOccurrences(of: "%", with: "")
            if let n = Double(s) { return .number(t.contains("%") || abs(n) > 1 ? n / 100 : n) }
            return .text(t)
        case .number, .currency, .date:
            let s = t.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            if let n = Double(s) { return .number(n) }
            if column.type == .date, let serial = serial(fromISO: t) { return .number(serial) }
            return .text(t)
        }
    }

    static func serial(fromISO s: String) -> Double? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: s) else { return nil }
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 1899, month: 12, day: 30).date ?? Date()
        return d.timeIntervalSince(base) / 86400
    }

    /// Formats an aggregate using the value column's type.
    static func aggregate(_ n: Double, field: Column?, aggregation: Aggregation) -> String {
        if aggregation == .count { return String(Int(n)) }
        guard let col = field else { return numberString(n, decimals: 0) }
        var c = col
        if aggregation == .avg && c.type == .percent { c.decimals = max(c.decimals, 1) }
        return display(.number(n), column: c)
    }
}

struct ValueCount: Hashable { var value: String; var count: Int }

// MARK: - Pivot

struct PivotRow: Equatable {
    var label: String
    var values: [Double]
    var total: Double
    var isTotal: Bool = false
}

struct PivotResult: Equatable {
    var rowField: String
    var columnHeaders: [String]        // one entry when there is no column field
    var rows: [PivotRow]
    var valueColumn: Column?
    var aggregation: Aggregation

    func format(_ n: Double) -> String { CellFormatter.aggregate(n, field: valueColumn, aggregation: aggregation) }
}

// MARK: - Chart

struct ChartSegment: Equatable { var value: Double; var seriesIndex: Int }
struct ChartBar: Equatable { var label: String; var total: Double; var segments: [ChartSegment] }
struct ChartResult: Equatable {
    var bars: [ChartBar]
    var series: [String]
    var maxValue: Double
    var yColumn: Column?
    var aggregation: Aggregation
    func format(_ n: Double) -> String { CellFormatter.aggregate(n, field: yColumn, aggregation: aggregation) }
}

extension Workbook {
    private func aggregate(_ rows: [VisibleRow], field: Int?, _ agg: Aggregation) -> Double {
        if agg == .count { return Double(rows.count) }
        guard let f = field else { return 0 }
        let nums = rows.compactMap { CellFormatter.number($0.values[f]) }
        if agg == .avg { return nums.isEmpty ? 0 : nums.reduce(0, +) / Double(nums.count) }
        return nums.reduce(0, +)
    }

    func pivot(_ cfg: PivotConfig) -> PivotResult? {
        guard let sheet = sheet(cfg.sheetID), let ri = sheet.columnIndex(named: cfg.rowField) else { return nil }
        let rows = visibleRows(of: sheet, respectFilter: cfg.respectFilter)
        let vi = sheet.columnIndex(named: cfg.valueField)
        let ci = cfg.columnField.flatMap { sheet.columnIndex(named: $0) }
        let keys = orderedDistinct(rows.map { CellFormatter.plainText($0.values[ri]) })
        let cols = ci.map { c in orderedDistinct(rows.map { CellFormatter.plainText($0.values[c]) }) } ?? []
        var out: [PivotRow] = keys.map { key in
            let mine = rows.filter { CellFormatter.plainText($0.values[ri]) == key }
            let values: [Double] = ci != nil
                ? cols.map { c in aggregate(mine.filter { CellFormatter.plainText($0.values[ci!]) == c }, field: vi, cfg.aggregation) }
                : [aggregate(mine, field: vi, cfg.aggregation)]
            return PivotRow(label: key, values: values, total: aggregate(mine, field: vi, cfg.aggregation))
        }
        if cfg.sortByValue { out.sort { $0.total > $1.total } } else { out.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending } }
        if cfg.totals {
            let colTotals: [Double] = ci != nil
                ? cols.map { c in aggregate(rows.filter { CellFormatter.plainText($0.values[ci!]) == c }, field: vi, cfg.aggregation) }
                : [aggregate(rows, field: vi, cfg.aggregation)]
            out.append(PivotRow(label: "Total", values: colTotals, total: aggregate(rows, field: vi, cfg.aggregation), isTotal: true))
        }
        let headers = ci != nil ? cols : [(cfg.aggregation == .count ? "count" : cfg.aggregation == .avg ? "avg " : "") + cfg.valueField]
        return PivotResult(rowField: cfg.rowField, columnHeaders: headers, rows: out, valueColumn: vi.map { sheet.columns[$0] }, aggregation: cfg.aggregation)
    }

    func chart(_ cfg: ChartConfig) -> ChartResult? {
        guard let sheet = sheet(cfg.sheetID), let xi = sheet.columnIndex(named: cfg.xField) else { return nil }
        let rows = visibleRows(of: sheet, respectFilter: cfg.respectFilter)
        let yi = sheet.columnIndex(named: cfg.yField)
        let si = cfg.seriesField.flatMap { sheet.columnIndex(named: $0) }
        let agg: Aggregation = (yi.map { sheet.columns[$0].type == .percent } ?? false) ? .avg : .sum
        let xs = orderedDistinct(rows.map { CellFormatter.plainText($0.values[xi]) })
        let series = si.map { s in orderedDistinct(rows.map { CellFormatter.plainText($0.values[s]) }) } ?? []
        var bars: [ChartBar] = xs.map { x in
            let mine = rows.filter { CellFormatter.plainText($0.values[xi]) == x }
            let total = aggregate(mine, field: yi, agg)
            let segs: [ChartSegment]
            if let s = si {
                segs = series.enumerated().compactMap { (i, name) in
                    let v = aggregate(mine.filter { CellFormatter.plainText($0.values[s]) == name }, field: yi, agg)
                    return v > 0 ? ChartSegment(value: v, seriesIndex: i) : nil
                }
            } else {
                segs = [ChartSegment(value: total, seriesIndex: 0)]
            }
            return ChartBar(label: x, total: total, segments: segs)
        }
        if cfg.sortByValue { bars.sort { $0.total > $1.total } } else { bars.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending } }
        return ChartResult(bars: bars, series: series, maxValue: max(1, bars.map { $0.total }.max() ?? 1), yColumn: yi.map { sheet.columns[$0] }, aggregation: agg)
    }

    /// Distinct values of a text column with their counts, in first-seen order.
    func distinctValues(sheet: Sheet, column: Int) -> [ValueCount] {
        var counts: [String: Int] = [:], order: [String] = []
        for row in evaluatedRows(of: sheet) {
            let k = CellFormatter.plainText(row[column])
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        return order.map { ValueCount(value: $0, count: counts[$0] ?? 0) }
    }

    private func orderedDistinct(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }
}

// MARK: - Formula descriptions (shown in the view panel)

extension PivotConfig {
    func formulaDescription(sheetName: String, range: String, filter: String?) -> String {
        var s = "=PIVOT(\(sheetName)!\(range), rows: \(rowField)"
        if let c = columnField { s += ", cols: \(c)" }
        s += ", values: \(aggregation.rawValue.uppercased())(\(valueField))"
        if respectFilter, let f = filter { s += ", where: \(f)" }
        return s + ")"
    }
}

extension ChartConfig {
    func formulaDescription(sheetName: String, range: String) -> String {
        var s = "=CHART(\(sheetName)!\(range), type: \"\(type.rawValue)\", x: \(xField), y: \(yField)"
        if let f = seriesField { s += ", series: \(f)" }
        return s + ")"
    }
}
