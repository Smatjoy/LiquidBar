import SwiftUI

/// The expandable part of the card under the transport controls, as in
/// Liqoria: the queue button reveals "Playing Next", the AirPlay button
/// reveals "Outputs". The glass grows to fit on the same bouncy spring.
enum PanelSection: Equatable {
  case none, queue, outputs
}

enum SectionMetrics {
  static let top: CGFloat = 12
  static let header: CGFloat = 22
  static let bottom: CGFloat = 12
  static let queueRow: CGFloat = 52
  static let maxQueueRows = 4
  static let outputRow: CGFloat = 34
  static let outputSpacing: CGFloat = 8

  static func height(for section: PanelSection, queueCount: Int, outputCount: Int) -> CGFloat {
    switch section {
    case .none:
      return 0
    case .queue:
      let rows = max(min(queueCount, maxQueueRows), 1)
      return top + header + CGFloat(rows) * queueRow + bottom
    case .outputs:
      let rows = max(outputCount, 1)
      return top + header + CGFloat(rows) * outputRow + CGFloat(rows - 1) * outputSpacing + bottom
    }
  }

  /// Tallest the card can get; sizes the panel window.
  static var maxHeight: CGFloat {
    CardMetrics.height + top + header + CGFloat(maxQueueRows) * queueRow + bottom
  }
}

struct SectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: SectionMetrics.header, alignment: .leading)
  }
}

// MARK: - Queue

struct QueueSection: View {
  let service: NowPlayingService
  let presentation: PanelPresentation
  @State private var drag = QueueDragState()
  /// Flips on appear so the rows spring in one after another.
  @State private var animateItems = false

  var body: some View {
    VStack(spacing: 0) {
      SectionHeader(title: "Playing Next")
      if !service.isQueueSupported {
        placeholder("This player doesn't share its queue")
      } else if service.queue.isEmpty {
        placeholder("Nothing playing next")
      } else {
        ScrollView(.vertical) {
          LazyVStack(spacing: 0) {
            ForEach(Array(service.queue.enumerated()), id: \.element.id) { index, item in
              QueueRow(item: item, index: index, artwork: service.artwork(forHash: item.artworkHash),
                       service: service, presentation: presentation, drag: drag, animateItems: animateItems)
            }
          }
        }
        .scrollIndicators(.never)
        .frame(height: CGFloat(min(service.queue.count, SectionMetrics.maxQueueRows)) * SectionMetrics.queueRow)
        .overlay {
          QueueDragSource {
            guard let id = drag.hoveredID, let item = service.queue.first(where: { $0.id == id }) else { return nil }
            return (item, service.artwork(forHash: item.artworkHash))
          } onBegan: { item in
            drag.begin(item, service: service)
          } onEnded: { dropped in
            drag.end(dropped: dropped, service: service)
          }
        }
        .onDrop(of: [QueueDrag.type], delegate: QueueListDropDelegate(drag: drag, service: service))
      }
    }
    .padding(.top, SectionMetrics.top)
    .padding(.bottom, SectionMetrics.bottom)
    .padding(.horizontal, CardMetrics.padding)
    .onAppear {
      // Next tick, so the rows first render in their hidden state.
      Task { animateItems = true }
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, minHeight: SectionMetrics.queueRow)
  }
}

struct QueueRow: View {
  let item: QueueItem
  let index: Int
  let artwork: NSImage?
  let service: NowPlayingService
  let presentation: PanelPresentation
  let drag: QueueDragState
  let animateItems: Bool
  @State private var isHovering = false
  @State private var swipe = QueueRowSwipe()
  /// Set by a completed left swipe: the row slides out, then leaves the queue.
  @State private var isRemoving = false
  @State private var rippleTrigger = false

  /// Another row is lifted: this one steps back.
  private var isReceded: Bool {
    drag.elevatedID != nil && drag.elevatedID != item.id
  }

  private var isVisible: Bool {
    (animateItems && drag.draggingID != item.id) || isReceded
  }

