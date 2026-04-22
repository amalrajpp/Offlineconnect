import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/constants/assets.dart';
import '../../core/models/connection.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/local_db_service.dart';
import '../chat/chat_screen.dart';
import 'connections_controller.dart';
import '../../core/services/identity_service.dart';

/// Displays the list of accepted (and pending) connections from the local DB.
///
/// - Accepted connections show the other user's profile photo (fetched from
///   Firestore) and navigate to the chat screen on tap.
/// - Pending connections show generic icons without photos.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ConnectionsController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        centerTitle: true,
        actions: [
          if (kDebugMode)
            IconButton(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Run Load Test',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Developer Stress Test'),
                    content: const Text(
                      'Inject 1,000 mock offline users and 500 connections to test scrolling, memory, and database scaling?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Inject Load'),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;
                Get.snackbar(
                  'Load Test',
                  'Injecting mock data... wait a moment.',
                  snackPosition: SnackPosition.BOTTOM,
                );
                final identity = Get.find<IdentityService>().identity;
                await Get.find<LocalDbService>().runDeveloperLoadTest(
                  identity.offlineId,
                );
                controller.loadConnections();
                Get.snackbar(
                  'Success',
                  'Injected 500 Connections and 1000 Users.',
                  snackPosition: SnackPosition.BOTTOM,
                  duration: const Duration(seconds: 4),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => controller.loadConnections(),
          ),
        ],
      ),
      body: Obx(() {
        final maxLimit = controller.maxConnectionsPerDay;
        final used = controller.connectionsMadeToday.value;
        final remaining = (maxLimit - used).clamp(0, maxLimit);
        final resetsIn = controller.formattedResetTime;

        final limitBanner = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: remaining > 0
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: remaining > 0
                    ? theme.colorScheme.primary.withValues(alpha: 0.3)
                    : theme.colorScheme.error.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  remaining > 0
                      ? Icons.battery_charging_full
                      : Icons.battery_alert,
                  color: remaining > 0
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connections Today: $used / $maxLimit',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        remaining > 0
                            ? '$remaining connections remaining'
                            : 'Limit reached. Resets in $resetsIn',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

        if (controller.connections.isEmpty) {
          return Column(
            children: [
              limitBanner,
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.radar_outlined,
                        size: 80,
                        color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Your radar is completely quiet.\nSwitch to "Nearby" to start scanning.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        final connected = controller.connections
            .where((c) => c.status == ConnectionStatus.accepted)
            .toList();
        final sentRequests = controller.connections
            .where((c) => c.status == ConnectionStatus.pendingOutgoing)
            .toList();
        final receivedRequests = controller.connections
            .where((c) => c.status == ConnectionStatus.pendingIncoming)
            .toList();
        final blocked = controller.connections
            .where((c) => c.status == ConnectionStatus.blocked)
            .toList();

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: limitBanner,
              ),
            ),
            if (connected.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildSectionHeader('Connected', connected.length),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildConnectionTile(context, connected[index], true),
                  childCount: connected.length,
                ),
              ),
            ],
            if (sentRequests.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Sent Requests',
                  sentRequests.length,
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildConnectionTile(context, sentRequests[index], false),
                  childCount: sentRequests.length,
                ),
              ),
            ],
            if (receivedRequests.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildSectionHeader(
                  'Received Requests',
                  receivedRequests.length,
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildConnectionTile(
                    context,
                    receivedRequests[index],
                    false,
                  ),
                  childCount: receivedRequests.length,
                ),
              ),
            ],
            if (blocked.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildSectionHeader('Blocked', blocked.length),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildConnectionTile(context, blocked[index], false),
                  childCount: blocked.length,
                ),
              ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 20)),
          ],
        );
      }),
    );
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 8),
          Text(
            '($count)',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionTile(
    BuildContext context,
    Connection conn,
    bool isAccepted,
  ) {
    final controller = Get.find<ConnectionsController>();
    final theme = Theme.of(context);
    final isBusy = controller.isRequestActionBusy(conn.id);
    final shortId = conn.otherOfflineId.length >= 8
        ? conn.otherOfflineId.substring(0, 8)
        : conn.otherOfflineId;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isAccepted
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        leading: isAccepted
            ? Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: ConnectedAvatar(
                  offlineId: conn.otherOfflineId,
                  shortId: shortId,
                ),
              )
            : Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _statusColor(
                    conn.status,
                    theme,
                  ).withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _statusIcon(conn.status),
                  color: _statusColor(conn.status, theme),
                  size: 20,
                ),
              ),
        title: isAccepted
            ? ConnectedName(
                offlineId: conn.otherOfflineId,
                fallback: 'User $shortId…',
              )
            : Text(
                'User $shortId…',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
        subtitle: Text(
          '${_statusLabel(conn.status)}  •  ${_formatDate(conn.firstMetAt)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        trailing: isAccepted
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(
                      Icons.chat_bubble_rounded,
                      size: 18,
                      color: Colors.black,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Chat',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            : conn.status == ConnectionStatus.pendingIncoming
            ? Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: isBusy
                        ? null
                        : () => controller.ignoreIncomingRequest(conn),
                    child: Text(isBusy ? 'Ignoring…' : 'Ignore'),
                  ),
                  FilledButton(
                    onPressed: isBusy
                        ? null
                        : () => controller.acceptIncomingRequest(conn),
                    child: isBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Accept'),
                  ),
                ],
              )
            : null,
        onTap: isAccepted
            ? () {
                Get.to(
                  () => ChatScreen(
                    otherOfflineId: conn.otherOfflineId,
                    otherDisplayName: 'User $shortId…',
                  ),
                  transition: Transition.cupertino,
                );
              }
            : null,
      ),
    );
  }

  // ── Helpers ──

  Color _statusColor(ConnectionStatus status, ThemeData theme) {
    switch (status) {
      case ConnectionStatus.accepted:
        return Colors.green;
      case ConnectionStatus.pendingOutgoing:
        return Colors.orange;
      case ConnectionStatus.pendingIncoming:
        return Colors.blue;
      case ConnectionStatus.blocked:
        return Colors.red;
    }
  }

  IconData _statusIcon(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.accepted:
        return Icons.check;
      case ConnectionStatus.pendingOutgoing:
        return Icons.arrow_upward;
      case ConnectionStatus.pendingIncoming:
        return Icons.arrow_downward;
      case ConnectionStatus.blocked:
        return Icons.block;
    }
  }

  String _statusLabel(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.accepted:
        return 'Connected';
      case ConnectionStatus.pendingOutgoing:
        return 'Request sent';
      case ConnectionStatus.pendingIncoming:
        return 'Incoming request';
      case ConnectionStatus.blocked:
        return 'Blocked';
    }
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Fetches and displays the connected user's profile photo.
///
/// Photos are only visible after mutual connection (privacy-first).
class ConnectedAvatar extends StatelessWidget {
  final String offlineId;
  final String shortId;

