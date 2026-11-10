import XCTest
import ZIPFoundation
@testable import Grid

final class FormulaTests: XCTestCase {
    func testArithmeticAndFunctions() {
        let wb = SampleData.workbook()
        let e = wb.engine()
        XCTAssertEqual(e.evaluate("=1+2*3", in: "Orders"), .number(7))
        XCTAssertEqual(e.evaluate("=(1+2)*3", in: "Orders"), .number(9))
        XCTAssertEqual(e.evaluate("=2^3", in: "Orders"), .number(8))
        XCTAssertEqual(e.evaluate("=-D2", in: "Orders"), .number(-4))
        XCTAssertEqual(e.evaluate("=D2*E2", in: "Orders"), .number(154000))
        XCTAssertEqual(e.evaluate("=SUM(D2:D4)", in: "Orders"), .number(22))
        XCTAssertEqual(e.evaluate("=COUNT(D:D)", in: "Orders"), .number(21))
        XCTAssertEqual(e.evaluate("=IF(D2>3, \"big\", \"small\")", in: "Orders"), .text("big"))
        XCTAssertEqual(e.evaluate("=Orders!D2*2", in: "Pricing"), .number(8))
        XCTAssertEqual(e.evaluate("='Orders'!B2&\"!\"", in: "Pricing"), .text("West!"))
        XCTAssertEqual(e.evaluate("=ROUND(2.567, 2)", in: nil), .number(2.57))
        XCTAssertEqual(e.evaluate("=50%", in: nil), .number(0.5))
    }

    func testErrors() {
        let wb = SampleData.workbook()
        let e = wb.engine()
        XCTAssertEqual(e.evaluate("=1/0", in: nil), .error("#DIV/0!"))
        XCTAssertEqual(e.evaluate("=NOPE(1)", in: nil), .error("#NAME?"))
        XCTAssertEqual(e.evaluate("=(1+", in: nil), .error("#SYNTAX"))
    }

    func testCycleIsDetected() {
        var wb = Workbook.empty
        wb.sheets[0].rows[0][1] = .formula("=C2")
        wb.sheets[0].rows[0][2] = .formula("=B2")
        let rows = wb.evaluatedRows(of: wb.sheets[0])
        XCTAssertEqual(rows[0][1], .text("#CYCLE"))
    }

    func testRevenueFormulaFollowsEdits() {
        var wb = SampleData.workbook()
        wb.sheets[0].rows[0][3] = .number(10)
        let rows = wb.evaluatedRows(of: wb.sheets[0])
        XCTAssertEqual(rows[0][5], .number(385000))
    }
}

final class AnalyticsTests: XCTestCase {
    func testSortAndFilter() {
        var wb = SampleData.workbook()
        wb.sheets[0].sorts = [SortKey(column: 1, ascending: true), SortKey(column: 5, ascending: false)]
        let rows = wb.visibleRows(of: wb.sheets[0])
        XCTAssertEqual(CellFormatter.plainText(rows[0].values[1]), "APAC")
        XCTAssertEqual(rows[0].values[5], .number(32800))   // APAC's largest revenue first
        wb.sheets[0].filter = ValueFilter(column: 7, values: ["Shipped", "Delivered"])
        XCTAssertEqual(wb.visibleRows(of: wb.sheets[0]).count, 11)
    }

    func testPivot() {
        let wb = SampleData.workbook()
        let cfg = PivotConfig(sheetID: wb.sheets[0].id, rowField: "Region", valueField: "Revenue")
        let p = wb.pivot(cfg)!
        XCTAssertEqual(p.rows.count, 7)   // 6 regions + total
        XCTAssertEqual(p.rows.last?.label, "Total")
        XCTAssertEqual(p.rows.first { $0.label == "West" }?.total, 252850)
        XCTAssertEqual(p.format(252850), "$252,850")

        var cross = cfg; cross.columnField = "Status"; cross.aggregation = .count
        let x = wb.pivot(cross)!
        XCTAssertEqual(x.columnHeaders.count, 5)
        XCTAssertEqual(x.rows.last?.total, 21)
    }

    func testChart() {
        let wb = SampleData.workbook()
        var cfg = ChartConfig(sheetID: wb.sheets[0].id, type: .stacked, xField: "Region", yField: "Revenue")
        cfg.seriesField = "Status"
        let c = wb.chart(cfg)!
        XCTAssertEqual(c.bars.count, 6)
        XCTAssertEqual(c.series.count, 5)
        XCTAssertEqual(c.bars.first?.label, "West")   // sorted by value
        XCTAssertEqual(c.maxValue, 252850)
    }

    func testFormatting() {
        XCTAssertEqual(CellFormatter.display(.number(1234.5), column: Column(name: "x", type: .currency, decimals: 1)), "$1,234.5")
        XCTAssertEqual(CellFormatter.display(.number(0.415), column: Column(name: "x", type: .percent, decimals: 1)), "41.5%")
        XCTAssertEqual(CellFormatter.parse("41%", column: Column(name: "x", type: .percent)), .number(0.41))
        XCTAssertEqual(CellFormatter.parse("$1,200", column: Column(name: "x", type: .currency)), .number(1200))
        XCTAssertEqual(CellFormatter.parse("=A1", column: Column(name: "x", type: .text)), .formula("=A1"))
    }
}

final class XLSXTests: XCTestCase {
    func testRoundTrip() throws {
        let wb = SampleData.workbook()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grid-test-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try XLSXWriter.write(wb, to: url)
        let back = try XLSXReader.read(from: url)

        XCTAssertEqual(back.sheets.map { $0.name }, ["Orders", "Inventory", "Pricing"])
        XCTAssertEqual(back.canvases.count, 3)
        XCTAssertEqual(back.sheets[0].columns.map { $0.type }, wb.sheets[0].columns.map { $0.type })
        XCTAssertEqual(back.sheets[0].rows.count, 21)
        XCTAssertEqual(back.sheets[0].rows[0][5], .formula("=D2*E2"))
        XCTAssertEqual(back.sheets[0].rows[0][6], .number(0.41))
        XCTAssertEqual(back.sheets[0].pinnedColumns, 1)
        XCTAssertEqual(back.canvases[0].cards.count, 3)
        if case .pivot(let cfg) = back.canvases[0].cards[1].kind { XCTAssertEqual(cfg.rowField, "Region") } else { XCTFail("pivot card lost") }
        XCTAssertEqual(back.evaluatedRows(of: back.sheets[0])[0][5], .number(154000))
    }

