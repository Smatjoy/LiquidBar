import SwiftUI

/// Drives the panel presentation.
///
/// Recovered from Liqoria (60 fps screen recording + constants in the binary):
/// nothing zooms. The glass is card-wide from the first frame and drops
/// down from the menu bar on an under-damped spring that overshoots and
/// rebounds; the controls fall with it, stretched from the top edge
/// (Liqoria's `hostingScale` scales y only), sharpening and fading in
/// (`hostingBlur`, `hostingOpacity`). The glass itself stays live glass.
@Observable
final class PanelPresentation {
  var width: CGFloat = CardMetrics.width
  var height: CGFloat = PanelMotion.startHeight
  /// Vertical scale of the controls, from the top edge.
  var contentScale: CGFloat = PanelMotion.hiddenScale
  var contentBlur: CGFloat = PanelMotion.hiddenBlur
  var contentOpacity: Double = 0
  var isOpen = false
  /// Horizontal finger travel during a track-change swipe, already rubber-banded.
  var swipeOffset: CGFloat = 0
  /// Strength of the frosted underlayer, from the system Liquid Glass slider.
  var frost: Double = SystemGlass.frost
  /// Queue or outputs revealed under the controls.
  var section: PanelSection = .none
  @ObservationIgnored var onToggleSection: ((PanelSection) -> Void)?
  /// A queue row is under the pointer: two-finger swipes belong to the row,
  /// not to the panel's track-change / dismiss swipe.
  @ObservationIgnored var isPointerOverQueueRow = false
}

/// The system Liquid Glass appearance slider (System Settings › Appearance),
/// stored globally as `NSGlassTintAmount` (0 = Clear … 1 = Tinted).
enum SystemGlass {
  static var tintAmount: Double {
    UserDefaults.standard.object(forKey: "NSGlassTintAmount") as? Double ?? 0.5
  }

  /// Near Clear the lensing glass shows through almost untouched; toward
  /// Tinted the frost builds up to the strength that matched Liqoria there.
  static var frost: Double {
    min(max(tintAmount, 0), 1) * 0.85
  }
}

/// Apple's rubber-band curve: tracks the finger 1:1 at first, then resists,
/// never exceeding `limit`.
func rubberBand(_ offset: CGFloat, limit: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
  (offset * limit * constant) / (limit + constant * abs(offset))
}

enum PanelMotion {
  /// The glass starts as a strip the height of the menu bar item. With the
  /// (0.3, 0.5) spring this reproduces Liqoria's ~20 pt bottom overshoot
  /// (overshoot ≈ 16% of the distance travelled).
  static let startHeight: CGFloat = 30

  /// Liqoria's appear spring, (0.3, 0.5) (0x10031b228).
  static let height = Animation.spring(response: 0.3, dampingFraction: 0.5)
  /// Opening or closing the queue / outputs: Liqoria animates its mode
  /// height (158 + section) with `spring(0.3, 0.7)` (0x10031906c), so the
  /// glass doesn't swing up into the controls when a section folds away.
  static let section = Animation.spring(response: 0.3, dampingFraction: 0.7)

  /// The controls' hidden state, set by Liqoria's disappear (0x10031bc2c):
  /// squashed to 0.4 of their height toward the top edge, blur 7, opacity 0.
  /// Its appear (0x10031bb80) returns them to 1 / 0 / 1 on the same
  /// (0.3, 0.5) spring as the glass, so they stretch past full height and
  /// settle: the waterfall. The scale is y-only: Liqoria applies
  /// `scaleEffect(x: 1 − 0.95p, y: hostingScale · (1 − 0.95p), anchor: .top)`,
  /// `p` being swipe-to-dismiss progress (0x100318b00).
  static let hiddenScale: CGFloat = 0.4
  static let hiddenBlur: CGFloat = 7
  static let contentIn = height

  /// Liqoria's disappear is `.linear(duration: 0.3)` (0x10031b198): the
  /// open in reverse, glass and controls rising back toward the menu bar.
  static let close = Animation.linear(duration: 0.3)
  static let closeDuration: TimeInterval = 0.3

  static let reducedFade = Animation.easeOut(duration: 0.15)
}
