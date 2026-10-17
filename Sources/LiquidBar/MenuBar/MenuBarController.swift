import AppKit
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "LiquidBar", category: "MenuBar")

/// Wires the status item, the player panel and the Now Playing service.
///
/// Mirrors Liqoria's `MenuBarPlayer`: a status item whose hover view opens the
/// panel, a delayed close when the pointer leaves, a global event monitor that
/// dismisses a click-pinned panel, and scroll gestures that change track.
final class MenuBarController: NSObject {
  private let service: NowPlayingService
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let content = StatusItemContentView()
  private let panel: PlayerPanelController

  private var openOnHover: Bool {
    get { UserDefaults.standard.object(forKey: "openOnHover") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "openOnHover") }
  }

  private var isPinned = false
  private var hoverOpenTask: Task<Void, Never>?
  private var hoverWatchTimer: Timer?
  private var pointerLeftAt: Date?
  private var clickMonitor: Any?
  private var scrollMonitor: Any?
  private var swipe = SwipeAccumulator()

  init(service: NowPlayingService) {
    self.service = service
    self.panel = PlayerPanelController(service: service)
    super.init()
    configureStatusItem()
    observeService()
    installScrollMonitor()
  }

  // MARK: Status item

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    button.title = ""
    button.target = self
    button.action = #selector(statusItemClicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    content.frame = button.bounds
    content.autoresizingMask = [.width, .height]
    content.onHoverChange = { [weak self] hovering in self?.statusHoverChanged(hovering) }
    button.addSubview(content)
    refreshStatusItem()
  }

  private func observeService() {
    Task { [weak self, service] in
      let changes = Observations {
        (service.track, service.playback.isPlaying, service.artworkID)
      }
      for await _ in changes {
        self?.refreshStatusItem()
      }
    }
  }

  private func refreshStatusItem() {
    let track = service.track
    content.update(title: track?.title, artist: track?.artist, artwork: service.artwork,
                   isPlaying: service.playback.isPlaying)
    statusItem.length = ceil(content.preferredWidth)
    if track == nil, panel.isOpen { closePanel() }
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    log.debug("status click \(NSApp.currentEvent?.type.rawValue ?? 0)")
    if NSApp.currentEvent?.type == .rightMouseUp {
      showMenu()
      return
    }
    hoverOpenTask?.cancel()
    if panel.isOpen {
      // Clicking the item again always dismisses, however the panel opened.
      closePanel()
    } else {
      // A click pins the panel open until you click elsewhere.
      openPanel()
      isPinned = true
    }
  }

  private func showMenu() {
    closePanel()
    let menu = NSMenu()
    let hover = NSMenuItem(title: "Open on Hover", action: #selector(toggleOpenOnHover), keyEquivalent: "")
    hover.target = self
    hover.state = openOnHover ? .on : .off
    menu.addItem(hover)

    let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    login.target = self
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit LiquidBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @objc private func toggleOpenOnHover() { openOnHover.toggle() }

  @objc private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    try? service.status == .enabled ? service.unregister() : service.register()
  }

  // MARK: Hover

  private func statusHoverChanged(_ hovering: Bool) {
    log.debug("status hover \(hovering)")
    guard hovering, openOnHover, service.hasMedia, !panel.isOpen else {
      if !hovering { hoverOpenTask?.cancel() }
      return
    }
    // A short dwell keeps a pointer sweeping across the menu bar from
    // popping the player open.
    hoverOpenTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(70))
      guard !Task.isCancelled else { return }
      self?.openPanel()
    }
  }

  private func openPanel() {
    log.debug("openPanel")
    guard service.hasMedia,
          let buttonWindow = statusItem.button?.window,
          let screen = buttonWindow.screen ?? NSScreen.main
    else { return }
    isPinned = false
    pointerLeftAt = nil
    panel.open(below: buttonWindow.frame, on: screen)
    startHoverWatch()
    installClickMonitor()
  }

  private func closePanel() {
    log.debug("closePanel")
    hoverOpenTask?.cancel()
    hoverWatchTimer?.invalidate()
    hoverWatchTimer = nil
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    isPinned = false
    panel.close()
  }

  /// Polls the pointer while open. Tracking-area exits alone miss fast
  /// movements and the gap between the status item and the card.
  private func startHoverWatch() {
    hoverWatchTimer?.invalidate()
    let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkPointer() }
    }
    RunLoop.main.add(timer, forMode: .common)
    hoverWatchTimer = timer
  }

  private func checkPointer() {
    guard panel.isOpen, !isPinned, let statusFrame = statusItem.button?.window?.frame else { return }
    let point = NSEvent.mouseLocation
    let card = panel.cardFrame.insetBy(dx: -6, dy: -6)
    let status = statusFrame.insetBy(dx: -2, dy: -2)
    // The corridor between the item and the card, so crossing it doesn't close.
    let corridor = CGRect(x: max(status.minX, card.minX), y: card.maxY - 2,
                          width: max(min(status.maxX, card.maxX) - max(status.minX, card.minX), 0),
                          height: status.minY - card.maxY + 4)
    let inside = card.contains(point) || status.contains(point) || corridor.contains(point)

    if inside || NSEvent.pressedMouseButtons != 0 {
      pointerLeftAt = nil
    } else if let left = pointerLeftAt {
      if Date().timeIntervalSince(left) > 0.15 { closePanel() }
    } else {
      pointerLeftAt = Date()
    }
  }

  private func installClickMonitor() {
    guard clickMonitor == nil else { return }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated { self?.clickedOutside(at: NSEvent.mouseLocation) }
    }
  }

  /// Mouse-down on the status item also reaches the global monitor; leave
  /// that one to the item's own action so a second click toggles closed.
  private func clickedOutside(at point: CGPoint) {
    let onItem = statusItem.button?.window?.frame.contains(point) ?? false
    guard !onItem, !panel.cardFrame.contains(point) else { return }
    closePanel()
  }

  // MARK: Swipe to change track

  /// Liqoria's `MenuBarScrollHandler` / `PanelScrollHandler`: a horizontal
  /// two-finger swipe over the item or the card skips tracks, a swipe up on
  /// the card dismisses it.
  private func installScrollMonitor() {
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
      return consumed ? nil : event
    }
  }

  /// Returns true when the event was used as a swipe and should not propagate.
  private func handleScroll(_ event: NSEvent) -> Bool {
    let overStatus = event.window === statusItem.button?.window
    // Over a queue row the swipe removes or moves that song instead.
    let overPanel = event.window === panel.window && panel.isOpen && !panel.presentation.isPointerOverQueueRow
    guard overStatus || overPanel, event.hasPreciseScrollingDeltas, service.hasMedia else { return false }

    switch swipe.feed(event) {
    case .tracking(let offset):
      if overStatus { content.setScrollOffset(offset, animated: false) }
      if overPanel { panel.presentation.swipeOffset = rubberBand(offset, limit: 28) }
    case .next, .previous:
      let next = swipe.lastAction == .next
      next ? service.next() : service.previous()
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      settleSwipe()
    case .dismiss:
      if overPanel { closePanel() }
      settleSwipe()
    case .ended:
      settleSwipe()
    case .ignored:
      return false
    }
    return true
  }

  private func settleSwipe() {
    content.setScrollOffset(0, animated: true)
    withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
      panel.presentation.swipeOffset = 0
    }
  }
}

/// Turns trackpad scroll phases into one decision per gesture.
struct SwipeAccumulator {
  enum Result: Equatable { case tracking(CGFloat), next, previous, dismiss, ended, ignored }

  private var x: CGFloat = 0
  private var y: CGFloat = 0
  private var fired = false
  private(set) var lastAction: Result = .ended

  private let horizontalThreshold: CGFloat = 60
  private let dismissThreshold: CGFloat = 45

  mutating func feed(_ event: NSEvent) -> Result {
    if event.phase == .began {
      x = 0; y = 0; fired = false
    }
    // Momentum after a decision belongs to the same gesture; swallow it.
    if !event.momentumPhase.isEmpty { return fired ? .ignored : .ended }
    if event.phase == .ended || event.phase == .cancelled { return .ended }
    guard !fired else { return .tracking(0) }

    x += event.scrollingDeltaX
    y += event.scrollingDeltaY

    if abs(x) > abs(y) {
      if abs(x) > horizontalThreshold {
        fired = true
        lastAction = x < 0 ? .next : .previous
        return lastAction
      }
      return .tracking(x)
    }
    if -y > dismissThreshold {
      fired = true
      lastAction = .dismiss
      return .dismiss
    }
    return .tracking(0)
  }
}
