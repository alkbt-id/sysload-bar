import Foundation

/// Processes grouped by app: every helper inside "Foo.app/" counts towards Foo, like the screenshot's
/// "Visual Studio Code 112%" instead of a dozen "Code Helper" rows.
struct ProcGroup: Identifiable {
    let id: String          // app bundle path or executable path
    var name: String
    var cpu: Double         // percent of one core, can exceed 100
    var memory: UInt64      // resident bytes
    var count: Int
}

enum Processes {
    static func snapshot() -> [ProcGroup] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pcpu=,rss=,comm="]
        p.environment = ["LC_ALL": "C"]    // "12.5", not "12,5"
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return group(String(decoding: data, as: UTF8.self))
    }

    static func group(_ psOutput: String) -> [ProcGroup] {
        var groups: [String: ProcGroup] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let cpu = Double(fields[0]), let rss = UInt64(fields[1]) else { continue }
            let (key, name) = owner(of: String(fields[2]))
            groups[key, default: ProcGroup(id: key, name: name, cpu: 0, memory: 0, count: 0)].cpu += cpu
            groups[key]!.memory += rss * 1024
            groups[key]!.count += 1
        }
        return Array(groups.values)
    }

    /// Outermost ".app" in the path, or the executable itself.
    static func owner(of path: String) -> (key: String, name: String) {
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound]) + ".app"
            return (app, String((app as NSString).lastPathComponent.dropLast(4)))
        }
        return (path, (path as NSString).lastPathComponent)
    }
}

/// Facts about one process from libproc and sysctl, for the few processes watched on every tick (Ollama, PyTorch).
enum ProcInfo {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()
    private static let argmax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var v: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &v, &size, nil, 0) == 0 ? Int(v) : 4096
    }()

    /// Every process with its executable path (resolved: a venv's python shows as the interpreter it links to).
    static func all() -> [(pid: pid_t, path: String)] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)     // PROC_PIDPATHINFO_MAXSIZE
        return pids.prefix(max(0, count)).compactMap { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? (pid, String(cString: path)) : nil
        }
    }

    /// argv. KERN_PROCARGS2 is argc, then the executable path, NUL padding, argv and the environment.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [UInt8](repeating: 0, count: argmax)
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        return buf[4..<size].split(separator: 0).dropFirst().prefix(argc).map { String(decoding: $0, as: UTF8.self) }
    }

    static func parent(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    /// CPU time so far, ns, and the memory the process is charged for (Activity Monitor's "Memory"), which on a Mac
    /// includes what it allocated for the GPU. nil when the process is gone.
    static func usage(_ pid: pid_t) -> (cpu: UInt64, footprint: UInt64)? {
        var u = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &u) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        // Mach time units, which on Apple Silicon are not nanoseconds.
        let cpu = (u.ri_user_time + u.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
        return r == 0 ? (cpu, u.ri_phys_footprint) : nil
    }

    /// Whether a file whose path contains `fragment` is mapped, e.g. a library the process loaded. Walks the memory
    /// regions from the bottom, so a hit among the libraries is quick; a miss walks them all (≈1 ms for a small process).
    static func maps(_ pid: pid_t, _ fragment: String) -> Bool {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        while proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size) == size {
            let path = withUnsafeBytes(of: info.prp_vip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if path.contains(fragment) { return true }
            address = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size
        }
        return false
    }
}
