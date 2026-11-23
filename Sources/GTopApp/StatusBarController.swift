import AppKit
import GTopCore
import Observation
import SwiftUI

/// Native AppKit NSStatusItem + NSPopover controller for the macOS menu bar.
/// Avoids macOS 27 SwiftUI `MenuBarExtra(isInserted:)` KVO/AppGraph infinite loop while
/// delivering crisp native popover behavior and live free/total GPU counters.
@MainActor
final class StatusBarController: NSObject {
    private let store: ClusterMonitorStore
    private let coordinator: AppCoordinator
    private let onOpenMainWindow: @MainActor (SidebarDestination?) -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var isTracking = false

    init(
        store: ClusterMonitorStore,
        coordinator: AppCoordinator,
        onOpenMainWindow: @escaping @MainActor (SidebarDestination?) -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onOpenMainWindow = onOpenMainWindow
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                store: store,
                onOpenMainWindow: { [weak self] destination in
                    self?.popover.performClose(nil)
                    self?.onOpenMainWindow(destination)
                }
            )
        )
    }

    func start() {
        syncFromStore()
        beginObservationLoop()
    }

    func stop() {
        isTracking = false
        popover.performClose(nil)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func beginObservationLoop() {
        guard !isTracking else { return }
        isTracking = true
        observeNextChange()
    }

    private func observeNextChange() {
        guard isTracking else { return }
        withObservationTracking {
            _ = store.settings.showMenuBarExtra
            _ = store.totalGPUCount
            _ = store.idleGPUs.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.syncFromStore()
                self.observeNextChange()
            }
        }
    }

    private func syncFromStore() {
        let shouldShow = store.settings.showMenuBarExtra
        if shouldShow {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    let img = NSImage(systemSymbolName: "cpu", accessibilityDescription: "GTop")
                    img?.isTemplate = true
                    button.image = img
                    button.imagePosition = .imageLeading
                    button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
                    button.target = self
                    button.action = #selector(togglePopover(_:))
                }
                statusItem = item
            }
            if let button = statusItem?.button {
                let total = store.totalGPUCount
                let newTitle = total > 0 ? " \(store.idleGPUs.count)/\(total)" : ""
                if button.title != newTitle {
                    button.title = newTitle
                }
            }
        } else if let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
