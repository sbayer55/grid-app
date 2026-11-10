import SwiftUI

/// ⌘K. The round-1 design, made functional: fuzzy token filter, ↑↓ to move, ↩ to run.
struct CommandPaletteView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        let theme = state.theme
        let cmds = state.commands(matching: state.paletteQuery)
        let hi = min(state.paletteIndex, max(0, cmds.count - 1))
        ZStack {
            theme.crust.swiftUI.opacity(0.35)
                .background(VisualEffectView(material: .hudWindow).opacity(0.4))
                .ignoresSafeArea()
                .onTapGesture { state.togglePalette() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("❯").font(Theme.uiFont(16, weight: .bold)).foregroundStyle(theme.accent.swiftUI)
                    TextField("type a command…", text: $state.paletteQuery)
                        .textFieldStyle(.plain)
                        .font(Theme.uiFont(15, weight: .medium))
                        .foregroundStyle(theme.text.swiftUI)
                        .focused($focused)
                        .onSubmit { state.runPaletteCommand(at: hi) }
                        .onExitCommand { state.togglePalette() }
                        .onKeyPress(.downArrow) { state.paletteIndex = min(hi + 1, max(0, cmds.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { state.paletteIndex = max(0, hi - 1); return .handled }
                        .onChange(of: state.paletteQuery) { _, _ in state.paletteIndex = 0 }
                    KeyCap("esc")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)

                VStack(spacing: 2) {
                    ForEach(Array(cmds.enumerated()), id: \.element.id) { i, cmd in
                        let on = i == hi
                        HStack(spacing: 12) {
                            Circle().fill(on ? theme.accent.swiftUI : theme.surface1.swiftUI)
                                .frame(width: 8, height: 8)
                                .shadow(color: on ? theme.accent.swiftUI : .clear, radius: 6)
                            Text(cmd.group.uppercased()).font(Theme.uiFont(9.5)).tracking(0.8).foregroundStyle(theme.subtext.swiftUI).frame(width: 52, alignment: .leading)
                            Text(cmd.label).font(Theme.uiFont(13)).foregroundStyle(on ? theme.bright.swiftUI : theme.text.swiftUI)
                            Spacer()
                            if !cmd.shortcut.isEmpty { Text(cmd.shortcut).font(Theme.uiFont(11)).foregroundStyle(theme.subtext.swiftUI) }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? theme.accent.swiftUI.opacity(0.18) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? theme.accent.swiftUI.opacity(0.45) : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { state.runPaletteCommand(at: i) }
                        .onHover { if $0 { state.paletteIndex = i } }
                    }
                    if cmds.isEmpty {
                        Text("nothing matches — try \"sort\", \"pivot\", \"chart\", \"pin\", \"canvas\", \"zoom\"")
                            .font(Theme.uiFont(11)).foregroundStyle(theme.subtext.swiftUI)
                            .padding(12)
                    }
                }
                .padding(8)

                Rectangle().fill(theme.text.swiftUI.opacity(0.1)).frame(height: 1)
                HStack(spacing: 14) {
                    HStack(spacing: 4) { KeyCap("↑"); KeyCap("↓"); Text("move") }
                    HStack(spacing: 4) { KeyCap("↩"); Text("run") }
                    Spacer()
                    Text("\(cmds.count) commands")
                }
                .font(Theme.uiFont(11)).foregroundStyle(theme.subtext.swiftUI)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.mantle.swiftUI.opacity(0.94)))
            .background(VisualEffectView(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 14)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LinearGradient(colors: [theme.accent.swiftUI, theme.blue.swiftUI, theme.teal.swiftUI], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
            .shadow(color: theme.accent.swiftUI.opacity(0.25), radius: 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 150)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .onAppear { focused = true }
    }
}
