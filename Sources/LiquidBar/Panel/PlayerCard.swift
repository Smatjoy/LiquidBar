import SwiftUI

/// Layout measured from Liqoria's menu bar player (points at 1x).
enum CardMetrics {
  static let width: CGFloat = 307
  static let height: CGFloat = 158
  static let cornerRadius: CGFloat = 26
  static let padding: CGFloat = 16
  static let artwork: CGFloat = 58
  /// Concentric with the card: 26 − 14 inset ≈ 12.
  static let artworkRadius: CGFloat = 12
}

struct PanelRootView: View {
  let service: NowPlayingService
  let presentation: PanelPresentation
  let outputs: AudioOutputs

  /// Card height for the revealed section; the glass springs to it.
  private var targetHeight: CGFloat {
    CardMetrics.height + SectionMetrics.height(for: presentation.section,
                                               queueCount: service.queue.count,
                                               outputCount: outputs.devices.count)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: CardMetrics.cornerRadius, style: .continuous)

    VStack(spacing: 0) {
      PlayerCard(service: service, presentation: presentation, isActive: presentation.isOpen)
        .frame(height: CardMetrics.height)
      sectionView
    }
      .frame(width: CardMetrics.width, height: targetHeight, alignment: .top)
      // Scale, blur and fade belong to the controls only. Applied to the glass
      // they render it offscreen and Liquid Glass degrades into a flat blur.
      .scaleEffect(x: 1, y: presentation.contentScale, anchor: .top)
      .blur(radius: max(presentation.contentBlur, 0))
      .opacity(presentation.contentOpacity)
      // The glass frame morphs while the controls keep their layout. Width and
      // height are separate modifiers so each follows its own spring.
      .modifier(AnimatedFrame(axis: .horizontal, length: presentation.width))
      .modifier(AnimatedFrame(axis: .vertical, length: presentation.height))
      .clipShape(shape)
      .background(LiquidGlass(cornerRadius: CardMetrics.cornerRadius, frost: presentation.frost))
      .offset(x: presentation.swipeOffset)
      .allowsHitTesting(presentation.isOpen)
      .padding(.top, PanelLayout.topGap)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onChange(of: targetHeight) { _, height in
        // Opening a section, or the queue changing length, springs the glass.
        guard presentation.isOpen else { return }
        withAnimation(PanelMotion.section) { presentation.height = height }
      }
  }

  @ViewBuilder private var sectionView: some View {
    Group {
      switch presentation.section {
      case .none: EmptyView()
      case .queue: QueueSection(service: service, presentation: presentation)
      case .outputs: OutputsSection(outputs: outputs)
      }
    }
    .overlay(alignment: .top) {
      if presentation.section != .none {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5).padding(.horizontal, CardMetrics.padding)
      }
    }
    // Rows sharpen in just behind the glass, as Liqoria's do.
    .transition(.blurReplace.combined(with: .opacity))
  }
}

/// One axis of the glass frame. Being `Animatable`, each axis interpolates
/// with the transaction of its own state change; a plain `.frame` would be
/// animated as layout, where SwiftUI merges both axes into a single spring.
struct AnimatedFrame: ViewModifier, Animatable {
  var axis: Axis
  var length: CGFloat

  var animatableData: CGFloat {
    get { length }
    set { length = newValue }
  }

  func body(content: Content) -> some View {
    switch axis {
    case .horizontal: content.frame(width: max(length, 1))
    case .vertical: content.frame(height: max(length, 1), alignment: .top)
    }
  }
}

/// Liqoria's panel glass, rebuilt from what its binary sets.
///
/// Liqoria wraps `NSGlassEffectView` in its own `DockMaterialNSView` /
/// `CornerMaskedGlassView` and configures it through private keys
/// (`_variant`, `_contentLensing`, …; see docs/REVERSE_ENGINEERING.md).
/// Matched on screen against the real app over the same backdrop:
/// - a lensing glass (`_variant` 11) that bends what is behind it;
/// - drawn `edgeOutset` larger than the card and clipped to it, so its bright
///   specular band is cut down to the thin, light line along the top and
///   bottom edges that Liqoria shows;
/// - over a frosted glass (`_variant` 4) whose strength follows the system
///   Liquid Glass slider, as Liqoria's glass does (crisp near Clear, soft
///   toward Tinted).
/// Without the private key both layers fall back to standard glass styles.
struct LiquidGlass: View {
  var cornerRadius: CGFloat
  /// 0...1 strength of the frosted underlayer.
  var frost: Double

