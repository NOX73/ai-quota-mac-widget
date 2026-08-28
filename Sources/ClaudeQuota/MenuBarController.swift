import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let service = AggregateQuotaService()
    private var observation: Any?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateButton(button)
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(service: service))
        self.popover = popover

        observation = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                self.updateButton(button)
            }
        }

        service.startPolling()
    }

    private func updateButton(_ button: NSStatusBarButton) {
        let titleText = service.menuBarTitle
        let maxPct = service.maxUtilization

        let color: NSColor
        if maxPct == 0 {
            color = .secondaryLabelColor
        } else if maxPct < 50 {
            color = .systemGreen
        } else if maxPct < 80 {
            color = .systemOrange
        } else {
            color = .systemRed
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: titleText, attributes: attrs)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            startOutsideClickMonitor()
        }
    }

    /// `.transient` popover dismissal can be unreliable for accessory-policy (menu bar only)
    /// apps, so we back it up with an explicit global click monitor: any mouse-down outside
    /// this app closes the popover, like a normal widget.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitor()
    }
}
