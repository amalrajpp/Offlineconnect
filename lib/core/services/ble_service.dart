import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_models.dart';
import '../models/offline_identity.dart';

/// The Zero-GATT Connectionless Handshake Engine.
///
/// Devices communicate purely through BLE **advertisement manufacturer data**.
/// No GATT connections are ever opened.
///
/// ### Manufacturer Data Layout (14 bytes, ID 0xFFFF)
/// | Byte | Content                                              |
/// |------|------------------------------------------------------|
/// | 0    | Protocol version (`0x01`)                            |
/// | 1    | Intent index (`BleIntent.index`)                     |
/// | 2–7  | Sender hash (first 6 bytes of offline ID, hex→bytes) |
/// | 8–13 | Target hash (6 bytes) or `0x000000000000` if presence|
///
/// **Advertising** is handled via a platform channel to native code
/// (`BluetoothLeAdvertiser` on Android, `CBPeripheralManager` on iOS).
/// On platforms that do not support peripheral advertising the call is
/// silently ignored and the app continues in scan-only (listen) mode.
class BleService extends GetxService {
  // ── Constants ───────────────────────────────────────────────────────────
  static const int _manufacturerId = 0xFFFF;
  static const int _protocolVersion = 0x01;
  static const int _payloadLength = 27;

  /// Platform channel for native BLE advertising (peripheral mode).
  static const MethodChannel _advertChannel = MethodChannel(
    'com.offlineconnect/ble_advertiser',
  );

  // ── Streams ─────────────────────────────────────────────────────────────
  final StreamController<DiscoveredPeer> _peerController =
      StreamController<DiscoveredPeer>.broadcast();

  /// A broadcast stream of discovered peers parsed from advertisements.
  Stream<DiscoveredPeer> get discoveredPeers => _peerController.stream;

  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // ── Adapter & Permissions (Fix #2 & #14) ────────────────────────────────

  /// Returns `true` if the Bluetooth adapter is currently on.
  ///
  /// If the adapter is off, attempts to prompt the user to turn it on
  /// (Android only — iOS requires the user to toggle it in Settings).
  Future<bool> ensureAdapterOn() async {
    try {
      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              return BluetoothAdapterState.unknown;
            },
          );

      if (state == BluetoothAdapterState.on) return true;

      if (state == BluetoothAdapterState.unknown) {
        // Emulator or device without BLE — can't proceed.
        Get.log('BleService: adapter state unknown (emulator or no BLE).');
        return false;
      }

