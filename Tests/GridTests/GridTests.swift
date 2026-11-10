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
