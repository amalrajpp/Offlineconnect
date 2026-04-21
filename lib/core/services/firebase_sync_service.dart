import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:get/get.dart';

import '../models/connection.dart';
import '../models/message.dart';
import '../models/offline_identity.dart';
import '../models/user_profile.dart';
import 'identity_service.dart';

/// Syncs offline data to Firebase when the device is online.
///
/// This service is purely supplementary — the app works fully offline for
/// BLE discovery. When connectivity resumes it handles:
/// - Anonymous authentication
/// - Profile sync (display name, bio)
/// - Connection sync
/// - Real-time messaging via Firestore
class FirebaseSyncService extends GetxService {
  /// Canonical key used for chat participant identity across platforms.
  ///
  /// BLE shares hashed IDs (10-12 hex chars), while local identity is a
  /// full 32-char hex string. To keep both devices in the same conversation,
  /// we normalize all hex IDs to their first 10 chars.
  static String canonicalChatKey(String id) {
    final clean = id.trim().toLowerCase();
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
    if (!isHex) return clean;
    if (clean.length >= 10) return clean.substring(0, 10);
    return clean;
  }

  // ── Firebase availability ───────────────────────────────────────────────

  /// Whether Firebase was successfully initialised.
  bool get isFirebaseAvailable {
    try {
      Firebase.app();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ensures Firebase is initialized, with light retries for iOS cold-start races.
  Future<bool> ensureFirebaseReady({int maxAttempts = 3}) async {
    if (isFirebaseAvailable) return true;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
        }
        if (isFirebaseAvailable) {
          return true;
        }
      } catch (e) {
        Get.log(
          'FirebaseSyncService: ensureFirebaseReady attempt $attempt failed – $e',
        );
      }

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }
    }

    return isFirebaseAvailable;
  }

  FirebaseFirestore? get _firestore =>
      isFirebaseAvailable ? FirebaseFirestore.instance : null;

  FirebaseAuth? get _auth => isFirebaseAvailable ? FirebaseAuth.instance : null;

  /// The current Firebase UID if signed in.
  String? get firebaseUid => _auth?.currentUser?.uid;

  /// Whether the user is currently authenticated with Firebase.
  bool get isSignedIn => firebaseUid != null;

  // ── Authentication ──────────────────────────────────────────────────────

  /// Signs in anonymously and links the Firebase UID to the offline identity.
  ///
  /// Returns `true` if authentication succeeded, `false` if Firebase is
  /// unavailable or the sign-in failed.
  Future<bool> signInAnonymously(OfflineIdentity identity) async {
    final auth = _auth;
    if (auth == null) {
      Get.log('FirebaseSyncService: Firebase not available – skipping auth.');
      return false;
    }

    try {
      // If already signed in, just bind the identity.
      if (auth.currentUser != null) {
        await bindOfflineIdentity(identity);
        return true;
      }

      await auth.signInAnonymously();
      if (auth.currentUser == null) {
        Get.log('FirebaseSyncService: signInAnonymously returned no user.');
        return false;
      }
      await bindOfflineIdentity(identity);
      return true;
    } catch (e) {
      Get.log('FirebaseSyncService: anonymous sign-in failed – $e');
      return false;
    }
  }

  /// Ensures anonymous auth with lightweight retries (useful on iOS cold start).
  Future<bool> ensureSignedIn(
    OfflineIdentity identity, {
    int maxAttempts = 3,
  }) async {
    final ready = await ensureFirebaseReady(maxAttempts: maxAttempts);
    if (!ready) return false;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (isSignedIn) {
        await bindOfflineIdentity(identity);
        return true;
      }

      final ok = await signInAnonymously(identity);
      if (ok && isSignedIn) {
        return true;
      }

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 350 * attempt));
      }
    }

    return isSignedIn;
  }

  /// Associates the offline identity with the Firebase UID in Firestore.
  Future<void> bindOfflineIdentity(OfflineIdentity identity) async {
    final firestore = _firestore;
    final uid = firebaseUid;
    if (firestore == null || uid == null) return;

    try {
      await firestore.collection('users').doc(identity.offlineId).set({
        'firebaseUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'lastOnline': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      Get.log('FirebaseSyncService: bindOfflineIdentity failed – $e');
    }
  }

  // ── Profile ─────────────────────────────────────────────────────────────

  /// Syncs the user's profile (display name, bio) to Firestore.
  Future<void> syncProfile(UserProfile profile) async {
    final firestore = _firestore;
    if (firestore == null) return;

    try {
      await firestore
          .collection('users')
          .doc(profile.offlineId)
          .set(
            profile.toFirestoreMap(firebaseUid: firebaseUid),
            SetOptions(merge: true),
          );
    } catch (e) {
      Get.log('FirebaseSyncService: syncProfile failed – $e');
    }
  }

  /// Fetches another user's profile from Firestore.
  ///
  /// Returns `null` if the user hasn't synced their profile yet.
  Future<UserProfile?> fetchProfile(String offlineId) async {
    final firestore = _firestore;
    if (firestore == null) return null;

    try {
      final doc = await firestore.collection('users').doc(offlineId).get();
      if (!doc.exists || doc.data() == null) return null;
      return UserProfile.fromFirestore(offlineId, doc.data()!);
    } catch (e) {
      Get.log('FirebaseSyncService: fetchProfile failed – $e');
      return null;
    }
  }

  /// Uploads a profile photo to Firebase Storage.
  ///
  /// Returns the download URL on success, or `null` on failure.
  Future<String?> uploadProfilePhoto(String offlineId, File imageFile) async {
    if (!isFirebaseAvailable) return null;

    try {
      final ref = FirebaseStorage.instance
          .ref()
          .child('profile_photos')
          .child('$offlineId.jpg');

      final uploadTask = await ref.putFile(
        imageFile,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      if (uploadTask.state == TaskState.success) {
        final url = await ref.getDownloadURL();

        // Also update the Firestore profile doc.
        await _firestore?.collection('users').doc(offlineId).set({
          'photoUrl': url,
        }, SetOptions(merge: true));

        return url;
      }
      return null;
    } catch (e) {
      Get.log('FirebaseSyncService: uploadProfilePhoto failed – $e');
      return null;
    }
  }

  // ── Connections sync ────────────────────────────────────────────────────

  /// Batch-uploads accepted connections to Firestore.
  Future<void> syncConnections(
    String myOfflineId,
    List<Connection> connections,
  ) async {
    final firestore = _firestore;
    if (firestore == null || !isSignedIn) return;

    try {
      final col = firestore
          .collection('users')
          .doc(myOfflineId)
          .collection('connections');

      final accepted = connections
          .where((c) => c.status == ConnectionStatus.accepted)
          .toList();

      if (accepted.isEmpty) return;

      // Firestore restricts batches to 500 operations. We chunk the sync to prevent
      // load-test and extreme density crashes.
      for (var i = 0; i < accepted.length; i += 400) {
        final chunk = accepted.skip(i).take(400);
        final batch = firestore.batch();

        for (final conn in chunk) {
          final docId = conn.otherOfflineId;
          batch.set(col.doc(docId), {
            'otherOfflineId': conn.otherOfflineId,
            'status': conn.status.index,
            'firstMetAt': Timestamp.fromDate(conn.firstMetAt),
          }, SetOptions(merge: true));
        }

        await batch.commit();
      }
    } catch (e) {
      Get.log('FirebaseSyncService: syncConnections failed – $e');
    }
  }

  // ── Conversations ───────────────────────────────────────────────────────

  /// Generates a deterministic conversation ID from two offline IDs.
  ///
  /// Both sides generate the same ID regardless of who initiates.
  static String conversationId(String idA, String idB) {
    final sorted = [canonicalChatKey(idA), canonicalChatKey(idB)]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Returns all known deterministic conversation-ID variants for two users.
  ///
  /// This helps read legacy chats where one side used full IDs while the other
  /// side used canonical BLE hash IDs.
  static List<String> conversationIdCandidates(String idA, String idB) {
    final aRaw = idA.trim().toLowerCase();
    final bRaw = idB.trim().toLowerCase();
    final aCanon = canonicalChatKey(aRaw);
    final bCanon = canonicalChatKey(bRaw);

    List<String> hashVariants(String id) {
      final clean = id.trim().toLowerCase();
      final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
      if (!isHex) {
        return [clean];
      }

      final values = <String>{clean};
      if (clean.length == 10) {
        values.add('${clean}00');
      }
      if (clean.length == 12 && clean.endsWith('00')) {
        values.add(clean.substring(0, 10));
      }
      if (clean.length > 12) {
        final short10 = clean.substring(0, 10);
        values.add(short10);
        values.add('${short10}00');
      }
      return values.toList();
    }

    final ids = <String>{};
    void addPair(String left, String right) {
      final sorted = [left, right]..sort();
      ids.add('${sorted[0]}_${sorted[1]}');
    }

    addPair(aCanon, bCanon);
    addPair(aRaw, bRaw);
    addPair(aRaw, bCanon);
    addPair(aCanon, bRaw);

    for (final a in hashVariants(aRaw)) {
      for (final b in hashVariants(bRaw)) {
        addPair(a, b);
      }
    }

    return ids.toList();
  }

  /// Resolves the best existing conversation document for two IDs.
  ///
  /// Chooses the candidate with most recent `lastMessageAt`; falls back to the
  /// canonical conversation ID if none exists yet.
  Future<String> resolveConversationId(String myId, String otherId) async {
    final firestore = _firestore;
    if (firestore == null) return conversationId(myId, otherId);

    try {
      final candidates = conversationIdCandidates(myId, otherId);
      String? bestId;
      DateTime bestAt = DateTime.fromMillisecondsSinceEpoch(0);

      for (final id in candidates) {
        final doc = await firestore.collection('conversations').doc(id).get();
        if (!doc.exists) continue;

        final data = doc.data();
        final ts = data?['lastMessageAt'];
        final at = ts is Timestamp
            ? ts.toDate()
            : DateTime.fromMillisecondsSinceEpoch(0);

        if (bestId == null || at.isAfter(bestAt)) {
          bestId = id;
          bestAt = at;
        }
      }

      return bestId ?? conversationId(myId, otherId);
    } catch (e) {
      Get.log('FirebaseSyncService: resolveConversationId failed – $e');
      return conversationId(myId, otherId);
    }
  }

  /// Creates or updates a conversation document between two users.
  Future<void> ensureConversation(String myId, String otherId) async {
    final firestore = _firestore;
    if (firestore == null) return;

    try {
      final myKey = canonicalChatKey(myId);
      final otherKey = canonicalChatKey(otherId);
      final convId = conversationId(myId, otherId);
      final docRef = firestore.collection('conversations').doc(convId);
      final doc = await docRef.get();

      if (!doc.exists) {
        await docRef.set({
          'participants': [myKey, otherKey],
          'participantsRaw': [myId, otherId],
          'lastMessage': null,
          'lastMessageAt': FieldValue.serverTimestamp(),
          'lastMessageBy': null,
        });
      }
    } catch (e) {
      Get.log('FirebaseSyncService: ensureConversation failed – $e');
    }
  }

  /// Returns a real-time stream of conversations the user participates in.
  Stream<QuerySnapshot>? conversationsStream(String myOfflineId) {
    final firestore = _firestore;
    if (firestore == null) return null;

    final myKey = canonicalChatKey(myOfflineId);

    return firestore
        .collection('conversations')
        .where('participants', arrayContains: myKey)
        .snapshots();
  }

  /// Finds all conversation document IDs between [myOfflineId] and [otherId].
  ///
  /// This covers legacy schemas by checking both `participants` (canonical)
  /// and `participantsRaw` (full IDs), then filtering by canonical peer key.
  Future<Set<String>> peerConversationIds(
    String myOfflineId,
    String otherId,
  ) async {
    final firestore = _firestore;
    if (firestore == null) return <String>{};

    final myKey = canonicalChatKey(myOfflineId);
    final otherKey = canonicalChatKey(otherId);
    final docsById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    Future<void> collect(Query<Map<String, dynamic>> query) async {
      try {
        final snap = await query.get();
        for (final doc in snap.docs) {
          docsById[doc.id] = doc;
        }
      } catch (e) {
        Get.log('FirebaseSyncService: peerConversationIds query failed – $e');
      }
    }

    await collect(
      firestore
          .collection('conversations')
          .where('participants', arrayContains: myKey),
    );
    await collect(
      firestore
          .collection('conversations')
          .where('participants', arrayContains: myOfflineId),
    );
    await collect(
      firestore
          .collection('conversations')
          .where('participantsRaw', arrayContains: myOfflineId),
    );

    final result = <String>{};
    for (final entry in docsById.entries) {
      final data = entry.value.data();
      final participants =
          (data['participants'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];
      final participantsRaw =
          (data['participantsRaw'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];

      final hasOther =
          participants.any((p) => canonicalChatKey(p) == otherKey) ||
          participants.any((p) => p == otherKey || p == '${otherKey}00') ||
          participantsRaw.any((p) => canonicalChatKey(p) == otherKey) ||
          participantsRaw.any((p) => p == otherKey || p == '${otherKey}00');

      if (hasOther) {
        result.add(entry.key);
      }
    }

    return result;
  }

  /// Returns canonical peer IDs for conversations that already have messages.
  ///
  /// Used by the Connections screen to hide peers that have moved to Chats.
  Future<Set<String>> startedChatPeerKeys(String myOfflineId) async {
    final firestore = _firestore;
    if (firestore == null || !isSignedIn) return <String>{};

    final myKey = canonicalChatKey(myOfflineId);

    try {
      final snapshot = await firestore
          .collection('conversations')
          .where('participants', arrayContains: myKey)
          .get();

      final peers = <String>{};

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final lastMessage = (data['lastMessage'] as String?)?.trim() ?? '';
        if (lastMessage.isEmpty) {
          continue; // conversation created but no chat yet
        }

        final rawParticipants =
            (data['participantsRaw'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        final participants =
            (data['participants'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];

        String? other;
        if (rawParticipants.isNotEmpty) {
          for (final p in rawParticipants) {
            if (p == myOfflineId) continue;
            if (canonicalChatKey(p) == myKey) continue;
            other = p;
            break;
          }
        }

        if (other == null) {
          for (final p in participants) {
            if (canonicalChatKey(p) == myKey) continue;
            other = p;
            break;
          }
        }

        if (other != null && other.trim().isNotEmpty) {
          peers.add(canonicalChatKey(other));
        }
      }

      return peers;
    } catch (e) {
      Get.log('FirebaseSyncService: startedChatPeerKeys failed – $e');
      return <String>{};
    }
  }

  // ── Messages ────────────────────────────────────────────────────────────

  /// Sends a message in a conversation.
  Future<bool> sendMessage(String convId, Message message) async {
    final firestore = _firestore;
    if (firestore == null) return false;

    try {
      final convRef = firestore.collection('conversations').doc(convId);

      // Add message to subcollection.
      await convRef.collection('messages').add(message.toFirestoreMap());

      // Update conversation last message preview.
      await convRef.update({
        'lastMessage': message.text.length > 100
            ? '${message.text.substring(0, 100)}…'
            : message.text,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastMessageBy': message.senderId,
      });
      return true;
    } catch (e) {
      Get.log('FirebaseSyncService: sendMessage failed – $e');
      return false;
    }
  }

  /// Returns a real-time stream of messages in a conversation,
  /// ordered by creation time (oldest first).
  Stream<QuerySnapshot>? messagesStream(String convId) {
    final firestore = _firestore;
    if (firestore == null) return null;

    return firestore
        .collection('conversations')
        .doc(convId)
        .collection('messages')
        .snapshots();
  }

  DateTime _parseAnyDate(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is int) {
      final millis = value > 1000000000000 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  /// Builds synthetic messages from conversation previews.
  ///
  /// Useful fallback when message subcollection docs are missing/inaccessible
  /// but conversation-level `lastMessage` fields are present.
  Future<List<Message>> fetchConversationPreviewMessages(
    List<String> conversationIds,
  ) async {
    final firestore = _firestore;
    if (firestore == null || conversationIds.isEmpty) return const <Message>[];

    final previews = <Message>[];
    final uniqueIds = conversationIds.toSet();

    for (final convId in uniqueIds) {
      try {
        final doc = await firestore
            .collection('conversations')
            .doc(convId)
            .get();
        if (!doc.exists) continue;
        final data = doc.data();
        if (data == null) continue;

        final lastMessage = (data['lastMessage'] as String?)?.trim() ?? '';
        if (lastMessage.isEmpty) continue;

        final sender = (data['lastMessageBy'] ?? '').toString();
        final at = _parseAnyDate(data['lastMessageAt']);

        previews.add(
          Message(
            id: 'preview-$convId',
            senderId: sender,
            text: lastMessage,
            createdAt: at,
          ),
        );
      } catch (e) {
        Get.log(
          'FirebaseSyncService: fetchConversationPreviewMessages failed for $convId – $e',
        );
      }
    }

    previews.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return previews;
  }

  /// Marks all unread messages in a conversation as read.
  Future<void> markAsRead(String convId, String myOfflineId) async {
    final firestore = _firestore;
    if (firestore == null) return;

    try {
      final unread = await firestore
          .collection('conversations')
          .doc(convId)
          .collection('messages')
          .where('readAt', isNull: true)
          .where('senderId', isNotEqualTo: myOfflineId)
          .get();

      if (unread.docs.isEmpty) return;

      final batch = firestore.batch();
      for (final doc in unread.docs) {
        batch.update(doc.reference, {'readAt': FieldValue.serverTimestamp()});
      }
      await batch.commit();
    } catch (e) {
      Get.log('FirebaseSyncService: markAsRead failed – $e');
    }
  }

  // ── Heartbeat ───────────────────────────────────────────────────────────

  /// Updates the user's `lastOnline` timestamp.
  Future<void> updateLastOnline(String offlineId) async {
    final firestore = _firestore;
    if (firestore == null) return;

    try {
      await firestore.collection('users').doc(offlineId).update({
        'lastOnline': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      // Ignore — not critical.
    }
  }

  /// The Cloud Ban: Blocks a user in Firestore
  Future<void> blockUser(String peerId) async {
    final firestore = _firestore;
    if (firestore == null) return;
    try {
      final user = _auth?.currentUser;
      if (user == null) return;
      final myOfflineId = Get.find<IdentityService>().identity.offlineId;
      await firestore
          .collection('users')
          .doc(myOfflineId)
          .collection('blocked')
          .doc(peerId)
          .set({'timestamp': FieldValue.serverTimestamp()});
    } catch (e) {
      Get.log('FirebaseSyncService: blockUser failed - $e');
    }
  }

  /// The Firestore Drop: Reports a user for moderation
  Future<void> reportUser({
    required String reportedId,
    required String reason,
    required List<Message> messages,
  }) async {
    final firestore = _firestore;
    if (firestore == null) return;
    try {
      final reporterId = Get.find<IdentityService>().identity.offlineId;
      final payload = {
        'reporter_id': reporterId,
        'reported_id': reportedId,
        'reason': reason,
        'timestamp': FieldValue.serverTimestamp(),
        'message_history': messages.map((m) => m.toMap("")).toList(),
      };
      await firestore.collection('reports').add(payload);
    } catch (e) {
      Get.log('FirebaseSyncService: reportUser failed - $e');
    }
  }

  /// The Account Deletion Protocol: Permanently erases user data from the cloud
  Future<void> deleteAccount(String offlineId) async {
    final firestore = _firestore;
    if (firestore == null) return;
    try {
      final user = _auth?.currentUser;

      // 1. Delete Firestore User Document
      await firestore.collection('users').doc(offlineId).delete();

      // 2. Delete Authentication Data
      await user?.delete();
    } catch (e) {
      Get.log('FirebaseSyncService: deleteAccount failed - $e');
    }
  }
}
