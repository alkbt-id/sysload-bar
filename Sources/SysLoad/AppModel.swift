import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    struct Sample: Identifiable {
        let t: Date
        let cpuUser: Double, cpuSystem: Double   // 0...1
        var cpuTemp: Double?                     // °C, hottest die sensor
        let memory: Double                       // 0...1
        let rx: Double, tx: Double               // bytes/s
        var id: Date { t }
    }

    static let interval: TimeInterval = 2
    static let historyLength = 90                // 3 minutes at 2 s
    /// Ollama's processes are re-listed every 3rd tick.
    static let ollamaEvery = 3

    @Published var cpu = CPULoad()
    @Published var memory = MemoryInfo()
    @Published var net = NetRate()
    @Published var netTotals = NetCounters()
    @Published var load: [Double] = [0, 0, 0]
    @Published var gpu: GPUInfo?
    @Published var disk: DiskInfo?
    @Published var temps = Temperatures()
    @Published var interface: (name: String, ip: String?)?
    @Published var history: [Sample] = []
    @Published var processes: [ProcGroup] = []
    @Published var ollama: OllamaStatus?         // nil: not running
    @Published var ollamaBusy = false            // a model is generating
    @Published var now = Date()
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    let bootTime = Sampler.bootTime()
    private let sampler = Sampler()
    private let thermal = Thermal()
    private let psQueue = DispatchQueue(label: "sysload.ps", qos: .utility)
    private var psRunning = false
    private let ollamaClient = Ollama()
    private let ollamaProcesses = OllamaProcesses()
    private var ollamaRunning = false
    private var ticks = 0
    private var timer: Timer?

    /// Details (processes, GPU, disk, interface, Ollama stats) are read only while the panel is open.
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
        temps = thermal.read()
        memory = sampler.memory()
        (net, netTotals) = sampler.network()
        history.append(Sample(t: now, cpuUser: cpu.user, cpuSystem: cpu.system, cpuTemp: temps.cpuMax,
                              memory: memory.fraction, rx: net.rx, tx: net.tx))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        if ticks % Self.ollamaEvery == 0 {
            // With the panel closed the API is asked only when Ollama's processes change (a model loaded or unloaded)
            // and once a minute: each request is a line in its log.
            let changed = ollamaProcesses.rescan()
            if !panelOpen, changed || ticks % 30 == 0 { refreshOllama(details: false) }
        }
        ollamaBusy = ollamaProcesses.cores() > 0.2
        if panelOpen { refreshDetails() }
        ticks += 1
    }

    var ollamaState: OllamaState? {
        ollama.map { $0.loaded.isEmpty ? .noModel : ollamaBusy ? .busy : .loaded }
    }

    func refreshDetails() {
        load = Sampler.loadAverage()
        gpu = Sampler.gpu()
        disk = Sampler.disk()
        interface = Sampler.primaryInterface()
        refreshOllama(details: true)
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

    /// The menu bar shows whether a model is loaded, so this runs with the panel closed too, without the panel-only details.
    private func refreshOllama(details: Bool) {
        guard !ollamaRunning else { return }
        ollamaRunning = true
        Task {
            ollama = await ollamaClient.status(details: details)
            ollamaRunning = false
        }
    }
}
