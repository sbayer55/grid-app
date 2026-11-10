import Foundation
import CoreGraphics
import ZIPFoundation

/// Minimal .xlsx reader. Handles shared strings, inline strings, numbers, booleans,
/// formulas (with cached values), column widths, frozen panes and number formats
/// (used to infer column types). If the file carries `xl/grid-meta.json` from this app,
/// canvases, cards and column metadata are restored exactly.
enum XLSXReader {
    enum ReadError: Error { case notAnArchive, missingWorkbook }

    static func read(from url: URL) throws -> Workbook {
        let archive = try Archive(url: url, accessMode: .read)
        func part(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var out = Data()
            _ = try? archive.extract(entry, consumer: { out.append($0) })
            return out
        }
        guard let wbData = part("xl/workbook.xml") else { throw ReadError.missingWorkbook }
        let sheetsList = WorkbookParser.parse(wbData)
        let rels = RelsParser.parse(part("xl/_rels/workbook.xml.rels") ?? Data())
        let shared = part("xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let styles = part("xl/styles.xml").map(StylesParser.parse) ?? StylesParser.Result()
        let meta = part("xl/grid-meta.json").flatMap(Meta.decode)
        let generated = Set(meta?.generatedSheets ?? [])

        var sheets: [Sheet] = []
        for entry in sheetsList where !generated.contains(entry.name) {
            guard let target = rels[entry.rId] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            guard let data = part(path) else { continue }
            let raw = SheetParser.parse(data, shared: shared)
            sheets.append(makeSheet(name: entry.name, raw: raw, styles: styles, meta: meta?.sheets.first { $0.name == entry.name }))
        }
        if sheets.isEmpty { sheets = [Sheet(name: "Sheet 1", columns: [Column(name: "A"), Column(name: "B")], rows: [])] }

        var workbook = Workbook(sheets: sheets, canvases: [])
        if let meta = meta {
            // Keep only canvases whose grid sheets exist; drop cards pointing at missing sheets.
            let ids = Set(sheets.map { $0.id })
            workbook.canvases = meta.canvases.compactMap { canvas in
                var c = canvas
                c.cards = c.cards.filter { card in
                    switch card.kind {
                    case .grid(let id): return ids.contains(id)
                    case .pivot(let cfg): return ids.contains(cfg.sheetID)
                    case .chart(let cfg): return ids.contains(cfg.sheetID)
                    }
                }
                return c.cards.isEmpty ? nil : c
            }
        }
        let covered = Set(workbook.canvases.flatMap { $0.cards.compactMap { card -> UUID? in if case .grid(let id) = card.kind { return id }; return nil } })
        for sheet in sheets where !covered.contains(sheet.id) {
            workbook.canvases.append(Canvas(name: sheet.name, cards: [Card(kind: .grid(sheetID: sheet.id), origin: .zero)]))
        }
        return workbook
    }

    // MARK: Sheet assembly

    struct RawCell { var value: CellValue; var styleIndex: Int }
    struct RawSheet {
        var cells: [Int: [Int: RawCell]] = [:]   // row (1-based) → col (0-based) → cell
        var widths: [Int: CGFloat] = [:]         // col → px
        var frozenRows = 0, frozenCols = 0
        var maxRow = 0, maxCol = -1
    }

    static func makeSheet(name: String, raw: RawSheet, styles: StylesParser.Result, meta: Meta.SheetMeta?) -> Sheet {
        let colCount = max(raw.maxCol + 1, meta?.columns.count ?? 0)
        let headerRow = raw.cells[1] ?? [:]
        let headerIsText = colCount > 0 && (0..<colCount).allSatisfy { c in
            if let cell = headerRow[c] { if case .text = cell.value { return true }; return false }
            return true
        } && !headerRow.isEmpty

        var columns: [Column] = []
        if let m = meta, m.columns.count == colCount {
            columns = m.columns
        } else {
            for c in 0..<colCount {
                var col = Column(name: headerIsText ? (headerRow[c].map { CellFormatter.plainText($0.value) } ?? Sheet.columnLetter(c)) : Sheet.columnLetter(c))
                if col.name.isEmpty { col.name = Sheet.columnLetter(c) }
                col.width = raw.widths[c] ?? 100
                // Infer type from the first non-empty data cell's number format / value.
                let firstDataRow = headerIsText ? 2 : 1
                if raw.maxRow >= firstDataRow {
                    for r in firstDataRow...raw.maxRow {
                        guard let cell = raw.cells[r]?[c], !cell.value.isEmpty else { continue }
                        let fmt = styles.format(forStyle: cell.styleIndex)
                        switch cell.value {
                        case .number:
                            if fmt.code.contains("%") { col.type = .percent; col.decimals = fmt.decimals }
                            else if fmt.code.contains("$") || fmt.code.contains("€") || fmt.code.contains("£") || fmt.code.contains("¤") { col.type = .currency; col.decimals = fmt.decimals }
                            else if fmt.isDate { col.type = .date }
                            else { col.type = .number; col.decimals = fmt.decimals }
                        case .bool: col.type = .check
                        case .formula: col.type = fmt.code.contains("%") ? .percent : (fmt.code.contains("$") ? .currency : .number); col.decimals = fmt.decimals
                        default: col.type = .text
                        }
                        break
                    }
                }
                columns.append(col)
            }
        }

        var rows: [[CellValue]] = []
        let firstDataRow = (meta != nil || headerIsText) ? 2 : 1
        if raw.maxRow >= firstDataRow {
            for r in firstDataRow...raw.maxRow {
                let rowCells = raw.cells[r] ?? [:]
                rows.append((0..<colCount).map { rowCells[$0]?.value ?? .empty })
            }
        }
        var sheet = Sheet(id: meta?.id ?? UUID(), name: name, columns: columns, rows: rows)
        sheet.sorts = meta?.sorts ?? []
        sheet.filter = meta?.filter
        sheet.pinnedRows = meta?.pinnedRows ?? raw.frozenRows
        sheet.pinnedColumns = meta?.pinnedColumns ?? raw.frozenCols
        return sheet
    }
}

// MARK: - XML parsers

final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Entry { var name: String; var rId: String }
    private var entries: [Entry] = []

