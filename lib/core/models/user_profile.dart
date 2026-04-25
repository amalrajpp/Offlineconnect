import 'package:cloud_firestore/cloud_firestore.dart';

/// A minimal user profile stored locally for known nearby users,
/// and synced to Firestore when online.
class UserProfile {
  /// The offline identity of this user.
  final String offlineId;

  /// Display name (max 30 characters).
  final String displayName;

  /// Short bio / tagline (optional).
  final String? bio;

  /// Firebase Storage URL for profile photo (optional).
  /// Only visible to mutually connected users.
  final String? photoUrl;

  /// The local Bitwise Bio avatar ID.
  final int avatarDna;

  /// Last time the user was seen online (from Firestore).
  final DateTime? lastOnline;

  const UserProfile({
    required this.offlineId,
    required this.displayName,
    this.bio,
    this.photoUrl,
    this.avatarDna = 0,
    this.lastOnline,
  });

  // ── Local SQLite ────────────────────────────────────────────────────────

  Map<String, dynamic> toMap() => {
    'offline_id': offlineId,
    'display_name': displayName,
    if (bio != null) 'bio': bio,
    if (photoUrl != null) 'photo_url': photoUrl,
    'avatar_id': avatarDna,
  };

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      offlineId: map['offline_id'] as String,
      displayName: map['display_name'] as String,
      bio: map['bio'] as String?,
      photoUrl: map['photo_url'] as String?,
      avatarDna: map['avatar_id'] as int? ?? 0,
    );
  }

  // ── Firestore ───────────────────────────────────────────────────────────

  Map<String, dynamic> toFirestoreMap({String? firebaseUid}) => {
    'displayName': displayName,
    if (bio != null) 'bio': bio,
    if (photoUrl != null) 'photoUrl': photoUrl,
    'avatarId': avatarDna,
    if (firebaseUid != null) 'firebaseUid': firebaseUid,
    'lastOnline': FieldValue.serverTimestamp(),
  };

  factory UserProfile.fromFirestore(
    String offlineId,
    Map<String, dynamic> data,
  ) {
    return UserProfile(
      offlineId: offlineId,
      displayName: data['displayName'] as String? ?? 'Unknown',
      bio: data['bio'] as String?,
      photoUrl: data['photoUrl'] as String?,
      avatarDna: data['avatarDna'] as int? ?? 0,
      lastOnline: data['lastOnline'] != null
          ? (data['lastOnline'] as Timestamp).toDate()
          : null,
    );
  }

  UserProfile copyWith({
    String? displayName,
    String? bio,
    String? photoUrl,
    int? avatarDna,
  }) {
    return UserProfile(
      offlineId: offlineId,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      photoUrl: photoUrl ?? this.photoUrl,
      avatarDna: avatarDna ?? this.avatarDna,
      lastOnline: lastOnline,
    );
  }

  @override
  String toString() => 'UserProfile(id=$offlineId, name=$displayName)';
}
