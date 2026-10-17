import AppKit
import Observation
import os

private let log = Logger(subsystem: "LiquidBar", category: "NowPlaying")

/// Owns the MediaRemote bridge process and publishes the system-wide
/// Now Playing state.
///
/// MediaRemote rejects third-party processes since macOS 15.4, so the bridge
/// library runs inside `/usr/bin/perl` (Apple-signed) and streams JSON lines.
@Observable
final class NowPlayingService {
  private(set) var track: Track?
  private(set) var playback = Playback()
  private(set) var artwork: NSImage?
  /// Changes whenever `artwork` does; drives artwork transitions.
  private(set) var artworkID: String?
  private(set) var appIcon: NSImage?
  /// Lossless / Hi-Res Lossless / Dolby Atmos for the current track, if any.
  private(set) var audioQuality: AudioQuality?
  private(set) var isBridgeRunning = false
  /// Items after the current one, in play order.
  private(set) var queue: [QueueItem] = []
  /// False when the player does not expose its queue to MediaRemote.
  private(set) var isQueueSupported = true
  @ObservationIgnored private var currentQueueItemID: String?

  var hasMedia: Bool { track != nil }

  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var input: FileHandle?
  @ObservationIgnored private var readTask: Task<Void, Never>?
  @ObservationIgnored private var restartDelay: Duration = .milliseconds(500)
  @ObservationIgnored private var clearArtworkTask: Task<Void, Never>?
  @ObservationIgnored private var ignoreStateUntil = Date.distantPast
  /// The bridge only ships artwork bytes when the hash changes, so tracks
  /// from the same album arrive with a hash and no data. Keep recent images.
  @ObservationIgnored private var artworkCache: [String: NSImage] = [:]

  // MARK: Lifecycle

  func start() {
    guard process == nil else { return }
    guard let library = Self.bridgeLibraryURL() else {
      log.error("NowPlayingBridge dylib not found next to the app")
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", Self.perlLoader, library.path]
    let stdout = Pipe(), stdin = Pipe()
    process.standardOutput = stdout
    process.standardInput = stdin
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.bridgeDidExit() }
    }

    do {
      try process.run()
    } catch {
      log.error("Failed to launch bridge: \(error.localizedDescription, privacy: .public)")
      scheduleRestart()
      return
    }

    self.process = process
    input = stdin.fileHandleForWriting
    isBridgeRunning = true

