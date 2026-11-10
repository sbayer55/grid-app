import SwiftUI

/// The floating config card for a selected pivot or chart. Fixed to the viewport's top-right,
/// never pans or scales with the canvas, always on top. Every control edits the card's formula.
struct ViewPanelView: View {
    @EnvironmentObject var state: AppState
    let card: Card

    var body: some View {
        let theme = state.theme
        FloatingCard(width: 316) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(title).font(Theme.uiFont(13, weight: .bold)).foregroundStyle(theme.bright.swiftUI)
                    Text("formula-backed").font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI)
                    Spacer()
                    Button { state.toggleFullscreen(card.id) } label: {
                        Image(systemName: state.fullscreenCardID == card.id ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.subtext.swiftUI)
                    .help(state.fullscreenCardID == card.id ? "Exit full screen (esc)" : "Fill the canvas (⇧⌘F)")
                    Button { state.selectedCardID = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22) }
                        .buttonStyle(.plain).foregroundStyle(theme.subtext.swiftUI)
                }
                .padding(.horizontal, 14).padding(.top, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Source")
                        Text(sourceText).font(Theme.uiFont(10.5, weight: .semibold)).foregroundStyle(theme.accent.swiftUI)
                        switch card.kind {
                        case .pivot(let cfg): pivotControls(cfg)
                        case .chart(let cfg): chartControls(cfg)
                        case .grid: EmptyView()
                        }
                        SectionLabel("Actions")
                        HStack(spacing: 6) {
                            Button("duplicate") { state.duplicateCard(card.id) }.buttonStyle(ToolButtonStyle(theme: theme))
                            Button("remove") { state.removeCard(card.id) }.buttonStyle(ToolButtonStyle(theme: theme)).foregroundStyle(theme.red.swiftUI)
                        }
                        .padding(.bottom, 12)
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxHeight: 560)

                Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("formula").font(Theme.uiFont(10.5)).foregroundStyle(theme.subtext.swiftUI)
                    Text(formula).font(Theme.uiFont(11)).foregroundStyle(theme.text.swiftUI).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private var sheet: Sheet? { state.sheet(for: card.id) }
    private var title: String { card.kind.label.capitalized }
    private var sourceText: String { sheet.map { "\($0.name)!\($0.rangeDescription)" } ?? "" }
    private var textFields: [String] { sheet?.columns.filter { $0.type == .text }.map { $0.name } ?? [] }
    private var numericFields: [String] { sheet?.columns.filter { $0.type.isNumeric }.map { $0.name } ?? [] }

    private var formula: String {
        guard let s = sheet else { return "" }
        let filter = s.filter.flatMap { f in f.column < s.columns.count ? "\(s.columns[f.column].name) in {\(f.values.joined(separator: ", "))}" : nil }
        switch card.kind {
        case .pivot(let cfg): return cfg.formulaDescription(sheetName: s.name, range: s.rangeDescription, filter: filter)
        case .chart(let cfg): return cfg.formulaDescription(sheetName: s.name, range: s.rangeDescription)
        case .grid: return ""
        }
    }

    // MARK: Pivot

    @ViewBuilder
    private func pivotControls(_ cfg: PivotConfig) -> some View {
        let theme = state.theme
        SectionLabel("Rows")
        fieldPicker(cfg.rowField, options: textFields, allowNone: false) { v in state.updatePivot(card.id) { $0.rowField = v } }
        SectionLabel("Columns")
        fieldPicker(cfg.columnField ?? "", options: textFields, allowNone: true) { v in state.updatePivot(card.id) { $0.columnField = v.isEmpty ? nil : v } }
        SectionLabel("Value")
        fieldPicker(cfg.valueField, options: numericFields, allowNone: false) { v in state.updatePivot(card.id) { $0.valueField = v } }
        HStack(spacing: 5) {
            ForEach(Aggregation.allCases, id: \.self) { a in
                Button(a.label) { state.updatePivot(card.id) { $0.aggregation = a } }.buttonStyle(ToolButtonStyle(theme: theme, on: cfg.aggregation == a))
            }
        }
        .padding(.top, 6)
        SectionLabel("Options")
        VStack(alignment: .leading, spacing: 7) {
            toggle("totals", cfg.totals) { state.updatePivot(card.id) { $0.totals.toggle() } }
            toggle("sort rows by value", cfg.sortByValue) { state.updatePivot(card.id) { $0.sortByValue.toggle() } }
            toggle("respect sheet filter", cfg.respectFilter) { state.updatePivot(card.id) { $0.respectFilter.toggle() } }
        }
    }

    // MARK: Chart

    @ViewBuilder
    private func chartControls(_ cfg: ChartConfig) -> some View {
        let theme = state.theme
        SectionLabel("Type")
        HStack(spacing: 6) {
            ForEach(ChartType.allCases, id: \.self) { t in
                Button(t.rawValue) {
                    state.updateChart(card.id) { c in c.type = t; if t == .stacked && c.seriesField == nil { c.seriesField = textFields.first { $0 != c.xField } } }
                }
                .buttonStyle(ToolButtonStyle(theme: theme, on: cfg.type == t))
            }
        }
        SectionLabel("X")
        fieldPicker(cfg.xField, options: textFields, allowNone: false) { v in state.updateChart(card.id) { $0.xField = v } }
        SectionLabel("Y")
        fieldPicker(cfg.yField, options: numericFields, allowNone: false) { v in state.updateChart(card.id) { $0.yField = v } }
        SectionLabel("Series")
        fieldPicker(cfg.seriesField ?? "", options: textFields, allowNone: true) { v in
            state.updateChart(card.id) { c in c.seriesField = v.isEmpty ? nil : v; if v.isEmpty && c.type == .stacked { c.type = .column } }
        }
        Group {
            SectionLabel("Options")
            VStack(alignment: .leading, spacing: 7) {
                toggle("value labels", cfg.valueLabels) { state.updateChart(card.id) { $0.valueLabels.toggle() } }
                toggle("sort x by value", cfg.sortByValue) { state.updateChart(card.id) { $0.sortByValue.toggle() } }
                toggle("respect sheet filter", cfg.respectFilter) { state.updateChart(card.id) { $0.respectFilter.toggle() } }
            }
            SectionLabel("Palette · from theme")
            HStack(spacing: 6) {
                ForEach(Array(theme.series.prefix(6).enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 6).fill(c.swiftUI).frame(width: 22, height: 22)
                }
            }
        }
    }

    // MARK: Controls

    private func fieldPicker(_ value: String, options: [String], allowNone: Bool, set: @escaping (String) -> Void) -> some View {
        let theme = state.theme
        return Menu {
            if allowNone { Button("none") { set("") } }
            ForEach(options, id: \.self) { o in Button(o) { set(o) } }
        } label: {
            HStack {
                Text(value.isEmpty ? "none" : value).font(Theme.uiFont(11.5, weight: .medium)).foregroundStyle(theme.text.swiftUI)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.subtext.swiftUI)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.surface0.swiftUI))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.text.swiftUI.opacity(0.14), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func toggle(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) {
            Text(label).font(Theme.uiFont(11.5)).foregroundStyle(state.theme.text.swiftUI)
        }
        .toggleStyle(.checkbox)
        .tint(state.theme.accent.swiftUI)
    }
}
