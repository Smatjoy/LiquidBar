import AppKit
import SwiftUI

/// Two-finger swipes on a "Playing Next" row, after Liqoria's
/// `ScrollingQueueItem` (see docs/REVERSE_ENGINEERING.md):
///
/// - Only the row under the pointer listens: hover starts a local scroll-wheel
///   monitor, leaving stops it.
/// - Each event past ±0.1 pt of horizontal travel adds twice its distance to
///   a counter capped at 35 pt. Swiping the other way first takes the counter
///   back down.
/// - Reaching 35 pt fires the action once, then a 0.5 s cooldown.
/// - Lifting the fingers short of it eases the row back over 0.15 s (a plain
///   mouse wheel, which has no phases, gets 0.1 s of quiet instead).
///
/// `deltaX` < 0 removes the song, `deltaX` > 0 moves it to play next.
@Observable
final class QueueRowSwipe {
  static let threshold: CGFloat = 35
  static let sensitivity: CGFloat = 2
  static let deadZone: CGFloat = 0.1
  static let cooldown: Duration = .milliseconds(500)
  static let wheelResetDelay: TimeInterval = 0.1
  static let reset = Animation.easeOut(duration: 0.15)

  /// 0...1 toward removing the song.
  var removeProgress: CGFloat = 0
  /// 0...1 toward moving the song to play next.
  var moveProgress: CGFloat = 0

  @ObservationIgnored var onRemove: (() -> Void)?
  @ObservationIgnored var onMoveToTop: (() -> Void)?

  @ObservationIgnored private var removeAmount: CGFloat = 0
  @ObservationIgnored private var moveAmount: CGFloat = 0
  @ObservationIgnored private var isInCooldown = false
  @ObservationIgnored private var isInMoveCooldown = false
  @ObservationIgnored private var monitor: Any?
  @ObservationIgnored private var resetTimer: Timer?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
      return event
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    resetTimer?.invalidate()
    resetTimer = nil
    isInCooldown = false
    isInMoveCooldown = false
    resetRemove()
    resetMove()
  }

  private func handle(_ event: NSEvent) {
    guard !isInCooldown else { return }
    let dx = event.deltaX
    let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
    // Momentum after the fingers lift doesn't count.
    if isWheel || event.phase.contains(.began) || event.phase.contains(.changed) {
      if dx < -Self.deadZone {
        resetTimer?.invalidate()
        addRemove(dx)
        if isWheel { scheduleReset(remove: true) }
      } else if dx > Self.deadZone {
        if removeAmount > 0 {
          removeAmount = max(removeAmount - abs(dx) * Self.sensitivity, 0)
          removeProgress = removeAmount / Self.threshold
        } else if !isInMoveCooldown {
          resetTimer?.invalidate()
          addMove(dx)
          if isWheel { scheduleReset(remove: false) }
        }
      }
    }
    if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
      if removeAmount > 0 { resetRemove() }
      if moveAmount > 0 { resetMove() }
    }
  }

  private func addRemove(_ dx: CGFloat) {
    removeAmount = min(removeAmount + abs(dx) * Self.sensitivity, Self.threshold)
    removeProgress = removeAmount / Self.threshold
    guard removeAmount >= Self.threshold else { return }
    isInCooldown = true
    onRemove?()
    removeAmount = 0
    if removeProgress != 0 { removeProgress = 0 }
    endCooldown(remove: true)
  }

  private func addMove(_ dx: CGFloat) {
    moveAmount = min(moveAmount + abs(dx) * Self.sensitivity, Self.threshold)
    moveProgress = moveAmount / Self.threshold
    guard moveAmount >= Self.threshold else { return }
    isInMoveCooldown = true
    onMoveToTop?()
    moveAmount = 0
    moveProgress = 0
    endCooldown(remove: false)
  }

  private func resetRemove() {
    removeAmount = 0
    withAnimation(Self.reset) { removeProgress = 0 }
  }

  private func resetMove() {
    moveAmount = 0
    withAnimation(Self.reset) { moveProgress = 0 }
  }

  private func scheduleReset(remove: Bool) {
    resetTimer = Timer.scheduledTimer(withTimeInterval: Self.wheelResetDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        remove ? self?.resetRemove() : self?.resetMove()
      }
    }
  }

  private func endCooldown(remove: Bool) {
    Task { [weak self] in
      try? await Task.sleep(for: Self.cooldown)
      if remove { self?.isInCooldown = false } else { self?.isInMoveCooldown = false }
    }
  }
}

// MARK: - Ripple

/// The ripple that runs through a row as it jumps to play next: a damped wave
/// spreading from the artwork. Liqoria's `RippleEffect` values: origin
/// (12, 20), 0.6 s, amplitude 16, frequency 14, decay 14, 700 pt/s.
///
/// The Metal shader (Shaders/Ripple.metal) is compiled by Scripts/build-app.sh
/// when Xcode's Metal Toolchain is installed; without it the row just moves.
struct RippleEffect: ViewModifier {
  var origin = CGPoint(x: 12, y: 20)
  var trigger: Bool
  var duration: TimeInterval = 0.6
  var amplitude: Double = 16
  var frequency: Double = 14
  var decay: Double = 14
  var speed: Double = 700

  func body(content: Content) -> some View {
    if RippleShader.isAvailable {
      content.keyframeAnimator(initialValue: 0, trigger: trigger) { view, elapsed in
        view.modifier(RippleModifier(origin: origin, elapsed: elapsed, duration: duration,
                                     amplitude: amplitude, frequency: frequency, decay: decay, speed: speed))
      } keyframes: { _ in
        MoveKeyframe(0)
        LinearKeyframe(duration, duration: duration)
      }
    } else {
      content
    }
  }
}

private struct RippleModifier: ViewModifier {
  var origin: CGPoint
  var elapsed: TimeInterval
  var duration: TimeInterval
  var amplitude: Double
  var frequency: Double
  var decay: Double
  var speed: Double

  func body(content: Content) -> some View {
    let shader = ShaderLibrary.default.ripple(
      .float2(origin), .float(elapsed), .float(amplitude), .float(frequency), .float(decay), .float(speed)
    )
    content.layerEffect(shader, maxSampleOffset: CGSize(width: amplitude, height: amplitude),
                        isEnabled: 0 < elapsed && elapsed < duration)
  }
}

private enum RippleShader {
  static let isAvailable = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
}
