import Foundation
import XCTest
@testable import Tilde

/// Folder-tree logic on `Workspace` (pure: no store, no files, no shells).
final class FolderTreeTests: XCTestCase {
    private func folder(_ name: String, parent: UUID? = nil, dir: String? = nil) -> Folder {
        var f = Folder(name: name, directory: dir)
        f.parentID = parent
        f.tabs = [TerminalTab(directory: dir)]
        return f
    }

    /// A ─┬─ A1 ── A1a
    ///    └─ A2
    /// B
    private func sample() -> (Workspace, a: UUID, a1: UUID, a1a: UUID, a2: UUID, b: UUID) {
        var ws = Workspace()
        let a = folder("A"), b = folder("B")
        ws.folders = [a, b]
        let a1 = folder("A1"), a2 = folder("A2"), a1a = folder("A1a")
        XCTAssertTrue(ws.insertSubfolder(a1, in: a.id))
        XCTAssertTrue(ws.insertSubfolder(a2, in: a.id))
        XCTAssertTrue(ws.insertSubfolder(a1a, in: a1.id))
        return (ws, a.id, a1.id, a1a.id, a2.id, b.id)
    }

    private func names(_ fs: [Folder]) -> [String] { fs.map(\.name) }

    func testInsertBuildsTreeInSidebarOrder() {
        let (ws, a, a1, _, _, _) = sample()
        XCTAssertEqual(names(ws.childFolders(of: nil)), ["A", "B"])
        XCTAssertEqual(names(ws.childFolders(of: a)), ["A1", "A2"])
        XCTAssertEqual(names(ws.childFolders(of: a1)), ["A1a"])
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "A1", "A1a", "A2", "B"])
    }

    func testInsertIntoMissingParentFails() {
        var ws = Workspace()
        XCTAssertFalse(ws.insertSubfolder(folder("X"), in: UUID()))
        XCTAssertTrue(ws.folders.isEmpty)
    }

    func testInsertExpandsParent() {
        var ws = Workspace()
        var a = folder("A"); a.isExpanded = false
        ws.folders = [a]
        ws.insertSubfolder(folder("A1"), in: a.id)
        XCTAssertTrue(ws.folders[0].isExpanded)
    }

    func testPathAndDescendants() {
        let (ws, a, a1, a1a, a2, b) = sample()
        XCTAssertEqual(ws.folderPath(a1a), "A › A1 › A1a")
        XCTAssertEqual(ws.folderPath(b), "B")
        XCTAssertEqual(ws.folderAndDescendantIDs(a), [a, a1, a1a, a2])
        XCTAssertEqual(ws.folderAndDescendantIDs(a1a), [a1a])
    }

    func testRemoveFolderTreeRemovesDescendantsOnly() {
        var (ws, _, a1, _, _, _) = sample()
        let removed = ws.removeFolderTree(a1)
        XCTAssertEqual(Set(names(removed)), ["A1", "A1a"])
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "A2", "B"])
        XCTAssertTrue(ws.removeFolderTree(UUID()).isEmpty)
    }

    func testReparentMovesWholeSubtree() {
        var (ws, _, a1, _, _, b) = sample()
        XCTAssertTrue(ws.reparentFolder(a1, to: b))
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "A2", "B", "A1", "A1a"])
        XCTAssertEqual(ws.folderPath(ws.folders.first { $0.name == "A1a" }!.id), "B › A1 › A1a")
    }

    func testReparentToTopLevel() {
        var (ws, _, a1, _, _, _) = sample()
        XCTAssertTrue(ws.reparentFolder(a1, to: nil))
        XCTAssertEqual(names(ws.childFolders(of: nil)), ["A", "B", "A1"])
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "A2", "B", "A1", "A1a"])
    }

    func testReparentRefusesCycles() {
        var (ws, a, a1, a1a, _, _) = sample()
        let before = ws.folders
        XCTAssertFalse(ws.reparentFolder(a, to: a))
        XCTAssertFalse(ws.reparentFolder(a, to: a1a))
        XCTAssertFalse(ws.reparentFolder(a1, to: a1a))
        XCTAssertEqual(ws.folders, before)
    }

    func testReorderChildrenOnlyTouchesSiblings() {
        var (ws, a, _, _, _, _) = sample()
        ws.reorderChildren(of: a, from: IndexSet(integer: 1), to: 0)   // A2 before A1
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "A2", "A1", "A1a", "B"])
        ws.reorderChildren(of: nil, from: IndexSet(integer: 1), to: 0) // B before A
        XCTAssertEqual(names(ws.displayOrderedFolders), ["B", "A", "A2", "A1", "A1a"])
    }

    func testOrphanedFolderShowsAtTopLevel() {
        var ws = Workspace()
        ws.folders = [folder("A"), folder("Orphan", parent: UUID())]
        XCTAssertEqual(names(ws.childFolders(of: nil)), ["A", "Orphan"])
        XCTAssertEqual(names(ws.displayOrderedFolders), ["A", "Orphan"])
    }

    func testOldWorkspaceFilesWithoutParentIDStillLoad() throws {
        // A folder as written by the previous version (no parentID key).
        let json = """
        {"folders":[{"id":"\(UUID().uuidString)","name":"Home","directory":"/tmp","isExpanded":true,"tabs":[]}]}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(ws.folders.count, 1)
        XCTAssertNil(ws.folders[0].parentID)
    }

    func testParentIDRoundTrips() throws {
        let (ws, _, _, a1a, _, _) = sample()
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(back.folderPath(a1a), "A › A1 › A1a")
    }
}
