import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/models/ble_models.dart';
import '../../core/models/connection.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/ble_service.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';
import '../connections/connections_controller.dart';

/// Controls the nearby-discovery feature with an aggressive 2-second
/// buffer/throttler to protect battery, CPU, and prevent UI jank in
/// dense crowds (100+ devices).
///
/// ### How it works
/// 1. Raw scan results are funnelled silently into [_buffer] (a Map keyed
///    by the peer's BLE hash) so the latest RSSI always wins.
/// 2. Every 2 seconds [_processBuffer] flushes the buffer → the observable
///    [users] list is updated once, triggering a single Obx rebuild.
/// 3. Peers not seen for 15 seconds are pruned.
/// 4. Connection-intent handling (request / accept) is evaluated during
///    the buffer flush, not per-advertisement.
class NearbyController extends GetxController with WidgetsBindingObserver {
  final BleService _ble = Get.find<BleService>();
  final IdentityService _identity = Get.find<IdentityService>();
  final LocalDbService _db = Get.find<LocalDbService>();

  /// The list that the UI observes. Updated every 2 seconds.
  final RxList<DiscoveredPeer> users = <DiscoveredPeer>[].obs;

  /// Whether scanning/broadcasting is active.
  final RxBool scanning = false.obs;

  /// The peer we are currently broadcasting a request/accept to (if any).
  /// Used to disable the connect button for other peers while in-flight.
  final Rx<String?> pendingRequestTarget = Rx<String?>(null);

  /// First 12 characters of the offline ID (6 bytes in hex).
  late final String myHash;

  /// Canonical 10-char hash prefix used for cross-platform intent matching.
  ///
  /// iOS UUID mode carries only 5 hash bytes, while Android manufacturer
  /// payload carries 6 bytes. Matching by first 10 hex chars keeps routing
  /// stable across both encodings.
  String _canonicalHash(String hash) {
    final clean = hash.toLowerCase();
    return clean.length <= 10 ? clean : clean.substring(0, 10);
  }

  bool _samePeer(String a, String b) => _canonicalHash(a) == _canonicalHash(b);

  String displayPeerId(String hash) {
    final canonical = _canonicalHash(hash);
    return canonical.length <= 8 ? canonical : canonical.substring(0, 8);
  }

  /// Latest known local-DB status for each nearby peer (keyed canonically).
  final RxMap<String, ConnectionStatus> _peerConnectionStatus =
      <String, ConnectionStatus>{}.obs;

  ConnectionStatus? connectionStatusForPeer(String hash) {
    return _peerConnectionStatus[_canonicalHash(hash)];
  }

  bool isPeerPending(String hash) {
    final pending = pendingRequestTarget.value;
    return pending != null && _samePeer(pending, hash);
  }

  bool canAddConnection(String hash) {
    if (isPeerPending(hash)) return false;
    return connectionStatusForPeer(hash) == null;
  }

  bool _isTargetedToMe(DiscoveredPeer peer) {
    final target = peer.targetHash;
    if (target == null) return false;
    return _samePeer(target, myHash);
  }

  Future<void> _refreshPeerConnectionStatus() async {
    try {
      final all = await _db.getConnections();
      final map = <String, ConnectionStatus>{};
      for (final conn in all) {
        map[_canonicalHash(conn.otherOfflineId)] = conn.status;
      }
      _peerConnectionStatus.assignAll(map);
    } catch (e) {
      Get.log('NearbyController: _refreshPeerConnectionStatus failed – $e');
    }
  }

  Future<void> _ensureChatReadyForPeer(String peerOfflineId) async {
    try {
      final firebase = Get.find<FirebaseSyncService>();
      if (!firebase.isFirebaseAvailable) return;

      if (!firebase.isSignedIn) {
        final signed = await firebase.signInAnonymously(_identity.identity);
        if (!signed) return;
      }

      await firebase.ensureConversation(
        _identity.identity.offlineId,
        peerOfflineId,
      );
    } catch (e) {
      Get.log('NearbyController: ensure chat ready failed – $e');
    }
  }

