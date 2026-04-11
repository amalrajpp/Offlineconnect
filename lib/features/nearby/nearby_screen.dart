import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/models/ble_models.dart';
import '../../core/models/connection.dart';
import '../../core/constants/interests_map.dart';
import '../../core/constants/assets.dart';
import '../chat/chat_screen.dart';
import 'nearby_controller.dart';

/// Displays nearby BLE peers discovered via the Zero-GATT protocol
/// using an interactive 2D Gamified Sonar Radar.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    // Continuous 4-second sweep animation
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _radarController.dispose();
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
          final center = Offset(
            constraints.maxWidth / 2,
            constraints.maxHeight / 2,
          );
          final maxRadius =
              math.min(constraints.maxWidth, constraints.maxHeight) * 0.45;

          return Obx(() {
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
                      'Tap ▶ to activate sonar\nNo internet required.',
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

                // 2. Center User dot (Me)
                Positioned(
                  left: center.dx - 12,
                  top: center.dy - 12,
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

                // 3. Floating Blips (Other Users)
                ...controller.users.map((peer) {
                  // Normalize RSSI: -30 (close) to -100 (far)
                  double rawRssi = peer.rssi.toDouble();
                  double normalized = (rawRssi + 30) / -70; // Map to [0.0, 1.0]
                  normalized = normalized.clamp(0.1, 1.0);

                  // Deterministic Sector Placement via MyHash
                  final angleDegrees = peer.myHash.hashCode % 360;
                  final angleRads = angleDegrees * (math.pi / 180.0);

                  final d = normalized * maxRadius;
                  final x = center.dx + d * math.cos(angleRads);
                  final y = center.dy + d * math.sin(angleRads);

                  return Positioned(
                    left: x - 24, // Assuming avatar is 48x48
                    top: y - 24,
                    child: GestureDetector(
                      onTap: () => _showPeerDetails(context, peer, controller),
                      child: _buildRadarBlip(peer, theme, controller),
                    ),
                  );
                }),

                // Scanning Text Overlay (if empty but scanning)
                if (controller.users.isEmpty)
                  Positioned(
                    bottom: 40,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        'Scanning perimeter...',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          });
        },
      ),
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
          child: CircleAvatar(
            radius: 26,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            backgroundImage: AssetImage(AppAssets.getAvatarPath(peer.avatarId)),
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

    final category = getFieldName(peer.fieldId);
    final subCategory = getSubfieldName(peer.fieldId, peer.subfieldId);

    return '$desc Currently into: $category -> $subCategory'.trim();
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
