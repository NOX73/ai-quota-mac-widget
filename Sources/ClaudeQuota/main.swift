import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = MenuBarController()
    app.delegate = controller

    app.run()
}
