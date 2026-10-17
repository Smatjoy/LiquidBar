import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag-to-reorder for "Playing Next", modelled on Liqoria's
/// `DragSourceNSView` + `QueueDropDelegate` (see docs/REVERSE_ENGINEERING.md):
///
/// - The whole row is the drag handle. One AppKit view over the list watches
///   the mouse with a local monitor (it never takes clicks itself, so tapping
///   still plays and × still removes) and starts a drag after 4 pt of travel,
///   for the row under the pointer. (One view per row went wrong: the lazy
///   list keeps views for off-screen rows, and those answered presses too.)
/// - The drag image is a rendered copy of the row, centred on the pointer.
/// - The row leaves an empty slot; the others dim and soften while it moves.
/// - Hovering another row moves the dragged one there immediately, so the
///   list shows the final order before the drop.
/// - On drop the player is told; 0.3 s later the slot fills back in. Dropping
///   anywhere else puts the original order back.
enum QueueDrag {
  static let type = UTType(exportedAs: "dev.mattia.liquidbar.queue-item", conformingTo: .data)
  static let threshold: CGFloat = 4
  static let settleDelay: Duration = .milliseconds(300)
  /// Rows sliding into their new places while a drag hovers. Liqoria's binary
  /// doesn't pin this one down; it reuses the rows' own entrance spring.
  static let reorder = Animation.interpolatingSpring(mass: 1, stiffness: 150, damping: 15)
}

/// What the queue list knows about an ongoing drag.
@Observable
final class QueueDragState {
  /// The row being dragged; its slot shows empty.
  private(set) var draggingID: String?
  /// The lifted row: the others dim and blur slightly while it's set.
  private(set) var elevatedID: String?
  /// The row under the pointer; the one a press-and-move picks up.
  @ObservationIgnored var hoveredID: String?
  @ObservationIgnored private var originalOrder: [QueueItem]?
  @ObservationIgnored private var settleTask: Task<Void, Never>?

  func begin(_ item: QueueItem, service: NowPlayingService) {
    settleTask?.cancel()
    originalOrder = service.queue
    service.holdsQueueUpdates = true
    draggingID = item.id
    elevatedID = item.id
  }

  /// The pointer is over `target`: move the dragged row into its place.
  func hover(over target: QueueItem, service: NowPlayingService) {
    guard let draggingID, draggingID != target.id,
          let from = service.queue.firstIndex(where: { $0.id == draggingID }),
          let to = service.queue.firstIndex(of: target)
    else { return }
    var items = service.queue
    items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    withAnimation(QueueDrag.reorder) { service.previewQueueOrder(items) }
  }

  /// Dropped inside the list: keep the shown order and tell the player.
  func drop(service: NowPlayingService) -> Bool {
    guard let draggingID, let item = service.queue.first(where: { $0.id == draggingID }) else { return false }
    if let originalOrder, service.queue != originalOrder {
      service.commitQueueMove(item, from: originalOrder)
    }
    originalOrder = nil
    settle(service: service)
    return true
  }

  /// The drag session is over. Unless it was dropped on the list, the original
  /// order comes back.
  func end(dropped: Bool, service: NowPlayingService) {
    guard draggingID != nil else { return }
    if !dropped, let originalOrder {
      withAnimation(QueueDrag.reorder) { service.previewQueueOrder(originalOrder) }
    }
    originalOrder = nil
    if settleTask == nil { settle(service: service) }
  }

  private func settle(service: NowPlayingService) {
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: QueueDrag.settleDelay)
      guard let self, !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        self.draggingID = nil
        self.elevatedID = nil
      }
      self.settleTask = nil
      service.holdsQueueUpdates = false
    }
  }
}

// MARK: - Drop

/// One per row: entering a row reorders, dropping on it commits.
struct QueueRowDropDelegate: DropDelegate {
  let item: QueueItem
  let drag: QueueDragState
  let service: NowPlayingService

  func validateDrop(info: DropInfo) -> Bool { drag.draggingID != nil }

  func dropEntered(info: DropInfo) {
    drag.hover(over: item, service: service)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: drag.draggingID != nil ? .move : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    drag.drop(service: service)
  }
}

