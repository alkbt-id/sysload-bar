import AppKit
import SwiftUI
import Combine

/// Menu bar item: "CPU 15%" over "GPU 24%", then a column with "PWR 15W" (the whole Mac) over "TMP 50°" (hottest CPU die
/// sensor), in two small lines, with Ollama and PyTorch indicators to the left while they run.
/// Everything else lives in the panel.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageOnly
        }

        // A tick changes several properties at once: one redraw after all of them.
        model.objectWillChange
            .debounce(for: .milliseconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
            .store(in: &bag)
        render()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.panelOpen = true
            popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(model))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A closed panel's SwiftUI views would still redraw their charts on every tick and hold their GPU textures,
    /// so they are built on open and dropped on close.
    func popoverDidClose(_ notification: Notification) {
        model.panelOpen = false
        popover.contentViewController = nil
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = Self.image(cpu: model.cpu.total, gpu: model.gpu?.utilization, power: model.power,
                                  temperature: model.temps.cpuMax, ollama: model.ollamaState, torch: model.torchState)
        var tip = ["ЦП \(Fmt.percent(model.cpu.total)) · \(Fmt.degrees(model.temps.cpuMax)) · "
            + "GPU \(model.gpu.map { Fmt.percent($0.utilization) } ?? "—") · Mac \(Fmt.watts(model.power))"]
        if let o = model.ollama, let state = model.ollamaState {
            let line = switch state {
            case .noModel: "Ollama: ни одна модель не загружена"
            case .loaded(_, let busy):
                activity(busy: busy) + o.loaded.map(\.name).joined(separator: ", ")
                    + " — \(Fmt.bytes(o.memory, binary: true)) из \(Fmt.bytes(Ollama.gpuMemory, binary: true)) памяти GPU"
            }
            tip.append(line)
        }
        if let state = model.torchState {
            let memory = model.torch.reduce(0) { $0 + $1.memory }
            tip.append(torchActivity(busy: state.busy) + model.torch.map(\.project).joined(separator: ", ")
                + " — \(Fmt.bytes(memory, binary: true)) из \(Fmt.bytes(Ollama.gpuMemory, binary: true)) памяти GPU")
        }
        tip.append("Нажмите, чтобы открыть панель")
        button.toolTip = tip.joined(separator: "\n")
    }

    /// "Ollama отвечает: ", or within the hold after a reply "Ollama, ответ 12 с назад: ".
    private func activity(busy: Bool) -> String {
        guard busy, let at = model.ollamaActiveAt else { return "Ollama: " }
        let ago = model.now.timeIntervalSince(at)
        return ago < AppModel.interval ? "Ollama отвечает: " : "Ollama, ответ \(Fmt.duration(ago)) назад: "
    }

    /// "PyTorch считает: ", or within the hold "PyTorch, считал 12 с назад: ".
    private func torchActivity(busy: Bool) -> String {
        guard busy, let at = model.torchActiveAt else { return "PyTorch: " }
        let ago = model.now.timeIntervalSince(at)
        return ago < AppModel.interval ? "PyTorch считает: " : "PyTorch, считал \(Fmt.duration(ago)) назад: "
    }

    static func image(cpu: Double, gpu: Double?, power: Double?, temperature: Double?, ollama: OllamaState? = nil, torch: TorchState? = nil) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let baselines: [CGFloat] = [12, 2]
        // Each column: its widest value, then a line per baseline as (label, text, load for color).
        let columns: [(widest: String, rows: [(String, String, Double)])] = [
            ("100%", [("CPU", Fmt.percent(cpu), cpu), ("GPU", gpu.map(Fmt.percent) ?? "—", gpu ?? 0)]),
            ("100W", [("PWR", Fmt.watts(power, unit: "W"), Fmt.powerLoad(power)), ("TMP", Fmt.degrees(temperature), Fmt.heat(temperature))]),
        ]

        let glyphs = [ollama.flatMap(indicator), torch.flatMap(indicator)].compactMap { $0 }
        var right = glyphs.reduce(-6) { $0 + ceil($1.size.width) + 4 }
        let cells = columns.map { column in
            let labels = column.rows.map { NSAttributedString(string: $0.0, attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]) }
            let values = column.rows.map { NSAttributedString(string: $0.1, attributes: [.font: valueFont, .foregroundColor: Palette.barColor($0.2)]) }
            let left = right + 6
            let labelWidth = ceil(labels.map { $0.size().width }.max() ?? 0)
            // Fixed value width, right-aligned: the item doesn't jitter as numbers change.
            right = left + labelWidth + 3 + ceil((column.widest as NSString).size(withAttributes: [.font: valueFont]).width)
            return (left: left, right: right, labels: labels, values: values)
        }
        let width = right

        // draw(at:) takes the line's bottom-left corner; the baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for glyph in glyphs {
                glyph.draw(in: NSRect(origin: NSPoint(x: x, y: (22 - glyph.size.height) / 2), size: glyph.size))
                x += ceil(glyph.size.width) + 4
            }
            for cell in cells {
                for (i, baseline) in baselines.enumerated() {
                    cell.labels[i].draw(at: NSPoint(x: cell.left, y: baseline + labelFont.descender))
                    cell.values[i].draw(at: NSPoint(x: cell.right - cell.values[i].size().width, y: baseline + valueFont.descender))
                }
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Dim: Ollama runs but no model is in memory. With models: green to red as they fill the GPU memory, filled while generating.
    private static func indicator(_ state: OllamaState) -> NSImage? {
        switch state {
        case .noModel: symbol("brain", color: .tertiaryLabelColor, name: "Ollama")
        case .loaded(let memory, let busy): symbol(busy ? "brain.fill" : "brain", color: Palette.gradient(memory), name: "Ollama")
        }
    }

    /// A flame, like PyTorch's logo: green to red as its processes fill the GPU memory, filled while they compute.
    private static func indicator(_ state: TorchState) -> NSImage? {
        symbol(state.busy ? "flame.fill" : "flame", color: Palette.gradient(state.memory), name: "PyTorch")
    }

    private static func symbol(_ symbol: String, color: NSColor, name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)?.withSymbolConfiguration(config)
    }
}
