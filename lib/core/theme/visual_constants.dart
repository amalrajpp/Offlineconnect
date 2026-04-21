import 'package:flutter/material.dart';

/// Central dictionary mapping the bitwise 4-bit, 3-bit, and 5-bit integers
/// back into fast O(1) visual constants for the immediate Radar Views.
class VisualConstants {
  // ── Outfit Colors (0-15 = 4 bits) ───────────────────────────────────────
  // These represent the exact real-world colors users can pick for clothes.
  static const List<Color> outfitColors = [
    Colors.transparent, // 0 - None/Hide
    Colors.black, // 1
    Colors.white, // 2
    Colors.grey, // 3
    Colors.red, // 4
    Colors.blue, // 5
    Colors.green, // 6
    Colors.amber, // 7
    Colors.purple, // 8
    Colors.orange, // 9
    Colors.brown, // 10
    Color(0xFFF5F5DC), // 11 - Beige
    Colors.teal, // 12 (Multicolor proxy)
    Colors.indigo, // 13 - Denim proxy
    Colors.pink, // 14
    Color(0xFF607D8B), // 15 - Other/BlueGrey
  ];

  static Color getOutfitColor(int bits) {
    if (bits < 0 || bits >= outfitColors.length) return Colors.transparent;
    return outfitColors[bits];
  }
}
