class AvatarDNA {
  /// Packs Fluttermoji features into a single 32-bit unsigned integer.
  ///
  /// Bit Allocation:
  /// - Top Style: 6 bits (0-63) << 26
  /// - Hair Color: 4 bits (0-15) << 22
  /// - Eye Style: 4 bits (0-15) << 18
  /// - Brow Type: 4 bits (0-15) << 14
  /// - Mouth Type: 4 bits (0-15) << 10
  /// - Skin Color: 4 bits (0-15) << 6
  /// - Facial Hair: 3 bits (0-7) << 3
  /// - Accessories: 3 bits (0-7) << 0
  static int pack({
    required int topStyle,
    required int hairColor,
    required int eyeStyle,
    required int eyebrowType,
    required int mouthType,
    required int skinColor,
    required int facialHairType,
    required int accessoriesType,
  }) {
    int dna =
        ((topStyle & 0x3F) << 26) |
        ((hairColor & 0x0F) << 22) |
        ((eyeStyle & 0x0F) << 18) |
        ((eyebrowType & 0x0F) << 14) |
        ((mouthType & 0x0F) << 10) |
        ((skinColor & 0x0F) << 6) |
        ((facialHairType & 0x07) << 3) |
        (accessoriesType & 0x07);

    return dna.toUnsigned(32);
  }

  /// Unpacks a 32-bit integer back into a Fluttermoji-compatible Map.
  static Map<String, int> unpack(int dna) {
    return {
      'topStyle': (dna >> 26) & 0x3F,
      'hairColor': (dna >> 22) & 0x0F,
      'eyeStyle': (dna >> 18) & 0x0F,
      'eyebrowType': (dna >> 14) & 0x0F,
      'mouthType': (dna >> 10) & 0x0F,
      'skinColor': (dna >> 6) & 0x0F,
      'facialHairType': (dna >> 3) & 0x07,
      'accessoriesType': dna & 0x07,
    };
  }

  /// Extracts exactly 4 bytes from the 32-bit integer (Big-Endian).
  static List<int> toBytes(int dna) {
    return [
      (dna >> 24) & 0xFF,
      (dna >> 16) & 0xFF,
      (dna >> 8) & 0xFF,
      dna & 0xFF,
    ];
  }

  /// Reconstructs a 32-bit integer from 4 consecutive bytes.
  static int fromBytes(List<int> bytes, int offset) {
    if (offset + 3 >= bytes.length) return 0;
    int dna =
        ((bytes[offset] & 0xFF) << 24) |
        ((bytes[offset + 1] & 0xFF) << 16) |
        ((bytes[offset + 2] & 0xFF) << 8) |
        (bytes[offset + 3] & 0xFF);
    return dna.toUnsigned(32);
  }
}
