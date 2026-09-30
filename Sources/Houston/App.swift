import AppKit
import SwiftUI
import Combine
import HoustonCore

@main struct HoustonMain {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--agent-event") {
            if let name = CommandLine.arguments.dropFirst(index + 1).first, let provider = AgentProvider(rawValue: name) {
                try? AgentBridge.capture(FileHandle.standardInput.readDataToEndOfFile(), provider: provider)
            }
            // Hooks observe status only; never interfere with the agent's decision or exit code.
            return
        }
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
        if CommandLine.arguments.contains("--check-github-alerts") {
            do {
                let snapshot = try GitHubSignalReader.read()
                print("GitHub checks and reviews: \(snapshot.signals.count) readings for \(snapshot.login)")
                for signal in snapshot.signals { print("  \(signal.detail): \(signal.state)") }
            } catch { print(error.localizedDescription); exit(1) }
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
        if let index = CommandLine.arguments.firstIndex(of: "--check-usage") {
            let name = CommandLine.arguments.dropFirst(index + 1).first
            let providers = name.map { name in Provider.allCases.filter { $0.rawValue.lowercased() == name.lowercased() } } ?? Provider.allCases
            guard !providers.isEmpty else { print("Choose: codex, claude, cursor, copilot, gemini, windsurf, openrouter"); exit(1) }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                var failures = 0
                for provider in providers {
                    do {
                        let snapshot = try await Store.readUsage(provider, true, false, UsageReader.claudeFile)
                        print("\(provider.rawValue): connected · captured \(snapshot.capturedAt.ISO8601Format())")
                        print(snapshot.accountID == nil ? "  History: account identity unavailable" : "  History: account identity verified")
                        for window in snapshot.windows { print("  \(window.name): \(Int(window.remaining))% left · \(window.countdown())") }
                        if let detail = snapshot.detail { print("  \(detail)") }
                    } catch { failures += 1; print("\(provider.rawValue): \(error.localizedDescription)") }
                }
                if failures > 0 { exit(1) }
                done.signal()
            }
            done.wait()
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

final class IslandPanel: NSPanel, NSDraggingDestination {
    weak var store: Store?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let store, !store.dropShelf.isDragging,
              sender.draggingSourceOperationMask.contains(.copy),
              !DropShelf.fileURLs(from: sender.draggingPasteboard).isEmpty else {
            self.store?.dropShelf.isTargeted = false
            return []
        }
        store.dropShelf.isTargeted = true
        store.openDropShelf()
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) { store?.dropShelf.isTargeted = false }
    func draggingEnded(_ sender: any NSDraggingInfo) { store?.dropShelf.isTargeted = false }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !draggingUpdated(sender).isEmpty
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let store, !store.dropShelf.isDragging else { return false }
        defer { store.dropShelf.isTargeted = false }
        let accepted = store.dropShelf.hold(DropShelf.fileURLs(from: sender.draggingPasteboard))
        if accepted { store.openDropShelf() }
        return accepted
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { store?.dropShelf.isTargeted = false }
}

/// Keep the entire panel inside the usable display, including scaled and portrait displays.
struct IslandGeometry {
    /// Room beside the camera for the provider ring on one side and the reading on the other: snug, like the Dynamic Island.
    static let notchSide: CGFloat = 56
    /// The detached pill on a display without a camera housing.
    static let detachedWidth: CGFloat = 132
    let compactWidth: CGFloat
    let expandedSize: NSSize
    let peekSize: NSSize
    let topInset: CGFloat
    let notchWidth: CGFloat
    let bandHeight: CGFloat
    private let presentation: IslandPresentation
    private let centerX: CGFloat
    private let top: CGFloat
    var frame: NSRect { frame(for: presentation) }

    init(screen: NSRect, visible: NSRect, topInset: CGFloat, notchWidth: CGFloat, expanded: Bool) {
        self.init(screen: screen, visible: visible, topInset: topInset, notchWidth: notchWidth, presentation: expanded ? .expanded : .compact)
    }

