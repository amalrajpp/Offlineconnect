import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

import '../nearby/nearby_controller.dart';
import '../nearby/widgets/remote_avatar_view.dart';
import '../../core/models/ble_models.dart';
import 'connections_screen.dart';

enum ConnectState { listening, connecting, success }

class KineticConnectScreen extends StatefulWidget {
  const KineticConnectScreen({super.key});

  @override
  State<KineticConnectScreen> createState() => _KineticConnectScreenState();
}

class _KineticConnectScreenState extends State<KineticConnectScreen>
    with TickerProviderStateMixin {
  ConnectState _currentState = ConnectState.listening;

  // Sensor & Stream Subscriptions
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;

  // Tuning Variables (Golden Ratio)
  final double _kineticThreshold = 0.8;
  final int _rssiThreshold = -65;

  // Debug & Caching
  double _lastMagnitude = 0.0;
  DiscoveredPeer? _acceptedPeer;
  bool _isProcessingBump = false;

  // New Variables for Gyro and Haptics
  double _tiltX = 0.0;
  double _tiltY = 0.0;
  StreamSubscription<AccelerometerEvent>? _tiltSubscription;
  Timer? _hapticTimer;

  late AnimationController _stringController;

  @override
  void initState() {
    super.initState();
    _startSensorFusion();

    // Track device tilt to map lighting and shadow layers interactively
    _tiltSubscription = accelerometerEventStream().listen((event) {
      if (!mounted) return;
      setState(() {
        _tiltX = event.x;
        _tiltY = event.y;
      });
    });

    // CRITICAL: Ensure BLE is actively scanning for peers.
    final controller = Get.find<NearbyController>();
    if (!controller.scanning.value) {
      controller.startScanningAndBroadcasting();
    }

    _stringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  void _startSensorFusion() {
    _accelSubscription = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      if (_currentState != ConnectState.listening || _isProcessingBump) return;

      double magnitude = sqrt(
        pow(event.x, 2) + pow(event.y, 2) + pow(event.z, 2),
      );

      if (magnitude > 1.0 && mounted) {
        setState(() {
          _lastMagnitude = magnitude;
        });
      }

      if (magnitude >= _kineticThreshold) {
        _handleKineticBump();
      }
    });
  }

  Future<void> _handleKineticBump() async {
    _isProcessingBump = true;

    try {
      final controller = Get.find<NearbyController>();

      DiscoveredPeer? targetPeer;
      for (var peer in controller.users) {
        if (targetPeer == null || peer.rssi > targetPeer.rssi) {
          targetPeer = peer;
        }
      }

      if (targetPeer != null && targetPeer.rssi >= _rssiThreshold) {
        // Stop listening to prevent battery drain and false triggers
        _accelSubscription?.pause();

        // Trigger Heavy Haptics like AirDrop
        // Sequence: Heavy impact on bump, then delay, then connection burst
        HapticFeedback.heavyImpact();

        if (mounted) {
          setState(() {
            _currentState = ConnectState.connecting;
            _acceptedPeer = targetPeer;
          });
          _stringController.repeat();
          _startHapticSymphony();
        }

        // Wait to show off the beautiful undulating string animation simulating connection
        await Future.delayed(const Duration(milliseconds: 2000));

        // Execute Silent Handshake
        await _executeMeshHandshake(targetPeer.myHash);
      } else {
        // False alarm (bumped but no one is near). Reset debounce.
        await Future.delayed(const Duration(milliseconds: 500));
        _isProcessingBump = false;
      }
    } catch (e) {
      debugPrint('Error during kinetic bump: $e');
      _isProcessingBump = false;
    }
  }

  Future<void> _executeMeshHandshake(String targetNode) async {
    try {
      final controller = Get.find<NearbyController>();

      // Atomic accept on both devices, SILENT parameter hides standard UI snackbars
      controller.sendAcceptRequest(targetNode, silent: true);

      // Trigger the success explosion, but keep the stringController running for a gentle swing
      if (mounted) {
        setState(() {
          _currentState = ConnectState.success;
        });

        _playAirDropHapticSequence();
      }
    } catch (e) {
      debugPrint('Handshake error: $e');
    }
  }

  Future<void> _testAnimation() async {
    if (_currentState != ConnectState.listening || _isProcessingBump) return;
    _isProcessingBump = true;

    final dummyPeer = DiscoveredPeer(
      deviceId: 'test_123',
      myHash: 't_hash',
      offlineUsername: 'Test User',
      avatarDna: 0x1A2B3C4D, // Use a representative 32-bit DNA for the test
      intent: BleIntent.presence,
      rssi: -40,
      lastSeen: DateTime.now(),
    );

    _accelSubscription?.pause();
    HapticFeedback.heavyImpact();

    if (mounted) {
      setState(() {
        _currentState = ConnectState.connecting;
        _acceptedPeer = dummyPeer;
      });
      _stringController.repeat();
      _startHapticSymphony();
    }

    await Future.delayed(const Duration(milliseconds: 2000));

    if (mounted) {
      setState(() {
        _currentState = ConnectState.success;
      });
      _playAirDropHapticSequence();
    }
  }

  // Replicates a deeply premium 'Heartbeat' (Lub-Dub) natively on both Android and iOS
  Future<void> _startHapticSymphony() async {
    _hapticTimer?.cancel();

    // Use the vibration package to bypass weak Android default haptics
    final bool hasCustomVibe = await Vibration.hasCustomVibrationsSupport();

    while (_currentState == ConnectState.connecting && mounted) {
      if (hasCustomVibe) {
        Vibration.vibrate(duration: 40, amplitude: 128); // Lub (mid depth)
      } else {
        HapticFeedback.mediumImpact();
      }

      await Future.delayed(const Duration(milliseconds: 120));
      if (_currentState != ConnectState.connecting || !mounted) break;

      if (hasCustomVibe) {
        Vibration.vibrate(duration: 20, amplitude: 64); // Dub (soft)
      } else {
        HapticFeedback.lightImpact();
      }

      await Future.delayed(const Duration(milliseconds: 800));
    }
  }

  // The definitive AirDrop success crescendo pushed directly to the hardware motor
  Future<void> _playAirDropHapticSequence() async {
    final bool hasCustomVibe = await Vibration.hasCustomVibrationsSupport();

    if (hasCustomVibe) {
      // Direct amplitude control to physically hit the motor hard
      // Pattern: wait 0ms, vibrate 40ms at mid power (tick), wait 100ms, vibrate 120ms at MAX power (THUD)
      Vibration.vibrate(
        pattern: [0, 40, 100, 120],
        intensities: [0, 128, 0, 255],
      );
    } else {
      // Fallback for missing custom support or iOS CoreHaptics bridging
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 140));
      HapticFeedback.heavyImpact();
    }
  }

  void _resetAnimation() {
    if (!mounted) return;
    setState(() {
      _currentState = ConnectState.listening;
      _acceptedPeer = null;
      _isProcessingBump = false;
    });
    _stringController.stop();
    _stringController.reset();
    _hapticTimer?.cancel();
    _accelSubscription?.resume();
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _tiltSubscription?.cancel();
    _hapticTimer?.cancel();
    _stringController.dispose();
    super.dispose();
  }

  int get _liveClosestRssi {
    try {
      final ctrl = Get.find<NearbyController>();
      if (ctrl.users.isEmpty) return -100;
      return ctrl.users.map((e) => e.rssi).reduce((a, b) => a > b ? a : b);
    } catch (_) {
      return -100;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          Colors.black, // Pure black so the neon red pops flawlessly
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_currentState == ConnectState.listening)
            IconButton(
              icon: const Icon(Icons.bug_report, color: Colors.amber),
              tooltip: 'Test Animation',
              onPressed: _testAnimation,
            ),
          if (_currentState != ConnectState.listening)
            IconButton(
              icon: const Icon(Icons.restore, color: Colors.amber),
              tooltip: 'Reset Animation',
              onPressed: _resetAnimation,
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            tooltip: 'Force Wake Scanner',
            onPressed: () {
              final ctrl = Get.find<NearbyController>();
              ctrl.stopScanningAndBroadcasting().then((_) {
                ctrl.startScanningAndBroadcasting();
              });
            },
          ),
        ],
      ),
      body: SizedBox.expand(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 0. Volumetric Ember Particles (Depth)
            if (_currentState != ConnectState.listening)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _stringController,
                  builder: (context, child) {
                    return CustomPaint(
                      painter: _EmberPainter(_stringController.value),
                    );
                  },
                ),
              ),

            // 1. Sleek Ethereal Aurora Wash (NameDrop effect)
            if (_currentState != ConnectState.listening)
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 2500),
                  curve: Curves
                      .fastOutSlowIn, // Extreme smoothness, fluid like NameDrop liquid
                  builder: (context, value, child) {
                    return Container(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(0, -1.2 + (value * 1.6)),
                          radius: 1.5 + (value * 2.5),
                          colors: [
                            const Color(0xFFE50914).withValues(
                              alpha: 0.5 * (value < 0.2 ? value * 5 : 1.0),
                            ), // Intense neon red
                            const Color(0xFF7A0410).withValues(
                              alpha: 0.2 * (value < 0.2 ? value * 5 : 1.0),
                            ), // Deep crimson edge
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    );
                  },
                ),
              ),

            // 2. Beautiful Thin Redstring Painter
            if (_currentState != ConnectState.listening)
              Positioned.fill(
                child: TweenAnimationBuilder<double>(
                  // Tension animates: 1.0 during connecting, physically snaps to 0.0 elastically on success
                  tween: Tween(
                    begin: 1.0,
                    end: _currentState == ConnectState.success ? 0.0 : 1.0,
                  ),
                  duration: const Duration(milliseconds: 2000),
                  curve: Curves
                      .easeOutCubic, // Butter-smooth tightening, zero harsh recoil
                  builder: (context, tension, child) {
                    return AnimatedBuilder(
                      animation: _stringController,
                      builder: (context, child) {
                        return TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 1800),
                          curve: Curves.fastOutSlowIn, // Viscous, heavy drop
                          builder: (context, dropProgress, child) {
                            return CustomPaint(
                              painter: _RedStringPainter(
                                wavePhase: _stringController.value * 2 * pi,
                                dropProgress: dropProgress,
                                tension: tension,
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),

            // 3. Success Smooth Shockwave & Lens Flare
            if (_currentState == ConnectState.success)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 3000),
                curve: Curves
                    .fastOutSlowIn, // Smoothly swells and beautifully drifts away
                builder: (context, value, child) {
                  final inverseValue = (1 - value).clamp(0.0, 1.0);
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Massive Red Gradient Aura Explosion
                      Container(
                        width: 150 + (value * 1400), // Envelopes the screen
                        height: 150 + (value * 1400),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              const Color(
                                0xFFE50914,
                              ).withValues(alpha: inverseValue * 0.8),
                              const Color(
                                0xFF7A0410,
                              ).withValues(alpha: inverseValue * 0.3),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.6, 1.0],
                          ),
                        ),
                      ),
                      // Center Soft Illuminating Flash (Lens Flare)
                      Container(
                        width: 10 + (value * 1000),
                        height: 10 + (value * 1000),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              Colors.white.withValues(
                                alpha: inverseValue * 0.6,
                              ), // Whisper smooth flare
                              const Color(
                                0xFFE50914,
                              ).withValues(alpha: inverseValue * 0.3),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.4, 1.0],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),

            // 4. Perfectly Centered Profile Visualizer
            _buildVisualizer(),

            // 4.5. Status Text Positioned below center
            Positioned(bottom: 180, child: _buildStatusText()),

            // 5. The Pop-in Button upon success
            if (_currentState == ConnectState.success)
              Positioned(
                bottom: 80,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) {
                    return Transform.scale(
                      scale: scale,
                      child: ElevatedButton.icon(
                        onPressed: () =>
                            Get.off(() => const ConnectionsScreen()),
                        icon: const Icon(
                          Icons.check_circle_rounded,
                          color: Colors.white,
                        ),
                        label: const Text(
                          'View Connection',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            letterSpacing: -0.5,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE50914),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          elevation: 12,
                          shadowColor: const Color(
                            0xFFE50914,
                          ).withValues(alpha: 0.5),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer() {
    if (_currentState == ConnectState.listening || _acceptedPeer == null) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12, width: 2),
        ),
        child: const Center(
          child: Icon(Icons.sensors, color: Colors.white38, size: 40),
        ),
      );
    }

    // Cinematic Reveal Avatar Bubble
    // Connecting = Small tight spark. Success = Well-balanced premium profile size
    final size = _currentState == ConnectState.connecting ? 30.0 : 130.0;
    final isSuccess = _currentState == ConnectState.success;

    // Interactive 3D lighting shadow offset based on device tilt
    // _tiltX is gravity on X axis (negative when tilting right), so shadow goes right.
    final double lightX = (_tiltX * -2.5).clamp(-15.0, 15.0);
    final double lightY = (_tiltY * 2.5).clamp(-15.0, 15.0);

    return AnimatedBuilder(
      animation: _stringController,
      builder: (context, child) {
        // Smooth floating motion at all times
        final double bobOffset = isSuccess
            ? sin(_stringController.value * 2 * pi) * 6.0
            : sin(_stringController.value * 4 * pi) * 4.0;

        return Transform.translate(offset: Offset(0, bobOffset), child: child);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 2000),
        curve: Curves.easeOutQuint,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Removed the hard red line so the profile blends flawlessly with the glow
          boxShadow: [
            if (isSuccess)
              BoxShadow(
                color: const Color(0xFFE50914).withValues(alpha: 0.6),
                blurRadius: 60,
                spreadRadius: 20,
                offset: Offset(lightX, lightY), // Apply Gyro offset!
              )
            else ...[
              BoxShadow(
                color: const Color(0xFFE50914).withValues(alpha: 0.9),
                blurRadius: 40,
                spreadRadius: 15,
              ),
              const BoxShadow(
                color: Colors.white,
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ],
        ),
        // "Alchemical Forge" (Atmospheric Dust Assembly)
        child: isSuccess
            ? TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(
                  milliseconds: 3200,
                ), // Extended slightly for full alchemy phases
                curve: Curves
                    .linear, // Drive perfectly linearly; we use explicit math for phases
                builder: (context, linearValue, child) {
                  // The dust organically forms a dense 130px disk matching the avatar by 0.5.
                  // We softly cross-fade the photo over the dust disk, giving the illusion that the dust BECOMES the photo.
                  final double transitionPhase = ((linearValue - 0.4) / 0.3)
                      .clamp(0.0, 1.0);

                  return SizedBox(
                    width: size,
                    height: size,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // 1. The Raw Alchemical Dust Math
                        Positioned.fill(
                          // Overflow constraints ensure dust can fly in from completely off-screen
                          child: OverflowBox(
                            maxWidth: double.infinity,
                            maxHeight: double.infinity,
                            child: CustomPaint(
                              painter: _AlchemicalDustPainter(linearValue),
                            ),
                          ),
                        ),

                        // 2. The Transmuted Solid Profile
                        Opacity(
                          opacity: Curves.easeIn.transform(transitionPhase),
                          child: RemoteAvatarView(
                            dna: _acceptedPeer!.avatarDna,
                            radius: size / 2,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildStatusText() {
    String text;
    if (_currentState == ConnectState.listening) {
      text = "Bump phones to connect";
    } else if (_currentState == ConnectState.connecting) {
      text = "Binding strand..."; // Keep the surprise hidden!
    } else {
      text = "Connected with ${_acceptedPeer?.offlineUsername ?? 'Unknown'}";
    }

    return Column(
      children: [
        AnimatedSwitcher(
          duration: const Duration(
            milliseconds: 1800,
          ), // Slow cinematic crossfade
          switchInCurve: Curves.fastOutSlowIn,
          switchOutCurve: Curves.fastOutSlowIn,
          child: _currentState == ConnectState.success && _acceptedPeer != null
              ? RichText(
                  key: ValueKey(text),
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    children: [
                      const TextSpan(
                        text: 'Connected with\n',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          height: 1.5,
                          letterSpacing: 0.5,
                        ),
                      ),
                      TextSpan(
                        text: _acceptedPeer!.offlineUsername,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.0,
                        ),
                      ),
                    ],
                  ),
                )
              : Text(
                  text,
                  key: ValueKey(text),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),
        ),
        if (_currentState == ConnectState.listening) ...[
          const SizedBox(height: 24),
          GetX<NearbyController>(
            builder: (ctrl) {
              return Text(
                'Debug Metrics\nBump Force: ${_lastMagnitude.toStringAsFixed(1)} m/s² (Needs > $_kineticThreshold)\nLive Proximity: $_liveClosestRssi dBm (Needs > $_rssiThreshold)\nActive Peers in Room: ${ctrl.users.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white24,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _AlchemicalDustPainter extends CustomPainter {
  final double progress; // 0.0 to 1.0
  _AlchemicalDustPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress >= 0.99 || progress <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final random = Random(42);

    // Phase 1 (0.0 to 0.5): Suck inward violently into the precise shape of the avatar disk.
    // Phase 2 (0.5 to 1.0): Dust gracefully cross-fades out as the photo perfectly replaces it.

    final double suckInProgress = (progress / 0.5).clamp(0.0, 1.0);
    // Smoothly dissolve the dust exactly as the photo attains full opacity (0.4 to 0.7).
    final double fadeOut = ((progress - 0.4) / 0.3).clamp(0.0, 1.0);

    final double dustOpacity = 1.0 - Curves.easeIn.transform(fadeOut);

    final glowPaint = Paint()
      ..color = const Color(0xFFE50914).withValues(alpha: dustOpacity * 0.8)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10.0);

    final corePaint = Paint()
      ..color = Colors.white.withValues(alpha: dustOpacity);

    final int dustCount = 200;

    for (int i = 0; i < dustCount; i++) {
      final double angle = random.nextDouble() * 2 * pi;
      // Start them far away in the atmosphere
      final double initialRadius = 150 + random.nextDouble() * 400;

      // Instead of pulling to a single 0-radius dot, they pull into a random, stationary spot inside the 130px avatar (radius 65)
      final double finalTargetRadius = random.nextDouble() * 60;

      // Cubic easing for the inward pull
      final double easedSuck = pow(
        suckInProgress,
        0.5 + random.nextDouble(),
      ).toDouble();

      // Animate from off-screen into the solid disk shape
      double currentRadius =
          initialRadius + (finalTargetRadius - initialRadius) * easedSuck;

      // Keep them swirling, but rapidly slow down the spin as they hit the core for a solidifying effect
      final double spinSpeed = 1.0 - suckInProgress;
      final double swirlingAngle =
          angle + (progress * pi * 4 * random.nextDouble() * spinSpeed);

      final double px = center.dx + cos(swirlingAngle) * currentRadius;
      final double py = center.dy + sin(swirlingAngle) * currentRadius;

      final double baseSize = random.nextDouble() * 4 + 1;

      // As they compress, they swell slightly, ensuring the 130px disk becomes completely solid without gaps
      final double sizeMultiplier = 1.0 + (suckInProgress * 2.0);

      canvas.drawCircle(
        Offset(px, py),
        (baseSize * sizeMultiplier).clamp(0.0, 12.0) + 4,
        glowPaint,
      );
      canvas.drawCircle(
        Offset(px, py),
        (baseSize * sizeMultiplier).clamp(0.0, 12.0),
        corePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AlchemicalDustPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _EmberPainter extends CustomPainter {
  final double time;
  _EmberPainter(this.time);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE50914).withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

    final random = Random(42);
    for (int i = 0; i < 25; i++) {
      double startX = random.nextDouble() * size.width;
      double startY = random.nextDouble() * size.height;
      int speedMult = 1 + random.nextInt(3);

      // Infinitely looping vertical float
      double currentY =
          (startY - (time * size.height * speedMult)) % size.height;
      if (currentY < 0) currentY += size.height;

      // Gentle horizontal sway
      double currentX = startX + sin((time * 2 * pi * speedMult) + i) * 15.0;

      canvas.drawCircle(
        Offset(currentX, currentY),
        random.nextDouble() * 4 + 1,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EmberPainter oldDelegate) =>
      oldDelegate.time != time;
}

class _RedStringPainter extends CustomPainter {
  final double wavePhase;
  final double dropProgress;
  final double tension;

  _RedStringPainter({
    required this.wavePhase,
    required this.dropProgress,
    required this.tension,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (dropProgress <= 0) return;

    // Elegant, realistic bright red glow
    final glowingPaint = Paint()
      ..color = const Color(0xFFE50914).withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);

    // Thinner, sharper core thread
    final corePaint = Paint()
      ..color =
          const Color(0xFFFF6675) // Noticeably lighter inner core
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    // Super crisp central light specular
    final sparkPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final double startX = size.width / 2;
    // Start above the screen slightly so it drops in
    final double startY = -50;

    // Target is exactly the true vertical center of the screen
    final double targetY = size.height / 2;

    final double currentLineLength = (targetY - startY) * dropProgress;

    path.moveTo(startX, startY);

    final int segments = 80; // High resolution path
    final double segmentHeight = currentLineLength / segments;

    // Smooth, physics-driven elastic wave snap
    final double maxAmplitude = 8.0 + (17.0 * tension);
    final double currentAmplitude = maxAmplitude * dropProgress;

    for (int i = 1; i <= segments; i++) {
      final double y = startY + (i * segmentHeight);

      // Taper amplitude at the start and end of the string so it connects solidly
      final double progressDownLine = i / segments;
      // Sine taper ensures it's 0 at start and end, fat in the middle
      final double taper = sin(progressDownLine * pi);

      // The wave travels down the string as wavePhase moves
      // i * 0.15 controls wave frequency
      final double xOffset =
          sin((i * 0.15) - wavePhase) * currentAmplitude * taper;
      final double x = startX + xOffset;

      path.lineTo(x, y);
    }

    // Paint layers (darkest/blurriest to sharpest/lightest)
    canvas.drawPath(path, glowingPaint);
    canvas.drawPath(path, corePaint);
    canvas.drawPath(path, sparkPaint);
  }

  @override
  bool shouldRepaint(covariant _RedStringPainter oldDelegate) {
    return oldDelegate.wavePhase != wavePhase ||
        oldDelegate.dropProgress != dropProgress ||
        oldDelegate.tension != tension;
  }
}
