import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/models/connection.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';
import '../connections/connections_screen.dart';
import 'chat_screen.dart';

/// Dedicated inbox screen showing all chat conversations.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  late Future<void> _seedFuture;
  final Map<String, DateTime> _acceptedAtByPeer = {};
  List<Connection> _acceptedConnections = const [];

  void _retryCloudChats() {
    setState(() {
      _seedFuture = _seedChatsFromAcceptedConnections();
    });
  }

  String _canonicalPeerId(String id) {
    final clean = id.trim().toLowerCase();
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
    if (isHex && clean.length <= 12) {
      return clean.length <= 10 ? clean : clean.substring(0, 10);
    }
    return clean;
  }

  String? _otherIdFromConversationDoc(
    QueryDocumentSnapshot<Object?> doc,
    String myId,
  ) {
    final data = (doc.data() as Map<String, dynamic>?);
    if (data == null) return null;

    final myKey = FirebaseSyncService.canonicalChatKey(myId);

    // Prefer raw participant IDs when present so we pass the same peer ID
    // shape used by Connections screen (full ID when available).
    final rawParticipants =
        (data['participantsRaw'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    if (rawParticipants.isNotEmpty) {
      final rawOthers = rawParticipants
          .where(
            (p) =>
                p.trim().isNotEmpty &&
                p != myId &&
                FirebaseSyncService.canonicalChatKey(p) != myKey,
          )
          .toList();
      if (rawOthers.isNotEmpty) return rawOthers.first;
    }

    final participants =
        (data['participants'] as List?)?.cast<String>() ?? const <String>[];
    final others = participants
        .where((p) => FirebaseSyncService.canonicalChatKey(p) != myKey)
        .toList();
    if (others.isEmpty) return null;
    return others.first;
  }

  DateTime _effectiveSortTime(QueryDocumentSnapshot<Object?> doc, String myId) {
    final data = (doc.data() as Map<String, dynamic>?);
    final ts = data?['lastMessageAt'];
    if (ts is Timestamp) return ts.toDate();

    final otherId = _otherIdFromConversationDoc(doc, myId);
    if (otherId != null) {
      final fromConnection = _acceptedAtByPeer[_canonicalPeerId(otherId)];
      if (fromConnection != null) return fromConnection;
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  void initState() {
    super.initState();
    _seedFuture = _seedChatsFromAcceptedConnections();
  }

  Future<void> _seedChatsFromAcceptedConnections() async {
    final firebase = Get.find<FirebaseSyncService>();
    final db = Get.find<LocalDbService>();
    final identity = Get.find<IdentityService>().identity;
    final myId = identity.offlineId;

    try {
      final accepted = await db.getConnections(
        status: ConnectionStatus.accepted,
      );
      _acceptedConnections = accepted;

      final acceptedMap = <String, DateTime>{};
      for (final conn in accepted) {
        acceptedMap[_canonicalPeerId(conn.otherOfflineId)] = conn.firstMetAt;
      }

      _acceptedAtByPeer
        ..clear()
        ..addAll(acceptedMap);

      // Best effort: when Firebase is ready, seed conversations for accepted users.
      if (firebase.isFirebaseAvailable) {
        if (!firebase.isSignedIn) {
          final signedIn = await firebase.signInAnonymously(identity);
          if (!signedIn) return;
        }
        for (final conn in accepted) {
          await firebase.ensureConversation(myId, conn.otherOfflineId);
        }
      }
    } catch (e) {
      Get.log('ChatsScreen: seed from accepted connections failed – $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firebase = Get.find<FirebaseSyncService>();
    final myId = Get.find<IdentityService>().identity.offlineId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Refresh chats',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _seedFuture = _seedChatsFromAcceptedConnections();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _seedFuture,
        builder: (_, __) => _buildBody(theme, firebase, myId),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    FirebaseSyncService firebase,
    String myId,
  ) {
    if (!firebase.isFirebaseAvailable || !firebase.isSignedIn) {
      return _buildLocalAcceptedFallback(
        theme,
        helperText:
            'Showing your connected friends. Cloud sync is still initializing.',
      );
    }

    final stream = firebase.conversationsStream(myId);
    if (stream == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          Get.log(
            'ChatsScreen: conversations stream failed – ${snapshot.error}',
          );
          return _buildLocalAcceptedFallback(
            theme,
            helperText:
                'Cloud chat list is temporarily unavailable. Showing connected users instead.',
            onRetry: _retryCloudChats,
          );
        }

        final docs =
            List<QueryDocumentSnapshot<Object?>>.from(
              snapshot.data?.docs ?? const <QueryDocumentSnapshot<Object?>>[],
            )..sort(
              (a, b) => _effectiveSortTime(
                b,
                myId,
              ).compareTo(_effectiveSortTime(a, myId)),
            );
        if (docs.isEmpty) {
          return Center(
            child: Text(
              'No chats yet.\nConnect with someone and start messaging.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          );
        }

        return ListView.builder(
          itemCount: docs.length,
          padding: const EdgeInsets.only(top: 8, bottom: 84), // Avoid nav bar overlap
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = (doc.data() as Map<String, dynamic>?) ?? {};
            final otherId = _otherIdFromConversationDoc(doc, myId);

            if (otherId == null || otherId.isEmpty) {
              return const SizedBox.shrink();
            }

            final shortId = otherId.length > 8
                ? otherId.substring(0, 8)
                : otherId;
            final lastMessage = (data['lastMessage'] as String?)?.trim();
            final lastMessageText = (lastMessage == null || lastMessage.isEmpty)
                ? 'Say hello 👋'
                : lastMessage;

            final ts = data['lastMessageAt'];
            DateTime? at;
            if (ts is Timestamp) at = ts.toDate();
            at ??= _acceptedAtByPeer[_canonicalPeerId(otherId)];

            return Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                leading: ConnectedAvatar(offlineId: otherId, shortId: shortId),
                title: ConnectedName(
                  offlineId: otherId,
                  fallback: 'User $shortId…',
                ),
                subtitle: Text(
                  lastMessageText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    fontSize: 14,
                  ),
                ),
                trailing: at == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text(
                          _formatTime(at),
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            fontWeight: FontWeight.w500,
                            fontSize: 12,
                          ),
                        ),
                      ),
                onTap: () {
                  Get.to(
                    () => ChatScreen(
                      otherOfflineId: otherId,
                      otherDisplayName: 'User $shortId…',
                    ),
                    transition: Transition.cupertino,
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLocalAcceptedFallback(
    ThemeData theme, {
    String? helperText,
    VoidCallback? onRetry,
  }) {
    if (_acceptedConnections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                helperText ?? 'No connected users yet.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry cloud chats'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final list = ListView.separated(
      itemCount: _acceptedConnections.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemBuilder: (context, index) {
        final conn = _acceptedConnections[index];
        final otherId = conn.otherOfflineId;
        final shortId = otherId.length > 8 ? otherId.substring(0, 8) : otherId;

        return Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),
            leading: ConnectedAvatar(offlineId: otherId, shortId: shortId),
            title: ConnectedName(
              offlineId: otherId,
              fallback: 'User $shortId…',
            ),
            subtitle: Text('Connected • ${_formatTime(conn.firstMetAt)}'),
            onTap: () {
              Get.to(
                () => ChatScreen(
                  otherOfflineId: otherId,
                  otherDisplayName: 'User $shortId…',
                ),
                transition: Transition.cupertino,
              );
            },
          ),
        );
      },
    );

    if (onRetry == null) return list;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      helperText ?? 'Cloud chat list unavailable.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  String _formatTime(DateTime at) {
    final now = DateTime.now();
    final diff = now.difference(at);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
