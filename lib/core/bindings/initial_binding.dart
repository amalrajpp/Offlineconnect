import 'package:get/get.dart';

import '../services/ble_service.dart';
import '../services/firebase_sync_service.dart';
import '../../features/connections/connections_controller.dart';
import '../../features/nearby/nearby_controller.dart';
import '../../features/profile/profile_controller.dart';
import '../services/device_compatibility_service.dart';

/// Registers remaining services and feature controllers with GetX DI.
///
/// Note: [IdentityService] and [LocalDbService] are registered in `main()`
/// before `runApp()` so they are fully initialised before any controller
/// tries to access them.
class InitialBinding extends Bindings {
  @override
  void dependencies() {
    // ── Services ──
    Get.put(BleService(), permanent: true);
    Get.put(DeviceCompatibilityService(), permanent: true);
    Get.put(FirebaseSyncService(), permanent: true);

    // ── Controllers ──
    Get.put(ProfileController(), permanent: true);
    Get.put(NearbyController());
    Get.put(ConnectionsController());
  }
}
