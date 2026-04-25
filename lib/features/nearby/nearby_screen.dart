import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/models/ble_models.dart';
import '../../core/models/connection.dart';
import '../../core/constants/assets.dart';
import '../chat/chat_screen.dart';
import '../connections/kinetic_connect_screen.dart';
import 'widgets/remote_avatar_view.dart';
import 'nearby_controller.dart';

/// Displays nearby BLE peers discovered via the Zero-GATT protocol
/// using an interactive 2D Gamified Sonar Radar.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen>
    with TickerProviderStateMixin {
  late final AnimationController _radarController;
  late final AnimationController _recenterController;
  late final AnimationController _windController;
  late final AnimationController _shootController;
  late Animation<Matrix4> _recenterAnimation;
  late final Worker _pendingWorker;

  final TransformationController _viewController = TransformationController();
  bool _viewInitialized = false;
  late Matrix4 _initialMatrix;

  // Cache to store the computed non-overlapping positions for discovered peers
  // to avoid recalculating O(N^2) spiral logic continuously on the UI thread.
  final Map<String, Offset> _cachedPositions = {};

  void _initViewMatrix(BoxConstraints constraints) {
    if (_viewInitialized) return;
    _viewInitialized = true;

    const double mapSize = 3000.0;
    // Display a comfortable zoomed-in version based on the screen size.
    final scale = math.min(constraints.maxWidth, constraints.maxHeight) / 600.0;

    // Center the camera exactly on the middle point of our 3000x3000 map
    final tx = (constraints.maxWidth / 2.0) - ((mapSize / 2.0) * scale);
    final ty = (constraints.maxHeight / 2.0) - ((mapSize / 2.0) * scale);

    _initialMatrix = Matrix4.identity()
      ..setTranslationRaw(tx, ty, 0.0)
      ..scaleByDouble(scale, scale, 1.0, 1.0);

    _viewController.value = _initialMatrix;
  }

  void _recenter() {
    if (!_viewInitialized) return;
    _recenterAnimation =
        Matrix4Tween(begin: _viewController.value, end: _initialMatrix).animate(
          CurvedAnimation(
            parent: _recenterController,
            curve: Curves.easeOutCubic,
          ),
        );
    _recenterController.forward(from: 0.0);
  }

  @override
  void initState() {
    super.initState();
    // Continuous 4-second sweep animation
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _recenterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _recenterController.addListener(() {
      _viewController.value = _recenterAnimation.value;
    });

    _windController = AnimationController(
       vsync: this,
       duration: const Duration(seconds: 5),
    )..repeat();

    _shootController = AnimationController(
       vsync: this,
       duration: const Duration(milliseconds: 500),
    );

    final controller = Get.find<NearbyController>();
    _pendingWorker = ever(controller.pendingRequestTarget, (target) {
      if (target != null) {
        _shootController.forward(from: 0.0);
      }
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    _recenterController.dispose();
    _windController.dispose();
    _shootController.dispose();
    _pendingWorker.dispose();
    _viewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<NearbyController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Local Radar'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.sensors),
            tooltip: 'Kinetic Bump',
            onPressed: () => Get.to(() => const KineticConnectScreen(), transition: Transition.cupertino),
          ),
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Run Load Test',
              onPressed: () {
                controller.runDeveloperLoadTest();
                Get.snackbar(
                  'Load Test Initiated',
                  'Injected 300 devices. Simulating +10 more every 3s...',
                  snackPosition: SnackPosition.BOTTOM,
                );
              },
            ),
          // Play / Pause toggle.
          Obx(() {
            final isScanning = controller.scanning.value;
            return IconButton(
              icon: Icon(isScanning ? Icons.pause_circle : Icons.play_circle),
              tooltip: isScanning ? 'Stop scanning' : 'Start scanning',
              onPressed: () {
                if (isScanning) {
                  controller.stopScanningAndBroadcasting();
                } else {
                  controller.startScanningAndBroadcasting();
                }
              },
            );
          }),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _initViewMatrix(constraints);
          });

          const double mapSize = 3000.0;
          final center = const Offset(mapSize / 2, mapSize / 2);
          final maxRadius = mapSize / 2 * 0.95;

          return Obx(() {
            // \u2500\u2500 Session Complete: show summary screen \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            if (controller.sessionComplete.value) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 80,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Session Complete',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        controller.sessionEndReason.value,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Stats row
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildStatColumn(
                              theme,
                              '${controller.sessionRequestsSent.value}',
                              'Requests\nSent',
                              Icons.send,
                            ),
                            Container(
                              width: 1,
                              height: 48,
                              color: theme.dividerColor,
                            ),
                            _buildStatColumn(
                              theme,
                              '${controller.sessionMutualConnections.value}',
                              'Connections\nMade',
                              Icons.people,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // New Session button — respects cooldown
                      Obx(() {
                        final cooling = controller.isCooldownActive;
                        final remaining = controller.cooldownRemaining.value;

                        return Column(
                          children: [
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: cooling
                                      ? theme.colorScheme.surfaceContainerHighest
                                      : theme.colorScheme.primary,
                                  foregroundColor: cooling
                                      ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                                      : Colors.black,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28),
                                  ),
                                ),
                                onPressed: cooling
                                    ? null
                                    : () {
                                        controller.users.clear();
                                        _cachedPositions.clear();
                                        controller.startScanningAndBroadcasting();
                                      },
                                icon: Icon(
                                  cooling ? Icons.timer_outlined : Icons.refresh,
                                ),
                                label: Text(
                                  cooling
                                      ? 'New Session in $remaining'
                                      : 'Start New Session',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              cooling
                                  ? 'Move to a new place or wait for the cooldown.'
                                  : 'Move to a new place for fresh limits.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              );
            }

            // \u2500\u2500 Idle: not scanning and no discovered users \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
            if (!controller.scanning.value && controller.users.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.radar,
                      size: 72,
                      color: theme.colorScheme.primary.withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Tap \u25b6 to activate sonar\nNo internet required.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            // The sweeping Radar Engine
            return Stack(
              fit: StackFit.expand,
              children: [
                InteractiveViewer(
                  transformationController: _viewController,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(
                    mapSize,
                  ), // let them pan around
                  minScale: 0.05,
                  maxScale: 10.0,
                  child: SizedBox(
                    width: mapSize,
                    height: mapSize,
                    child: Stack(
                      fit: StackFit.loose,
                      children: [
                        // 0. Virtual Space Grid Background
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: VirtualSpacePainter(
                                theme.colorScheme.primary.withValues(
                                  alpha: 0.08,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // 1. Base Sonar Sweep
                        AnimatedBuilder(
                          animation: _radarController,
                          builder: (_, __) => CustomPaint(
                            painter: RadarPainter(
                              _radarController.value,
                              theme.colorScheme.primary,
                            ),
                          ),
                        ),

                        // 2. Center User dot (Me) - Pulsing
                        Positioned(
                          left: center.dx - 12,
                          top: center.dy - 12,
                          child: AnimatedBuilder(
                            animation: _radarController,
                            builder: (context, child) {
                              // Gentle pulse between 1.0 and 1.3
                              final pulse =
                                  1.0 +
                                  math.sin(
                                        _radarController.value * 2 * math.pi,
                                      ) *
                                      0.15;
                              return Transform.scale(
                                scale: pulse,
                                child: child,
                              );
                            },
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.onSurface,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // X. The Red String of Fate
                        AnimatedBuilder(
                          animation: Listenable.merge([_windController, _shootController]),
                          builder: (_, __) {
                            return CustomPaint(
                              painter: RedStringPainter(
                                center: center,
                                cachedPositions: _cachedPositions,
                                users: controller.users.toList(),
                                controller: controller,
                                windProgress: _windController.value,
                                shootProgress: _shootController.value,
                                theme: theme,
                              ),
                            );
                          },
                        ),

                        // 3. Floating Blips (Other Users) with Anti-Overlap Calculation
                        ...() {
                          final placedRects = <Rect>[];

                          // Sync cache: Remove peers that are no longer discovered
                          final currentHashes = controller.users
                              .map((e) => e.myHash)
                              .toSet();
                          _cachedPositions.removeWhere(
                            (hash, _) => !currentHashes.contains(hash),
                          );

                          // Block previously cached positions so new devices don't land on them
                          for (final pos in _cachedPositions.values) {
                            placedRects.add(
                              Rect.fromCenter(
                                center: pos,
                                width: 64,
                                height: 64,
                              ),
                            );
                          }

                          // Sort users so overlap resolution happens in a deterministic order
                          final sortedUsers = controller.users.toList()
                            ..sort((a, b) => a.myHash.compareTo(b.myHash));

                          return sortedUsers.map((peer) {
                            if (_cachedPositions.containsKey(peer.myHash)) {
                              final pos = _cachedPositions[peer.myHash]!;
                              return _buildPositionedBlip(
                                pos.dx,
                                pos.dy,
                                peer,
                                theme,
                                controller,
                                _radarController,
                                context,
                                _buildRadarBlip,
                                _showPeerDetails,
                              );
                            }

                            // Normalize RSSI: -30 (close) to -100 (far)
                            double rawRssi = peer.rssi.toDouble();
                            double normalized =
                                (rawRssi + 30) / -70; // Map to [0.0, 1.0]
                            normalized = normalized.clamp(0.1, 1.0);

                            // Initial deterministic placement
                            double angleDegrees = (peer.myHash.hashCode % 360)
                                .toDouble();
                            double d = normalized * maxRadius;

                            double x = 0;
                            double y = 0;
                            bool overlapped = true;
                            int attempts = 0;

                            // Collision avoidance: Spiral outwards if overlapping
                            while (overlapped && attempts < 100) {
                              final angleRads =
                                  angleDegrees * (math.pi / 180.0);
                              x = center.dx + d * math.cos(angleRads);
                              y = center.dy + d * math.sin(angleRads);

                              final rect = Rect.fromCenter(
                                center: Offset(x, y),
                                width: 64, // Touch target + spacing
                                height: 64,
                              );

                              // Check overlap against previously placed avatars
                              overlapped = placedRects.any(
                                (r) => r.overlaps(rect),
                              );

                              if (overlapped) {
                                angleDegrees +=
                                    13.0; // Rotate a prime-ish amount
                                d +=
                                    5.0; // Spirals gently outward away from center
                                attempts++;
                              } else {
                                placedRects.add(rect);
                              }
                            }

                            if (overlapped) {
                              placedRects.add(
                                Rect.fromCenter(
                                  center: Offset(x, y),
                                  width: 64,
                                  height: 64,
                                ),
                              );
                            }

                            // Cache calculated position
                            _cachedPositions[peer.myHash] = Offset(x, y);

                            return _buildPositionedBlip(
                              x,
                              y,
                              peer,
                              theme,
                              controller,
                              _radarController,
                              context,
                              _buildRadarBlip,
                              _showPeerDetails,
                            );
                          });
                        }(),
                      ],
                    ),
                  ),
                ),

                // Fixed HUD Overlay: Scanning Indicator
                if (controller.scanning.value)
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.8,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.1,
                              ),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Scanning perimeter...',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // ── Non-blocking Incoming Request Banner ──────────────────
                if (controller.currentIncomingPeer.value != null)
                  Positioned(
                    bottom: 24,
                    left: 16,
                    right: 16,
                    child: _IncomingRequestBanner(
                      peer: controller.currentIncomingPeer.value!,
                      controller: controller,
                    ),
                  ),
              ],
            );
          });
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _recenter,
        tooltip: 'Recenter Radar',
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(
          Icons.my_location,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  /// Builds a stat column for the session-complete summary card.
  Widget _buildStatColumn(
    ThemeData theme,
    String value,
    String label,
    IconData icon,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 28, color: theme.colorScheme.primary),
        const SizedBox(height: 8),
        Text(
          value,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  /// Visual representation of a user hovering on the sonar grid.
  Widget _buildRadarBlip(
    DiscoveredPeer peer,
    ThemeData theme,
    NearbyController controller,
  ) {
    final isThisPeerPending = controller.isPeerPending(peer.myHash);

    return Stack(
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.primary, width: 2),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
          child: RemoteAvatarView(
            dna: peer.avatarDna,
            radius: 26,
          ),
        ),
        if (isThisPeerPending)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiary,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.hourglass_top,
                size: 12,
                color: theme.colorScheme.onTertiary,
              ),
            ),
          ),
      ],
    );
  }

  /// Spawns a sleek BottomSheet with the Bio and "Connect" button.
  void _showPeerDetails(
    BuildContext context,
    DiscoveredPeer peer,
    NearbyController controller,
  ) {
    final theme = Theme.of(context);
    final shortName = controller.displayPeerId(peer.myHash);
    final hasUsername =
        peer.offlineUsername != null && peer.offlineUsername!.trim().isNotEmpty;
    final displayTitle = hasUsername
        ? '@${peer.offlineUsername}'
        : 'User $shortName…';
    final bioLine = _buildBioSentence(peer);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Modal Handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Text(
                  displayTitle,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  bioLine.isEmpty ? 'Offline identity confirmed.' : bioLine,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Signal Strength: ${peer.rssi} dBm',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 32),

                Obx(() {
                  final isThisPeerPending = controller.isPeerPending(
                    peer.myHash,
                  );
                  final isAnyPending =
                      controller.pendingRequestTarget.value != null;
                  final status = controller.connectionStatusForPeer(
                    peer.myHash,
                  );
                  final canAdd = controller.canAddConnection(peer.myHash);
                  final isConnected = status == ConnectionStatus.accepted;

                  String label;
                  IconData icon;
                  if (isThisPeerPending ||
                      status == ConnectionStatus.pendingOutgoing) {
                    label = 'Request Already Sent';
                    icon = Icons.hourglass_top;
                  } else if (status == ConnectionStatus.accepted) {
                    label = 'Chat';
                    icon = Icons.chat_bubble;
                  } else if (status == ConnectionStatus.pendingIncoming) {
                    label = 'Incoming Request Pending';
                    icon = Icons.mark_email_unread;
                  } else if (status == ConnectionStatus.blocked) {
                    label = 'Connection Unavailable';
                    icon = Icons.block;
                  } else if (isAnyPending) {
                    label = 'Another Connection in Progress';
                    icon = Icons.hourglass_top;
                  } else {
                    label = 'Add Connection';
                    icon = Icons.person_add;
                  }

                  return SizedBox(
                    width: double.infinity,
                    height: 64, // Taller button
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor:
                            Colors.black, // High contrast text on yellow
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(32),
                        ),
                      ),
                      onPressed: (canAdd && !isAnyPending)
                          ? () {
                              controller.sendConnectionRequest(peer.myHash);
                              Navigator.pop(context); // Close sheet elegantly
                            }
                          : isConnected
                          ? () {
                              final shortId = controller.displayPeerId(
                                peer.myHash,
                              );
                              Navigator.pop(context);
                              Get.to(
                                () => ChatScreen(
                                  otherOfflineId: peer.myHash,
                                  otherDisplayName: 'User $shortId…',
                                ),
                                transition: Transition.cupertino,
                              );
                            }
                          : null,
                      icon: Icon(icon, size: 24),
                      label: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  String _buildBioSentence(DiscoveredPeer peer) {
    final colors = [
      'None',
      'Black',
      'White',
      'Gray',
      'Red',
      'Blue',
      'Green',
      'Yellow',
      'Orange',
      'Purple',
      'Pink',
      'Brown',
      'Beige',
      'Multicolor',
      'Denim',
      'Other',
    ];
    String desc = '';
    final top = peer.topWearColor;
    final bottom = peer.bottomWearColor;
    if (top > 0 || bottom > 0) {
      desc += 'Wearing ';
      if (top > 0) desc += 'a ${colors[top].toLowerCase()} top';
      if (top > 0 && bottom > 0) desc += ' and ';
      if (bottom > 0) desc += 'a ${colors[bottom].toLowerCase()} bottom';
      desc += '. ';
    }

    return desc.isEmpty ? 'No outfit details shared.' : desc.trim();
  }
}

/// Draws the static concentric distance rings and the animated sonar beam.
class RadarPainter extends CustomPainter {
  final double sweepProgress;
  final Color baseColor;

  RadarPainter(this.sweepProgress, this.baseColor);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) * 0.45;

    final ringPaint = Paint()
      ..color = baseColor.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // 3 Distance Rings
    canvas.drawCircle(center, maxRadius * 0.33, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.66, ringPaint);
    canvas.drawCircle(center, maxRadius, ringPaint);

    // Sweeping Radar Cone
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          baseColor.withValues(alpha: 0.0),
          baseColor.withValues(alpha: 0.1),
          baseColor.withValues(alpha: 0.5),
          baseColor.withValues(alpha: 0.0), // sharp cutoff
        ],
        stops: const [0.0, 0.5, 0.95, 1.0],
        transform: GradientRotation(sweepProgress * 2 * math.pi),
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: maxRadius),
      sweepProgress * 2 * math.pi - math.pi / 2, // Rotate to spin around
      math.pi / 2, // 90 degree sweep cone
      true,
      sweepPaint,
    );
  }

  @override
  bool shouldRepaint(RadarPainter oldDelegate) =>
      oldDelegate.sweepProgress != sweepProgress ||
      oldDelegate.baseColor != baseColor;
}

