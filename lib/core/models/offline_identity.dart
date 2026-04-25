/// Persistent offline identity that survives app restarts.
///
/// The [offlineId] is a random 16-byte (32 hex-char) string stored in
/// secure storage. The first 12 characters are used as the BLE broadcast hash.
class OfflineIdentity {
  /// 32-character hex string (16 random bytes).
  final String offlineId;

  /// The 10-character offline username.
  final String username;

  // ── Offline Bitwise Bio Parameters ──
  final int avatarDna; // 32-bit (4-byte) packed DNA
  final int topWearColor; // 0-15
  final int bottomWearColor; // 0-15

  /// Timestamp when the identity was first generated.
  final DateTime createdAt;

  const OfflineIdentity({
    required this.offlineId,
    required this.username,
    required this.avatarDna,
    required this.topWearColor,
    required this.bottomWearColor,
    required this.createdAt,
  });

  /// The 12-character hash that is broadcast over BLE (first 6 bytes).
  String get bleHash => offlineId.substring(0, 12);

  Map<String, dynamic> toMap() => {
    'offlineId': offlineId,
    'username': username,
    'avatarDna': avatarDna,
    'topWearColor': topWearColor,
    'bottomWearColor': bottomWearColor,
    'createdAt': createdAt.toIso8601String(),
  };

  factory OfflineIdentity.fromMap(Map<String, dynamic> map) {
    return OfflineIdentity(
      offlineId: map['offlineId'] as String,
      username: map['username'] as String? ?? 'User',
      avatarDna: map['avatarDna'] as int? ?? 0,
      topWearColor: map['topWearColor'] as int? ?? 0,
      bottomWearColor: map['bottomWearColor'] as int? ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  OfflineIdentity copyWith({
    String? offlineId,
    String? username,
    int? avatarDna,
    int? topWearColor,
    int? bottomWearColor,
    DateTime? createdAt,
  }) {
    return OfflineIdentity(
      offlineId: offlineId ?? this.offlineId,
      username: username ?? this.username,
      avatarDna: avatarDna ?? this.avatarDna,
      topWearColor: topWearColor ?? this.topWearColor,
      bottomWearColor: bottomWearColor ?? this.bottomWearColor,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() => 'OfflineIdentity(id=$offlineId)';
}
