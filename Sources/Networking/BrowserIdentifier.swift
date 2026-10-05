import Darwin
import Foundation

/// Identifies which browser owns a local WebSocket connection, so meetings
/// from Chrome and Comet each record the matching MacWhisper source.
///
/// Every Chromium browser opens the socket from a helper process inside its
/// own bundle (e.g. `/Applications/Google Chrome.app/.../Google Chrome Helper`),
/// so the outermost `.app` in the owning process's path names the browser.
enum BrowserIdentifier {
    /// Name of the app (e.g. "Comet", "Google Chrome") whose process has a TCP
    /// socket from `clientPort` to `serverPort`, or `nil` if none is found.
    static func appName(clientPort: UInt16, serverPort: UInt16) -> String? {
        guard let pid = socketOwner(localPort: clientPort, remotePort: serverPort) else {
            return nil
        }
        return outermostAppName(path: executablePath(pid))
    }

    /// "/Applications/Google Chrome.app/Contents/.../Helper.app/..." -> "Google Chrome"
    static func outermostAppName(path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        let appPath = path[path.startIndex..<range.lowerBound]
        return appPath.split(separator: "/").last.map(String.init)
    }

    private static func socketOwner(localPort: UInt16, remotePort: UInt16) -> pid_t? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return nil }

        for pid in pids.prefix(Int(listed)) where pid > 0 {
            if hasTCPSocket(pid: pid, localPort: localPort, remotePort: remotePort) {
                return pid
            }
        }
        return nil
    }

    private static func hasTCPSocket(pid: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard used > 0 else { return false }

        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(used) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            if lport == localPort && fport == remotePort { return true }
        }
        return false
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