  static let edgeOutset: CGFloat = 2

  var body: some View {
    let outset = Self.edgeOutset
    ZStack {
      GlassLayer(cornerRadius: cornerRadius + outset, style: .regular, variant: 4, alpha: frost)
      GlassLayer(cornerRadius: cornerRadius + outset, style: .clear, variant: 11,
                 tint: NSColor.white.withAlphaComponent(0.1))
    }
    .padding(-outset)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .background(GlassShadow(cornerRadius: cornerRadius))
  }
}

/// The soft shadow the system glass casts under Liqoria's card (its glass
/// config carries `_useReducedShadowRadius`). Ours is clipped away with the
/// rim, so it's drawn here, cut out under the card: a dark fill behind the
/// glass would be lensed into it and dim the card.
private struct GlassShadow: View {
  var cornerRadius: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    shape
      .fill(.black)
      .shadow(color: .black.opacity(0.16), radius: 9, y: 4)
      .mask {
        Rectangle()
          .padding(-40)
          .overlay { shape.blendMode(.destinationOut) }
          .compositingGroup()
      }
      .allowsHitTesting(false)
  }
}

/// One `NSGlassEffectView`. SwiftUI resizes it every animation frame, so the
/// glass itself morphs: lensing, rim light and all.
struct GlassLayer: NSViewRepresentable {
  var cornerRadius: CGFloat
  var style: NSGlassEffectView.Style
  var variant: Int?
  var tint: NSColor?
  var alpha: CGFloat = 1

  func makeNSView(context: Context) -> NSGlassEffectView {
    let glass = NSGlassEffectView()
    configure(glass)
    return glass
  }

  func updateNSView(_ glass: NSGlassEffectView, context: Context) {
    configure(glass)
  }

  private func configure(_ glass: NSGlassEffectView) {
    glass.style = style
    glass.cornerRadius = cornerRadius
    glass.tintColor = tint
    glass.alphaValue = alpha
    glass.isHidden = alpha < 0.01
    if let variant, glass.responds(to: NSSelectorFromString("set_variant:")),
       (glass.value(forKey: "_variant") as? Int) != variant {
      glass.setValue(variant, forKey: "_variant")
    }
  }
}

struct PlayerCard: View {
  let service: NowPlayingService
  let presentation: PanelPresentation
  let isActive: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        ArtworkTile(image: service.artwork, id: service.artworkID, isPlaying: service.playback.isPlaying)
        TrackInfo(track: service.track, isActive: isActive, isPlaying: service.playback.isPlaying,
                  quality: service.audioQuality)
      }
      .padding(.bottom, 12)

      Scrubber(playback: service.playback, isActive: isActive) { service.seek(to: $0) }
        .padding(.bottom, 8)

      Controls(service: service, section: presentation.section) { presentation.onToggleSection?($0) }
        .padding(.horizontal, -3)
    }
    .padding(.horizontal, CardMetrics.padding)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }
}

// MARK: - Artwork

struct ArtworkTile: View {
  let image: NSImage?
  let id: String?
  var isPlaying = true

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: CardMetrics.artworkRadius, style: .continuous)
    ZStack {
      shape.fill(.quaternary)
      Image(systemName: "music.note")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.tertiary)

      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
          .id(id)
          // Liqoria imports BlurReplaceTransition(.downUp) for content swaps.
          .transition(.blurReplace(.downUp))
      }
    }
    .frame(width: CardMetrics.artwork, height: CardMetrics.artwork)
    .clipShape(shape)
    .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    // Paused artwork recedes, as in Liqoria.
    .opacity(isPlaying ? 1 : 0.5)
    .animation(.smooth(duration: 0.45), value: id)
    .animation(.easeInOut(duration: 0.3), value: isPlaying)
    .accessibilityHidden(true)
  }
}

