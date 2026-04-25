import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttermoji/fluttermoji.dart';
import 'package:get/get.dart';

class AvatarDnaSelectionScreen extends StatefulWidget {
  const AvatarDnaSelectionScreen({super.key});

  @override
  State<AvatarDnaSelectionScreen> createState() => _AvatarDnaSelectionScreenState();
}

class _AvatarDnaSelectionScreenState extends State<AvatarDnaSelectionScreen> {
  final FluttermojiController fluttermojiController = Get.put(FluttermojiController());

  Future<void> _onSave() async {
    HapticFeedback.heavyImpact();
    
    // Extract the current state from Fluttermoji
    final Map<dynamic, dynamic> rawState = await fluttermojiController.getFluttermojiOptions();
    final Map<String, int> state = rawState.map((key, value) => MapEntry(key.toString(), value as int));
    
    // Map to our 32-bit DNA keys
    final result = {
      'topStyle': state['topType'] ?? 0,
      'hairColor': state['hairColor'] ?? 0,
      'eyeStyle': state['eyeType'] ?? 0,
      'eyebrowType': state['eyebrowType'] ?? 0,
      'mouthType': state['mouthType'] ?? 0,
      'skinColor': state['skinColor'] ?? 0,
      'facialHairType': state['facialHairType'] ?? 0,
      'accessoriesType': state['accessoriesType'] ?? 0,
    };

    Get.back(result: result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'GENETIC FORGE',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            fontSize: 14,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Get.back(),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          // Preview Area
          Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFFE50914).withValues(alpha: 0.15),
                    Colors.transparent,
                  ],
                ),
              ),
              child: FluttermojiCircleAvatar(
                radius: 80,
                backgroundColor: Colors.grey[900],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // The Customizer
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[900]!.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                child: FluttermojiCustomizer(
                  scaffoldHeight: 400,
                  theme: FluttermojiThemeData(
                    labelTextStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                    primaryBgColor: Colors.transparent,
                    secondaryBgColor: Colors.transparent,
                    iconColor: Colors.white,
                    selectedIconColor: const Color(0xFFE50914),
                    unselectedIconColor: Colors.white30,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ElevatedButton(
            onPressed: _onSave,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE50914),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 60),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
            child: const Text(
              'SEQUENCE DNA',
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}
