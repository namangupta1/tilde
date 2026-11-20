import AppKit

/// Finds folders worth opening: git repos in common project roots, zoxide's history, and recent tab folders.
@MainActor
enum FolderFinder {
    private(set) static var repos: [String] = []
    private(set) static var zoxide: [String] = []
    private static var scanned = false

    static let roots = ["dev", "Developer", "code", "Code", "projects", "Projects", "src", "repos", "work", "Documents", "Desktop"]

    /// Scans in the background (cheap: two levels deep, stops at each repo).
    static func refresh() {
        guard !scanned else { return }
        scanned = true
        Task.detached(priority: .utility) {
            let home = NSHomeDirectory()
            var found: [String] = []
            let fm = FileManager.default
            func isRepo(_ p: String) -> Bool { fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) }
            for r in roots {
                let root = (home as NSString).appendingPathComponent(r)
                guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for k in kids where !k.hasPrefix(".") {
                    let p = (root as NSString).appendingPathComponent(k)
                    var dir: ObjCBool = false
                    guard fm.fileExists(atPath: p, isDirectory: &dir), dir.boolValue else { continue }
                    if isRepo(p) { found.append(p); continue }
                    for g in (try? fm.contentsOfDirectory(atPath: p))?.prefix(200) ?? [] where !g.hasPrefix(".") {
                        let q = (p as NSString).appendingPathComponent(g)
                        if isRepo(q) { found.append(q) }
                    }
                }
                if found.count > 400 { break }
            }
            var z: [String] = []
            for bin in ["/opt/homebrew/bin/zoxide", "/usr/local/bin/zoxide"] where fm.isExecutableFile(atPath: bin) {
                let r = await ProcessRunner.run(bin, ["query", "-l"], timeout: 3)
                z = r.stdout.split(separator: "\n").prefix(40).map(String.init)
                break
            }
            let repos = found.sorted(), zo = z
            await MainActor.run { FolderFinder.repos = repos; FolderFinder.zoxide = zo }
        }
    }

    /// Folders for the palette, most useful first, de-duplicated.
    static func candidates(store: WorkspaceStore) -> [(path: String, kind: String)] {
        var seen = Set<String>(), out: [(String, String)] = []
        func add(_ p: String, _ k: String) {
            let n = (p as NSString).standardizingPath
            guard !seen.contains(n), n != NSHomeDirectory() else { return }
            seen.insert(n); out.append((n, k))
        }
        for t in store.orderedTabs {
            for p in t.root.allPanes {
                if let d = TerminalRegistry.shared.existing(p.id)?.currentDirectory ?? p.lastDirectory { add(d, "Recent") }
            }
        }
        for z in zoxide { add(z, "zoxide") }
        for r in repos { add(r, "Git repo") }
        return out
    }
}

extension WorkspaceStore {
    /// Opens a folder: a new tab in the sidebar folder already rooted there, else a new sidebar folder.
    func openFolder(_ path: String) {
        if let f = workspace.folders.first(where: { $0.directory.map { ($0 as NSString).standardizingPath } == path }) {
            newTab(inFolder: f.id)
        } else {
            addFolder(name: (path as NSString).lastPathComponent, directory: path)
        }
    }

    /// ⌥⌘T: new tab in a fresh git worktree of the current repo, on a new branch.
    func newWorktreeTab() {
        let cwd = activeSession?.currentDirectory ?? selectedFolderIndex.flatMap { workspace.folders[$0].directory } ?? NSHomeDirectory()
        Task { @MainActor in
            let top = await ProcessRunner.run("/usr/bin/git", ["-C", cwd, "rev-parse", "--show-toplevel"], timeout: 5)
            guard top.status == 0 else { showToast("Not inside a git repository: \(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"); return }
            let repo = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let f = DateFormatter(); f.dateFormat = "MMdd-HHmm"
            let alert = NSAlert()
            alert.messageText = "New worktree for \((repo as NSString).lastPathComponent)"
            alert.informativeText = "Creates a new branch checked out in its own folder next to the repository, and opens a tab there."
            let field = NSTextField(string: "tilde/\(f.string(from: Date()))")
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let branch = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !branch.isEmpty else { return }
            let parent = (repo as NSString).deletingLastPathComponent
            let dir = (parent as NSString).appendingPathComponent((repo as NSString).lastPathComponent + ".worktrees")
            let path = (dir as NSString).appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            let r = await ProcessRunner.run("/usr/bin/git", ["-C", repo, "worktree", "add", "-b", branch, path], timeout: 60)
            guard r.status == 0 else {
                showToast("✗ git worktree: " + (r.stderr.split(separator: "\n").last.map(String.init) ?? "failed"), seconds: 8)
                return
            }
            guard let fi = selectedFolderIndex else { return }
            var tab = TerminalTab(directory: path)
            tab.customTitle = branch
            workspace.folders[fi].tabs.append(tab)
            workspace.folders[fi].isExpanded = true
            select(tab.id)
            showToast("Worktree \(branch) at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }
    }
}
