import AppKit

/// Core Graphics drawing for cards. Everything is drawn in world units; the canvas view
/// applies the pan/zoom transform before calling in.
struct Renderer {
    let ctx: CGContext
    let theme: Theme
    let zoom: CGFloat
    /// 0…2π, advanced by the canvas timer; drives the conic border and the selection pulse.
    let phase: CGFloat

    // MARK: Text

    func draw(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, align: NSTextAlignment = .left, inset: CGFloat = 8) {
        guard !text.isEmpty else { return }
        let ps = NSMutableParagraphStyle()
        ps.alignment = align
        ps.lineBreakMode = .byClipping
        let attr = NSAttributedString(string: text, attributes: [.font: Theme.font(size, weight: weight), .foregroundColor: color, .paragraphStyle: ps])
        let h = attr.size().height
        let r = CGRect(x: rect.minX + inset, y: rect.midY - h / 2, width: rect.width - inset * 2, height: h)
        ctx.saveGState()
        ctx.clip(to: rect)
        attr.draw(with: r, options: [.usesLineFragmentOrigin], context: nil)
        ctx.restoreGState()
    }

    func width(of text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: Theme.font(size, weight: weight)]).size().width
    }

    // MARK: Card chrome

    func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Card background with shadow and a gradient ring. `conic` animates the ring (selected cards).
    func drawCardChrome(_ frame: CGRect, colors: [NSColor], conic: Bool, glow: NSColor?) {
        let outer = roundedPath(frame, radius: Layout.cardRadius)
        let innerRect = frame.insetBy(dx: Layout.border, dy: Layout.border)
        let inner = roundedPath(innerRect, radius: Layout.cardRadius - Layout.border)

        // Shadow + glow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(outer)
        ctx.setFillColor(theme.mantle.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        if let glow = glow {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 28, color: glow.withAlphaComponent(0.35).cgColor)
            ctx.addPath(outer)
            ctx.setStrokeColor(glow.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Gradient ring
        ctx.saveGState()
        ctx.addPath(outer)
        ctx.addPath(inner)
        ctx.clip(using: .evenOdd)
        let cg = colors.map { $0.cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cg, locations: nil) {
            if conic {
                CGContextDrawConicGradient(ctx, gradient, CGPoint(x: frame.midX, y: frame.midY), phase)
            } else {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: frame.minX, y: frame.minY), end: CGPoint(x: frame.maxX, y: frame.maxY), options: [])
            }
        }
        ctx.restoreGState()

        // Body
        ctx.addPath(inner)
        ctx.setFillColor(theme.mantle.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
    }

    func drawHeaderStrip(_ frame: CGRect) {
        let r = CGRect(x: frame.minX + Layout.border, y: frame.minY + Layout.border, width: frame.width - Layout.border * 2, height: Layout.cardHeader)
        ctx.setStrokeColor(theme.text.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); ctx.strokePath()
    }

    func line(from a: CGPoint, to b: CGPoint, color: NSColor, width: CGFloat = 1) {
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }

    func fill(_ rect: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.fill(rect)
    }

    func fillRounded(_ rect: CGRect, radius: CGFloat, _ color: NSColor) {
        ctx.addPath(roundedPath(rect, radius: radius)); ctx.setFillColor(color.cgColor); ctx.fillPath()
    }

    // MARK: Grid card

    struct GridState {
        var selection: Selection?
        var editing: CellRef?
        var hasSelection: Bool
    }

    func drawGrid(_ l: Layout.CardLayout, state: GridState) {
        guard let sheet = l.sheet else { return }
        let f = l.frame
        drawCardChrome(f, colors: [theme.accent, theme.blue], conic: false, glow: theme.accent.withAlphaComponent(0.5))
        drawHeaderStrip(f)

        // Header strip text
        let header = CGRect(x: f.minX + Layout.border, y: f.minY + Layout.border, width: f.width - Layout.border * 2, height: Layout.cardHeader)
        var x = header.minX + 10
        draw(sheet.name, in: CGRect(x: x, y: header.minY, width: 300, height: header.height), size: 11, weight: .bold, color: theme.accent, inset: 0)
        x += width(of: sheet.name, size: 11, weight: .bold) + 8
        let sub = "\(sheet.rangeDescription) · \(l.rows.count) rows"
        draw(sub, in: CGRect(x: x, y: header.minY, width: 300, height: header.height), size: 11, color: theme.subtext, inset: 0)
        x += width(of: sub, size: 11) + 10
        var pin = ""
        if sheet.pinnedRows > 0 { pin += "row 1" }
        if sheet.pinnedColumns > 0 { pin += (pin.isEmpty ? "" : " · ") + "cols A:" + Sheet.columnLetter(sheet.pinnedColumns - 1) }
        if !pin.isEmpty {
            draw("⌖ " + pin, in: CGRect(x: x, y: header.minY, width: 300, height: header.height), size: 11, color: theme.accent, inset: 0)
        }
        let right: String
        if state.hasSelection {
            right = "pivot ⌘⇧P · chart ⌘⇧C · filter ⌘⇧L"
        } else if !sheet.sorts.isEmpty {
            right = "sort: " + sheet.sorts.map { sheet.columns[$0.column].name + ($0.ascending ? " ↑" : " ↓") }.joined(separator: ", ")
        } else { right = "no sort" }
        draw(right, in: CGRect(x: header.minX, y: header.minY, width: header.width - 10, height: header.height), size: 11, color: state.hasSelection ? theme.accent : theme.subtext, align: .right, inset: 0)

        // Column header row + gutter backgrounds
        let colHeaderY = f.minY + Layout.border + Layout.cardHeader
        let gutterBG = theme.crust.withAlphaComponent(0.55)
        let namesY = colHeaderY + Layout.rowHeight
        fill(CGRect(x: f.minX + Layout.border, y: colHeaderY, width: f.width - Layout.border * 2, height: Layout.rowHeight * 2), gutterBG)
        let rowsTop = f.minY + l.rowY(0)
        let rowsHeight = Layout.rowHeight * CGFloat(l.rows.count)
        fill(CGRect(x: f.minX + Layout.border, y: rowsTop, width: Layout.gutter, height: rowsHeight), gutterBG)

        let lineColor = theme.text.withAlphaComponent(0.08)
        // Selection band highlights on headers
        if let s = state.selection, s.cardID == l.card.id, !sheet.columns.isEmpty, !l.rows.isEmpty, s.minCol < sheet.columns.count, s.minRow < l.rows.count {
            for c in s.minCol...min(s.maxCol, sheet.columns.count - 1) {
                fill(CGRect(x: f.minX + l.columnX(c), y: colHeaderY, width: sheet.columns[c].width, height: Layout.rowHeight), theme.accent.withAlphaComponent(0.12))
            }
            for r in s.minRow...min(s.maxRow, l.rows.count - 1) {
                fill(CGRect(x: f.minX + Layout.border, y: f.minY + l.rowY(r), width: Layout.gutter, height: Layout.rowHeight), theme.accent.withAlphaComponent(0.12))
            }
        }

        // Column letters
        for (c, col) in sheet.columns.enumerated() {
            let r = CGRect(x: f.minX + l.columnX(c), y: colHeaderY, width: col.width, height: Layout.rowHeight)
            let inSel = state.selection.map { $0.cardID == l.card.id && c >= $0.minCol && c <= $0.maxCol } ?? false
            draw(Sheet.columnLetter(c), in: r, size: 11, weight: .semibold, color: inSel ? theme.accent : theme.subtext, align: .center)
            var badge = ""
            if let i = sheet.sorts.firstIndex(where: { $0.column == c }) { badge = "\(i + 1)" + (sheet.sorts[i].ascending ? "↑" : "↓") }
            if sheet.filter?.column == c { badge += " ⏷" }
            if !badge.isEmpty { draw(badge, in: CGRect(x: r.maxX - 40, y: r.minY, width: 36, height: 12), size: 9, weight: .bold, color: theme.accent, align: .right, inset: 2) }
            line(from: CGPoint(x: r.maxX, y: colHeaderY), to: CGPoint(x: r.maxX, y: rowsTop + rowsHeight), color: lineColor)
        }

        // Row 1: column names
        draw("1", in: CGRect(x: f.minX + Layout.border, y: namesY, width: Layout.gutter, height: Layout.rowHeight), size: 11, color: theme.subtext, align: .right)
        for (c, col) in sheet.columns.enumerated() {
            let r = CGRect(x: f.minX + l.columnX(c), y: namesY, width: col.width, height: Layout.rowHeight)
            let align: NSTextAlignment = col.effectiveAlignment == .left ? .left : (col.effectiveAlignment == .center ? .center : .right)
            draw(col.name, in: r, size: 12, weight: .bold, color: theme.bright, align: align)
        }
        line(from: CGPoint(x: f.minX + Layout.border, y: namesY), to: CGPoint(x: f.maxX - Layout.border, y: namesY), color: lineColor)

        // Rows
        for (r, row) in l.rows.enumerated() {
            let y = f.minY + l.rowY(r)
            let rowRect = CGRect(x: f.minX + Layout.border, y: y, width: f.width - Layout.border * 2, height: Layout.rowHeight)
            let inSelRow = state.selection.map { $0.cardID == l.card.id && r >= $0.minRow && r <= $0.maxRow } ?? false
            draw(String(r + 2), in: CGRect(x: rowRect.minX, y: y, width: Layout.gutter, height: Layout.rowHeight), size: 11, color: inSelRow ? theme.accent : theme.subtext, align: .right)
            for (c, col) in sheet.columns.enumerated() where c < row.values.count {
                let cell = CGRect(x: f.minX + l.columnX(c), y: y, width: col.width, height: Layout.rowHeight)
                let selected = state.selection.map { $0.cardID == l.card.id && $0.contains(r, c) } ?? false
                if selected { fill(cell, theme.accent.withAlphaComponent(0.16)) }
                if state.editing == CellRef(row: r, col: c) { continue }   // the NSTextField draws here
                let value = row.values[c]
                var color = theme.text
                var textRect = cell
                if col.colorByValue, let semantic = theme.color(forValue: CellFormatter.plainText(value)) {
                    color = semantic
                    ctx.setFillColor(semantic.cgColor)
                    ctx.fillEllipse(in: CGRect(x: cell.minX + 8, y: cell.midY - 3, width: 6, height: 6))
                    textRect.origin.x += 12; textRect.size.width -= 12
                } else if case .text(let s) = value, s.hasPrefix("#") {
                    color = theme.red
                } else if sheet.rows.indices.contains(row.sourceIndex), c < sheet.rows[row.sourceIndex].count, sheet.rows[row.sourceIndex][c].isFormula {
                    color = theme.lavender
                }
                let align: NSTextAlignment = col.effectiveAlignment == .left ? .left : (col.effectiveAlignment == .center ? .center : .right)
                draw(CellFormatter.display(value, column: col), in: textRect, size: 12, color: color, align: align)
            }
            line(from: CGPoint(x: rowRect.minX, y: rowRect.maxY), to: CGPoint(x: rowRect.maxX, y: rowRect.maxY), color: lineColor)
        }
        line(from: CGPoint(x: f.minX + Layout.border, y: rowsTop), to: CGPoint(x: f.maxX - Layout.border, y: rowsTop), color: lineColor)
        line(from: CGPoint(x: f.minX + Layout.border + Layout.gutter, y: colHeaderY), to: CGPoint(x: f.minX + Layout.border + Layout.gutter, y: rowsTop + rowsHeight), color: lineColor)

        // Pins
        if sheet.pinnedRows > 0 {
            line(from: CGPoint(x: f.minX + Layout.border, y: rowsTop), to: CGPoint(x: f.maxX - Layout.border, y: rowsTop), color: theme.accent, width: 2)
        }
        if sheet.pinnedColumns > 0, sheet.pinnedColumns <= sheet.columns.count {
            let px = f.minX + l.columnX(sheet.pinnedColumns)
            line(from: CGPoint(x: px, y: colHeaderY), to: CGPoint(x: px, y: rowsTop + rowsHeight), color: theme.accent, width: 2)
        }

        // Current cell ring (pulses)
        if let s = state.selection, s.cardID == l.card.id, s.anchor.row < l.rows.count, s.anchor.col < sheet.columns.count, state.editing == nil {
            let cell = CGRect(x: f.minX + l.columnX(s.anchor.col), y: f.minY + l.rowY(s.anchor.row), width: sheet.columns[s.anchor.col].width, height: Layout.rowHeight)
            let pulse = 0.55 + 0.45 * (sin(phase * 2) + 1) / 2
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10 + 8 * pulse, color: theme.accent.withAlphaComponent(0.6 * pulse).cgColor)
            ctx.setStrokeColor(theme.accent.cgColor); ctx.setLineWidth(2)
            ctx.stroke(cell.insetBy(dx: 1, dy: 1))
            ctx.restoreGState()
        }

        // Footer
        let footerY = rowsTop + rowsHeight
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        line(from: CGPoint(x: f.minX + Layout.border, y: footerY), to: CGPoint(x: f.maxX - Layout.border, y: footerY), color: theme.text.withAlphaComponent(0.18))
        ctx.restoreGState()
        let footer = CGRect(x: f.minX + Layout.border + Layout.gutter, y: footerY, width: f.width - Layout.border * 2 - Layout.gutter, height: Layout.footer)
        draw("+ row   ·   + column", in: footer, size: 11, color: theme.subtext, inset: 10)
        var note = ""
        if let flt = sheet.filter, flt.column < sheet.columns.count { note = "filter: \(sheet.columns[flt.column].name) ∈ {\(flt.values.joined(separator: ", "))}" }
        else if let cb = sheet.columns.first(where: { $0.colorByValue }) { note = "\(cb.name) · colored by value" }
        draw(note, in: footer, size: 11, color: theme.subtext, align: .right, inset: 10)
    }

    // MARK: Pivot card

    func drawPivot(_ l: Layout.CardLayout, cfg: PivotConfig, selected: Bool) {
        guard let p = l.pivot, let sheet = l.sheet else { return }
        let f = l.frame
        drawCardChrome(f, colors: selected ? theme.borderGradient : [theme.accent, theme.pink], conic: selected, glow: selected ? theme.accent : nil)
        drawHeaderStrip(f)
        let header = CGRect(x: f.minX + Layout.border, y: f.minY + Layout.border, width: f.width - Layout.border * 2, height: Layout.cardHeader)
        var x = header.minX + 10
        draw("pivot", in: CGRect(x: x, y: header.minY, width: 100, height: header.height), size: 11, weight: .bold, color: theme.accent, inset: 0)
        x += width(of: "pivot", size: 11, weight: .bold) + 8
        let sub = "\(sheet.name) · by \(cfg.rowField)" + (cfg.columnField.map { " × \($0)" } ?? "")
        draw(sub, in: CGRect(x: x, y: header.minY, width: header.width - 120, height: header.height), size: 11, color: theme.subtext, inset: 0)
        draw(selected ? "editing  ×" : "live  ×", in: CGRect(x: header.minX, y: header.minY, width: header.width - 10, height: header.height), size: 11, color: selected ? theme.accent : theme.subtext, align: .right, inset: 0)

        let showTotal = cfg.totals && p.columnHeaders.count > 1
        let top = f.minY + Layout.border + Layout.cardHeader
        let left = f.minX + Layout.border + 1
        fill(CGRect(x: f.minX + Layout.border, y: top, width: f.width - Layout.border * 2, height: Layout.rowHeight), theme.crust.withAlphaComponent(0.5))
        draw(p.rowField, in: CGRect(x: left, y: top, width: Layout.pivotLabelWidth, height: Layout.rowHeight), size: 12, weight: .bold, color: theme.bright, inset: 10)
        for (i, h) in p.columnHeaders.enumerated() {
            let r = CGRect(x: left + Layout.pivotLabelWidth + Layout.pivotValueWidth * CGFloat(i), y: top, width: Layout.pivotValueWidth, height: Layout.rowHeight)
            draw(h, in: r, size: 12, weight: .bold, color: theme.color(forValue: h) ?? theme.bright, align: .right, inset: 10)
        }
        if showTotal {
            draw("Total", in: CGRect(x: left + Layout.pivotLabelWidth + Layout.pivotValueWidth * CGFloat(p.columnHeaders.count), y: top, width: Layout.pivotTotalWidth, height: Layout.rowHeight), size: 12, weight: .bold, color: theme.bright, align: .right, inset: 10)
        }
        let lineColor = theme.text.withAlphaComponent(0.08)
        for (i, row) in p.rows.enumerated() {
            let y = top + Layout.rowHeight * CGFloat(i + 1)
            let rowRect = CGRect(x: f.minX + Layout.border, y: y, width: f.width - Layout.border * 2, height: Layout.rowHeight)
            if row.isTotal { fill(rowRect, theme.surface0.withAlphaComponent(0.5)) }
            let w: NSFont.Weight = row.isTotal ? .bold : .regular
            let c = row.isTotal ? theme.bright : theme.text
            draw(row.label, in: CGRect(x: left, y: y, width: Layout.pivotLabelWidth, height: Layout.rowHeight), size: 12, weight: w, color: c, inset: 10)
            for (j, v) in row.values.enumerated() {
                let r = CGRect(x: left + Layout.pivotLabelWidth + Layout.pivotValueWidth * CGFloat(j), y: y, width: Layout.pivotValueWidth, height: Layout.rowHeight)
                draw(v == 0 && !row.isTotal && p.columnHeaders.count > 1 ? "–" : p.format(v), in: r, size: 12, weight: w, color: c, align: .right, inset: 10)
            }
            if showTotal {
                draw(p.format(row.total), in: CGRect(x: left + Layout.pivotLabelWidth + Layout.pivotValueWidth * CGFloat(p.columnHeaders.count), y: y, width: Layout.pivotTotalWidth, height: Layout.rowHeight), size: 12, weight: .bold, color: theme.bright, align: .right, inset: 10)
            }
            line(from: CGPoint(x: rowRect.minX, y: rowRect.maxY), to: CGPoint(x: rowRect.maxX, y: rowRect.maxY), color: lineColor)
        }
    }

    // MARK: Chart card

    func drawChart(_ l: Layout.CardLayout, cfg: ChartConfig, selected: Bool) {
        guard let ch = l.chart, let sheet = l.sheet else { return }
        let f = l.frame
        drawCardChrome(f, colors: selected ? theme.borderGradient : [theme.teal, theme.blue], conic: selected, glow: selected ? theme.teal : nil)
        drawHeaderStrip(f)
        let header = CGRect(x: f.minX + Layout.border, y: f.minY + Layout.border, width: f.width - Layout.border * 2, height: Layout.cardHeader)
        var x = header.minX + 10
        draw("chart", in: CGRect(x: x, y: header.minY, width: 100, height: header.height), size: 11, weight: .bold, color: theme.teal, inset: 0)
        x += width(of: "chart", size: 11, weight: .bold) + 8
        draw("\(sheet.name) · \(cfg.type.rawValue)", in: CGRect(x: x, y: header.minY, width: 200, height: header.height), size: 11, color: theme.subtext, inset: 0)
        draw(selected ? "editing  ×" : "live  ×", in: CGRect(x: header.minX, y: header.minY, width: header.width - 10, height: header.height), size: 11, color: selected ? theme.teal : theme.subtext, align: .right, inset: 0)

        // Title + legend
        let titleY = f.minY + Layout.border + Layout.cardHeader + 8
        let title = "\(cfg.yField) by \(cfg.xField)" + (cfg.seriesField.map { " · by \($0)" } ?? "")
        draw(title, in: CGRect(x: f.minX + 16, y: titleY, width: f.width - 32, height: 18), size: 12, weight: .bold, color: theme.bright, inset: 0)
        if !ch.series.isEmpty {
            var lx = f.maxX - 16
            for (i, s) in ch.series.enumerated().reversed() {
                let w = width(of: s, size: 10) + 16
                lx -= w
                fillRounded(CGRect(x: lx, y: titleY + 4, width: 9, height: 9), radius: 3, theme.series[i % theme.series.count])
                draw(s, in: CGRect(x: lx + 12, y: titleY, width: w, height: 18), size: 10, color: theme.text, inset: 0)
                lx -= 10
            }
        }

        let plot = CGRect(x: f.minX + 16, y: titleY + 28, width: f.width - 32, height: f.maxY - (titleY + 28) - 14)
        if cfg.type == .bar {
            let rowH = min(26, plot.height / CGFloat(max(1, ch.bars.count)))
            let startY = plot.minY + (plot.height - rowH * CGFloat(ch.bars.count)) / 2
            for (i, bar) in ch.bars.enumerated() {
                let y = startY + rowH * CGFloat(i)
                draw(bar.label, in: CGRect(x: plot.minX, y: y, width: 64, height: rowH), size: 11, color: theme.text, inset: 0)
                let track = CGRect(x: plot.minX + 74, y: y + (rowH - 14) / 2, width: plot.width - 74 - (cfg.valueLabels ? 78 : 0), height: 14)
                fillRounded(track, radius: 7, theme.surface1.withAlphaComponent(0.5))
                ctx.saveGState()
                ctx.addPath(roundedPath(track, radius: 7)); ctx.clip()
                var sx = track.minX
                for seg in bar.segments {
                    let w = track.width * CGFloat(seg.value / ch.maxValue)
                    fill(CGRect(x: sx, y: track.minY, width: w, height: track.height), theme.series[seg.seriesIndex % theme.series.count])
                    sx += w
                }
                ctx.restoreGState()
                if cfg.valueLabels { draw(ch.format(bar.total), in: CGRect(x: plot.maxX - 76, y: y, width: 76, height: rowH), size: 11, color: theme.subtext, align: .right, inset: 0) }
            }
        } else {
            let axisY = plot.maxY - 18
            let area = CGRect(x: plot.minX, y: plot.minY + 14, width: plot.width, height: axisY - plot.minY - 14)
            for i in 0...4 {
                let y = area.minY + area.height * CGFloat(i) / 4
                line(from: CGPoint(x: area.minX, y: y), to: CGPoint(x: area.maxX, y: y), color: theme.text.withAlphaComponent(0.07))
            }
            line(from: CGPoint(x: area.minX, y: axisY), to: CGPoint(x: area.maxX, y: axisY), color: theme.text.withAlphaComponent(0.18))
            let slot = area.width / CGFloat(max(1, ch.bars.count))
            let barW = min(44, slot * 0.6)
            for (i, bar) in ch.bars.enumerated() {
                let cx = area.minX + slot * (CGFloat(i) + 0.5)
                var y = axisY
                for seg in bar.segments {
                    let h = area.height * CGFloat(seg.value / ch.maxValue)
                    fill(CGRect(x: cx - barW / 2, y: y - h, width: barW, height: h), theme.series[seg.seriesIndex % theme.series.count])
                    line(from: CGPoint(x: cx - barW / 2, y: y - h), to: CGPoint(x: cx + barW / 2, y: y - h), color: theme.mantle.withAlphaComponent(0.6))
                    y -= h
                }
                if cfg.valueLabels { draw(ch.format(bar.total), in: CGRect(x: cx - slot / 2, y: y - 16, width: slot, height: 14), size: 9.5, color: theme.text, align: .center, inset: 0) }
                draw(bar.label, in: CGRect(x: cx - slot / 2, y: axisY + 2, width: slot, height: 16), size: 10, color: theme.text, align: .center, inset: 2)
            }
        }
    }

    // MARK: Links

    func drawLink(from a: CGPoint, to b: CGPoint, color: NSColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: a)
        ctx.addCurve(to: b, control1: CGPoint(x: a.x + 40, y: a.y), control2: CGPoint(x: b.x - 40, y: b.y))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: a.x - 3.5, y: a.y - 3.5, width: 7, height: 7))
    }
}