  var body: some View {
    HStack(spacing: 10) {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      ZStack {
        shape.fill(.quaternary)
        if let artwork {
          Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
          Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(.tertiary)
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(shape)

      VStack(alignment: .leading, spacing: 1) {
        Text(item.title)
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(item.artist)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Liqoria leaves it off the first row: that song is already next.
      if index > 0 {
        PlayNextButton(action: moveToTop)
          .accessibilityLabel("Play \(item.title) next")
      }

      Button {
        withAnimation(.smooth(duration: 0.3)) { service.removeQueueItem(item) }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(item.title) from queue")
    }
    .frame(height: SectionMetrics.queueRow)
    .padding(.horizontal, 6)
    .background {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.primary.opacity(isHovering && drag.draggingID == nil ? 0.07 : 0))
    }
    .overlay(alignment: .bottom) {
      Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 56)
    }
    .contentShape(.rect)
    .onHover { hovering in
      isHovering = hovering
      presentation.isPointerOverQueueRow = hovering
      if hovering {
        drag.hoveredID = item.id
        swipe.onRemove = removeBySwipe
        swipe.onMoveToTop = moveToTop
        swipe.start()
      } else {
        if drag.hoveredID == item.id { drag.hoveredID = nil }
        swipe.stop()
      }
    }
    .onDisappear {
      swipe.stop()
      if isHovering { presentation.isPointerOverQueueRow = false }
    }
    .onTapGesture { service.playQueueItem(item) }
    // Liqoria's QueueItemView (0x10006f87c): the row follows the swipe up to
    // 40 pt, fading and softening as it nears the threshold.
    .offset(x: isRemoving ? -60 : (swipe.moveProgress - swipe.removeProgress) * 40)
    .opacity(isRemoving ? 0 : 1 - 0.3 * swipe.removeProgress - 0.3 * swipe.moveProgress)
    .blur(radius: isRemoving ? 6 : 2 * swipe.removeProgress + 2 * swipe.moveProgress)
    .modifier(RippleEffect(trigger: rippleTrigger))
    .onDrop(of: [QueueDrag.type], delegate: QueueRowDropDelegate(item: item, drag: drag, service: service))
    // Liqoria's row modifiers, in its order (QueueListView row builder,
    // 0x10007d300): others recede while one is lifted…
    .opacity(isReceded ? 0.7 : 1)
    .blur(radius: isReceded ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: drag.elevatedID)
    // …the dragged row leaves its slot empty, and on appear each row drops
    // in from slightly above, small and soft, 40 ms after the one before.
    .opacity(isVisible ? 1 : 0)
    .scaleEffect(animateItems ? (drag.draggingID == item.id ? 1.05 : 1) : 0.85)
    .offset(y: animateItems ? 0 : -10)
    .blur(radius: animateItems ? 0 : 4)
    .animation(.interpolatingSpring(mass: 1, stiffness: 150, damping: 15).delay(Double(index) * 0.04),
               value: animateItems)
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Plays this song now. Drag to reorder.")
    .accessibilityAction(named: "Play Next") { moveToFront() }
    .accessibilityAction(named: "Remove") { withAnimation(.smooth(duration: 0.3)) { service.removeQueueItem(item) } }
  }

  /// Liqoria (0x100072784): a tap of haptic feedback, the row slides out on a
  /// critically damped spring, and the song goes 0.35 s later.
  private func removeBySwipe() {
    guard !isRemoving else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
      isRemoving = true
      swipe.removeProgress = 0
    }
    Task {
      try? await Task.sleep(for: .milliseconds(350))
      withAnimation(.smooth(duration: 0.3)) { service.removeQueueItem(item) }
    }
  }

  /// Liqoria (0x100072c40, and the button's release at 0x1000737f4): the
  /// first song is already next; any other ripples, then moves 0.2 s later.
  private func moveToTop() {
    guard index > 0 else { return }
    rippleTrigger.toggle()
    Task {
      try? await Task.sleep(for: .milliseconds(200))
      moveToFront()
    }
  }

  private func moveToFront() {
    withAnimation(QueueDrag.reorder) { service.moveQueueItemToFront(item) }
  }
}

/// Liqoria's play-next button (QueueItemView, 0x100070adc): a secondary
/// glyph lifted or sunk 0.3 in brightness to stand off the glass, that dips to
/// 85 % while held and fires on release (unless the press turned into a
/// row drag, which Liqoria doesn't guard against).
private struct PlayNextButton: View {
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var isPressing = false

  var body: some View {
    Image(systemName: "text.line.first.and.arrowtriangle.forward")
      .foregroundStyle(.secondary)
      .brightness(colorScheme == .dark ? 0.3 : -0.3)
      .scaleEffect(isPressing ? 0.85 : 1)
      .animation(.spring(response: 0.2, dampingFraction: 1), value: isPressing)
      .frame(width: 22, height: 30)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in if !isPressing { isPressing = true } }
          .onEnded { value in
            isPressing = false
            // Past the drag threshold the press became a row drag instead.
            if hypot(value.translation.width, value.translation.height) <= QueueDrag.threshold { action() }
          }
      )
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { action() }
  }
}

// MARK: - Outputs

struct OutputsSection: View {
  let outputs: AudioOutputs

  var body: some View {
    VStack(spacing: 0) {
      SectionHeader(title: "Outputs")
      VStack(spacing: SectionMetrics.outputSpacing) {
        ForEach(outputs.devices) { device in
          OutputRow(device: device, isSelected: device.id == outputs.defaultID, outputs: outputs)
        }
      }
    }
    .padding(.top, SectionMetrics.top)
    .padding(.bottom, SectionMetrics.bottom)
    .padding(.horizontal, CardMetrics.padding)
  }
}

/// A capsule per device. The selected one fills white up to its volume and
/// can be dragged to change it, as in Liqoria.
struct OutputRow: View {
  let device: AudioOutputs.Device
  let isSelected: Bool
  let outputs: AudioOutputs
  @State private var isHovering = false

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let level = CGFloat(outputs.volume ?? 1)
      ZStack(alignment: .leading) {
        Capsule().fill(.primary.opacity(isHovering && !isSelected ? 0.14 : 0.08))
        if isSelected {
          Capsule()
            .fill(.white.opacity(0.92))
            .frame(width: max(proxy.size.height, width * level))
        }
        HStack(spacing: 8) {
          Image(systemName: device.symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 18)
          Text(device.name)
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            .lineLimit(1)
          Spacer(minLength: 4)
          if isSelected {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
          }
        }
        .padding(.horizontal, 12)
        .foregroundStyle(isSelected ? AnyShapeStyle(.black.opacity(0.8)) : AnyShapeStyle(.secondary))
      }
      .contentShape(Capsule())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard isSelected, outputs.volume != nil else { return }
            outputs.setVolume(Float(value.location.x / max(width, 1)))
          }
          .onEnded { value in
            if !isSelected, abs(value.translation.width) < 4 { outputs.select(device) }
          }
      )
    }
    .frame(height: SectionMetrics.outputRow)
    .onHover { isHovering = $0 }
    .animation(.smooth(duration: 0.25), value: isSelected)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(device.name)
    .accessibilityValue(isSelected ? "Selected, volume \(Int((outputs.volume ?? 0) * 100)) percent" : "")
    .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
  }
}
