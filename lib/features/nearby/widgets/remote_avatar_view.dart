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
      'clotheType': 4,
      'clotheColor': 1,
      'style': 0,
      'graphicType': 0,
    };
    
    final svgString = functions.decodeFluttermojifromString(
      jsonEncode(encoded)
    );

    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey[800],
      child: ClipOval(
        child: Visibility(
          visible: dna != 0,
          replacement: Icon(Icons.person, size: radius, color: Colors.white24),
          child: SvgPicture.string(
            svgString,
            height: radius * 1.6,
            placeholderBuilder: (context) => const CircularProgressIndicator(),
          ),
        ),
      ),
    );
  }
}
