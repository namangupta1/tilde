import Foundation

enum Reach: Equatable { case unknown, checking, online, offline, viaProxy }

struct HostStatus: Equatable {
    var reach: Reach = .unknown
    /// A shared ssh connection (ControlMaster) is alive → everything connects instantly.
    var sharedConnection = false
    /// Background (BatchMode) login failed: user must authenticate once in a tab.
    var needsLogin = false
    var fetchingFacts = false
    var lastError: String?
    var lastChecked: Date?
}

struct CommandRun: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var command: String
    var output = ""
    var status: Int32?
    var running = true
    var duration: TimeInterval = 0
}

/// Background status for every host: reachability, shared connection, cached facts.
@MainActor
final class HostMonitor: ObservableObject {
    static let shared = HostMonitor()

    @Published private(set) var status: [UUID: HostStatus] = [:]
    @Published var runs: [UUID: [CommandRun]] = [:]

    private var timer: Timer?
    /// Effective (hostname, port, proxied) per host from `ssh -G`.
    private var resolved: [UUID: (String, Int, Bool)] = [:]
    private let factsMaxAge: TimeInterval = 300

    func start() {
        guard timer == nil else { return }
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func status(_ id: UUID) -> HostStatus { status[id] ?? HostStatus() }

    func invalidate(_ id: UUID) {
        resolved[id] = nil
        Task { await refresh(id, forceFacts: false) }
    }

    func refreshAll() {
        for h in HostStore.shared.hosts { Task { await refresh(h.id, forceFacts: false) } }
    }

    private func update(_ id: UUID, _ change: (inout HostStatus) -> Void) {
        var s = status[id] ?? HostStatus()
        change(&s)
        status[id] = s
    }

    /// Reachability + shared-connection check, then facts when stale (or forced).
    func refresh(_ id: UUID, forceFacts: Bool) async {
        guard let h = HostStore.shared.host(id) else { return }
        if status(id).reach == .unknown { update(id) { $0.reach = .checking } }

        // 1. Resolve effective hostname/port (handles ~/.ssh/config aliases).
        if resolved[id] == nil {
            let r = await ProcessRunner.run(SSH.executable, SSH.baseArgs(h) + ["-G", h.address], timeout: 5)
            var host = h.address, port = h.port ?? 22, proxied = !h.jumpHost.isEmpty
            for line in r.stdout.split(separator: "\n") {
                let p = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard p.count == 2 else { continue }
                switch p[0] {
                case "hostname": host = p[1]
                case "port": port = Int(p[1]) ?? port
                case "proxyjump", "proxycommand": if p[1] != "none" { proxied = true }
                default: break
                }
            }
            resolved[id] = (host, port, proxied)
        }
        let (rHost, rPort, proxied) = resolved[id]!

        // 2. Reachability (skip direct TCP when going through a jump host).
        let reach: Reach
        if proxied {
            reach = .viaProxy
        } else {
            reach = await Reachability.check(host: rHost, port: rPort) ? .online : .offline
        }

        // 3. Is a shared connection alive?
        let check = await ProcessRunner.run(SSH.executable, SSH.baseArgs(h) + ["-O", "check", h.address], timeout: 5)
        let shared = check.status == 0
        update(id) {
            $0.reach = reach
            $0.sharedConnection = shared
            $0.lastChecked = Date()
        }

        // 4. Facts when stale, forced, or a connection just appeared.
        let stale = h.factsUpdated.map { Date().timeIntervalSince($0) > factsMaxAge } ?? true
        let canTry = reach != .offline && (!status(id).needsLogin || shared)
        if canTry && (forceFacts || stale) {
            await fetchFacts(id)
        }
    }

    func fetchFacts(_ id: UUID) async {
        guard let h = HostStore.shared.host(id), !status(id).fetchingFacts else { return }
        update(id) { $0.fetchingFacts = true }
        let r = await ProcessRunner.run(SSH.executable, SSH.batchArgs(h, command: SSH.factsScript), timeout: 20)
        if r.status == 0 {
            HostStore.shared.storeFacts(id, SSH.parseFacts(r.stdout))
            update(id) { $0.needsLogin = false; $0.lastError = nil; $0.fetchingFacts = false }
        } else {
            let err = r.timedOut ? "Timed out" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let auth = err.contains("Permission denied") || err.contains("passphrase") || err.contains("Host key verification")
                || err.contains("keyboard-interactive")
            update(id) {
                $0.needsLogin = auth
                $0.lastError = err.isEmpty ? "ssh exited with \(r.status)" : String(err.suffix(300))
                $0.fetchingFacts = false
            }
        }
        // Background login may have created a shared connection.
        let check = await ProcessRunner.run(SSH.executable, SSH.baseArgs(h) + ["-O", "check", h.address], timeout: 5)
        update(id) { $0.sharedConnection = check.status == 0 }
    }

    /// Runs a saved quick command over the shared connection; output appears in the host panel.
    func run(_ cmd: QuickCommand, on id: UUID) {
        guard let h = HostStore.shared.host(id) else { return }
        let run = CommandRun(name: cmd.name, command: cmd.command)
        runs[id, default: []].insert(run, at: 0)
        if runs[id]!.count > 10 { runs[id]!.removeLast() }
        Task {
            let r = await ProcessRunner.run(SSH.executable, SSH.batchArgs(h, command: cmd.command), timeout: 60)
            guard let i = runs[id]?.firstIndex(where: { $0.id == run.id }) else { return }
            var out = r.stdout
            if !r.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + r.stderr }
            if r.timedOut { out += "\n[timed out after 60s]" }
            runs[id]![i].output = out
            runs[id]![i].status = r.status
            runs[id]![i].running = false
            runs[id]![i].duration = r.duration
            if r.status == 255 && (r.stderr.contains("Permission denied") || r.stderr.contains("passphrase")) {
                update(id) { $0.needsLogin = true }
            }
        }
    }

    func clearRuns(_ id: UUID) { runs[id] = [] }

    /// Closes the shared connection (ssh -O exit).
    func disconnect(_ id: UUID) {
        guard let h = HostStore.shared.host(id) else { return }
        Task {
            _ = await ProcessRunner.run(SSH.executable, SSH.baseArgs(h) + ["-O", "exit", h.address], timeout: 5)
            update(id) { $0.sharedConnection = false }
        }
    }

    /// Called when an interactive SSH pane connects/disconnects, to update the dot quickly.
    func poke(_ id: UUID) {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh(id, forceFacts: status(id).needsLogin)
        }
    }
}