    func testPartsAreWellFormedXML() throws {
        let parts = try XLSXWriter.build(SampleData.workbook())
        for (path, data) in parts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            let parser = XMLParser(data: data)
            XCTAssertTrue(parser.parse(), "\(path) is not well-formed: \(String(describing: parser.parserError))")
        }
        XCTAssertTrue(parts.contains { $0.0 == "xl/grid-meta.json" })
        XCTAssertTrue(parts.contains { $0.0 == "xl/worksheets/sheet4.xml" })   // generated pivot sheet
    }

    func testReadsForeignWorkbookWithoutMeta() throws {
        // Build a workbook, strip the meta part, make sure plain-xlsx inference still yields a sensible sheet.
        let parts = try XLSXWriter.build(SampleData.workbook()).filter { $0.0 != "xl/grid-meta.json" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grid-foreign-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in parts {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate, provider: { p, s in data.subdata(in: Int(p)..<(Int(p) + s)) })
        }
        let back = try XLSXReader.read(from: url)
        let orders = back.sheets[0]
        XCTAssertEqual(orders.columns.map { $0.name }, ["Order", "Region", "Product", "Units", "Unit price", "Revenue", "Margin", "Status", "Notes"])
        XCTAssertEqual(orders.columns[4].type, .currency)
        XCTAssertEqual(orders.columns[6].type, .percent)
        XCTAssertEqual(orders.rows.count, 21)
        XCTAssertEqual(back.canvases.count, 4)   // one per sheet, including the generated pivot sheet
    }
}

final class LayoutTests: XCTestCase {
    /// Grid cards have two header rows (column letters, then row 1 with the column names) above the data.
    func testGridHitTesting() throws {
        let wb = SampleData.workbook()
        let canvas = try XCTUnwrap(wb.canvases.first)
        let layouts = Layout.layouts(canvas: canvas, workbook: wb)
        let l = try XCTUnwrap(layouts.first { $0.card.kind.isGrid })
        let id = l.card.id
        let x1 = l.frame.minX + l.columnX(1) + 5                       // inside column B
        let gutterX = l.frame.minX + Layout.border + 5
        func y(_ row: Int) -> CGFloat { l.frame.minY + l.rowY(row) + Layout.rowHeight / 2 }
        func hit(_ x: CGFloat, _ y: CGFloat) -> Layout.Hit { Layout.hit(CGPoint(x: x, y: y), layouts: [l]) }

        if case .columnHeader(id, 1) = hit(x1, y(-2)) {} else { XCTFail("letters row should hit the column header") }
        if case .columnHeader(id, 1) = hit(x1, y(-1)) {} else { XCTFail("names row should hit the column header") }
        if case .cell(id, row: 0, col: 1) = hit(x1, y(0)) {} else { XCTFail("first data row should hit cell 0") }
        if case .cell(id, row: 3, col: 1) = hit(x1, y(3)) {} else { XCTFail("fourth data row should hit cell 3") }
        if case .rowNumber(id, 0) = hit(gutterX, y(0)) {} else { XCTFail("gutter should hit row number 0") }
        if case .cardBody = hit(gutterX, y(-1)) {} else { XCTFail("gutter beside the names row is not a row number") }
        let last = l.rows.count - 1
        if case .cell(id, row: last, col: 1) = hit(x1, y(last)) {} else { XCTFail("last data row should hit its cell") }
        if case .addRow = hit(l.frame.minX + Layout.border + Layout.gutter + 10, y(last + 1)) {} else { XCTFail("footer left should hit add row") }
        if case .addColumn = hit(l.frame.maxX - 20, y(last + 1)) {} else { XCTFail("footer right should hit add column") }
        XCTAssertEqual(l.frame.height, Layout.cardHeader + Layout.rowHeight * CGFloat(l.rows.count + 2) + Layout.footer + Layout.border * 2)
    }
}

final class DelimitedTests: XCTestCase {
    private let tricky: [[String]] = [
        ["plain", "has,comma", "has\ttab"],
        ["say \"hi\"", "", "two\nlines"],
        ["", "", "last"]
    ]

    func testRoundTripBothDelimiters() {
        for d: Character in ["\t", ","] {
            let text = Delimited.encode(tricky, delimiter: d)
            XCTAssertEqual(Delimited.decode(text, delimiter: d), tricky, "delimiter \(d.unicodeScalars.first!.value)")
        }
    }

    func testQuotingIsPerDelimiter() {
        // A comma is ordinary in TSV and a tab is ordinary in CSV: only the active delimiter is quoted.
        XCTAssertEqual(Delimited.encode([["a,b", "c"]], delimiter: "\t"), "a,b\tc")
        XCTAssertEqual(Delimited.encode([["a,b", "c"]], delimiter: ","), "\"a,b\",c")
        XCTAssertEqual(Delimited.encode([["a\tb", "c"]], delimiter: ","), "a\tb,c")
        XCTAssertEqual(Delimited.encode([["a\tb", "c"]], delimiter: "\t"), "\"a\tb\"\tc")
        XCTAssertEqual(Delimited.encode([["6\" pipe"]], delimiter: ","), "\"6\"\" pipe\"")
    }

    func testLineEndingsAndTrailingNewline() {
        for d in ["\t", ","] {
            let rows = [["a", "b"], ["c", "d"]]
            XCTAssertEqual(Delimited.decode("a\(d)b\r\nc\(d)d\r\n", delimiter: Character(d)), rows)   // Excel
            XCTAssertEqual(Delimited.decode("a\(d)b\nc\(d)d\n", delimiter: Character(d)), rows)
            XCTAssertEqual(Delimited.decode("a\(d)b\rc\(d)d", delimiter: Character(d)), rows)
            XCTAssertEqual(Delimited.decode("a\(d)b\n\nc\(d)d", delimiter: Character(d)), [["a", "b"], [""], ["c", "d"]])
        }
        XCTAssertEqual(Delimited.decode("", delimiter: ","), [])
    }

    func testRaggedAndEmptyFields() {
        XCTAssertEqual(Delimited.decode("a,b,c\nd\ne,", delimiter: ","), [["a", "b", "c"], ["d"], ["e", ""]])
        XCTAssertEqual(Delimited.decode("a\t\tc\n\t\t", delimiter: "\t"), [["a", "", "c"], ["", "", ""]])
        XCTAssertEqual(Delimited.decode("\"\",x", delimiter: ","), [["", "x"]])
        // A quote that does not open the field is literal.
        XCTAssertEqual(Delimited.decode("6\" pipe,x", delimiter: ","), [["6\" pipe", "x"]])
    }

    func testSniffing() {
        XCTAssertEqual(Delimited.sniff("a\tb\nc\td"), [["a", "b"], ["c", "d"]])                    // tab → TSV
        XCTAssertEqual(Delimited.sniff("a,x\tb"), [["a,x", "b"]])                                  // tab wins over comma
        XCTAssertEqual(Delimited.sniff("a,b\nc,d\n"), [["a", "b"], ["c", "d"]])                    // consistent lines → CSV
        XCTAssertEqual(Delimited.sniff("id,note\n1,\"two\nlines\""), [["id", "note"], ["1", "two\nlines"]])
        XCTAssertEqual(Delimited.sniff("Hello, world"), [["Hello, world"]])                        // one line of prose
        XCTAssertEqual(Delimited.sniff("a,b,c\nd,e"), [["a,b,c"], ["d,e"]])                        // uneven → not CSV
        XCTAssertEqual(Delimited.sniff("one\ntwo\nthree"), [["one"], ["two"], ["three"]])          // a copied column
    }
}

