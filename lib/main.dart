import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:get/get.dart';

import 'core/bindings/initial_binding.dart';
import 'core/services/firebase_sync_service.dart';
import 'core/services/identity_service.dart';
import 'core/services/local_db_service.dart';
import 'features/chat/chats_screen.dart';
import 'features/connections/connections_screen.dart';
import 'features/nearby/nearby_screen.dart';
import 'features/profile/profile_controller.dart';
import 'features/profile/profile_setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise Firebase (requires platform-specific config files).
  try {
    await Firebase.initializeApp();
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

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  Future<void> _checkProfile() async {
    // Wait for ProfileController to finish loading.
    final profileCtrl = Get.find<ProfileController>();

    // Give the controller a moment to load from DB.
    await Future.delayed(const Duration(milliseconds: 300));

    final hasProfile = profileCtrl.isProfileSetUp;

    if (mounted) {
      setState(() {
        _needsProfile = !hasProfile;
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

    return const _HomeShell();
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

  final List<Widget> _screens = [
    const NearbyScreen(key: ValueKey('tab-nearby')),
    const ConnectionsScreen(key: ValueKey('tab-connections')),
    const ChatsScreen(key: ValueKey('tab-chats')),
    ProfileSetupScreen(
      key: const ValueKey('tab-profile'),
      onComplete: () {
        Get.snackbar(
          'Profile Saved',
          'Your identity has been updated locally.',
          snackPosition: SnackPosition.BOTTOM,
        );
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _screens),
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
