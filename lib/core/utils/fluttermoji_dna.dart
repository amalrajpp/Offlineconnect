import 'dart:convert';
import 'package:fluttermoji/fluttermoji.dart';
import '../models/avatar_dna.dart';

class FluttermojiDna {
  /// Converts a bit-packed 32-bit DNA integer into an SVG string.
  static String dnaToSvg(int dna) {
    final traits = AvatarDNA.unpack(dna);
    final functions = FluttermojiFunctions();

    // Map our bit-packet keys back to Fluttermoji internal JSON keys
    final encoded = {
      'topType': traits['topStyle'],
      'hairColor': traits['hairColor'],
      'eyeType': traits['eyeStyle'],
      'eyebrowType': traits['eyebrowType'],
      'mouthType': traits['mouthType'],
      'skinColor': traits['skinColor'],
      'facialHairType': traits['facialHairType'],
      'facialHairColor': traits['hairColor'],
      'accessoriesType': traits['accessoriesType'],
      'clotheType': 4, // Default hoodie
      'clotheColor': 1, // Default neutral
      'style': 0,
      'graphicType': 0,
    };

    return functions.decodeFluttermojifromString(jsonEncode(encoded));
  }
}
