import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String = ""
    var icon: String
    var kind: String
    var shortcut: String = ""
    var tint: Color? = nil
    var action: @MainActor () -> Void
}

/// Subsequence fuzzy match with bonuses for word starts and contiguous runs. nil = no match.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0, prev: Character = " "
        for ch in t {
            if qi < q.count && ch == q[qi] {
                run += 1
                score += 1 + run * 2 + ((prev == " " || prev == "/" || prev == "-" || prev == ":" || prev == ".") ? 6 : 0)
                qi += 1
            } else {
                run = 0
            }
            prev = ch
        }
        guard qi == q.count else { return nil }
        return score - t.count / 8
    }
}

@MainActor
enum PaletteBuilder {
    static func items(store: WorkspaceStore, hosts: HostStore, snippets: SnippetStore, theme: ThemeManager) -> [PaletteItem] {
        var out: [PaletteItem] = []
        let session = store.activeSession

        // Actions
        let actions: [(String, String, String, @MainActor () -> Void)] = [
            ("New Tab", "plus.square", "⌘T", { store.newTab() }),
            ("New Folder", "folder.badge.plus", "⇧⌘N", { store.addFolder() }),
            ("Add Folder from Disk…", "folder", "⌘O", { store.addFolderFromDisk() }),
            ("Split Right", "rectangle.split.2x1", "⌘D", { store.split(.horizontal) }),
            ("Split Down", "rectangle.split.1x2", "⇧⌘D", { store.split(.vertical) }),
            ("Rename Tab", "pencil", "⌘R", { NotificationCenter.default.post(name: .renameCurrentTab, object: nil) }),
            ("Find in Scrollback", "magnifyingglass", "⌘F", { store.activeSession?.showFind() }),
            ("Jump to Tab Needing Attention", "bell.badge", "⌘J", { store.jumpToAttention() }),
            ("Previous Prompt", "arrow.up.to.line", "⌘↑", { store.activeSession?.jumpToPrompt(up: true) }),
            ("Next Prompt", "arrow.down.to.line", "⌘↓", { store.activeSession?.jumpToPrompt(up: false) }),
            ("Restart / Reconnect Pane", "arrow.clockwise", "⇧⌘R", { store.restartActivePane() }),
            ("New Host…", "server.rack", "⇧⌘H", { store.editingHost = Host.blank() }),
            ("Import Hosts from ~/.ssh/config", "square.and.arrow.down", "", { hosts.importSSHConfig(); HostMonitor.shared.refreshAll() }),
            ("Manage Snippets…", "text.badge.plus", "⌥⌘S", { store.showSnippets = true }),
            ("Manage Templates…", "square.grid.2x2", "", { store.showTemplates = true }),
            ("Save Folder as Template…", "square.and.arrow.down", "", {
                if let i = store.selectedFolderIndex { store.promptSaveTemplate(folderID: store.workspace.folders[i].id) } }),
            ("Run Command on Hosts…", "server.rack", "⌥⌘H", { store.showMultiRun = true }),
            ("Broadcast Input to All Panes (toggle)", "dot.radiowaves.left.and.right", "⌥⌘I", { store.toggleBroadcast() }),
            ("Export Transcript…", "doc.text", "⇧⌘E", { if let t = store.selectedTab { store.exportTranscript(t.id) } }),
            ("Quick Terminal", "menubar.dock.rectangle", QuickTerminal.enabled ? QuickTerminal.hotkey.label : "", { QuickTerminal.shared.toggle() }),
            ("Import iTerm2 Color Scheme…", "paintpalette", "", { ThemeImport.importScheme() }),
            ("Appearance: Light", "sun.max", "", { theme.modeRaw = AppearanceMode.light.rawValue }),
            ("Appearance: Dark", "moon", "", { theme.modeRaw = AppearanceMode.dark.rawValue }),
            ("Appearance: System", "circle.lefthalf.filled", "", { theme.modeRaw = AppearanceMode.system.rawValue }),
            ("Settings…", "gearshape", "⌘,", { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }),
        ]
        for (title, icon, key, act) in actions {
            out.append(PaletteItem(id: "action:" + title, title: title, icon: icon, kind: "Action", shortcut: key, action: act))
        }

        // Templates
        for t in TemplateStore.shared.templates {
            out.append(PaletteItem(id: "tpl:\(t.id)", title: "Open template: \(t.name)", subtitle: "\(t.tabs.count) tabs",
                                   icon: "square.grid.2x2", kind: "Template", action: { store.openTemplate(t) }))
        }

        // Tabs
        for f in store.workspace.folders {
            for t in f.tabs {
                let needs = store.attention.contains(t.id)
                out.append(PaletteItem(id: "tab:\(t.id)", title: store.displayTitle(t),
                                       subtitle: f.name + (t.notes.isEmpty ? "" : " — " + (t.notes.split(separator: "\n").first.map(String.init) ?? "")),
                                       icon: needs ? "bell.badge.fill" : "terminal", kind: "Tab",
                                       tint: needs ? .accentColor : t.color.color,
                                       action: { store.select(t.id) }))
            }
        }

        // Hosts
        for h in hosts.hosts {
            out.append(PaletteItem(id: "ssh:\(h.id)", title: "SSH: \(h.name)", subtitle: h.target, icon: "network", kind: "Host",
                                   tint: h.isProduction ? .red : nil, action: { store.openSSHTab(h.id) }))
            out.append(PaletteItem(id: "host:\(h.id)", title: "Host details: \(h.name)", subtitle: h.target, icon: "server.rack", kind: "Host",
                                   action: { store.selectHost(h.id) }))
            for c in h.commands {
                out.append(PaletteItem(id: "hostcmd:\(h.id):\(c.id)", title: "\(h.name): \(c.name)", subtitle: c.command,
                                       icon: "play.circle", kind: "Host command",
                                       action: { store.selectHost(h.id); HostMonitor.shared.run(c, on: h.id) }))
            }
        }

        // Snippets
        for s in snippets.available(folderID: store.activeFolderID, hostID: store.activeHostID) {
            out.append(PaletteItem(id: "snip:\(s.id)", title: s.name, subtitle: s.command, icon: "text.insert", kind: "Snippet",
                                   shortcut: s.runImmediately ? "runs" : "", action: { store.useSnippet(s) }))
        }

        // Recent commands in this pane (newest first, de-duplicated)
        if let session {
            var seen = Set<String>()
            for r in session.history.reversed() where r.finished && !r.command.isEmpty && !seen.contains(r.command) {
                seen.insert(r.command)
                let ok = r.exitCode == 0
                out.append(PaletteItem(id: "hist:\(r.id)", title: r.command,
                                       subtitle: "\(ok ? "✓" : "✗ exit \(r.exitCode.map(String.init) ?? "?")") · \(Notifier.format(r.duration ?? 0))",
                                       icon: "clock.arrow.circlepath", kind: "Recent", tint: ok ? nil : .red,
                                       action: { store.activeSession?.insert(r.command, run: false) }))
                out.append(PaletteItem(id: "save:\(r.id)", title: "Save as snippet: \(r.command)", icon: "square.and.arrow.down.on.square",
                                       kind: "Recent", action: {
                                           let name = String(r.command.prefix(40))
                                           SnippetStore.shared.add(Snippet(name: name, command: r.command))
                                           store.showSnippets = true
                                       }))
                if seen.count >= 25 { break }
            }
        }
        return out
    }
}

