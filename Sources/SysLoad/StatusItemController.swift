import AppKit
import SwiftUI
import Combine

/// Menu bar item: "CPU 15%" over "RAM 80%" in two small lines. Everything else lives in the panel.
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
        button.image = Self.image(cpu: model.cpu.total, memory: model.memory.fraction)
        button.toolTip = "ЦП \(Fmt.percent(model.cpu.total)) · память \(Fmt.percent(model.memory.fraction)) — нажмите, чтобы открыть панель"
    }

    static func image(cpu: Double, memory: Double) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let rows = [("CPU", cpu, CGFloat(12)), ("RAM", memory, CGFloat(2))]   // (label, value, baseline)

        let labels = rows.map { NSAttributedString(string: $0.0, attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]) }
        let values = rows.map { NSAttributedString(string: Fmt.percent($0.1), attributes: [.font: valueFont, .foregroundColor: Palette.barColor($0.1)]) }
        let labelWidth = ceil(labels.map { $0.size().width }.max() ?? 0)
        // Fixed value width ("100%"), right-aligned: the item doesn't jitter as numbers change.
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)
        let width = labelWidth + 3 + valueWidth

        // draw(at:) takes the line's bottom-left corner; the baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            for (i, row) in rows.enumerated() {
                labels[i].draw(at: NSPoint(x: 0, y: row.2 + labelFont.descender))
                values[i].draw(at: NSPoint(x: width - values[i].size().width, y: row.2 + valueFont.descender))
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