    init(screen: NSRect, visible: NSRect, topInset: CGFloat, notchWidth: CGFloat, notchCenterX: CGFloat? = nil, presentation: IslandPresentation, contentHeight: CGFloat = 600) {
        let hasNotch = topInset > 0 && notchWidth > 0
        self.topInset = hasNotch ? topInset : 0
        self.notchWidth = hasNotch ? notchWidth : 0
        let centerX = hasNotch ? notchCenterX ?? screen.midX : visible.midX
        // Keep the camera gap centered even when a side Dock shifts the usable display area.
        let availableWidth = max(1, 2 * min(centerX - visible.minX, visible.maxX - centerX) - 24)
        let top = hasNotch ? screen.maxY : min(visible.maxY, screen.maxY - topInset) - 7
        self.centerX = centerX
        self.top = top
        compactWidth = min(hasNotch ? notchWidth + 2 * Self.notchSide : Self.detachedWidth, availableWidth)
        bandHeight = max(34, self.topInset + 6)
        expandedSize = NSSize(width: min(460, availableWidth), height: min(contentHeight + self.topInset, max(1, top - visible.minY - 12)))
        peekSize = Self.peekSize(compactWidth: compactWidth, expandedWidth: expandedSize.width, bandHeight: bandHeight)
        self.presentation = presentation
    }

    /// A start grows the strip a little wider than compact and adds one line under the band; never wider than the panel.
    static func peekSize(compactWidth: CGFloat, expandedWidth: CGFloat, bandHeight: CGFloat) -> NSSize {
        NSSize(width: min(compactWidth + 160, expandedWidth), height: bandHeight + IslandStyle.peekRowHeight)
    }

    /// Sizes before any agent or content is live; the store sizes the island it actually shows.
    func size(for presentation: IslandPresentation) -> NSSize {
        switch presentation {
        case .compact: NSSize(width: compactWidth, height: bandHeight)
        case .hover: NSSize(width: min(compactWidth + IslandStyle.swell.width, expandedSize.width), height: bandHeight + IslandStyle.swell.height)
        case .peek: peekSize
        case .banner: NSSize(width: min(expandedSize.width, max(compactWidth + 100, 420)), height: bandHeight + IslandStyle.bannerRowHeight)
        case .home: NSSize(width: expandedSize.width, height: min(bandHeight + IslandHome.height(agentRows: 0), expandedSize.height))
        case .expanded: expandedSize
        }
    }

    func frame(for presentation: IslandPresentation) -> NSRect { frame(for: size(for: presentation)) }