  const ConnectedAvatar({
    super.key,
    required this.offlineId,
    required this.shortId,
  });

  Future<Map<String, dynamic>> _resolveProfile() async {
    final localDb = Get.find<LocalDbService>();
    final localProfile = await localDb.getKnownUser(offlineId);

    String? photoUrl = localProfile?.photoUrl;
    int avatarId = localProfile?.avatarId ?? 0;
    bool hasProfile = localProfile != null;

    final firebase = Get.find<FirebaseSyncService>();
    if (firebase.isFirebaseAvailable) {
      final cloudProfile = await firebase.fetchProfile(offlineId);
      if (cloudProfile != null) {
        hasProfile = true;
        photoUrl = cloudProfile.photoUrl ?? photoUrl;
        avatarId = cloudProfile.avatarId;
      }
    }

    return {
      'hasProfile': hasProfile,
      'photoUrl': photoUrl,
      'avatarId': avatarId,
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _resolveProfile(),
      builder: (context, snapshot) {
        final data = snapshot.data;
        final hasProfile = data?['hasProfile'] == true;
        final photoUrl = data?['photoUrl'] as String?;
        final avatarId = (data?['avatarId'] as int?) ?? 0;

        if (photoUrl != null) {
          return CircleAvatar(
            backgroundImage: CachedNetworkImageProvider(photoUrl),
          );
        }

        return CircleAvatar(
          backgroundColor: Colors.green,
          backgroundImage: hasProfile
              ? ResizeImage(
                  AssetImage(AppAssets.getAvatarPath(avatarId)),
                  width: 96,
                  height: 96,
                )
              : null,
          child: !hasProfile
              ? Text(
                  shortId.substring(0, 2).toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// Fetches and displays the connected user's display name from local DB or Firestore.
class ConnectedName extends StatelessWidget {
  final String offlineId;
  final String fallback;

  const ConnectedName({
    super.key,
    required this.offlineId,
    required this.fallback,
  });

  Future<String?> _resolveName() async {
    final localDb = Get.find<LocalDbService>();
    final localProfile = await localDb.getKnownUser(offlineId);
    if (localProfile != null && localProfile.displayName.isNotEmpty) {
      return localProfile.displayName;
    }

    final firebase = Get.find<FirebaseSyncService>();
    if (firebase.isFirebaseAvailable) {
      final cloudProfile = await firebase.fetchProfile(offlineId);
      if (cloudProfile != null && cloudProfile.displayName.isNotEmpty) {
        return cloudProfile.displayName;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _resolveName(),
      builder: (context, snapshot) {
        final name = snapshot.data;
        return Text(
          name ?? fallback,
          style: const TextStyle(fontWeight: FontWeight.w600),
        );
      },
    );
  }
}
