import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @AppStorage("notifyLongCommands") private var notify = true
    @AppStorage("notifyThreshold") private var threshold = 10.0
    @AppStorage("shellIntegration") private var integration = true
    @AppStorage(PersistentSessions.defaultsKey) private var keepSessions = true
    @AppStorage(QuickTerminal.enabledKey) private var quickEnabled = true
    @AppStorage(QuickTerminal.hotkeyKey) private var quickHotkey = QuickHotkey.ctrlGrave.rawValue

    var body: some View {
        Form {
            Section("Commands & notifications") {
                Toggle("Shell integration (zsh): prompt marks, exit codes, command history", isOn: $integration)
                Text("Applies to new tabs. Your own ~/.zshrc still loads as usual.").font(.caption).foregroundStyle(.secondary)
                Toggle("Notify when a long command finishes in a tab you're not looking at", isOn: $notify)
                Stepper(value: $threshold, in: 3...600, step: threshold < 30 ? 1 : 10) {
                    Text("Long command: \(Int(threshold))s or more")
                }
                .disabled(!notify)
            }
            Section("Sessions") {
                Toggle("Keep shells running after quitting Tilde", isOn: $keepSessions)
                Text("Reopening Tilde reconnects every tab with its scrollback, running programs and SSH sessions. Use Tilde ▸ Quit and End All Shells (⌥⌘Q) to stop them. Applies to new tabs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quick terminal") {
                Toggle("Drop-down terminal from any app", isOn: $quickEnabled)
                Picker("Hotkey", selection: $quickHotkey) {
                    ForEach(QuickHotkey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .disabled(!quickEnabled)
            }
            .onChange(of: quickEnabled) { _, _ in QuickTerminal.shared.start() }
            .onChange(of: quickHotkey) { _, _ in QuickTerminal.shared.start() }
            Section("Appearance") {
            Picker("Appearance", selection: $theme.modeRaw) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Font") {
                Text("SF Mono (system monospaced)").foregroundStyle(.secondary)
            }
            HStack {
                Slider(value: $theme.fontSize, in: 9...28, step: 1) { Text("Font size") }
                Text("\(Int(theme.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            LabeledContent("Dark colours") { paletteControls(dark: true) }
            LabeledContent("Light colours") { paletteControls(dark: false) }
            Text("The quick brown fox — ls -la ~/projects")
                .font(Font(theme.font))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: theme.palette.background))
                .foregroundStyle(Color(nsColor: theme.palette.foreground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    @ViewBuilder
    private func paletteControls(dark: Bool) -> some View {
        let _ = theme.modeRaw
        HStack {
            Text(ThemeImport.stored(dark: dark)?.name ?? "Tilde default").foregroundStyle(.secondary)
            if ThemeImport.stored(dark: dark) != nil {
                Button("Reset") { ThemeImport.reset(dark: dark) }
            }
            Button("Import iTerm2…") { ThemeImport.importScheme() }
        }
    }
}
