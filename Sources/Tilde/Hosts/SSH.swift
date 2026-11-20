import Foundation
import Network

/// Builds ssh invocations that share one multiplexed connection per host (ControlMaster).
enum SSH {
    static let executable = "/usr/bin/ssh"

    /// Short path without spaces: unix socket paths are limited to ~104 chars.
    static let controlDir: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/\(AppInfo.name)/cm")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static func baseArgs(_ h: Host) -> [String] {
        var a = ["-o", "ControlMaster=auto",
                 "-o", "ControlPath=\(controlDir)/%C",
                 "-o", "ControlPersist=15m",
                 "-o", "ServerAliveInterval=30"]
        if let p = h.port { a += ["-p", String(p)] }
        if !h.identityFile.isEmpty { a += ["-i", (h.identityFile as NSString).expandingTildeInPath] }
        if !h.jumpHost.isEmpty { a += ["-J", h.jumpHost] }
        if !h.user.isEmpty { a += ["-l", h.user] }
        a += splitArgs(h.extraArgs)
        return a
    }

    /// Interactive login (for a terminal pane). Env vars are exported on the remote side.
    static func interactiveArgs(_ h: Host) -> [String] {
        var a = baseArgs(h) + ["-o", "ConnectTimeout=10"]
        let exports = h.env.filter { !$0.key.isEmpty }.map { "export \($0.key)=\(shellQuote($0.value))" }
        if exports.isEmpty {
            a.append(h.address)
        } else {
            a += ["-t", h.address, exports.joined(separator: "; ") + "; exec \"${SHELL:-/bin/sh}\" -l"]
        }
        return a
    }

    /// Non-interactive, never prompts (BatchMode). Reuses the shared connection when one exists.
    static func batchArgs(_ h: Host, command: String) -> [String] {
        baseArgs(h) + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-T", h.address, command]
    }

    /// scp over the shared connection (never prompts). Destination `remoteDir` empty = home.
    static func scpArgs(_ h: Host, files: [String], remoteDir: String) -> [String] {
        var a = ["-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDir)/%C", "-o", "ControlPersist=15m",
                 "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-r", "-p"]
        if let p = h.port { a += ["-P", String(p)] }
        if !h.identityFile.isEmpty { a += ["-i", (h.identityFile as NSString).expandingTildeInPath] }
        if !h.jumpHost.isEmpty { a += ["-J", h.jumpHost] }
        // Only -o options carry over from ssh's extra args.
        let extra = splitArgs(h.extraArgs)
        var i = 0
        while i < extra.count {
            if extra[i] == "-o", i + 1 < extra.count { a += ["-o", extra[i + 1]]; i += 2; continue }
            if extra[i].hasPrefix("-o"), extra[i].count > 2 { a.append(extra[i]) }
            i += 1
        }
        a += ["--"] + files
        let target = h.user.isEmpty ? h.address : "\(h.user)@\(h.address)"
        a.append(target + ":" + remoteDir)
        return a
    }

    /// Human-readable command for copying.
    static func commandLine(_ h: Host) -> String {
        var parts = ["ssh"]
        if let p = h.port { parts += ["-p", String(p)] }
        if !h.identityFile.isEmpty { parts += ["-i", h.identityFile] }
        if !h.jumpHost.isEmpty { parts += ["-J", h.jumpHost] }
        if !h.extraArgs.isEmpty { parts.append(h.extraArgs) }
        parts.append(h.target)
        return parts.joined(separator: " ")
    }

    /// Splits a user-entered argument string, honouring simple quotes.
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == " " || ch == "\t" { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Prints key=value lines; POSIX sh so it works on Linux, BSD and macOS hosts.
    static let factsScript = #"""
    echo "hostname=$(hostname 2>/dev/null)"
    if [ -r /etc/os-release ]; then . /etc/os-release; echo "os=$PRETTY_NAME"; else echo "os=$(uname -sr)"; fi
    echo "kernel=$(uname -r)"
    echo "arch=$(uname -m)"
    u=$(uptime -p 2>/dev/null | sed 's/^up //'); [ -z "$u" ] && u=$(uptime | sed 's/.*up *//; s/, *[0-9]* user.*//'); echo "uptime=$u"
    if [ -r /proc/loadavg ]; then echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"; else echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | xargs)"; fi
    echo "cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
    if command -v free >/dev/null 2>&1; then free -m | awk '/^Mem:/{printf "memory=%d / %d MB (%d%%)\n", $3, $2, ($2>0)?$3*100/$2:0}'
    else m=$(sysctl -n hw.memsize 2>/dev/null) && echo "memory=$((m/1048576)) MB total"; fi
    df -Ph / 2>/dev/null | awk 'NR==2{print "disk=" $3 " / " $2 " (" $5 ")"}'
    echo "ip=$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "users=$(who 2>/dev/null | wc -l | tr -d ' ')"
    """#

    static func parseFacts(_ out: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty { d[k] = v }
        }
        if d["uptime"] == nil || d["uptime"]!.isEmpty { d["uptime"] = nil }
        return d
    }
}

struct ProcessResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var duration: TimeInterval
}

/// Runs a process without blocking, robust to children that keep pipes open.
enum ProcessRunner {
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 20) async -> ProcessResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            let lock = NSLock()
            var out = Data(), err = Data()
            var finished = false
            var timedOut = false
            let start = Date()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); out.append(d); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; lock.lock(); err.append(d); lock.unlock()
            }
            func finish(_ status: Int32) {
                lock.lock()
                if finished { lock.unlock(); return }
                finished = true
                lock.unlock()
                // Give the readability handlers a moment to drain, then stop reading
                // (a backgrounded ControlMaster may keep the pipe open forever).
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    lock.lock()
                    let r = ProcessResult(status: status,
                                          stdout: String(decoding: out, as: UTF8.self),
                                          stderr: String(decoding: err, as: UTF8.self),
                                          timedOut: timedOut, duration: Date().timeIntervalSince(start))
                    lock.unlock()
                    cont.resume(returning: r)
                }
            }
            p.terminationHandler = { proc in finish(proc.terminationStatus) }
            do { try p.run() } catch {
                lock.lock(); err.append(Data("\(error.localizedDescription)".utf8)); lock.unlock()
                finish(-1)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { lock.lock(); timedOut = true; lock.unlock(); p.terminate() }
            }
        }
    }
}

/// Plain TCP reachability check, independent of authentication.
enum Reachability {
    static func check(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var done = false
            func finish(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
