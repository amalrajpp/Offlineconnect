import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:get/get.dart';

import 'core/bindings/initial_binding.dart';
import 'core/services/firebase_sync_service.dart';
import 'core/services/identity_service.dart';
import 'core/services/local_db_service.dart';
import 'features/chat/chats_screen.dart';
import 'features/connections/connections_screen.dart';
import 'features/nearby/nearby_screen.dart';
import 'features/nearby/nearby_controller.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise Firebase (requires platform-specific config files).
  try {
    await Firebase.initializeApp();

    // Secure backend from unauthorized access using App Check
    await FirebaseAppCheck.instance.activate(
      // Play Integrity is the recommended provider for Android
      androidProvider: AndroidProvider.playIntegrity,
      // DeviceCheck is the recommended provider for iOS
      appleProvider: AppleProvider.deviceCheck,
    );
  } catch (e) {
    debugPrint('Firebase init skipped (no config found): $e');
  }

  // Pre-load the offline identity.
  final identityService = IdentityService();
  await identityService.loadOrCreateIdentity();
  Get.put(identityService, permanent: true);

  // Pre-warm the database.
  final localDbService = LocalDbService();
  await localDbService.ensureInitialised();
  Get.put(localDbService, permanent: true);

  runApp(const OfflineConnectApp());
}

/// Root application widget.
class OfflineConnectApp extends StatelessWidget {
  const OfflineConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Offline Connect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFFFCC00), // Warmer Yellow
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFAFAFA), // Off-white modern
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFFFFFFFF),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0x0A000000), width: 1),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          backgroundColor: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shadowColor: const Color(0x1A000000),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFFFCC00), // Warmer Yellow
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212), // Premium Dark
        cardTheme: CardThemeData(
          color: const Color(0xFF1E1E1E),
          elevation: 0,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0x1AFFFFFF), width: 1),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          backgroundColor: const Color(0xFF1E1E1E),
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shadowColor: const Color(0x33000000),
        ),
      ),
      themeMode: ThemeMode.system,
      initialBinding: InitialBinding(),
      home: const _AppGate(),
    );
  }
}

/// Gates the app: shows profile setup if no display name is set,
/// otherwise shows the main home shell.
///
/// Also triggers Firebase anonymous auth and connection sync
/// in the background when connectivity is available.
class _AppGate extends StatefulWidget {
  const _AppGate();

  @override
  State<_AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<_AppGate> {
  bool _ready = false;
  bool _needsProfile = true;
  bool _needsWardrobeCheck = false;

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  Future<void> _checkProfile() async {
    // Wait for ProfileController to finish loading.
    final profileCtrl = Get.find<ProfileController>();
    final identitySvc = Get.find<IdentityService>();

    // Give the controller a moment to load from DB.
    await Future.delayed(const Duration(milliseconds: 300));

    final hasProfile = profileCtrl.isProfileSetUp;
    final needsWardrobe = hasProfile && await identitySvc.needsWardrobeCheck();

    if (mounted) {
      setState(() {
        _needsProfile = !hasProfile;
        _needsWardrobeCheck = needsWardrobe;
        _ready = true;
      });
    }

    // Trigger Firebase auth + sync in background.
    _backgroundSync();
  }

  Future<void> _backgroundSync() async {
    try {
      final firebase = Get.find<FirebaseSyncService>();
      final identity = Get.find<IdentityService>().identity;

      if (firebase.isFirebaseAvailable) {
        await firebase.signInAnonymously(identity);

        // Sync profile if set.
        final profileCtrl = Get.find<ProfileController>();
        if (profileCtrl.isProfileSetUp) {
          await profileCtrl.syncToCloud();
        }

        // Sync accepted connections.
        final db = Get.find<LocalDbService>();
        final connections = await db.getConnections();
        await firebase.syncConnections(identity.offlineId, connections);

        // Update online heartbeat.
        await firebase.updateLastOnline(identity.offlineId);
      }
    } catch (e) {
      debugPrint('Background sync failed (non-critical): $e');
    }
  }

  void _onProfileComplete() {
    setState(() => _needsProfile = false);
    _backgroundSync(); // Sync the newly created profile.
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_needsProfile) {
      return ProfileSetupScreen(onComplete: _onProfileComplete);
    }

    if (_needsWardrobeCheck) {
      // Force wardrobe check inline, acting like an overlay
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showWardrobeCheck(context);
        setState(() {
          _needsWardrobeCheck = false; // Prevents infinite loop
        });
      });
    }

    return const _HomeShell();
  }

  void _showWardrobeCheck(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => const _WardrobeCheckSheet(),
    );
  }
}

