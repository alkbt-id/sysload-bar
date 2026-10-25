import Foundation
import IOKit

/// A Python process that loaded PyTorch: a Jupyter kernel, a script, a training run. Transformers and the like run
/// inside it, so which model it holds and how fast it generates are not visible from outside.
struct TorchProcess: Identifiable {
    let pid: pid_t
    let project: String         // "05a-forward-pass": the folder holding the venv, or the script's folder
    let kind: String            // "Jupyter", "train.py", "python -m foo"
    var memory: UInt64          // footprint, GPU allocations included
    var gpu: Double             // share of the last interval the GPU worked for it, 0...1
    var cores: Double           // CPU cores busy over the last interval
    var id: pid_t { pid }
    var busy: Bool { gpu > 0.05 || cores > 0.5 }
}

/// The menu bar indicator; nil (no indicator) when no PyTorch process runs.
struct TorchState {
    let memory: Double          // share of `Ollama.gpuMemory` the processes take
    let busy: Bool
}

/// Finds PyTorch processes and measures them. A process counts when it maps torch's libraries, so a kernel shows up
/// once `import torch` runs. Its DataLoader workers (child processes with torch too) count towards it.
final class TorchProcesses {
    private struct Tracked {
        let project: String, kind: String
        var members: [pid_t] = []
    }
    private var tracked: [pid_t: Tracked] = [:]     // by the top torch process
    private var checked: Set<pid_t> = []            // pythons without torch, until the next full check
    private var gpuTime: [pid_t: UInt64] = [:]      // ns so far, per member
    private var cpuTime: [pid_t: UInt64] = [:]
    private var last: Date?
    private var rescans = 0

    /// Picks the PyTorch processes out of all processes. Pythons found without torch are checked again every
    /// 5th call, since a kernel imports torch whenever a cell asks.
    func rescan(_ all: [(pid: pid_t, path: String)]) {
        if rescans % 5 == 0 { checked = [] }
        rescans += 1
        let pythons = Set(all.filter { ($0.path as NSString).lastPathComponent.lowercased().hasPrefix("python") }.map(\.pid))
        let known = Set(tracked.values.flatMap(\.members))
        var torch = known.intersection(pythons)
        for pid in pythons.subtracting(known).subtracting(checked) {
            if ProcInfo.maps(pid, "/torch/lib/") { torch.insert(pid) } else { checked.insert(pid) }
        }
        checked.formIntersection(pythons)

        var next: [pid_t: Tracked] = [:]
        for pid in torch {
            var top = pid
            while case let up = ProcInfo.parent(top), torch.contains(up) { top = up }
            next[top, default: tracked[top].map { Tracked(project: $0.project, kind: $0.kind) } ?? Self.describe(top)].members.append(pid)
        }
        tracked = next
        let members = Set(next.values.flatMap(\.members))
        gpuTime = gpuTime.filter { members.contains($0.key) }
        cpuTime = cpuTime.filter { members.contains($0.key) }
    }

    /// Memory and load since the last call, biggest process first.
    func sample() -> [TorchProcess] {
        let now = Date()
        defer { last = now }
        let elapsed = last.map { now.timeIntervalSince($0) * 1e9 } ?? 0
        let gpu = tracked.isEmpty ? [:] : Self.gpuTimes()
        return tracked.map { top, t in
            var p = TorchProcess(pid: top, project: t.project, kind: t.kind, memory: 0, gpu: 0, cores: 0)
            for pid in t.members {
                guard let u = ProcInfo.usage(pid) else { continue }    // exited; dropped on the next rescan
                p.memory += u.footprint
                let g = gpu[pid] ?? 0
                if elapsed > 0 {
                    p.gpu += Double(g - min(g, gpuTime[pid] ?? g)) / elapsed
                    p.cores += Double(u.cpu - min(u.cpu, cpuTime[pid] ?? u.cpu)) / elapsed
                }
                gpuTime[pid] = g
                cpuTime[pid] = u.cpu
            }
            p.gpu = min(1, p.gpu)
            return p
        }
        .sorted { $0.memory > $1.memory }
    }

    /// GPU time per process, ns: every Metal client of the GPU is an IORegistry entry under it with the creator's pid
    /// and its accumulated GPU time (what Activity Monitor's "GPU Time" column shows).
    private static func gpuTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var gpus: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &gpus) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(gpus) }
        while case let gpu = IOIteratorNext(gpus), gpu != 0 {
            defer { IOObjectRelease(gpu) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(gpu, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                // "pid 33620, python3.14"
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      creator.hasPrefix("pid "), let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                result[pid, default: 0] += usage.reduce(0) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            }
        }
        return result
    }

    /// Names a process by its command line: "/…/05a-forward-pass/.venv/bin/python -m ipykernel_launcher …" is
    /// ("05a-forward-pass", "Jupyter"), "python /…/lab/train.py" is ("lab", "train.py").
    private static func describe(_ pid: pid_t) -> Tracked {
        let argv = ProcInfo.arguments(pid)
        let args = Array(argv.dropFirst())
        let kind: String
        var script: String?
        if args.contains(where: { $0.contains("ipykernel") }) {
            kind = "Jupyter"
        } else if let i = args.firstIndex(of: "-m"), i + 1 < args.count {
            kind = "python -m \(args[i + 1])"
        } else if args.contains("-c") {
            kind = "python -c"
        } else if let s = args.first(where: { !$0.hasPrefix("-") }) {
            script = s
            kind = (s as NSString).lastPathComponent
        } else {
            kind = "python"
        }
        // The venv's folder is the project's; argv[0] keeps the venv path the kernel resolves away.
        let python = argv.first ?? ""
        let project: String
        if let r = python.range(of: "/.venv/") ?? python.range(of: "/venv/") {
            project = (String(python[..<r.lowerBound]) as NSString).lastPathComponent
        } else if let script, script.contains("/") {
            project = ((script as NSString).deletingLastPathComponent as NSString).lastPathComponent
        } else {
            project = "PID \(pid)"
        }
        return Tracked(project: project, kind: kind)
    }
}

/// Models downloaded by Hugging Face libraries (transformers, diffusers…): ~/.cache/huggingface/hub. HF_HOME isn't
/// visible to a LaunchAgent, so only the default place.
enum HFCache {
    private static let hub = URL(fileURLWithPath: ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath)

    /// Model count and their size on disk; nil without the folder. Files are counted once: snapshots only link to blobs.
    static func models() -> (count: Int, size: UInt64)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: hub.path) else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let files = fm.enumerator(at: hub, includingPropertiesForKeys: Array(keys)) else { return nil }
        var size: UInt64 = 0
        for case let url as URL in files {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            size += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return (entries.filter { $0.hasPrefix("models--") }.count, size)
    }
}