final class FormulaShiftTests: XCTestCase {
    func testRelativeAndAbsolute() {
        XCTAssertEqual(Formula.shifted("=D2*E2", dRow: 1, dCol: 0), "=D3*E3")
        XCTAssertEqual(Formula.shifted("=D2*E2", dRow: 0, dCol: 2), "=F2*G2")
        XCTAssertEqual(Formula.shifted("=$D$2+D2", dRow: 3, dCol: 1), "=$D$2+E5")
        XCTAssertEqual(Formula.shifted("=$D2+D$2", dRow: 3, dCol: 1), "=$D5+E$2")
        XCTAssertEqual(Formula.shifted("=d2", dRow: 1, dCol: 1), "=E3")
        XCTAssertEqual(Formula.shifted("=Z1", dRow: 0, dCol: 1), "=AA1")
        XCTAssertEqual(Formula.shifted("=D2*E2", dRow: 0, dCol: 0), "=D2*E2")
    }

    func testRanges() {
        XCTAssertEqual(Formula.shifted("=SUM(D2:D4)", dRow: 2, dCol: 1), "=SUM(E4:E6)")
        XCTAssertEqual(Formula.shifted("=SUM(F:F)", dRow: 5, dCol: 1), "=SUM(G:G)")
        XCTAssertEqual(Formula.shifted("=SUM($F:F)", dRow: 5, dCol: 1), "=SUM($F:G)")
        XCTAssertEqual(Formula.shifted("=SUM(F : F)", dRow: 0, dCol: 1), "=SUM(G : G)")
    }

    func testLeavesNonReferencesAlone() {
        XCTAssertEqual(Formula.shifted("=IF(G2>0.4,\"A1 high\",\"low\")", dRow: 1, dCol: 0), "=IF(G3>0.4,\"A1 high\",\"low\")")
        XCTAssertEqual(Formula.shifted("=Orders!F2", dRow: 1, dCol: 1), "=Orders!G3")
        XCTAssertEqual(Formula.shifted("='Other Sheet'!A1:A9", dRow: 1, dCol: 0), "='Other Sheet'!A2:A10")
        XCTAssertEqual(Formula.shifted("=AND(TRUE,B2>1)", dRow: 1, dCol: 0), "=AND(TRUE,B3>1)")
        XCTAssertEqual(Formula.shifted("=ROUND(B2*1.5, 2)+10", dRow: 1, dCol: 0), "=ROUND(B3*1.5, 2)+10")
    }

    func testOffSheetBecomesRefError() {
        XCTAssertEqual(Formula.shifted("=A2+1", dRow: 0, dCol: -1), "=#REF!+1")
        XCTAssertEqual(Formula.shifted("=B1", dRow: -1, dCol: 0), "=#REF!")
        XCTAssertEqual(Formula.shifted("=B2", dRow: -1, dCol: 0), "=B1")   // row 1 (the names) is a real row
        XCTAssertEqual(SampleData.workbook().engine().evaluate("=#REF!+1", in: "Orders"), .error("#REF!"))
    }
}

final class ClipboardModelTests: XCTestCase {
    private func orders() -> (Workbook, UUID) { let wb = SampleData.workbook(); return (wb, wb.sheets[0].id) }

    func testClipCarriesRawAndEvaluated() throws {
        let (wb, id) = orders()
        let clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...1, cols: 3...5))
        XCTAssertEqual(clip.cells, [[.number(4), .number(38500), .formula("=D2*E2")], [.number(12), .number(1450), .formula("=D3*E3")]])
        XCTAssertEqual(clip.texts, [["4", "38500", "154000"], ["12", "1450", "17400"]])
        XCTAssertEqual(clip.sourceRows, [0, 1])
        XCTAssertEqual(clip.originCol, 3)
        XCTAssertEqual(try JSONDecoder().decode(CellClip.self, from: JSONEncoder().encode(clip)), clip)
    }

    func testClipFollowsDisplayOrder() throws {
        var (wb, id) = orders()
        wb.sheets[0].filter = ValueFilter(column: 1, values: ["West"])
        wb.sheets[0].sorts = [SortKey(column: 3, ascending: false)]
        let clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...1, cols: 0...0))
        XCTAssertEqual(clip.texts, [["OR-1051"], ["OR-1056"]])     // West by units: 9, 6, 4, 3
        XCTAssertEqual(clip.sourceRows, [10, 15])
    }

    func testPasteShiftsFormulasByDistanceMoved() throws {
        var (wb, id) = orders()
        let clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...0, cols: 5...5))   // F2 = D2*E2
        let range = wb.paste(.clip(clip), sheetID: id, displayRow: 4, col: 8)        // → I6
        XCTAssertEqual(range, CellRange(rows: 4...4, cols: 8...8))
        XCTAssertEqual(wb.sheets[0].rows[4][8], .formula("=G6*H6"))
        wb.paste(.clip(clip), sheetID: id, displayRow: 4, col: 5)                    // → F6, same column
        XCTAssertEqual(wb.sheets[0].rows[4][5], .formula("=D6*E6"))
        XCTAssertEqual(wb.evaluatedRows(of: wb.sheets[0])[4][5], .number(32000))
    }

    func testCutPasteKeepsFormulasAsWritten() throws {
        var (wb, id) = orders()
        var clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...0, cols: 5...5))
        clip.isCut = true
        wb.paste(.clip(clip), sheetID: id, displayRow: 4, col: 8)
        XCTAssertEqual(wb.sheets[0].rows[4][8], .formula("=D2*E2"))
    }

    func testPasteUnderSortShiftsBySheetRow() throws {
        var (wb, id) = orders()
        wb.sheets[0].sorts = [SortKey(column: 3, ascending: false)]      // display row 0 is OR-1059 (sheet row 20)
        let clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...0, cols: 5...5))
        XCTAssertEqual(clip.cells, [[.formula("=D20*E20")]])
        wb.paste(.clip(clip), sheetID: id, displayRow: 1, col: 8)        // display row 1 is OR-1053 (sheet row 14)
        XCTAssertEqual(wb.sheets[0].rows[12][8], .formula("=G14*H14"))
    }

    func testTextIsParsedByDestinationColumn() {
        var (wb, id) = orders()
        // Out of a CSV file: the quoted comma must not split the currency field.
        let rows = Delimited.decode("7,\"$1,200\",,45%,Held\n", delimiter: ",")
        wb.paste(.text(rows), sheetID: id, displayRow: 0, col: 3)
        let r = wb.sheets[0].rows[0]
        XCTAssertEqual(r[3], .number(7))
        XCTAssertEqual(r[4], .number(1200))
        XCTAssertEqual(r[5], .empty)                 // an empty field clears the cell
        XCTAssertEqual(r[6], .number(0.45))
        XCTAssertEqual(r[7], .text("Held"))
        wb.paste(.text([["=D2*2"]]), sheetID: id, displayRow: 0, col: 5)
        XCTAssertEqual(wb.sheets[0].rows[0][5], .formula("=D2*2"))
    }

    func testSingleCellFillsSelection() {
        var (wb, id) = orders()
        let range = wb.paste(.text([["Held"]]), sheetID: id, displayRow: 2, col: 7, fillRows: 3, fillCols: 2)
        XCTAssertEqual(range, CellRange(rows: 2...4, cols: 7...8))
        for r in 2...4 { XCTAssertEqual(Array(wb.sheets[0].rows[r][7...8]), [.text("Held"), .text("Held")]) }
        XCTAssertEqual(wb.sheets[0].rows[1][7], .text("Delivered"))
        XCTAssertEqual(wb.sheets[0].rows[5][7], .text("Backorder"))
    }

    func testSingleFormulaFillShiftsPerCell() throws {
        var (wb, id) = orders()
        let clip = try XCTUnwrap(wb.clip(sheetID: id, rows: 0...0, cols: 5...5))
        wb.paste(.clip(clip), sheetID: id, displayRow: 1, col: 8, fillRows: 2, fillCols: 1)
        XCTAssertEqual(wb.sheets[0].rows[1][8], .formula("=G3*H3"))
        XCTAssertEqual(wb.sheets[0].rows[2][8], .formula("=G4*H4"))
    }

    func testOverflowGrowsSheet() {
        var (wb, id) = orders()
        let text = [["x1", "y1", "z1"], ["x2", "y2", "z2"], ["x3", "y3", "z3"]]
        let range = wb.paste(.text(text), sheetID: id, displayRow: 20, col: 7)       // last row, last two columns
        XCTAssertEqual(range, CellRange(rows: 20...22, cols: 7...9))
        let sheet = wb.sheets[0]
        XCTAssertEqual(sheet.rows.count, 23)
        XCTAssertEqual(sheet.columns.count, 10)
        XCTAssertTrue(sheet.rows.allSatisfy { $0.count == 10 })
        XCTAssertEqual(Array(sheet.rows[22][7...9]), [.text("x3"), .text("y3"), .text("z3")])
        XCTAssertEqual(sheet.rows[22][5], .formula("=D24*E24"))                     // new rows get the Revenue template
        XCTAssertEqual(sheet.rows[0][9], .empty)
    }

    func testPasteIntoFilteredViewHitsVisibleRows() {
        var (wb, id) = orders()
        wb.sheets[0].filter = ValueFilter(column: 1, values: ["West"])              // sheet rows 0, 5, 10, 15
        wb.paste(.text([["a"], ["b"], ["c"]]), sheetID: id, displayRow: 1, col: 8)
        let rows = wb.sheets[0].rows
        XCTAssertEqual([rows[5][8], rows[10][8], rows[15][8]], [.text("a"), .text("b"), .text("c")])
        XCTAssertEqual(rows[6][8], .text("Renewal"))                                // hidden row in between is untouched
        XCTAssertEqual(rows[0][8], .text("Expedited freight"))
    }

    func testRaggedTextLeavesMissingCellsAlone() {
        var (wb, id) = orders()
        wb.paste(.text([["a", "b"], ["c"]]), sheetID: id, displayRow: 0, col: 7)
        XCTAssertEqual(wb.sheets[0].rows[1][7], .text("c"))
        XCTAssertEqual(wb.sheets[0].rows[1][8], .empty)
        XCTAssertEqual(wb.sheets[0].rows[0][8], .text("b"))
    }

    func testEmptyContentIsANoOp() {
        var (wb, id) = orders()
        let before = wb
        XCTAssertNil(wb.paste(.text([]), sheetID: id, displayRow: 0, col: 0))
        XCTAssertNil(wb.paste(.text([["x"]]), sheetID: UUID(), displayRow: 0, col: 0))
        XCTAssertEqual(wb, before)
    }
}