class _WardrobeCheckSheet extends StatefulWidget {
  const _WardrobeCheckSheet();

  @override
  State<_WardrobeCheckSheet> createState() => _WardrobeCheckSheetState();
}

class _WardrobeCheckSheetState extends State<_WardrobeCheckSheet> {
  int topWearColor = 0;
  int bottomWearColor = 0;

  @override
  void initState() {
    super.initState();
    final identity = Get.find<IdentityService>().identity;
    topWearColor = identity.topWearColor;
    bottomWearColor = identity.bottomWearColor;
  }

  Future<void> _confirm() async {
    final identityService = Get.find<IdentityService>();
    final identity = identityService.identity;

    // Set traits updates SecureStorage and calls confirmWardrobe()
    await identityService.setTraits(
      avatarId: identity.avatarId,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      gender: identity.gender,
      nativity: identity.nativity,
    );

    // Refresh Broadcast to broadcast new colors instantly
    if (Get.isRegistered<NearbyController>()) {
      Get.find<NearbyController>().refreshBroadcast();
    }

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 24,
        right: 24,
        top: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.checkroom, size: 48, color: Colors.orange),
          const SizedBox(height: 16),
          Text(
            'Daily Wardrobe Check',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Are you still wearing the same colors today? Keep your digital radar proxy accurate.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          // We can replace these raw sliders with Swatch pickers from ProfileSetupScreen later
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _ColorSelector(
                label: 'Top',
                value: topWearColor,
                onChanged: (v) => setState(() => topWearColor = v),
              ),
              _ColorSelector(
                label: 'Bottom',
                value: bottomWearColor,
                onChanged: (v) => setState(() => bottomWearColor = v),
              ),
            ],
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: _confirm,
              child: const Text('Confirm Identity'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ColorSelector extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _ColorSelector({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  // A simulated list of common vibrant colors mimicking the physical palette (0-15 limits)
  static const List<Color> palette = [
    Colors.black,
    Colors.white,
    Colors.grey,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.amber,
    Colors.purple,
    Colors.orange,
    Colors.pink,
    Colors.teal,
    Colors.cyan,
    Colors.brown,
    Colors.indigo,
    Colors.lime,
    Colors.deepPurple,
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () {
            // Cycle through colors
            onChanged((value + 1) % 16);
          },
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: palette[value % 16],
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade300, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: value == 0
                ? const Icon(Icons.touch_app, color: Colors.white54)
                : null,
          ),
        ),
      ],
    );
  }
}

/// Shell widget with a [NavigationBar] toggling between Nearby and Connections.
class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _selectedIndex = 0;

  // We only build the screens once they are visited to prevent
  // background lag on startup (due to animations/image loading).
  final List<Widget?> _screens = [null, null, null, null];

  Widget _getScreen(int index) {
    // If the index isn't the active one and hasn't been visited, return a dummy placeholder.
    if (_selectedIndex != index && _screens[index] == null) {
      return const SizedBox.shrink();
    }

    if (_screens[index] != null) return _screens[index]!;

    switch (index) {
      case 0:
        _screens[0] = const NearbyScreen(key: ValueKey('tab-nearby'));
        break;
      case 1:
        _screens[1] = const ConnectionsScreen(key: ValueKey('tab-connections'));
        break;
      case 2:
        _screens[2] = const ChatsScreen(key: ValueKey('tab-chats'));
        break;
      case 3:
        _screens[3] = ProfileSetupScreen(
          key: const ValueKey('tab-profile'),
          onComplete: () {
            Get.snackbar(
              'Profile Saved',
              'Your identity has been updated locally.',
              snackPosition: SnackPosition.BOTTOM,
            );
          },
        );
        break;
    }
    return _screens[index]!;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: List.generate(4, (i) => _getScreen(i)),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
            selectedIcon: Icon(Icons.bluetooth_connected),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Connections',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
