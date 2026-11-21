import Foundation
import SwiftUI

enum TabColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }
    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
    var label: String { self == .none ? "None" : rawValue.capitalized }
}

enum SplitAxis: String, Codable {
    case horizontal   // side by side
    case vertical     // stacked
}

/// A pane = one shell. `lastDirectory` is refreshed while running so we can restore it.
struct Pane: Codable, Identifiable, Hashable {
    var id = UUID()
    var lastDirectory: String?
    /// nil = local shell; otherwise an SSH session or a local shell with a host's environment.
    var connection: PaneConnection?
    /// Typed into the shell the first time it starts (from a workspace template), then cleared.
    var startupCommand: String?
}

indirect enum PaneNode: Codable, Hashable {
    case leaf(Pane)
    case split(axis: SplitAxis, children: [PaneNode])

    var allPanes: [Pane] {
        switch self {
        case .leaf(let p): return [p]
        case .split(_, let c): return c.flatMap { $0.allPanes }
        }
    }

    /// Stable identity for SwiftUI diffing.
    var nodeID: String {
        switch self {
        case .leaf(let p): return p.id.uuidString
        case .split(let a, let c): return "split-\(a.rawValue)-" + (c.first?.nodeID ?? "")
        }
    }

    func contains(_ paneID: UUID) -> Bool { allPanes.contains { $0.id == paneID } }

    /// Split the given pane, inserting `newPane` after it.
    func splitting(_ paneID: UUID, axis: SplitAxis, newPane: Pane) -> PaneNode {
        switch self {
        case .leaf(let p):
            guard p.id == paneID else { return self }
            return .split(axis: axis, children: [.leaf(p), .leaf(newPane)])
        case .split(let a, let children):
            // If the target is a direct leaf child and axis matches, add as sibling.
            if a == axis, let idx = children.firstIndex(where: { if case .leaf(let p) = $0 { return p.id == paneID }; return false }) {
                var c = children
                c.insert(.leaf(newPane), at: idx + 1)
                return .split(axis: a, children: c)
            }
            return .split(axis: a, children: children.map { $0.splitting(paneID, axis: axis, newPane: newPane) })
        }
    }

    /// Remove a pane; returns nil when the tree becomes empty.
    func removing(_ paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let p):
            return p.id == paneID ? nil : self
        case .split(let a, let children):
            let c = children.compactMap { $0.removing(paneID) }
            if c.isEmpty { return nil }
            if c.count == 1 { return c[0] }
            return .split(axis: a, children: c)
        }
    }

    func replacingPane(_ paneID: UUID, with new: Pane) -> PaneNode {
        switch self {
        case .leaf(let p): return p.id == paneID ? .leaf(new) : self
        case .split(let a, let c): return .split(axis: a, children: c.map { $0.replacingPane(paneID, with: new) })
        }
    }

    func updatingPane(_ paneID: UUID, _ change: (inout Pane) -> Void) -> PaneNode {
        switch self {
        case .leaf(var p):
            if p.id == paneID { change(&p) }
            return .leaf(p)
        case .split(let a, let children):
            return .split(axis: a, children: children.map { $0.updatingPane(paneID, change) })
        }
    }
}

struct TerminalTab: Codable, Identifiable, Hashable {
    var id = UUID()
    /// User-assigned name. When nil, an automatic title is shown.
    var customTitle: String?
    var notes: String = ""
    var color: TabColor = .none
    /// Keystrokes in one pane go to every pane of this tab.
    var broadcast = false
    /// Pane shown alone, filling the tab (⇧⌘↩).
    var zoomedPaneID: UUID?
    var root: PaneNode
    var activePaneID: UUID

    init(directory: String?, connection: PaneConnection? = nil) {
        let pane = Pane(lastDirectory: directory, connection: connection)
        root = .leaf(pane)
        activePaneID = pane.id
    }

    init(root: PaneNode) {
        self.root = root
        activePaneID = root.allPanes.first!.id
    }

    private enum CodingKeys: String, CodingKey { case id, customTitle, notes, color, broadcast, zoomedPaneID, root, activePaneID }

    // Tolerant decoding so older workspace files (missing newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        color = try c.decodeIfPresent(TabColor.self, forKey: .color) ?? .none
        broadcast = try c.decodeIfPresent(Bool.self, forKey: .broadcast) ?? false
        zoomedPaneID = try c.decodeIfPresent(UUID.self, forKey: .zoomedPaneID)
        root = try c.decode(PaneNode.self, forKey: .root)
        activePaneID = try c.decodeIfPresent(UUID.self, forKey: .activePaneID) ?? root.allPanes.first!.id
    }
}

struct Folder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Default working directory for new tabs in this folder.
    var directory: String?
    var isExpanded = true
    var tabs: [TerminalTab] = []
    /// Containing folder; nil = top level. Folders are stored flat in `Workspace.folders`
    /// (siblings keep their relative order), so tab lookups don't need to recurse.
    var parentID: UUID?
}

