import AppKit
import QuartzCore

/// Artwork · scrolling title · waveform, drawn inside the status item button.
///
/// Like Liqoria's `MenuBarHoverView`, it reports hover through an always-active
/// tracking area but returns `nil` from `hitTest`, so clicks still reach the
/// status button underneath.
final class StatusItemContentView: NSView {
  var onHoverChange: ((Bool) -> Void)?

  private let artworkView = NSImageView()
  private let placeholder = NSImageView()
  private let marquee = MarqueeView()
  private let waveform = WaveformGlyphView()
  private var trackingArea: NSTrackingArea?

  private let artworkSize: CGFloat = 17
  private let gap: CGFloat = 6
  private let edgeInset: CGFloat = 5
  private var showsMedia = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true

    artworkView.wantsLayer = true
    artworkView.imageScaling = .scaleProportionallyUpOrDown
    artworkView.layer?.cornerRadius = 4
    artworkView.layer?.cornerCurve = .continuous
    artworkView.layer?.masksToBounds = true

    placeholder.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music")
    placeholder.symbolConfiguration = .init(pointSize: 14, weight: .medium)
    placeholder.contentTintColor = .labelColor

    [artworkView, marquee, waveform, placeholder].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    marquee.scrollOnce()
    onHoverChange?(true)
  }
  override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

  // MARK: Content

  func update(title: String?, artist: String?, artwork: NSImage?, isPlaying: Bool) {
    showsMedia = title != nil
    placeholder.isHidden = showsMedia
    artworkView.isHidden = !showsMedia
    marquee.isHidden = !showsMedia
    waveform.isHidden = !showsMedia

    if artworkView.image !== artwork {
      // Same cross-dissolve the panel uses, scaled down to menu bar size.
      let fade = CATransition()
      fade.type = .fade
      fade.duration = 0.3
      artworkView.layer?.add(fade, forKey: "artwork")
      artworkView.image = artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
    }
    marquee.text = title ?? ""
    if showsMedia, isPlaying != waveform.isPlaying {
      // Liqoria replays the title whenever playback starts or pauses.
      marquee.scrollOnce(after: 0.15)
    }
    waveform.isPlaying = isPlaying
    // Paused artwork recedes, as in Liqoria's menu bar item.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      artworkView.animator().alphaValue = isPlaying || !showsMedia ? 1 : 0.55
    }

    setAccessibilityLabel(title.map { [$0, artist].compactMap(\.self).joined(separator: ", ") } ?? "Nothing playing")
    needsLayout = true
  }

  var preferredWidth: CGFloat {
    guard showsMedia else { return 24 }
    return edgeInset + artworkSize + gap + marquee.intrinsicContentSize.width + gap + 2
      + waveform.intrinsicContentSize.width + edgeInset
  }

  override func layout() {
    super.layout()
    let midY = bounds.midY
    var x = edgeInset

    artworkView.frame = CGRect(x: x, y: midY - artworkSize / 2, width: artworkSize, height: artworkSize)
    x += artworkSize + gap

    let marqueeSize = marquee.intrinsicContentSize
    marquee.frame = CGRect(x: x, y: 0, width: marqueeSize.width, height: bounds.height)
    x += marqueeSize.width + gap + 2

    let waveSize = waveform.intrinsicContentSize
    waveform.frame = CGRect(x: x, y: midY - waveSize.height / 2, width: waveSize.width, height: waveSize.height)

    placeholder.frame = bounds
  }

  // MARK: Scroll feedback

  /// Rubber-bands the content while a horizontal scroll is building toward a
  /// track change, so the gesture has continuous feedback.
  func setScrollOffset(_ offset: CGFloat, animated: Bool) {
    guard let layer else { return }
    let banded = rubberBand(offset, limit: 10)
    let from = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.setValue(banded, forKeyPath: "transform.translation.x")
    CATransaction.commit()
    guard animated else { return }
    let spring = CASpringAnimation(keyPath: "transform.translation.x")
    spring.fromValue = from
    spring.toValue = banded
    spring.mass = 1
    spring.stiffness = 260
    spring.damping = 22
    spring.duration = spring.settlingDuration
    layer.add(spring, forKey: "scroll")
  }
}
