import AppKit
import SwiftUI

/// A tab closed recently, for ⇧⌘T.
struct ClosedTab {
    var tab: TerminalTab
    var folderID: UUID
    var index: Int
}

enum PaneDirection { case left, right, up, down }

extension Notification.Name {
    /// Resets split fractions to equal sizes.
    static let equalizePanes = Notification.Name("TildeEqualizePanes")
}

extension PaneNode {
    /// Pane rectangles in a unit square (equal split fractions), for directional focus.
    func frames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(UUID, CGRect)] {
        switch self {
        case .leaf(let p): return [(p.id, rect)]
        case .split(let axis, let children):
            let n = CGFloat(children.count)
            return children.enumerated().flatMap { i, c -> [(UUID, CGRect)] in
                let r = axis == .horizontal
                    ? CGRect(x: rect.minX + rect.width * CGFloat(i) / n, y: rect.minY, width: rect.width / n, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + rect.height * CGFloat(i) / n, width: rect.width, height: rect.height / n)
                return c.frames(in: r)
            }
        }
    }
}

extension WorkspaceStore {
    // MARK: Pane focus

    private func focusPane(_ id: UUID) {
        guard let t = selectedTab else { return }
        setActivePane(id, inTab: t.id)
        if t.zoomedPaneID != nil { mutateTab(t.id) { $0.zoomedPaneID = id } }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusActiveTerminal, object: nil) }
    }

    /// ⌘[ / ⌘]
    func cyclePane(_ delta: Int) {
        guard let t = selectedTab else { return }
        let panes = t.root.allPanes
        guard panes.count > 1, let i = panes.firstIndex(where: { $0.id == t.activePaneID }) else { return }
        focusPane(panes[(i + delta + panes.count) % panes.count].id)
    }

    /// ⌥⌘ arrows: nearest pane in that direction.
    func focusPane(_ dir: PaneDirection) {
        guard let t = selectedTab else { return }
        let frames = t.root.frames()
        guard let cur = frames.first(where: { $0.0 == t.activePaneID })?.1 else { return }
        let candidates = frames.filter { id, r in
            guard id != t.activePaneID else { return false }
            switch dir {
            case .left: return r.maxX <= cur.minX + 0.001 && r.maxY > cur.minY && r.minY < cur.maxY
            case .right: return r.minX >= cur.maxX - 0.001 && r.maxY > cur.minY && r.minY < cur.maxY
            case .up: return r.maxY <= cur.minY + 0.001 && r.maxX > cur.minX && r.minX < cur.maxX
            case .down: return r.minY >= cur.maxY - 0.001 && r.maxX > cur.minX && r.minX < cur.maxX
            }
        }
        let best = candidates.min { a, b in
            hypot(a.1.midX - cur.midX, a.1.midY - cur.midY) < hypot(b.1.midX - cur.midX, b.1.midY - cur.midY)
        }
        if let best { focusPane(best.0) } else { NSSound.beep() }
    }

    /// ⇧⌘↩: show the active pane alone, or go back to the split.
    func toggleZoom() {
        guard let t = selectedTab, t.root.allPanes.count > 1 else { return }
        mutateTab(t.id) { $0.zoomedPaneID = $0.zoomedPaneID == nil ? $0.activePaneID : nil }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusActiveTerminal, object: nil) }
    }

    func equalizePanes() { NotificationCenter.default.post(name: .equalizePanes, object: nil) }

    // MARK: Tabs

    /// Moves the selected tab up/down within its folder.
    func moveSelectedTab(_ delta: Int) {
        guard let t = selectedTab, let fi = folderIndex(containingTab: t.id),
              let ti = workspace.folders[fi].tabs.firstIndex(where: { $0.id == t.id }) else { return }
        let dest = ti + delta
        guard workspace.folders[fi].tabs.indices.contains(dest) else { return }
        workspace.folders[fi].tabs.swapAt(ti, dest)
    }

    /// Remembers a tab being closed so ⇧⌘T can bring its layout back (with fresh shells).
    func rememberClosed(_ tab: TerminalTab, folderID: UUID, index: Int) {
        var copy = snapshotDirectories().folders.flatMap(\.tabs).first { $0.id == tab.id } ?? tab
        copy.broadcast = false
        copy.zoomedPaneID = nil
        Self.closedTabs.append(ClosedTab(tab: copy, folderID: folderID, index: index))
        if Self.closedTabs.count > 20 { Self.closedTabs.removeFirst() }
    }

    var canReopenClosedTab: Bool { !Self.closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let c = Self.closedTabs.popLast() else { NSSound.beep(); return }
        var tab = c.tab
        let (root, map) = tab.root.withFreshIDs()
        tab.id = UUID()
        tab.root = root
        tab.activePaneID = map[c.tab.activePaneID] ?? root.allPanes[0].id
        if workspace.folders.isEmpty { workspace.folders.append(Folder(name: "Home", directory: NSHomeDirectory())) }
        let fi = workspace.folders.firstIndex { $0.id == c.folderID } ?? selectedFolderIndex ?? 0
        workspace.folders[fi].tabs.insert(tab, at: min(c.index, workspace.folders[fi].tabs.count))
        workspace.folders[fi].isExpanded = true
        select(tab.id)
    }

    // MARK: Detach

    /// Takes the tab out of the window; its shells keep running in their daemons.
    func detachTab(_ id: UUID) {
        guard PersistentSessions.available, let t = tab(id), let fi = folderIndex(containingTab: id),
              let ti = workspace.folders[fi].tabs.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        let title = displayTitle(t)
        let snap = snapshotDirectories().folders[fi].tabs[ti]
        for p in t.root.allPanes { TerminalRegistry.shared.detach(p.id) }
        attention.remove(id)
        let ordered = orderedTabs
        let flat = ordered.firstIndex { $0.id == id } ?? 0
        workspace.folders[fi].tabs.remove(at: ti)
        workspace.detached.append(DetachedTab(tab: snap, folderID: workspace.folders[fi].id,
                                              folderName: workspace.folders[fi].name, title: title))
        if workspace.selectedTabID == id {
            let rest = orderedTabs
            workspace.selectedTabID = rest.isEmpty ? nil : rest[min(flat, rest.count - 1)].id
        }
        showToast("Detached “\(title)” — its shells keep running. File ▸ Detached Sessions to bring it back.")
    }

    func reattach(_ id: UUID) {
        guard let i = workspace.detached.firstIndex(where: { $0.id == id }) else { return }
        let d = workspace.detached.remove(at: i)
        let fi = workspace.folders.firstIndex { $0.id == d.folderID } ?? {
            workspace.folders.append(Folder(name: d.folderName))
            return workspace.folders.count - 1
        }()
        workspace.folders[fi].tabs.append(d.tab)
        workspace.folders[fi].isExpanded = true
        select(d.tab.id)
    }

    /// Ends a detached tab's shells.
    func endDetached(_ id: UUID) {
        guard let i = workspace.detached.firstIndex(where: { $0.id == id }) else { return }
        for p in workspace.detached[i].tab.root.allPanes { PersistentSessions.kill(p.id) }
        workspace.detached.remove(at: i)
    }

    /// Detached panes whose daemon is still alive.
    func liveDetached() -> [DetachedTab] {
        let live = Set(PersistentSessions.liveIDs())
        return workspace.detached.filter { d in d.tab.root.allPanes.contains { live.contains($0.id) } }
    }

    // MARK: Screen

    /// Clears the screen and scrollback of the active pane (shell redraws its prompt).
    func clearActive(scrollback: Bool) {
        guard let s = activeSession else { return }
        s.view.feed(text: scrollback ? "\u{1b}[H\u{1b}[2J\u{1b}[3J" : "\u{1b}[H\u{1b}[2J")
        s.view.send(txt: "\u{0c}")   // ^L: the shell redraws its prompt
    }
}

// MARK: - Detached sessions sheet

struct DetachedSessionsView: View {
    @EnvironmentObject var store: WorkspaceStore
    let onClose: () -> Void

    var body: some View {
        let items = store.liveDetached()
        VStack(alignment: .leading, spacing: 12) {
            Text("Detached Sessions").font(.headline)
            if items.isEmpty {
                Text("No detached tabs. File ▸ Detach Tab takes a tab out of the window while its programs keep running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(items) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.title).lineLimit(1).truncationMode(.middle)
                            Text("\(d.folderName) · \(d.tab.root.allPanes.count) pane\(d.tab.root.allPanes.count == 1 ? "" : "s") · detached \(d.detachedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help(d.title)
                        Spacer(minLength: 8)
                        Button("End…") {
                            guard Confirm.ask("End “\(d.title)”?", "Its shells and anything running in them are stopped.", confirm: "End Session") else { return }
                            store.endDetached(d.id)
                        }
                        Button("Reattach") { onClose(); store.reattach(d.id) }.buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 160)
            }
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 520)
        .onExitCommand(perform: onClose)
    }
}
