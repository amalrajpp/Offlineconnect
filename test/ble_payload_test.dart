import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connect/core/models/ble_models.dart';
import 'package:offline_connect/core/models/offline_identity.dart';
import 'package:offline_connect/core/services/ble_service.dart';

void main() {
  group('BleService Bitwise Data Packing Tests', () {
    late BleService bleService;

    setUp(() {
      bleService = BleService();
    });

    test('packBlePayload strictly fits traits into 27 bytes', () {
      final identity = OfflineIdentity(
        offlineId: 'a1b2c3d4e5f6g7h8', // length 16 hash
        username: 'Tester',
        avatarDna: 0x12345678,
        topWearColor: 15, // Max length 4-bits
        bottomWearColor: 15, // Max length 4-bits
        createdAt: DateTime.now(),
      );

      final payload = bleService.buildPayloadTest(
        identity,
        BleIntent.presence,
        null,
      );

      // Bytes 10-13 – avatar DNA
      expect(payload[10], equals(0x12));
      expect(payload[11], equals(0x34));
      expect(payload[12], equals(0x56));
      expect(payload[13], equals(0x78));

      // Byte 14 – Outfit Colors (top & bottom: 15 & 15 => 11111111 = 255)
      expect(payload[14], equals(255));

      // Bytes 15-26 should contain "Tester" and padded with 0
      expect(payload[15], equals(84)); // 'T'
      expect(payload[16], equals(101)); // 'e'
      expect(payload[17], equals(115)); // 's'
      expect(payload[18], equals(116)); // 't'
      expect(payload[19], equals(101)); // 'e'
      expect(payload[20], equals(114)); // 'r'
      expect(payload[21], equals(0)); // null padding
    });

    test('packBlePayload correctly bit-shifts outfit colors', () {
      final identity = OfflineIdentity(
        offlineId:
            '1a2b3c4d5e6f7g8h', // must be min 12 char for bleHash substring
        username: 'A',
        avatarDna: 0,
        topWearColor: 2, // 0010
        bottomWearColor: 1, // 0001
        createdAt: DateTime.now(),
      );

      final payload = bleService.buildPayloadTest(
        identity,
        BleIntent.presence,
        null,
      );

      // topWearColor(2) << 4 | bottomWearColor(1)
      // 0010 0000 | 0000 0001 = 0010 0001 = 33
      expect(payload[14], equals(33));
    });
  });
}
