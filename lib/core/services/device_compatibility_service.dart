import 'dart:io';

import 'package:get/get.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Checks whether the current device supports features the app relies on.
class DeviceCompatibilityService extends GetxService {
  /// Minimum supported Android SDK (based on plugin support).
  static const int minSupportedSdk = 21; // Android 5.0 Lollipop

  Future<bool> hasBleSupport() async {
    try {
      // Use the static API to check availability.
      final supported = await FlutterBluePlus.isAvailable;
      return supported;
    } catch (e) {
      return false;
    }
  }

  Future<bool> isAndroidSupported() async {
    if (!Platform.isAndroid) return true;
    final info = DeviceInfoPlugin();
    final android = await info.androidInfo;
    final sdk = android.version.sdkInt;
    return (sdk ?? 0) >= minSupportedSdk;
  }

  /// Returns a human-friendly explanation when compatibility is missing.
  Future<String?> incompatibilityReason() async {
    final osOk = await isAndroidSupported();
    if (!osOk) return 'This device is running an unsupported Android version.';
    final ble = await hasBleSupport();
    if (!ble)
      return 'This device does not support Bluetooth Low Energy (BLE). Some features will be disabled.';
    return null;
  }
}
