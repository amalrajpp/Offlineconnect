import 'dart:io';

import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/models/avatar_dna.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';
import '../nearby/nearby_controller.dart';

class ProfileController extends GetxController {
  final IdentityService _identity = Get.find<IdentityService>();
  final LocalDbService _db = Get.find<LocalDbService>();
  final FirebaseSyncService _firebase = Get.find<FirebaseSyncService>();
  final ImagePicker _imagePicker = ImagePicker();

  final RxBool hasAcceptedEULA = false.obs;
  final Rx<UserProfile?> profile = Rx<UserProfile?>(null);
  final RxBool isUploadingPhoto = false.obs;

  bool get isProfileSetUp => profile.value != null;
  String get _myOfflineId => _identity.identity.offlineId;

  @override
  void onInit() {
    super.onInit();
    loadLocalProfile();
    _loadEulaState();
  }

  Future<void> _loadEulaState() async {
    hasAcceptedEULA.value = await _identity.getEulaAccepted();
  }

  Future<void> loadLocalProfile() async {
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

  Future<void> saveProfile({
    required String username,
    required String displayName,
    required int topStyle,
    required int hairColor,
    required int eyeStyle,
    required int eyebrowType,
    required int mouthType,
    required int skinColor,
    required int facialHairType,
    required int accessoriesType,
    required int topWearColor,
    required int bottomWearColor,
    String? bio,
    String? photoUrl,
  }) async {
    if (!hasAcceptedEULA.value) {
      Get.snackbar('EULA Required', 'You must agree to the EULA to continue.');
      return;
    }
    await _identity.setEulaAccepted(true);

    // ── BITWISE FIREWALL ASSERTIONS (Fluttermoji) ──────────────────────────
    assert(topStyle >= 0 && topStyle <= 63);
    assert(hairColor >= 0 && hairColor <= 15);
    assert(eyeStyle >= 0 && eyeStyle <= 15);
    assert(eyebrowType >= 0 && eyebrowType <= 15);
    assert(mouthType >= 0 && mouthType <= 15);
    assert(skinColor >= 0 && skinColor <= 15);
    assert(facialHairType >= 0 && facialHairType <= 7);
    assert(accessoriesType >= 0 && accessoriesType <= 7);
    assert(topWearColor >= 0 && topWearColor <= 15);
    assert(bottomWearColor >= 0 && bottomWearColor <= 15);

    final trimmedName = displayName.trim();
    final trimmedUsername = username.trim();
    if (trimmedName.isEmpty || trimmedUsername.isEmpty) return;

    await _identity.setUsername(trimmedUsername);

    int avatarDna = AvatarDNA.pack(
      topStyle: topStyle,
      hairColor: hairColor,
      eyeStyle: eyeStyle,
      eyebrowType: eyebrowType,
      mouthType: mouthType,
      skinColor: skinColor,
      facialHairType: facialHairType,
      accessoriesType: accessoriesType,
    );

    await _identity.setTraits(
      avatarDna: avatarDna,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
    );

    final newProfile = UserProfile(
      offlineId: _myOfflineId,
      displayName: trimmedName,
      bio: bio?.trim().isEmpty == true ? null : bio?.trim(),
      photoUrl: photoUrl ?? profile.value?.photoUrl,
      avatarDna: avatarDna,
    );

    await _db.upsertKnownUser(newProfile);
    profile.value = newProfile;
    _firebase.syncProfile(newProfile);

    if (Get.isRegistered<NearbyController>()) {
      Get.find<NearbyController>().refreshBroadcast();
    }
  }

  Future<String?> pickAndUploadPhoto() async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (picked == null) return null;
      isUploadingPhoto.value = true;
      final url = await _firebase.uploadProfilePhoto(
        _myOfflineId,
        File(picked.path),
      );
      if (url != null) {
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

  Future<void> syncToCloud() async {
    final p = profile.value;
    if (p == null) return;
    await _firebase.syncProfile(p);
  }
}