/// End to end through `AppState`, on a private pasteboard so the real clipboard is untouched.
@MainActor
final class ClipboardAppStateTests: XCTestCase {
    private var state: AppState!
    private var pb: NSPasteboard!
    private var card: UUID!

    override func setUp() async throws {
        state = AppState()
        state.workbook = SampleData.workbook()
        state.canvasIndex = 0
        state.undoManager.removeAllActions()
        card = try XCTUnwrap(state.gridCard?.id)
        pb = NSPasteboard.withUniqueName()
    }

    override func tearDown() async throws { pb.releaseGlobally() }

    private func select(_ r0: Int, _ c0: Int, _ r1: Int? = nil, _ c1: Int? = nil) {
        state.select(card: card, row: r0, col: c0, extend: false)
        if let r1 = r1, let c1 = c1 { state.select(card: card, row: r1, col: c1, extend: true) }
    }
    private var rows: [[CellValue]] { state.workbook.sheets[0].rows }

    func testCopyWritesCellsTSVAndCSV() throws {
        select(0, 2, 1, 4)     // Product, Units, Unit price
        XCTAssertTrue(state.copySelection(to: pb))
        XCTAssertEqual(pb.string(forType: .string), "Adult patient simulator\t4\t38500\nIV training arm\t12\t1450")
        XCTAssertEqual(pb.string(forType: AppState.csvPasteboardType), "Adult patient simulator,4,38500\nIV training arm,12,1450")
        XCTAssertNotNil(pb.data(forType: AppState.cellsPasteboardType))
        select(15, 2)          // "Service plan, 3 yr" has a comma: quoted in CSV only
        state.copySelection(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "Service plan, 3 yr")
        XCTAssertEqual(pb.string(forType: AppState.csvPasteboardType), "\"Service plan, 3 yr\"")
    }

    func testCopyPasteWithinGrid() {
        select(0, 3, 1, 5)     // D2:F3 with the Revenue formulas
        state.copySelection(to: pb)
        select(10, 3)
        state.paste(from: pb)
        XCTAssertEqual(Array(rows[10][3...5]), [.number(4), .number(38500), .formula("=D12*E12")])
        XCTAssertEqual(Array(rows[11][3...5]), [.number(12), .number(1450), .formula("=D13*E13")])
        XCTAssertEqual(state.selection, Selection(cardID: card, anchor: CellRef(row: 10, col: 3), focus: CellRef(row: 11, col: 5)))
        XCTAssertTrue(state.dirty)
    }

    func testTSVAndCSVRepresentationsPasteIdentically() throws {
        select(0, 0, 20, 8)
        state.copySelection(to: pb)
        let tsv = try XCTUnwrap(pb.string(forType: .string)), csv = try XCTUnwrap(pb.string(forType: AppState.csvPasteboardType))
        XCTAssertNotEqual(tsv, csv)
        let expected = state.workbook.evaluatedRows(of: state.workbook.sheets[0])

        // As another app would offer them: plain text only (sniffed), then the CSV type only.
        for (text, type) in [(tsv, NSPasteboard.PasteboardType.string), (csv, .string), (csv, AppState.csvPasteboardType)] {
            state.workbook = SampleData.workbook()
            card = try XCTUnwrap(state.gridCard?.id)
            select(0, 0, 20, 8)
            state.clearSelection()
            XCTAssertEqual(rows[0][0], .empty)
            pb.clearContents()
            pb.setString(text, forType: type)
            select(0, 0)
            state.paste(from: pb)
            XCTAssertEqual(rows, expected)   // values, not formulas: text carries what was displayed
        }
    }

    func testSingleLineWithCommaStaysOneCell() {
        pb.clearContents()
        pb.setString("Hold, pending review", forType: .string)
        select(0, 8)
        state.paste(from: pb)
        XCTAssertEqual(rows[0][8], .text("Hold, pending review"))
        XCTAssertEqual(state.workbook.sheets[0].columns.count, 9)
    }

