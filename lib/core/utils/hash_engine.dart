class HashEngine {
  /// Generates a 32-bit (4-byte) FNV-1a hash from a string.
  /// This gives you 4.29 billion unique combinations.
  static int generate4ByteHash(String input) {
    int hash = 0x811c9dc5; // FNV offset basis
    int prime = 0x01000193; // FNV prime

    for (int i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      // Multiply by prime and constrain to 32 bits
      hash = (hash * prime) & 0xFFFFFFFF; 
    }
    
    return hash;
  }
}
