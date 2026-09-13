import AppKit
import SwiftUI
import Combine
import HoustonCore

@main struct HoustonMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--claude-statusline") {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            do {
                try UsageReader.captureClaude(input)
                // Claude Code shows this text in its status line, so make the bridge useful there too.
                if let snapshot = try? UsageReader.parseClaude(input) {
                    print(("Houston" + snapshot.windows.map { " · \($0.name) \(Int($0.remaining))% left" }.joined()))
                } else { print("Houston connected · waiting for usage") }
            } catch { try? FileHandle.standardError.write(contentsOf: Data("Houston: unable to save usage\n".utf8)) }
            return
        }
        if CommandLine.arguments.contains("--check-system") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let sampler = SystemSampler()
                _ = await sampler.sample()
                try? await Task.sleep(for: .seconds(1))
                print(describe(await sampler.sample()).joined(separator: "\n"))
                done.signal()
            }
            done.wait()
            return
        }
        if CommandLine.arguments.contains("--check-github") {
            do {
                let overview = try GitHubReader.readOverview()
                print("Signed in as \(overview.login)")
                for (title, items) in [("Open pull requests", overview.authored), ("Review requests", overview.reviewRequests), ("Notifications", overview.notifications)] {
                    print("\(title): \(items.count)")
                    for item in items { print("  \(item.title) [\(item.state)] \(item.detail)") }
                }
                print("Recent repositories: \(overview.repositories.joined(separator: ", "))")
                if let note = overview.note { print("Note: \(note)") }
                if let repository = UserDefaults.standard.string(forKey: "repository") {
                    print("Watching \(repository)")
                    let activity = try GitHubReader.read(repository: repository)
                    print("  pull requests \(activity.pullRequests.count), runs \(activity.runs.count)")
                }
            } catch { print(error.localizedDescription); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--check-codex") {
            do {
                let snapshot = try UsageReader.readCodex()
                for window in snapshot.windows { print("\(window.name): \(Int(window.remaining))% left · \(window.countdown())") }
            } catch { print(error.localizedDescription); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

private func describe(_ system: SystemSnapshot) -> [String] {
    var lines = ["\(system.chip) (\(system.model)) · \(system.cores.count) cores · \(SystemFormat.memory(system.memoryTotal))",
                 "CPU " + (system.cpuLoad.map { "\(Int($0.rounded()))%" } ?? "n/a") + " · load " + system.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "),
                 "Cores " + system.cores.map { "\($0.efficiency ? "E" : "P")\(Int($0.load.rounded()))%" }.joined(separator: " "),
                 "GPU " + (system.gpuLoad.map { "\(Int($0.rounded()))%" } ?? "n/a"),
                 "Memory \(SystemFormat.memory(system.memoryUsed)) of \(SystemFormat.memory(system.memoryTotal)) · swap \(SystemFormat.memory(system.swapUsed))",
                 "Thermal \(system.thermalState)"]
    lines += system.sensors.map { String(format: "%@ %.1f°C hottest, %.1f°C average of %d sensors", $0.name, $0.hottest, $0.average, $0.count) }
    lines += system.fans.map { "Fan \($0.id + 1) \(Int($0.rpm)) rpm (\(Int($0.minimum))–\(Int($0.maximum)))" }
    if let power = system.systemPower { lines.append(String(format: "System power %.1f W", power) + (system.chargerPower.map { String(format: " · charger %.1f W", $0) } ?? "")) }
    if let battery = system.battery { lines.append("Battery \(battery.percent)% " + (battery.charging ? "charging" : battery.external ? "plugged in" : "discharging") + (battery.minutesRemaining.map { " · \(SystemFormat.duration(minutes: $0))" } ?? "")) }
    lines.append("Disk \(SystemFormat.disk(system.diskUsed)) of \(SystemFormat.disk(system.diskTotal)) · up \(SystemFormat.uptime(system.uptime))")
    return lines
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keep the entire panel inside the usable display, including scaled and portrait displays.
struct IslandGeometry {
    let compactWidth: CGFloat
    let expandedSize: NSSize
    let frame: NSRect

    init(screen: NSRect, visible: NSRect, topInset: CGFloat, notchWidth: CGFloat, expanded: Bool) {
        let availableWidth = max(1, visible.width - 24)
        compactWidth = min(max(240, notchWidth + 90), availableWidth)
        let top = topInset > 0 ? screen.maxY : visible.maxY - 7
        expandedSize = NSSize(width: min(460, availableWidth), height: min(600 + topInset, max(1, top - visible.minY - 12)))
        let size = expanded ? expandedSize : NSSize(width: compactWidth, height: max(34, topInset + 6))
        frame = NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panel: IslandPanel!
    private var status: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var closeTimer: Timer?
    private var targetScreen: NSScreen?
    private var keyboardOpened = false
    private var pointerExitedAt: Date?
    private var topInset: CGFloat = 0
    private var compactWidth: CGFloat = 210
    private var menu: NSMenu!
    private var hosting: NSHostingView<IslandView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Houston")
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu = NSMenu()
        menu.addItem(withTitle: "Show Houston", action: #selector(show), keyEquivalent: "o")
        menu.addItem(withTitle: "Toggle Keep Open", action: #selector(togglePin), keyEquivalent: "p")
        menu.addItem(withTitle: "Connections", action: #selector(connections), keyEquivalent: ",")
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        for (index, tab) in PanelTab.allCases.enumerated() {
            let item = menu.addItem(withTitle: tab.rawValue, action: #selector(selectTab(_:)), keyEquivalent: String(index + 1))
            item.tag = index
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Houston", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem(title: "Houston", action: nil, keyEquivalent: "")
        appMenu.submenu = menu
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu

        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.setAccessibilityLabel("Houston")

        store.$expanded.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async {
                guard let self else { return }
                self.layout()
                if !self.store.expanded {
                    self.keyboardOpened = false
                    self.closeTimer?.invalidate(); self.closeTimer = nil
                    self.pointerExitedAt = nil
                }
            } }.store(in: &subscriptions)
        store.$editing.combineLatest(store.$pinned).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.checkHover() } }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        store.demo = CommandLine.arguments.contains("--demo")
        layout()
        panel.orderFrontRegardless()
        store.start()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown)) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 && self.panel.isKeyWindow {
                        self.panel.makeFirstResponder(nil)
                        self.store.editing = false
                        self.store.expanded = false
                        return true
                    }
                } else { self.checkHover() }
                return false
            }
            return handled ? nil : event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        closeTimer?.invalidate()
    }

    func layout() {
        let screens = NSScreen.screens
        guard let screen = targetScreen.flatMap({ target in screens.first { $0 == target } }) ?? screens.first else { return }
        topInset = screen.safeAreaInsets.top
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else { notchWidth = 0 }
        let geometry = IslandGeometry(screen: screen.frame, visible: screen.visibleFrame, topInset: topInset,
                                      notchWidth: notchWidth, expanded: store.expanded)
        compactWidth = geometry.compactWidth
        store.topInset = topInset
        store.compactWidth = compactWidth
        store.expandedWidth = geometry.expandedSize.width
        store.expandedHeight = geometry.expandedSize.height
        if hosting == nil {
            let content = NSHostingView(rootView: IslandView(store: store))
            content.sizingOptions = []
            hosting = content
            panel.contentView = content
        }
        panel.setFrame(geometry.frame, display: true, animate: false)
    }

    func checkHover(at point: NSPoint = NSEvent.mouseLocation, now: Date = .now) {
        guard let panel else { return }
        let hitArea = panel.frame.insetBy(dx: store.expanded ? 0 : -8, dy: store.expanded ? 0 : -6)
        if hitArea.contains(point) {
            closeTimer?.invalidate(); closeTimer = nil
            keyboardOpened = false
            pointerExitedAt = nil
            if !store.expanded { store.expanded = true }
        } else if store.expanded && !store.pinned && !store.editing && !keyboardOpened {
            let exitedAt = pointerExitedAt ?? now
            pointerExitedAt = exitedAt
            let elapsed = now.timeIntervalSince(exitedAt)
            if elapsed >= 0.35 {
                closeTimer?.invalidate(); closeTimer = nil
                pointerExitedAt = nil
                store.expanded = false
            } else if closeTimer == nil {
                let timer = Timer(timeInterval: max(0.01, 0.35 - elapsed), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeTimer = nil; self?.checkHover() }
                }
                closeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            closeTimer?.invalidate(); closeTimer = nil
            pointerExitedAt = nil
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { status.menu = menu; status.button?.performClick(nil); status.menu = nil }
        else if store.expanded { store.expanded = false }
        else { show() }
    }
    @objc private func show() {
        targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        keyboardOpened = true
        store.expanded = true
        layout()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func refresh() { if !store.demo { store.refresh() } }
    @objc private func selectTab(_ sender: NSMenuItem) { store.tab = PanelTab.allCases[sender.tag]; show() }
    @objc private func togglePin() { store.pinned.toggle(); if store.pinned { show() } }
    @objc private func connections() { store.connections = true; show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func screenChanged() { layout() }
    @objc private func woke() { layout(); store.refresh() }
}