    let messages = BridgeReader.messages(from: stdout.fileHandleForReading)
    readTask = Task { [weak self] in
      for await message in messages {
        self?.apply(message)
      }
    }
  }

  func stop() {
    readTask?.cancel()
    try? input?.close()
    process?.terminate()
    process = nil
  }

  private func bridgeDidExit() {
    process = nil
    input = nil
    isBridgeRunning = false
    readTask?.cancel()
    scheduleRestart()
  }

  private func scheduleRestart() {
    let delay = restartDelay
    restartDelay = min(restartDelay * 2, .seconds(10))
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      self?.start()
    }
  }

  // MARK: Commands

  /// Optimistic: the UI flips immediately, the bridge confirms a moment later.
  func togglePlayPause() {
    let now = Date()
    playback.elapsed = playback.position(at: now)
    playback.timestamp = now
    playback.isPlaying.toggle()
    holdOptimisticState()
    send("toggle")
  }

  func next() { send("next") }

  // MARK: Queue

  func refreshQueue() { send("queue") }

  func playQueueItem(_ item: QueueItem) {
    send("queueplay \(item.id)")
  }

  /// Optimistic: the row leaves at once, the bridge re-reads the queue after.
  func removeQueueItem(_ item: QueueItem) {
    queue.removeAll { $0.id == item.id }
    send("queueremove \(item.id)")
  }

  /// While a row is being dragged the list reorders live; bridge updates
  /// wait until the drag is over so they don't yank rows from under it.
  var holdsQueueUpdates = false {
    didSet {
      guard !holdsQueueUpdates, let pending = pendingQueue else { return }
      pendingQueue = nil
      applyQueue(pending)
    }
  }
  @ObservationIgnored private var pendingQueue: BridgeMessage?

  /// Shows a new order without telling the player (drag in progress).
  func previewQueueOrder(_ items: [QueueItem]) {
    queue = items
  }

  /// Moves `item` to play right after the current song.
  func moveQueueItemToFront(_ item: QueueItem) {
    guard let index = queue.firstIndex(where: { $0.id == item.id }), index > 0,
          let current = currentQueueItemID
    else { return }
    queue.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
    send("queuemove \(item.id) \(current)")
  }

  /// Tells the player about a move already shown by `previewQueueOrder`.
  ///
  /// MediaRemote's reorder takes "insert after <anchor>", but a song moved
  /// *down* lands just before the anchor (observed with Music on macOS 27).
  /// So moving up anchors on the new predecessor, moving down on the new
  /// successor, and moving to the very end takes two steps.
  func commitQueueMove(_ item: QueueItem, from original: [QueueItem]) {
    guard let old = original.firstIndex(where: { $0.id == item.id }),
          let new = queue.firstIndex(where: { $0.id == item.id }),
          old != new
    else { return }

    if new < old {
      guard let anchor = new > 0 ? queue[new - 1].id : currentQueueItemID else { return }
      send("queuemove \(item.id) \(anchor)")
    } else if new + 1 < queue.count {
      send("queuemove \(item.id) \(queue[new + 1].id)")
    } else {
      // Lands just before the old last song; then lift that one above it.
      let last = queue[new - 1]
      guard let above = new >= 2 ? queue[new - 2].id : currentQueueItemID else { return }
      send("queuemove \(item.id) \(last.id)")
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(300))
        self?.send("queuemove \(last.id) \(above)")
      }
    }
  }

  func artwork(forHash hash: String?) -> NSImage? {
    hash.flatMap { artworkCache[$0] }
  }
  func previous() { send("previous") }

  func seek(to time: TimeInterval) {
    playback.elapsed = time
    playback.timestamp = Date()
    holdOptimisticState()
    send("seek \(time)")
  }

  /// Players echo the pre-command state once before the new one; ignore that
  /// echo so the optimistic UI doesn't flicker back.
  private func holdOptimisticState() {
    ignoreStateUntil = Date().addingTimeInterval(0.35)
  }

  private func send(_ command: String) {
    guard let input else { return }
    try? input.write(contentsOf: Data((command + "\n").utf8))
  }

  // MARK: Applying bridge state

  private func apply(_ message: BridgeMessage) {
    switch message.type {
    case "ready":
      restartDelay = .milliseconds(500)
    case "state":
      applyState(message)
    case "queue":
      applyQueue(message)
    case "quality":
      // Ignore an answer that belongs to the previous track.
      guard message.title == nil || message.title == track?.title else { break }
      let quality = message.quality.flatMap(AudioQuality.init(rawValue:))
      if quality != audioQuality { audioQuality = quality }
    case "error":
      log.error("Bridge: \(message.message ?? "unknown", privacy: .public)")
    default:
      break
    }
  }

  private func applyState(_ message: BridgeMessage) {
    guard let title = message.title, !title.isEmpty else {
      track = nil
      audioQuality = nil
      playback = Playback()
      setArtwork(nil, id: nil)
      return
    }

    let newTrack = Track(
      title: title,
      artist: message.artist ?? "",
      album: message.album ?? "",
      bundleID: message.bundleID
    )
    let trackChanged = newTrack.id != track?.id
    if trackChanged { audioQuality = nil }
    if newTrack.bundleID != track?.bundleID { appIcon = Self.icon(for: newTrack.bundleID) }
    track = newTrack

    if trackChanged || Date() >= ignoreStateUntil {
      playback = Playback(
        isPlaying: message.playing ?? false,
        duration: message.duration ?? 0,
        elapsed: message.elapsed ?? 0,
        timestamp: message.timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date(),
        rate: (message.rate ?? 0) > 0 ? message.rate! : 1
      )
    }

    if let data = message.artwork, let image = NSImage(data: data) {
      if let hash = message.artworkHash {
        if artworkCache.count > 96 { artworkCache.removeAll() }
        artworkCache[hash] = image
      }
      setArtwork(image, id: message.artworkHash)
    } else if let hash = message.artworkHash {
      if let cached = artworkCache[hash] {
        setArtwork(cached, id: hash)
      } else if hash != artworkID {
        // Known hash but no bytes we kept: ask the bridge to resend them.
        send("refresh")
      }
    } else if trackChanged {
      // Players often publish the title before the artwork. Keep the old
      // artwork briefly instead of flashing the placeholder.
      clearArtworkTask?.cancel()
      clearArtworkTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled else { return }
        self?.setArtwork(nil, id: nil)
      }
    }
  }

  private func applyQueue(_ message: BridgeMessage) {
    guard !holdsQueueUpdates else {
      pendingQueue = message
      return
    }
    isQueueSupported = message.supported ?? false
    let items = message.items ?? []
    for item in items {
      if let hash = item.artworkHash, let data = item.artwork, artworkCache[hash] == nil,
         let image = NSImage(data: data) {
        artworkCache[hash] = image
      }
    }
    let location = min(max(message.location ?? 0, 0), items.count)
    currentQueueItemID = location < items.count ? items[location].id : nil
    queue = items.dropFirst(location + 1).compactMap { item in
      guard let id = item.id else { return nil }
      return QueueItem(id: id, title: item.title ?? "", artist: item.artist ?? "", artworkHash: item.artworkHash)
    }
  }

  private func setArtwork(_ image: NSImage?, id: String?) {
    clearArtworkTask?.cancel()
    guard id != artworkID || image == nil && artwork != nil else { return }
    artwork = image
    artworkID = id
  }

  func activatePlayerApp() {
    guard let bundleID = track?.bundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }

  // MARK: Helpers

  private static func icon(for bundleID: String?) -> NSImage? {
    guard let bundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  private static let perlLoader = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "npb_run") or die DynaLoader::dl_error();
    my $run = DynaLoader::dl_install_xsub("main::npb_run", $sym);
    &$run();
    """

  /// The app bundle ships it in Resources; `swift run` leaves it beside the executable.
  private static func bridgeLibraryURL() -> URL? {
    let name = "libNowPlayingBridge.dylib"
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent(name),
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
    ]
    return candidates.compactMap(\.self).first { FileManager.default.fileExists(atPath: $0.path) }
  }
}

/// Splits the bridge's stdout into decoded messages off the main actor;
/// artwork lines can be a megabyte of base64.
nonisolated enum BridgeReader {
  static func messages(from handle: FileHandle) -> AsyncStream<BridgeMessage> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        let decoder = JSONDecoder()
        do {
          for try await line in handle.bytes.lines {
            guard let message = try? decoder.decode(BridgeMessage.self, from: Data(line.utf8)) else { continue }
            continuation.yield(message)
          }
        } catch {}
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
