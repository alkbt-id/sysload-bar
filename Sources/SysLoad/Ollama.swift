import Foundation
import Darwin
import Metal

/// A model Ollama keeps in memory (`ollama ps`).
struct OllamaModel: Identifiable {
    let name: String
    let size: UInt64            // bytes in memory
    let sizeVRAM: UInt64        // part of it on the GPU
    let parameters: String      // "7.6B"
    let quantization: String    // "Q4_K_M"
    let context: Int?           // tokens
    let expiresAt: Date?        // unloaded after this unless a request comes (keep_alive)
    var id: String { name }
    var gpuShare: Double { size > 0 ? min(1, Double(sizeVRAM) / Double(size)) : 0 }
}

/// Recent work, from the server log.
struct OllamaActivity {
    var requests = 0            // generation requests in the last `window` seconds
    var lastRequest: Date?
    var latency: Double?        // mean response time of those requests, seconds
    var generation: Double?     // tokens/s over the recent requests
    var prompt: Double?         // prompt processing, tokens/s
}

/// The menu bar indicator; nil (no indicator) when Ollama isn't running.
enum OllamaState {
    case noModel
    case loaded(memory: Double, busy: Bool)     // memory: share of `Ollama.gpuMemory` the models take
}

struct OllamaStatus {
    var version = ""
    var loaded: [OllamaModel] = []
    var installed = 0
    var installedSize: UInt64 = 0   // on disk
    var activity: OllamaActivity?   // nil when the log isn't found
    var memory: UInt64 { loaded.reduce(0) { $0 + $1.size } }
}

