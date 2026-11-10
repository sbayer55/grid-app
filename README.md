# Grid

A lightweight, native macOS spreadsheet. Reads and writes `.xlsx`, keeps sheets on an infinite
canvas with numbered workspace tabs, and treats pivots and charts as formula-backed cards that
live next to the data they read. Catppuccin Mocha, blur, gradient borders, ⌘K for everything.

This is the build of the design canvas from the Claude Design sessions (round 3 prototype).

## Build

Requires macOS 14+ and Xcode 15+ (Swift 5.9).

```sh
swift build            # debug build
swift run Grid         # run from the package (window appears, no .app bundle)
swift test             # formula engine, pivot/chart, xlsx round-trip
make app               # release build → build/Grid.app (ad-hoc signed)
make dmg               # build/Grid-<version>.dmg with an /Applications shortcut
make icon              # redraw Resources/AppIcon.icns from Scripts/make-icon.swift
```

Or open the package in Xcode: `xed .` — the `Grid` scheme runs the app directly.

The only dependency is [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for the xlsx container.
Install [JetBrains Mono](https://www.jetbrains.com/lp/mono/) for the intended look; it falls back to
the system monospaced font otherwise.

The app and the DMG are ad-hoc signed and Apple Silicon only: they run on the Mac that built them,
but Gatekeeper will block the DMG elsewhere until it is signed with a Developer ID and notarized.

## Layout of the code

```
Sources/Grid
├─ App/        GridApp (menus & shortcuts), AppState (all state + mutations + undo), Commands (⌘K list)
├─ Model/      Model (sheets, columns, cards, canvases), Formula (engine), Analytics (format, pivot, chart), SampleData
├─ IO/         XLSXWriter, XLSXReader (minimal OOXML over ZIPFoundation, plus xl/grid-meta.json)
├─ Canvas/     CanvasView (NSView: pan/zoom, input, in-place editing), Renderer (Core Graphics), Layout (geometry + hit-testing)
├─ Theme/      Theme (Catppuccin Mocha tokens, ~/.config/grid/theme.json overrides)
└─ UI/         ContentView (window chrome), TabBarView + StatusBarView, CommandPaletteView, ViewPanelView, ColumnMenuView
```

Architecture in one paragraph: `AppState` owns a plain-value `Workbook` and every mutation goes
through `mutate(name) { wb in … }`, which snapshots the previous value for undo. The canvas is a
single `NSView` that draws every card with Core Graphics (so a sheet with thousands of cells is
one draw call, not thousands of views) and translates mouse/keyboard input into `AppState` calls.
SwiftUI draws only the chrome: tabs, status bar, the ⌘K palette, the column menu and the floating
view-config card — these sit in the viewport and never pan or scale.

## What it does

- **Canvases** — tabs `1 · Orders`, `2 · Inventory`, … (⌘1-9, ⌘T new, double-click to rename). Each holds one sheet card and any number of view cards. Drag empty canvas to pan, ⌘+scroll or pinch to zoom, ⌘0 fits everything.
- **Grid** — bounded to the data; `+ row` / `+ column` at the edges (⌘⇧↩ appends a row). Click / drag / ⇧-click to select, arrows and Tab to move, type to edit, ↩ commits, ⌫ clears. Column header click opens the column menu.
- **Column menu** — sort (multi-key, numbered badges), pin columns, filter by values, type (text / number / currency / percent / date / check), alignment, decimals, fit width, color by value. That is the whole formatting surface.
- **Formulas** — `=D7*E7`, `=SUM(F:F)`, `=IF(G2>0.4,"high","low")`, `=Orders!F2`, `='Other Sheet'!A1:A9`. Functions: SUM AVERAGE COUNT COUNTA MIN MAX ABS ROUND IF AND OR NOT LEN CONCAT. A column can carry a `formulaTemplate` so new rows get the formula automatically (Revenue does).
- **Views** — select a range, then ⌘⇧P (pivot) or ⌘⇧C (chart). Click a view's header to open its floating config card: rows × columns × value × aggregation, totals, sort-by-value; chart type (bar / column / stacked), x / y / series. Views recompute live as cells change and respect the sheet filter.
- **⌘K** — context-aware command palette: sorts for the selected column, type/alignment changes, pins, views, canvases, zoom, files.
- **Files** — ⌘O / ⌘S / ⌘⇧S. Sheets round-trip as real worksheets (typed number formats, formulas with cached values, frozen panes, autofilter range). Canvases, cards and column metadata live in `xl/grid-meta.json` inside the package; Excel ignores it. Pivot cards are additionally written out as value sheets (`Pivot · Region`) so Excel users can read them; this app hides those on reopen. Foreign workbooks (no metadata) get one canvas per sheet and column types inferred from number formats.
- **Theme** — drop a JSON at `~/.config/grid/theme.json` to override any token: `{ "accent": "#89b4fa", "animateBorders": false, "windowOpacity": 0.9 }`. View ▸ Reload Theme.

## Known gaps (v0.1)

- `date` and `check` column types are display-only.
- Chart types are bar / column / stacked; no line, area or donut yet.
- Undo covers data and structure; pan/zoom/card moves are not undoable (by design).
- Cross-canvas formula links are drawn from the grid card to each view card, not between sheets.
- No cell styles are read from foreign files beyond number formats; nothing is written beyond number formats and bold headers — the point is to stay lightweight.