// MARK: - Title

struct TrackInfo: View {
  let track: Track?
  var isActive = true
  var isPlaying = false
  var quality: AudioQuality?

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      MarqueeLabel(text: track?.title ?? "Not Playing", font: .systemFont(ofSize: 13, weight: .semibold),
                   cue: isActive ? (isPlaying ? 2 : 1) : 0)
        .frame(height: 17)
      HStack(spacing: 4) {
        Text(track?.artist ?? "")
          .font(.system(size: 12))
          .lineLimit(1)
          .layoutPriority(1)
        if let quality {
          AudioQualityBadge(quality: quality)
            .transition(.opacity)
        }
      }
      .foregroundStyle(.secondary)
      .animation(.easeOut(duration: 0.2), value: quality)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .id(track?.id)
    .transition(.blurReplace(.downUp))
    .animation(.smooth(duration: 0.4), value: track?.id)
    .accessibilityElement(children: .combine)
  }
}

/// Bridges the Core Animation marquee so the panel title scrolls exactly like
/// the menu bar one.
struct MarqueeLabel: NSViewRepresentable {
  let text: String
  let font: NSFont
  /// Any change while non-zero replays one pass: the panel opening (0 → n)
  /// or playback starting or pausing.
  var cue = 0

  final class Coordinator { var lastCue = 0 }
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MarqueeView {
    let view = MarqueeView()
    view.font = font
    view.text = text
    return view
  }

  func updateNSView(_ view: MarqueeView, context: Context) {
    view.text = text
    if cue != context.coordinator.lastCue {
      if cue != 0 { view.scrollOnce(after: 0.45) } else { view.stopScrolling() }
      context.coordinator.lastCue = cue
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarqueeView, context: Context) -> CGSize? {
    let width = proposal.width ?? 200
    if view.maxWidth != width { view.maxWidth = width }
    return CGSize(width: width, height: view.intrinsicContentSize.height)
  }
}

// MARK: - Scrubber

struct Scrubber: View {
  let playback: Playback
  let isActive: Bool
  let onSeek: (TimeInterval) -> Void

  @State private var dragProgress: Double?
  @State private var barHeight: CGFloat = 6
  /// While held, the times light up in the fill's white.
  @State private var isHeld = false

  var body: some View {
    let paused = !isActive || !playback.isPlaying || dragProgress != nil
    TimelineView(.animation(minimumInterval: 0.25, paused: paused)) { context in
      let progress = dragProgress ?? playback.progress(at: context.date)
      let position = progress * playback.duration

      HStack(spacing: 8) {
        timeLabel(position.playbackLabel, alignment: .leading)
        bar(progress: progress)
        timeLabel("-" + max(playback.duration - position, 0).playbackLabel, alignment: .trailing)
      }
    }
    .frame(height: 14)
  }

  private func timeLabel(_ text: String, alignment: Alignment) -> some View {
    Text(text)
      .font(.system(size: 10.5, weight: .medium).monospacedDigit())
      .foregroundStyle(isHeld ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      .frame(minWidth: 30, alignment: alignment)
      .contentTransition(.numericText())
  }

  /// Liqoria's `MusicSlider` (0x10011fff0…0x1001218d8), modelled on Apple
  /// Music's scrubber rather than the system `Slider`: a 6 pt capsule that
  /// swells to 12 pt while held (`spring(0.25, 1.0)`) and settles back on
  /// release (`spring(0.4, 0.65)`). Hovering changes nothing.
  private func bar(progress: Double) -> some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let track = RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
      ZStack(alignment: .leading) {
        track.fill(.primary.opacity(0.18))
        Rectangle()
          .fill(.white)
          .frame(width: width * min(max(progress, 0), 1))
      }
      .clipShape(track)
      .frame(height: barHeight)
      .frame(maxHeight: .infinity)
      .contentShape(.rect)
      // Track 1:1 from the first touch; seek once on release.
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            if dragProgress == nil {
              withAnimation(.spring(response: 0.25, dampingFraction: 1)) {
                barHeight = 12
                isHeld = true
              }
            }
            dragProgress = min(max(value.location.x / max(width, 1), 0), 1)
          }
          .onEnded { _ in
            if let dragProgress { onSeek(dragProgress * playback.duration) }
            dragProgress = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
              barHeight = 6
              isHeld = false
            }
          }
      )
    }
    .accessibilityElement()
    .accessibilityLabel("Playback position")
    .accessibilityValue("\(playback.position(at: .now).playbackLabel) of \(playback.duration.playbackLabel)")
    .accessibilityAdjustableAction { direction in
      let step: TimeInterval = direction == .increment ? 10 : -10
      onSeek(min(max(playback.position(at: .now) + step, 0), playback.duration))
    }
  }
}

