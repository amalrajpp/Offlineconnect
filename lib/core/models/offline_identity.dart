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
  final int fieldId; // 0-15
  final int subfieldId; // 0-15

  /// Timestamp when the identity was first generated.
  final DateTime createdAt;

  const OfflineIdentity({
    required this.offlineId,
    required this.username,
    required this.avatarId,
    required this.topWearColor,
    required this.bottomWearColor,
    required this.fieldId,
    required this.subfieldId,
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
        'fieldId': fieldId,
        'subfieldId': subfieldId,
        'createdAt': createdAt.toIso8601String(),
      };

  factory OfflineIdentity.fromMap(Map<String, dynamic> map) {
    return OfflineIdentity(
      offlineId: map['offlineId'] as String,
      username: map['username'] as String? ?? 'User',
      avatarId: map['avatarId'] as int? ?? 0,
      topWearColor: map['topWearColor'] as int? ?? 0,
      bottomWearColor: map['bottomWearColor'] as int? ?? 0,
      fieldId: map['fieldId'] as int? ?? 0,
      subfieldId: map['subfieldId'] as int? ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }

  OfflineIdentity copyWith({
    String? offlineId,
    String? username,
    int? avatarId,
    int? topWearColor,
    int? bottomWearColor,
    int? fieldId,
    int? subfieldId,
    DateTime? createdAt,
  }) {
    return OfflineIdentity(
      offlineId: offlineId ?? this.offlineId,
      username: username ?? this.username,
      avatarId: avatarId ?? this.avatarId,
      topWearColor: topWearColor ?? this.topWearColor,
      bottomWearColor: bottomWearColor ?? this.bottomWearColor,
      fieldId: fieldId ?? this.fieldId,
      subfieldId: subfieldId ?? this.subfieldId,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() => 'OfflineIdentity(id=$offlineId)';
}
