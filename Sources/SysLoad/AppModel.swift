import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    struct Sample: Identifiable {
        let t: Date
        let cpuUser: Double, cpuSystem: Double   // 0...1
        let memory: Double                       // 0...1
        let rx: Double, tx: Double               // bytes/s
        var id: Date { t }
    }

    static let interval: TimeInterval = 2
    static let historyLength = 90                // 3 minutes at 2 s

    @Published var cpu = CPULoad()
    @Published var memory = MemoryInfo()
    @Published var net = NetRate()
    @Published var netTotals = NetCounters()
    @Published var load: [Double] = [0, 0, 0]
    @Published var gpu: GPUInfo?
    @Published var disk: DiskInfo?
    @Published var interface: (name: String, ip: String?)?
    @Published var history: [Sample] = []
    @Published var processes: [ProcGroup] = []
    @Published var now = Date()
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    let bootTime = Sampler.bootTime()
    private let sampler = Sampler()
    private let psQueue = DispatchQueue(label: "sysload.ps", qos: .utility)
    private var psRunning = false
    private var timer: Timer?

    /// Details (processes, GPU, disk, interface) are read only while the panel is open.
    var panelOpen = false {
        didSet { if panelOpen && !oldValue { refreshDetails() } }
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    func tick() {
        now = Date()
        cpu = sampler.cpu()
        memory = sampler.memory()
        (net, netTotals) = sampler.network()
        history.append(Sample(t: now, cpuUser: cpu.user, cpuSystem: cpu.system,
                              memory: memory.fraction, rx: net.rx, tx: net.tx))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        if panelOpen { refreshDetails() }
    }

    func refreshDetails() {
        load = Sampler.loadAverage()
        gpu = Sampler.gpu()
        disk = Sampler.disk()
        interface = Sampler.primaryInterface()
        guard !psRunning else { return }
        psRunning = true
        psQueue.async {
            let list = Processes.snapshot()
            Task { @MainActor in
                self.processes = list
                self.psRunning = false
            }
        }
    }
}
