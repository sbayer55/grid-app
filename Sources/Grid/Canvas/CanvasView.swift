import AppKit
import SwiftUI
import Combine

/// The infinite canvas: draws every card of the current canvas with Core Graphics,
/// handles pan/zoom, selection, card dragging, keyboard navigation and in-place editing.
final class CanvasView: NSView, NSTextFieldDelegate {
    let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var layouts: [Layout.CardLayout] = []
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var selecting = false
    private var editor: NSTextField?
    private var editingCell: (cardID: UUID, ref: CellRef)?
    private var viewportTransition: (from: (CGPoint, CGFloat), to: (CGPoint, CGFloat), start: TimeInterval)?
    private let overlay = OverlayView()
    private let pulseLayer = CAShapeLayer()
    private static let pulseKey = "pulse"

    /// Hosts Core Animation layers above the drawn canvas; never takes mouse events.
    private final class OverlayView: NSView {
        override var isFlipped: Bool { true }   // AppKit flips the hosted layer to match: y down, like the canvas
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private enum Drag {
        case pan(start: CGPoint, origin: CGPoint)
        case card(id: UUID, start: CGPoint, origin: CGPoint, moved: Bool)
    }
    private var drag: Drag?

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        state.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }
            .store(in: &cancellables)
        state.beginEditRequest
            .sink { [weak self] initial in self?.beginEditing(initial: initial) }
            .store(in: &cancellables)
        state.focusCanvasRequest
            .sink { [weak self] in self?.window?.makeFirstResponder(self) }
            .store(in: &cancellables)
        state.animateViewportRequest
            .sink { [weak self] in self?.startViewportTransition() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self = self, (note.object as? NSWindow) === self.window else { return }
                self.needsDisplay = true
                self.syncTimer()
            }
            .store(in: &cancellables)

        let root = CALayer()
        root.masksToBounds = true
        overlay.layer = root
        overlay.wantsLayer = true
        addSubview(overlay)
        pulseLayer.fillColor = nil
        pulseLayer.shadowOffset = .zero
        pulseLayer.isHidden = true
        root.addSublayer(pulseLayer)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    // MARK: Frame timer

    /// Only the conic ring of a selected view card and the fit/zoom transition are redrawn
    /// frame by frame. Everything else is static, so the timer runs only while one of them is
    /// on screen; an idle canvas does not redraw at all.
    private var needsFrames: Bool {
        guard window?.occlusionState.contains(.visible) == true else { return false }
        if viewportTransition != nil { return true }
        return state.theme.animateBorders && state.selectedCardID != nil
    }