/// Ollama state from its HTTP API (models in memory, downloaded models) and its server log (requests, speed).
actor Ollama {
    // OLLAMA_HOST isn't visible to a LaunchAgent anyway, so only the default address.
    private static let base = URL(string: "http://127.0.0.1:11434")!

    /// What the GPU can hold; on a Mac Ollama treats it as VRAM (≈ 3/4 of RAM: 37 GiB of 48).
    nonisolated static let gpuMemory = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
        ?? ProcessInfo.processInfo.physicalMemory * 3 / 4

    nonisolated static let isInstalled = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1
        return URLSession(configuration: c)
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private var log = OllamaLog()
    private var activity: OllamaActivity?
    // Version and the downloaded list rarely change: refetched every 30 s, not on every tick.
    private var catalog: (version: String, count: Int, size: UInt64, at: Date)?

    private struct PS: Decodable {
        struct Details: Decodable { let parameterSize: String?, quantizationLevel: String? }
        struct Entry: Decodable {
            let name: String, size: UInt64, sizeVram: UInt64?, expiresAt: String?, contextLength: Int?, details: Details?
        }
        let models: [Entry]
    }
    private struct Tags: Decodable {
        struct Entry: Decodable { let size: UInt64 }
        let models: [Entry]
    }
    private struct Version: Decodable { let version: String }

    /// nil when the server doesn't answer. Without `details` only the models in memory are fetched (for the menu bar);
    /// the downloaded list and the log keep their last values.
    func status(details: Bool) async -> OllamaStatus? {
        guard let ps: PS = await get("api/ps") else { return nil }
        if details, catalog == nil || Date().timeIntervalSince(catalog!.at) > 30,
           let tags: Tags = await get("api/tags"), let v: Version = await get("api/version") {
            catalog = (v.version, tags.models.count, tags.models.reduce(0) { $0 + $1.size }, Date())
        }
        if details { activity = log.read() }
        let loaded = ps.models.map {
            OllamaModel(name: $0.name, size: $0.size, sizeVRAM: $0.sizeVram ?? 0,
                        parameters: $0.details?.parameterSize ?? "", quantization: $0.details?.quantizationLevel ?? "",
                        context: $0.contextLength, expiresAt: $0.expiresAt.flatMap(Self.date))
        }
        return OllamaStatus(version: catalog?.version ?? "", loaded: loaded,
                            installed: catalog?.count ?? 0, installedSize: catalog?.size ?? 0,
                            activity: activity)
    }

    private func get<T: Decodable>(_ path: String) async -> T? {
        guard let (data, response) = try? await session.data(from: Self.base.appendingPathComponent(path)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// "2026-10-23T18:50:03.594318+03:00", with or without the fraction.
    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Ollama's processes: the server and a runner per loaded model, found by path ("…/ollama", "…/ollama/llama-server",
/// "Ollama.app/…"), so both the Homebrew service and the app work. The runners' CPU time shows when a model is
/// generating: it grows by several seconds per second then, and stands still when idle, even with the model on the GPU.
final class OllamaProcesses {
    private var pids: Set<pid_t> = []
    private var cpu: [pid_t: UInt64] = [:]      // runners' CPU time so far, ns
    private var last: Date?
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

    /// Re-lists the processes; true when the set changed (a model loaded or unloaded, the server started or stopped).
    func rescan() -> Bool {
        var all = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4096)     // PROC_PIDPATHINFO_MAXSIZE
        let found = Set(all.prefix(max(0, count)).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).lowercased().contains("ollama")
        })
        guard found != pids else { return false }
        pids = found
        // The server and CLI commands ("ollama pull") also use CPU, downloading and hashing models; answering happens
        // in the runners the server starts.
        let servers = Set(found.filter { Self.command($0) == "serve" })
        let runners = found.filter { servers.contains(Self.parent($0)) }
        cpu = Dictionary(uniqueKeysWithValues: runners.map { ($0, cpu[$0] ?? Self.cpuTime($0) ?? 0) })
        return true
    }

    /// Cores busy since the last call.
    func cores() -> Double {
        let now = Date()
        defer { last = now }
        var used: UInt64 = 0
        for (pid, before) in cpu {
            guard let t = Self.cpuTime(pid) else { continue }    // exited; dropped on the next rescan
            used += t > before ? t - before : 0
            cpu[pid] = t
        }
        guard let last, now > last else { return 0 }
        return Double(used) / 1e9 / now.timeIntervalSince(last)
    }

    /// argv[1], e.g. "serve". KERN_PROCARGS2 is argc, then the executable path, NUL padding, argv and the environment.
    private static func command(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [UInt8](repeating: 0, count: argmax)
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4,
              buf.withUnsafeBytes({ $0.load(as: Int32.self) }) > 1 else { return nil }
        let words = buf[4..<size].split(separator: 0)      // path, argv[0], argv[1], …
        return words.count > 2 ? String(decoding: words[words.startIndex + 2], as: UTF8.self) : nil
    }

    private static func parent(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
    }

    private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var u = rusage_info_v0()
        let r = withUnsafeMutablePointer(to: &u) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        // Mach time units, which on Apple Silicon are not nanoseconds.
        return r == 0 ? (u.ri_user_time + u.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom) : nil
    }
}

/// Tails the server log. Ollama logs every HTTP request:
///   [GIN] 2026/10/23 - 18:23:37 | 200 |    393.9185ms |       127.0.0.1 | POST     "/api/generate"
/// and the llama.cpp runner the speed of each one:
///   prompt eval time =     282.70 ms /   201 tokens (    1.41 ms per token,   711.01 tokens per second)
///          eval time =     153.64 ms /    12 tokens (   13.97 ms per token,    71.60 tokens per second)
/// The file is read incrementally: only what was appended since the last read.
struct OllamaLog {
    static let window: TimeInterval = 300
    private static let firstRead: UInt64 = 4 << 20     // on start, the last 4 MB is plenty for 5 minutes
    private static let speedSamples = 20
    // Ollama.app, Homebrew service on Apple Silicon, on Intel.
    private static let candidates = ["~/.ollama/logs/server.log", "/opt/homebrew/var/log/ollama.log", "/usr/local/var/log/ollama.log"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    private static let timing = #/(prompt )?eval time =\s*([\d.]+) ms /\s*(\d+) (?:tokens|runs)/#
    private static let ginDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd - HH:mm:ss"     // local time
        return f
    }()

