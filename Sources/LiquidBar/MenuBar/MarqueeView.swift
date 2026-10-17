import AppKit
import QuartzCore

/// Single-line text that scrolls once, on cue, when it overflows.
///
/// Liqoria's `MarqueeNSView` uses the same structure: two text layers in a
/// container, a gradient mask, Core Animation in the render server. Like
/// Liqoria it does not loop forever: one pass runs when the title changes,
/// when playback starts or pauses, or when the pointer enters, then the
/// title rests at its start.
final class MarqueeView: NSView, CAAnimationDelegate {
  var text = "" {
    didSet { if text != oldValue { rebuild() } }
  }
  var font = NSFont.systemFont(ofSize: 13, weight: .semibold) {
    didSet { rebuild() }
  }
  /// Full-strength white/black. `labelColor` carries 15% transparency, which
  /// reads grey next to the menu bar's own titles.
  static let solidLabel = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
  }

  var textColor = MarqueeView.solidLabel {
    didSet { applyColor() }
  }
  /// Widest the view will grow before it starts scrolling.
  var maxWidth: CGFloat = 100 {
    didSet { rebuild() }
  }
  /// Points per second. Constant motion is linear by design.
  var speed: CGFloat = 30
  /// Pause before a pass triggered by a new title, so it can be read first.
  var delay: CFTimeInterval = 1.2
  var spacing: CGFloat = 32
  var fadeWidth: CGFloat = 10

  private let container = CALayer()
  private let first = CATextLayer()
  private let second = CATextLayer()
  private let fadeMask = CAGradientLayer()
  private var textWidth: CGFloat = 0
  private var isOverflowing: Bool { textWidth > maxWidth }
  private static let scrollKey = "marquee.scroll"

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(container)
    for text in [first, second] {
      // No implicit cross-fade when the string or colour is re-set; the
      // menu bar changes appearance often and the title would keep fading.
      text.actions = ["contents": NSNull(), "string": NSNull(), "foregroundColor": NSNull()]
      text.truncationMode = .none
      text.isWrapped = false
      container.addSublayer(text)
    }
    fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
    fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
    fadeMask.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var intrinsicContentSize: NSSize {
    NSSize(width: ceil(min(textWidth, maxWidth)), height: ceil(font.ascender - font.descender + font.leading))
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 2
    first.contentsScale = scale
    second.contentsScale = scale
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColor()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    viewDidChangeBackingProperties()
    scrollOnce(after: delay)
  }

  override func layout() {
    super.layout()
    let height = intrinsicContentSize.height
    let y = (bounds.height - height) / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    container.frame = CGRect(x: 0, y: y, width: textWidth * 2 + spacing, height: height)
    first.frame = CGRect(x: 0, y: 0, width: ceil(textWidth) + 1, height: height)
    second.frame = first.frame.offsetBy(dx: textWidth + spacing, dy: 0)
    second.isHidden = !isOverflowing
    fadeMask.frame = bounds
    layer?.mask = isOverflowing ? fadeMask : nil
    setFade(leading: false)
    CATransaction.commit()
  }

  // MARK: Content

  private func rebuild() {
    let string = NSAttributedString(string: text, attributes: [.font: font])
    textWidth = ceil(string.size().width)
    first.string = string
    second.string = string
    applyColor()
    invalidateIntrinsicContentSize()
    needsLayout = true
    stopScrolling()
    scrollOnce(after: delay)
  }

  private func applyColor() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
      first.string = attributed
      second.string = attributed
    }
  }

  // MARK: Animation

  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private var isScrolling: Bool { container.animation(forKey: Self.scrollKey) != nil }

  /// Runs one full pass, unless one is already running.
  func scrollOnce(after wait: CFTimeInterval = 0) {
    guard !isScrolling, window != nil, isOverflowing, !reduceMotion else { return }

    let distance = textWidth + spacing
    let travel = CFTimeInterval(distance / speed)
    let begin = CACurrentMediaTime() + wait

    let scroll = CABasicAnimation(keyPath: "transform.translation.x")
    scroll.fromValue = 0
    scroll.toValue = -distance
    scroll.duration = travel
    scroll.beginTime = begin
    scroll.timingFunction = CAMediaTimingFunction(name: .linear)
    scroll.delegate = self
    scroll.isRemovedOnCompletion = true
    container.add(scroll, forKey: Self.scrollKey)

    // The leading fade only exists while text is moving under it; at rest the
    // first letters stay crisp.
    let fade = CAKeyframeAnimation(keyPath: "locations")
    fade.values = [fadeLocations(leading: false), fadeLocations(leading: true),
                   fadeLocations(leading: true), fadeLocations(leading: false)]
    let edge = min(0.25 / travel, 0.2)
    fade.keyTimes = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
    fade.duration = travel
    fade.beginTime = begin
    fadeMask.add(fade, forKey: "fade")
  }

  func stopScrolling() {
    container.removeAnimation(forKey: Self.scrollKey)
    fadeMask.removeAllAnimations()
  }

  func animationDidStop(_ animation: CAAnimation, finished: Bool) {
    // The second copy now sits where the first started, so the pass ends on
    // the same frame it began. Rest there until the next cue.
    container.removeAnimation(forKey: Self.scrollKey)
  }

  private func setFade(leading: Bool) {
    fadeMask.locations = fadeLocations(leading: leading)
  }

  private func fadeLocations(leading: Bool) -> [NSNumber] {
    let width = max(bounds.width, 1)
    let fraction = Double(fadeWidth / width)
    return [0, leading ? NSNumber(value: fraction) : 0, NSNumber(value: 1 - fraction), 1]
  }
}