/// A tab taken out of the window whose shells keep running (File ▸ Detach Tab).
struct DetachedTab: Codable, Identifiable, Hashable {
    var id: UUID { tab.id }
    var tab: TerminalTab
    var folderID: UUID?
    var folderName: String
    var title: String
    var detachedAt = Date()
}

struct Workspace: Codable {
    var folders: [Folder] = []
    var selectedTabID: UUID?
    var detached: [DetachedTab] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case folders, selectedTabID, detached }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        detached = (try? c.decodeIfPresent([DetachedTab].self, forKey: .detached)) ?? []
    }
}

// MARK: - Folder tree
// Folders are stored flat; `parentID` links a subfolder to its parent. Siblings keep their
// relative order in `folders`. These are pure so they can be unit-tested without the store.
extension Workspace {
    /// Direct children of `parentID` (nil = top level), in sidebar order.
    /// A folder whose parent no longer exists is treated as top level.
    func childFolders(of parentID: UUID?) -> [Folder] {
        let ids = Set(folders.map(\.id))
        return folders.filter { f in
            guard let p = f.parentID, ids.contains(p) else { return parentID == nil }
            return p == parentID
        }
    }

    /// All folders depth-first, in the order the sidebar shows them (a folder, then its subfolders).
    var displayOrderedFolders: [Folder] {
        var out: [Folder] = [], seen = Set<UUID>()
        func walk(_ parent: UUID?) {
            for f in childFolders(of: parent) where seen.insert(f.id).inserted { out.append(f); walk(f.id) }
        }
        walk(nil)
        return out
    }

    /// The folder and everything nested inside it.
    func folderAndDescendantIDs(_ id: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        func walk(_ x: UUID) {
            guard out.insert(x).inserted else { return }
            for c in childFolders(of: x) { walk(c.id) }
        }
        walk(id)
        return out
    }

    /// "Parent › Child" for menus and pickers.
    func folderPath(_ id: UUID) -> String {
        var names: [String] = [], cur: UUID? = id, seen = Set<UUID>()
        while let c = cur, seen.insert(c).inserted, let f = folders.first(where: { $0.id == c }) {
            names.insert(f.name, at: 0); cur = f.parentID
        }
        return names.joined(separator: " › ")
    }

    /// Index right after the last folder of `parentID`'s subtree (where a new last child goes).
    private func endOfSubtree(_ parentID: UUID) -> Int? {
        let family = folderAndDescendantIDs(parentID)
        return folders.lastIndex { family.contains($0.id) }.map { $0 + 1 }
    }

    /// Adds `folder` as the last child of `parentID`. Returns false if the parent doesn't exist.
    @discardableResult
    mutating func insertSubfolder(_ folder: Folder, in parentID: UUID) -> Bool {
        guard let pi = folders.firstIndex(where: { $0.id == parentID }), let at = endOfSubtree(parentID) else { return false }
        var f = folder
        f.parentID = parentID
        folders.insert(f, at: at)
        folders[pi].isExpanded = true
        return true
    }

    /// Re-parents a folder (nil = top level) as the parent's last child, keeping its own subtree.
    /// Refuses (returns false) to move a folder into itself or one of its own subfolders.
    @discardableResult
    mutating func reparentFolder(_ id: UUID, to parentID: UUID?) -> Bool {
        guard folders.contains(where: { $0.id == id }) else { return false }
        if let parentID {
            guard folders.contains(where: { $0.id == parentID }),
                  !folderAndDescendantIDs(id).contains(parentID) else { return false }
        }
        // Lift the folder and its subtree out (in their current order), then drop them in.
        let subtree = folderAndDescendantIDs(id)
        var moving = folders.filter { subtree.contains($0.id) }
        folders.removeAll { subtree.contains($0.id) }
        if let i = moving.firstIndex(where: { $0.id == id }) { moving[i].parentID = parentID }
        if let parentID, let at = endOfSubtree(parentID) {
            folders.insert(contentsOf: moving, at: at)
            if let pi = folders.firstIndex(where: { $0.id == parentID }) { folders[pi].isExpanded = true }
        } else {
            folders.append(contentsOf: moving)
        }
        return true
    }

    /// Reorders the children of `parentID`; offsets refer to `childFolders(of: parentID)`.
    /// Siblings go back into the slots they occupied, in the new order; other folders stay put.
    mutating func reorderChildren(of parentID: UUID?, from source: IndexSet, to destination: Int) {
        var siblings = childFolders(of: parentID).map(\.id)
        siblings.move(fromOffsets: source, toOffset: destination)
        let slots = Set(siblings)
        var next = siblings.makeIterator()
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        folders = folders.map { f in slots.contains(f.id) ? byID[next.next()!]! : f }
    }

    /// Removes a folder and all of its subfolders; returns what was removed.
    @discardableResult
    mutating func removeFolderTree(_ id: UUID) -> [Folder] {
        guard folders.contains(where: { $0.id == id }) else { return [] }
        let doomed = folderAndDescendantIDs(id)
        let removed = folders.filter { doomed.contains($0.id) }
        folders.removeAll { doomed.contains($0.id) }
        return removed
    }
}