    /// Every presentation hangs from the camera housing, centered on it.
    func frame(for size: NSSize) -> NSRect {
        NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
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
    private var openTimer: Timer?
    private var targetScreen: NSScreen?
    private var keyboardOpened = false
    private var pointerExitedAt: Date?
    private var pointerEnteredAt: Date?
    private var lastLevel = IslandLevel.closed
    /// After the island closes under the pointer, hover waits for the pointer to leave before it can open it again.
    private var hoverSuppressed = false
    private var menu: NSMenu!
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var hosting: NSHostingView<IslandView>?
    private var geometry: IslandGeometry?
    /// The island's size, and the panel's: the panel leads the island when it grows and trails it until the spring settles.
    private var islandSize: CGSize = .zero
    private var panelSize: CGSize = .zero
    private var settle: DispatchWorkItem?
    private var shadowRefresh: [DispatchWorkItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Houston")
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu = NSMenu()
        menu.addItem(withTitle: "Command Palette…", action: #selector(commandPalette), keyEquivalent: "k")
        menu.addItem(withTitle: "Guided Setup…", action: #selector(guidedSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Connection Health…", action: #selector(connectionHealth), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Show Houston", action: #selector(show), keyEquivalent: "o")
        menu.addItem(withTitle: "Toggle Keep Open", action: #selector(togglePin), keyEquivalent: "p")
        menu.addItem(withTitle: "Connections", action: #selector(connections), keyEquivalent: ",")
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Open Projects Window", action: #selector(openProjectsWindow), keyEquivalent: "0")
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
        // The island is black in every presentation, so its native controls always use the dark appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityLabel("Houston")

        store.$level.removeDuplicates().dropFirst()
            .sink { [weak self] level in MainActor.assumeIsolated {
                guard let self, level == .closed else { return }
                self.keyboardOpened = false
                self.closeTimer?.invalidate(); self.closeTimer = nil
                self.pointerExitedAt = nil
            } }.store(in: &subscriptions)
        // Presentations, a live agent, home content, and the Drop page's height all change the island's size.
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.islandChanged() } }.store(in: &subscriptions)
        store.dropShelf.$isDragging.combineLatest(store.dropShelf.$isTargeted).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.checkHover() } }.store(in: &subscriptions)
        store.$editing.combineLatest(store.$pinned).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.checkHover() } }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingChanged), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingChanged), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        layout()
        panel.orderFrontRegardless()
        store.reveal = { [weak self] in self?.show() }
        store.appServices.start { [weak self] in self?.commandPalette() }
        store.start()
        if !UserDefaults.standard.bool(forKey: "setupComplete") { guidedSetup() }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown)) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 && self.panel.isKeyWindow && self.trackingMenus.isEmpty && !self.store.dropShelf.isDragging {
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
        store.appServices.stop()
        store.stop()
        store.projects.runner.shutdown()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        closeTimer?.invalidate()
        openTimer?.invalidate()
        settle?.cancel()
        for work in shadowRefresh { work.cancel() }
    }

    /// Grow the panel before the island springs to a new size, with room for the spring's overshoot, and shrink it
    /// around the island only after the spring has settled, so the animation always has room and never clips mid-motion.
    private func islandChanged() {
        let target = store.size(for: store.presentation)
        guard target != islandSize else { return }
        islandSize = target
        settle?.cancel(); settle = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            panelSize = CGSize(width: max(panelSize.width, target.width + IslandMotion.overshoot.width),
                               height: max(panelSize.height, target.height + IslandMotion.overshoot.height))
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settle = nil
                self.layout()
            }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.settle, execute: work)
        }
        layout()
        // The window shadow follows the island's alpha; refresh it a few times while the shape is moving.
        for work in shadowRefresh { work.cancel() }
        shadowRefresh = (reduceMotion ? [0] : [0.08, 0.2, 0.35, 0.55, 0.8]).map { delay in
            let work = DispatchWorkItem { [weak self] in self?.panel.invalidateShadow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    func layout() {
        let screens = NSScreen.screens
        guard let screen = targetScreen.flatMap({ target in screens.first { $0 == target } }) ?? screens.first else { return }
        let notchWidth: CGFloat
        let notchCenterX: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
            notchCenterX = (left.maxX + right.minX) / 2
        } else { notchWidth = 0; notchCenterX = nil }
        let geometry = IslandGeometry(screen: screen.frame, visible: screen.visibleFrame, topInset: screen.safeAreaInsets.top,
                                      notchWidth: notchWidth, notchCenterX: notchCenterX, presentation: .compact,
                                      contentHeight: store.tab == .drop ? 360 : 600)
        self.geometry = geometry
        // Publishing unchanged values would echo back through objectWillChange, so only publish real changes.
        if store.topInset != geometry.topInset { store.topInset = geometry.topInset }
        if store.notchWidth != geometry.notchWidth { store.notchWidth = geometry.notchWidth }
        if store.compactWidth != geometry.compactWidth { store.compactWidth = geometry.compactWidth }
        if store.expandedWidth != geometry.expandedSize.width { store.expandedWidth = geometry.expandedSize.width }
        if store.expandedHeight != geometry.expandedSize.height { store.expandedHeight = geometry.expandedSize.height }
        if panel.store == nil {
            panel.store = store
            panel.registerForDraggedTypes([.fileURL])
        }
        if hosting == nil {
            let content = NSHostingView(rootView: IslandView(store: store))
            content.sizingOptions = []
            hosting = content
            panel.contentView = content
        }
        let island = store.size(for: store.presentation)
        if settle == nil {
            islandSize = island
            panelSize = island
        } else {
            panelSize = CGSize(width: max(panelSize.width, island.width), height: max(panelSize.height, island.height))
        }
        panel.setFrame(geometry.frame(for: panelSize), display: true, animate: false)
    }

    /// Where the pointer counts as over the island: the island itself when open, a little beyond the closed strip.
    private func hitArea(for presentation: IslandPresentation) -> NSRect {
        let island = geometry?.frame(for: store.size(for: presentation)) ?? panel.frame
        return presentation.isOpen ? island : island.insetBy(dx: -8, dy: -6)
    }

    /// Reaching the closed strip swells it with a tick of the trackpad; resting there a moment opens the home view,
    /// while passing through on the way to the menu bar only swells it. A banner under the pointer holds instead,
    /// so its buttons can be read and pressed. Leaving an open island closes it after a short grace period.
    func checkHover(at point: NSPoint = NSEvent.mouseLocation, now: Date = .now) {
        guard let panel else { return }
        let closedSinceLastCheck = lastLevel != .closed && store.level == .closed
        defer { lastLevel = store.level }
        guard !store.dropShelf.isDragging, !store.dropShelf.isTargeted,
              trackingMenus.isEmpty, panel.attachedSheet == nil,
              (panel.firstResponder as? NSTextView)?.isFieldEditor != true else {
            closeTimer?.invalidate(); closeTimer = nil
            pointerExitedAt = nil
            endHover()
            return
        }
        // Hover follows the island itself, not the panel, which stays large while a spring settles.
        if hitArea(for: store.presentation).contains(point) {
            closeTimer?.invalidate(); closeTimer = nil
            keyboardOpened = false
            pointerExitedAt = nil
            // Closing under the pointer, with Esc or the collapse button, must not swell and reopen on the next move.
            if closedSinceLastCheck { hoverSuppressed = true }
            guard store.level == .closed, !hoverSuppressed else { return }
            if let peek = store.peek, peek.isBanner {
                store.holdPeek(true)
                return
            }
            let enteredAt = pointerEnteredAt ?? now
            if pointerEnteredAt == nil {
                pointerEnteredAt = now
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { store.hovering = true }
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            let elapsed = now.timeIntervalSince(enteredAt)
            if elapsed >= IslandMotion.hoverDwell {
                endHover()
                store.openIsland(at: now)
            } else if openTimer == nil {
                let timer = Timer(timeInterval: max(0.01, IslandMotion.hoverDwell - elapsed), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.openTimer = nil; self?.checkHover() }
                }
                openTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        hoverSuppressed = false
        endHover()
        store.holdPeek(false)
        if store.level != .closed && !store.pinned && !store.editing && !keyboardOpened {
            let exitedAt = pointerExitedAt ?? now
            pointerExitedAt = exitedAt
            let elapsed = now.timeIntervalSince(exitedAt)
            if elapsed >= 0.35 {
                closeTimer?.invalidate(); closeTimer = nil
                pointerExitedAt = nil
                store.level = .closed
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

    private func endHover() {
        openTimer?.invalidate(); openTimer = nil
        pointerEnteredAt = nil
        if store.hovering { store.hovering = false }
    }

    @objc func menuTrackingChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if notification.name == NSMenu.didBeginTrackingNotification {
            trackingMenus.insert(ObjectIdentifier(menu))
        } else {
            trackingMenus.remove(ObjectIdentifier(menu))
        }
        checkHover()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { status.menu = menu; status.button?.performClick(nil); status.menu = nil }
        else if store.level != .closed { store.level = .closed }
        else { show() }
    }
    @objc private func show() { open(.home) }
    /// Open from the keyboard or a menu. It never steps back from a page that is already showing.
    private func open(_ level: IslandLevel) {
        targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        keyboardOpened = true
        if store.level < level { store.level = level }
        layout()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func commandPalette() { UtilityWindow.shared.show(store: store, page: .palette) }
    @objc private func guidedSetup() { UtilityWindow.shared.show(store: store, page: .setup) }
    @objc private func connectionHealth() { UtilityWindow.shared.show(store: store, page: .health) }
    @objc private func checkForUpdates() {
        if store.appServices.updatesAvailable { store.appServices.checkForUpdates() }
        else { store.navigate(to: .tools) }
    }
    @objc private func refresh() { store.refresh() }
    @objc private func openProjectsWindow() { ProjectWorkspaceWindow.shared.show(store: store) }
    @objc private func selectTab(_ sender: NSMenuItem) { store.tab = PanelTab.allCases[sender.tag]; open(.full) }
    @objc private func togglePin() { store.pinned.toggle(); if store.pinned { show() } }
    @objc private func connections() { store.connections = true; open(.full) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func screenChanged() { layout() }
    @objc private func woke() { layout(); store.refresh() }
}
