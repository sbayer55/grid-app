import Foundation
import ZIPFoundation

/// Minimal .xlsx writer: one worksheet per sheet, inline strings, typed number formats,
/// formulas with cached values, frozen panes for pinned rows/columns, plus a
/// `xl/grid-meta.json` part that carries canvases, cards and column metadata so the
/// file round-trips through this app losslessly. Excel ignores the extra part.
enum XLSXWriter {
    static let generatedSheetPrefix = "Pivot · "

    static func write(_ workbook: Workbook, to url: URL) throws {
        let parts = try build(workbook)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in parts {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate, provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            })
        }
    }

    /// Builds every package part. Exposed for tests.
    static func build(_ workbook: Workbook) throws -> [(String, Data)] {
        var styles = StyleTable()
        var sheetsXML: [(name: String, xml: String)] = []
        for sheet in workbook.sheets {
            sheetsXML.append((sheet.name, worksheetXML(sheet, workbook: workbook, styles: &styles)))
        }
        // Pivot views become plain value sheets so Excel users can see them.
        var generated: [String] = []
        for canvas in workbook.canvases {
            for card in canvas.cards {
                if case .pivot(let cfg) = card.kind, let result = workbook.pivot(cfg) {
                    var name = generatedSheetPrefix + cfg.rowField
                    var n = 2
                    while sheetsXML.contains(where: { $0.name == name }) { name = generatedSheetPrefix + cfg.rowField + " \(n)"; n += 1 }
                    generated.append(name)
                    sheetsXML.append((name, pivotSheetXML(result, styles: &styles)))
                }
            }
        }

        var parts: [(String, Data)] = []
        parts.append(("[Content_Types].xml", contentTypes(sheetCount: sheetsXML.count).data))
        parts.append(("_rels/.rels", rootRels.data))
        parts.append(("xl/workbook.xml", workbookXML(sheetsXML.map { $0.name }).data))
        parts.append(("xl/_rels/workbook.xml.rels", workbookRels(sheetCount: sheetsXML.count).data))
        parts.append(("xl/styles.xml", styles.xml.data))
        for (i, s) in sheetsXML.enumerated() { parts.append(("xl/worksheets/sheet\(i + 1).xml", s.xml.data)) }
        parts.append(("xl/grid-meta.json", try Meta.encode(workbook, generatedSheets: generated)))
        return parts
    }

    // MARK: Parts

    static func contentTypes(sheetCount: Int) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="json" ContentType="application/json"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>

        """
        for i in 1...max(1, sheetCount) {
            s += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n"
        }
        return s + "</Types>"
    }

    static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    static func workbookXML(_ names: [String]) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>

        """
        for (i, n) in names.enumerated() {
            s += "<sheet name=\"\(xmlEscape(String(n.prefix(31))))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>\n"
        }
        return s + "</sheets>\n</workbook>"
    }

    static func workbookRels(sheetCount: Int) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">

        """
        for i in 1...max(1, sheetCount) {
            s += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i).xml\"/>\n"
        }
        s += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n"
        return s + "</Relationships>"
    }

    static func worksheetXML(_ sheet: Sheet, workbook: Workbook, styles: inout StyleTable) -> String {
        let evaluated = workbook.evaluatedRows(of: sheet)
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheetViews><sheetView workbookViewId="0">
        """
        if sheet.pinnedRows > 0 || sheet.pinnedColumns > 0 {
            let topLeft = Sheet.columnLetter(sheet.pinnedColumns) + String(sheet.pinnedRows + 1)
            s += "<pane"
            if sheet.pinnedColumns > 0 { s += " xSplit=\"\(sheet.pinnedColumns)\"" }
            if sheet.pinnedRows > 0 { s += " ySplit=\"\(sheet.pinnedRows)\"" }
            s += " topLeftCell=\"\(topLeft)\" activePane=\"bottomRight\" state=\"frozen\"/>"
        }
        s += "</sheetView></sheetViews>\n<cols>"
        for (i, col) in sheet.columns.enumerated() {
            s += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(String(format: "%.2f", Double(col.width - 5) / 7))\" customWidth=\"1\"/>"
        }
        s += "</cols>\n<sheetData>\n"
        // Header row
        s += "<row r=\"1\">"
        for (c, col) in sheet.columns.enumerated() {
            s += cellXML(ref: Sheet.columnLetter(c) + "1", value: .text(col.name), cached: nil, style: styles.index(for: .text, decimals: 0, bold: true))
        }
        s += "</row>\n"
        for (r, row) in sheet.rows.enumerated() {
            s += "<row r=\"\(r + 2)\">"
            for (c, cell) in row.enumerated() where c < sheet.columns.count {
                let col = sheet.columns[c]
                if cell.isEmpty { continue }
                let cached = cell.isFormula && r < evaluated.count ? evaluated[r][c] : nil
                s += cellXML(ref: Sheet.columnLetter(c) + String(r + 2), value: cell, cached: cached, style: styles.index(for: col.type, decimals: col.decimals, bold: false))
            }
            s += "</row>\n"
        }
        s += "</sheetData>\n"
        if !sheet.columns.isEmpty { s += "<autoFilter ref=\"\(sheet.rangeDescription)\"/>\n" }
        return s + "</worksheet>"
    }

    static func pivotSheetXML(_ result: PivotResult, styles: inout StyleTable) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>

        """
        let bold = styles.index(for: .text, decimals: 0, bold: true)
        let valType = result.aggregation == .count ? ColumnType.number : (result.valueColumn?.type ?? .number)
        let valStyle = styles.index(for: valType, decimals: result.valueColumn?.decimals ?? 0, bold: false)
        s += "<row r=\"1\">" + cellXML(ref: "A1", value: .text(result.rowField), cached: nil, style: bold)
        for (i, h) in result.columnHeaders.enumerated() { s += cellXML(ref: Sheet.columnLetter(i + 1) + "1", value: .text(h), cached: nil, style: bold) }
        if result.columnHeaders.count > 1 { s += cellXML(ref: Sheet.columnLetter(result.columnHeaders.count + 1) + "1", value: .text("Total"), cached: nil, style: bold) }
        s += "</row>\n"
        for (r, row) in result.rows.enumerated() {
            let rn = r + 2
            s += "<row r=\"\(rn)\">" + cellXML(ref: "A\(rn)", value: .text(row.label), cached: nil, style: row.isTotal ? bold : 0)
            for (i, v) in row.values.enumerated() { s += cellXML(ref: Sheet.columnLetter(i + 1) + String(rn), value: .number(v), cached: nil, style: valStyle) }
            if result.columnHeaders.count > 1 { s += cellXML(ref: Sheet.columnLetter(result.columnHeaders.count + 1) + String(rn), value: .number(row.total), cached: nil, style: valStyle) }
            s += "</row>\n"
        }
        return s + "</sheetData>\n</worksheet>"
    }

    static func cellXML(ref: String, value: CellValue, cached: CellValue?, style: Int) -> String {
        let st = style > 0 ? " s=\"\(style)\"" : ""
        switch value {
        case .empty: return ""
        case .text(let t): return "<c r=\"\(ref)\" t=\"inlineStr\"\(st)><is><t xml:space=\"preserve\">\(xmlEscape(t))</t></is></c>"
        case .number(let n): return "<c r=\"\(ref)\"\(st)><v>\(numberText(n))</v></c>"
        case .bool(let b): return "<c r=\"\(ref)\" t=\"b\"\(st)><v>\(b ? 1 : 0)</v></c>"
        case .formula(let f):
            var body = f
            if body.hasPrefix("=") { body.removeFirst() }
            switch cached {
            case .number(let n)?: return "<c r=\"\(ref)\"\(st)><f>\(xmlEscape(body))</f><v>\(numberText(n))</v></c>"
            case .text(let t)?: return "<c r=\"\(ref)\" t=\"str\"\(st)><f>\(xmlEscape(body))</f><v>\(xmlEscape(t))</v></c>"
            case .bool(let b)?: return "<c r=\"\(ref)\" t=\"b\"\(st)><f>\(xmlEscape(body))</f><v>\(b ? 1 : 0)</v></c>"
            default: return "<c r=\"\(ref)\"\(st)><f>\(xmlEscape(body))</f></c>"
            }
        }
    }

    static func numberText(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Assigns cell style (xf) indices for (type, decimals, bold) combinations and renders styles.xml.
struct StyleTable {
    struct Key: Hashable { var type: ColumnType; var decimals: Int; var bold: Bool }
    private var keys: [Key] = []            // xf index = position + 1 (0 is the default xf)
    private var numFmts: [String: Int] = [:] // format code → id (custom ids start at 164)

    mutating func index(for type: ColumnType, decimals: Int, bold: Bool) -> Int {
        if type == .text && !bold { return 0 }
        let k = Key(type: type, decimals: min(max(decimals, 0), 4), bold: bold)
        if let i = keys.firstIndex(of: k) { return i + 1 }
        keys.append(k)
        _ = numFmtID(for: k)
        return keys.count
    }

    private mutating func numFmtID(for k: Key) -> Int {
        let dec = k.decimals > 0 ? "." + String(repeating: "0", count: k.decimals) : ""
        let code: String
        switch k.type {
        case .text, .check: return 0
        case .number: code = "#,##0" + dec
        case .currency: code = "\"$\"#,##0" + dec
        case .percent: code = "0" + dec + "%"
        case .date: return 14
        }
        if let id = numFmts[code] { return id }
        let id = 164 + numFmts.count
        numFmts[code] = id
        return id
    }

    var xml: String {
        var s = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">

        """
        if !numFmts.isEmpty {
            s += "<numFmts count=\"\(numFmts.count)\">"
            for (code, id) in numFmts.sorted(by: { $0.value < $1.value }) { s += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(XLSXWriter.xmlEscape(code))\"/>" }
            s += "</numFmts>\n"
        }
        s += """
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="\(keys.count + 1)">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>

        """
        var table = self
        for k in keys {
            let id = table.numFmtID(for: k)
            let applyFmt = id > 0 ? " applyNumberFormat=\"1\"" : ""
            let applyFont = k.bold ? " applyFont=\"1\"" : ""
            s += "<xf numFmtId=\"\(id)\" fontId=\"\(k.bold ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\"" + applyFmt + applyFont + "/>\n"
        }
        s += "</cellXfs>\n<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>\n</styleSheet>"
        return s
    }
}

// MARK: - Metadata part

/// Everything that is not plain cell data: column types/widths, sorts, filters, pins,
/// canvases and cards. Rows are not duplicated here — the worksheets hold them.
struct Meta: Codable {
    struct SheetMeta: Codable {
        var id: UUID
        var name: String
        var columns: [Column]
        var sorts: [SortKey]
        var filter: ValueFilter?
        var pinnedRows: Int
        var pinnedColumns: Int
    }
    var version = 1
    var app = "grid"
    var sheets: [SheetMeta]
    var canvases: [Canvas]
    var generatedSheets: [String]

    static func encode(_ wb: Workbook, generatedSheets: [String]) throws -> Data {
        let meta = Meta(
            sheets: wb.sheets.map { SheetMeta(id: $0.id, name: $0.name, columns: $0.columns, sorts: $0.sorts, filter: $0.filter, pinnedRows: $0.pinnedRows, pinnedColumns: $0.pinnedColumns) },
            canvases: wb.canvases,
            generatedSheets: generatedSheets
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(meta)
    }

    static func decode(_ data: Data) -> Meta? { try? JSONDecoder().decode(Meta.self, from: data) }
}

extension String {
    var data: Data { Data(utf8) }
}
