/// BLE intent types for the Zero-GATT connectionless handshake protocol.
enum BleIntent {
  /// Device is simply announcing its presence (index 0).
  presence,

  /// Device is requesting a connection with a specific target (index 1).
  requestConnection,

  /// Device is accepting a connection from a specific target (index 2).
  acceptConnection,
}

/// Represents a peer discovered via BLE advertisement scanning.
class DiscoveredPeer {
  /// The platform-level BLE device identifier.
  final String deviceId;

  /// The 4-byte hex hash of the discovered peer's offlineId.
  final String myHash;

  /// The target hash embedded in the advertisement (non-null when intent > 0).
  final String? targetHash;

  /// The broadcasted username (truncated to 12 bytes UTF-8 on Android).
  final String? offlineUsername;

  // ── Offline Bio Traits (32-bit Packed DNA) ──
  final int avatarDna;
  final int topWearColor;
  final int bottomWearColor;

  /// The intent encoded in the advertisement payload.
  final BleIntent intent;

  /// The received signal strength indicator (closer to 0 = stronger).
  final int rssi;

  /// The last time this peer was seen.
  final DateTime lastSeen;

  DiscoveredPeer({
    required this.deviceId,
    required this.myHash,
    this.targetHash,
    this.offlineUsername,
    this.avatarDna = 0,
    this.topWearColor = 0,
    this.bottomWearColor = 0,
    required this.intent,
    required this.rssi,
    required this.lastSeen,
  });

  /// Creates a copy with updated fields (used by the buffer to refresh RSSI).
  DiscoveredPeer copyWith({
    int? rssi,
    DateTime? lastSeen,
    BleIntent? intent,
    String? targetHash,
    String? offlineUsername,
    int? avatarDna,
    int? topWearColor,
    int? bottomWearColor,
  }) {
    return DiscoveredPeer(
      deviceId: deviceId,
      myHash: myHash,
      targetHash: targetHash ?? this.targetHash,
      offlineUsername: offlineUsername ?? this.offlineUsername,
      avatarDna: avatarDna ?? this.avatarDna,
      topWearColor: topWearColor ?? this.topWearColor,
      bottomWearColor: bottomWearColor ?? this.bottomWearColor,
      intent: intent ?? this.intent,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeer &&
          runtimeType == other.runtimeType &&
          myHash == other.myHash;

  @override
  int get hashCode => myHash.hashCode;

  @override
  String toString() =>
      'DiscoveredPeer(hash=$myHash, intent=$intent, rssi=$rssi)';
}