    func testCutThenPasteMoves() {
        let original = state.workbook
        select(0, 3, 0, 5)
        state.cutSelection(to: pb)
        XCTAssertEqual(Array(rows[0][3...5]), [.empty, .empty, .empty])
        XCTAssertEqual(state.undoManager.undoActionName, "Cut")
        RunLoop.current.run(until: Date())   // end the event, as the app does between keystrokes: closes the undo group
        select(4, 3)
        state.paste(from: pb)
        XCTAssertEqual(Array(rows[4][3...5]), [.number(4), .number(38500), .formula("=D2*E2")])
        state.undoManager.undo()
        XCTAssertEqual(Array(rows[4][3...5]), [.number(10), .number(3200), .formula("=D6*E6")])
        XCTAssertEqual(Array(rows[0][3...5]), [.empty, .empty, .empty])
        state.undoManager.undo()
        XCTAssertEqual(state.workbook, original)
    }

    func testPasteIsOneUndoStep() {
        let before = state.workbook
        pb.clearContents()
        pb.setString("a\tb\nc\td\ne\tf", forType: .string)
        select(20, 8)                       // runs two rows and one column past the edge
        state.paste(from: pb)
        let after = state.workbook
        XCTAssertEqual(after.sheets[0].rows.count, 23)
        XCTAssertEqual(after.sheets[0].columns.count, 10)
        XCTAssertEqual(state.undoManager.undoActionName, "Paste")
        state.undoManager.undo()
        XCTAssertEqual(state.workbook, before)
        XCTAssertNotNil(state.selection)    // clamped back inside the smaller sheet
        state.undoManager.redo()
        XCTAssertEqual(state.workbook, after)
    }

    func testNothingToPasteOrNowhereToPutIt() {
        let before = state.workbook
        pb.clearContents()
        select(0, 0)
        XCTAssertFalse(state.canPaste(from: pb))
        state.paste(from: pb)
        pb.setString("x", forType: .string)
        XCTAssertTrue(state.canPaste(from: pb))
        state.selection = nil
        XCTAssertFalse(state.canCopy)
        XCTAssertFalse(state.canPaste(from: pb))
        XCTAssertFalse(state.copySelection(to: pb))
        state.paste(from: pb)
        state.cutSelection(to: pb)
        XCTAssertEqual(state.workbook, before)
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertEqual(pb.string(forType: .string), "x")   // a failed copy leaves the pasteboard alone
    }
}

final class StructureFormulaTests: XCTestCase {
    private func rows(_ f: String, _ rows: Set<Int>, own: Bool = true) -> String {
        Formula.adjusted(f, for: .deleteRows(rows), sheetName: "Orders", inEditedSheet: own)
    }
    private func cols(_ f: String, _ cols: Set<Int>, own: Bool = true) -> String {
        Formula.adjusted(f, for: .deleteColumns(cols), sheetName: "Orders", inEditedSheet: own)
    }

    func testRowDeleteShiftsAndBreaksReferences() {
        XCTAssertEqual(rows("=D2*E9", [5]), "=D2*E8")
        XCTAssertEqual(rows("=D5+1", [5]), "=#REF!+1")
        XCTAssertEqual(rows("=$D$9", [3, 4]), "=$D$7")           // anchors follow the cell too
        XCTAssertEqual(rows("=D1&D2", [2]), "=D1&#REF!")         // the header row never moves
    }

    func testRowDeleteShrinksRanges() {
        XCTAssertEqual(rows("=SUM(D2:D10)", [5, 6]), "=SUM(D2:D8)")
        XCTAssertEqual(rows("=SUM(D2:D4)", [2]), "=SUM(D2:D3)")
        XCTAssertEqual(rows("=SUM(D4:D2)", [4]), "=SUM(D3:D2)")
        XCTAssertEqual(rows("=SUM(D5:D6)", [5, 6]), "=SUM(#REF!)")
        XCTAssertEqual(rows("=COUNT(D:D)", [5]), "=COUNT(D:D)")
    }

    func testColumnDeleteShiftsAndBreaksReferences() {
        XCTAssertEqual(cols("=D2*E2", [1]), "=C2*D2")
        XCTAssertEqual(cols("=D2*E2", [3]), "=#REF!*D2")
        XCTAssertEqual(cols("=SUM(B2:F2)", [1, 3]), "=SUM(B2:D2)")
        XCTAssertEqual(cols("=COUNT(D:D)", [3]), "=COUNT(#REF!)")
        XCTAssertEqual(cols("=SUM(A:C)", [1]), "=SUM(A:B)")
    }

    func testOnlyReferencesToTheEditedSheetMove() {
        XCTAssertEqual(rows("=Orders!D9+D9", [5], own: false), "=Orders!D8+D9")
        XCTAssertEqual(rows("='orders'!D9+Pricing!D9", [5]), "='orders'!D8+Pricing!D9")
        XCTAssertEqual(rows("=SUM(Pricing!B2:B9)+D9", [5]), "=SUM(Pricing!B2:B9)+D8")
    }

    func testLeavesNonReferencesAlone() {
        XCTAssertEqual(rows("=IF(D9>3, \"D9\", LOG10(2))", [5]), "=IF(D8>3, \"D9\", LOG10(2))")
        XCTAssertEqual(rows("=#REF!+D9", [5]), "=#REF!+D8")
        XCTAssertEqual(rows("=1.5*D9", [5]), "=1.5*D8")
    }
}

final class StructureWorkbookTests: XCTestCase {
    private func orders() -> (Workbook, UUID) { let wb = SampleData.workbook(); return (wb, wb.sheets[0].id) }

    func testDeleteRowsClosesGapAndKeepsFormulasOnTheirData() {
        var (wb, id) = orders()
        let before = wb.evaluatedRows(of: wb.sheets[0])
        XCTAssertEqual(wb.deleteRows(sheetID: id, sourceRows: [1, 2]), 2)
        XCTAssertEqual(wb.sheets[0].rows.count, before.count - 2)
        XCTAssertEqual(wb.sheets[0].rows[1][0], .text("OR-1044"))
        XCTAssertEqual(wb.sheets[0].rows[1][5], .formula("=D3*E3"))                // was =D5*E5
        XCTAssertEqual(wb.evaluatedRows(of: wb.sheets[0]), [before[0]] + before[3...])
        XCTAssertEqual(wb.sheets[0].columns[5].formulaTemplate, "=D{row}*E{row}")
        XCTAssertEqual(wb.deleteRows(sheetID: id, sourceRows: [999]), 0)
    }

    func testDeleteRowsRewritesOtherSheets() {
        var (wb, id) = orders()
        wb.sheets[1].rows[0][0] = .formula("=Orders!D5+SUM(Orders!D2:D4)")
        wb.deleteRows(sheetID: id, sourceRows: [1])
        XCTAssertEqual(wb.sheets[1].rows[0][0], .formula("=Orders!D4+SUM(Orders!D2:D3)"))
    }

