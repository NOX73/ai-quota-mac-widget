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
        // `.transient` auto-closes the popover whenever the app resigns active status — which
        // happens the moment the OAuth browser flow opens a browser window. That force-closes
        // the popover out from under the Settings/auth sheets presented on top of it, leaving
        // them as unresponsive orphaned windows. We manage dismissal ourselves instead.
        popover.behavior = .applicationDefined
        self.popover = popover

        observation = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem.button else { return }
                self.updateButton(button)
            }
        }

        service.startPolling()
    }

    private static let trayFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let trayIconSize = NSSize(width: 13, height: 13)

    private func updateButton(_ button: NSStatusBarButton) {
        let connected = service.providers.filter { $0.status.isConnected }

        guard !connected.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "AI Quota", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: Self.trayFont
            ])
            return
        }

        let title = NSMutableAttributedString()
        for (index, provider) in connected.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  "))
            }

            let pct = provider.worstUtilization
            let color = trayColor(for: pct)

            if service.showTrayIcon {
                let icon = tintedTrayIcon(forProviderID: provider.id, color: color)
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: -3, width: Self.trayIconSize.width, height: Self.trayIconSize.height)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " "))
            }

            let text = pct.map { "\(Int($0))%" } ?? "–%"
            title.append(NSAttributedString(string: text, attributes: [
                .foregroundColor: color,
                .font: Self.trayFont
            ]))
        }

        button.attributedTitle = title
    }

    private func trayColor(for utilization: Double?) -> NSColor {
        guard service.trayColorEnabled else { return .labelColor }
        guard let utilization else { return .secondaryLabelColor }
        switch UtilizationLevel(utilization: utilization, warningThreshold: service.warningThreshold, criticalThreshold: service.criticalThreshold) {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    /// Renders a provider's template logomark tinted to a solid color, for inline use in the
    /// menu bar's attributed title (NSTextAttachment doesn't auto-tint template images the way
    /// SF Symbol attachments do).
    private func tintedTrayIcon(forProviderID id: String, color: NSColor) -> NSImage {
        let source = ProviderIcons.icon(forProviderID: id)
        let result = NSImage(size: Self.trayIconSize)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: Self.trayIconSize)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        return result
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            // Rebuild the hosting controller's view fresh on every open rather than reusing one
            // created at launch. An NSHostingController that stays alive while the popover is
            // closed can end up showing a stale SwiftUI render when reopened (e.g. after the
            // OAuth round-trip updates provider state in the background) even though the
            // underlying @Published data is already correct — a full rebuild sidesteps that.
            popover.contentViewController = makePopoverContentViewController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            startOutsideClickMonitor()
        }
    }

    private func makePopoverContentViewController() -> NSHostingController<PopoverView> {
        NSHostingController(rootView: PopoverView(service: service, onSettingsDismissed: { [weak self] in
            self?.rebuildPopoverContentIfShown()
        }))
    }

    /// The popover can stay open through the whole Settings → OAuth-in-browser → back-to-Settings
    /// round trip without ever being closed and reopened. Its live SwiftUI view doesn't reliably
    /// pick up provider state that changed while obscured behind those sheets, so once Settings
    /// is dismissed (the moment the user returns to looking at the popover), force a fresh render
    /// the same way a manual close/reopen already does.
    private func rebuildPopoverContentIfShown() {
        guard popover.isShown, popover.contentViewController?.view.window?.attachedSheet == nil else { return }
        popover.contentViewController = makePopoverContentViewController()
    }

    /// Since the popover is `.applicationDefined`, we own all dismissal: any mouse-down outside
    /// this app closes the popover, like a normal widget.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePopoverUnlessSheetPresented()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Outside clicks (e.g. in the browser during the OAuth flow) shouldn't tear down the
    /// popover while Settings or an auth sheet is presented on top of it — that's exactly the
    /// scenario that used to orphan those sheets. Only close when nothing is layered on top.
    private func closePopoverUnlessSheetPresented() {
        guard popover.contentViewController?.view.window?.attachedSheet == nil else { return }
        closePopover()
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitor()
    }
}
