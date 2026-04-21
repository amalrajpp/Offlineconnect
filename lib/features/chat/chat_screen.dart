import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/constants/assets.dart';
import '../../core/services/identity_service.dart';
import 'chat_controller.dart';

/// Real-time chat screen powered by Firestore.
///
/// Shows message bubbles (sent = right/primary, received = left/grey),
/// a text input field, and auto-scrolls to the latest message.
/// Profile photo is shown in the app bar — only visible because this
/// screen is only reachable for mutually accepted connections.
class ChatScreen extends StatefulWidget {
  /// The other party's offline ID.
  final String otherOfflineId;

  /// The display name to show in the app bar (fallback to hash).
  final String otherDisplayName;

  const ChatScreen({
    super.key,
    required this.otherOfflineId,
    required this.otherDisplayName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Register a unique controller for this conversation.
    _controller = Get.put(
      ChatController(otherOfflineId: widget.otherOfflineId),
      tag: widget.otherOfflineId,
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    Get.delete<ChatController>(tag: widget.otherOfflineId);
    super.dispose();
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _controller.sendMessage(text);
    _textController.clear();
  }

  void _showReportDialog(BuildContext context) {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report User/Content'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Please describe the abusive behavior, harassment, or objectionable content.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                hintText: 'Reason for reporting...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final reason = reasonController.text.trim();
              if (reason.isNotEmpty) {
                Navigator.pop(ctx);
                _controller.reportUser(reason);
              }
            },
            child: const Text('Submit Report'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myId = Get.find<IdentityService>().identity.offlineId;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Obx(() {
          final profile = _controller.otherProfile.value;
          final photoUrl = profile?.photoUrl;
          final avatarId = profile?.avatarId ?? 0;
          final name = profile?.displayName ?? widget.otherDisplayName;

          return Row(
            children: [
              // Photo — only shown for connected users (privacy-first).
              CircleAvatar(
                radius: 18,
                backgroundColor: theme.colorScheme.primaryContainer,
                backgroundImage: photoUrl != null
                    ? CachedNetworkImageProvider(photoUrl)
                    : ResizeImage(
                            AssetImage(AppAssets.getAvatarPath(avatarId)),
                            width: 144,
                            height: 144,
                          )
                          as ImageProvider,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, overflow: TextOverflow.ellipsis),
                    if (profile?.bio != null)
                      Text(
                        profile!.bio!,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        }),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'block') _controller.blockUser();
              if (value == 'report') _showReportDialog(context);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'block',
                child: Text('Block User', style: TextStyle(color: Colors.red)),
              ),
              const PopupMenuItem(
                value: 'report',
                child: Text('Report Content'),
              ),
            ],
          ),
        ],
      ),
      body: Obx(() {
        // ── Firebase not available ──
        if (!_controller.isAvailable.value) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off,
                    size: 64,
                    color: theme.colorScheme.error.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Chat requires an internet connection.\n'
                    'Connect to Wi-Fi or mobile data to start messaging.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // ── Loading ──
        if (_controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        // Auto-scroll when messages change.
        // No longer needed due to `reverse: true` anchoring to bottom.

        final reversedMessages = _controller.messages.reversed.toList();

        return Column(
          children: [
            // ── Messages list ──
            Expanded(
              child: reversedMessages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet.\nSay hello! 👋',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true, // Anchor to bottom
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      itemCount: reversedMessages.length,
                      itemBuilder: (context, index) {
                        final msg = reversedMessages[index];
                        final isMine = msg.senderId == myId;

                        return _MessageBubble(
                          text: msg.text,
                          time: msg.createdAt,
                          isMine: isMine,
                          isRead: msg.readAt != null,
                          status: msg.status,
                        );
                      },
                    ),
            ),

            // ── Floating Input bar ──
            Container(
              margin: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      textCapitalization: TextCapitalization.sentences,
                      maxLines: 4,
                      minLines: 1,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        filled: false,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.3,
                          ),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton(
                      onPressed: _send,
                      icon: const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// A single chat message bubble.
class _MessageBubble extends StatelessWidget {
  final String text;
  final DateTime time;
  final bool isMine;
  final bool isRead;
  final String status;

  const _MessageBubble({
    required this.text,
    required this.time,
    required this.isMine,
    required this.isRead,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPending = status == 'pending';

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: isMine && isPending ? 0.6 : 1.0,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isMine
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isMine ? 20 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 20),
            ),
            boxShadow: [
              if (isMine && !isPending)
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                text,
                style: TextStyle(
                  color: isMine
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isMine
                          ? theme.colorScheme.onPrimary.withValues(alpha: 0.7)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Icon(
                        isPending
                            ? Icons.access_time
                            : (isRead ? Icons.done_all : Icons.check),
                        key: ValueKey<String>('$status-$isRead'),
                        size: 14,
                        color: isRead && !isPending
                            ? Colors.white
                            : theme.colorScheme.onPrimary.withValues(
                                alpha: 0.8,
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
