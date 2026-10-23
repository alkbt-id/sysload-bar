import AppKit
import SwiftUI
import Combine

/// Menu bar item: "CPU 15%" over "TMP 50°" (hottest CPU die sensor) in two small lines, with an Ollama indicator
/// to the left while it runs. Everything else lives in the panel.
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
        popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(model))

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageOnly
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.render() } }
            .store(in: &bag)
        render()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.panelOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.panelOpen = false
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = Self.image(cpu: model.cpu.total, temperature: model.temps.cpuMax, ollama: model.ollamaState)
        var tip = ["ЦП \(Fmt.percent(model.cpu.total)) · \(Fmt.degrees(model.temps.cpuMax))"]
        if let state = model.ollamaState {
            let names = (model.ollama?.loaded ?? []).map(\.name).joined(separator: ", ")
            let line = switch state {
            case .noModel: "Ollama: ни одна модель не загружена"
            case .loaded: "Ollama: \(names)"
            case .busy: "Ollama отвечает: \(names)"
            }
            tip.append(line)
        }
        tip.append("Нажмите, чтобы открыть панель")
        button.toolTip = tip.joined(separator: "\n")
    }

    static func image(cpu: Double, temperature: Double?, ollama: OllamaState? = nil) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        // (label, text, load for color, baseline)
        let rows = [("CPU", Fmt.percent(cpu), cpu, CGFloat(12)),
                    ("TMP", Fmt.degrees(temperature), Fmt.heat(temperature), CGFloat(2))]

        let labels = rows.map { NSAttributedString(string: $0.0, attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]) }
        let values = rows.map { NSAttributedString(string: $0.1, attributes: [.font: valueFont, .foregroundColor: Palette.barColor($0.2)]) }
        let labelWidth = ceil(labels.map { $0.size().width }.max() ?? 0)
        // Fixed value width ("100%"), right-aligned: the item doesn't jitter as numbers change.
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)
        let glyph = ollama.flatMap(indicator)
        let x0 = glyph.map { ceil($0.size.width) + 4 } ?? 0
        let width = x0 + labelWidth + 3 + valueWidth

        // draw(at:) takes the line's bottom-left corner; the baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            if let glyph {
                glyph.draw(in: NSRect(origin: NSPoint(x: 0, y: (22 - glyph.size.height) / 2), size: glyph.size))
            }
            for (i, row) in rows.enumerated() {
                labels[i].draw(at: NSPoint(x: x0, y: row.3 + labelFont.descender))
                values[i].draw(at: NSPoint(x: width - values[i].size().width, y: row.3 + valueFont.descender))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Dim: Ollama runs but no model is in memory; normal: a model is loaded; green: it is generating.
    private static func indicator(_ state: OllamaState) -> NSImage? {
        let color: NSColor = switch state {
        case .noModel: .tertiaryLabelColor
        case .loaded: .labelColor
        case .busy: Palette.nsColor(0)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "brain", accessibilityDescription: "Ollama")?.withSymbolConfiguration(config)
    }
}
