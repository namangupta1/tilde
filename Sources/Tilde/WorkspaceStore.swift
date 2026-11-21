import AppKit
import Combine
import SwiftUI

/// Single source of truth for folders/tabs/panes. Persists to Application Support as JSON.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspace: Workspace { didSet { scheduleSave() } }
    /// Bumped when a live session's auto title changes, so the sidebar re-renders.
    @Published var titleTick = 0
    /// Tab currently being renamed inline in the sidebar.
    @Published var renamingTabID: UUID?
    @Published var renamingFolderID: UUID?
    /// When set, the detail area shows this host instead of the selected tab.
    @Published var selectedHostID: UUID?
    /// Host being added/edited in the sheet.
    @Published var editingHost: Host?
    /// Tabs that need the user (long command finished, bell, notification) — cleared on view.
    @Published var attention: Set<UUID> = [] { didSet { updateDockBadge() } }
    @Published var showPalette = false
    @Published var showSnippets = false
    @Published var showTemplates = false
    @Published var showDetached = false
    @Published var showSessionSearch = false
    @Published var showShortcuts = false
    @Published var showMultiRun = false
    /// Short message shown at the bottom of the window (e.g. upload progress).
    @Published var toast: String?
    /// Snippet waiting for placeholder values before insertion.
    @Published var pendingSnippet: PendingSnippet?

    private var saveWork: DispatchWorkItem?
    private var pollTimer: Timer?

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workspace.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let ws = try? JSONDecoder().decode(Workspace.self, from: data), !ws.folders.isEmpty {
            workspace = ws
        } else {
            var ws = Workspace()
            var folder = Folder(name: "Home", directory: NSHomeDirectory())
            let tab = TerminalTab(directory: NSHomeDirectory())
            folder.tabs = [tab]
            ws.folders = [folder]
            ws.selectedTabID = tab.id
            workspace = ws
        }
        if selectedTab == nil { workspace.selectedTabID = workspace.folders.first?.tabs.first?.id }
        startPolling()
    }

    // MARK: Lookup

    var selectedTab: TerminalTab? {
        guard let id = workspace.selectedTabID else { return nil }
        return tab(id)
    }

    func tab(_ id: UUID) -> TerminalTab? {
        for f in workspace.folders { if let t = f.tabs.first(where: { $0.id == id }) { return t } }
        return nil
    }

    func folderIndex(containingTab id: UUID) -> Int? {
        workspace.folders.firstIndex { $0.tabs.contains { $0.id == id } }
    }

    var selectedFolderIndex: Int? {
        if let id = workspace.selectedTabID, let i = folderIndex(containingTab: id) { return i }
        return workspace.folders.isEmpty ? nil : 0
    }

    /// Flat tab order as displayed in the sidebar (used for ⌘1–9 and next/prev).
    var orderedTabs: [TerminalTab] { displayOrderedFolders.flatMap { $0.tabs } }

    // MARK: Folder tree (logic lives on Workspace; see Models.swift)

    func childFolders(of parentID: UUID?) -> [Folder] { workspace.childFolders(of: parentID) }
    var displayOrderedFolders: [Folder] { workspace.displayOrderedFolders }
    func folderAndDescendantIDs(_ id: UUID) -> Set<UUID> { workspace.folderAndDescendantIDs(id) }
    func folderPath(_ id: UUID) -> String { workspace.folderPath(id) }

    func displayTitle(_ tab: TerminalTab) -> String {
        if let c = tab.customTitle, !c.isEmpty { return c }
        if let s = TerminalRegistry.shared.existing(tab.activePaneID) { return s.autoTitle }
        if let h = host(for: tab) { return h.name }
        if let d = tab.root.allPanes.first?.lastDirectory {
            return d == NSHomeDirectory() ? "~" : (d as NSString).lastPathComponent
        }
        return "Terminal"
    }

    static var closedTabs: [ClosedTab] = []

    func mutateTab(_ id: UUID, _ change: (inout TerminalTab) -> Void) {
        guard let fi = folderIndex(containingTab: id),
              let ti = workspace.folders[fi].tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&workspace.folders[fi].tabs[ti])
    }

    // MARK: Folders

    func addFolder(name: String = "New Folder", directory: String? = nil) {
        var f = Folder(name: name, directory: directory)
        let tab = TerminalTab(directory: directory)
        f.tabs = [tab]
        workspace.folders.append(f)
        workspace.selectedTabID = tab.id
        renamingFolderID = directory == nil ? f.id : nil
    }

    /// Creates a folder nested inside `parentID` (inherits its default directory) and starts renaming it.
    func addSubfolder(in parentID: UUID, name: String = "New Folder") {
        guard let parent = workspace.folders.first(where: { $0.id == parentID }) else { return }
        var f = Folder(name: name, directory: parent.directory)
        let tab = TerminalTab(directory: parent.directory)
        f.tabs = [tab]
        guard workspace.insertSubfolder(f, in: parentID) else { return }
        workspace.selectedTabID = tab.id
        renamingFolderID = f.id
    }

    /// New subfolder in the folder of the selected tab (top-level folder when nothing is selected).
    func addSubfolderToSelected() {
        if let i = selectedFolderIndex { addSubfolder(in: workspace.folders[i].id) } else { addFolder() }
    }

    /// Re-parents a folder (nil = top level). Refuses to move a folder into itself or its own subfolders.
    func moveFolder(_ id: UUID, toParent parentID: UUID?) {
        workspace.reparentFolder(id, to: parentID)
    }

    /// Opens a folder picker and creates a folder rooted at the chosen directory.
    func addFolderFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(name: url.lastPathComponent, directory: url.path)
    }

    func chooseDirectory(forFolder id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Set Directory"
        guard panel.runModal() == .OK, let url = panel.url,
              let i = workspace.folders.firstIndex(where: { $0.id == id }) else { return }
        workspace.folders[i].directory = url.path
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = workspace.folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { workspace.folders[i].name = trimmed }
        renamingFolderID = nil
    }

    func toggleFolder(_ id: UUID) {
        guard let i = workspace.folders.firstIndex(where: { $0.id == id }) else { return }
        workspace.folders[i].isExpanded.toggle()
    }

    /// Deletes the folder, its subfolders, and closes all their tabs.
    func deleteFolder(_ id: UUID) {
        var ws = workspace
        let removed = ws.removeFolderTree(id)
        guard !removed.isEmpty else { return }
        for f in removed { for t in f.tabs { for p in t.root.allPanes { TerminalRegistry.shared.close(p.id) } } }
        let removedSelection = removed.contains { $0.tabs.contains { $0.id == ws.selectedTabID } }
        workspace = ws
        if removedSelection { workspace.selectedTabID = orderedTabs.first?.id }
    }

    /// Reorders the children of `parentID`; offsets refer to `childFolders(of: parentID)`.
    func moveFolders(parent parentID: UUID? = nil, from source: IndexSet, to destination: Int) {
        workspace.reorderChildren(of: parentID, from: source, to: destination)
    }

    // MARK: Tabs

    func newTab(inFolder folderID: UUID? = nil) {
        let fi: Int
        if let folderID, let i = workspace.folders.firstIndex(where: { $0.id == folderID }) {
            fi = i
        } else if let i = selectedFolderIndex {
            fi = i
        } else {
            addFolder(name: "Home", directory: NSHomeDirectory())
            return
        }
        // New tab inherits the current tab's cwd when in the same folder, else the folder's directory.
        var dir = workspace.folders[fi].directory
        if folderID == nil, let sel = selectedTab, let s = TerminalRegistry.shared.existing(sel.activePaneID) {
            dir = s.currentDirectory ?? dir
        }
        let tab = TerminalTab(directory: dir)
        workspace.folders[fi].tabs.append(tab)
        workspace.folders[fi].isExpanded = true
        workspace.selectedTabID = tab.id
    }

    func select(_ tabID: UUID) {
        selectedHostID = nil
        workspace.selectedTabID = tabID
        attention.remove(tabID)
    }

    // MARK: Attention

    private func tabID(forPane paneID: UUID) -> UUID? {
        orderedTabs.first { $0.root.contains(paneID) }?.id
    }

    /// Whether the user is currently looking at this tab.
    private func isVisible(_ tabID: UUID) -> Bool {
        NSApp.isActive && selectedHostID == nil && workspace.selectedTabID == tabID
            && (NSApp.keyWindow?.isVisible ?? false) && !(NSApp.keyWindow?.isMiniaturized ?? true)
    }

    func commandFinished(paneID: UUID, record: CommandRecord) {
        titleTick &+= 1
        guard let tid = tabID(forPane: paneID), let tab = tab(tid),
              let d = record.duration, d >= Notifier.threshold, !isVisible(tid) else { return }
        attention.insert(tid)
        let ok = record.exitCode == 0
        let cmd = record.command.count > 60 ? String(record.command.prefix(57)) + "…" : record.command
        Notifier.post(title: (ok ? "✓ " : "✗ ") + cmd,
                      body: "\(displayTitle(tab)) · \(Notifier.format(d))" + (ok ? "" : " · exit \(record.exitCode.map(String.init) ?? "?")"),
                      tabID: tid)
    }

    func paneWantsAttention(paneID: UUID, title: String, body: String?) {
        guard let tid = tabID(forPane: paneID), let tab = tab(tid), !isVisible(tid) else { return }
        attention.insert(tid)
        if title == "Bell" {
            Notifier.post(title: "🔔 \(displayTitle(tab))", body: "Bell in \(displayTitle(tab))", tabID: tid)
        } else {
            Notifier.post(title: title, body: body ?? displayTitle(tab), tabID: tid)
        }
    }

    /// ⌘J — next tab that needs attention (wraps around).
    func jumpToAttention() {
        let tabs = orderedTabs
        guard !attention.isEmpty, !tabs.isEmpty else { NSSound.beep(); return }
        let cur = tabs.firstIndex { $0.id == workspace.selectedTabID } ?? -1
        for k in 1...tabs.count {
            let t = tabs[(cur + k + tabs.count) % tabs.count]
            if attention.contains(t.id) { select(t.id); return }
        }
    }

    func appBecameActive() {
        if let id = workspace.selectedTabID, selectedHostID == nil { attention.remove(id) }
    }

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = attention.isEmpty ? nil : String(attention.count)
    }

    // MARK: Active session helpers

    var activeSession: TerminalSession? {
        guard selectedHostID == nil, let t = selectedTab else { return nil }
        return TerminalRegistry.shared.existing(t.activePaneID)
    }

    func selectHost(_ id: UUID) { selectedHostID = id }

    /// Host the tab is connected to (via its active pane, else any pane).
    func host(for tab: TerminalTab) -> Host? {
        let panes = tab.root.allPanes
        let conn = panes.first(where: { $0.id == tab.activePaneID })?.connection ?? panes.compactMap(\.connection).first
        return conn.flatMap { HostStore.shared.host($0.hostID) }
    }

    func isProduction(_ tab: TerminalTab) -> Bool {
        tab.root.allPanes.contains { p in p.connection.flatMap { HostStore.shared.host($0.hostID)?.isProduction } ?? false }
    }

    // MARK: Hosts → tabs

    /// Opens an SSH tab (reuses the shared connection when one is alive).
    func openSSHTab(_ hostID: UUID) { openHostTab(.ssh(hostID: hostID)) }

    /// Opens a local shell with the host's environment variables exported.
    func openEnvShell(_ hostID: UUID) { openHostTab(.localEnv(hostID: hostID)) }

    private func openHostTab(_ conn: PaneConnection) {
        guard let host = HostStore.shared.host(conn.hostID) else { return }
        if workspace.folders.isEmpty { workspace.folders.append(Folder(name: "Home", directory: NSHomeDirectory())) }
        let fi = selectedFolderIndex ?? 0
        let dir: String? = { if case .localEnv = conn { return workspace.folders[fi].directory }; return nil }()
        var tab = TerminalTab(directory: dir, connection: conn)
        if host.isProduction { tab.color = .red }
        if case .localEnv = conn { tab.customTitle = "\(host.name) env" }
        workspace.folders[fi].tabs.append(tab)
        workspace.folders[fi].isExpanded = true
        select(tab.id)
    }

    func renameTab(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        mutateTab(id) { $0.customTitle = trimmed.isEmpty ? nil : trimmed }
        renamingTabID = nil
    }

    func setNotes(_ id: UUID, _ notes: String) { mutateTab(id) { $0.notes = notes } }
    func setColor(_ id: UUID, _ color: TabColor) { mutateTab(id) { $0.color = color } }

    func closeTab(_ id: UUID) {
        attention.remove(id)
        guard let fi = folderIndex(containingTab: id),
              let ti = workspace.folders[fi].tabs.firstIndex(where: { $0.id == id }) else { return }
        let ordered = orderedTabs
        let flatIndex = ordered.firstIndex { $0.id == id } ?? 0
        rememberClosed(workspace.folders[fi].tabs[ti], folderID: workspace.folders[fi].id, index: ti)
        for p in workspace.folders[fi].tabs[ti].root.allPanes { TerminalRegistry.shared.close(p.id) }
        workspace.folders[fi].tabs.remove(at: ti)
        if workspace.selectedTabID == id {
            let remaining = orderedTabs
            workspace.selectedTabID = remaining.isEmpty ? nil : remaining[min(flatIndex, remaining.count - 1)].id
        }
    }

    func duplicateTab(_ id: UUID) {
        guard let t = tab(id), let fi = folderIndex(containingTab: id) else { return }
        let dir = TerminalRegistry.shared.existing(t.activePaneID)?.currentDirectory ?? t.root.allPanes.first?.lastDirectory
        var copy = TerminalTab(directory: dir, connection: t.root.allPanes.first { $0.id == t.activePaneID }?.connection)
        copy.customTitle = t.customTitle.map { $0 + " copy" }
        copy.color = t.color
        let ti = workspace.folders[fi].tabs.firstIndex { $0.id == id }! + 1
        workspace.folders[fi].tabs.insert(copy, at: ti)
        workspace.selectedTabID = copy.id
    }

    func moveTab(_ id: UUID, toFolder folderID: UUID, at index: Int? = nil) {
        guard let fi = folderIndex(containingTab: id),
              let ti = workspace.folders[fi].tabs.firstIndex(where: { $0.id == id }),
              let dest = workspace.folders.firstIndex(where: { $0.id == folderID }) else { return }
        let t = workspace.folders[fi].tabs.remove(at: ti)
        var insertAt = index ?? workspace.folders[dest].tabs.count
        if fi == dest && ti < insertAt { insertAt -= 1 }
        insertAt = max(0, min(insertAt, workspace.folders[dest].tabs.count))
        workspace.folders[dest].tabs.insert(t, at: insertAt)
        workspace.folders[dest].isExpanded = true
    }

    func selectTab(atFlatIndex i: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        // ⌘9 = last tab, like browsers
        let idx = i == 8 ? tabs.count - 1 : i
        if idx < tabs.count { workspace.selectedTabID = tabs[idx].id }
    }

    func cycleTab(_ delta: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let cur = tabs.firstIndex { $0.id == workspace.selectedTabID } ?? 0
        workspace.selectedTabID = tabs[(cur + delta + tabs.count) % tabs.count].id
    }

    func clearStartupCommand(_ paneID: UUID) {
        guard let t = orderedTabs.first(where: { $0.root.contains(paneID) }) else { return }
        mutateTab(t.id) { $0.root = $0.root.updatingPane(paneID) { $0.startupCommand = nil } }
    }

    // MARK: Broadcast

    func toggleBroadcast() {
        guard let t = selectedTab else { return }
        mutateTab(t.id) { $0.broadcast.toggle() }
    }

    /// Views that should also receive input typed into `paneID` (other panes of a broadcasting tab).
    func broadcastPeers(of paneID: UUID) -> [TildeTerminalView] {
        guard let t = orderedTabs.first(where: { $0.root.contains(paneID) }), t.broadcast else { return [] }
        return t.root.allPanes.compactMap { p in
            p.id == paneID ? nil : TerminalRegistry.shared.existing(p.id).flatMap { $0.exited ? nil : $0.view }
        }
    }

    // MARK: Panes

    func split(_ axis: SplitAxis) {
        guard let t = selectedTab else { return }
        let dir = TerminalRegistry.shared.existing(t.activePaneID)?.currentDirectory
        // Splitting an SSH pane opens another session to the same host (instant via the shared connection).
        let conn = t.root.allPanes.first { $0.id == t.activePaneID }?.connection
        let newPane = Pane(lastDirectory: dir, connection: conn)
        mutateTab(t.id) {
            $0.zoomedPaneID = nil
            $0.root = $0.root.splitting($0.activePaneID, axis: axis, newPane: newPane)
            $0.activePaneID = newPane.id
        }
    }

    func setActivePane(_ paneID: UUID, inTab tabID: UUID) {
        guard tab(tabID)?.activePaneID != paneID else { return }
        mutateTab(tabID) { $0.activePaneID = paneID }
    }

    /// ⌘W: closes the active pane, or the tab when it's the last pane.
    func closeActivePane() {
        guard let t = selectedTab else { return }
        closePane(t.activePaneID, inTab: t.id)
    }

    func closePane(_ paneID: UUID, inTab tabID: UUID) {
        guard let t = tab(tabID) else { return }
        TerminalRegistry.shared.close(paneID)
        guard let newRoot = t.root.removing(paneID) else { closeTab(tabID); return }
        mutateTab(tabID) {
            $0.root = newRoot
            if $0.zoomedPaneID == paneID || newRoot.allPanes.count < 2 { $0.zoomedPaneID = nil }
            if $0.activePaneID == paneID { $0.activePaneID = newRoot.allPanes.last!.id }
        }
    }

    /// Called when a shell exits on its own (e.g. `exit`).
    /// A failed SSH session stays open so the error is readable.
    func paneExited(_ paneID: UUID, exitCode: Int32?) {
        guard let t = orderedTabs.first(where: { $0.root.contains(paneID) }) else { return }
        let pane = t.root.allPanes.first { $0.id == paneID }
        if case .ssh = pane?.connection, exitCode != 0, let s = TerminalRegistry.shared.existing(paneID) {
            let code = exitCode.map(String.init) ?? "signal"
            s.view.feed(text: "\r\n\u{1b}[2m[ssh exited (\(code)) — ⌘W to close, ⇧⌘R to reconnect]\u{1b}[0m\r\n")
            return
        }
        closePane(paneID, inTab: t.id)
    }

    /// Restarts the active pane's process (e.g. reconnect a dropped SSH session).
    func restartActivePane() {
        guard let t = selectedTab, let pane = t.root.allPanes.first(where: { $0.id == t.activePaneID }) else { return }
        TerminalRegistry.shared.close(pane.id)
        let fresh = Pane(lastDirectory: pane.lastDirectory, connection: pane.connection)
        mutateTab(t.id) {
            $0.root = $0.root.replacingPane(pane.id, with: fresh)
            $0.activePaneID = fresh.id
        }
    }

    // MARK: Polling & persistence

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        var changed = false
        for s in TerminalRegistry.shared.sessions.values where s.refresh() { changed = true }
        if changed { titleTick &+= 1 }
        pollAgents()
    }

    /// Copies live cwd into the model so restore reopens shells where they were.
    func snapshotDirectories() -> Workspace {
        var ws = workspace
        for fi in ws.folders.indices {
            for ti in ws.folders[fi].tabs.indices {
                for p in ws.folders[fi].tabs[ti].root.allPanes {
                    if let d = TerminalRegistry.shared.existing(p.id)?.currentDirectory {
                        ws.folders[fi].tabs[ti].root = ws.folders[fi].tabs[ti].root.updatingPane(p.id) { $0.lastDirectory = d }
                    }
                }
            }
        }
        return ws
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        let ws = snapshotDirectories()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(ws) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    private static var toastWork: DispatchWorkItem?
    func showToast(_ text: String, seconds: Double = 4) {
        toast = text
        Self.toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        Self.toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}