    private var url: URL?
    private var offset: UInt64 = 0
    private var partial = Data()                    // unfinished last line
    private var requests: [(at: Date, seconds: Double)] = []
    private var lastRequest: Date?
    private var generation: [(ms: Double, tokens: Int)] = []
    private var prompt: [(ms: Double, tokens: Int)] = []

    mutating func read() -> OllamaActivity? {
        // The most recently written log, in case both the app and the Homebrew service were used.
        let found = Self.candidates
            .compactMap { u in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .max { $0.1 < $1.1 }?.0
        guard let found, let handle = try? FileHandle(forReadingFrom: found) else { return nil }
        defer { try? handle.close() }
        if found != url { self = OllamaLog(); url = found }

        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset { offset = 0; partial = Data() }    // rotated or truncated
        var skipFirstLine = false
        if end - offset > Self.firstRead {
            offset = end - Self.firstRead
            partial = Data()
            skipFirstLine = true                            // starts mid-line
        }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)

        var chunk = partial + data
        if let nl = chunk.lastIndex(of: 0x0A) {
            partial = chunk[(nl + 1)...]
            chunk = chunk[..<nl]
        } else {
            partial = chunk
            chunk = Data()
        }
        var lines = String(decoding: chunk, as: UTF8.self).split(separator: "\n")
        if skipFirstLine, !lines.isEmpty { lines.removeFirst() }
        lines.forEach { parse($0) }

        let since = Date().addingTimeInterval(-Self.window)
        requests.removeAll { $0.at < since }
        return OllamaActivity(requests: requests.count,
                              lastRequest: lastRequest,
                              latency: requests.isEmpty ? nil : requests.reduce(0) { $0 + $1.seconds } / Double(requests.count),
                              generation: Self.speed(generation),
                              prompt: Self.speed(prompt))
    }

    private mutating func parse(_ line: Substring) {
        if line.hasPrefix("[GIN]") {
            let f = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 5 else { return }
            let call = f[4].split(separator: " ", omittingEmptySubsequences: true)
            guard call.count == 2, call[0] == "POST", Self.isGeneration(call[1].trimmingCharacters(in: ["\""])),
                  let at = Self.ginDate.date(from: String(f[0].dropFirst(5)).trimmingCharacters(in: .whitespaces)) else { return }
            lastRequest = at
            requests.append((at, Self.seconds(f[2]) ?? 0))
        } else if let m = line.firstMatch(of: Self.timing), let ms = Double(m.2), let n = Int(m.3), n > 0 {
            if m.1 != nil { Self.push(&prompt, (ms, n)) } else { Self.push(&generation, (ms, n)) }
        }
    }

    /// Requests that run a model; our own polling (/api/ps, /api/tags) and model management are not counted.
    private static func isGeneration(_ path: String) -> Bool {
        ["/api/generate", "/api/chat", "/api/embed", "/v1/"].contains { path.hasPrefix($0) }
    }

    private static func push(_ list: inout [(ms: Double, tokens: Int)], _ sample: (Double, Int)) {
        list.append(sample)
        if list.count > speedSamples { list.removeFirst(list.count - speedSamples) }
    }

    /// Tokens over time across samples, so a 2-token reply doesn't swing the number.
    private static func speed(_ list: [(ms: Double, tokens: Int)]) -> Double? {
        let ms = list.reduce(0) { $0 + $1.ms }
        return ms > 0 ? Double(list.reduce(0) { $0 + $1.tokens }) / ms * 1000 : nil
    }

    /// Go duration: "393.9185ms", "12.5µs", "1.2s", "2m3.4s".
    static func seconds(_ s: String) -> Double? {
        for (unit, k) in [("ns", 1e-9), ("µs", 1e-6), ("us", 1e-6), ("ms", 1e-3)] where s.hasSuffix(unit) {
            return Double(s.dropLast(unit.count)).map { $0 * k }
        }
        var total = 0.0, number = ""
        for c in s {
            switch c {
            case "h": total += (Double(number) ?? 0) * 3600; number = ""
            case "m": total += (Double(number) ?? 0) * 60; number = ""
            case "s": total += Double(number) ?? 0; number = ""
            default: number.append(c)
            }
        }
        return number.isEmpty ? total : nil
    }
}
