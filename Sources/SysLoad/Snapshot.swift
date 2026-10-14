import AppKit
import SwiftUI

/// `SysLoad --snapshot <dir> [--live]`: renders the panel and the menu bar item to PNG.
/// Without `--live` the data is made up, so the images are safe to publish.
@MainActor
enum Snapshot {
    static func run(to dir: URL) async {
        let model = AppModel()
        if CommandLine.arguments.contains("--live") {
            model.panelOpen = true
            for _ in 0..<5 {
                model.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            model.tick()
        } else {
            fillDemo(model)
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let host = NSHostingView(rootView: PopoverView().environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 900)
            host.appearance = NSAppearance(named: appearance)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: appearance)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 500_000_000)
            save(host, to: dir.appendingPathComponent("panel-\(suffix).png"))

            let img = StatusItemController.image(cpu: model.cpu.total, temperature: model.temps.cpuMax)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: img.size.width + 24, height: 24))
            bar.appearance = NSAppearance(named: appearance)
            bar.wantsLayer = true
            bar.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).cgColor
            let iv = NSImageView(frame: NSRect(x: 12, y: 1, width: img.size.width, height: img.size.height))
            iv.image = img
            bar.addSubview(iv)
            let w2 = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w2.appearance = NSAppearance(named: appearance)
            w2.contentView = bar
            save(bar, to: dir.appendingPathComponent("menubar-\(suffix).png"))
        }
    }

    private static func fillDemo(_ m: AppModel) {
        let now = Date()
        let gb: UInt64 = 1 << 30
        m.history = (0..<AppModel.historyLength).map { i in
            let x = Double(i)
            let burst = (40...55).contains(i) ? 0.35 : 0
            return AppModel.Sample(
                t: now.addingTimeInterval(-AppModel.interval * Double(AppModel.historyLength - 1 - i)),
                cpuUser: 0.08 + 0.05 * sin(x / 5) + burst + Double.random(in: 0...0.04),
                cpuSystem: 0.05 + 0.02 * sin(x / 3) + burst / 3,
                cpuTemp: 50 + burst * 60,
                memory: 0.78 + 0.02 * sin(x / 20),
                rx: max(0, 400_000 + 900_000 * sin(x / 7) + ((60...70).contains(i) ? 6_000_000 : 0)),
                tx: max(0, 60_000 + 40_000 * sin(x / 4)))
        }
        m.cpu = CPULoad(user: 0.09, system: 0.06)
        m.memory = MemoryInfo(total: 36 * gb, app: 17 * gb, wired: 5 * gb, compressed: 7 * gb,
                              cached: 6 * gb, swapUsed: gb / 2, swapTotal: 2 * gb, pressure: 2)
        m.net = NetRate(rx: 1_240_000, tx: 34_000)
        m.netTotals = NetCounters(rx: 18_400_000_000, tx: 2_100_000_000)
        m.load = [2.68, 2.97, 3.67]
        m.gpu = GPUInfo(utilization: 0.24, memoryUsed: 1_810_000_000, memoryAllocated: 4_590_000_000)
        m.temps = Temperatures(cpuMax: 59, cpuAvg: 54, ssd: 33, battery: 30)
        m.disk = DiskInfo(total: 1_000_000_000_000, free: 550_000_000_000)
        m.interface = ("en0", "192.168.1.24")
        m.processes = [
            ProcGroup(id: "/Applications/Safari.app", name: "Safari", cpu: 38.2, memory: 3 * gb, count: 9),
            ProcGroup(id: "/System/Applications/Utilities/Terminal.app", name: "Terminal", cpu: 12.5, memory: gb / 3, count: 2),
            ProcGroup(id: "/System/Library/CoreServices/Finder.app", name: "Finder", cpu: 3.1, memory: gb / 4, count: 1),
            ProcGroup(id: "/usr/sbin/WindowServer", name: "WindowServer", cpu: 21.4, memory: gb / 2, count: 1),
            ProcGroup(id: "kernel_task", name: "kernel_task", cpu: 8.7, memory: gb / 8, count: 1),
            ProcGroup(id: "/System/Applications/Music.app", name: "Music", cpu: 1.9, memory: gb / 3, count: 2),
        ]
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
