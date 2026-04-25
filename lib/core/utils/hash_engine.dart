class HashEngine {
  /// Generates a 32-bit FNV-1a hash to act as a 4-byte unique token for IDs.
  ///
  /// This allows us to represent long UUID strings in strictly 4 bytes
  /// for BLE manufacturing data / Service UUID spoofing.
  static int generate4ByteHash(String input) {
    int hash = 0x811c9dc5;
    const int prime = 0x01000193;

    for (int i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      // Ensure the multiplication stays within 32-bit bounds
      hash = (hash * prime).toUnsigned(32);
    }

    return hash;
  }

  /// Extracts exactly 4 bytes from the 32-bit hash (Big-Endian).
  static List<int> toBytes(int hash) {
    return [
      (hash >> 24) & 0xFF,
      (hash >> 16) & 0xFF,
      (hash >> 8) & 0xFF,
      hash & 0xFF,
    ];
  }
}
