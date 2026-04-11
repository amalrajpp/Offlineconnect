import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get/get.dart';

import '../../core/models/message.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';

/// Manages a single chat conversation with real-time Firestore updates.
///
/// Each instance is bound to a specific conversation between the current
/// user and [otherOfflineId].
class ChatController extends GetxController {
  final FirebaseSyncService _firebase = Get.find<FirebaseSyncService>();
  final IdentityService _identity = Get.find<IdentityService>();

  /// The other party's offline ID.
  final String otherOfflineId;

  /// The deterministic conversation ID.
  late final String conversationId;

  /// Legacy + canonical conversation IDs used to avoid split threads.
  late final List<String> _conversationCandidates;

  /// Selected write target conversation ID.
  late String _activeConversationId;

  /// The other user's profile (fetched from Firestore).
  final Rx<UserProfile?> otherProfile = Rx<UserProfile?>(null);

  /// The list of messages, updated in real-time.
  final RxList<Message> messages = <Message>[].obs;

  /// Whether the chat is available (Firebase is connected).
  final RxBool isAvailable = false.obs;

  /// Whether messages are loading.
  final RxBool isLoading = true.obs;

  final List<StreamSubscription<QuerySnapshot>> _messageSubs = [];
  final Map<String, Message> _mergedMessages = {};
  final Map<String, Set<String>> _docKeysByConversation = {};
  Timer? _silentRetryTimer;
  bool _initInProgress = false;
  bool _streamsStarted = false;
  int _silentRetryAttempts = 0;
  bool _previewFallbackInProgress = false;
  bool _previewFallbackAttempted = false;
  List<String> _listeningConversationIds = const [];

  static const int _maxSilentRetries = 2;
  static const Duration _silentRetryDelay = Duration(seconds: 2);

  String get _myId => _identity.identity.offlineId;

  ChatController({required this.otherOfflineId});

  @override
  void onInit() {
    super.onInit();
    conversationId = FirebaseSyncService.conversationId(_myId, otherOfflineId);
    _conversationCandidates = FirebaseSyncService.conversationIdCandidates(
      _myId,
      otherOfflineId,
    );
    _activeConversationId = conversationId;
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initInProgress || _streamsStarted) return;
    _initInProgress = true;

    try {
      final ready = await _firebase.ensureFirebaseReady();
      if (!ready) {
        isAvailable.value = false;
        isLoading.value = false;
        return;
      }

      // Firebase is initialized, so chat should not show the hard offline banner
      // even if anonymous auth is still warming up (common iOS cold-start race).
      isAvailable.value = true;

      // iOS can occasionally reach this screen before background auth finishes.
      // Attempt a local sign-in retry instead of showing a false "offline" state.
      final signedIn = await _firebase.ensureSignedIn(_identity.identity);
      if (!signedIn) {
        if (_silentRetryAttempts < _maxSilentRetries) {
          _silentRetryAttempts++;
          _silentRetryTimer?.cancel();
          _silentRetryTimer = Timer(_silentRetryDelay, () {
            if (isClosed) return;
            isLoading.value = true;
            _initialize();
          });
        } else {
          isLoading.value = false;
          Get.snackbar(
            'Chat sync initializing',
            'Please wait a moment and reopen chat if messages do not appear yet.',
            snackPosition: SnackPosition.BOTTOM,
          );
        }
        return;
      }

      _silentRetryAttempts = 0;

      _activeConversationId = await _firebase.resolveConversationId(
        _myId,
        otherOfflineId,
      );

      final discoveredConversations = await _firebase.peerConversationIds(
        _myId,
        otherOfflineId,
      );

      // Ensure conversation document exists.
      await _firebase.ensureConversation(_myId, otherOfflineId);

      // Fetch the other user's profile.
      final profile = await _firebase.fetchProfile(otherOfflineId);
      otherProfile.value = profile;

      final allCandidates = <String>{
        ..._conversationCandidates,
        ...discoveredConversations,
        _activeConversationId,
      }.toList();

      _startMessageListeners(allCandidates);
    } finally {
      _initInProgress = false;
    }
  }

  void _startMessageListeners(List<String> candidates) {
    if (_streamsStarted) return;
    _streamsStarted = true;
    _listeningConversationIds = candidates.toSet().toList();

    Get.log(
      'ChatController: subscribing to conversations $_listeningConversationIds',
    );

    if (candidates.isEmpty) {
      isLoading.value = false;
      return;
    }

    var attachedAny = false;

    for (final convId in candidates) {
      final stream = _firebase.messagesStream(convId);
      if (stream == null) continue;
      attachedAny = true;

      final sub = stream.listen(
        (snapshot) {
          final previousKeys =
              _docKeysByConversation[convId] ?? const <String>{};
          for (final key in previousKeys) {
            _mergedMessages.remove(key);
          }

          final nextKeys = <String>{};
          for (final doc in snapshot.docs) {
            try {
              final msg = Message.fromFirestore(doc);
              if (msg.text.trim().isEmpty) continue;
              final key = '$convId/${doc.id}';
              _mergedMessages[key] = msg;
              nextKeys.add(key);
            } catch (e) {
              Get.log('ChatController: failed to parse message ${doc.id} – $e');
            }
          }

          _docKeysByConversation[convId] = nextKeys;
          _publishMergedMessages();

          // Mark incoming messages as read for this conversation variant.
          _firebase.markAsRead(convId, _myId);
        },
        onError: (error) {
          Get.log(
            'ChatController: messages stream failed for $convId – $error',
          );
          isLoading.value = false;
        },
      );

      _messageSubs.add(sub);
    }

    if (!attachedAny) {
      isLoading.value = false;
    }
  }

  void _publishMergedMessages() {
    final msgs = _mergedMessages.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (msgs.isNotEmpty) {
      messages.assignAll(msgs);
      isLoading.value = false;
      return;
    }

    _tryPreviewFallback();
  }

  void _tryPreviewFallback() {
    if (_previewFallbackInProgress || _previewFallbackAttempted) {
      isLoading.value = false;
      return;
    }

    _previewFallbackInProgress = true;
    _previewFallbackAttempted = true;

    final ids = <String>{
      ..._listeningConversationIds,
      _activeConversationId,
    }.toList();

    _firebase
        .fetchConversationPreviewMessages(ids)
        .then((fallback) {
          if (isClosed) return;
          if (_mergedMessages.isEmpty && fallback.isNotEmpty) {
            messages.assignAll(fallback);
            Get.log(
              'ChatController: using preview fallback from conversations $ids',
            );
          }
        })
        .catchError((e) {
          Get.log('ChatController: preview fallback failed – $e');
        })
        .whenComplete(() {
          _previewFallbackInProgress = false;
          if (!isClosed) {
            isLoading.value = false;
          }
        });
  }

  /// Sends a text message.
  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !isAvailable.value) return;

    final now = DateTime.now();
    final tempId = 'local-${now.microsecondsSinceEpoch}';
    final message = Message(
      id: tempId,
      senderId: _myId,
      text: trimmed,
      createdAt: now,
    );

    // Optimistic render so sender sees the message immediately.
    messages.add(message);

    final sent = await _firebase.sendMessage(
      _activeConversationId,
      Message(senderId: _myId, text: trimmed, createdAt: now),
    );

    if (!sent) {
      messages.removeWhere((m) => m.id == tempId);
      Get.snackbar(
        'Message not sent',
        'Could not deliver message. Please check internet and try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  @override
  void onClose() {
    _silentRetryTimer?.cancel();
    for (final sub in _messageSubs) {
      sub.cancel();
    }
    super.onClose();
  }
}
