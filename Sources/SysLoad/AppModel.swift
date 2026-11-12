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
    /// Ollama's and PyTorch's processes, and the network connection, are re-read every 3rd tick.
    static let ollamaEvery = 3
    /// An indicator stays filled this long after a model stops generating, so a short reply isn't missed.
    static let ollamaHold: TimeInterval = 60

    @Published var cpu = CPULoad()
    @Published var memory = MemoryInfo()
    @Published var net = NetRate()
    @Published var netTotals = NetCounters()
    @Published var load: [Double] = [0, 0, 0]
    @Published var gpu: GPUInfo?
    @Published var disk: DiskInfo?
    @Published var temps = Temperatures()
    @Published var power: Double?                // W, whole Mac; nil: no such sensor
    @Published var interface: (name: String, ip: String?)?
    @Published var network = NetStatus()         // cable and Wi-Fi: off, up, or carrying the VPN or proxy
    @Published var history: [Sample] = []
    @Published var processes: [ProcGroup] = []
    @Published var ollama: OllamaStatus?         // nil: not running
    @Published var ollamaActiveAt: Date?         // last tick a model was generating
    @Published var torch: [TorchProcess] = []
    @Published var torchActiveAt: Date?          // last tick a PyTorch process was computing
    @Published var hfCache: (count: Int, size: UInt64)?
    @Published var now = Date()
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    let bootTime = Sampler.bootTime()
    private let sampler = Sampler()
    private let thermal = Thermal()
    private let powerMeter = PowerMeter()
    private let linkMonitor = NetLinkMonitor()
    private let psQueue = DispatchQueue(label: "sysload.ps", qos: .utility)
    private var psRunning = false
    private let ollamaClient = Ollama()
    private let ollamaProcesses = OllamaProcesses()
    private let torchProcesses = TorchProcesses()
    private var hfCacheAt: Date?
    private var ollamaRunning = false
    private var ollamaRecheck = false
    private var ticks = 0
    private var timer: Timer?

    /// Details (processes, disk, interface, Ollama stats) are read only while the panel is open.
    var panelOpen = false {
        didSet {
            guard panelOpen && !oldValue else { return }
            temps = thermal.read()    // SSD and battery too, which the menu bar doesn't need
            refreshDetails()
        }
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
        gpu = sampler.gpu()
        temps = thermal.read(cpuOnly: !panelOpen)
        power = powerMeter.watts()
        memory = sampler.memory()
        (net, netTotals) = sampler.network()
        linkMonitor.record(sampler.interfaceBytes)
        history.append(Sample(t: now, cpuUser: cpu.user, cpuSystem: cpu.system, cpuTemp: temps.cpuMax,
                              memory: memory.fraction, rx: net.rx, tx: net.tx))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        if ollamaProcesses.cores() > 0.2 { ollamaActiveAt = now }
        if ticks % Self.ollamaEvery == 0 {
            // With the panel closed the API is asked only when needed, since each request is a line in Ollama's log:
            // when its processes change (a model loads or unloads) and once more after that, because a runner starts
            // before its model shows in the API; while a model works; and once a minute.
            network = linkMonitor.read()
            let all = ProcInfo.all()
            torchProcesses.rescan(all)
            let changed = ollamaProcesses.rescan(all)
            let working = ollamaActiveAt.map { now.timeIntervalSince($0) < AppModel.interval * Double(Self.ollamaEvery) } ?? false
            if !panelOpen, changed || ollamaRecheck || working || ticks % 30 == 0 { refreshOllama(details: false) }
            ollamaRecheck = changed
        }
        torch = torchProcesses.sample()
        if torch.contains(where: \.busy) { torchActiveAt = now }
        if panelOpen { refreshDetails() }
        ticks += 1
    }

    var ollamaState: OllamaState? {
        let busy = ollamaActiveAt.map { now.timeIntervalSince($0) < Self.ollamaHold } ?? false
        return ollama.map { $0.loaded.isEmpty ? .noModel : .loaded(memory: Double($0.memory) / Double(Ollama.gpuMemory), busy: busy) }
    }

    var torchState: TorchState? {
        guard !torch.isEmpty else { return nil }
        return TorchState(memory: Double(torch.reduce(0) { $0 + $1.memory }) / Double(Ollama.gpuMemory),
                          busy: torchActiveAt.map { now.timeIntervalSince($0) < Self.ollamaHold } ?? false)
    }

    func refreshDetails() {
        load = Sampler.loadAverage()
        disk = Sampler.disk()
        interface = Sampler.primaryInterface()
        refreshOllama(details: true)
        if hfCacheAt.map({ now.timeIntervalSince($0) > 30 }) ?? true {
            hfCache = HFCache.models()
            hfCacheAt = now
        }
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