/// Draws a very subtle, modern tech-grid representing the "virtual space" plane.
class VirtualSpacePainter extends CustomPainter {
  final Color gridColor;

  VirtualSpacePainter(this.gridColor);

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw a deep radial gradient for a void-like background
    final bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          gridColor.withValues(
            alpha: gridColor.a * 2.0,
          ), // Center slightly lighter
          const Color(0xFF000000), // Fade to pure black at edges
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // 2. Draw the grid
    const double gridSize = 100.0;

    final paint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Draw vertical lines
    for (double x = 0; x <= size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Draw horizontal lines
    for (double y = 0; y <= size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Add small crosses or dots at intersections to make it look futuristic
    final crossPaint = Paint()
      ..color = gridColor.withValues(alpha: gridColor.a * 1.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (double x = gridSize; x < size.width; x += gridSize) {
      for (double y = gridSize; y < size.height; y += gridSize) {
        canvas.drawLine(Offset(x - 5, y), Offset(x + 5, y), crossPaint);
        canvas.drawLine(Offset(x, y - 5), Offset(x, y + 5), crossPaint);
      }
    }
  }

  @override
  bool shouldRepaint(VirtualSpacePainter oldDelegate) =>
      oldDelegate.gridColor != gridColor;
}

/// A non-blocking banner that appears at the bottom of the radar when
/// someone sends a connection request. Unlike a modal dialog, the user
/// can still interact with the radar while this is visible.
class _IncomingRequestBanner extends StatelessWidget {
  final DiscoveredPeer peer;
  final NearbyController controller;

  const _IncomingRequestBanner({
    required this.peer,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUsername =
        peer.offlineUsername != null && peer.offlineUsername!.trim().isNotEmpty;
    final displayName = hasUsername
        ? '@${peer.offlineUsername}'
        : 'User ${controller.displayPeerId(peer.myHash)}…';

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.4),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              blurRadius: 20,
              spreadRadius: 4,
              offset: const Offset(0, -4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                backgroundImage: ResizeImage(
                  AssetImage(AppAssets.getAvatarPath(peer.avatarDna)),
                  width: 96,
                  height: 96,
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Name + label
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Wants to connect',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // Ignore button
            IconButton(
              onPressed: controller.ignoreCurrentIncoming,
              icon: Icon(
                Icons.close,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              tooltip: 'Ignore',
              style: IconButton.styleFrom(
                backgroundColor:
                    theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(width: 8),

            // Accept button
            FilledButton(
              onPressed: controller.acceptCurrentIncoming,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              child: const Text(
                'Accept',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildPositionedBlip(
  double x,
  double y,
  DiscoveredPeer peer,
  ThemeData theme,
  NearbyController controller,
  AnimationController radarController,
  BuildContext context,
  Widget Function(DiscoveredPeer, ThemeData, NearbyController) blipBuilder,
  void Function(BuildContext, DiscoveredPeer, NearbyController) tapHandler,
) {
  return Positioned(
    left: x - 24, // Assuming avatar is 48x48 bounds visually
    top: y - 24,
    child: AnimatedBuilder(
      animation: radarController,
      builder: (context, child) {
        // Deterministic phase so they bob independently
        final phase = (peer.myHash.hashCode % 100) / 100.0 * 2 * math.pi;
        // Gentle bobbing effect
        final floatY =
            math.sin(radarController.value * 2 * math.pi + phase) * 8.0;
        return Transform.translate(offset: Offset(0, floatY), child: child);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => tapHandler(context, peer, controller),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: blipBuilder(peer, theme, controller),
        ),
      ),
    ),
  );
}

/// Draws an animated, fluttering Red String of Fate between you (center)
/// and any connected (or pending) users.
class RedStringPainter extends CustomPainter {
  final Offset center;
  final Map<String, Offset> cachedPositions;
  final List<DiscoveredPeer> users;
  final NearbyController controller;
  final double windProgress;
  final double shootProgress;
  final ThemeData theme;

  RedStringPainter({
    required this.center,
    required this.cachedPositions,
    required this.users,
    required this.controller,
    required this.windProgress,
    required this.shootProgress,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintGlow = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final paintCore = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    for (final peer in users) {
      final status = controller.connectionStatusForPeer(peer.myHash);

      bool isConnected = status == ConnectionStatus.accepted;
      bool isPending = status == ConnectionStatus.pendingOutgoing;

      if (!isConnected && !isPending) continue;

      final targetPos = cachedPositions[peer.myHash];
      if (targetPos == null) continue;

      final p0 = center;
      final p3 = targetPos;

      // Calculate vector from center to peer
      double dx = p3.dx - p0.dx;
      double dy = p3.dy - p0.dy;
      double dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1.0) continue;

      // Normal vector (perpendicular)
      double nx = -dy / dist;
      double ny = dx / dist;

      // Organic sway math
      double sag = dist * 0.15; // Natural gravity/slack

      // Wind flutter (composed of two sin waves for organic chaos)
      double flutter1 = math.sin(windProgress * math.pi * 2 + peer.myHash.hashCode) * (dist * 0.06);
      double flutter2 = math.cos(windProgress * math.pi * 4 - peer.myHash.hashCode) * (dist * 0.03);

      double totalOffset = sag + flutter1 + flutter2;

      // Control points for cubic bezier, shifted along the normal
      final p1 = Offset(p0.dx + dx * 0.33 + nx * totalOffset, p0.dy + dy * 0.33 + ny * totalOffset);
      final p2 = Offset(p0.dx + dx * 0.66 + nx * (totalOffset * 0.8), p0.dy + dy * 0.66 + ny * (totalOffset * 0.8));

      final path = Path()
        ..moveTo(p0.dx, p0.dy)
        ..cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, p3.dx, p3.dy);

      Path pathToDraw = path;

      // If pending, use shootProgress to extract partial path
      if (isPending) {
        final metrics = path.computeMetrics().toList();
        if (metrics.isNotEmpty) {
          final metric = metrics.first;
          // Apply a fast ease-out effect to the shoot progress
          final curveProgress = Curves.easeOutCubic.transform(shootProgress);
          pathToDraw = metric.extractPath(0.0, metric.length * curveProgress);
        }
      }

      // Draw string
      canvas.drawPath(pathToDraw, paintGlow);
      canvas.drawPath(pathToDraw, paintCore);
    }
  }

  @override
  bool shouldRepaint(RedStringPainter oldDelegate) => true;
}

