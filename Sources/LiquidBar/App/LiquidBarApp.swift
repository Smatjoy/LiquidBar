import AppKit

@main
enum LiquidBarApp {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon, never steals activation.
    app.setActivationPolicy(.accessory)
    app.run()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let service = NowPlayingService()
  private var menuBar: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    service.start()
    menuBar = MenuBarController(service: service)
  }

  func applicationWillTerminate(_ notification: Notification) {
    service.stop()
  }
}
