import 'dart:io';

import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/user_profile.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';
import '../nearby/nearby_controller.dart';

/// Manages the user's own profile — display name, bio, and photo.
///
/// Saves locally (SQLite) for offline access and syncs to Firestore
/// when online so other connected users can see the profile.
class ProfileController extends GetxController {
  final IdentityService _identity = Get.find<IdentityService>();
  final LocalDbService _db = Get.find<LocalDbService>();
  final FirebaseSyncService _firebase = Get.find<FirebaseSyncService>();
  final ImagePicker _imagePicker = ImagePicker();

  /// EULA Agreement required for UGC compliance.
  final RxBool hasAcceptedEULA = false.obs;

  /// The user's own profile. Observable so the UI updates reactively.
  final Rx<UserProfile?> profile = Rx<UserProfile?>(null);

  /// Whether a photo upload is in progress.
  final RxBool isUploadingPhoto = false.obs;

  /// Whether the profile has been set up (has a display name).
  bool get isProfileSetUp => profile.value != null;

  String get _myOfflineId => _identity.identity.offlineId;

  @override
  void onInit() {
    super.onInit();
    _loadLocalProfile();
  }

  /// Loads the profile from local DB.
  Future<void> _loadLocalProfile() async {
    try {
      final db = await _db.database;
      final rows = await db.query(
        'known_users',
        where: 'offline_id = ?',
        whereArgs: [_myOfflineId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        profile.value = UserProfile.fromMap(rows.first);
      }
    } catch (e) {
      Get.log('ProfileController: loadLocalProfile failed – $e');
    }
  }

  /// Saves or updates the user's profile.
  ///
  /// Persists locally first (always works), then syncs to Firestore
  /// if Firebase is available.
  Future<void> saveProfile({
    required String username,
    required String displayName,
    required int avatarId,
    required int topWearColor,
    required int bottomWearColor,
    required int gender,
    required int nativity,
    String? bio,
    String? photoUrl,
  }) async {
    if (!hasAcceptedEULA.value) {
      Get.snackbar(
        'EULA Required',
        'You must agree to the End User License Agreement to continue.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }
    // ── BITWISE FIREWALL ASSERTIONS ─────────────────────────────────────────
    // These guarantee our integers never exceed the bit-length we allocate
    // in the manufacturer data payload. If they do, the payload will silently
    // overflow or corrupt, destroying the mesh visibility logic.
    assert(
      avatarId >= 0 && avatarId <= 255,
      'Avatar ID overflow - must fit 8 bits (0-255)',
    );
    assert(
      topWearColor >= 0 && topWearColor <= 15,
      'Top color overflow - must fit 4 bits (0-15)',
    );
    assert(
      bottomWearColor >= 0 && bottomWearColor <= 15,
      'Bottom color overflow - must fit 4 bits (0-15)',
    );
    assert(
      gender >= 0 && gender <= 7,
      'Gender overflow - must fit 3 bits (0-7)',
    );
    assert(
      nativity >= 0 && nativity <= 31,
      'Nativity overflow - must fit 5 bits (0-31)',
    );
    // ────────────────────────────────────────────────────────────────────────

    final trimmedName = displayName.trim();
    final trimmedUsername = username.trim();
    if (trimmedName.isEmpty || trimmedName.length > 30) return;
    if (trimmedUsername.isEmpty || trimmedUsername.length > 10) return;

    await _identity.setUsername(trimmedUsername);
    await _identity.setTraits(
      avatarId: avatarId,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      gender: gender,
      nativity: nativity,
    );

    final newProfile = UserProfile(
      offlineId: _myOfflineId,
      displayName: trimmedName,
      bio: bio?.trim().isEmpty == true ? null : bio?.trim(),
      photoUrl: photoUrl ?? profile.value?.photoUrl,
      avatarId: avatarId,
    );

    // Save locally.
    await _db.upsertKnownUser(newProfile);
    profile.value = newProfile;

    // Sync to Firestore in the background (fire-and-forget).
    _firebase.syncProfile(newProfile);

    // If currently broadcasting our presence via BLE, refresh it silently
    // so peers instantly pick up our latest clothing or avatar traits.
    if (Get.isRegistered<NearbyController>()) {
      Get.find<NearbyController>().refreshBroadcast();
    }
  }

  /// Picks a photo from the gallery and uploads it to Firebase Storage.
  ///
  /// Returns the download URL on success, or `null` on failure.
  Future<String?> pickAndUploadPhoto() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );
      if (picked == null) return null;

      isUploadingPhoto.value = true;

      final url = await _firebase.uploadProfilePhoto(
        _myOfflineId,
        File(picked.path),
      );

      if (url != null) {
        // Update local profile with the new photo URL.
        final current = profile.value;
        if (current != null) {
          final updated = current.copyWith(photoUrl: url);
          await _db.upsertKnownUser(updated);
          profile.value = updated;
        }
      }

      return url;
    } catch (e) {
      Get.log('ProfileController: pickAndUploadPhoto failed – $e');
      return null;
    } finally {
      isUploadingPhoto.value = false;
    }
  }

  /// Syncs the local profile to Firestore (call when connectivity resumes).
  Future<void> syncToCloud() async {
    final p = profile.value;
    if (p == null) return;
    await _firebase.syncProfile(p);
  }
}
