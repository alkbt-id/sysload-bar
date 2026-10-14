import Foundation
import Darwin
import IOKit
import SystemConfiguration

/// CPU time split, fractions of all cores (0...1).
struct CPULoad {
    var user = 0.0
    var system = 0.0
    var total: Double { min(1, user + system) }
    var idle: Double { max(0, 1 - total) }
}

/// Memory in bytes, split the way Activity Monitor does it.
struct MemoryInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    var pressure: Int32 = 1

    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

/// Bytes per second.
struct NetRate {
    var rx = 0.0
    var tx = 0.0
}

struct NetCounters {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

struct GPUInfo {
    var utilization: Double    // 0...1
    var memoryUsed: UInt64
    var memoryAllocated: UInt64
}

struct DiskInfo {
    var total: Int64
    var free: Int64
    var fraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

/// Reads system counters. CPU and network are rates, so they need the previous sample.
final class Sampler {
    private let host = mach_host_self()
    private var lastTicks: [UInt32]?
    private var lastNet: (counters: NetCounters, at: Date)?

    // MARK: CPU

    func cpu() -> CPULoad {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return CPULoad() }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3]    // user, system, idle, nice
        defer { lastTicks = ticks }
        guard let prev = lastTicks else { return CPULoad() }
        // Counters are 32-bit and wrap, so subtract with overflow.
        let d = zip(ticks, prev).map { Double($0 &- $1) }
        let all = d.reduce(0, +)
        guard all > 0 else { return CPULoad() }
        return CPULoad(user: (d[0] + d[3]) / all, system: d[1] / all)
    }

    // MARK: Memory

    func memory() -> MemoryInfo {
        var out = MemoryInfo(total: ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
            out.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            out.wired = UInt64(stats.wire_count) * page
            out.compressed = UInt64(stats.compressor_page_count) * page
            out.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            out.swapUsed = swap.xsu_used
            out.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            out.pressure = level
        }
        return out
    }

    // MARK: Network

    /// Current rate and totals since boot over physical interfaces.
    func network() -> (rate: NetRate, totals: NetCounters) {
        let now = Date()
        let c = Self.netCounters()
        defer { lastNet = (c, now) }
        guard let prev = lastNet else { return (NetRate(), c) }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0 else { return (NetRate(), c) }
        // An interface going down resets its counters; treat a drop as zero, not a huge wrap.
        let rx = c.rx >= prev.counters.rx ? Double(c.rx - prev.counters.rx) / dt : 0
        let tx = c.tx >= prev.counters.tx ? Double(c.tx - prev.counters.tx) / dt : 0
        return (NetRate(rx: rx, tx: tx), c)
    }

    /// Tunnels (VPN), loopback and AirDrop/bridge interfaces would double-count traffic.
    private static let skippedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "gif", "stf", "bridge", "anpi", "ap"]

    /// 64-bit byte counters from NET_RT_IFLIST2 (getifaddrs only has 32-bit ones, which wrap at 4 GB).
    static func netCounters() -> NetCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return NetCounters() }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return NetCounters() }

        var out = NetCounters()
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil {
                        let ifname = String(cString: name)
                        if !skippedPrefixes.contains(where: ifname.hasPrefix) {
                            out.rx += h2.ifm_data.ifi_ibytes
                            out.tx += h2.ifm_data.ifi_obytes
                        }
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return out
    }

    /// Interface that carries the default route (e.g. "en0", or "utun4" with a VPN on) and its IPv4.
    static func primaryInterface() -> (name: String, ip: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "SysLoad" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = dict["PrimaryInterface"] as? String else { return nil }
        return (name, ipv4(of: name))
    }

    private static func ipv4(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: GPU

    /// Utilization from the IOAccelerator's PerformanceStatistics (works on Apple Silicon and most Intel GPUs).
    static func gpu() -> GPUInfo? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: GPUInfo?
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any],
                  let util = (perf["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            let info = GPUInfo(utilization: min(1, util / 100),
                               memoryUsed: (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0,
                               memoryAllocated: (perf["Alloc system memory"] as? NSNumber)?.uint64Value ?? 0)
            if best == nil || info.utilization > best!.utilization { best = info }
        }
        return best
    }

    // MARK: Disk, load, misc

    static func disk() -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskInfo(total: Int64(total), free: free)
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : [0, 0, 0]
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    static let chipName: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()
}
