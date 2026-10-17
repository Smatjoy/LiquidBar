import AppKit

/// What is playing. Changes once per track.
struct Track: Equatable {
  var title: String
  var artist: String
  var album: String
  var bundleID: String?

  var id: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }
}

/// Where the playhead is. MediaRemote reports the elapsed time at a timestamp,
/// so the current position is extrapolated instead of polled.
struct Playback: Equatable {
  var isPlaying = false
  var duration: TimeInterval = 0
  var elapsed: TimeInterval = 0
  var timestamp = Date()
  var rate: Double = 1

  func position(at date: Date) -> TimeInterval {
    guard isPlaying else { return clamp(elapsed) }
    return clamp(elapsed + date.timeIntervalSince(timestamp) * max(rate, 0))
  }

  func progress(at date: Date) -> Double {
    duration > 0 ? position(at: date) / duration : 0
  }

  private func clamp(_ value: TimeInterval) -> TimeInterval {
    duration > 0 ? min(max(value, 0), duration) : max(value, 0)
  }
}

/// One line of bridge output.
nonisolated struct BridgeMessage: Decodable, Sendable {
  var type: String
  var playing: Bool?
  var bundleID: String?
  var title: String?
  var artist: String?
  var album: String?
  var duration: Double?
  var elapsed: Double?
  var rate: Double?
  var timestamp: Double?
  var artworkHash: String?
  var artwork: Data?
  var message: String?
  // type == "queue"
  var location: Int?
  var items: [BridgeQueueItem]?
  var supported: Bool?
  // type == "quality"
  var quality: String?
}

/// The badge Liqoria shows after the artist (its `AudioQuality`), from the
/// now-playing item's audio format tier.
enum AudioQuality: String {
  case lossless, hiResLossless, dolbyAtmos
}

extension TimeInterval {
  /// `3:07`, or `1:02:45` past an hour.
  var playbackLabel: String {
    let total = Int(self.rounded(.down))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }
}
