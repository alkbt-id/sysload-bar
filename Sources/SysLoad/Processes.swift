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
