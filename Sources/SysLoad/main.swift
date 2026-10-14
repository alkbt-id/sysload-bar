import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(model: model)
        model.start()
    }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        _ = NSApplication.shared
        Task {
            await Snapshot.run(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        RunLoop.main.run()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