    static func parse(_ data: Data) -> [Entry] {
        let p = WorkbookParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.entries
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "sheet" || name.hasSuffix(":sheet") {
            let rId = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
            entries.append(Entry(name: attributes["name"] ?? "Sheet", rId: rId))
        }
    }
}

final class RelsParser: NSObject, XMLParserDelegate {
    private var map: [String: String] = [:]
    static func parse(_ data: Data) -> [String: String] {
        let p = RelsParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.map
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "Relationship", let id = attributes["Id"], let t = attributes["Target"] { map[id] = t }
    }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inT = false
    private var inSI = false

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.strings
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { inSI = true; current = "" }
        if name == "t" && inSI { inT = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inT { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false }
        if name == "si" { strings.append(current); inSI = false }
    }
}

final class StylesParser: NSObject, XMLParserDelegate {
    struct Format { var code: String; var decimals: Int; var isDate: Bool }
    struct Result {
        var numFmts: [Int: String] = [:]
        var cellXfs: [Int] = []   // xf index → numFmtId

        func format(forStyle s: Int) -> Format {
            let id = s >= 0 && s < cellXfs.count ? cellXfs[s] : 0
            let builtin: [Int: String] = [1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)", 39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)"]
            let code = numFmts[id] ?? builtin[id] ?? ""
            let isDate = (14...22).contains(id) || (45...47).contains(id) || (code.lowercased().contains("yy") || code.lowercased().contains("dd")) && !code.contains("#")
            var decimals = 0
            if let dot = code.firstIndex(of: ".") {
                decimals = code[code.index(after: dot)...].prefix { $0 == "0" }.count
            }
            return Format(code: code, decimals: decimals, isDate: isDate)
        }
    }
    private var result = Result()
    private var inCellXfs = false

    static func parse(_ data: Data) -> Result {
        let p = StylesParser(); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.result
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "numFmt":
            if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] { result.numFmts[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf": if inCellXfs { result.cellXfs.append(Int(attributes["numFmtId"] ?? "0") ?? 0) }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cellXfs" { inCellXfs = false }
    }
}

final class SheetParser: NSObject, XMLParserDelegate {
    private var raw = XLSXReader.RawSheet()
    private let shared: [String]
    private var ref = "", type = "", style = 0
    private var v = "", f = "", isText = ""
    private var inV = false, inF = false, inIS = false, inT = false, inC = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> XLSXReader.RawSheet {
        let p = SheetParser(shared: shared); let x = XMLParser(data: data); x.delegate = p; x.parse(); return p.raw
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "c":
            inC = true; ref = attributes["r"] ?? ""; type = attributes["t"] ?? ""; style = Int(attributes["s"] ?? "0") ?? 0
            v = ""; f = ""; isText = ""
        case "v": inV = true
        case "f": inF = true
        case "is": inIS = true
        case "t": if inIS { inT = true }
        case "col":
            if let lo = Int(attributes["min"] ?? ""), let hi = Int(attributes["max"] ?? ""), let w = Double(attributes["width"] ?? ""), lo >= 1, lo <= hi, hi - lo < 1000 {
                for c in lo...hi { raw.widths[c - 1] = CGFloat(w * 7 + 5) }
            }
        case "pane":
            if attributes["state"] == "frozen" {
                raw.frozenRows = Int(attributes["ySplit"] ?? "0") ?? 0
                raw.frozenCols = Int(attributes["xSplit"] ?? "0") ?? 0
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { v += string } else if inF { f += string } else if inT { isText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inV = false
        case "f": inF = false
        case "t": inT = false
        case "is": inIS = false
        case "c":
            inC = false
            guard let (col, row) = SheetParser.parseRef(ref) else { return }
            var value: CellValue
            if !f.isEmpty {
                value = .formula("=" + f)
            } else {
                switch type {
                case "s": value = Int(v).flatMap { (i: Int) -> CellValue? in i < shared.count ? CellValue.text(shared[i]) : nil } ?? .empty
                case "inlineStr": value = .text(isText)
                case "str": value = .text(v)
                case "b": value = .bool(v == "1")
                case "e": value = .text(v)
                default: value = Double(v).map { .number($0) } ?? (v.isEmpty ? .empty : .text(v))
                }
            }
            if value.isEmpty { return }
            raw.cells[row, default: [:]][col] = XLSXReader.RawCell(value: value, styleIndex: style)
            raw.maxRow = max(raw.maxRow, row); raw.maxCol = max(raw.maxCol, col)
        default: break
        }
    }

    static func parseRef(_ s: String) -> (Int, Int)? {
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard let col = Sheet.columnIndex(fromLetters: String(letters)), let row = Int(digits) else { return nil }
        return (col, row)
    }
}