    private func syncTimer() {
        if needsFrames {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                guard self.needsFrames else { self.syncTimer(); return }
                self.phase += 0.025
                if self.phase > .pi * 2 { self.phase -= .pi * 2 }
                self.needsDisplay = true
            }
            t.tolerance = 0.005
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { state.undoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        needsDisplay = true
        syncTimer()
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        let size = bounds.size
        if state.viewportSize != size { DispatchQueue.main.async { self.state.viewportSize = size } }
    }

    // MARK: Coordinates

    private var pan: CGPoint { state.canvas.pan }
    private var zoom: CGFloat { state.canvas.zoom }
    private func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = state.theme
        advanceViewportTransition()
        let pan = self.pan, zoom = self.zoom

        // Dot grid (viewport space)
        let spacing = 22 * zoom
        if spacing > 6 {
            ctx.setFillColor(theme.text.withAlphaComponent(0.14).cgColor)
            let ox = pan.x.truncatingRemainder(dividingBy: spacing), oy = pan.y.truncatingRemainder(dividingBy: spacing)
            var y = oy
            while y < bounds.height {
                var x = ox
                while x < bounds.width { ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += spacing }
                y += spacing
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)

        layouts = Layout.layouts(canvas: state.canvas, workbook: state.workbook)
        let r = Renderer(ctx: ctx, theme: theme, zoom: zoom, phase: phase)

        // Links from the grid to each view card
        if let grid = layouts.first(where: { $0.card.kind.isGrid }) {
            for (i, l) in layouts.filter({ !$0.card.kind.isGrid }).enumerated() {
                let a = CGPoint(x: grid.frame.maxX, y: grid.frame.minY + 120 + CGFloat(i) * 40)
                let b = CGPoint(x: l.frame.minX, y: l.frame.minY + 14)
                let color: NSColor = { if case .pivot = l.card.kind { return theme.accent }; return theme.teal }()
                r.drawLink(from: a, to: b, color: color)
            }
        }

        for l in layouts {
            switch l.card.kind {
            case .grid:
                let editing = editingCell.flatMap { $0.cardID == l.card.id ? $0.ref : nil }
                r.drawGrid(l, state: Renderer.GridState(selection: state.selection, editing: editing, hasSelection: state.selection?.cardID == l.card.id))
            case .pivot(let cfg):
                r.drawPivot(l, cfg: cfg, selected: state.selectedCardID == l.card.id)
            case .chart(let cfg):
                r.drawChart(l, cfg: cfg, selected: state.selectedCardID == l.card.id)
            }
        }
        ctx.restoreGState()
        positionEditor()
        updatePulse()
        syncTimer()
    }

    // MARK: Current-cell ring

    /// The pulsing ring around the current cell. It is a layer with a repeating Core Animation
    /// glow, so it costs the app nothing while a cell just sits selected.
    private func updatePulse() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard editingCell == nil, let s = state.selection,
              let index = layouts.firstIndex(where: { $0.card.id == s.cardID }),
              let sheet = layouts[index].sheet,
              s.anchor.row < layouts[index].rows.count, s.anchor.col < sheet.columns.count else {
            pulseLayer.isHidden = true
            pulseLayer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        let l = layouts[index]
        let origin = toView(CGPoint(x: l.frame.minX + l.columnX(s.anchor.col), y: l.frame.minY + l.rowY(s.anchor.row)))
        let cell = CGRect(x: origin.x, y: origin.y, width: sheet.columns[s.anchor.col].width * zoom, height: Layout.rowHeight * zoom)
        let accent = state.theme.accent.cgColor
        pulseLayer.frame = bounds
        pulseLayer.path = CGPath(rect: cell.insetBy(dx: zoom, dy: zoom), transform: nil)
        pulseLayer.lineWidth = 2 * zoom
        pulseLayer.strokeColor = accent
        pulseLayer.shadowColor = accent
        pulseLayer.shadowRadius = 9
        pulseLayer.shadowOpacity = 0.6
        pulseLayer.isHidden = false

        // Cards drawn after this one sit on top of it; keep the ring underneath them.
        let glow = cell.insetBy(dx: -40, dy: -40)
        var visible: CGPath?
        for later in layouts[(index + 1)...] {
            let o = toView(later.frame.origin)
            let frame = CGRect(x: o.x, y: o.y, width: later.frame.width * zoom, height: later.frame.height * zoom)
            guard frame.intersects(glow) else { continue }
            let radius = min(Layout.cardRadius * zoom, frame.width / 2, frame.height / 2)
            let hole = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            visible = (visible ?? CGPath(rect: bounds, transform: nil)).subtracting(hole)
        }
        if let visible = visible {
            let mask = (pulseLayer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = bounds
            mask.path = visible
            pulseLayer.mask = mask
        } else {
            pulseLayer.mask = nil
        }

        if pulseLayer.animation(forKey: Self.pulseKey) == nil {
            // Same range and period as the old per-frame pulse (0.55…1 of full glow, ~4.2 s).
            let radius = CABasicAnimation(keyPath: "shadowRadius")
            radius.fromValue = 7.2; radius.toValue = 9
            let opacity = CABasicAnimation(keyPath: "shadowOpacity")
            opacity.fromValue = 0.33; opacity.toValue = 0.6
            let group = CAAnimationGroup()
            group.animations = [radius, opacity]
            group.duration = 2.1
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.isRemovedOnCompletion = false
            pulseLayer.add(group, forKey: Self.pulseKey)
        }
    }

    // MARK: Viewport animation (fit / zoom buttons)

    private func startViewportTransition() {
        // The state already holds the target; animate from the last drawn values.
        guard let from = lastDrawnViewport else { return }
        let to = (state.canvas.pan, state.canvas.zoom)
        guard from.0 != to.0 || from.1 != to.1 else { return }
        viewportTransition = (from: from, to: to, start: CACurrentMediaTime())
        // Draw from the previous values; draw() interpolates toward `to` on each frame.
        state.updateCanvas { c in c.pan = from.0; c.zoom = from.1 }
        needsDisplay = true
    }

    private var lastDrawnViewport: (CGPoint, CGFloat)?

    private func advanceViewportTransition() {
        defer { lastDrawnViewport = (state.canvas.pan, state.canvas.zoom) }
        guard let t = viewportTransition else { return }
        let p = min(1, (CACurrentMediaTime() - t.start) / 0.42)
        let e = 1 - pow(1 - p, 3)   // ease-out cubic
        let pan = CGPoint(x: t.from.0.x + (t.to.0.x - t.from.0.x) * e, y: t.from.0.y + (t.to.0.y - t.from.0.y) * e)
        let zoom = t.from.1 + (t.to.1 - t.from.1) * e
        state.updateCanvas { c in c.pan = pan; c.zoom = zoom }
        if p >= 1 { viewportTransition = nil }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let world = toWorld(p)
        viewportTransition = nil
        switch Layout.hit(world, layouts: layouts) {
        case .cardHeader(let id):
            commitEditing()
            if let l = layouts.first(where: { $0.card.id == id }) {
                drag = .card(id: id, start: p, origin: l.frame.origin, moved: false)
            }
            state.columnMenu = nil
        case .removeView(let id):
            commitEditing()
            state.removeCard(id)
        case .columnHeader(let id, let c):
            commitEditing()
            if let l = layouts.first(where: { $0.card.id == id }) {
                let anchor = toView(CGPoint(x: l.frame.minX + l.columnX(c), y: l.frame.minY + l.rowY(0)))
                state.openColumnMenu(cardID: id, column: c, anchor: anchor)
            }
        case .rowNumber(let id, let r):
            commitEditing()
            if let sheet = state.sheet(for: id) {
                state.select(card: id, row: r, col: 0, extend: false)
                state.selection?.focus = CellRef(row: r, col: max(0, sheet.columns.count - 1))
                state.selectedCardID = nil
            }
        case .cell(let id, let row, let col):
            if let e = editingCell, e.cardID == id, e.ref == CellRef(row: row, col: col) { return }
            commitEditing()
            state.select(card: id, row: row, col: col, extend: event.modifierFlags.contains(.shift))
            state.selectedCardID = nil
            selecting = true
            if event.clickCount == 2 { beginEditing(initial: nil) }
        case .addRow(let id):
            commitEditing()
            if state.gridCard?.id == id { state.appendRow() }
        case .addColumn(let id):
            commitEditing()
            if state.gridCard?.id == id { state.appendColumn() }
        case .cardBody:
            commitEditing()
            state.columnMenu = nil
        case .empty:
            commitEditing()
            state.selection = nil
            state.columnMenu = nil
            drag = .pan(start: p, origin: pan)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .pan(let start, let origin):
            state.updateCanvas { c in c.pan = CGPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y) }
            needsDisplay = true
        case .card(let id, let start, let origin, _):
            let o = CGPoint(x: origin.x + (p.x - start.x) / zoom, y: origin.y + (p.y - start.y) / zoom)
            drag = .card(id: id, start: start, origin: origin, moved: true)
            state.moveCard(id, to: o)
        case .none:
            if selecting, case .cell(let id, let row, let col) = Layout.hit(toWorld(p), layouts: layouts), state.selection?.cardID == id {
                state.selection?.focus = CellRef(row: row, col: col)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .card(let id, _, _, let moved) = drag, !moved, let card = state.canvas.cards.first(where: { $0.id == id }), !card.kind.isGrid {
            state.selectedCardID = id
            state.columnMenu = nil
        }
        if case .pan = drag { NSCursor.pop() }
        drag = nil
        selecting = false
    }

    override func scrollWheel(with event: NSEvent) {
        viewportTransition = nil
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor = exp(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05))
            state.zoom(to: zoom * factor, around: p)
        } else {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            state.updateCanvas { c in c.pan = CGPoint(x: c.pan.x + dx, y: c.pan.y + dy) }
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        viewportTransition = nil
        let p = convert(event.locationInWindow, from: nil)
        state.zoom(to: zoom * (1 + event.magnification), around: p)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), shift = flags.contains(.shift), alt = flags.contains(.option)
        let key = event.charactersIgnoringModifiers ?? ""
        let code = event.keyCode

        switch code {
        case 53: // esc
            if state.columnMenu != nil { state.columnMenu = nil }
            else if state.selectedCardID != nil { state.selectedCardID = nil }
            else { state.selection = nil }
            return
        case 126, 125, 123, 124: // ↑ ↓ ← →
            if cmd && (code == 126 || code == 125), let s = state.selection, let sheet = state.sheet(for: s.cardID) {
                state.sort(sheetID: sheet.id, column: s.anchor.col, ascending: code == 126)
                return
            }
            let d: (Int, Int) = code == 126 ? (-1, 0) : code == 125 ? (1, 0) : code == 123 ? (0, -1) : (0, 1)
            if state.selection == nil, let g = state.gridCard { state.select(card: g.id, row: 0, col: 0, extend: false); return }
            state.moveSelection(dRow: d.0, dCol: d.1, extend: shift)
            return
        case 48: // tab
            state.moveSelection(dRow: 0, dCol: shift ? -1 : 1, extend: false)
            return
        case 36, 76: // return / enter
            if cmd && shift { state.appendRow(); return }
            beginEditing(initial: nil)
            return
        case 51, 117: // delete / forward delete
            state.clearSelection()
            return
        default: break
        }
        if alt && key.lowercased() == "p", let s = state.selection, let sheet = state.sheet(for: s.cardID) {
            state.togglePin(sheetID: sheet.id, throughColumn: s.anchor.col); return
        }
        if alt && key.lowercased() == "w", let s = state.selection, let sheet = state.sheet(for: s.cardID) {
            state.fitColumnWidth(sheetID: sheet.id, column: s.anchor.col); return
        }
        if !cmd && !flags.contains(.control), let ch = event.characters, ch.count == 1, let scalar = ch.unicodeScalars.first, scalar.value >= 32, scalar.value < 0xF700, state.selection != nil {
            beginEditing(initial: ch)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: In-place editing

    func beginEditing(initial: String?) {
        guard let s = state.selection, let sheet = state.sheet(for: s.cardID), let l = layouts.first(where: { $0.card.id == s.cardID }), l.card.kind.isGrid else { return }
        guard s.anchor.row < l.rows.count, s.anchor.col < sheet.columns.count else { return }
        let col = sheet.columns[s.anchor.col]
        let source = l.rows[s.anchor.row].sourceIndex
        let raw = sheet.rows[source][s.anchor.col]
        commitEditing()
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = state.theme.base
        field.textColor = state.theme.bright
        field.font = Theme.font(12 * zoom, weight: .medium)
        field.alignment = col.effectiveAlignment == .left ? .left : (col.effectiveAlignment == .center ? .center : .right)
        field.stringValue = initial ?? raw.editText
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderColor = state.theme.accent.cgColor
        field.layer?.borderWidth = 2
        field.layer?.cornerRadius = 3
        addSubview(field)
        editor = field
        editingCell = (s.cardID, s.anchor)
        positionEditor()
        window?.makeFirstResponder(field)
        if let tv = field.currentEditor() as? NSTextView {
            if initial != nil { tv.setSelectedRange(NSRange(location: field.stringValue.count, length: 0)) }
            else { tv.selectAll(nil) }
        }
        needsDisplay = true
    }

    private func positionEditor() {
        guard let field = editor, let e = editingCell, let l = layouts.first(where: { $0.card.id == e.cardID }), let sheet = l.sheet, e.ref.col < sheet.columns.count else { return }
        let world = CGRect(x: l.frame.minX + l.columnX(e.ref.col), y: l.frame.minY + l.rowY(e.ref.row), width: sheet.columns[e.ref.col].width, height: Layout.rowHeight)
        let origin = toView(world.origin)
        field.frame = CGRect(x: origin.x, y: origin.y, width: world.width * zoom, height: world.height * zoom)
        field.font = Theme.font(12 * zoom, weight: .medium)
    }

    func commitEditing(cancel: Bool = false) {
        guard let field = editor, let e = editingCell else { return }
        editor = nil
        editingCell = nil
        let text = field.stringValue
        field.removeFromSuperview()
        if !cancel { state.setCell(cardID: e.cardID, displayRow: e.ref.row, col: e.ref.col, text: text) }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitEditing(); state.moveSelection(dRow: 1, dCol: 0, extend: false); return true
        case #selector(NSResponder.insertTab(_:)):
            commitEditing(); state.moveSelection(dRow: 0, dCol: 1, extend: false); return true
        case #selector(NSResponder.insertBacktab(_:)):
            commitEditing(); state.moveSelection(dRow: 0, dCol: -1, extend: false); return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitEditing(cancel: true); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus moved elsewhere (click on another control): commit what was typed.
        if editor != nil { commitEditing() }
    }
}

// MARK: - SwiftUI bridge

struct CanvasRepresentable: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> CanvasView { CanvasView(state: state) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }
}
