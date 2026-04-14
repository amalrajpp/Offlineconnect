import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'profile_controller.dart';
import '../../core/services/identity_service.dart';
import '../../core/constants/bio_constants.dart';
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
  bool _isLoading = true; // Added loading state back per request
  String? _photoUrl;

  int _avatarId = 0;
  int _topWearColor = 0;
  int _bottomWearColor = 0;
  int _gender = 0;
  int _nativity = 0;

  // Cached constants for faster building
  static const List<String> _outfitColors = [
    "None/Hide",
    "Black",
    "White",
    "Gray",
    "Red",
    "Blue",
    "Green",
    "Yellow",
    "Orange",
    "Purple",
    "Pink",
    "Brown",
    "Beige",
    "Multicolor",
    "Denim",
    "Other",
  ];

  late final List<DropdownMenuItem<int>> _outfitColorItems;
  late final List<DropdownMenuItem<int>> _fieldItems;
  final Map<int, List<DropdownMenuItem<int>>> _subfieldItemsCache = {};

  @override
  void initState() {
    super.initState();
    _initIdentity();
    _buildDropdownCaches();
    _preloadAssets();
  }

  void _buildDropdownCaches() {
    _outfitColorItems = _outfitColors.asMap().entries.map((e) {
      return DropdownMenuItem<int>(
        value: e.key,
        child: Text(e.value, overflow: TextOverflow.ellipsis),
      );
    }).toList();

    _fieldItems = List.generate(
      genderOptions.length,
      (index) => DropdownMenuItem(
        value: index,
        child: Text(getGenderName(index), overflow: TextOverflow.ellipsis),
      ),
    );
  }

  List<DropdownMenuItem<int>> _getSubfieldItems(int fieldIndex) {
    if (_subfieldItemsCache.containsKey(fieldIndex)) {
      return _subfieldItemsCache[fieldIndex]!;
    }
    final len = nativityOptions.length;
    final items = List.generate(
      len,
      (idx) => DropdownMenuItem(
        value: idx,
        child: Text(
          getNativityName(idx),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    _subfieldItemsCache[fieldIndex] = items;
    return items;
  }

  void _initIdentity() {
    try {
      final identity = Get.find<IdentityService>().identity;
      _usernameController.text = identity.username;
      _avatarId = identity.avatarId;
      if (_avatarId < 0 || _avatarId >= AppAssets.maxAvatars) _avatarId = 0;

      _topWearColor = identity.topWearColor;
      if (_topWearColor < 0 || _topWearColor > 15) _topWearColor = 0;

      _bottomWearColor = identity.bottomWearColor;
      if (_bottomWearColor < 0 || _bottomWearColor > 15) _bottomWearColor = 0;

      _gender = identity.gender;
      if (_gender < 0 || _gender >= genderOptions.length) _gender = 0;

      _nativity = identity.nativity;
      final subLen = nativityOptions.length;
      if (_nativity < 0 || _nativity >= subLen) _nativity = 0;
    } catch (_) {}
  }

  Future<void> _preloadAssets() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    final futures = <Future<void>>[];
    for (int i = 0; i < AppAssets.maxAvatars; i++) {
      futures.add(
        precacheImage(
          ResizeImage(
            AssetImage(AppAssets.getAvatarPath(i)),
            width: 144,
            height: 144,
          ),
          context,
        ),
      );
    }
    await Future.wait(futures);

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
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
        avatarId: _avatarId,
        topWearColor: _topWearColor,
        bottomWearColor: _bottomWearColor,
        gender: _gender,
        nativity: _nativity,
        bio: _bioController.text,
        photoUrl: _photoUrl,
      );
      widget.onComplete();
    } catch (e) {
      Get.snackbar(
        'Error',
        'Failed to save profile: $e',
        snackPosition: SnackPosition.BOTTOM,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Bold UI Helpers ──

  InputDecoration _flatInputDecoration(
    String label,
    String hint,
    IconData icon,
    ThemeData theme,
  ) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: 0.5,
      ),
      prefixIcon: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: theme.colorScheme.onSurface, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    );
  }

  Widget _buildFlatCard({required Widget child, required ThemeData theme}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
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
        title: Text(
          'Create Identity',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: theme.colorScheme.onSurface,
          ),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(),
                  Image.asset(
                    AppAssets.getAvatarPath(0),
                    width: 72,
                    height: 72,
                  ),
                  const SizedBox(height: 24),
                  CircularProgressIndicator(
                    color: theme.colorScheme.primary,
                    strokeWidth: 4,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Loading virtual closet...',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            )
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'This is how nearby devices will discover you.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 32),

                      _buildFlatCard(
                        theme: theme,
                        child: Column(
                          children: [
                            // ── Photo picker ──
                            GestureDetector(
                              onTap: _pickPhoto,
                              child: Obx(() {
                                final uploading =
                                    controller.isUploadingPhoto.value;
                                return Stack(
                                  alignment: Alignment.bottomRight,
                                  children: [
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: theme.colorScheme.onSurface,
                                          width: 3,
                                        ),
                                      ),
                                      child: CircleAvatar(
                                        radius: 56,
                                        backgroundColor: theme
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        backgroundImage: _photoUrl != null
                                            ? CachedNetworkImageProvider(
                                                _photoUrl!,
                                              )
                                            : null,
                                        child: _photoUrl == null && !uploading
                                            ? Icon(
                                                Icons.person,
                                                size: 48,
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              )
                                            : uploading
                                            ? const CircularProgressIndicator(
                                                strokeWidth: 2,
                                              )
                                            : null,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .primary, // Snapchat Yellow
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: theme.colorScheme.surface,
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.camera_alt,
                                        size: 20,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Tap to add photo',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                            const SizedBox(height: 32),

                            // ── Offline Avatar Picker ──
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Offline Radar Avatar',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              height: 90,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: AppAssets.maxAvatars,
                                itemBuilder: (context, index) {
                                  final isSelected = _avatarId == index;
                                  return GestureDetector(
                                    onTap: () =>
                                        setState(() => _avatarId = index),
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      margin: const EdgeInsets.only(right: 16),
                                      transform: Matrix4.diagonal3Values(
                                        isSelected ? 1.0 : 0.9,
                                        isSelected ? 1.0 : 0.9,
                                        1.0,
                                      ),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isSelected
                                              ? theme.colorScheme.primary
                                              : Colors.transparent,
                                          width: isSelected ? 4 : 0,
                                        ),
                                      ),
                                      child: CircleAvatar(
                                        radius: 36,
                                        backgroundImage: ResizeImage(
                                          AssetImage(
                                            AppAssets.getAvatarPath(index),
                                          ),
                                          width: 144,
                                          height: 144,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Bio Inputs ──
                      _buildFlatCard(
                        theme: theme,
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _usernameController,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLength: 10,
                              decoration: _flatInputDecoration(
                                'Offline Handle',
                                '@NightOwl',
                                Icons.alternate_email,
                                theme,
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty)
                                  return 'Required for offline discovery';
                                if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value))
                                  return 'Only letters, numbers, and underscores';
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _nameController,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLength: 30,
                              textCapitalization: TextCapitalization.words,
                              decoration: _flatInputDecoration(
                                'Display Name',
                                'How should people know you?',
                                Icons.badge_outlined,
                                theme,
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty)
                                  return 'Please enter a display name';
                                if (value.trim().length < 2)
                                  return 'Name must be at least 2 characters';
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _bioController,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLength: 100,
                              maxLines: 2,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: _flatInputDecoration(
                                'Bio (optional)',
                                'A short tagline about you',
                                Icons.info_outline,
                                theme,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Outfit Colors Inputs ──
                      _buildFlatCard(
                        theme: theme,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Outfit Colors',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    isExpanded: true,
                                    dropdownColor: theme.colorScheme.surface,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    initialValue: _topWearColor,
                                    decoration: _flatInputDecoration(
                                      'Top Color',
                                      '',
                                      Icons.checkroom,
                                      theme,
                                    ),
                                    items: _outfitColorItems,
                                    onChanged: (v) =>
                                        setState(() => _topWearColor = v ?? 0),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    isExpanded: true,
                                    dropdownColor: theme.colorScheme.surface,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    initialValue: _bottomWearColor,
                                    decoration: _flatInputDecoration(
                                      'Bottom Color',
                                      '',
                                      Icons.dry_cleaning,
                                      theme,
                                    ),
                                    items: _outfitColorItems,
                                    onChanged: (v) => setState(
                                      () => _bottomWearColor = v ?? 0,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),

                      // ── Vibe Inputs ──
                      _buildFlatCard(
                        theme: theme,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Your Vibe',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    isExpanded: true,
                                    dropdownColor: theme.colorScheme.surface,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    initialValue: _gender,
                                    decoration: _flatInputDecoration(
                                      'Field',
                                      '',
                                      Icons.category_rounded,
                                      theme,
                                    ),
                                    items: _fieldItems,
                                    onChanged: (v) {
                                      if (v != null) {
                                        setState(() {
                                          _gender = v;
                                          _nativity = 0;
                                        });
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    isExpanded: true,
                                    dropdownColor: theme.colorScheme.surface,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    key: ValueKey(
                                      'subfields_for_$_gender',
                                    ), // Force rebuild of dropdown when items change
                                    initialValue: _nativity,
                                    decoration: _flatInputDecoration(
                                      'Niche',
                                      '',
                                      Icons.tag_rounded,
                                      theme,
                                    ),
                                    items: _getSubfieldItems(_gender),
                                    onChanged: (v) {
                                      if (v != null)
                                        setState(() => _nativity = v);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 32),

                      // ── Submit button ──
                      SizedBox(
                        width: double.infinity,
                        height: 64,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                theme.colorScheme.primary, // Snapchat yellow!
                            foregroundColor:
                                Colors.black, // Dark text on yellow
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                          ),
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Save & Update Radar',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
