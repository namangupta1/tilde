import AppKit
import Foundation

/// Shells that outlive the app. Each pane runs inside a `tilde-session` daemon (bundled next to
/// the app binary); the terminal view only runs a small client that attaches to it. Quitting Tilde
/// detaches; reopening reattaches and replays recent output.
enum PersistentSessions {
    static let defaultsKey = "keepSessions"
    /// Exit status the client uses when another window took over the session.
    static let kickedExitCode: Int32 = 197

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Short path: Unix socket paths are limited to 104 bytes.
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tilde/s", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }()

    static var helper: String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let path = exe.deletingLastPathComponent().appendingPathComponent("tilde-session").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var available: Bool { enabled && helper != nil }

    static func socket(for paneID: UUID) -> String { dir.appendingPathComponent(paneID.uuidString).path }

    /// PID of the real shell inside the daemon (written by the daemon at start).
    static func shellPid(for paneID: UUID) -> pid_t? {
        guard let s = try? String(contentsOfFile: socket(for: paneID) + ".pid", encoding: .utf8),
              let p = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), p > 1 else { return nil }
        return p
    }

    /// Hangs up the shell and removes the session (runs in the background).
    static func kill(_ paneID: UUID) {
        guard let helper else { return }
        let sock = socket(for: paneID)
        guard FileManager.default.fileExists(atPath: sock) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["kill", sock]
        try? p.run()
    }

    static func liveIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { $0.hasSuffix(".pid") ? nil : UUID(uuidString: $0) }
    }

    /// Ends sessions that no pane refers to any more (e.g. closed while the app was crashing).
    static func cleanup(keeping: Set<UUID>) {
        for id in liveIDs() where !keeping.contains(id) { kill(id) }
    }

    static func killAll() { for id in liveIDs() { kill(id) } }
}