  // ── Internal ────────────────────────────────────────────────────────────
  final Map<String, DiscoveredPeer> _buffer = {};
  Timer? _batchTimer;
  StreamSubscription<DiscoveredPeer>? _peerSub;

  /// Tracks peers whose accept responses we have already handled.
  final Set<String> _handledAccepts = {};

  /// Queue of incoming connection requests waiting to be shown as dialogs.
  /// We process one dialog at a time to avoid losing requests (Fix #3).
  final List<DiscoveredPeer> _incomingRequestQueue = [];

  /// Tracks peers whose incoming requests are queued or already handled.
  final Set<String> _knownIncomingHashes = {};

  /// Cancellable timer for reverting broadcast to presence after a request.
  Timer? _revertToPresenceTimer;

  @override
  void onInit() {
    super.onInit();
    myHash = _identity.identity.bleHash;
    WidgetsBinding.instance.addObserver(this);
  }

  // ── App lifecycle ──────────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (scanning.value) {
        _pauseScanning();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (scanning.value) {
        _resumeScanning();
      }
    }
  }

  void _pauseScanning() {
    _batchTimer?.cancel();
    _batchTimer = null;
    _peerSub?.cancel();
    _peerSub = null;
    _ble.stopScanning();
  }

  Future<void> _resumeScanning() async {
    _peerSub ??= _ble.discoveredPeers.listen(_onPeerDiscovered);
    final started = await _ble.startScanning(skipPermissionCheck: true);
    if (!started) {
      scanning.value = false;
      Get.snackbar(
        'Scan Failed',
        'Could not resume BLE scan. Please check Nearby Devices permission.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    _batchTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _processBuffer(),
    );
  }

  // ── Peer listener with smart buffer logic (Fix #4 & #5) ────────────────

  void _onPeerDiscovered(DiscoveredPeer peer) {
    Get.log(
      'NEARBY_TRACE: Discovered ${peer.myHash} (intent=${peer.intent}, rssi=${peer.rssi})',
    );
    // Fix #4 — Filter out self-advertisements.
    if (_samePeer(peer.myHash, myHash)) return;

    final peerKey = _canonicalHash(peer.myHash);

    // Fix #5 — Prefer higher-intent advertisements to avoid
    // a late-arriving "presence" overwriting a "requestConnection".
    final existing = _buffer[peerKey];
    if (existing == null) {
      _buffer[peerKey] = peer;
    } else if (peer.intent.index >= existing.intent.index) {
      // New intent is same or higher priority → use it fully.
      _buffer[peerKey] = peer;
    } else if (peer.lastSeen.difference(existing.lastSeen).inSeconds > 5) {
      // The higher-intent ad is stale (>5s old) → accept the new one.
      _buffer[peerKey] = peer;
    } else {
      // Keep the existing higher intent, but update RSSI/lastSeen.
      _buffer[peerKey] = existing.copyWith(
        rssi: peer.rssi,
        lastSeen: peer.lastSeen,
      );
    }
    Get.log('NEARBY_TRACE: Buffer now has ${_buffer.length} items');
  }

  // ── Public API ──────────────────────────────────────────────────────────

  /// Begins scanning for nearby peers and broadcasting presence.
  Future<void> startScanningAndBroadcasting() async {
    if (scanning.value) return;

    try {
      final adapterOk = await _ble.ensureAdapterOn();
      if (!adapterOk) {
        Get.snackbar(
          'Bluetooth Off',
          'Please enable Bluetooth to discover nearby people.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      final permissionsOk = await _ble.requestPermissions();
      if (!permissionsOk) {
        final locationServiceOn = await _ble.isLocationServiceEnabled();
        if (!locationServiceOn) {
          Get.snackbar(
            'Location Services Off',
            'Turn on Location services to detect nearby devices.',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 6),
            mainButton: TextButton(
              onPressed: () => _ble.openDeviceLocationSettings(),
              child: const Text('Open Settings'),
            ),
          );
          return;
        }

        Get.snackbar(
          'Permissions Required',
          'Enable Nearby Devices, Location permission, and Location services to scan for nearby devices.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 6),
          mainButton: TextButton(
            onPressed: () => _ble.openDeviceLocationSettings(),
            child: const Text('Open Settings'),
          ),
        );
        return;
      }

      await _refreshPeerConnectionStatus();

      scanning.value = true;

      // Broadcast our presence intent.
      await _ble.broadcastState(_identity.identity, BleIntent.presence);

      // Funnel all results into the buffer with smart filtering.
      // Must listen BEFORE starting the scan to avoid losing the first native stream burst!
      _peerSub ??= _ble.discoveredPeers.listen(_onPeerDiscovered);

      // Start scanning.
      final started = await _ble.startScanning(skipPermissionCheck: true);
      if (!started) {
        scanning.value = false;
        await _ble.stopBroadcasting();
        Get.snackbar(
          'Scan Failed',
          'Could not start BLE scan. Ensure Nearby Devices and Location permissions are enabled.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      // Flush the buffer every 2 seconds.
      _batchTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _processBuffer(),
      );
    } catch (e) {
      scanning.value = false;
      Get.log('NearbyController: start failed – $e');
    }
  }

  /// Stops scanning and broadcasting.
  Future<void> stopScanningAndBroadcasting() async {
    scanning.value = false;
    pendingRequestTarget.value = null;
    _batchTimer?.cancel();
    _batchTimer = null;
    _revertToPresenceTimer?.cancel();
    _revertToPresenceTimer = null;
    await _peerSub?.cancel();
    _peerSub = null;
    await _ble.stopScanning();
    await _ble.stopBroadcasting();
    _buffer.clear();
    _knownIncomingHashes.clear();
    _handledAccepts.clear();
    _incomingRequestQueue.clear();
    users.clear();
  }

  /// Sends a connection request directed at [targetHash].
  ///
  /// After 10 seconds the broadcast reverts to plain presence.
  Future<void> sendConnectionRequest(String targetHash) async {
    try {
      // Fix #1 — Prevent overwriting an in-flight request.
      if (pendingRequestTarget.value != null) {
        Get.snackbar(
          'Request In Progress',
          'Wait for your current request to complete before sending another.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
        return;
      }

      // Don't allow duplicate/invalid re-requests when a local row exists.
      final existing = await _db.findConnectionByOther(targetHash);
      if (existing != null) {
        switch (existing.status) {
          case ConnectionStatus.pendingOutgoing:
            Get.snackbar(
              'Request Already Sent',
              'You already sent a request to this user.',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
            return;
          case ConnectionStatus.pendingIncoming:
            Get.snackbar(
              'Incoming Request Pending',
              'This user has already requested to connect with you.',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
            return;
          case ConnectionStatus.accepted:
            Get.snackbar(
              'Already Connected',
              'You are already connected with this user.',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
            return;
          case ConnectionStatus.blocked:
            Get.snackbar(
              'Connection Unavailable',
              'You cannot send a request to this user.',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2),
            );
            return;
        }
      }

      pendingRequestTarget.value = targetHash;

      await _ble.broadcastState(
        _identity.identity,
        BleIntent.requestConnection,
        targetHash: targetHash,
      );

      // Save an outgoing pending connection locally.
      if (existing == null) {
        await _db.insertConnection(
          Connection(
            myOfflineId: _identity.identity.offlineId,
            otherOfflineId: targetHash,
            status: ConnectionStatus.pendingOutgoing,
            firstMetAt: DateTime.now(),
          ),
        );
        _refreshConnectionsList();
      }

      await _refreshPeerConnectionStatus();

      final shortHash = displayPeerId(targetHash);
      Get.snackbar(
        'Request Sent',
        'Connection request sent to $shortHash…',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      // Revert to presence after 10 seconds.
      _revertToPresenceTimer?.cancel();
      _revertToPresenceTimer = Timer(const Duration(seconds: 10), () {
        pendingRequestTarget.value = null;
        if (scanning.value) {
          _ble.broadcastState(_identity.identity, BleIntent.presence);
        }
      });
    } catch (e) {
      pendingRequestTarget.value = null;
      Get.log('NearbyController: sendConnectionRequest failed – $e');
    }
  }

  // ── Buffer processor (runs every 2 s) ──────────────────────────────────

  bool _shouldRebuildUi(
    List<DiscoveredPeer> oldList,
    List<DiscoveredPeer> newList,
  ) {
    Get.log(
      'NEARBY_TRACE: _shouldRebuildUi check (old: ${oldList.length}, new: ${newList.length})',
    );
    if (oldList.length != newList.length) {
      Get.log('NEARBY_TRACE: YES! Length changed');
      return true;
    }
    for (var i = 0; i < oldList.length; i++) {
      if (oldList[i].myHash != newList[i].myHash) {
        Get.log('NEARBY_TRACE: YES! Hash mismatch at $i');
        return true;
      }
      if (oldList[i].intent != newList[i].intent) {
        Get.log('NEARBY_TRACE: YES! Intent mismatch at $i');
        return true;
      }
      // Rebuild if RSSI changes by more than 5 dBm
      if ((oldList[i].rssi - newList[i].rssi).abs() > 5) {
        Get.log('NEARBY_TRACE: YES! Rssi jitter > 5');
        return true;
      }
    }
    return false;
  }

  Future<void> _processBuffer() async {
    final now = DateTime.now();

    // Prune stale peers (not seen in last 15 seconds).
    _buffer.removeWhere(
      (_, peer) => now.difference(peer.lastSeen).inSeconds > 15,
    );

    // Sort by RSSI (closest first – higher RSSI value = closer).
    final sorted = _buffer.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    final displayList = sorted.take(100).toList();
    Get.log(
      'NEARBY_TRACE: Processing buffer loop... displayList has ${displayList.length} items',
    );

    if (_shouldRebuildUi(users, displayList)) {
      users.assignAll(displayList);
      Get.log(
        'NEARBY_TRACE: UI assigned successfully. Users count: ${users.length}',
      );
    } else {
      Get.log('NEARBY_TRACE: UI matched perfectly, no rebuild.');
    }

    await _refreshPeerConnectionStatus();

    // ── Handle incoming connection requests ──
    for (final peer in sorted) {
      final peerKey = _canonicalHash(peer.myHash);

      // Queue new incoming requests (Fix #3 — don't drop when dialog is open).
      if (peer.intent == BleIntent.requestConnection &&
          _isTargetedToMe(peer) &&
          !_knownIncomingHashes.contains(peerKey)) {
        _knownIncomingHashes.add(peerKey);
        _incomingRequestQueue.add(peer);
      }

      // Handle accept responses.
      if (peer.intent == BleIntent.acceptConnection &&
          _isTargetedToMe(peer) &&
          !_handledAccepts.contains(peerKey)) {
        _handledAccepts.add(peerKey);
        _handleAccepted(peer);
      }
    }

    // Process one queued incoming request at a time.
    if (!(Get.isDialogOpen ?? false) && _incomingRequestQueue.isNotEmpty) {
      final next = _incomingRequestQueue.removeAt(0);
      _handleIncomingRequest(next);
    }
  }

  /// Shows a dialog when an incoming connection request is detected.
  Future<void> _handleIncomingRequest(DiscoveredPeer peer) async {
    // Fix #2 — Check for simultaneous request (both sides requested each other).
    final existing = await _db.findConnectionByOther(peer.myHash);
    if (existing != null &&
        existing.status == ConnectionStatus.pendingOutgoing) {
      // Auto-accept — both sides want to connect (mutual request).
      await _db.updateConnectionStatus(existing.id!, ConnectionStatus.accepted);
      await _db.upsertKnownUser(
        UserProfile(
          offlineId: peer.myHash,
          displayName:
              peer.offlineUsername != null && peer.offlineUsername!.isNotEmpty
              ? '@${peer.offlineUsername}'
              : 'User ${displayPeerId(peer.myHash)}',
        ),
        rssi: peer.rssi,
      );
      _refreshConnectionsList();
      await _refreshPeerConnectionStatus();
      await _ensureChatReadyForPeer(peer.myHash);
      Get.snackbar(
        'Connected!',
        'Mutual connection with ${displayPeerId(peer.myHash)}…',
      );

      // Clear pending request since it's now resolved.
      if (pendingRequestTarget.value != null &&
          _samePeer(pendingRequestTarget.value!, peer.myHash)) {
        pendingRequestTarget.value = null;
      }
      // Queue the accept broadcast so the other side sees it.
      _enqueueAcceptBroadcast(peer.myHash);
      return;
    }

    // Fix #6 — Don't show dialog if already connected.
    if (existing != null && existing.status == ConnectionStatus.accepted) {
      // Re-broadcast accept in case the peer missed our previous packet.
      _enqueueAcceptBroadcast(peer.myHash);
      return;
    }

    // Ensure received requests appear in Connections > Received Requests.
    if (existing == null) {
      await _db.insertConnection(
        Connection(
          myOfflineId: _identity.identity.offlineId,
          otherOfflineId: peer.myHash,
          status: ConnectionStatus.pendingIncoming,
          firstMetAt: DateTime.now(),
        ),
      );
      _refreshConnectionsList();
      await _refreshPeerConnectionStatus();
    }

    if (!(Get.isDialogOpen ?? false)) {
      Get.defaultDialog(
        title: 'Connection Request',
        middleText: 'User ${displayPeerId(peer.myHash)}… wants to connect.',
        textConfirm: 'Accept',
        textCancel: 'Ignore',
        confirmTextColor: Colors.white,
        onConfirm: () async {
          Get.back(); // close dialog
          await _acceptPeer(peer);
        },
        onCancel: () {
          // Record as ignored so we don't ask again this scan session.
          // The dialog is auto-closed by GetX on cancel.
        },
      );
    } else {
      // Dialog is still open from a previous request — re-queue this one.
      _incomingRequestQueue.insert(0, peer);
    }
  }

  /// Shared logic for accepting a peer — persists to DB and queues the
  /// accept broadcast so it stays on-air long enough for the other side
  /// to detect it.
  Future<void> _acceptPeer(DiscoveredPeer peer) async {
    // Persist the connection.
    final existing = await _db.findConnectionByOther(peer.myHash);
    if (existing != null) {
      await _db.updateConnectionStatus(existing.id!, ConnectionStatus.accepted);
    } else {
      await _db.insertConnection(
        Connection(
          myOfflineId: _identity.identity.offlineId,
          otherOfflineId: peer.myHash,
          status: ConnectionStatus.accepted,
          firstMetAt: DateTime.now(),
        ),
      );
    }

    // Save as known user.
    await _db.upsertKnownUser(
      UserProfile(
        offlineId: peer.myHash,
        displayName:
            peer.offlineUsername != null && peer.offlineUsername!.isNotEmpty
            ? '@${peer.offlineUsername}'
            : 'User ${displayPeerId(peer.myHash)}',
      ),
      rssi: peer.rssi,
    );

    _refreshConnectionsList();
    await _refreshPeerConnectionStatus();
    await _ensureChatReadyForPeer(peer.myHash);

    Get.snackbar(
      'Connected!',
      'You are now connected with ${displayPeerId(peer.myHash)}…',
    );

    // Queue the accept broadcast.
    _enqueueAcceptBroadcast(peer.myHash);
  }

  // ── Accept broadcast queue ─────────────────────────────────────────────
  //
  // When accepting multiple requests, each accept must be broadcast long
  // enough (5s) for the requester to scan and see it. We queue them and
  // broadcast one at a time.

  final List<String> _acceptBroadcastQueue = [];
  Timer? _acceptBroadcastTimer;

  void _enqueueAcceptBroadcast(String targetHash) {
    _acceptBroadcastQueue.add(targetHash);
    // If nothing is currently broadcasting an accept, start immediately.
    if (_acceptBroadcastTimer == null || !_acceptBroadcastTimer!.isActive) {
      _processNextAcceptBroadcast();
    }
  }

  void _processNextAcceptBroadcast() {
    if (_acceptBroadcastQueue.isEmpty) {
      // All accepts sent — revert to presence.
      if (scanning.value) {
        _ble.broadcastState(_identity.identity, BleIntent.presence);
      }
      return;
    }

    final target = _acceptBroadcastQueue.removeAt(0);
    _ble.broadcastState(
      _identity.identity,
      BleIntent.acceptConnection,
      targetHash: target,
    );

    // Keep this accept on-air for 5 seconds before moving to the next.
    _acceptBroadcastTimer = Timer(const Duration(seconds: 5), () {
      _processNextAcceptBroadcast();
    });
  }

  /// Handles an acceptance from a peer we previously requested.
  Future<void> _handleAccepted(DiscoveredPeer peer) async {
    final existing = await _db.findConnectionByOther(peer.myHash);
    if (existing != null) {
      if (existing.status != ConnectionStatus.accepted) {
        await _db.updateConnectionStatus(
          existing.id!,
          ConnectionStatus.accepted,
        );
      }

      await _db.upsertKnownUser(
        UserProfile(
          offlineId: peer.myHash,
          displayName:
              peer.offlineUsername != null && peer.offlineUsername!.isNotEmpty
              ? '@${peer.offlineUsername}'
              : 'User ${displayPeerId(peer.myHash)}',
        ),
        rssi: peer.rssi,
      );

      // Clear pending request state.
      if (pendingRequestTarget.value != null &&
          _samePeer(pendingRequestTarget.value!, peer.myHash)) {
        pendingRequestTarget.value = null;
        _revertToPresenceTimer?.cancel();
      }

      _refreshConnectionsList();
      await _refreshPeerConnectionStatus();
      await _ensureChatReadyForPeer(peer.myHash);

      Get.snackbar(
        'Connection Accepted!',
        '${displayPeerId(peer.myHash)}… accepted your request.',
      );
    } else {
      // Recovery path: if local pending row was lost, still mark as connected.
      await _db.insertConnection(
        Connection(
          myOfflineId: _identity.identity.offlineId,
          otherOfflineId: peer.myHash,
          status: ConnectionStatus.accepted,
          firstMetAt: DateTime.now(),
        ),
      );
      await _db.upsertKnownUser(
        UserProfile(
          offlineId: peer.myHash,
          displayName:
              peer.offlineUsername != null && peer.offlineUsername!.isNotEmpty
              ? '@${peer.offlineUsername}'
              : 'User ${displayPeerId(peer.myHash)}',
        ),
        rssi: peer.rssi,
      );
      _refreshConnectionsList();
      await _refreshPeerConnectionStatus();
      await _ensureChatReadyForPeer(peer.myHash);
    }
  }

  /// Refreshes the ConnectionsController list so the Connections tab
  /// updates without a manual refresh tap.
  void _refreshConnectionsList() {
    try {
      Get.find<ConnectionsController>().loadConnections();
    } catch (_) {
      // Controller may not be registered yet.
    }
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _batchTimer?.cancel();
    _revertToPresenceTimer?.cancel();
    _acceptBroadcastTimer?.cancel();
    _peerSub?.cancel();
    super.onClose();
  }
}
