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

    test('packBlePayload strictly fits traits into 3 bytes without overflow', () {
      final identity = OfflineIdentity(
        offlineId: 'a1b2c3d4e5f6g7h8', // length 16 hash
        username: 'Tester',
        avatarId: 255, // Max length 8-bits
        topWearColor: 15, // Max length 4-bits
        bottomWearColor: 15, // Max length 4-bits
        gender: 7, // Max length 3-bits
        nativity: 31, // Max length 5-bits
        createdAt: DateTime.now(),
      );

      final payload = bleService.buildPayloadTest(
        identity,
        BleIntent.presence,
        null,
      );

      // Verify the lengths and structures based on platform differences inside BleService
      // Android generates a 27-byte payload by default if Platform.isIOS is false during test.
      // We are forcing the testing environment to see the raw byte packing.
      expect(payload[14], equals(255)); // avatar ID

      // Outfit Colors (top & bottom: 15 & 15 => 11111111 = 255)
      expect(payload[15], equals(255));

      // Bio (gender 7, nativity 31 => 11111111 = 255)
      expect(payload[16], equals(255));

      // Bytes 17-26 should contain "Tester" and padded with 0
      expect(payload[17], equals(84)); // 'T'
      expect(payload[18], equals(101)); // 'e'
      expect(payload[19], equals(115)); // 's'
      expect(payload[20], equals(116)); // 't'
      expect(payload[21], equals(101)); // 'e'
      expect(payload[22], equals(114)); // 'r'
      expect(payload[23], equals(0)); // null padding
    });

    test('packBlePayload correctly bit-shifts partial values', () {
      final identity = OfflineIdentity(
        offlineId:
            '1a2b3c4d5e6f7g8h', // must be min 12 char for bleHash substring
        username: 'A',
        avatarId: 42,
        topWearColor: 2, // 0010
        bottomWearColor: 1, // 0001
        gender: 1, // 001
        nativity: 2, // 00010
        createdAt: DateTime.now(),
      );

      final payload = bleService.buildPayloadTest(
        identity,
        BleIntent.presence,
        null,
      );

      expect(payload[14], equals(42));

      // topWearColor(2) << 4 | bottomWearColor(1)
      // 0010 0000 | 0000 0001 = 0010 0001 = 33
      expect(payload[15], equals(33));

      // gender(1) << 5 | nativity(2)
      // 0010 0000 | 0000 0010 = 0010 0010 = 34
      expect(payload[16], equals(34));
    });
  });
}
