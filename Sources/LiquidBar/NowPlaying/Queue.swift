import Foundation

/// One upcoming item in the player's queue ("Playing Next").
struct QueueItem: Identifiable, Equatable {
  var id: String
  var title: String
  var artist: String
  var artworkHash: String?
}

/// Queue entry as the bridge sends it. Artwork bytes arrive once per image;
/// later entries carry only the hash.
nonisolated struct BridgeQueueItem: Decodable, Sendable {
  var id: String?
  var title: String?
  var artist: String?
  var artworkHash: String?
  var artwork: Data?
}
