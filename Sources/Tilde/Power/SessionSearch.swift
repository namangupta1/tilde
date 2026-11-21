import SwiftUI

/// ⇧⌘F: searches the scrollback of every open pane.
struct SessionSearchView: View {
    @EnvironmentObject var store: WorkspaceStore
    let onClose: () -> Void

    struct Hit: Identifiable {
        let id = UUID()
        var tabID: UUID
        var paneID: UUID
        var tabTitle: String
        var line: String
        var lineNumber: Int
    }

    @State private var query = ""
    @State private var caseSensitive = false
    @State private var regex = false
    @State private var hits: [Hit] = []
    @State private var searched = false
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search output in all open tabs", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    // ↑/↓ pick a match, Return opens it (searches first if nothing is listed yet).
                    .onSubmit { if hits.indices.contains(selected) { open(hits[selected]) } else { search() } }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(hits.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .task(id: query) {
                        // Search as you type, after a short pause.
                        try? await Task.sleep(for: .milliseconds(query.count < 3 ? 400 : 200))
                        if !Task.isCancelled { search() }
                    }
                Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button).help("Match case")
                Toggle(".*", isOn: $regex).toggleStyle(.button).help("Regular expression")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                            Button { open(h) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(h.tabTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .frame(width: 120, alignment: .leading).lineLimit(1)
                                        .help(h.tabTitle)
                                    Text(h.line).font(.system(.callout, design: .monospaced)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == selected ? Color.accentColor.opacity(0.22) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(h.id)
                            .onHover { if $0 { selected = i } }
                        }
                    }
                }
                .onChange(of: selected) { _, s in if hits.indices.contains(s) { proxy.scrollTo(hits[s].id) } }
            }
            .frame(height: 320)
            .overlay {
                if hits.isEmpty {
                    Text(searched ? "No matches in open tabs" : "Type to search every pane's scrollback (tabs not opened since launch aren't loaded yet).")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            HStack {
                if !hits.isEmpty { Text("\(hits.count)\(hits.count >= 500 ? "+" : "") matches").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 680)
        .onAppear { focused = true }
        .onChange(of: caseSensitive) { _, _ in search() }
        .onChange(of: regex) { _, _ in search() }
    }

    private func search() {
        let q = query
        guard !q.isEmpty else { hits = []; searched = false; return }
        let re: NSRegularExpression? = regex ? try? NSRegularExpression(pattern: q, options: caseSensitive ? [] : [.caseInsensitive]) : nil
        if regex && re == nil { hits = []; searched = true; return }
        var out: [Hit] = []
        outer: for t in store.orderedTabs {
            for p in t.root.allPanes {
                guard let s = TerminalRegistry.shared.existing(p.id) else { continue }
                let text = String(decoding: s.view.getBufferAsData(kind: .normal), as: UTF8.self)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let matched: Bool
                    if let re { matched = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
                    else { matched = line.range(of: q, options: caseSensitive ? [] : [.caseInsensitive]) != nil }
                    if matched {
                        out.append(Hit(tabID: t.id, paneID: p.id, tabTitle: store.displayTitle(t),
                                       line: line.trimmingCharacters(in: .whitespaces), lineNumber: i))
                        if out.count >= 500 { break outer }
                    }
                }
            }
        }
        hits = out
        selected = 0
        searched = true
    }

    private func open(_ h: Hit) {
        onClose()
        store.select(h.tabID)
        store.setActivePane(h.paneID, inTab: h.tabID)
        // Pre-fill the find bar through the shared find pasteboard, then jump to the match.
        let pb = NSPasteboard(name: .find)
        pb.clearContents()
        pb.setString(regex ? h.line : query, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let s = TerminalRegistry.shared.existing(h.paneID) else { return }
            s.showFind()
            s.findPrevious()
        }
    }
}

/// ⌘/: every shortcut on one sheet.
struct ShortcutsView: View {
    let onClose: () -> Void

    /// Keep in step with the menu bindings in TildeApp.swift.
    private var groups: [(String, [(String, String)])] { [
        ("Tabs & folders", [("⌘T", "New tab"), ("⌥⌘T", "New tab in a git worktree"), ("⇧⌘N", "New folder"), ("⌥⇧⌘N", "New subfolder"), ("⌘O", "Add folder from disk"),
                            ("⌘R", "Rename tab"), ("⇧⌘I", "Toggle notes"), ("⌘1–9", "Go to tab"), ("⇧⌘[ / ⇧⌘]", "Previous / next tab"),
                            ("⌃⇧⌘[ / ⌃⇧⌘]", "Move tab up / down"), ("⇧⌘T", "Reopen closed tab"), ("⌥⌘W", "Close tab"), ("⌃⌘S", "Show / hide sidebar")]),
        ("Panes", [("⌘D / ⇧⌘D", "Split right / down"), ("⌘W", "Close pane"), ("⌘[ / ⌘]", "Previous / next pane"),
                   ("⌥⌘ arrows", "Move focus between panes"), ("⇧⌘↩", "Zoom pane"), ("⌃⌘=", "Equalize panes"),
                   ("⌥⌘I", "Broadcast input to all panes"), ("⇧⌘R", "Restart / reconnect pane")]),
        ("Output", [("⌘F / ⌘G / ⇧⌘G", "Find, next, previous"), ("⇧⌘F", "Search all sessions"), ("⇧⌘↑ / ⇧⌘↓", "Previous / next prompt"),
                    ("⇧⌘C", "Copy last command output"), ("⇧⌘O", "Open selected file in editor"), ("⌥⌘V", "Paste image as file path"),
                    ("⌘L / ⌥⌘K", "Clear screen / scrollback"), ("⇧⌘E", "Export transcript")]),
        ("Go", [("⌘K", "Command palette"), ("⌘J", "Next tab needing you"), ("⌥⌘S", "Snippets"),
                ("⌥⌘H", "Run command on hosts"), ("⇧⌘H", "New host"), (QuickTerminal.hotkey.label, "Quick terminal from any app (set in Settings)")]),
        ("App", [("⌘= / ⌘- / ⌘0", "Text size"), ("⌘,", "Settings"), ("⌥⌘Q", "Quit and end all shells"), ("⌘/", "This list")]),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
                    ForEach(groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.0).font(.subheadline.weight(.semibold))
                            ForEach(g.1, id: \.0) { k, v in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(k).font(.callout.monospaced()).frame(width: 120, alignment: .leading)
                                    Text(v).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 680, height: 520)
        .onExitCommand(perform: onClose)
    }
}
