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
  final int avatarId; // 0-255
  final int topWearColor; // 0-15
  final int bottomWearColor; // 0-15
  final int gender; // 0-3
  final int nativity; // 0-31

  /// Timestamp when the identity was first generated.
  final DateTime createdAt;

  const OfflineIdentity({
    required this.offlineId,
    required this.username,
    required this.avatarId,
    required this.topWearColor,
    required this.bottomWearColor,
    required this.gender,
    required this.nativity,
    required this.createdAt,
  });

  /// The 12-character hash that is broadcast over BLE (first 6 bytes).
  String get bleHash => offlineId.substring(0, 12);

  Map<String, dynamic> toMap() => {
    'offlineId': offlineId,
    'username': username,
    'avatarId': avatarId,
    'topWearColor': topWearColor,
    'bottomWearColor': bottomWearColor,
    'gender': gender,
    'nativity': nativity,
    'createdAt': createdAt.toIso8601String(),
  };

  factory OfflineIdentity.fromMap(Map<String, dynamic> map) {
    return OfflineIdentity(
      offlineId: map['offlineId'] as String,
      username: map['username'] as String? ?? 'User',
      avatarId: map['avatarId'] as int? ?? 0,
      topWearColor: map['topWearColor'] as int? ?? 0,
      bottomWearColor: map['bottomWearColor'] as int? ?? 0,
      gender: map['gender'] as int? ?? 0,
      nativity: map['nativity'] as int? ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  OfflineIdentity copyWith({
    String? offlineId,
    String? username,
    int? avatarId,
    int? topWearColor,
    int? bottomWearColor,
    int? gender,
    int? nativity,
    DateTime? createdAt,
  }) {
    return OfflineIdentity(
      offlineId: offlineId ?? this.offlineId,
      username: username ?? this.username,
      avatarId: avatarId ?? this.avatarId,
      topWearColor: topWearColor ?? this.topWearColor,
      bottomWearColor: bottomWearColor ?? this.bottomWearColor,
      gender: gender ?? this.gender,
      nativity: nativity ?? this.nativity,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() => 'OfflineIdentity(id=$offlineId)';
}
