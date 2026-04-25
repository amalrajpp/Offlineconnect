import "../utils/hash_engine.dart";
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../models/avatar_dna.dart';
import '../models/ble_models.dart';
import '../models/offline_identity.dart';
import 'identity_service.dart';

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
    'com.redstring/ble_advertiser',
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
        final androidInfo = await DeviceInfoPlugin().androidInfo;

        if (androidInfo.version.sdkInt >= 31) {
          // Android 12+: Only need Bluetooth (Nearby Devices) permissions
          final scan = await Permission.bluetoothScan.request();
          final connect = await Permission.bluetoothConnect.request();
          final advertise = await Permission.bluetoothAdvertise.request();

          if (!scan.isGranted || !connect.isGranted || !advertise.isGranted) {
            return false;
          }
        } else {
          // Android 11 and below: Need Location + legacy Bluetooth
          final location = await Permission.location.request();
          final ble = await Permission.bluetooth.request();
          if (!location.isGranted || !ble.isGranted) {
            return false;
          }

          // On older Androids, Location services (device-level toggle) must be enabled
          final locationService = await Permission.location.serviceStatus;
          if (!locationService.isEnabled) {
            Get.log('BleService: location services are disabled.');
            return false;
          }
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
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 31) {
        return true; // Modern Android does not require device-level location for BLE
      }
      final status = await Permission.location.serviceStatus;
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

  // ── Blink Protocol (Adaptive Hz Connection Pipeline) ────────────────────

  /// Generates the 3-byte command payload for handshakes.
  Uint8List packBlinkPayload({
    required String myOfflineId,
    required String targetOfflineId,
    required bool isAccepting,
  }) {
    final buffer = ByteData(3);

    // Byte 0: The Command Flag (0xFF = Request, 0xEE = Accept)
    buffer.setUint8(0, isAccepting ? 0xEE : 0xFF);

    // Byte 1: Sender ID (first byte of hash)
    buffer.setUint8(1, _hexToBytes(myOfflineId).first);

    // Byte 2: Target ID (first byte of their hash)
    buffer.setUint8(2, _hexToBytes(targetOfflineId).first);

    return buffer.buffer.asUint8List();
  }

  /// Hijacks the passive 1Hz visual broadcast and fires a 10Hz Blink Payload
  /// for 3 seconds to guarantee a handshake reaches the target in crowded rooms.
  Future<void> executeBlinkHandshake(
    OfflineIdentity identity,
    String targetId,
    bool isAccepting,
  ) async {
    // 1. Stop the passive 1Hz visual broadcast
    await stopBroadcasting();

    // 2. Generate the Command Payload
    final blinkPayload = packBlinkPayload(
      myOfflineId: identity.offlineId,
      targetOfflineId: targetId,
      isAccepting: isAccepting,
    );

    // 3. Start Aggressive Advertising (Low Latency / 10Hz)
    try {
      await _advertChannel.invokeMethod('startAdvertisingRaw', {
        'manufacturerId': _manufacturerId,
        'payload': blinkPayload,
        'lowLatency': true, // Adaptive Hz boost
      });
    } on MissingPluginException {
      await _advertChannel.invokeMethod('startAdvertising', {
        'manufacturerId': _manufacturerId,
        'payload': blinkPayload,
      });
    } catch (e) {
      Get.log('BleService: executeBlinkHandshake failed to start - $e');
    }

    // 4. Hold the Blink for exactly 3 seconds
    await Future.delayed(const Duration(seconds: 3));

    // 5. Tear down the aggressive broadcast and return to normal presence
    await stopBroadcasting();
    await broadcastState(identity, BleIntent.presence);
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
        if (kDebugMode) {
          Get.log(
            'BLE_SCAN: onScanResults batch: ${results.length} result(s).',
          );
        }
        for (final result in results) {
          final peer = _parseScanResult(result);
          if (peer != null) {
            if (kDebugMode) {
              Get.log('BLE_SCAN: ✅ Parsed peer ${peer.myHash}');
            }
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

  @visibleForTesting
  Uint8List buildPayloadTest(
    OfflineIdentity identity,
    BleIntent intent,
    String? targetHash,
  ) {
    return _buildPayload(identity, intent, targetHash);
  }

  /// Builds the 27-byte manufacturer data payload.
  Uint8List _buildPayload(
    OfflineIdentity identity,
    BleIntent intent,
    String? targetHash,
  ) {
    int senderHash = HashEngine.generate4ByteHash(identity.offlineId);

    int tHash = 0;
    if (intent != BleIntent.presence && targetHash != null) {
      if (targetHash.length == 8) {
        // If it's already a 4-byte hash (8 hex chars), parse it
        tHash = int.parse(targetHash, radix: 16);
      } else {
        // Otherwise hash it
        tHash = HashEngine.generate4ByteHash(targetHash);
      }
    }

    final outfitColorByte =
        ((identity.topWearColor & 0x0F) << 4) |
        (identity.bottomWearColor & 0x0F);

    final data = Uint8List(_payloadLength);

    // Byte 0 – protocol version
    data[0] = _protocolVersion;

    // Byte 1 – intent
    data[1] = intent.index;

    // Bytes 2-5 – sender hash
    data[2] = (senderHash >> 24) & 0xFF;
    data[3] = (senderHash >> 16) & 0xFF;
    data[4] = (senderHash >> 8) & 0xFF;
    data[5] = senderHash & 0xFF;

    // Bytes 6-9 – target hash
    data[6] = (tHash >> 24) & 0xFF;
    data[7] = (tHash >> 16) & 0xFF;
    data[8] = (tHash >> 8) & 0xFF;
    data[9] = tHash & 0xFF;

    // Bytes 10-13 - Avatar DNA
    data[10] = (identity.avatarDna >> 24) & 0xFF;
    data[11] = (identity.avatarDna >> 16) & 0xFF;
    data[12] = (identity.avatarDna >> 8) & 0xFF;
    data[13] = identity.avatarDna & 0xFF;

    // Byte 14 - Outfit Colors (4 bits top, 4 bits bottom)
    data[14] = outfitColorByte;

    // Bytes 15-26 – sender username
    final nameBytes = utf8.encode(identity.username);
    for (var i = 0; i < 12; i++) {
      data[15 + i] = i < nameBytes.length ? nameBytes[i] : 0;
    }

    // iOS uses a compact 16-byte UUID encoding to bypass ManufacturerData limits and Android LocalName caching.
    if (Platform.isIOS) {
      final iosData = Uint8List(16);
      iosData[0] = 0x0C; // Magic Byte 1
      iosData[1] = 0x0C; // Magic Byte 2
      iosData[2] = ((_protocolVersion & 0x0F) << 4) | (intent.index & 0x0F);

      iosData[3] = (identity.avatarDna >> 24) & 0xFF;
      iosData[4] = (identity.avatarDna >> 16) & 0xFF;
      iosData[5] = (identity.avatarDna >> 8) & 0xFF;
      iosData[6] = identity.avatarDna & 0xFF;

      iosData[7] = outfitColorByte;

      iosData[8] = (senderHash >> 24) & 0xFF;
      iosData[9] = (senderHash >> 16) & 0xFF;
      iosData[10] = (senderHash >> 8) & 0xFF;
      iosData[11] = senderHash & 0xFF;

      iosData[12] = (tHash >> 24) & 0xFF;
      iosData[13] = (tHash >> 16) & 0xFF;
      iosData[14] = (tHash >> 8) & 0xFF;
      iosData[15] = tHash & 0xFF;

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
    if (kDebugMode && Platform.isAndroid) {
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
        if (kDebugMode) {
          Get.log(
            'BLE_UUID_CHECK: "${uuidPattern.str}" -> stripped="$uuidStr" len=${uuidStr.length}',
          );
        }
        if (uuidStr.startsWith('0c0c')) {
          sawProtocolCandidate = true;
        }
        if (uuidStr.startsWith('0c0c') && uuidStr.length == 32) {
          raw = _hexToBytes(uuidStr);
          if (kDebugMode) {
            Get.log(
              'BLE_DEBUG: ✅ Found iOS UUID: $uuidStr -> ${raw.length} bytes',
            );
          }
          break;
        }
      }
      if (raw == null && allUuids.isNotEmpty && kDebugMode) {
        if (sawProtocolCandidate) {
          Get.log(
            'BLE_DEBUG: ⚠️ Found 0c0c-like UUID(s), but payload length/format was invalid.',
          );
        }
      }
    }

    // Minimum viable payload: 3 bytes (Blink), 16 bytes (iOS UUID), or 27 bytes (Android full).
    if (raw == null || raw.length < 3) return null;

    // ── The Scanner Intercept (The Shield) ───────────────────────────────
    // Intercept 3-byte command packets before they crash the visual parser
    if (raw[0] == 0xFF || raw[0] == 0xEE) {
      if (raw.length >= 3) {
        int myFirstByte = _hexToBytes(
          Get.find<IdentityService>().identity.offlineId,
        ).first;
        if (raw[2] == myFirstByte) {
          // It's targeted at me! Format it as a blink request
          final intent = raw[0] == 0xFF
              ? BleIntent.requestConnection
              : BleIntent.acceptConnection;
          // The blink sender hash will just be a 1-byte proxy. Our app matches
          // to known users by this proxy prefix if not exact.
          final senderProxyHash = _bytesToHex([raw[1]]);

          // Note: We bypass normal avatar/bio rendering.
          return DiscoveredPeer(
            deviceId: result.device.remoteId.str,
            myHash:
                senderProxyHash, // This will be matched to the full 6-byte hash locally in NearbyController
            targetHash: Get.find<IdentityService>().identity.offlineId,
            offlineUsername: null,
            avatarDna: 0,
            topWearColor: 0,
            bottomWearColor: 0,
            intent: intent,
            rssi: result.rssi,
            lastSeen: result.timeStamp,
          );
        }
      }
      return null;
    }

    if (raw.length < 16) {
      debugPrint('BLE_DEBUG: Dropping because too short: ${raw.length}');
      return null;
    }

    int intentIndex;
    String myHash;
    List<int> targetBytes;
    int avatarDna = 0;
    int topWearColor = 0;
    int bottomWearColor = 0;
    String? targetHashStr;
    String? offlineUsername;

    // Standard payload decoding (Android)
    if (raw.length >= 27) {
      if (raw[0] != _protocolVersion) return null;
      intentIndex = raw[1];

      final senderInt =
          (raw[2] << 24) | (raw[3] << 16) | (raw[4] << 8) | raw[5];
      myHash = senderInt.toUnsigned(32).toRadixString(16).padLeft(8, '0');

      final targetInt =
          (raw[6] << 24) | (raw[7] << 16) | (raw[8] << 8) | raw[9];
      final targetHex = targetInt
          .toUnsigned(32)
          .toRadixString(16)
          .padLeft(8, '0');
      targetBytes = targetInt == 0
          ? [0, 0, 0, 0]
          : [255]; // Proxy to pass `any` check below

      avatarDna = (raw[10] << 24) | (raw[11] << 16) | (raw[12] << 8) | raw[13];
      avatarDna = avatarDna.toUnsigned(32);

      topWearColor = (raw[14] >> 4) & 0x0F;
      bottomWearColor = raw[14] & 0x0F;

      targetHashStr = targetHex;

      final nameBytes = raw.sublist(15, 27);
      final cleanNameBytes = nameBytes.where((b) => b != 0).toList();
      offlineUsername = cleanNameBytes.isNotEmpty
          ? utf8.decode(cleanNameBytes, allowMalformed: true)
          : null;
    } else if (raw.length == 16 && raw[0] == 0x0C && raw[1] == 0x0C) {
      // iOS UUID encoding payload decoding
      final version = (raw[2] >> 4) & 0x0F;
      if (version != _protocolVersion) return null;
      intentIndex = raw[2] & 0x0F;

      avatarDna = (raw[3] << 24) | (raw[4] << 16) | (raw[5] << 8) | raw[6];
      avatarDna = avatarDna.toUnsigned(32);

      topWearColor = (raw[7] >> 4) & 0x0F;
      bottomWearColor = raw[7] & 0x0F;

      final senderInt =
          (raw[8] << 24) | (raw[9] << 16) | (raw[10] << 8) | raw[11];
      myHash = senderInt.toUnsigned(32).toRadixString(16).padLeft(8, '0');

      final targetInt =
          (raw[12] << 24) | (raw[13] << 16) | (raw[14] << 8) | raw[15];
      final targetHex = targetInt
          .toUnsigned(32)
          .toRadixString(16)
          .padLeft(8, '0');
      targetBytes = targetInt == 0 ? [0, 0, 0, 0] : [255];
      targetHashStr = targetHex;
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
    final targetHash = hasTarget ? targetHashStr : null;

    final traits = AvatarDNA.unpack(avatarDna);
    final gender = traits['eyeShape'] ?? 0;
    final nativity = traits['noseShape'] ?? 0;

    return DiscoveredPeer(
      deviceId: result.device.remoteId.str,
      myHash: myHash,
      targetHash: targetHash,
      offlineUsername: offlineUsername,
      avatarDna: avatarDna,
      topWearColor: topWearColor,
      bottomWearColor: bottomWearColor,
      gender: gender,
      nativity: nativity,
      intent: intent,
      rssi: result.rssi,
      lastSeen: result.timeStamp,
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
