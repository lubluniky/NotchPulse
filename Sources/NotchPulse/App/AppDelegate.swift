import AppKit
import Combine

/// Entry point: an accessory (menu-bar-less, Dock-less) AppKit app.
@main
@MainActor
enum NotchPulseMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate          // NSApplication.delegate is weak; `delegate` is static.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = NotchViewModel()
    private var notch: NotchWindowController?
    private var mock: MockDataSource?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions()

        if options.useMock {
            let source = MockDataSource(model: viewModel, scenario: options.scenario)
            source.start()
            mock = source
            viewModel.onOpenThread = { id in print("NotchPulse(mock): open thread \(id)") }
            viewModel.onExpandedChanged = { expanded in print("NotchPulse(mock): fastMode=\(expanded)") }
        } else {
            bindLiveData()
        }

        let controller = NotchWindowController(model: viewModel)
        controller.forceExpanded = options.forceExpanded
        controller.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        controller.show()
        notch = controller

        DebugCapture.scheduleIfRequested { [weak self] in self?.viewModel.geometry ?? .placeholder }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mock?.stop()
        t3.stop()
        systemMonitor.stop()
        notch?.tearDown()
    }

    // MARK: - Live data

    private let t3 = T3Store()
    private let systemMonitor = SystemMonitor()

    private func bindLiveData() {
        t3.$snapshot
            .receive(on: RunLoop.main)
            .assign(to: &viewModel.$agents)
        systemMonitor.$snapshot
            .receive(on: RunLoop.main)
            .assign(to: &viewModel.$system)
        viewModel.onOpenThread = { [weak self] id in self?.t3.openThread(id) }
        viewModel.onExpandedChanged = { [weak self] expanded in
            self?.systemMonitor.fastMode = expanded      // 1 s sampling while open, 3 s otherwise
        }
        t3.start()
        systemMonitor.start()
    }

    // MARK: - Context menu (right-click on the island)

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open T3 Code", action: #selector(openT3), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        login.isEnabled = LoginItem.isSupported
        if !LoginItem.isSupported { login.toolTip = "Available when running the bundled NotchPulse.app" }
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchPulse", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openT3() {
        viewModel.openT3App()
    }

    @objc private func toggleLaunchAtLogin() {
        if let error = LoginItem.setEnabled(!LoginItem.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
