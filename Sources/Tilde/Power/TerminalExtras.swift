import AppKit
import SwiftTerm
import Carbon.HIToolbox

/// Editors Tilde can open `path:line:col` in.
enum EditorChoice: String, CaseIterable, Identifiable {
    case system, vscode, cursor, zed, sublime, xcode
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Default app for the file"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .xcode: return "Xcode"
        }
    }
    static let key = "editor"
    static var current: EditorChoice { UserDefaults.standard.string(forKey: key).flatMap(EditorChoice.init) ?? .system }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

enum FileOpener {
    struct Location { var path: String; var line: Int?; var column: Int? }

    /// Splits `file.swift:12:5` (also `file.swift(12,5)`) into path, line, column.
    static func parse(_ raw: String) -> Location {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`")))
        if s.hasPrefix("file://"), let u = URL(string: s) { s = u.path }
        var nums: [Int] = []
        if let paren = s.range(of: #"\((\d+)(,(\d+))?\)$"#, options: .regularExpression) {
            nums = s[paren].dropFirst().dropLast().split(separator: ",").compactMap { Int($0) }
            s = String(s[..<paren.lowerBound])
        } else {
            while let r = s.range(of: #":(\d+)$"#, options: .regularExpression), nums.count < 2 {
                nums.insert(Int(s[r].dropFirst())!, at: 0)
                s = String(s[..<r.lowerBound])
            }
        }
        if s.hasSuffix(":") { s.removeLast() }
        return Location(path: s, line: nums.first, column: nums.count > 1 ? nums[1] : nil)
    }

    /// Resolves against `cwd`; nil when there's no such local file.
    static func resolve(_ loc: Location, cwd: String?) -> Location? {
        var l = loc
        let expanded = (l.path as NSString).expandingTildeInPath
        l.path = expanded.hasPrefix("/") ? expanded : ((cwd ?? NSHomeDirectory()) as NSString).appendingPathComponent(expanded)
        l.path = (l.path as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: l.path) ? l : nil
    }

    static func open(_ l: Location) {
        let suffix = (l.line.map { ":\($0)" } ?? "") + (l.column.map { ":\($0)" } ?? "")
        let enc = l.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? l.path
        switch EditorChoice.current {
        case .vscode: openURL("vscode://file\(enc)\(suffix)", fallback: l)
        case .cursor: openURL("cursor://file\(enc)\(suffix)", fallback: l)
        case .zed: openURL("zed://file\(enc)\(suffix)", fallback: l)
        case .sublime:
            let subl = "/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl"
            if FileManager.default.isExecutableFile(atPath: subl) { run(subl, [l.path + suffix]) } else { system(l) }
        case .xcode:
            var args = [l.path]
            if let line = l.line { args = ["-l", String(line), l.path] }
            run("/usr/bin/xed", args)
        case .system: system(l)
        }
    }

    /// File on an SSH host: VS Code / Cursor open it through Remote - SSH.
    static func openRemote(path: String, line: Int?, host: Host) -> Bool {
        let scheme: String
        switch EditorChoice.current {
        case .vscode: scheme = "vscode"
        case .cursor: scheme = "cursor"
        default: return false
        }
        let target = host.user.isEmpty ? host.address : "\(host.user)@\(host.address)"
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(scheme)://vscode-remote/ssh-remote+\(target)\(enc)" + (line.map { ":\($0)" } ?? "")) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func system(_ l: Location) { NSWorkspace.shared.open(URL(fileURLWithPath: l.path)) }

    private static func openURL(_ s: String, fallback: Location) {
        if let u = URL(string: s), NSWorkspace.shared.urlForApplication(toOpen: u) != nil { NSWorkspace.shared.open(u) }
        else { system(fallback) }
    }

    private static func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
    }
}

extension TerminalSession {
    /// Handles a ⌘-clicked link that isn't a URL: a file path, opened in the chosen editor.
    func openLinkAsFile(_ link: String) -> Bool {
        if link.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil && !link.hasPrefix("file://") {
            return false
        }
        if link.hasPrefix("mailto:") { return false }
        let loc = FileOpener.parse(link)
        if case .ssh(let hid) = connection, let host = HostStore.shared.host(hid) {
            let path = loc.path.hasPrefix("/") ? loc.path : remoteDirectory.map { ($0 as NSString).appendingPathComponent(loc.path) }
            if let path, FileOpener.openRemote(path: path, line: loc.line, host: host) { return true }
            return false
        }
        guard let resolved = FileOpener.resolve(loc, cwd: currentDirectory) else { return false }
        FileOpener.open(resolved)
        return true
    }

    /// Saves the clipboard image as a PNG and types its path (uploads it first on SSH panes).
    func pasteImageAsPath() {
        let pb = NSPasteboard.general
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            onToast?("No image on the clipboard")
            return
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tilde/pasted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "image-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let url = dir.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { onToast?("Couldn't save the image"); return }

        if case .ssh(let hid) = connection, let host = HostStore.shared.host(hid) {
            let remote = "/tmp/tilde-\(name)"
            onToast?("Uploading image to \(host.name)…")
            Task { @MainActor in
                let r = await ProcessRunner.run("/usr/bin/scp", SSH.scpArgs(host, files: [url.path], remoteDir: remote), timeout: 120)
                if r.status == 0 {
                    self.view.send(txt: SSH.shellQuote(remote) + " ")
                    self.onToast?("✓ Image uploaded to \(host.name):\(remote)")
                } else {
                    self.onToast?("✗ Image upload failed")
                }
            }
        } else {
            view.send(txt: SSH.shellQuote(url.path) + " ")
        }
        view.window?.makeFirstResponder(view)
    }

    /// Text of the last finished command's output, found below its command line in the scrollback.
    func lastCommandOutput() -> String? {
        guard let rec = lastFinished else { return nil }
        let text = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        var lines = text.components(separatedBy: "\n").map { l -> String in
            var x = l; while x.last == " " { x.removeLast() }; return x
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2 else { return nil }
        let cmd = rec.command.split(separator: "\n").first.map(String.init) ?? rec.command
        // The prompt line now is the last line; find the command line before it.
        guard let start = lines[..<(lines.count - 1)].lastIndex(where: { $0.hasSuffix(cmd) }) else { return nil }
        let out = lines[(start + 1)..<(lines.count - 1)]
        return out.joined(separator: "\n")
    }

    func contextMenu(store: WorkspaceStore) -> NSMenu {
        let m = NSMenu()
        let v = view
        m.addItem(ClosureMenuItem("Copy") { v.copy(v) })
        m.addItem(ClosureMenuItem("Paste") { v.paste(v) })
        if NSImage(pasteboard: .general) != nil {
            m.addItem(ClosureMenuItem("Paste Image as File Path") { [weak self] in self?.pasteImageAsPath() })
        }
        m.addItem(.separator())
        if let sel = v.getSelection(), !sel.isEmpty {
            m.addItem(ClosureMenuItem("Open “\(sel.prefix(30))” in Editor") { [weak self] in
                if self?.openLinkAsFile(sel) != true { self?.onToast?("No file named \(sel.prefix(40))") }
            })
        }
        m.addItem(ClosureMenuItem("Copy Last Command Output") { store.copyLastOutput() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Split Right") { store.split(.horizontal) })
        m.addItem(ClosureMenuItem("Split Down") { store.split(.vertical) })
        m.addItem(ClosureMenuItem("Zoom Pane") { store.toggleZoom() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Clear Scrollback") { store.clearActive(scrollback: true) })
        return m
    }
}

extension WorkspaceStore {
    func copyLastOutput() {
        guard let s = activeSession else { return }
        guard let out = s.lastCommandOutput() else {
            showToast(s.lastFinished == nil ? "No finished command yet (needs shell integration)" : "Couldn't find that command's output")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        let n = out.isEmpty ? 0 : out.components(separatedBy: "\n").count
        showToast("Copied \(n) line\(n == 1 ? "" : "s") of output from “\(s.lastFinished!.command.prefix(40))”")
    }

    func openSelectedFile() {
        guard let s = activeSession else { return }
        guard let sel = s.view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            showToast("Select a file path first"); return
        }
        if !s.openLinkAsFile(sel) { showToast("No file named \(sel.prefix(60))") }
    }
}

/// Secure Keyboard Entry: other apps can't read keystrokes while Tilde is active.
@MainActor
enum SecureInput {
    static let key = "secureKeyboardEntry"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    private static var on = false

    static func update() {
        let want = enabled && NSApp.isActive
        if want && !on { EnableSecureEventInput(); on = true }
        if !want && on { DisableSecureEventInput(); on = false }
    }

    static func install() {
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            }
        }
        update()
    }
}
