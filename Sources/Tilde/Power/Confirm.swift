import AppKit

/// Confirmation prompts for destructive actions.
@MainActor
enum Confirm {
    /// Shows a warning alert; returns true when the user picks the destructive button.
    /// The destructive button is not the default, so Return cancels.
    static func ask(_ title: String, _ message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: confirm)
        ok.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        ok.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

extension WorkspaceStore {
    /// Commands still running in a tab's panes (shell integration, else a non-shell foreground program).
    /// An SSH pane's foreground program is always `ssh`, so only its reported command counts.
    func busyCommands(in tab: TerminalTab) -> [String] {
        tab.root.allPanes.compactMap { p in
            guard let s = TerminalRegistry.shared.existing(p.id), !s.exited else { return nil }
            if let c = s.runningCommand?.command, !c.isEmpty { return c }
            if case .ssh = p.connection { return nil }
            return s.foregroundProgram
        }
    }

    /// Closes the tab, asking first when something is still running in it (⇧⌘T can reopen it).
    func closeTabConfirmingIfBusy(_ id: UUID) {
        guard let t = tab(id) else { return }
        let busy = busyCommands(in: t)
        if !busy.isEmpty {
            let list = busy.prefix(3).map { "• \($0.count > 60 ? String($0.prefix(57)) + "…" : $0)" }.joined(separator: "\n")
            guard Confirm.ask("Close “\(displayTitle(t))”?",
                              "Still running:\n\(list)\n\nClosing ends these processes.",
                              confirm: "Close Tab") else { return }
        }
        closeTab(id)
    }

    /// Deletes a folder (and its subfolders) after confirming; their tabs can be reopened with ⇧⌘T.
    func deleteFolderConfirming(_ id: UUID) {
        guard let f = workspace.folders.first(where: { $0.id == id }) else { return }
        let subtree = workspace.folders.filter { folderAndDescendantIDs(id).contains($0.id) }
        let tabs = subtree.flatMap(\.tabs)
        let subs = subtree.count - 1
        var parts: [String] = []
        if subs > 0 { parts.append(Confirm.plural(subs, "subfolder")) }
        parts.append(Confirm.plural(tabs.count, "tab"))
        let busy = tabs.flatMap { busyCommands(in: $0) }
        let running = busy.isEmpty ? "" : "\n\n\(Confirm.plural(busy.count, "command")) still running will be ended."
        guard Confirm.ask("Delete “\(f.name)”?",
                          "This removes the folder, \(parts.joined(separator: " and ")) and closes their shells. "
                          + "Closed tabs can be reopened with ⇧⌘T." + running,
                          confirm: "Delete") else { return }
        deleteFolder(id)
    }
}
