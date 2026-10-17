import AppKit
import QuartzCore

/// The little equalizer next to the menu bar title.
///
/// Liqoria's `WaveformAnimator` eases capsule heights toward random targets
/// on a timer. This produces the same smoothed-random motion with cubic
/// keyframes in the render server, so idle playback costs no CPU.
final class WaveformGlyphView: NSView {
  var isPlaying = false {
    didSet { if isPlaying != oldValue { updateAnimation() } }
  }

  private let barCount = 5
  private let barWidth: CGFloat = 2
  private let barSpacing: CGFloat = 1.5
  private let minHeight: CGFloat = 3
  private let maxHeight: CGFloat = 12
  private var bars: [CALayer] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for _ in 0..<barCount {
      let bar = CALayer()
      bar.cornerRadius = barWidth / 2
      bar.cornerCurve = .continuous
      layer?.addSublayer(bar)
      bars.append(bar)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var intrinsicContentSize: NSSize {
    NSSize(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing, height: maxHeight)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      let x = CGFloat(index) * (barWidth + barSpacing)
      bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: restingHeight(index))
      bar.position = CGPoint(x: x + barWidth / 2, y: bounds.midY)
    }
    CATransaction.commit()
    updateAnimation()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let color = MarqueeView.solidLabel.cgColor
      bars.forEach { $0.backgroundColor = color }
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    viewDidChangeEffectiveAppearance()
    updateAnimation()
  }

  /// Paused bars collapse into a row of dots, as in Liqoria.
  private func restingHeight(_ index: Int) -> CGFloat { barWidth }

  private func updateAnimation() {
    let animate = isPlaying && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for (index, bar) in bars.enumerated() {
      let current = bar.presentation()?.bounds.height ?? bar.bounds.height
      bar.removeAnimation(forKey: "wave")

      guard animate else {
        // Settle from wherever the bar is, never jump.
        let settle = CABasicAnimation(keyPath: "bounds.size.height")
        settle.fromValue = current
        settle.toValue = restingHeight(index)
        settle.duration = 0.35
        settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        bar.bounds.size.height = restingHeight(index)
        bar.add(settle, forKey: "settle")
        continue
      }

      // Long random sequences so the loop seam is not noticeable.
      var values: [CGFloat] = [current]
      for _ in 0..<15 { values.append(.random(in: minHeight...maxHeight)) }
      values.append(current)
      let wave = CAKeyframeAnimation(keyPath: "bounds.size.height")
      wave.values = values
      wave.calculationMode = .cubic
      wave.duration = .random(in: 3.6...4.8)
      wave.repeatCount = .infinity
      bar.add(wave, forKey: "wave")
    }
  }
}