/// The gaps between and around rows accept the drop too, so letting go just
/// off a row keeps the order already shown.
struct QueueListDropDelegate: DropDelegate {
  let drag: QueueDragState
  let service: NowPlayingService

  func validateDrop(info: DropInfo) -> Bool { drag.draggingID != nil }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: drag.draggingID != nil ? .move : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    drag.drop(service: service)
  }
}

// MARK: - Drag source

/// Transparent overlay on the list that turns a press-and-move on a row into
/// an AppKit drag session, so the drag's end, including drops outside the
/// app, is reported (SwiftUI's `.draggable` never says when a drag is
/// cancelled).
struct QueueDragSource: NSViewRepresentable {
  /// The row under the pointer when the drag starts, with its artwork.
  let itemAtPointer: () -> (QueueItem, NSImage?)?
  let onBegan: (QueueItem) -> Void
  let onEnded: (_ dropped: Bool) -> Void

  func makeNSView(context: Context) -> QueueDragSourceView {
    QueueDragSourceView()
  }

  func updateNSView(_ view: QueueDragSourceView, context: Context) {
    view.itemAtPointer = itemAtPointer
    view.onBegan = onBegan
    view.onEnded = onEnded
  }

  static func dismantleNSView(_ view: QueueDragSourceView, coordinator: ()) {
    view.stopMonitoring()
  }
}

final class QueueDragSourceView: NSView, NSDraggingSource {
  var itemAtPointer: (() -> (QueueItem, NSImage?)?)?
  var onBegan: ((QueueItem) -> Void)?
  var onEnded: ((Bool) -> Void)?

  private var monitor: Any?
  private var mouseDown: NSEvent?
  private var isDragging = false

  /// Clicks fall through to the SwiftUI row underneath.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event) }
      return event
    }
  }

  func stopMonitoring() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  private func handle(_ event: NSEvent) {
    guard event.window === window else { return }
    switch event.type {
    case .leftMouseDown:
      let point = convert(event.locationInWindow, from: nil)
      mouseDown = visibleRect.contains(point) ? event : nil
      isDragging = false
    case .leftMouseDragged:
      guard let start = mouseDown, !isDragging else { return }
      let a = start.locationInWindow, b = event.locationInWindow
      guard hypot(b.x - a.x, b.y - a.y) > QueueDrag.threshold else { return }
      isDragging = true
      mouseDown = nil
      // Start outside the monitor callback; AppKit runs its own drag loop.
      DispatchQueue.main.async { [weak self] in self?.beginDrag(with: start) }
    case .leftMouseUp:
      mouseDown = nil
      isDragging = false
    default:
      break
    }
  }

  private func beginDrag(with event: NSEvent) {
    guard let (item, artwork) = itemAtPointer?() else { return }
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(item.id, forType: NSPasteboard.PasteboardType(QueueDrag.type.identifier))

    let image = renderPreview(for: item, artwork: artwork)
    let point = convert(event.locationInWindow, from: nil)
    let frame = CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                       width: image.size.width, height: image.size.height)
    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
    draggingItem.setDraggingFrame(frame, contents: image)

    onBegan?(item)
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  private func renderPreview(for item: QueueItem, artwork: NSImage?) -> NSImage {
    let dark = (window?.effectiveAppearance ?? effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let renderer = ImageRenderer(content:
      QueueDragPreview(item: item, artwork: artwork)
        .frame(width: bounds.width)
        .environment(\.colorScheme, dark ? .dark : .light)
    )
    renderer.scale = window?.backingScaleFactor ?? 2
    return renderer.nsImage ?? NSImage()
  }

  func draggingSession(_ session: NSDraggingSession,
                       sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    isDragging = false
    onEnded?(operation == .move)
  }
}

/// The row as it follows the pointer: artwork, title and artist floating on a
/// soft shadow, as Liqoria's `QueueItemDragPreview` draws it.
struct QueueDragPreview: View {
  let item: QueueItem
  let artwork: NSImage?

  var body: some View {
    HStack(spacing: 10) {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      ZStack {
        shape.fill(.quaternary)
        if let artwork {
          Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(shape)
      .shadow(color: .black.opacity(0.2), radius: 2)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(item.artist)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .shadow(color: .black.opacity(0.33), radius: 5)
  }
}
