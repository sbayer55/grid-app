import Foundation
import CoreGraphics

/// Geometry shared by the renderer and hit-testing. All values are in world (canvas) units.
enum Layout {
    static let cardHeader: CGFloat = 28
    static let rowHeight: CGFloat = 24
    static let headerRows = 2              // column letters, then row 1 (column names)
    static let gutter: CGFloat = 40        // row-number column
    static let footer: CGFloat = 24        // "+ row · + column" strip
    static let border: CGFloat = 1.5
    static let cardRadius: CGFloat = 12
    static let pivotLabelWidth: CGFloat = 110
    static let pivotValueWidth: CGFloat = 88
    static let pivotTotalWidth: CGFloat = 96
    static let chartSize = CGSize(width: 440, height: 300)
    /// Right end of a view card's header: the full screen button, then the 30pt remove zone.
    static let headerButtonsWidth: CGFloat = 56

    static func gridSize(sheet: Sheet, workbook: Workbook) -> CGSize {
        let w = gutter + sheet.columns.reduce(0) { $0 + $1.width } + border * 2
        let rows = workbook.visibleRows(of: sheet).count
        let h = cardHeader + rowHeight * CGFloat(rows + headerRows) + footer + border * 2
        return CGSize(width: w, height: h)
    }

    static func pivotSize(_ result: PivotResult, totals: Bool) -> CGSize {
        let w = pivotLabelWidth + pivotValueWidth * CGFloat(result.columnHeaders.count) + (totals && result.columnHeaders.count > 1 ? pivotTotalWidth : 0) + border * 2 + 2
        let h = cardHeader + rowHeight * CGFloat(result.rows.count + 1) + border * 2
        return CGSize(width: w, height: h)
    }

    /// Pivot geometry for a frame. At the natural `pivotSize` it is exactly the constants above;
    /// in a larger (full screen) frame the columns stretch to the width and rows and text grow
    /// up to 1.5×. A frame too short for the rows keeps natural row height and scrolls.
    struct PivotMetrics: Equatable {
        var labelWidth: CGFloat, valueWidth: CGFloat, totalWidth: CGFloat
        var rowHeight: CGFloat, fontSize: CGFloat
        /// How far the rows can scroll up under the column header.
        var maxScroll: CGFloat
    }

    static func pivotMetrics(_ result: PivotResult, totals: Bool, frame: CGSize) -> PivotMetrics {
        let natural = pivotSize(result, totals: totals)
        let chromeW = border * 2 + 2, chromeH = border * 2 + cardHeader
        let k = max(1, min(1.5, frame.width / natural.width, (frame.height - chromeH) / (natural.height - chromeH)))
        let sx = max(0.5, (frame.width - chromeW) / (natural.width - chromeW))
        let rowH = (rowHeight * k).rounded()
        let rowsHeight = rowH * CGFloat(result.rows.count + 1)
        return PivotMetrics(labelWidth: pivotLabelWidth * sx, valueWidth: pivotValueWidth * sx, totalWidth: pivotTotalWidth * sx,
                            rowHeight: rowH, fontSize: 12 * k, maxScroll: max(0, rowsHeight - (frame.height - chromeH)))
    }

    /// How much the chart's fixed sizes (bar thickness, label column, text) grow in a frame
    /// larger than the natural card. 1 on the canvas.
    static func chartScale(frame: CGSize) -> CGFloat {
        max(1, min(2, frame.width / chartSize.width, frame.height / chartSize.height))
    }

    static func chartSize(_ result: ChartResult, type: ChartType) -> CGSize {
        if type == .bar { return chartSize }
        return CGSize(width: max(chartSize.width, CGFloat(result.bars.count) * 60 + 40), height: chartSize.height)
    }

    /// Resolved frame + computed content for one card.
    struct CardLayout {
        var card: Card
        var frame: CGRect
        var sheet: Sheet?
        var rows: [VisibleRow] = []
        var pivot: PivotResult?
        var chart: ChartResult?

        /// x offset (from card origin) of the left edge of column `c` in a grid card.
        func columnX(_ c: Int) -> CGFloat {
            guard let s = sheet else { return 0 }
            return Layout.border + Layout.gutter + s.columns.prefix(c).reduce(0) { $0 + $1.width }
        }
        /// y offset of display row `r` (0 = first data row; -1 = column names, -2 = column letters).
        func rowY(_ r: Int) -> CGFloat { Layout.border + Layout.cardHeader + Layout.rowHeight * CGFloat(r + Layout.headerRows) }
    }

