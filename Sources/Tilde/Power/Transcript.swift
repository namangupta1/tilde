import AppKit
import UniformTypeIdentifiers

extension WorkspaceStore {
    /// Saves a tab's scrollback (every pane) plus its command history as Markdown.
    func exportTranscript(_ tabID: UUID) {
        guard let tab = tab(tabID) else { return }
        let md = Transcript.markdown(tab: tab, title: displayTitle(tab))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let stamp = Transcript.fileStamp.string(from: Date())
        panel.nameFieldStringValue = "\(Transcript.safeName(displayTitle(tab))) \(stamp).md"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
enum Transcript {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    static func markdown(tab: TerminalTab, title: String) -> String {
        var out = "# \(title)\n\n"
        out += "_Exported from Tilde on \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))_\n\n"
        if !tab.notes.isEmpty { out += "> " + tab.notes.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" }
        let panes = tab.root.allPanes
        for (i, pane) in panes.enumerated() {
            guard let s = TerminalRegistry.shared.existing(pane.id) else { continue }
            if panes.count > 1 { out += "## Pane \(i + 1)" + (s.currentDirectory.map { " — `\($0)`" } ?? "") + "\n\n" }
            let finished = s.history.filter(\.finished)
            if !finished.isEmpty {
                out += "### Commands\n\n| | Command | Took |\n|---|---|---|\n"
                for r in finished {
                    let mark = r.exitCode == 0 ? "✓" : "✗ \(r.exitCode.map(String.init) ?? "")"
                    let cmd = r.command.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
                    out += "| \(mark) | `\(cmd)` | \(Notifier.format(r.duration ?? 0)) |\n"
                }
                out += "\n### Output\n\n"
            }
            out += "```text\n" + text(of: s) + "\n```\n\n"
        }
        return out
    }

    /// Scrollback + screen of the normal buffer, trailing blank lines removed.
    static func text(of s: TerminalSession) -> String {
        let data = s.view.getBufferAsData(kind: .normal)
        var lines = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { line -> String in
                var l = line
                while l.last == " " { l.removeLast() }
                return l
            }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // Keep the code fence intact.
        return lines.joined(separator: "\n").replacingOccurrences(of: "```", with: "ʼʼʼ")
    }
}
