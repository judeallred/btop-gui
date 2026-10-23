import AppKit
import BtopCore
import Combine
import ServiceManagement
import SwiftUI

@main
enum BtopGUIApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor!
    private var statusItem: StatusItemController!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = Monitor()

        // `BtopGUI --snapshot out.png` renders the window to a PNG and exits (for docs and testing).
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[flag + 1]))
            return
        }


        statusItem = StatusItemController(monitor: monitor)

        // `kill`, logout and `launchctl` stop us with signals; resume everything first.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [monitor] in
                monitor?.releaseAllSync()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.releaseAllSync()
    }

    private func snapshot(to url: URL) {
        monitor.isVisible = true
        let view = NSHostingView(rootView: MonitorView(monitor: monitor))
        view.frame = NSRect(x: 0, y: 0, width: 940, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            NSApp.terminate(nil)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("btop-gui: login item change failed: \(error)")
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let monitor: Monitor
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MonitorView(monitor: monitor))
        popover.contentSize = NSSize(width: 940, height: 760)

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        monitor.$report
            .combineLatest(monitor.$autoPaused, monitor.$deprioritized)
            .receive(on: RunLoop.main)
            .sink { [weak self] report, paused, deprioritized in
                self?.updateIcon(report: report, throttling: !paused.isEmpty || !deprioritized.isEmpty, pausedCount: paused.count)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(report: HealthReport, throttling: Bool, pausedCount: Int) {
        guard let button = item.button else { return }
        let symbol: String
        var color: NSColor?
        switch report.level {
        case .lagging:
            symbol = "exclamationmark.triangle.fill"
            color = .systemRed
        case .strained:
            symbol = "exclamationmark.triangle.fill"
            color = .systemOrange
        case .elevated:
            symbol = throttling ? "tortoise.fill" : "gauge.with.dots.needle.67percent"
        case .ok:
            symbol = throttling ? "tortoise.fill" : "gauge.with.dots.needle.33percent"
        }

        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: report.level.label)?
            .withSymbolConfiguration(config)
        image?.isTemplate = color == nil
        button.image = image
        button.title = pausedCount > 0 ? " \(pausedCount)" : ""

        var tip = "btop-gui — \(report.level.label)"
        if !report.reasons.isEmpty { tip += ": " + report.reasons.joined(separator: ", ") }
        if pausedCount > 0 { tip += "\n\(pausedCount) job(s) paused by auto-throttle" }
        button.toolTip = tip
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.isVisible = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.isVisible = false
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFromMenu), keyEquivalent: "").target = self

        let modes = NSMenu()
        for mode in ThrottleMode.allCases {
            let entry = modes.addItem(withTitle: mode.label, action: #selector(setMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = monitor.mode == mode ? .on : .off
        }
        let modeItem = menu.addItem(withTitle: "Auto-throttle", action: nil, keyEquivalent: "")
        modeItem.submenu = modes

        menu.addItem(withTitle: "Resume everything", action: #selector(resumeAll), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit btop-gui", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openFromMenu() { togglePopover() }
    @objc private func resumeAll() { monitor.resumeEverything() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ThrottleMode(rawValue: raw) {
            monitor.mode = mode
        }
    }
}
