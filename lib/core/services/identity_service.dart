import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';

import '../models/offline_identity.dart';

/// Manages the persistent offline identity stored in secure storage.
///
/// On first launch a random 16-byte (32 hex-char) identity is generated
/// and persisted. Subsequent launches re-use the same identity.
class IdentityService extends GetxService {
  static const _keyId = 'offline_user_id';
  static const _keyDbEncryption = 'offline_db_encryption_key';
  static const _keyCreatedAt = 'offline_user_created_at';
  static const _keyUsername = 'offline_user_username';

  static const _keyAvatar = 'offline_user_avatar';
  static const _keyTopWearColor = 'offline_user_top_wear';
  static const _keyBottomWearColor = 'offline_user_bottom_wear';
  static const _keyGender = 'offline_user_gender';
  static const _keyNativity = 'offline_user_nativity';
  static const _keyLastWardrobeUpdate = 'offline_user_last_wardrobe_update';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  OfflineIdentity? _identity;
  String? _dbEncryptionKey;

  /// The current offline identity. Throws if [loadOrCreateIdentity] was not
  /// called yet.
  OfflineIdentity get identity {
    if (_identity == null) {
      throw StateError(
        'IdentityService: identity not loaded yet. '
        'Call loadOrCreateIdentity() first.',
      );
    }
    return _identity!;
  }

  /// Loads the existing identity from secure storage, or generates a fresh one.
  Future<OfflineIdentity> loadOrCreateIdentity() async {
    try {
      final existingId = await _storage.read(key: _keyId);
      final existingDbKey = await _storage.read(key: _keyDbEncryption);

      if (existingDbKey != null) {
        _dbEncryptionKey = existingDbKey;
      } else {
        // Generate a new 256-bit (32 byte) key for SQLCipher and store it
        final random = Random.secure();
        final keyBytes = List<int>.generate(32, (_) => random.nextInt(256));
        _dbEncryptionKey = keyBytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        await _storage.write(key: _keyDbEncryption, value: _dbEncryptionKey);
      }

      if (existingId != null) {
        final createdAtStr = await _storage.read(key: _keyCreatedAt);
        final un = await _storage.read(key: _keyUsername) ?? 'User';

        final av =
            int.tryParse(await _storage.read(key: _keyAvatar) ?? '0') ?? 0;
        final topColor =
            int.tryParse(await _storage.read(key: _keyTopWearColor) ?? '0') ??
            0;
        final bottomColor =
            int.tryParse(
              await _storage.read(key: _keyBottomWearColor) ?? '0',
            ) ??
            0;
        final gId =
            int.tryParse(await _storage.read(key: _keyGender) ?? '0') ?? 0;
        final nId =
            int.tryParse(await _storage.read(key: _keyNativity) ?? '0') ?? 0;

        _identity = OfflineIdentity(
          offlineId: existingId,
          username: un,
          avatarId: av,
          topWearColor: topColor,
          bottomWearColor: bottomColor,
          gender: gId,
          nativity: nId,
          createdAt: createdAtStr != null
              ? DateTime.parse(createdAtStr)
              : DateTime.now(),
        );
        return _identity!;
      }

      // Generate a new 16-byte random hex string (32 characters).
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      final hexId = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final fallbackUn =
          'User${random.nextInt(9999).toString().padLeft(4, '0')}';

      final now = DateTime.now();
      await _storage.write(key: _keyId, value: hexId);
      await _storage.write(key: _keyUsername, value: fallbackUn);
      await _storage.write(key: _keyCreatedAt, value: now.toIso8601String());
      await _storage.write(key: _keyAvatar, value: '0');
      await _storage.write(key: _keyTopWearColor, value: '0');
      await _storage.write(key: _keyBottomWearColor, value: '0');
      await _storage.write(key: _keyGender, value: '0');
      await _storage.write(key: _keyNativity, value: '0');

      _identity = OfflineIdentity(
        offlineId: hexId,
        username: fallbackUn,
        avatarId: 0,
        topWearColor: 0,
        bottomWearColor: 0,
        gender: 0,
        nativity: 0,
        createdAt: now,
      );

      await _storage.write(
        key: _keyLastWardrobeUpdate,
        value: now.toIso8601String(),
      );

      return _identity!;
    } catch (e) {
      throw Exception('IdentityService: failed to load/create identity – $e');
    }
  }

  Future<void> setUsername(String newUsername) async {
    final clean = newUsername.trim().substring(
      0,
      newUsername.trim().length > 10 ? 10 : newUsername.trim().length,
    );
    await _storage.write(key: _keyUsername, value: clean);
    _identity = _identity?.copyWith(username: clean);
  }

  /// Checks if a wardrobe update is required (older than 12 hours)
  Future<bool> needsWardrobeCheck() async {
    final lastUpdateStr = await _storage.read(key: _keyLastWardrobeUpdate);
    if (lastUpdateStr == null) return true;
    final lastUpdate = DateTime.tryParse(lastUpdateStr);
    if (lastUpdate == null) return true;
    final difference = DateTime.now().difference(lastUpdate);
    return difference.inHours >= 12;
  }

  /// Marks the wardrobe as visually confirmed and resets the 12-hour timer.
  Future<void> confirmWardrobe() async {
    await _storage.write(
      key: _keyLastWardrobeUpdate,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<void> setTraits({
    required int avatarId,
    required int topWearColor,
    required int bottomWearColor,
    required int gender,
    required int nativity,
  }) async {
    await _storage.write(key: _keyAvatar, value: avatarId.toString());
    await _storage.write(key: _keyTopWearColor, value: topWearColor.toString());
    await _storage.write(
      key: _keyBottomWearColor,
      value: bottomWearColor.toString(),
    );
    await _storage.write(key: _keyGender, value: gender.toString());
    await _storage.write(key: _keyNativity, value: nativity.toString());
    await confirmWardrobe();

    _identity = _identity?.copyWith(
      avatarId: avatarId,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      gender: gender,
      nativity: nativity,
    );
  }

  /// Clears the user identity and all secure storage completely. Required for UGC deletion.
  Future<void> wipeIdentity() async {
    await _storage.deleteAll();
    _identity = null;
    _dbEncryptionKey = null;
  }

  /// Returns the securely stored DB encryption key. Assumes loadOrCreateIdentity was called.
  String get dbEncryptionKey {
    if (_dbEncryptionKey == null) {
      throw StateError('IdentityService: dbEncryptionKey not loaded yet.');
    }
    return _dbEncryptionKey!;
  }
}
