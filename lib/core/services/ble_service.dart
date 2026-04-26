import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../models/avatar_dna.dart';
import '../models/ble_models.dart';
import '../models/offline_identity.dart';
import 'payload_builder.dart';

/// The Zero-GATT Connectionless Handshake Engine.
///
/// Devices communicate purely through BLE payloads.
/// iOS: Spoofed 16-byte Service UUID.
/// Android: 27-byte Manufacturer Specific Data.
class BleService extends GetxService {
  static const int _manufacturerId = 0xFFFF;

  static const MethodChannel _advertChannel = MethodChannel(
    'com.redstring/ble_advertiser',
  );

  final StreamController<DiscoveredPeer> _peerController =
      StreamController<DiscoveredPeer>.broadcast();

  Stream<DiscoveredPeer> get discoveredPeers => _peerController.stream;

  StreamSubscription<List<ScanResult>>? _scanSubscription;

  Future<bool> ensureAdapterOn() async {
    try {
      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => BluetoothAdapterState.unknown,
          );

      if (state == BluetoothAdapterState.on) return true;
      if (state == BluetoothAdapterState.unknown) return false;

      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        return false;
      }

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

  Future<bool> requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt >= 31) {
          final scan = await Permission.bluetoothScan.request();
          final connect = await Permission.bluetoothConnect.request();
          final advertise = await Permission.bluetoothAdvertise.request();
          if (!scan.isGranted || !connect.isGranted || !advertise.isGranted)
            return false;
        } else {
          final location = await Permission.location.request();
          final ble = await Permission.bluetooth.request();
          if (!location.isGranted || !ble.isGranted) return false;
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
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      return state == BluetoothAdapterState.on;
    } catch (e) {
      Get.log('BleService: requestPermissions failed – $e');
      return false;
    }
  }

  Future<void> broadcastState(
    OfflineIdentity identity,
    BleIntent intent, {
    String? targetId,
  }) async {
    try {
      List<int> payload;
      String? spoofedUuid;

      if (Platform.isIOS) {
        payload = PayloadBuilder.buildIosPayload(
          dna32: identity.avatarDna,
          outfitColor:
              ((identity.topWearColor & 0x0F) << 4) |
              (identity.bottomWearColor & 0x0F),
          myId: identity.offlineId,
          targetId: targetId ?? '',
          intent: intent,
        );
        spoofedUuid = PayloadBuilder.formatAsUuid(payload);
      } else {
        payload = PayloadBuilder.buildAndroidPayload(
          dna32: identity.avatarDna,
          outfitColor:
              ((identity.topWearColor & 0x0F) << 4) |
              (identity.bottomWearColor & 0x0F),
          myId: identity.offlineId,
          targetId: targetId ?? '',
          username: identity.username,
          intent: intent,
        );
      }

      await _advertChannel.invokeMethod('startAdvertising', {
        'manufacturerId': _manufacturerId,
        'payload': payload,
        if (spoofedUuid != null) 'serviceUuid': spoofedUuid,
      });
    } on MissingPluginException {
      Get.log('BleService: advertising not available on this platform.');
    } catch (e) {
      Get.log('BleService: advertising failed – $e');
    }
  }

  Future<void> stopBroadcasting() async {
    try {
      await _advertChannel.invokeMethod('stopAdvertising');
    } catch (_) {}
  }

  Future<bool> startScanning({bool skipPermissionCheck = false}) async {
    try {
      if (!skipPermissionCheck) {
        if (!await requestPermissions()) return false;
      }

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          final peer = _parseScanResult(result);
          if (peer != null) _peerController.add(peer);
        }
      });

      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        androidUsesFineLocation: true,
      );

      return FlutterBluePlus.isScanningNow;
    } catch (e) {
      Get.log('BleService: scanning failed – $e');
      return false;
    }
  }

  Future<void> stopScanning() async {
    try {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  DiscoveredPeer? _parseScanResult(ScanResult result) {
    List<int>? raw;

    // Android: Extract from Manufacturer Data
    final mfgData = result.advertisementData.manufacturerData;
    if (mfgData.containsKey(_manufacturerId)) {
      raw = mfgData[_manufacturerId];
    }

    // iOS: Extract from Service UUIDs
    if (raw == null) {
      for (final uuidPattern in result.advertisementData.serviceUuids) {
        final uuidStr = uuidPattern.str.replaceAll('-', '').toLowerCase();
        if (uuidStr.startsWith('0c0c') && uuidStr.length == 32) {
          raw = _hexToBytes(uuidStr);
          break;
        }
      }
    }

    if (raw == null || raw.length < 16) return null;

    // Handle Blink (Handshakes)
    if (raw[0] == 0xFF || raw[0] == 0xEE) {
      // (Blink logic remains largely similar but using HashEngine comparisons if needed)
      return null;
    }

    int intentIndex;
    String senderHashHex;
    String? targetHashHex;
    int avatarDna = 0;
    int topColor = 0;
    int bottomColor = 0;
    String? username;

    if (raw.length >= 24) {
      // Android
      intentIndex = raw[1] & 0x0F;
      senderHashHex = _bytesToHex(raw.sublist(2, 6));
      targetHashHex = _bytesToHex(raw.sublist(6, 10));
      avatarDna = AvatarDNA.fromBytes(raw, 10);
      topColor = (raw[14] >> 4) & 0x0F;
      bottomColor = raw[14] & 0x0F;

      final nameBytes = raw.sublist(15, 24).where((b) => b != 0).toList();
      if (nameBytes.isNotEmpty)
        username = utf8.decode(nameBytes, allowMalformed: true);
    } else if (raw.length == 16) {
      // iOS
      intentIndex = raw[2] & 0x0F;
      avatarDna = AvatarDNA.fromBytes(raw, 3);
      topColor = (raw[7] >> 4) & 0x0F;
      bottomColor = raw[7] & 0x0F;
      senderHashHex = _bytesToHex(raw.sublist(8, 12));
      targetHashHex = _bytesToHex(raw.sublist(12, 16));
    } else {
      return null;
    }

    if (intentIndex >= BleIntent.values.length) return null;

    return DiscoveredPeer(
      deviceId: result.device.remoteId.str,
      myHash: senderHashHex,
      targetHash: (targetHashHex == '00000000' || targetHashHex == '0000')
          ? null
          : targetHashHex,
      offlineUsername: username,
      avatarDna: avatarDna,
      topWearColor: topColor,
      bottomWearColor: bottomColor,
      intent: BleIntent.values[intentIndex],
      rssi: result.rssi,
      lastSeen: result.timeStamp,
    );
  }

  Future<bool> isLocationServiceEnabled() async {
    return await Permission.location.serviceStatus.isEnabled;
  }

  Future<void> openDeviceLocationSettings() async {
    await openAppSettings();
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void onClose() {
    _scanSubscription?.cancel();
    _peerController.close();
    super.onClose();
  }
}
