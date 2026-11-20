import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { store.selectedHostID ?? store.workspace.selectedTabID },
                set: { id in
                    guard let id else { return }
                    if hostStore.host(id) != nil { store.selectHost(id) } else { store.select(id) }
                }
            )) {
                ForEach(store.workspace.folders) { folder in
                    FolderSection(folder: folder)
                }
                .onMove { store.moveFolders(from: $0, to: $1) }
                HostsSection(editing: $store.editingHost)
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Menu {
                    Button("New Empty Folder") { store.addFolder() }
                    Button("Add Folder from Disk…") { store.addFolderFromDisk() }
                    TemplatesMenu(store: store)
                    Divider()
                    Button("New Host…") { store.editingHost = Host.blank() }
                    Button("Import Hosts from ~/.ssh/config") { hostStore.importSSHConfig(); HostMonitor.shared.refreshAll() }
                } label: {
                    Label("New", systemImage: "plus.rectangle.on.folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button { store.newTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Tab (⌘T)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct FolderSection: View {
    let folder: Folder
    @EnvironmentObject var store: WorkspaceStore
    @State private var hovering = false
    @State private var isTargeted = false

    var body: some View {
        Section(isExpanded: Binding(
            get: { folder.isExpanded },
            set: { _ in store.toggleFolder(folder.id) }
        )) {
            ForEach(folder.tabs) { tab in
                TabRow(tab: tab)
                    .tag(tab.id)
                    .draggable(tab.id.uuidString)
            }
            .onMove { from, to in
                guard let first = from.first else { return }
                store.moveTab(folder.tabs[first].id, toFolder: folder.id, at: to)
            }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.directory == nil ? "folder" : "folder.fill")
                .foregroundStyle(.secondary)
            if store.renamingFolderID == folder.id {
                InlineRenameField(initial: folder.name) { name in
                    if let name { store.renameFolder(folder.id, to: name) } else { store.renamingFolderID = nil }
                }
            } else {
                Text(folder.name)
                    .lineLimit(1)
                    .help(folder.directory ?? "No default directory")
                    .onTapGesture(count: 2) { store.renamingFolderID = folder.id }
            }
            Spacer(minLength: 0)
            if hovering {
                Button { store.newTab(inFolder: folder.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New tab in \(folder.name)")
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(isTargeted ? 0.2 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s) else { return false }
            store.moveTab(id, toFolder: folder.id)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("New Tab") { store.newTab(inFolder: folder.id) }
            Divider()
            Button("Rename Folder") { store.renamingFolderID = folder.id }
            Button("Set Default Directory…") { store.chooseDirectory(forFolder: folder.id) }
            Button("Save as Template…") { store.promptSaveTemplate(folderID: folder.id) }
            if let d = folder.directory {
                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: d) }
            }
            Divider()
            Button("Delete Folder and Close Its Tabs", role: .destructive) { store.deleteFolder(folder.id) }
        }
    }
}

struct TabRow: View {
    let tab: TerminalTab
    @EnvironmentObject var store: WorkspaceStore
    @State private var hovering = false

    var body: some View {
        let _ = store.titleTick   // re-render on live title changes
        let prod = store.isProduction(tab)
        let remote = tab.root.allPanes.contains { if case .ssh = $0.connection { return true }; return false }
        let needsYou = store.attention.contains(tab.id)
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tab.color.color ?? (prod ? .red : Color.secondary.opacity(0.35)))
                    .frame(width: 7, height: 7)
                if needsYou {
                    Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
            .frame(width: 12, height: 12)
            .help(needsYou ? "Needs attention (⌘J)" : "")
            VStack(alignment: .leading, spacing: 1) {
                if store.renamingTabID == tab.id {
                    InlineRenameField(initial: tab.customTitle ?? store.displayTitle(tab)) { name in
                        if let name { store.renameTab(tab.id, to: name) } else { store.renamingTabID = nil }
                        NotificationCenter.default.post(name: .focusActiveTerminal, object: nil)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(store.displayTitle(tab))
                            .lineLimit(1)
                            .fontWeight(needsYou ? .bold : (tab.customTitle != nil ? .medium : .regular))
                        if remote {
                            Image(systemName: "network").font(.caption2).foregroundStyle(.secondary)
                        }
                        if prod { ProdBadge() }
                        if tab.root.allPanes.count > 1 {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let line = tab.notes.split(separator: "\n").first, !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hovering {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Explicit select: List's own click-selection is swallowed by .draggable / double-tap on macOS.
        .simultaneousGesture(TapGesture(count: 1).onEnded { store.select(tab.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingTabID = tab.id })
        .help(tab.notes.isEmpty ? store.displayTitle(tab) : tab.notes)
        .contextMenu {
            Button("Rename…") { store.renamingTabID = tab.id }
            if tab.customTitle != nil {
                Button("Reset to Automatic Name") { store.renameTab(tab.id, to: "") }
            }
            Menu("Color") {
                ForEach(TabColor.allCases) { c in
                    Button { store.setColor(tab.id, c) } label: {
                        if c == tab.color { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                    }
                }
            }
            Menu("Move to Folder") {
                ForEach(store.workspace.folders) { f in
                    Button(f.name) { store.moveTab(tab.id, toFolder: f.id) }
                }
            }
            Button("Duplicate Tab") { store.duplicateTab(tab.id) }
            Divider()
            Button("Close Tab", role: .destructive) { store.closeTab(tab.id) }
        }
    }
}

/// TextField that grabs focus, commits on Return / focus loss, cancels on Escape.
struct InlineRenameField: View {
    let initial: String
    /// Called with the new text, or nil when cancelled.
    let commit: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var done = false

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, f in if !f { finish(text) } }
    }

    private func finish(_ value: String?) {
        guard !done else { return }
        done = true
        commit(value)
    }
}

/// "New Folder from Template" submenu.
struct TemplatesMenu: View {
    /// Passed explicitly: menu-bar commands have no environment objects.
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var templates = TemplateStore.shared

    var body: some View {
        Menu("New Folder from Template") {
            ForEach(templates.templates) { t in
                Button(t.name) { store.openTemplate(t) }
            }
            if !templates.templates.isEmpty { Divider() }
            Button("Manage Templates…") { store.showTemplates = true }
        }
    }
}
