import AppKit
import CoreServices
import SwiftUI
import TokiCore

@MainActor
private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var requested: Set<String> = []
    private var pending: Task<Void, Never>?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func update(_ requested: [String]) {
        self.requested = Set(requested)
        let directories = Array(Set(requested.map { path in
            var candidate = URL(fileURLWithPath: path)
            var isDirectory = ObjCBool(false)
            while candidate.path != "/" && !(FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue) {
                candidate.deleteLastPathComponent()
            }
            return candidate.path
        })).sorted()
        guard roots != directories else { return }
        stop()
        guard !directories.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { watcher.changed(paths) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, directories as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        self.stream = stream
        if FSEventStreamStart(stream) { roots = directories } else { stop() }
    }

    func stop() {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        roots = []
    }

    private func changed(_ paths: [String]) {
        guard paths.contains(where: { path in
            requested.contains { root in path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/") }
        }) else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.onChange()
        }
    }
}

@MainActor
final class TokiDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = AppState()
    private let engine = UsageEngine()
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var preferences: NSWindow?
    private var timer: Timer?
    private var refreshing: Task<Void, Never>?
    private var queued = false
    private var dateKey = Calendar.current.startOfDay(for: Date())
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private lazy var watcher = DirectoryWatcher { [weak self] in self?.refresh() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.image = Self.templateIcon()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 570)
        popover.contentViewController = NSHostingController(rootView: UsagePopover(
            state: state, refresh: { [weak self] in self?.refresh() },
            settings: { [weak self] in self?.openPreferences() },
            quit: { NSApplication.shared.terminate(nil) }
        ))
        state.displayChanged = { [weak self] in self?.updateStatusItem() }
        state.scheduleChanged = { [weak self] in self?.schedule() }
        state.refreshRequested = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged),
                                               name: .NSCalendarDayChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(dayChanged),
                                                           name: NSWorkspace.didWakeNotification, object: nil)
        schedule()
        updateStatusItem()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePopoverMonitors()
        timer?.invalidate()
        watcher.stop()
        refreshing?.cancel()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(state.interval, 15)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 2
    }

    @objc private func dayChanged() { refresh() }

    private func refresh() {
        let today = Calendar.current.startOfDay(for: Date())
        if dateKey != today {
            dateKey = today
            state.summaries = [:]
            updateStatusItem()
        }
        guard refreshing == nil else { queued = true; return }
        state.refreshing = true
        let enabled = state.enabled
        refreshing = Task { @MainActor [weak self] in
            guard let self else { return }
            let paths = await engine.watchPaths(providers: enabled)
            watcher.update(paths)
            let results = await engine.refresh(days: [1, 7, 30], providers: enabled)
            if dateKey == today, enabled == state.enabled {
                state.summaries = Dictionary(uniqueKeysWithValues: results.map { ($0.days, $0) })
                updateStatusItem()
            }
            state.refreshing = false
            refreshing = nil
            if queued {
                queued = false
                refresh()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = item?.button else { return }
        let summary = state.today
        let count = summary.map { state.compactInteger($0.totalTokens) } ?? "—"
        let title: String
        switch state.menuFormat {
        case .compact: title = count
        case .prefix: title = "\(state.windowTitle(1)) \(count)"
        case .cost:
            let cost = summary.flatMap { $0.usage.pricedRecords > 0 ? state.money($0.usage.costUsd) : nil } ?? "—"
            title = "\(count) · \(cost)"
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        ])
        let tooltip = summary.map {
            "\(state.exact($0.totalTokens)) \(state.local("Token", "tokens"))\n\(state.local("更新于", "Updated")) \(state.timestamp($0.updatedAt))"
        } ?? "Toki"
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            openPopover(relativeTo: button)
        }
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installPopoverMonitors()
    }

    private func closePopover() {
        removePopoverMonitors()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverMonitors()
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.closePopover()
                    return nil
                }
                return event
            }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.item?.button?.window
            if event.window !== popoverWindow && event.window !== statusWindow {
                self.closePopover()
            }
            return event
        }
    }

    private func removePopoverMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func openPreferences() {
        closePopover()
        if preferences == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 410),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(state: state))
            window.center()
            preferences = window
        }
        preferences?.title = "Toki · \(state.local("设置", "Settings"))"
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferences?.makeKeyAndOrderFront(nil)
    }

    private static func templateIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 18.0)
            transform.concat()

            // Sunrise time arc ("時") above the three ascending usage bars
            NSColor.black.withAlphaComponent(0.58).setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 1.4
            arc.lineCapStyle = .round
            arc.move(to: NSPoint(x: 3.0, y: 5.0))
            arc.curve(
                to: NSPoint(x: 15.0, y: 5.0),
                controlPoint1: NSPoint(x: 5.5, y: 2.3),
                controlPoint2: NSPoint(x: 12.5, y: 2.3)
            )
            arc.stroke()

            let bars: [(NSRect, CGFloat)] = [
                (NSRect(x: 2.6, y: 10.6, width: 3.1, height: 4.6), 0.55),
                (NSRect(x: 7.45, y: 8.4, width: 3.1, height: 6.8), 0.80),
                (NSRect(x: 12.3, y: 6.2, width: 3.1, height: 9.0), 1.00),
            ]
            for (barRect, alpha) in bars {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.1, yRadius: 1.1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