    func testDeleteColumnsFixesSortFilterPinsAndTemplates() throws {
        var (wb, id) = orders()
        wb.sheets[0].sorts = [SortKey(column: 1, ascending: true), SortKey(column: 6, ascending: false)]
        wb.sheets[0].filter = ValueFilter(column: 7, values: ["Shipped"])
        wb.sheets[0].pinnedColumns = 3
        let revenue = wb.evaluatedRows(of: wb.sheets[0]).map { $0[5] }
        let result = try XCTUnwrap(wb.deleteColumns(sheetID: id, columns: [1, 2]))   // Region, Product
        XCTAssertEqual(result.names, ["Region", "Product"])
        XCTAssertEqual(wb.sheets[0].columns.map { $0.name }, ["Order", "Units", "Unit price", "Revenue", "Margin", "Status", "Notes"])
        XCTAssertTrue(wb.sheets[0].rows.allSatisfy { $0.count == 7 })
        XCTAssertEqual(wb.sheets[0].sorts, [SortKey(column: 4, ascending: false)])
        XCTAssertEqual(wb.sheets[0].filter, ValueFilter(column: 5, values: ["Shipped"]))
        XCTAssertEqual(wb.sheets[0].pinnedColumns, 1)
        XCTAssertEqual(wb.sheets[0].rows[0][3], .formula("=B2*C2"))
        XCTAssertEqual(wb.sheets[0].columns[3].formulaTemplate, "=B{row}*C{row}")
        XCTAssertEqual(wb.evaluatedRows(of: wb.sheets[0]).map { $0[3] }, revenue)
    }

    func testDeleteColumnsRefusesToEmptyTheSheet() {
        var (wb, id) = orders()
        let before = wb
        XCTAssertNil(wb.deleteColumns(sheetID: id, columns: Set(0..<9)))
        XCTAssertNil(wb.deleteColumns(sheetID: id, columns: []))
        XCTAssertEqual(wb, before)
    }

    func testDeleteColumnsTakesDependentViewsAndTrimsOptionalFields() throws {
        var (wb, id) = orders()
        let keep = Card(kind: .pivot(PivotConfig(sheetID: id, rowField: "Status", columnField: "Region", valueField: "Revenue")), origin: .zero)
        let lose = Card(kind: .pivot(PivotConfig(sheetID: id, rowField: "Region", valueField: "Revenue")), origin: .zero)
        let chart = Card(kind: .chart(ChartConfig(sheetID: id, type: .stacked, xField: "Status", yField: "Revenue", seriesField: "Region")), origin: .zero)
        wb.canvases[0].cards = [try XCTUnwrap(wb.canvases[0].gridCard), keep, lose, chart]
        let result = try XCTUnwrap(wb.deleteColumns(sheetID: id, columns: [1]))
        XCTAssertEqual(result.removedViews, 1)
        XCTAssertEqual(wb.canvases[0].cards.map { $0.id }, [wb.canvases[0].cards[0].id, keep.id, chart.id])
        guard case .pivot(let p) = wb.canvases[0].cards[1].kind, case .chart(let c) = wb.canvases[0].cards[2].kind else { return XCTFail() }
        XCTAssertNil(p.columnField)
        XCTAssertNil(c.seriesField)
        XCTAssertEqual(c.type, .column)
        XCTAssertNotNil(wb.pivot(p))
        XCTAssertNotNil(wb.chart(c))
    }
}

final class FullscreenLayoutTests: XCTestCase {
    func testFullscreenLaysOutOnlyThatViewAtTheGivenFrame() throws {
        let wb = SampleData.workbook()
        let canvas = try XCTUnwrap(wb.canvases.first)
        let view = try XCTUnwrap(canvas.cards.first { !$0.kind.isGrid })
        let frame = Layout.fullscreenFrame(viewport: CGSize(width: 1200, height: 700), panelOpen: false)
        XCTAssertEqual(frame, CGRect(x: 12, y: 12, width: 1176, height: 676))
        XCTAssertEqual(Layout.fullscreenFrame(viewport: CGSize(width: 1200, height: 700), panelOpen: true).width, 836)
        let layouts = Layout.layouts(canvas: canvas, workbook: wb, fullscreen: (view.id, frame))
        XCTAssertEqual(layouts.map { $0.card.id }, [view.id])
        XCTAssertEqual(layouts[0].frame, frame)
        // The grid can't go full screen: asking for it lays out nothing rather than everything.
        let grid = try XCTUnwrap(canvas.gridCard)
        XCTAssertTrue(Layout.layouts(canvas: canvas, workbook: wb, fullscreen: (grid.id, frame)).isEmpty)
    }

    func testViewHeaderButtons() throws {
        let wb = SampleData.workbook()
        let canvas = try XCTUnwrap(wb.canvases.first)
        let l = try XCTUnwrap(Layout.layouts(canvas: canvas, workbook: wb).first { !$0.card.kind.isGrid })
        let y = l.frame.minY + 10, id = l.card.id
        func hit(_ fromRight: CGFloat) -> Layout.Hit { Layout.hit(CGPoint(x: l.frame.maxX - fromRight, y: y), layouts: [l]) }
        if case .removeView(id) = hit(15) {} else { XCTFail("far right is remove") }
        if case .toggleFullscreen(id) = hit(43) {} else { XCTFail("left of remove is full screen") }
        if case .cardHeader(id) = hit(80) {} else { XCTFail("the rest of the header drags the card") }
    }

    func testPivotMetrics() throws {
        let wb = SampleData.workbook()
        let cfg = PivotConfig(sheetID: wb.sheets[0].id, rowField: "Region", columnField: "Status", valueField: "Revenue")
        let p = try XCTUnwrap(wb.pivot(cfg))
        let natural = Layout.pivotSize(p, totals: true)
        let m = Layout.pivotMetrics(p, totals: true, frame: natural)
        XCTAssertEqual(m, Layout.PivotMetrics(labelWidth: Layout.pivotLabelWidth, valueWidth: Layout.pivotValueWidth, totalWidth: Layout.pivotTotalWidth, rowHeight: Layout.rowHeight, fontSize: 12, maxScroll: 0))
        // A big frame: columns fill the width, rows and text stop growing at 1.5×.
        let big = Layout.pivotMetrics(p, totals: true, frame: CGSize(width: natural.width * 3, height: natural.height * 3))
        XCTAssertEqual(big.rowHeight, 36)
        XCTAssertEqual(big.fontSize, 18)
        let cols = CGFloat(p.columnHeaders.count)
        XCTAssertEqual(big.labelWidth + big.valueWidth * cols + big.totalWidth, natural.width * 3 - Layout.border * 2 - 2, accuracy: 0.01)
        // Too short for the rows: natural row height, and the rest scrolls.
        let short = Layout.pivotMetrics(p, totals: true, frame: CGSize(width: natural.width, height: natural.height - 60))
        XCTAssertEqual(short.rowHeight, Layout.rowHeight)
        XCTAssertEqual(short.maxScroll, 60, accuracy: 0.01)
    }

    func testChartScale() {
        XCTAssertEqual(Layout.chartScale(frame: Layout.chartSize), 1)
        XCTAssertEqual(Layout.chartScale(frame: CGSize(width: 900, height: 300)), 1)
        XCTAssertEqual(Layout.chartScale(frame: CGSize(width: 660, height: 600)), 1.5)
        XCTAssertEqual(Layout.chartScale(frame: CGSize(width: 4000, height: 3000)), 2)
    }
}

