import 'package:flutter_test/flutter_test.dart';
import 'package:offline_connect/core/models/avatar_dna.dart';
import 'package:offline_connect/core/services/payload_builder.dart';
import 'package:offline_connect/core/utils/hash_engine.dart';

void main() {
  group('BLE Payload Packing Tests', () {
    test('iOS 16-byte Payload Packing', () {
      final dna = AvatarDNA.pack(
        topStyle: 10,
        hairColor: 2,
        eyeStyle: 3,
        eyebrowType: 4,
        mouthType: 5,
        skinColor: 6,
        facialHairType: 1,
        accessoriesType: 0,
      );

      final payload = PayloadBuilder.buildIosPayload(
        dna32: dna,
        outfitColor: 0xAB,
        myId: 'user_123',
        targetId: 'user_456',
      );

      expect(payload.length, 16);
      expect(payload[0], 0x0C);
      expect(payload[1], 0x0C);
      expect(payload[7], 0xAB);
    });

    test('Android 27-byte Payload Packing', () {
      final dna = AvatarDNA.pack(
        topStyle: 10,
        hairColor: 2,
        eyeStyle: 3,
        eyebrowType: 4,
        mouthType: 5,
        skinColor: 6,
        facialHairType: 1,
        accessoriesType: 0,
      );

      final payload = PayloadBuilder.buildAndroidPayload(
        dna32: dna,
        outfitColor: 0xAB,
        myId: 'user_123',
        targetId: 'user_456',
        username: 'Amal',
      );

      expect(payload.length, 27);
      expect(payload[0], 0x01);
      expect(payload[14], 0xAB);
      
      // Verify username truncation/packing
      final name = String.fromCharCodes(payload.sublist(15, 19));
      expect(name, 'Amal');
    });

    test('Fnv1a 32-bit Hash Consistency', () {
      final hash1 = HashEngine.generate4ByteHash('tester');
      final hash2 = HashEngine.generate4ByteHash('tester');
      final hash3 = HashEngine.generate4ByteHash('other');

      expect(hash1, hash2);
      expect(hash1, isNot(hash3));
    });
  });
}