// MARK: - Controls

struct Controls: View {
  let service: NowPlayingService
  let section: PanelSection
  let toggle: (PanelSection) -> Void
  @State private var previousTaps = 0
  @State private var nextTaps = 0

  var body: some View {
    HStack(spacing: 0) {
      Button { toggle(.queue) } label: {
        Image(systemName: "list.bullet").font(.system(size: 16, weight: .medium))
      }
      .buttonStyle(GlyphButtonStyle(isActive: section == .queue))
      .accessibilityLabel("Playing Next")

      Spacer(minLength: 0)

      HStack(spacing: 16) {
        Button {
          previousTaps += 1
          service.previous()
        } label: {
          Image(systemName: "backward.fill")
            .font(.system(size: 19))
            .symbolEffect(.bounce.down, value: previousTaps)
        }
        .accessibilityLabel("Previous")

        Button(action: service.togglePlayPause) {
          Image(systemName: service.playback.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 26))
            .contentTransition(.symbolEffect(.replace.downUp))
        }
        .accessibilityLabel(service.playback.isPlaying ? "Pause" : "Play")

        Button {
          nextTaps += 1
          service.next()
        } label: {
          Image(systemName: "forward.fill")
            .font(.system(size: 19))
            .symbolEffect(.bounce.down, value: nextTaps)
        }
        .accessibilityLabel("Next")
      }
      .buttonStyle(GlyphButtonStyle(size: 40))
      .foregroundStyle(.primary)

      Spacer(minLength: 0)

      // As tall and as bright as the play glyph, the way Liqoria draws it.
      Button { toggle(.outputs) } label: {
        Image(systemName: "airplay.audio")
          .font(.system(size: 24))
          .foregroundStyle(.primary)
      }
      .buttonStyle(GlyphButtonStyle(size: 40, isActive: section == .outputs))
      .accessibilityLabel("Outputs")
    }
    .foregroundStyle(.secondary)
  }
}

/// Plain glyph with a soft rounded highlight on hover (as in Liqoria) and a
/// press that responds on mouse-down.
struct GlyphButtonStyle: ButtonStyle {
  var size: CGFloat = 36
  /// Lit while its section is open, like Liqoria's circled AirPlay button.
  var isActive = false

  func makeBody(configuration: Configuration) -> some View {
    GlyphButton(configuration: configuration, size: size, isActive: isActive)
  }

  private struct GlyphButton: View {
    let configuration: Configuration
    let size: CGFloat
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
      configuration.label
        .modifier(ActiveForeground(isActive: isActive))
        .frame(width: size, height: size)
        .background {
          if isActive {
            Circle().fill(.primary.opacity(configuration.isPressed ? 0.22 : 0.16))
          } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0))
          }
        }
        .scaleEffect(configuration.isPressed ? 0.88 : 1)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // Instant feedback on press, a soft spring on release.
        .animation(configuration.isPressed ? .easeOut(duration: 0.08) : .spring(duration: 0.3, bounce: 0.25),
                   value: configuration.isPressed)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
  }
}

/// Brightens an active glyph; inactive ones keep the inherited style.
private struct ActiveForeground: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if isActive { content.foregroundStyle(.primary) } else { content }
  }
}
