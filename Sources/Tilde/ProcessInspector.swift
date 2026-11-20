import Darwin
import Foundation

/// Reads info about child processes without touching the terminal stream.
enum ProcessInspector {
    /// Current working directory of a process.
    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Name of the process group currently in the foreground of the PTY (e.g. "vim", "ssh").
    static func foregroundName(ptyFD: Int32) -> String? {
        guard ptyFD >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFD)
        guard pgid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(pgid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Foreground program of the terminal a shell is attached to (via the shell's PID).
    static func foregroundName(ofShell pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let pgid = pid_t(info.e_tpgid)
        guard pgid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard proc_name(pgid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}
