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

    private enum CodingKeys: String, CodingKey { case id, customTitle, notes, color, broadcast, root, activePaneID }

    // Tolerant decoding so older workspace files (missing newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        color = try c.decodeIfPresent(TabColor.self, forKey: .color) ?? .none
        broadcast = try c.decodeIfPresent(Bool.self, forKey: .broadcast) ?? false
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
}

struct Workspace: Codable {
    var folders: [Folder] = []
    var selectedTabID: UUID?
}
