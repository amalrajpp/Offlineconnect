import '../models/avatar_dna.dart';
import '../utils/hash_engine.dart';

class PayloadBuilder {
  /// Builds the 16-byte payload for iOS, formatted as a spoofed Service UUID.
  /// 
  /// Structure (16 bytes):
  /// - 0-1: Magic Bytes (0x0C0C)
  /// - 2: Protocol Version/Intent (0x11)
  /// - 3-6: Avatar DNA (4 bytes)
  /// - 7: Outfit Color (1 byte)
  /// - 8-11: My ID Hash (4 bytes)
  /// - 12-15: Target ID Hash (4 bytes)
  static List<int> buildIosPayload({
    required int dna32,
    required int outfitColor,
    required String myId,
    required String targetId,
  }) {
    final payload = List<int>.filled(16, 0);

    payload[0] = 0x0C;
    payload[1] = 0x0C;
    payload[2] = 0x11;

    payload.setRange(3, 7, AvatarDNA.toBytes(dna32));
    payload[7] = outfitColor & 0xFF;

    final myHash = HashEngine.generate4ByteHash(myId);
    final targetHash = HashEngine.generate4ByteHash(targetId);

    payload.setRange(8, 12, HashEngine.toBytes(myHash));
    payload.setRange(12, 16, HashEngine.toBytes(targetHash));

    return payload;
  }

  /// Converts a 16-byte payload into a valid UUID string format.
  /// Result: 0c0c11xx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  static String formatAsUuid(List<int> bytes) {
    if (bytes.length != 16) return '';
    final hexString = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return '${hexString.substring(0, 8)}-${hexString.substring(8, 12)}-'
           '${hexString.substring(12, 16)}-${hexString.substring(16, 20)}-'
           '${hexString.substring(20, 32)}';
  }

  /// Builds the 27-byte payload for Android Manufacturer Specific Data.
  /// 
  /// Structure (27 bytes):
  /// - 0: Version (0x01)
  /// - 1: Intent (0x11)
  /// - 2-5: My ID Hash (4 bytes)
  /// - 6-9: Target ID Hash (4 bytes)
  /// - 10-13: Avatar DNA (4 bytes)
  /// - 14: Outfit Color (1 byte)
  /// - 15-26: Truncated Username (up to 12 bytes)
  static List<int> buildAndroidPayload({
    required int dna32,
    required int outfitColor,
    required String myId,
    required String targetId,
    required String username,
  }) {
    final payload = List<int>.filled(27, 0);

    payload[0] = 0x01;
    payload[1] = 0x11;

    final myHash = HashEngine.generate4ByteHash(myId);
    final targetHash = HashEngine.generate4ByteHash(targetId);

    payload.setRange(2, 6, HashEngine.toBytes(myHash));
    payload.setRange(6, 10, HashEngine.toBytes(targetHash));
    payload.setRange(10, 14, AvatarDNA.toBytes(dna32));
    payload[14] = outfitColor & 0xFF;

    final nameBytes = username.codeUnits;
    for (int i = 0; i < 12 && i < nameBytes.length; i++) {
      payload[15 + i] = nameBytes[i];
    }

    return payload;
  }
}