/// Whole-row and whole-column selection, delete and full screen through `AppState`.
@MainActor
final class StructureAppStateTests: XCTestCase {
    private var state: AppState!
    private var card: UUID!

    override func setUp() async throws {
        state = AppState()
        state.workbook = SampleData.workbook()
        state.canvasIndex = 0
        state.undoManager.removeAllActions()
        card = try XCTUnwrap(state.gridCard?.id)
    }

    private var sheet: Sheet { state.workbook.sheets[0] }

    func testRowSelectionSpansTheSheetAndExtends() {
        state.selectRows(card: card, row: 2, extend: false)
        state.selectRows(card: card, row: 4, extend: true)
        XCTAssertEqual(state.selection, Selection(cardID: card, anchor: CellRef(row: 2, col: 0), focus: CellRef(row: 4, col: 8), span: .rows))
        state.moveSelection(dRow: 1, dCol: -3, extend: true)          // grows by rows only
        XCTAssertEqual(state.selection?.focus, CellRef(row: 5, col: 8))
        state.appendColumn()
        XCTAssertEqual(state.selection?.focus.col, 9)                 // still edge to edge
        state.moveSelection(dRow: 0, dCol: 1, extend: false)
        XCTAssertEqual(state.selection?.span, .cells)
        XCTAssertFalse(state.deleteSelection())                       // plain cells: ⌘⌫ deletes nothing
    }

    func testDeleteRowsUnderSortAndFilterRemovesWhatIsShown() {
        state.workbook.sheets[0].filter = ValueFilter(column: 1, values: ["West"])
        state.workbook.sheets[0].sorts = [SortKey(column: 3, ascending: false)]   // West by units: OR-1051, 1056, 1041, 1046
        let before = state.workbook
        state.selectRows(card: card, row: 0, extend: false)
        state.selectRows(card: card, row: 1, extend: true)
        XCTAssertTrue(state.canDeleteRows)
        XCTAssertTrue(state.deleteSelection())
        XCTAssertEqual(sheet.rows.count, 19)
        XCTAssertFalse(sheet.rows.contains { $0[0] == .text("OR-1051") || $0[0] == .text("OR-1056") })
        XCTAssertEqual(state.workbook.visibleRows(of: sheet).map { CellFormatter.plainText($0.values[0]) }, ["OR-1041", "OR-1046"])
        XCTAssertEqual(state.selection, Selection(cardID: card, anchor: CellRef(row: 0, col: 0), focus: CellRef(row: 0, col: 8), span: .rows))
        XCTAssertEqual(state.undoManager.undoActionName, "Delete Rows")
        state.undoManager.undo()
        XCTAssertEqual(state.workbook, before)
    }

    func testDeleteColumnsThroughTheMenu() {
        let before = state.workbook
        let views = state.canvas.cards.count
        state.openColumnMenu(cardID: card, column: 8, anchor: .zero)                  // Notes: nothing depends on it
        XCTAssertEqual(state.selection?.span, .columns)
        state.openColumnMenu(cardID: card, column: 7, anchor: .zero, extend: true)
        XCTAssertEqual(state.selection.map { [$0.minCol, $0.maxCol] }, [7, 8])
        XCTAssertNotNil(state.columnMenu)
        state.deleteSelectedColumns()
        XCTAssertNil(state.columnMenu)
        XCTAssertEqual(sheet.columns.count, 7)
        XCTAssertLessThanOrEqual(state.canvas.cards.count, views)
        XCTAssertEqual(state.selection?.span, .columns)
        XCTAssertEqual(state.selection?.minCol, 6)                                    // clamped onto the new last column
        state.undoManager.undo()
        XCTAssertEqual(state.workbook, before)
    }

    func testLastColumnCannotBeDeleted() {
        let before = state.workbook
        state.selectColumns(card: card, column: 0, extend: false)
        state.selectColumns(card: card, column: 8, extend: true)
        XCTAssertFalse(state.canDeleteColumns)
        state.deleteSelectedColumns()
        XCTAssertEqual(state.workbook, before)
    }

    func testRowMenuTogglesAndFollowsSelection() {
        state.openRowMenu(cardID: card, row: 3, anchor: .zero)
        XCTAssertEqual(state.rowMenu?.row, 3)
        XCTAssertEqual(state.selection?.span, .rows)
        state.openColumnMenu(cardID: card, column: 1, anchor: .zero, showFilter: true)
        XCTAssertNil(state.rowMenu)
        XCTAssertEqual(state.columnMenu?.showFilter, true)
        state.openRowMenu(cardID: card, row: 3, anchor: .zero)
        state.openRowMenu(cardID: card, row: 3, anchor: .zero)
        XCTAssertNil(state.rowMenu)
        XCTAssertNil(state.columnMenu)
    }

    func testFullscreenIsOnlyForViewsAndEndsWithTheCard() throws {
        let view = try XCTUnwrap(state.canvas.cards.first { !$0.kind.isGrid })
        state.toggleFullscreen(card)
        XCTAssertNil(state.fullscreenCard)
        state.select(card: card, row: 0, col: 0, extend: false)
        state.toggleFullscreen(view.id)
        XCTAssertEqual(state.fullscreenCard?.id, view.id)
        XCTAssertFalse(state.canCopy)                                 // the hidden grid is not edited blind
        state.toggleFullscreen(view.id)
        XCTAssertNil(state.fullscreenCard)
        state.toggleFullscreen(view.id)
        state.removeCard(view.id)
        XCTAssertNil(state.fullscreenCardID)
    }

    func testStepCanvasWraps() {
        let n = state.workbook.canvases.count
        XCTAssertGreaterThan(n, 1)
        state.stepCanvas(-1)
        XCTAssertEqual(state.canvasIndex, n - 1)
        state.stepCanvas(1)
        XCTAssertEqual(state.canvasIndex, 0)
    }
}

final class TitleBarTests: XCTestCase {
    func testDoubleClickFollowsTheSystemSetting() throws {
        let name = "grid.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set("Minimize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBarDragArea.doubleClickAction(defaults: d), .minimize)
        d.set("None", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBarDragArea.doubleClickAction(defaults: d), .none)
        d.set("Maximize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBarDragArea.doubleClickAction(defaults: d), .zoom)
    }
}

final class InsertTests: XCTestCase {
    private func orders() -> (Workbook, UUID) { let wb = SampleData.workbook(); return (wb, wb.sheets[0].id) }
    private func adjust(_ f: String, _ edit: StructuralEdit) -> String {
        Formula.adjusted(f, for: edit, sheetName: "Orders", inEditedSheet: true)
    }