    /// Where a full screen view sits in the viewport: inset from the edges, and clear of the
    /// config panel when that is open.
    static func fullscreenFrame(viewport: CGSize, panelOpen: Bool) -> CGRect {
        let margin: CGFloat = 12
        let panel: CGFloat = panelOpen ? 340 : 0
        return CGRect(x: margin, y: margin, width: max(240, viewport.width - margin * 2 - panel), height: max(160, viewport.height - margin * 2))
    }

    /// With `fullscreen`, only that view is laid out, at the given frame (viewport units; the
    /// canvas draws it unpanned and unzoomed).
    static func layouts(canvas: Canvas, workbook: Workbook, fullscreen: (id: UUID, frame: CGRect)? = nil) -> [CardLayout] {
        let cards = fullscreen.map { fs in canvas.cards.filter { $0.id == fs.id && !$0.kind.isGrid } } ?? canvas.cards
        return cards.compactMap { card in
            let size: (CGSize) -> CGSize = { natural in fullscreen?.frame.size ?? natural }
            let origin = fullscreen?.frame.origin ?? card.origin
            switch card.kind {
            case .grid(let id):
                guard let sheet = workbook.sheet(id) else { return nil }
                let size = gridSize(sheet: sheet, workbook: workbook)
                return CardLayout(card: card, frame: CGRect(origin: card.origin, size: size), sheet: sheet, rows: workbook.visibleRows(of: sheet))
            case .pivot(let cfg):
                guard let result = workbook.pivot(cfg) else { return nil }
                return CardLayout(card: card, frame: CGRect(origin: origin, size: size(pivotSize(result, totals: cfg.totals))), sheet: workbook.sheet(cfg.sheetID), pivot: result)
            case .chart(let cfg):
                guard let result = workbook.chart(cfg) else { return nil }
                return CardLayout(card: card, frame: CGRect(origin: origin, size: size(chartSize(result, type: cfg.type))), sheet: workbook.sheet(cfg.sheetID), chart: result)
            }
        }
    }

    static func contentBounds(canvas: Canvas, workbook: Workbook) -> CGRect {
        let frames = layouts(canvas: canvas, workbook: workbook).map { $0.frame }
        guard var r = frames.first else { return .zero }
        for f in frames.dropFirst() { r = r.union(f) }
        return r
    }

    // MARK: Hit testing

    enum Hit {
        case empty
        case cardHeader(UUID)
        case cardBody(UUID)
        case columnHeader(UUID, Int)
        case rowNumber(UUID, Int)
        case cell(UUID, row: Int, col: Int)
        case addRow(UUID)
        case addColumn(UUID)
        case removeView(UUID)
        case toggleFullscreen(UUID)
    }

    static func hit(_ p: CGPoint, layouts: [CardLayout]) -> Hit {
        for l in layouts.reversed() where l.frame.contains(p) {
            let local = CGPoint(x: p.x - l.frame.minX, y: p.y - l.frame.minY)
            if local.y < border + cardHeader {
                if !l.card.kind.isGrid, local.x > l.frame.width - 30 { return .removeView(l.card.id) }
                if !l.card.kind.isGrid, local.x > l.frame.width - headerButtonsWidth { return .toggleFullscreen(l.card.id) }
                return .cardHeader(l.card.id)
            }
            guard let sheet = l.sheet, l.card.kind.isGrid else { return .cardBody(l.card.id) }
            let rowBand = Int(floor((local.y - border - cardHeader) / rowHeight)) - headerRows   // < 0 = column letters / names
            if rowBand >= l.rows.count {
                return local.x < border + gutter + 80 ? .addRow(l.card.id) : .addColumn(l.card.id)
            }
            if local.x < border + gutter {
                return rowBand < 0 ? .cardBody(l.card.id) : .rowNumber(l.card.id, rowBand)
            }
            var x = border + gutter
            for (c, col) in sheet.columns.enumerated() {
                if local.x < x + col.width {
                    return rowBand < 0 ? .columnHeader(l.card.id, c) : .cell(l.card.id, row: rowBand, col: c)
                }
                x += col.width
            }
            return .cardBody(l.card.id)
        }
        return .empty
    }
}
