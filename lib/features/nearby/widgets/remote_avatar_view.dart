import 'dart:convert';
import 'package:flutter/material.dart';
import '../../../core/models/avatar_dna.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttermoji/fluttermoji.dart' as fm;

class RemoteAvatarView extends StatelessWidget {
  final int dna;
  final double radius;

  const RemoteAvatarView({
    super.key,
    required this.dna,
    this.radius = 40,
  });

  @override
  Widget build(BuildContext context) {
    final traits = AvatarDNA.unpack(dna);
    final functions = fm.FluttermojiFunctions();
    
    String svgString;
    try {
      // Clamping traits to known safe ranges for the current fluttermoji asset list
      final safeEncoded = {
        'topType': (traits['topStyle'] ?? 0).clamp(0, 31),
        'hairColor': (traits['hairColor'] ?? 0).clamp(0, 5),
        'eyeType': (traits['eyeStyle'] ?? 0).clamp(0, 5),
        'eyebrowType': (traits['eyebrowType'] ?? 0).clamp(0, 5),
        'mouthType': (traits['mouthType'] ?? 0).clamp(0, 5),
        'skinColor': (traits['skinColor'] ?? 0).clamp(0, 4),
        'facialHairType': (traits['facialHairType'] ?? 0).clamp(0, 5),
        'facialHairColor': (traits['hairColor'] ?? 0).clamp(0, 5),
        'accessoriesType': (traits['accessoriesType'] ?? 0).clamp(0, 5),
        'clotheType': 4,
        'clotheColor': 1,
        'style': 0,
        'graphicType': 0,
      };

      svgString = functions.decodeFluttermojifromString(
        jsonEncode(safeEncoded)
      );
    } catch (e) {
      // Fallback for extreme stress edge-cases
      svgString = ''; 
    }

    // Standardized premium background for all avatars
    const Color standardBg = Color(0xFF2D3139); // Deep Slate Metallic

    return CircleAvatar(
      radius: radius,
      backgroundColor: standardBg,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.15),
              Colors.black.withValues(alpha: 0.2),
            ],
            center: const Alignment(-0.3, -0.3),
            radius: 0.8,
          ),
        ),
        child: ClipOval(
          child: Visibility(
            visible: dna != 0 && svgString.isNotEmpty,
            replacement: Icon(Icons.person, size: radius, color: Colors.white24),
            child: SvgPicture.string(
              svgString,
              height: radius * 1.6,
              placeholderBuilder: (context) => const CircularProgressIndicator(),
            ),
          ),
        ),
      ),
    );
  }
}
