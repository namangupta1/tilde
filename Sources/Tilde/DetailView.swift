import SwiftUI

struct DetailView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        if let hid = store.selectedHostID, let host = hostStore.host(hid) {
            HostDetailView(host: host, editing: $store.editingHost)
        } else if let tab = store.selectedTab {
            VStack(spacing: 0) {
                if store.isProduction(tab), let h = store.host(for: tab) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("PRODUCTION · \(h.name)").fontWeight(.semibold)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.85))
                }
                TabHeader(tab: tab)
                Divider()
                PaneTreeView(node: tab.root, tab: tab)
                    .background(Color(nsColor: theme.palette.background))
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No tab open").font(.title3)
                Button("New Tab  ⌘T") { store.newTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Name + notes for the current tab: the "context" you keep with a terminal.
struct TabHeader: View {
    let tab: TerminalTab
    @EnvironmentObject var store: WorkspaceStore
    @AppStorage("showNotes") private var showNotes = true
    @State private var title = ""
    @State private var notes = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let _ = store.titleTick
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(tab.color.color ?? Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                TextField(store.displayTitle(tab), text: $title)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(); NotificationCenter.default.post(name: .focusActiveTerminal, object: nil) }
                    .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
                    .help("Name this tab (⌘R)")
                Spacer()
                if tab.broadcast && tab.root.allPanes.count > 1 {
                    Button { store.toggleBroadcast() } label: {
                        Label("Typing into \(tab.root.allPanes.count) panes", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Broadcast input is on — click to stop (⌥⌘I)")
                }
                if let agent = store.agentState(tab) {
                    Label("Claude: \(agent.label)", systemImage: agent.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(agent.color)
                }
                if tab.zoomedPaneID != nil {
                    Button { store.toggleZoom() } label: {
                        Label("Zoomed", systemImage: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show all panes (⇧⌘↩)")
                }
                if let rec = TerminalRegistry.shared.existing(tab.activePaneID)?.lastFinished {
                    LastCommandBadge(record: rec)
                }
                if let h = store.host(for: tab) {
                    Button { store.selectHost(h.id) } label: {
                        HStack(spacing: 4) {
                            StatusDot(status: HostMonitor.shared.status(h.id), size: 6)
                            Text(h.target).font(.caption.monospaced())
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show host details")
                } else if let dir = TerminalRegistry.shared.existing(tab.activePaneID)?.currentDirectory {
                    Text(abbreviate(dir))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if showNotes {
                TextField("Notes — what is this tab for?", text: $notes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...4)
                    .onChange(of: notes) { _, n in if n != tab.notes { store.setNotes(tab.id, n) } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear(perform: sync)
        .onChange(of: tab.id) { _, _ in sync() }
        .onChange(of: tab.customTitle) { _, _ in if !titleFocused { title = tab.customTitle ?? "" } }
        .onReceive(NotificationCenter.default.publisher(for: .renameCurrentTab)) { _ in titleFocused = true }
    }

    private func sync() {
        title = tab.customTitle ?? ""
        notes = tab.notes
    }

    private func commitTitle() {
        if title != (tab.customTitle ?? "") { store.renameTab(tab.id, to: title) }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct LastCommandBadge: View {
    let record: CommandRecord

    var body: some View {
        let ok = record.exitCode == 0
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(record.command).lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .leading)
            Text(Notifier.format(record.duration ?? 0)).foregroundStyle(.tertiary)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .help("Last command" + (ok ? "" : " — exit \(record.exitCode.map(String.init) ?? "?")"))
    }
}

extension Notification.Name {
    static let renameCurrentTab = Notification.Name("TildeRenameCurrentTab")
}
