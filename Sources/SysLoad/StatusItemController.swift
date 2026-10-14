import AppKit
import SwiftUI
import Combine

/// Menu bar item: "CPU 15%  RAM 80%". Everything else lives in the panel.
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
        let h: CGFloat = 22
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let gap: CGFloat = 8
        let baseline: CGFloat = 7

        // Fixed value width ("100%"), right-aligned: the item doesn't jitter as numbers change.
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)
        let parts = [("CPU", cpu), ("RAM", memory)].map { title, f in
            (NSAttributedString(string: title, attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]),
             NSAttributedString(string: Fmt.percent(f), attributes: [.font: valueFont, .foregroundColor: Palette.barColor(f)]))
        }
        let blockWidth = parts.map { ceil($0.0.size().width) + 3 + valueWidth }
        let width = blockWidth.reduce(0, +) + gap * CGFloat(parts.count - 1)

        // draw(at:) takes the line's bottom-left corner; baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, (title, value)) in parts.enumerated() {
                title.draw(at: NSPoint(x: x, y: baseline + labelFont.descender))
                value.draw(at: NSPoint(x: x + blockWidth[i] - value.size().width, y: baseline + valueFont.descender))
                x += blockWidth[i] + gap
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
