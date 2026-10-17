import AppKit
import SwiftUI

enum PanelLayout {
  /// Gap between the menu bar and the card.
  static let topGap: CGFloat = 7
  /// Room around the card so the overshoot, blur and glass shadow are not clipped.
  static let margin: CGFloat = 32
  /// The window fits the tallest card (queue open) plus spring overshoot.
  static var size: CGSize {
    CGSize(width: CardMetrics.width + margin * 2, height: topGap + SectionMetrics.maxHeight + margin * 2)
  }
}

/// Borderless, non-activating panel at pop-up-menu level, the same window
/// configuration Liqoria uses for its `MenubarPanel`. It never becomes key, so
/// hovering or clicking the player doesn't steal focus from the app you're in.
final class PlayerPanel: NSPanel {
  init() {
    super.init(
      contentRect: CGRect(origin: .zero, size: PanelLayout.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    isMovable = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click, so the player's buttons work
/// without activating the app first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PlayerPanelController {
  let presentation = PanelPresentation()
  private let panel = PlayerPanel()
  private let service: NowPlayingService
  private let outputs = AudioOutputs()

  init(service: NowPlayingService) {
    self.service = service
    let root = PanelRootView(service: service, presentation: presentation, outputs: outputs)
    let host = FirstClickHostingView(rootView: root)
    host.sizingOptions = []
    panel.contentView = host
    presentation.onToggleSection = { [weak self] section in self?.toggle(section) }
  }

  /// Queue and outputs share the space under the controls; tapping the open
  /// one again folds it away.
  private func toggle(_ section: PanelSection) {
    let next: PanelSection = presentation.section == section ? .none : section
    switch next {
    case .queue: service.refreshQueue()
    case .outputs: outputs.startListening()
    case .none: break
    }
    withAnimation(.smooth(duration: 0.3)) { presentation.section = next }
  }

  var isOpen: Bool { presentation.isOpen }

  /// The card's frame in screen coordinates, for hover hit-testing.
  var cardFrame: CGRect {
    let frame = panel.frame
    return CGRect(
      x: frame.midX - CardMetrics.width / 2,
      y: frame.maxY - PanelLayout.topGap - presentation.height,
      width: CardMetrics.width,
      height: presentation.height + PanelLayout.topGap
    )
  }

  var window: NSWindow { panel }

  func open(below anchor: CGRect, on screen: NSScreen) {
    let size = PanelLayout.size
    let visible = screen.visibleFrame
    var x = anchor.midX - size.width / 2
    x = min(max(x, visible.minX + 4 - PanelLayout.margin), visible.maxX - size.width - 4 + PanelLayout.margin)
    let y = anchor.minY - size.height
    panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)

    guard !presentation.isOpen else { return }
    presentation.isOpen = true
    presentation.frost = SystemGlass.frost
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let wasHidden = !panel.isVisible || panel.alphaValue < 0.01

    if wasHidden {
      // Start as a card-wide strip under the menu bar; it drops from there.
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) {
        presentation.width = CardMetrics.width
        presentation.height = reduce ? CardMetrics.height : PanelMotion.startHeight
        presentation.contentScale = reduce ? 1 : PanelMotion.hiddenScale
        presentation.contentBlur = reduce ? 0 : PanelMotion.hiddenBlur
        presentation.contentOpacity = 0
      }
      panel.alphaValue = 0
      panel.orderFrontRegardless()
      // Let SwiftUI commit the start rect first; otherwise the reset and the
      // targets coalesce into one update and nothing animates.
      DispatchQueue.main.async { [weak self] in self?.animateOpen(reduce: reduce) }
    } else {
      // Re-opening mid-close: springs retarget from the current values.
      animateOpen(reduce: reduce)
    }
  }

  private func animateOpen(reduce: Bool) {
    guard presentation.isOpen else { return }
    // The glass fades in through the window, so it never renders offscreen.
    fadeWindow(to: 1, duration: 0.1)
    withAnimation(reduce ? PanelMotion.reducedFade : PanelMotion.height) {
      presentation.height = CardMetrics.height
    }
    withAnimation(reduce ? PanelMotion.reducedFade : PanelMotion.contentIn) {
      presentation.contentScale = 1
      presentation.contentBlur = 0
      presentation.contentOpacity = 1
    }
  }

  func close() {
    guard presentation.isOpen else { return }
    presentation.isOpen = false
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    withAnimation(reduce ? PanelMotion.reducedFade : PanelMotion.close) {
      presentation.contentOpacity = 0
      if !reduce {
        presentation.contentScale = PanelMotion.hiddenScale
        presentation.contentBlur = PanelMotion.hiddenBlur
        presentation.height = PanelMotion.startHeight
      }
    }
    fadeWindow(to: 0, duration: reduce ? 0.15 : PanelMotion.closeDuration) { [weak self] in
      guard let self, !self.presentation.isOpen else { return }
      self.panel.orderOut(nil)
      self.presentation.section = .none
    }
  }

  private func fadeWindow(to alpha: CGFloat, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .linear)
      panel.animator().alphaValue = alpha
    } completionHandler: {
      MainActor.assumeIsolated { completion?() }
    }
  }
}
