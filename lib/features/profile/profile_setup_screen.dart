import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../core/models/avatar_dna.dart';
import 'avatar_dna_selection_screen.dart';
import '../nearby/widgets/remote_avatar_view.dart';

import 'profile_controller.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/local_db_service.dart';

import '../../core/constants/assets.dart';

/// One-time profile setup screen shown on first launch.
/// Redesigned with a modern, flat, bold Snapchat-style UI.
class ProfileSetupScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const ProfileSetupScreen({super.key, required this.onComplete});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _nameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _saving = false;
  bool _isLoading = true;
  String? _photoUrl;

  // New trait keys for 32-bit DNA (Observable)
  final _topStyle = 0.obs;
  final _hairColor = 0.obs;
  final _eyeStyle = 0.obs;
  final _eyebrowType = 0.obs;
  final _mouthType = 0.obs;
  final _skinColor = 0.obs;
  final _facialHairType = 0.obs;
  final _accessoriesType = 0.obs;

  final _topWearColor = 0.obs;
  final _bottomWearColor = 0.obs;

  @override
  void initState() {
    super.initState();
    _initIdentity();
    _preloadAssets();

    // Re-sync if the controller profile loads/changes (Fix for profile tab not showing saved DNA)
    final controller = Get.find<ProfileController>();
    ever(controller.profile, (_) => _initIdentity());

    // Force a fresh check after the first frame to catch any missed loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        controller.loadLocalProfile();
        _initIdentity();
      }
    });
  }

  void _initIdentity() {
    try {
      final identity = Get.find<IdentityService>().identity;
      _usernameController.text = identity.username;

      final dna = AvatarDNA.unpack(identity.avatarDna);

      _topStyle.value = dna['topStyle'] ?? 0;
      _hairColor.value = dna['hairColor'] ?? 0;
      _eyeStyle.value = dna['eyeStyle'] ?? 0;
      _eyebrowType.value = dna['eyebrowType'] ?? 0;
      _mouthType.value = dna['mouthType'] ?? 0;
      _skinColor.value = dna['skinColor'] ?? 0;
      _facialHairType.value = dna['facialHairType'] ?? 0;
      _accessoriesType.value = dna['accessoriesType'] ?? 0;

      _topWearColor.value = identity.topWearColor;
      _bottomWearColor.value = identity.bottomWearColor;

      final controller = Get.find<ProfileController>();
      final existing = controller.profile.value;
      if (existing != null) {
        if (mounted) {
          setState(() {
            _nameController.text = existing.displayName;
            _bioController.text = existing.bio ?? '';
            _photoUrl = existing.photoUrl;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _preloadAssets() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final controller = Get.find<ProfileController>();
    final url = await controller.pickAndUploadPhoto();
    if (url != null && mounted) {
      setState(() => _photoUrl = url);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    try {
      final controller = Get.find<ProfileController>();
      await controller.saveProfile(
        username: _usernameController.text,
        displayName: _nameController.text,
        topStyle: _topStyle.value,
        hairColor: _hairColor.value,
        eyeStyle: _eyeStyle.value,
        eyebrowType: _eyebrowType.value,
        mouthType: _mouthType.value,
        skinColor: _skinColor.value,
        facialHairType: _facialHairType.value,
        accessoriesType: _accessoriesType.value,
        topWearColor: _topWearColor.value,
        bottomWearColor: _bottomWearColor.value,
        bio: _bioController.text,
        photoUrl: _photoUrl,
      );
      widget.onComplete();
    } catch (e) {
      Get.snackbar('Error', 'Failed to save profile: $e', snackPosition: SnackPosition.BOTTOM);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildFlatCard({required Widget child, required ThemeData theme}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ProfileController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Create Identity', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      // Photo
                      GestureDetector(
                        onTap: _pickPhoto,
                        child: Obx(() {
                          final uploading = controller.isUploadingPhoto.value;
                          return CircleAvatar(
                            radius: 56,
                            backgroundImage: _photoUrl != null ? CachedNetworkImageProvider(_photoUrl!) : null,
                            child: uploading ? CircularProgressIndicator() : (_photoUrl == null ? Icon(Icons.person, size: 48) : null),
                          );
                        }),
                      ),
                      const SizedBox(height: 32),

                      // Username
                      TextFormField(
                        controller: _usernameController,
                        decoration: InputDecoration(labelText: 'Offline Username', hintText: 'e.g. Satoshi'),
                        validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),

                      // DNA
                      _buildFlatCard(
                        theme: theme,
                        child: Column(
                          children: [
                            Obx(() {
                              final currentDna = AvatarDNA.pack(
                                topStyle: _topStyle.value,
                                hairColor: _hairColor.value,
                                eyeStyle: _eyeStyle.value,
                                eyebrowType: _eyebrowType.value,
                                mouthType: _mouthType.value,
                                skinColor: _skinColor.value,
                                facialHairType: _facialHairType.value,
                                accessoriesType: _accessoriesType.value,
                              );
                              return Row(
                                children: [
                                  RemoteAvatarView(
                                    dna: currentDna,
                                    radius: 40,
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('AVATAR DNA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.white)),
                                        Text('DNA: 0x${currentDna.toRadixString(16).toUpperCase().padLeft(8, '0')}', 
                                            style: const TextStyle(color: Colors.white54, fontSize: 10, fontFamily: 'monospace')),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            }),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final result = await Get.to<Map<String, int>>(() => const AvatarDnaSelectionScreen());
                                  if (result != null) {
                                    _topStyle.value = result['topStyle'] ?? 0;
                                    _hairColor.value = result['hairColor'] ?? 0;
                                    _eyeStyle.value = result['eyeStyle'] ?? 0;
                                    _eyebrowType.value = result['eyebrowType'] ?? 0;
                                    _mouthType.value = result['mouthType'] ?? 0;
                                    _skinColor.value = result['skinColor'] ?? 0;
                                    _facialHairType.value = result['facialHairType'] ?? 0;
                                    _accessoriesType.value = result['accessoriesType'] ?? 0;
                                  }
                                },
                                icon: const Icon(Icons.fingerprint),
                                label: const Text('CONFIGURE DNA'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // EULA (Only show if not already accepted)
                      Obx(() => controller.hasAcceptedEULA.value 
                        ? const SizedBox.shrink() 
                        : Column(
                            children: [
                              CheckboxListTile(
                                title: Text('I agree to the Terms and EULA', style: TextStyle(fontSize: 12)),
                                value: controller.hasAcceptedEULA.value,
                                onChanged: (v) => controller.hasAcceptedEULA.value = v ?? false,
                                controlAffinity: ListTileControlAffinity.leading,
                              ),
                              const SizedBox(height: 16),
                            ],
                          )),

                      // Save
                      Obx(() {
                        final canSave = !_saving && controller.hasAcceptedEULA.value;
                        return SizedBox(
                          width: double.infinity,
                          height: 64,
                          child: FilledButton(
                            onPressed: canSave ? _save : null,
                            child: _saving ? const CircularProgressIndicator(color: Colors.white) : const Text('Save & Update Radar'),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
