class AvatarDNA {
  /// Packs 8 individual traits into a single 32-bit integer.
  static int pack({
    required int hairStyle, // 6 bits (0-63)
    required int hairColor, // 4 bits (0-15)
    required int eyeShape,  // 5 bits (0-31)
    required int eyeColor,  // 3 bits (0-7)
    required int mouthShape,// 4 bits (0-15)
    required int noseShape, // 4 bits (0-15)
    required int skinTone,  // 3 bits (0-7)
    required int extras,    // 3 bits (0-7)
  }) {
    int dna = ((hairStyle & 0x3F) << 26) |
              ((hairColor & 0x0F) << 22) |
              ((eyeShape & 0x1F) << 17) |
              ((eyeColor & 0x07) << 14) |
              ((mouthShape & 0x0F) << 10) |
              ((noseShape & 0x0F) << 6) |
              ((skinTone & 0x07) << 3) |
              (extras & 0x07);
              
    return dna.toUnsigned(32);
  }

  /// Unpacks a 32-bit integer back into a map of individual traits.
  static Map<String, int> unpack(int dna) {
    return {
      'hairStyle': (dna >> 26) & 0x3F,
      'hairColor': (dna >> 22) & 0x0F,
      'eyeShape': (dna >> 17) & 0x1F,
      'eyeColor': (dna >> 14) & 0x07,
      'mouthShape': (dna >> 10) & 0x0F,
      'noseShape': (dna >> 6) & 0x0F,
      'skinTone': (dna >> 3) & 0x07,
      'extras': dna & 0x07,
    };
  }
}
