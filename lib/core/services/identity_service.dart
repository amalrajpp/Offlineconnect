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
  static const _keyCreatedAt = 'offline_user_created_at';
  static const _keyUsername = 'offline_user_username';
  
  static const _keyAvatar = 'offline_user_avatar';
  static const _keyTopWearColor = 'offline_user_top_wear';
  static const _keyBottomWearColor = 'offline_user_bottom_wear';
  static const _keyField = 'offline_user_field';
  static const _keySubfield = 'offline_user_subfield';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  OfflineIdentity? _identity;

  /// The current offline identity. Throws if [loadOrCreateIdentity] was not
  /// called yet.
  OfflineIdentity get identity {
    if (_identity == null) {
      throw StateError('IdentityService: identity not loaded yet. '
          'Call loadOrCreateIdentity() first.');
    }
    return _identity!;
  }

  /// Loads the existing identity from secure storage, or generates a fresh one.
  Future<OfflineIdentity> loadOrCreateIdentity() async {
    try {
      final existingId = await _storage.read(key: _keyId);

      if (existingId != null) {
        final createdAtStr = await _storage.read(key: _keyCreatedAt);
        final un = await _storage.read(key: _keyUsername) ?? 'User';
        
        final av = int.tryParse(await _storage.read(key: _keyAvatar) ?? '0') ?? 0;
        final topColor = int.tryParse(await _storage.read(key: _keyTopWearColor) ?? '0') ?? 0;
        final bottomColor = int.tryParse(await _storage.read(key: _keyBottomWearColor) ?? '0') ?? 0;
        final fid = int.tryParse(await _storage.read(key: _keyField) ?? '0') ?? 0;
        final sfid = int.tryParse(await _storage.read(key: _keySubfield) ?? '0') ?? 0;

        _identity = OfflineIdentity(
          offlineId: existingId,
          username: un,
          avatarId: av,
          topWearColor: topColor,
          bottomWearColor: bottomColor,
          fieldId: fid,
          subfieldId: sfid,
          createdAt: createdAtStr != null
              ? DateTime.parse(createdAtStr)
              : DateTime.now(),
        );
        return _identity!;
      }

      // Generate a new 16-byte random hex string (32 characters).
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      final hexId =
          bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fallbackUn = 'User${random.nextInt(9999).toString().padLeft(4, '0')}';

      final now = DateTime.now();
      await _storage.write(key: _keyId, value: hexId);
      await _storage.write(key: _keyUsername, value: fallbackUn);
      await _storage.write(key: _keyCreatedAt, value: now.toIso8601String());
      await _storage.write(key: _keyAvatar, value: '0');
      await _storage.write(key: _keyTopWearColor, value: '0');
      await _storage.write(key: _keyBottomWearColor, value: '0');
      await _storage.write(key: _keyField, value: '0');
      await _storage.write(key: _keySubfield, value: '0');

      _identity = OfflineIdentity(
        offlineId: hexId, 
        username: fallbackUn, 
        avatarId: 0,
        topWearColor: 0,
        bottomWearColor: 0,
        fieldId: 0,
        subfieldId: 0,
        createdAt: now,
      );
      return _identity!;
    } catch (e) {
      throw Exception('IdentityService: failed to load/create identity – $e');
    }
  }

  Future<void> setUsername(String newUsername) async {
    final clean = newUsername.trim().substring(0, newUsername.trim().length > 10 ? 10 : newUsername.trim().length);
    await _storage.write(key: _keyUsername, value: clean);
    _identity = _identity?.copyWith(username: clean);
  }

  Future<void> setTraits({
    required int avatarId,
    required int topWearColor,
    required int bottomWearColor,
    required int fieldId,
    required int subfieldId,
  }) async {
    await _storage.write(key: _keyAvatar, value: avatarId.toString());
    await _storage.write(key: _keyTopWearColor, value: topWearColor.toString());
    await _storage.write(key: _keyBottomWearColor, value: bottomWearColor.toString());
    await _storage.write(key: _keyField, value: fieldId.toString());
    await _storage.write(key: _keySubfield, value: subfieldId.toString());

    _identity = _identity?.copyWith(
      avatarId: avatarId,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      fieldId: fieldId,
      subfieldId: subfieldId,
    );
  }
}