      // Adapter is off — try to turn it on (Android only).
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        // turnOn() throws on iOS or if denied.
        return false;
      }

      // Wait up to 5 seconds for adapter to come on.
      await for (final s in FlutterBluePlus.adapterState.timeout(
        const Duration(seconds: 5),
      )) {
        if (s == BluetoothAdapterState.on) return true;
      }
      return false;
    } on TimeoutException {
      return false;
    } catch (e) {
      Get.log('BleService: ensureAdapterOn failed – $e');
      return false;
    }
  }

  /// Requests the runtime BLE permissions needed on Android 12+ and iOS.
  ///
  /// Uses `flutter_blue_plus`'s built-in permission handling which
  /// internally calls the platform's permission APIs.
  Future<bool> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        // Android 12+ requires explicit BLE permissions
        final scan = await Permission.bluetoothScan.request();
        final connect = await Permission.bluetoothConnect.request();
        final advertise = await Permission.bluetoothAdvertise.request();

        if (!scan.isGranted || !connect.isGranted || !advertise.isGranted) {
          return false;
        }

        // Location is needed for BLE scanning on older Androids
        final location = await Permission.locationWhenInUse.request();
        if (!location.isGranted) return false;

        // On many Android devices, BLE discovery also requires
        // Location services (device-level toggle) to be enabled.
        final locationService =
            await Permission.locationWhenInUse.serviceStatus;
        if (!locationService.isEnabled) {
          Get.log('BleService: location services are disabled.');
          return false;
        }
      } else if (Platform.isIOS) {
        final ble = await Permission.bluetooth.request();
        if (!ble.isGranted) return false;
      }

      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              return BluetoothAdapterState.unknown;
            },
          );
      return state == BluetoothAdapterState.on;
    } catch (e) {
      Get.log('BleService: requestPermissions failed – $e');
      return false;
    }
  }

  /// Returns whether Android device-level Location services are enabled.
  ///
  /// For non-Android platforms this returns `true`.
  Future<bool> isLocationServiceEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.locationWhenInUse.serviceStatus;
      return status.isEnabled;
    } catch (e) {
      Get.log('BleService: failed to read location service status – $e');
      return false;
    }
  }

  /// Opens app settings as a fallback route to enable location-related access.
  Future<void> openDeviceLocationSettings() async {
    try {
      if (Platform.isAndroid) {
        await _advertChannel.invokeMethod('openLocationSettings');
      } else {
        await openAppSettings();
      }
    } catch (e) {
      Get.log('BleService: failed to open location settings – $e');
      try {
        await openAppSettings();
      } catch (_) {}
    }
  }

  // ── Advertising ─────────────────────────────────────────────────────────

  /// Starts broadcasting the given [intent] with this device's [myHash].
  ///
  /// If [intent] requires a target (request / accept), [targetHash] must be
  /// provided. For [BleIntent.presence] it is ignored and zero-filled.
  ///
  /// Advertising requires platform-specific native code. If the platform
  /// channel is not available the call is silently ignored, and the app
  /// works in passive (scan-only) mode.
  Future<void> broadcastState(
    OfflineIdentity identity,
    BleIntent intent, {
    String? targetHash,
  }) async {
    try {
      final payload = _buildPayload(identity, intent, targetHash);

      await _advertChannel.invokeMethod('startAdvertising', {
        'manufacturerId': _manufacturerId,
        'payload': payload,
      });
    } on MissingPluginException {
      // Platform channel not implemented – running in scan-only mode.
      Get.log(
        'BleService: advertising not available on this platform '
        '(MissingPluginException). Running in scan-only mode.',
      );
    } catch (e) {
      Get.log('BleService: advertising failed – $e');
    }
  }

  /// Stops the current BLE advertisement.
  Future<void> stopBroadcasting() async {
    try {
      await _advertChannel.invokeMethod('stopAdvertising');
    } on MissingPluginException {
      // Silently ignore.
    } catch (_) {}
  }

  // ── Scanning ────────────────────────────────────────────────────────────

  /// Begins a continuous BLE scan. Discovered peers that match our protocol
  /// are emitted on [discoveredPeers].
  ///
  /// Set [skipPermissionCheck] to `true` when the caller has already
  /// confirmed permissions to avoid a redundant OS round-trip.
  ///
  /// ### Android iOS cross-detection strategy
  /// iOS devices advertise via CBPeripheralManager with Service UUIDs.
  /// Android detects them via the `serviceUuids` field in the scan result.
  /// Our protocol encodes the identity into a 128-bit UUID starting with
  /// `0C0C` (see [_parseScanResult]).
  Future<bool> startScanning({bool skipPermissionCheck = false}) async {
    try {
      if (!skipPermissionCheck) {
        final hasPerms = await requestPermissions();
        if (!hasPerms) {
          Get.log('BleService: Cannot scan without permissions.');
          return false;
        }
      }

      // Only stop if a scan is currently running (avoid wasting Android's
      // 5-starts-per-30s budget).
      if (FlutterBluePlus.isScanningNow) {
        Get.log('BleService: Stopping existing scan before restart.');
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
        // Brief pause lets the BLE stack settle.
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Cancel and re-create the Dart-side subscription.
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      // Subscribe to scan results BEFORE starting scan to catch the first burst.
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        Get.log('BLE_SCAN: onScanResults batch: ${results.length} result(s).');
        for (final result in results) {
          final peer = _parseScanResult(result);
          if (peer != null) {
            Get.log('BLE_SCAN: ✅ Parsed peer ${peer.myHash}');
            _peerController.add(peer);
          }
        }
      });

      // Begin continuous scan — no service filter so we see all devices
      // and selectively parse our protocol from manufacturer data (Android)
      // or service UUIDs (iOS).
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        androidUsesFineLocation: true,
      );

      final started = FlutterBluePlus.isScanningNow;
      Get.log('BleService: ✅ Scan start attempted. isScanningNow=$started');
      return started;
    } catch (e) {
      Get.log('BleService: ❌ scanning failed – $e');
      return false;
    }
  }

  /// Stops the BLE scan.
  Future<void> stopScanning() async {
    try {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  // ── Internal helpers ────────────────────────────────────────────────────

  /// Builds the 27-byte manufacturer data payload.
  Uint8List _buildPayload(
    OfflineIdentity identity,
    BleIntent intent,
    String? targetHash,
  ) {
    final data = Uint8List(_payloadLength);

    // Byte 0 – protocol version
    data[0] = _protocolVersion;

    // Byte 1 – intent
    data[1] = intent.index;

    // Bytes 2-7 – sender hash (6 bytes from 12-char hex string)
    final myBytes = _hexToBytes(identity.bleHash);
    for (var i = 0; i < 6; i++) {
      data[2 + i] = i < myBytes.length ? myBytes[i] : 0;
    }

    // Bytes 8-13 – target hash or zeros
    if (intent != BleIntent.presence && targetHash != null) {
      final targetBytes = _hexToBytes(targetHash);
      for (var i = 0; i < 6; i++) {
        data[8 + i] = i < targetBytes.length ? targetBytes[i] : 0;
      }
    }

    // Byte 14 - Avatar ID
    data[14] = identity.avatarId & 0xFF;

    // Byte 15 - Outfit Colors (4 bits each)
    data[15] =
        ((identity.topWearColor & 0x0F) << 4) |
        (identity.bottomWearColor & 0x0F);

    // Byte 16 - Bio Bitfield (Field | Subfield)
    data[16] = ((identity.gender & 0x0F) << 4) | (identity.nativity & 0x0F);

    // Bytes 17-26 – sender username
    final nameBytes = utf8.encode(identity.username);
    for (var i = 0; i < 10; i++) {
      data[17 + i] = i < nameBytes.length ? nameBytes[i] : 0;
    }

    // iOS uses a compact 16-byte UUID encoding to bypass ManufacturerData limits and Android LocalName caching.
    if (Platform.isIOS) {
      final iosData = Uint8List(16);
      iosData[0] = 0x0C; // Magic Byte 1
      iosData[1] = 0x0C; // Magic Byte 2
      iosData[2] = ((_protocolVersion & 0x0F) << 4) | (intent.index & 0x0F);
      iosData[3] = identity.avatarId & 0xFF;
      iosData[4] =
          ((identity.topWearColor & 0x0F) << 4) |
          (identity.bottomWearColor & 0x0F);
      iosData[5] =
          ((identity.gender & 0x0F) << 4) | (identity.nativity & 0x0F);
      for (var i = 0; i < 5; i++) {
        iosData[6 + i] = i < myBytes.length ? myBytes[i] : 0;
      }
      if (intent != BleIntent.presence && targetHash != null) {
        final targetBytes = _hexToBytes(targetHash);
        for (var i = 0; i < 5; i++) {
          iosData[11 + i] = i < targetBytes.length ? targetBytes[i] : 0;
        }
      }
      return iosData;
    }

    return data;
  }

  /// Attempts to parse a [ScanResult] into a [DiscoveredPeer].
  ///
  /// Returns `null` if the advertisement does not contain our protocol data.
  DiscoveredPeer? _parseScanResult(ScanResult result) {
    List<int>? raw;

    // ── Comprehensive debug logging (every device) ───────────────────────
    // Log ALL devices so we can verify the scan is working and inspect
    // what the iOS advertisement actually looks like on Android.
    if (Platform.isAndroid) {
      final id = result.device.remoteId.str;
      final name = result.advertisementData.advName;
      final svcs = result.advertisementData.serviceUuids;
      final mfg = result.advertisementData.manufacturerData.keys.toList();
      final rssi = result.rssi;
      Get.log(
        'BLE_RAW [$id] rssi=$rssi name="$name" '
        'mfgIds=$mfg svcs=${svcs.map((u) => u.str).toList()}',
      );
    }

    // ── Android: manufacturer data (0xFFFF) ──────────────────────────────
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.containsKey(_manufacturerId)) {
      raw = mfgData[_manufacturerId];
    }

    // ── iOS peripheral: UUID encoding ────────────────────────────────────
    // iOS CBPeripheralManager advertises our 16-byte payload as a 128-bit
    // service UUID. The UUID starts with bytes 0x0C, 0x0C → hex "0c0c...".
    if (raw == null) {
      final allUuids = result.advertisementData.serviceUuids;
      var sawProtocolCandidate = false;
      for (final uuidPattern in allUuids) {
        final uuidStr = uuidPattern.str.replaceAll('-', '').toLowerCase();
        Get.log(
          'BLE_UUID_CHECK: "${uuidPattern.str}" -> stripped="$uuidStr" len=${uuidStr.length}',
        );
        if (uuidStr.startsWith('0c0c')) {
          sawProtocolCandidate = true;
        }
        if (uuidStr.startsWith('0c0c') && uuidStr.length == 32) {
          raw = _hexToBytes(uuidStr);
          Get.log(
            'BLE_DEBUG: ✅ Found iOS UUID: $uuidStr -> ${raw.length} bytes',
          );
          break;
        }
      }
      if (raw == null && allUuids.isNotEmpty) {
        if (sawProtocolCandidate) {
          Get.log(
            'BLE_DEBUG: ⚠️ Found 0c0c-like UUID(s), but payload length/format was invalid.',
          );
        } else {
          Get.log(
            'BLE_DEBUG: ℹ️ Skipping non-protocol UUID(s): ${allUuids.map((u) => u.str).toList()}',
          );
        }
      }
    }

    // Minimum viable payload: 16 bytes (iOS UUID) or 27 bytes (Android full).
    if (raw == null) return null;
    if (raw.length < 16) {
      debugPrint('BLE_DEBUG: Dropping because too short: ${raw.length}');
      return null;
    }

    int intentIndex;
    String myHash;
    List<int> targetBytes;
    int avatarId;
    int topWearColor;
    int bottomWearColor;
    int bioBits;

    // Standard payload decoding (Android)
    if (raw.length >= 27) {
      if (raw[0] != _protocolVersion) return null;
      intentIndex = raw[1];
      myHash = _bytesToHex(raw.sublist(2, 8));
      targetBytes = raw.sublist(8, 14);
      avatarId = raw[14];
      topWearColor = (raw[15] >> 4) & 0x0F;
      bottomWearColor = raw[15] & 0x0F;
      bioBits = raw[16];
    } else if (raw.length == 16 && raw[0] == 0x0C && raw[1] == 0x0C) {
      // iOS UUID encoding payload decoding
      final version = (raw[2] >> 4) & 0x0F;
      if (version != _protocolVersion) return null;
      intentIndex = raw[2] & 0x0F;
      avatarId = raw[3];
      topWearColor = (raw[4] >> 4) & 0x0F;
      bottomWearColor = raw[4] & 0x0F;
      bioBits = raw[5];
      // Pad out the 5-byte hashes to 6 bytes for the app to treat them equally
      final senderHashBytes = raw.sublist(6, 11).toList()..add(0);
      myHash = _bytesToHex(senderHashBytes);
      targetBytes = raw.sublist(11, 16).toList()..add(0);
      debugPrint(
        'BLE_DEBUG: iOS UUID successfully decoded! myHash=$myHash, target=${_bytesToHex(targetBytes)}',
      );
    } else {
      debugPrint(
        'BLE_DEBUG: Dropping because unknown format! length=${raw.length}, byte0=${raw[0]}, byte1=${raw[1]}',
      );
      return null;
    }

    if (intentIndex >= BleIntent.values.length) {
      debugPrint('BLE_DEBUG: Dropping because intent invalid: $intentIndex');
      return null;
    }
    final intent = BleIntent.values[intentIndex];
    final hasTarget = targetBytes.any((b) => b != 0);
    final targetHash = hasTarget ? _bytesToHex(targetBytes) : null;

    final gender = (bioBits >> 4) & 0x0F;
    final nativity = bioBits & 0x0F;

    String? offlineUsername;
    if (raw.length >= 27) {
      final nameBytes = raw.sublist(17, 27);
      final cleanNameBytes = nameBytes.where((b) => b != 0).toList();
      offlineUsername = cleanNameBytes.isNotEmpty
          ? utf8.decode(cleanNameBytes, allowMalformed: true)
          : null;
    }

    return DiscoveredPeer(
      deviceId: result.device.remoteId.str,
      myHash: myHash,
      targetHash: targetHash,
      offlineUsername: offlineUsername,
      avatarId: avatarId,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      gender: gender,
      nativity: nativity,
      intent: intent,
      rssi: result.rssi,
      lastSeen: DateTime.now(),
    );
  }

  /// Converts a hex string to a list of bytes.
  List<int> _hexToBytes(String hex) {
    final clean = hex.replaceAll(' ', '');
    final result = <int>[];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      result.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  /// Converts bytes to a lowercase hex string.
  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void onClose() {
    _scanSubscription?.cancel();
    _peerController.close();
    super.onClose();
  }
}
