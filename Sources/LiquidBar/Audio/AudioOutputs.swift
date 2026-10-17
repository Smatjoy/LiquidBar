import AudioToolbox
import CoreAudio
import Observation

/// The Mac's audio output devices, the current default and its volume.
///
/// Liqoria's "Outputs" list is exactly CoreAudio's output devices (on this Mac:
/// LG ULTRAGEAR, LSX II LT, MacBook Pro Speakers), with the selected one
/// doubling as a volume slider. Listeners keep it current when the output or
/// volume changes elsewhere (menu bar, System Settings, keyboard keys).
@Observable
final class AudioOutputs {
  struct Device: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var symbol: String { isBuiltIn ? "laptopcomputer" : "airplay.audio" }
  }

  private(set) var devices: [Device] = []
  private(set) var defaultID: AudioObjectID = 0
  /// 0...1, or nil when the device has no software volume (e.g. HDMI).
  private(set) var volume: Float?

  @ObservationIgnored private var volumeListenerDevice: AudioObjectID = 0
  @ObservationIgnored private var isListening = false

  init() {
    refresh()
  }

  // MARK: Reading

  func refresh() {
    devices = Self.outputDeviceIDs().compactMap { id in
      // The name comes back +1 retained.
      guard let name: Unmanaged<CFString> = Self.read(id, kAudioObjectPropertyName) else { return nil }
      let transport: UInt32 = Self.read(id, kAudioDevicePropertyTransportType) ?? 0
      return Device(id: id, name: name.takeRetainedValue() as String, transport: transport)
    }
    defaultID = Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    volume = Self.read(defaultID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    watchVolume(of: defaultID)
  }

  // MARK: Writing

  func select(_ device: Device) {
    var id = device.id
    for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
      var address = Self.address(selector)
      AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                 UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }
    refresh()
  }

  func setVolume(_ value: Float) {
    var clamped = min(max(value, 0), 1)
    volume = clamped
    var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    AudioObjectSetPropertyData(defaultID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &clamped)
  }

  // MARK: Listening

  /// Starts following device-list, default-device and volume changes.
  func startListening() {
    guard !isListening else { return }
    isListening = true
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
      var address = Self.address(selector)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
    refresh()
  }

  private func watchVolume(of device: AudioObjectID) {
    guard isListening, device != volumeListenerDevice, device != 0 else { return }
    volumeListenerDevice = device
    // Listeners on previous devices simply go quiet: their callbacks re-read
    // the *current* default, so a stale one is harmless.
    var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    AudioObjectAddPropertyListenerBlock(device, &address, .main) { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.volume = Self.read(self.defaultID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                scope: kAudioObjectPropertyScopeOutput)
      }
    }
  }

  // MARK: CoreAudio helpers

  private static func address(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var address = address(selector, scope: scope)
    guard AudioObjectHasProperty(object, &address) else { return nil }
    var size = UInt32(MemoryLayout<T>.size)
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { pointer.deallocate() }
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
    return pointer.load(as: T.self)
  }

  private static func outputDeviceIDs() -> [AudioObjectID] {
    var address = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
      var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
      var streamSize: UInt32 = 0
      return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
    }
  }
}