    func testInsertShiftsReferencesAndGrowsSpanningRanges() {
        XCTAssertEqual(adjust("=D2*E9+$D$5", .insertRows(before: 5, count: 1)), "=D2*E10+$D$6")
        XCTAssertEqual(adjust("=SUM(D2:D10)", .insertRows(before: 5, count: 2)), "=SUM(D2:D12)")
        XCTAssertEqual(adjust("=SUM(D2:D4)", .insertRows(before: 5, count: 1)), "=SUM(D2:D4)")     // just past the end: not taken in
        XCTAssertEqual(adjust("=SUM(D2:D4)", .insertRows(before: 2, count: 1)), "=SUM(D3:D5)")
        XCTAssertEqual(adjust("=COUNT(D:D)+D1", .insertRows(before: 2, count: 1)), "=COUNT(D:D)+D1")
        XCTAssertEqual(adjust("=D2*E2", .insertColumns(before: 4, count: 1)), "=D2*F2")
        XCTAssertEqual(adjust("=SUM(B2:F2)+COUNT(D:D)", .insertColumns(before: 3, count: 2)), "=SUM(B2:H2)+COUNT(F:F)")
    }

    func testInsertRowKeepsEveryFormulaOnItsData() {
        var (wb, id) = orders()
        wb.sheets[1].rows[0][0] = .formula("=Orders!D5+SUM(Orders!D2:D4)")
        let before = wb.evaluatedRows(of: wb.sheets[0])
        XCTAssertTrue(wb.insertRows(sheetID: id, at: 2))
        XCTAssertEqual(wb.sheets[0].rows.count, before.count + 1)
        XCTAssertEqual(wb.sheets[0].rows[2][0], .empty)
        XCTAssertEqual(wb.sheets[0].rows[2][5], .formula("=D4*E4"))                  // from the column template
        XCTAssertEqual(wb.sheets[0].rows[3][5], .formula("=D5*E5"))                  // was =D4*E4
        let after = wb.evaluatedRows(of: wb.sheets[0])
        XCTAssertEqual(Array(after[..<2]) + Array(after[3...]), before)
        XCTAssertEqual(wb.sheets[1].rows[0][0], .formula("=Orders!D6+SUM(Orders!D2:D5)"))
        XCTAssertTrue(wb.insertRows(sheetID: id, at: wb.sheets[0].rows.count))        // at the end, like append
        XCTAssertFalse(wb.insertRows(sheetID: id, at: 999))
    }

    func testInsertColumnKeepsSortFilterPinsViewsAndFormulas() throws {
        var (wb, id) = orders()
        wb.sheets[0].sorts = [SortKey(column: 1, ascending: true), SortKey(column: 6, ascending: false)]
        wb.sheets[0].filter = ValueFilter(column: 7, values: ["Shipped"])
        wb.sheets[0].pinnedColumns = 3
        let revenue = wb.evaluatedRows(of: wb.sheets[0]).map { $0[5] }
        let cards = wb.canvases[0].cards
        XCTAssertEqual(wb.insertColumns(sheetID: id, at: 2), ["Col C"])
        XCTAssertEqual(wb.sheets[0].columns.map { $0.name }, ["Order", "Region", "Col C", "Product", "Units", "Unit price", "Revenue", "Margin", "Status", "Notes"])
        XCTAssertTrue(wb.sheets[0].rows.allSatisfy { $0.count == 10 && $0[2] == .empty })
        XCTAssertEqual(wb.sheets[0].sorts, [SortKey(column: 1, ascending: true), SortKey(column: 7, ascending: false)])
        XCTAssertEqual(wb.sheets[0].filter, ValueFilter(column: 8, values: ["Shipped"]))
        XCTAssertEqual(wb.sheets[0].pinnedColumns, 4)
        XCTAssertEqual(wb.sheets[0].rows[0][6], .formula("=E2*F2"))
        XCTAssertEqual(wb.sheets[0].columns[6].formulaTemplate, "=E{row}*F{row}")
        XCTAssertEqual(wb.evaluatedRows(of: wb.sheets[0]).map { $0[6] }, revenue)
        XCTAssertEqual(wb.canvases[0].cards, cards)
        XCTAssertEqual(wb.insertColumns(sheetID: id, at: 2), ["Col C 2"])            // names stay unique for views
        XCTAssertEqual(wb.insertColumns(sheetID: id, at: 11), ["Col L"])             // at the end, like append
        XCTAssertNil(wb.insertColumns(sheetID: id, at: 99))
    }
}

@MainActor
final class InsertAppStateTests: XCTestCase {
    private var state: AppState!
    private var card: UUID!

    override func setUp() async throws {
        state = AppState()
        state.workbook = SampleData.workbook()
        state.canvasIndex = 0
        state.undoManager.removeAllActions()
        card = try XCTUnwrap(state.gridCard?.id)
    }

    private var sheet: Sheet { state.workbook.sheets[0] }

    func testInsertRowAboveAndBelowTheSelection() {
        let before = state.workbook
        state.select(card: card, row: 2, col: 0, extend: false)
        XCTAssertFalse(state.canInsertRows)                                     // whole rows only
        state.insertRow(below: false)
        XCTAssertEqual(state.workbook, before)
        state.selectRows(card: card, row: 2, extend: false)
        state.selectRows(card: card, row: 3, extend: true)
        state.insertRow(below: true)
        XCTAssertEqual(sheet.rows.count, 22)
        XCTAssertEqual(sheet.rows[4][0], .empty)
        XCTAssertEqual(sheet.rows[3][0], .text("OR-1044"))
        XCTAssertEqual(state.selection, Selection(cardID: card, anchor: CellRef(row: 4, col: 0), focus: CellRef(row: 4, col: 8), span: .rows))
        state.insertRow(below: false)
        XCTAssertEqual(sheet.rows[4][0], .empty)
        XCTAssertEqual(sheet.rows[5][0], .empty)
        XCTAssertEqual(sheet.rows[6][0], .text("OR-1045"))
        XCTAssertEqual(state.undoManager.undoActionName, "Insert Row")
        state.undoManager.undo(); state.undoManager.undo()
        XCTAssertEqual(state.workbook, before)
    }

    func testInsertRowUnderSortGoesNextToTheRowInTheSheet() {
        state.workbook.sheets[0].sorts = [SortKey(column: 3, ascending: false)]   // display row 0 is OR-1059, sheet row 18
        state.selectRows(card: card, row: 0, extend: false)
        state.insertRow(below: false)
        XCTAssertEqual(sheet.rows[18][0], .empty)
        XCTAssertEqual(sheet.rows[19][0], .text("OR-1059"))
        // The empty row sorts to the bottom, and the selection follows it there.
        XCTAssertEqual(state.selection?.minRow, 21)
        XCTAssertEqual(state.selection?.span, .rows)
    }

    func testInsertColumnLeftAndRight() {
        let before = state.workbook
        state.selectColumns(card: card, column: 3, extend: false)
        state.selectColumns(card: card, column: 4, extend: true)
        state.insertColumn(right: true)
        XCTAssertEqual(sheet.columns.map { $0.name }[3...6], ["Units", "Unit price", "Col F", "Revenue"])
        XCTAssertEqual(state.selection.map { [$0.minCol, $0.maxCol] }, [5, 5])
        XCTAssertEqual(state.selection?.span, .columns)
        state.insertColumn(right: false)
        XCTAssertEqual(sheet.columns.map { $0.name }[5...6], ["Col F 2", "Col F"])
        XCTAssertEqual(sheet.rows[0][7], .formula("=D2*E2"))                   // Revenue moved right; its inputs did not
        state.undoManager.undo(); state.undoManager.undo()
        XCTAssertEqual(state.workbook, before)
    }
}