struct CommandPalette: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var hosts: HostStore
    @EnvironmentObject var snippets: SnippetStore
    @EnvironmentObject var theme: ThemeManager
    @State private var query = ""
    @State private var selected = 0
    @State private var all: [PaletteItem] = []
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty query: tabs needing attention, recent commands, then tabs, then actions.
            let order = ["Tab", "Recent", "Snippet", "Template", "Action", "Host", "Host command"]
            return all.filter { $0.kind != "Recent" || !$0.id.hasPrefix("save:") }
                .sorted { (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9) }
                .prefix(60).map { $0 }
        }
        return all.compactMap { item -> (PaletteItem, Int)? in
            guard let s = Fuzzy.score(query, item.title + " " + item.subtitle) else { return nil }
            let titleBonus = Fuzzy.score(query, item.title) != nil ? 20 : 0
            return (item, s + titleBonus)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(60).map { $0.0 }
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tabs, hosts, snippets, recent commands, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            let i = items.firstIndex { $0.id == item.id } ?? 0
                            row(item, isSelected: i == selected)
                                .onTapGesture { selected = i; run(items) }
                        }
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, s in
                    if items.indices.contains(s) { proxy.scrollTo(items[s].id) }
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear {
            all = PaletteBuilder.items(store: store, hosts: hosts, snippets: snippets, theme: theme)
            focused = true
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(item.tint ?? .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(item.kind).font(.caption2).foregroundStyle(.tertiary).frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        close()
        DispatchQueue.main.async { item.action() }
    }

    private func close() {
        store.showPalette = false
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusActiveTerminal, object: nil) }
    }
}
