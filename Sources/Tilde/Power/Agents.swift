import AppKit
import SwiftUI

/// What a coding agent (Claude Code) in a pane is doing.
enum AgentState: String {
    case working, waiting, done, idle

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
    var color: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .working: return "circle.dotted"
        case .waiting: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }
}

/// Claude Code reports its state through hooks that write a small file per pane:
///   ~/Library/Caches/Tilde/agent/<TILDE_PANE_ID>  containing  "<state> <unix time>"
/// Without hooks, the spinner Claude Code puts in the window title is used instead.
enum AgentHooks {
    static let stateDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tilde/agent")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var scriptPath: String { (ShellIntegration.dir as NSString).appendingPathComponent("tilde-agent-hook") }
    static let marker = "tilde-agent-hook"

    static let script = """
    #!/bin/sh
    # Called by Claude Code hooks; records the agent state for the Tilde pane it runs in.
    [ -n "$TILDE_PANE_ID" ] || exit 0
    d="$HOME/Library/Caches/Tilde/agent"
    mkdir -p "$d" 2>/dev/null
    printf '%s %s\\n' "$1" "$(date +%s)" > "$d/$TILDE_PANE_ID" 2>/dev/null
    exit 0
    """

    static func installScript() {
        let p = scriptPath
        if (try? String(contentsOfFile: p, encoding: .utf8)) != script {
            try? script.write(toFile: p, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
    }

    static func state(for paneID: UUID) -> (AgentState, Date)? {
        guard let s = try? String(contentsOf: stateDir.appendingPathComponent(paneID.uuidString), encoding: .utf8) else { return nil }
        let parts = s.split(separator: " ")
        guard let first = parts.first, let st = AgentState(rawValue: String(first)) else { return nil }
        let t = parts.count > 1 ? Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        return (st, Date(timeIntervalSince1970: t))
    }

    static func clear(_ paneID: UUID) { try? FileManager.default.removeItem(at: stateDir.appendingPathComponent(paneID.uuidString)) }

    // MARK: Claude Code settings

    static var claudeSettingsURL: URL {
        // TILDE_CLAUDE_SETTINGS lets tests point this at a scratch file.
        if let p = ProcessInfo.processInfo.environment["TILDE_CLAUDE_SETTINGS"] { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    private static let events: [(String, String)] = [
        ("UserPromptSubmit", "working"), ("PreToolUse", "working"), ("PostToolUse", "working"),
        ("Notification", "waiting"), ("Stop", "done"), ("SessionEnd", "idle"),
    ]

    static var claudeInstalled: Bool {
        guard let d = try? Data(contentsOf: claudeSettingsURL), let s = String(data: d, encoding: .utf8) else { return false }
        return s.contains(marker)
    }

    /// Adds Tilde's hooks to ~/.claude/settings.json (keeps everything else; backs the file up first).
    static func installClaude() throws {
        installScript()
        var root = try readClaudeSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, state) in events {
            var list = (hooks[event] as? [[String: Any]] ?? []).filter { !mentionsMarker($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\"\(scriptPath)\" \(state)"]]]
            if event == "PreToolUse" || event == "PostToolUse" { entry["matcher"] = "*" }
            list.append(entry)
            hooks[event] = list
        }
        root["hooks"] = hooks
        try writeClaudeSettings(root)
    }

    /// Removes only Tilde's hooks.
    static func removeClaude() throws {
        var root = try readClaudeSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !mentionsMarker($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeClaudeSettings(root)
    }

    private static func mentionsMarker(_ entry: [String: Any]) -> Bool {
        let hs = entry["hooks"] as? [[String: Any]] ?? []
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func readClaudeSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: claudeSettingsURL.path) else { return [:] }
        let data = try Data(contentsOf: claudeSettingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Tilde", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object."])
        }
        return obj
    }

    private static func writeClaudeSettings(_ obj: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: claudeSettingsURL.path) {
            let backup = claudeSettingsURL.appendingPathExtension("tilde-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: claudeSettingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: claudeSettingsURL, options: .atomic)
    }
}

extension TerminalSession {
    /// Claude Code's title starts with a spinner (braille) while working and ✳ when idle.
    static func agentStateFromTitle(_ title: String?) -> AgentState? {
        guard let first = title?.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return nil }
        if (0x2800...0x28FF).contains(first.value) { return .working }
        if first == "✳" || first == "✻" || first == "✽" { return .idle }
        return nil
    }

    /// Title without the agent's spinner glyph.
    static func cleanTitle(_ t: String) -> String {
        var s = Substring(t.trimmingCharacters(in: .whitespaces))
        if let f = s.unicodeScalars.first, (0x2800...0x28FF).contains(f.value) || "✳✻✽·".unicodeScalars.contains(f) {
            s = s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension WorkspaceStore {
    /// Polls agent state for every live pane; raises attention when an agent needs you or finishes.
    func pollAgents() {
        var changed = false
        for (id, s) in TerminalRegistry.shared.sessions {
            var new: AgentState? = nil
            let agentRunning = s.foregroundProgram.map { $0 == "claude" || $0 == "node" || $0.hasPrefix("claude") } ?? false
            if let (st, at) = AgentHooks.state(for: id), agentRunning || Date().timeIntervalSince(at) < 5 {
                new = st == .idle ? nil : st
            } else if agentRunning, let st = TerminalSession.agentStateFromTitle(s.titleForAgent) {
                // Title fallback can't tell "done" from idle: idle after working counts as done.
                if st == .working { new = .working }
                else if s.agentState == .working || s.agentState == .done { new = .done }
                else if s.agentState == .waiting { new = .waiting }
            }
            if !agentRunning && new != .waiting && new != .done { new = nil }
            if new != s.agentState {
                let old = s.agentState
                s.agentState = new
                changed = true
                if (new == .waiting || new == .done) && old != new {
                    agentNeedsAttention(paneID: id, state: new!)
                }
            }
        }
        if changed { titleTick &+= 1 }
    }

    private func agentNeedsAttention(paneID: UUID, state: AgentState) {
        guard let t = orderedTabs.first(where: { $0.root.contains(paneID) }) else { return }
        let visible = NSApp.isActive && selectedHostID == nil && workspace.selectedTabID == t.id
        guard !visible else { return }
        attention.insert(t.id)
        Notifier.post(title: state == .waiting ? "Claude needs you" : "Claude finished",
                      body: displayTitle(t), tabID: t.id)
    }

    /// The most urgent agent state among a tab's panes.
    func agentState(_ tab: TerminalTab) -> AgentState? {
        let states = tab.root.allPanes.compactMap { TerminalRegistry.shared.existing($0.id)?.agentState }
        for s in [AgentState.waiting, .working, .done] where states.contains(s) { return s }
        return nil
    }
}

// MARK: - Settings section

struct AgentSettingsSection: View {
    @State private var installed = AgentHooks.claudeInstalled
    @State private var error: String?

    var body: some View {
        Section("Coding agents") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code status")
                    Text(installed ? "Hooks installed: tabs show Working / Needs you / Done exactly."
                                   : "Without hooks Tilde reads Claude's window title, which can't tell when it needs you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(installed ? "Remove" : "Set Up") {
                    do {
                        if installed { try AgentHooks.removeClaude() } else { try AgentHooks.installClaude() }
                        installed = AgentHooks.claudeInstalled
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Set Up adds a hook to ~/.claude/settings.json (a backup is saved next to it). Remove takes out only Tilde's entries.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
