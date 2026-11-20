import AppKit
import SwiftTerm

/// Terminal view; `onFocus` is triggered by the host when the user clicks into it.
final class TildeTerminalView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    var onBell: (() -> Void)?
    /// Other panes that should receive the same input (broadcast mode); set by the store.
    var broadcastPeers: (() -> [TildeTerminalView])?

    /// Files dropped on the terminal; return false to refuse.
    var onDropFiles: (([URL]) -> Void)?

    func enableFileDrops() { registerForDraggedTypes([.fileURL]) }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty || onDropFiles == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, let onDropFiles else { return false }
        onDropFiles(urls)
        return true
    }

    /// ⌘-click on a non-URL link (file path); return true when handled.
    var onOpenFileLink: ((String) -> Bool)?
    var menuProvider: (() -> NSMenu)?

    override func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        if let h = onOpenFileLink, h(request.link) { return }
        super.requestOpenLink(source: source, request: request)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func paste(_ sender: Any) {
        // Files copied in Finder paste as their quoted paths.
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " "
            send(txt: text)
            for v in broadcastPeers?() ?? [] { v.send(txt: text) }
            return
        }
        super.paste(sender)
        for v in broadcastPeers?() ?? [] { v.paste(sender) }
    }

    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }
}

/// One live shell, keyed by pane ID. Lives outside SwiftUI so switching tabs never kills it.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let paneID: UUID
    let view: TildeTerminalView
    private(set) var initialDirectory: String?

    /// Updated by polling: program in the foreground (nil when it's just the shell) and cwd.
    private(set) var foregroundProgram: String?
    private(set) var currentDirectory: String?
    private(set) var oscTitle: String?
    private(set) var exited = false
    /// Working directory on the remote host, when its shell reports one (OSC 7).
    private(set) var remoteDirectory: String?
    /// Short status message for the window (upload progress).
    var onToast: ((String) -> Void)?

    /// The host view currently allowed to display this terminal (newest wins).
    weak var ownerHost: NSView?

    var onChange: (() -> Void)?
    var onExit: ((Int32?) -> Void)?
    let connection: PaneConnection?
    /// Host name for SSH / env panes (used for the automatic title).
    private(set) var hostName: String?
    var onFocus: (() -> Void)? {
        didSet { view.onFocus = onFocus }
    }

    private var shellName: String
    private var oscObservation: TerminalOscObservation?
    /// Running inside a tilde-session daemon (survives quitting the app).
    private(set) var persistent = false
    private var shellPid: pid_t?
    /// True while the daemon replays old output after reattaching: ignore its events.
    private var replaying = false
    private var quietUntil = Date.distantPast
    /// Coding agent state in this pane (Claude Code), from hooks or its title.
    var agentState: AgentState?
    var titleForAgent: String? { oscTitle }
    /// Typed into the shell once it starts (workspace templates).
    var startupCommand: String?

    /// Commands seen via shell integration (newest last).
    private(set) var history: [CommandRecord] = []
    var runningCommand: CommandRecord? { history.last.flatMap { $0.finished ? nil : $0 } }
    var lastFinished: CommandRecord? { history.last(where: { $0.finished }) }
    var onCommandFinished: ((CommandRecord) -> Void)?
    /// (title, body) — a program asked for attention (bell, OSC 9/777 notification).
    var onAttention: ((String, String?) -> Void)?

    init(paneID: UUID, directory: String?, connection: PaneConnection? = nil, startupCommand: String? = nil) {
        self.paneID = paneID
        self.startupCommand = startupCommand
        self.initialDirectory = directory
        self.connection = connection
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.shellName = (shell as NSString).lastPathComponent
        view = TildeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = false   // keep ⌥ for macOS special characters
        view.onBell = { [weak self] in
            guard let self, !self.isQuiet else { return }
            self.onAttention?("Bell", nil)
        }
        oscObservation = view.observeOscEvents { [weak self] event in
            let code = event.code
            guard code == ShellIntegration.oscCode || code == 9 || code == 777 else { return }
            let text = String(decoding: event.payload, as: UTF8.self)
            DispatchQueue.main.async { self?.handleOsc(code: code, text: text) }
        }
        view.enableFileDrops()
        view.onDropFiles = { [weak self] urls in self?.filesDropped(urls) }
        view.onOpenFileLink = { [weak self] link in self?.openLinkAsFile(link) ?? false }
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .terminalThemeChanged, object: nil)
        start(shell: shell)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func start(shell: String) {
        let host = connection.flatMap { HostStore.shared.host($0.hostID) }
        hostName = host?.name
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tilde"
        env["TILDE_PANE_ID"] = paneID.uuidString
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Login shell by default: a leading "-" in argv[0], like Terminal.app.
        var shellArgv0 = "-" + shellName, shellArgs: [String] = []
        if connection == nil || { if case .localEnv = connection { return true }; return false }() {
            ShellIntegration.apply(to: &env, shellName: shellName, argv0: &shellArgv0, args: &shellArgs)
        }
        env.removeValue(forKey: "TERM_SESSION_ID")
        // Lets programs (vim, bat, …) pick light or dark colours.
        env["COLORFGBG"] = ThemeManager.shared.palette.isDarkBackground ? "15;0" : "0;15"
        if let host {
            env["TILDE_HOST"] = host.address
            env["TILDE_HOST_NAME"] = host.name
            if case .localEnv = connection {
                for kv in host.env where !kv.key.isEmpty { env[kv.key] = kv.value }
            }
        }
        let envList = env.map { "\($0.key)=\($0.value)" }

        var dir = initialDirectory.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            dir = NSHomeDirectory()
        }
        currentDirectory = dir
        let exe: String, argv0: String, args: [String]
        if case .ssh = connection, let host {
            (exe, argv0, args) = (SSH.executable, "ssh", SSH.interactiveArgs(host))
            HostMonitor.shared.poke(host.id)
        } else {
            (exe, argv0, args) = (shell, shellArgv0, shellArgs)
        }
        var reattaching = false
        if PersistentSessions.available, let helper = PersistentSessions.helper {
            persistent = true
            reattaching = FileManager.default.fileExists(atPath: PersistentSessions.socket(for: paneID))
            view.startProcess(executable: helper,
                              args: ["attach", PersistentSessions.socket(for: paneID), dir, exe, argv0] + args,
                              environment: envList, execName: "tilde-session", currentDirectory: dir)
        } else {
            view.startProcess(executable: exe, args: args, environment: envList, execName: argv0, currentDirectory: dir)
        }
        if let cmd = startupCommand, !cmd.isEmpty, !reattaching {
            startupCommand = nil
            // Typeahead: the shell reads it once its prompt is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.view.send(txt: cmd + "\r") }
        }
    }

    @objc private func themeChanged() { applyTheme() }

    func applyTheme() {
        let theme = ThemeManager.shared
        let p = theme.palette
        view.font = theme.font
        view.nativeForegroundColor = p.foreground
        view.nativeBackgroundColor = p.background
        view.caretColor = p.cursor
        view.selectedTextBackgroundColor = p.selection
        view.optionAsMetaKey = theme.optionAsMeta
        view.setCursorStyle(theme.cursorStyle)
        view.installColors(p.swiftTermColors)
        view.layer?.backgroundColor = p.background.cgColor
        view.needsDisplay = true
    }

    private func handleOsc(code: Int, text: String) {
        switch code {
        case ShellIntegration.oscCode:
            if text.hasPrefix("replay;") {
                replaying = text.hasSuffix("1")
                quietUntil = Date().addingTimeInterval(1.0)
                return
            }
            if replaying { return }
            if text.hasPrefix("start;") {
                let b64 = String(text.dropFirst(6))
                let cmd = Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self) } ?? b64
                history.append(CommandRecord(command: cmd, started: Date(), directory: currentDirectory))
                if history.count > 200 { history.removeFirst(history.count - 200) }
                onChange?()
            } else if text.hasPrefix("end;") {
                let code = Int32(text.dropFirst(4).trimmingCharacters(in: .whitespaces))
                guard let i = history.indices.last, !history[i].finished else { return }
                history[i].duration = Date().timeIntervalSince(history[i].started)
                history[i].exitCode = code
                onCommandFinished?(history[i])
            }
        case 9:
            // OSC 9;4;… is a progress report, not a notification.
            if text.hasPrefix("4;") || isQuiet { return }
            onAttention?(text, nil)
        case 777:
            // notify;title;body
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.first == "notify" && !isQuiet { onAttention?(parts.count > 1 ? parts[1] : "Notification", parts.count > 2 ? parts[2] : nil) }
        default: break
        }
    }

    /// SSH pane: upload over the shared connection into the remote cwd. Local: type the quoted paths.
    private func filesDropped(_ urls: [URL]) {
        if case .ssh(let hostID) = connection, let host = HostStore.shared.host(hostID) {
            let dir = remoteDirectory ?? ""
            let shown = "\(host.name):\(dir.isEmpty ? "~" : dir)"
            let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
            onToast?("Uploading \(what) to \(shown)…")
            Task { @MainActor in
                let r = await ProcessRunner.run("/usr/bin/scp", SSH.scpArgs(host, files: urls.map(\.path), remoteDir: dir),
                                                timeout: 1800)
                if r.status == 0 {
                    self.onToast?("✓ Uploaded \(what) to \(shown) (\(Notifier.format(r.duration)))")
                } else {
                    let why = r.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
                    self.onToast?("✗ Upload failed: \(why)")
                }
            }
        } else {
            view.send(txt: urls.map { SSH.shellQuote($0.path) }.joined(separator: " ") + " ")
            view.window?.makeFirstResponder(view)
        }
    }

    /// Old output being replayed: don't notify about it.
    private var isQuiet: Bool { replaying || Date() < quietUntil }

    func jumpToPrompt(up: Bool) {
        if let row = up ? view.previousSemanticPromptRow() : view.nextSemanticPromptRow() {
            view.scrollTo(row: row)
        } else if !up {
            view.scrollTo(row: Int.max)   // past the last prompt: back to the live screen
        }
    }

    func showFind() { finderAction(.showFindInterface) }
    func findNext() { finderAction(.nextMatch) }
    func findPrevious() { finderAction(.previousMatch) }

    private func finderAction(_ a: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = a.rawValue
        view.window?.makeFirstResponder(view)
        view.performTextFinderAction(item)
    }

    /// Types text into the shell (optionally pressing Return).
    func insert(_ text: String, run: Bool) {
        view.send(txt: text + (run ? "\r" : ""))
        view.window?.makeFirstResponder(view)
    }

    /// Poll process state (cheap syscalls). Returns true when something visible changed.
    @discardableResult
    func refresh() -> Bool {
        guard !exited, let process = view.process, process.running else { return false }
        if case .ssh = connection { return false }   // remote: local process info is meaningless
        let fg: String?, pid: pid_t
        if persistent {
            if shellPid == nil || kill(shellPid!, 0) != 0 { shellPid = PersistentSessions.shellPid(for: paneID) }
            guard let sp = shellPid else { return false }
            pid = sp
            fg = ProcessInspector.foregroundName(ofShell: sp)
        } else {
            pid = process.shellPid
            fg = ProcessInspector.foregroundName(ptyFD: process.childfd)
        }
        let program = (fg == nil || fg == shellName || fg == "-" + shellName || fg == "login") ? nil : fg
        let cwd = ProcessInspector.cwd(of: pid) ?? currentDirectory
        let changed = program != foregroundProgram || cwd != currentDirectory
        // A title set by a previous program is stale once the foreground program changes.
        if program != foregroundProgram { oscTitle = nil }
        foregroundProgram = program
        currentDirectory = cwd
        return changed
    }

    /// Automatic tab title when the user hasn't renamed the tab.
    var autoTitle: String {
        // While a program runs, prefer the title it sets (e.g. Claude Code's session name), else its name.
        let title = oscTitle.map(TerminalSession.cleanTitle)
        if case .ssh = connection, let n = hostName {
            if let t = title, !t.isEmpty { return t }
            return n
        }
        if let p = foregroundProgram {
            if let t = title, !t.isEmpty { return t }
            return p
        }
        // A command that ran for a while (a dev server, a build) names the tab; quick ones don't.
        if let last = lastFinished, (last.duration ?? 0) >= 3 {
            let c = last.command.split(separator: "\n").first.map(String.init) ?? last.command
            return c.count > 32 ? String(c.prefix(31)) + "…" : c
        }
        if let d = currentDirectory {
            if d == NSHomeDirectory() { return "~" }
            return (d as NSString).lastPathComponent
        }
        return shellName
    }

    /// `endSession: false` only detaches (the shell keeps running in its daemon).
    func terminate(endSession: Bool = true) {
        guard !exited else { return }
        exited = true
        view.terminate()
        if persistent && endSession { PersistentSessions.kill(paneID) }
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        oscTitle = title
        onChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let d = directory, !d.isEmpty else { return }
        if case .ssh = connection {
            // Remote path: file://host/path
            if let url = URL(string: d), !url.path.isEmpty { remoteDirectory = url.path }
            else if d.hasPrefix("/") { remoteDirectory = d }
            onChange?()
            return
        }
        if let url = URL(string: d), url.isFileURL, !url.path.isEmpty {
            currentDirectory = url.path
        } else if d.hasPrefix("file://") {
            // file://host/path — drop scheme + host, decode %20.
            let rest = d.dropFirst(7)
            if let slash = rest.firstIndex(of: "/") {
                currentDirectory = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
            }
        } else if d.hasPrefix("/") {
            currentDirectory = d
        }
        onChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            guard !self.exited else { return }
            self.exited = true
            // Another client took over this session; nothing actually exited.
            if self.persistent && exitCode == PersistentSessions.kickedExitCode { return }
            if let id = self.connection?.hostID { HostMonitor.shared.poke(id) }
            self.onExit?(exitCode)
        }
    }
}

/// Owns all live sessions.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private(set) var sessions: [UUID: TerminalSession] = [:]

    func session(for pane: Pane) -> TerminalSession {
        if let s = sessions[pane.id] { return s }
        let s = TerminalSession(paneID: pane.id, directory: pane.lastDirectory, connection: pane.connection,
                                startupCommand: pane.startupCommand)
        sessions[pane.id] = s
        return s
    }

    func existing(_ paneID: UUID) -> TerminalSession? { sessions[paneID] }

    func close(_ paneID: UUID) {
        sessions[paneID]?.terminate()
        sessions[paneID] = nil
    }

    /// On quit: detach (shells keep running) unless sessions shouldn't persist.
    func closeAll(endSessions: Bool) {
        for s in sessions.values { s.terminate(endSession: endSessions) }
        sessions.removeAll()
    }

    /// Drops the view but leaves the shell running in its daemon.
    func detach(_ paneID: UUID) {
        sessions[paneID]?.terminate(endSession: false)
        sessions[paneID] = nil
    }

    /// Sessions not shown in the main window (e.g. the quick terminal).
    func register(_ s: TerminalSession) { sessions[s.paneID] = s }
}
