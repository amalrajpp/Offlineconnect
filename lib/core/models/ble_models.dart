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

  /// The 12-char hex hash (first 6 bytes of offlineId) of the discovered peer.
  final String myHash;

  /// The target hash embedded in the advertisement (non-null when intent > 0).
  final String? targetHash;

  /// The broadcasted 10-char username.
  final String? offlineUsername;

  // ── Offline Bio Traits ──
  final int avatarId;
  final int topWearColor;
  final int bottomWearColor;
  final int gender;
  final int nativity;

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
    this.avatarId = 0,
    this.topWearColor = 0,
    this.bottomWearColor = 0,
    this.gender = 0,
    this.nativity = 0,
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
    int? avatarId,
    int? topWearColor,
    int? bottomWearColor,
    int? gender,
    int? nativity,
  }) {
    return DiscoveredPeer(
      deviceId: deviceId,
      myHash: myHash,
      targetHash: targetHash ?? this.targetHash,
      offlineUsername: offlineUsername ?? this.offlineUsername,
      avatarId: avatarId ?? this.avatarId,
      topWearColor: topWearColor ?? this.topWearColor,
      bottomWearColor: bottomWearColor ?? this.bottomWearColor,
      gender: gender ?? this.gender,
      nativity: nativity ?? this.nativity,
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
