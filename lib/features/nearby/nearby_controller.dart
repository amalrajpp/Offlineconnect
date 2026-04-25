import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/models/ble_models.dart';
import '../../core/models/connection.dart';
import '../../core/models/user_profile.dart';
import '../../core/services/ble_service.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';
import '../../core/models/avatar_dna.dart';
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

  // ── Per-Session (Per-Place) Limits ─────────────────────────────────────
  //
  // A "session" is one scanning cycle. When you walk into a cafe and start
  // scanning, that's your session. Limits reset when you stop and restart.

  /// Maximum outgoing requests allowed per session (per place).
  static const int maxRequestsPerSession = 5;

  /// Maximum mutual (accepted) connections allowed per session.
  static const int maxMutualPerSession = 2;

  /// Outgoing requests sent this session.
  final RxInt sessionRequestsSent = 0.obs;

  /// Mutual connections made this session (both directions count).
  final RxInt sessionMutualConnections = 0.obs;

  /// True when a session has ended due to limits being reached.
  /// The UI uses this to show a "session complete" summary instead of
  /// the live radar.
  final RxBool sessionComplete = false.obs;

  /// The reason the session ended (for UI display).
  final RxString sessionEndReason = ''.obs;

  // ── Session Cooldown ────────────────────────────────────────────────────
  //
  // After a session completes, enforce a 10-minute cooldown before the user
  // can start a new session at the same place. This prevents spamming the
  // "New Session" button to bypass per-session limits.

  /// Duration the user must wait after a session completes.
  static const Duration sessionCooldown = Duration(minutes: 10);

  /// When the current cooldown expires (null if no cooldown active).
  DateTime? _cooldownExpiresAt;

  /// Ticking countdown string for the UI (e.g. "9:45").
  final RxString cooldownRemaining = ''.obs;

  /// Whether a cooldown is currently active.
  bool get isCooldownActive =>
      _cooldownExpiresAt != null &&
      DateTime.now().isBefore(_cooldownExpiresAt!);

  Timer? _cooldownTickTimer;

  void _startCooldownTimer() {
    _cooldownExpiresAt = DateTime.now().add(sessionCooldown);
    _updateCooldownText();
    _cooldownTickTimer?.cancel();
    _cooldownTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isCooldownActive) {
        _cooldownTickTimer?.cancel();
        _cooldownTickTimer = null;
        cooldownRemaining.value = '';
        _cooldownExpiresAt = null;
        return;
      }
      _updateCooldownText();
    });
  }

  void _updateCooldownText() {
    if (_cooldownExpiresAt == null) {
      cooldownRemaining.value = '';
      return;
    }
    final diff = _cooldownExpiresAt!.difference(DateTime.now());
    if (diff.isNegative) {
      cooldownRemaining.value = '';
      return;
    }
    final m = diff.inMinutes;
    final s = diff.inSeconds % 60;
    cooldownRemaining.value = '$m:${s.toString().padLeft(2, '0')}';
  }

  // ── Non-Blocking Incoming Request Banner ─────────────────────────────────
  //
  // Instead of a modal dialog that blocks the entire UI, incoming requests
  // are surfaced as an observable peer that the UI renders as a dismissible
  // banner overlay on top of the radar. Users can accept/ignore without
  // losing visibility of the radar.

  /// The peer whose incoming request is currently shown in the banner.
  /// Null when no banner is visible.
  final Rx<DiscoveredPeer?> currentIncomingPeer = Rx<DiscoveredPeer?>(null);

  /// Whether the user can still send outgoing requests this session.
  bool get canSendRequest =>
      sessionRequestsSent.value < maxRequestsPerSession &&
      sessionMutualConnections.value < maxMutualPerSession;

  /// Remaining outgoing requests for this session.
  int get remainingRequests =>
      maxRequestsPerSession - sessionRequestsSent.value;

  /// Remaining mutual connections for this session.
  int get remainingMutual =>
      maxMutualPerSession - sessionMutualConnections.value;

  /// Whether either session limit has been reached.
  bool get _isSessionLimitReached =>
      sessionRequestsSent.value >= maxRequestsPerSession ||
      sessionMutualConnections.value >= maxMutualPerSession;

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
    if (!canSendRequest) return false;
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

  /// Grace-period timer for auto-completing the session after limits hit.
  Timer? _autoCompleteTimer;

  /// Retry timer for re-broadcasting connection requests in crowded areas.
  Timer? _requestRetryTimer;
  int _requestRetryCount = 0;
  static const int _maxRequestRetries = 3;
  static const Duration _requestRetryInterval = Duration(seconds: 10);

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
    if (kDebugMode) {
      Get.log(
        'NEARBY_TRACE: Discovered ${peer.myHash} (intent=${peer.intent}, rssi=${peer.rssi})',
      );
    }
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
    if (kDebugMode) {
      Get.log('NEARBY_TRACE: Buffer now has ${_buffer.length} items');
    }
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

      // ── Session cooldown gate ─────────────────────────────────────────
      if (isCooldownActive) {
        Get.snackbar(
          'Session Cooldown',
          'Wait ${cooldownRemaining.value} before starting a new session.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
        return;
      }

      // Reset per-session (per-place) counters.
      sessionRequestsSent.value = 0;
      sessionMutualConnections.value = 0;
      sessionComplete.value = false;
      sessionEndReason.value = '';
      currentIncomingPeer.value = null;

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
    _autoCompleteTimer?.cancel();
    _autoCompleteTimer = null;
    _requestRetryTimer?.cancel();
    _requestRetryTimer = null;
    _requestRetryCount = 0;
    await _peerSub?.cancel();
    _peerSub = null;
    await _ble.stopScanning();
    await _ble.stopBroadcasting();
    _buffer.clear();
    _knownIncomingHashes.clear();
    _handledAccepts.clear();
    _incomingRequestQueue.clear();
    // DON'T clear users — the session-complete screen still needs them
    // to show who was discovered. They get cleared on next session start.
  }

  /// Sends a connection request directed at [targetHash].
  ///
  /// After 10 seconds the broadcast reverts to plain presence.
  Future<void> sendConnectionRequest(String targetHash) async {
    try {
      final connCtrl = Get.find<ConnectionsController>();
      if (connCtrl.connectionsMadeToday.value >=
          connCtrl.maxConnectionsPerDay) {
        Get.snackbar(
          'Daily Connection Limit Reached',
          'You can only connect with ${connCtrl.maxConnectionsPerDay} people a day. Wait for the reset!',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 3),
        );
        return;
      }

      // ── Per-session limits — auto-stop handles the UI, just guard here ─
      if (_isSessionLimitReached) return;

      // If another request is in flight, cancel its retry chain so the user
      // can immediately send a new request to someone else. In crowded areas,
      // locking them out for 30s per request is frustrating.
      if (pendingRequestTarget.value != null) {
        _requestRetryTimer?.cancel();
        _requestRetryTimer = null;
        _requestRetryCount = 0;
        pendingRequestTarget.value = null;
        if (scanning.value) {
          await _ble.broadcastState(_identity.identity, BleIntent.presence);
        }
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
      sessionRequestsSent.value++;

      await _ble.broadcastState(
        _identity.identity,
        BleIntent.requestConnection,
        targetId: targetHash,
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
        'Connection request sent to $shortHash… ($remainingRequests left)',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );

      // ── Retry loop: re-broadcast request 3 times × 10s each ──────────
      // In crowded BLE environments, the target may not scan our specific
      // advertisement in a single 10-second window. We retry up to 3 times
      // (30s total) and stop early if the request gets accepted.
      _requestRetryCount = 1; // first broadcast already sent above
      _requestRetryTimer?.cancel();
      _requestRetryTimer = Timer.periodic(_requestRetryInterval, (timer) {
        // Stop retrying if: accepted, session ended, or max retries hit.
        if (pendingRequestTarget.value == null ||
            !scanning.value ||
            _requestRetryCount >= _maxRequestRetries) {
          timer.cancel();
          _requestRetryTimer = null;
          // Final revert to presence if still broadcasting request.
          if (pendingRequestTarget.value != null) {
            pendingRequestTarget.value = null;
            if (scanning.value) {
              _ble.broadcastState(_identity.identity, BleIntent.presence);
            }
          }
          return;
        }

        // Re-broadcast the request.
        _requestRetryCount++;
        Get.log(
          'NearbyController: Request retry $_requestRetryCount/$_maxRequestRetries '
          'for $targetHash',
        );
        _ble.broadcastState(
          _identity.identity,
          BleIntent.requestConnection,
          targetId: targetHash,
        );
      });

      // Check if this was the last allowed request → auto-complete session.
      _checkAndAutoComplete();
    } catch (e) {
      pendingRequestTarget.value = null;
      _requestRetryTimer?.cancel();
      _requestRetryTimer = null;
      Get.log('NearbyController: sendConnectionRequest failed – $e');
    }
  }

  /// Sends a connection accept request directed at [targetHash].
  ///
  /// This is used to manually trigger an accept response to a peer we
  /// previously requested to connect with.
  Future<void> sendAcceptRequest(
    String targetHash, {
    bool silent = false,
  }) async {
    try {
      // ── Per-session limits — auto-stop handles the UI, just guard here ─
      if (_isSessionLimitReached) return;

      // Fix #1 — Prevent overwriting an in-flight request.
      if (pendingRequestTarget.value != null) {
        if (!silent) {
          Get.snackbar(
            'Request In Progress',
            'Wait for your current request to complete before sending another.',
            snackPosition: SnackPosition.BOTTOM,
            duration: const Duration(seconds: 2),
          );
        }
        return;
      }

      pendingRequestTarget.value = targetHash;

      // Broadcast an accept response.
      await _ble.broadcastState(
        _identity.identity,
        BleIntent.acceptConnection,
        targetId: targetHash,
      );

      // Persist the connection as accepted.
      final existing = await _db.findConnectionByOther(targetHash);
      if (existing != null) {
        await _db.updateConnectionStatus(
          existing.id!,
          ConnectionStatus.accepted,
        );
      } else {
        await _db.insertConnection(
          Connection(
            myOfflineId: _identity.identity.offlineId,
            otherOfflineId: targetHash,
            status: ConnectionStatus.accepted,
            firstMetAt: DateTime.now(),
          ),
        );
      }

      // Save as known user.
      await _db.upsertKnownUser(
        UserProfile(
          offlineId: targetHash,
          displayName: 'User ${displayPeerId(targetHash)}',
        ),
      );

      if (!silent) {
        Get.snackbar(
          'Connection Accepted',
          'You are now connected with ${displayPeerId(targetHash)}.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }

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
      Get.log('NearbyController: sendAcceptRequest failed – $e');
    }
  }

  bool _shouldRebuildUi(
    List<DiscoveredPeer> current,
    List<DiscoveredPeer> next,
  ) {
    Get.log(
      'NEARBY_TRACE: _shouldRebuildUi check (old: ${current.length}, new: ${next.length})',
    );
    if (current.length != next.length) {
      Get.log('NEARBY_TRACE: YES! Length changed');
      return true;
    }
    for (var i = 0; i < current.length; i++) {
      if (current[i].myHash != next[i].myHash) {
        Get.log('NEARBY_TRACE: YES! Hash mismatch at $i');
        return true;
      }
      if (current[i].intent != next[i].intent) {
        Get.log('NEARBY_TRACE: YES! Intent mismatch at $i');
        return true;
      }
      // Rebuild if RSSI changes by more than 5 dBm
      if ((current[i].rssi - next[i].rssi).abs() > 5) {
        Get.log('NEARBY_TRACE: YES! Rssi jitter > 5');
        return true;
      }
    }
    return false;
  }

  Timer? _loadTestTimer;

  /// Bulk injects fake BLE peers directly into the nearby buffer to stress-test
  /// the 2-second processing loop, sorting, and UI rendering capacity.
  void runDeveloperLoadTest() {
    Get.log(
      'NEARBY_TRACE: Starting Load Test - Injecting initial 300 BLE peers',
    );
    _loadTestTimer?.cancel();
    _buffer.clear(); // Ensure we start fresh

    int currentCount = 0;

    void addPeers(int count) {
      final now = DateTime.now();
      for (int i = 0; i < count; i++) {
        if (currentCount >= 500) break;
        final mockHash = currentCount.toRadixString(16).padLeft(10, '0');
        final peerKey = _canonicalHash(mockHash);
        
        // Generate random randomized DNA within Fluttermoji's valid asset ranges (32-bit DNA)
        final random = math.Random();
        final mockDna = AvatarDNA.pack(
          topStyle: random.nextInt(35),      // Fluttermoji has ~35 top types
          hairColor: random.nextInt(10),     // ~10 hair colors
          eyeStyle: random.nextInt(10),      // ~10 eye types
          eyebrowType: random.nextInt(12),   // ~12 eyebrow types
          mouthType: random.nextInt(10),     // ~10 mouth types
          skinColor: random.nextInt(5),      // ~5 skin colors
          facialHairType: random.nextInt(8), // ~8 facial hair types
          accessoriesType: random.nextInt(8),// ~8 accessory types
        );

        _buffer[peerKey] = DiscoveredPeer(
          deviceId: 'simulated_device_$currentCount',
          myHash: mockHash,
          offlineUsername: 'Stress Bot $currentCount',
          avatarDna: mockDna,
          topWearColor: currentCount % 15,
          bottomWearColor: (currentCount + 5) % 15,
          intent: BleIntent.presence,
          rssi: -40 - (currentCount % 50),
          lastSeen: now,
        );
        currentCount++;
      }
    }

    addPeers(300);

    // Automatically start scanning to activate the radar animation and buffer processing loop
    startScanningAndBroadcasting();

    // Force immediate UI processing so the bots show up instantly
    _processBuffer();

    // Set timer to add 10 new users every 3 seconds up to maximum 500
    Get.log(
      'NEARBY_TRACE: Progressively adding 10 users every 3 seconds up to 500...',
    );
    _loadTestTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (currentCount >= 500) {
        Get.log('NEARBY_TRACE: Finished injecting 500 BLE peers.');
        timer.cancel();
        return;
      }
      Get.log('NEARBY_TRACE: Injecting 10 new mock users...');
      addPeers(10);
      _processBuffer(); // Process immediately to trigger UI update
    });
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

    // For load testing visibility, we expand the take limit if crowd exceeds 100
    final displayList = sorted.take(500).toList();
    if (kDebugMode) {
      Get.log(
        'NEARBY_TRACE: Processing buffer loop... displayList has ${displayList.length} items',
      );
    }

    if (_shouldRebuildUi(users, displayList)) {
      users.assignAll(displayList);
      if (kDebugMode) {
        Get.log(
          'NEARBY_TRACE: UI assigned successfully. Users count: ${users.length}',
        );
      }
    }

    // Note: _peerConnectionStatus is kept up-to-date by event-driven calls
    // (sendConnectionRequest, _handleAccepted, _handleIncomingRequest, etc.)
    // so we don't need a full DB query on every 2-second buffer flush.

    // ── Handle incoming connection requests ──
    // Skip entirely if mutual limit is already reached — no point processing
    // requests we can never accept.
    final mutualLimitReached =
        sessionMutualConnections.value >= maxMutualPerSession;

    for (final peer in sorted) {
      final peerKey = _canonicalHash(peer.myHash);

      // ── Lazy re-accept: if we already accepted this peer but they are
      // still broadcasting requestConnection (meaning they missed our
      // accept), re-broadcast the accept so it gets delivered.
      if (peer.intent == BleIntent.requestConnection && _isTargetedToMe(peer)) {
        final existingConn = _peerConnectionStatus[peerKey];
        if (existingConn == ConnectionStatus.accepted) {
          // They missed our accept — re-broadcast it.
          if (!_acceptBroadcastQueue.contains(peer.myHash) &&
              (_acceptBroadcastTimer == null ||
                  !_acceptBroadcastTimer!.isActive)) {
            Get.log(
              'NearbyController: Lazy re-accept for ${peer.myHash} '
              '(peer still requesting, we already accepted).',
            );
            _enqueueAcceptBroadcast(peer.myHash);
          }
          continue; // Skip normal incoming handling for this peer.
        }
      }

      // Queue new incoming requests only if we can still accept.
      if (!mutualLimitReached &&
          peer.intent == BleIntent.requestConnection &&
          _isTargetedToMe(peer) &&
          !_knownIncomingHashes.contains(peerKey)) {
        _knownIncomingHashes.add(peerKey);
        _incomingRequestQueue.add(peer);
      }

      // Handle accept responses (from peers we requested).
      if (!mutualLimitReached &&
          peer.intent == BleIntent.acceptConnection &&
          _isTargetedToMe(peer) &&
          !_handledAccepts.contains(peerKey)) {
        _handledAccepts.add(peerKey);
        _handleAccepted(peer);
      }
    }

    // Surface one queued incoming request at a time.
    // Only show the next if the current banner is empty (user acted on it).
    if (!mutualLimitReached &&
        currentIncomingPeer.value == null &&
        _incomingRequestQueue.isNotEmpty) {
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
      // ── Per-session mutual limit gate ──────────────────────────────────
      if (sessionMutualConnections.value >= maxMutualPerSession) {
        Get.log(
          'NearbyController: Mutual limit reached ($maxMutualPerSession). '
          'Ignoring auto-accept for ${peer.myHash}.',
        );
        return;
      }
      // Auto-accept — both sides want to connect (mutual request).
      sessionMutualConnections.value++;
      await _db.updateConnectionStatus(existing.id!, ConnectionStatus.accepted);
      await _db.upsertKnownUser(
        UserProfile(
          offlineId: peer.myHash,
          displayName:
              peer.offlineUsername != null && peer.offlineUsername!.isNotEmpty
              ? '@${peer.offlineUsername}'
              : 'User ${displayPeerId(peer.myHash)}',
          avatarDna: peer.avatarDna,
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
      _checkAndAutoComplete();
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

    // Surface the request as a non-blocking banner instead of a modal dialog.
    currentIncomingPeer.value = peer;
  }

  /// Called by the UI when the user taps "Accept" on the incoming request banner.
  Future<void> acceptCurrentIncoming() async {
    final peer = currentIncomingPeer.value;
    if (peer == null) return;
    currentIncomingPeer.value = null; // dismiss banner immediately
    await _acceptPeer(peer);
  }

  /// Called by the UI when the user taps "Ignore" on the incoming request banner.
  void ignoreCurrentIncoming() {
    currentIncomingPeer.value = null; // dismiss banner
  }

  /// Shared logic for accepting a peer — persists to DB and queues the
  /// accept broadcast so it stays on-air long enough for the other side
  /// to detect it.
  Future<void> _acceptPeer(DiscoveredPeer peer) async {
    // ── Per-session mutual limit gate ──────────────────────────────────
    if (sessionMutualConnections.value >= maxMutualPerSession) {
      Get.snackbar(
        'Mutual Connection Limit',
        'You already have $maxMutualPerSession connections at this place.',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return;
    }
    sessionMutualConnections.value++;

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
        avatarDna: peer.avatarDna,
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
    _checkAndAutoComplete();
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
      targetId: target,
    );

    // Keep this accept on-air for 10 seconds before moving to the next.
    // (Increased from 5s to survive crowded BLE environments where the
    // requester may not scan our advertisement quickly.)
    _acceptBroadcastTimer = Timer(const Duration(seconds: 10), () {
      _processNextAcceptBroadcast();
    });
  }

  /// Handles an acceptance from a peer we previously requested.
  Future<void> _handleAccepted(DiscoveredPeer peer) async {
    // ── Per-session mutual limit gate ──────────────────────────────────
    if (sessionMutualConnections.value >= maxMutualPerSession) {
      Get.log(
        'NearbyController: Mutual limit reached ($maxMutualPerSession). '
        'Ignoring accept from ${peer.myHash}.',
      );
      return;
    }

    // ── Stop request retries — the request was accepted! ───────────────
    if (pendingRequestTarget.value != null &&
        _samePeer(pendingRequestTarget.value!, peer.myHash)) {
      _requestRetryTimer?.cancel();
      _requestRetryTimer = null;
      _requestRetryCount = 0;
    }

    final existing = await _db.findConnectionByOther(peer.myHash);
    if (existing != null) {
      if (existing.status != ConnectionStatus.accepted) {
        sessionMutualConnections.value++;
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
          avatarDna: peer.avatarDna,
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
      sessionMutualConnections.value++;
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
          avatarDna: peer.avatarDna,
        ),
        rssi: peer.rssi,
      );
      _refreshConnectionsList();
      await _refreshPeerConnectionStatus();
      await _ensureChatReadyForPeer(peer.myHash);
    }
    _checkAndAutoComplete();
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

  // ── Blocklist & Moderation ────────────────────────────────────────────────

  /// Set of strictly blocked user hashes (fetched from SQLite).
  /// These users are immediately dropped from [_buffer] and never show on radar.
  final RxSet<String> _blockedHashes = <String>{}.obs;

  /// Expose method for ChatController to add to blocklist instantly.
  void addBlockedUser(String offlineId) {
    final hash = _canonicalHash(offlineId);
    _blockedHashes.add(hash);
    _peerConnectionStatus[hash] = ConnectionStatus.blocked;

    // Prune actively from buffers and view
    users.removeWhere((p) => _canonicalHash(p.myHash) == hash);
    Get.log(
      'NearbyController: Instantly dropped blocked user $hash from radar.',
    );
  }

  /// Direct UI hook for blocking users from the radar screen
  void blockUser(String offlineId) {
    addBlockedUser(offlineId);
    Get.snackbar(
      'User Blocked',
      'They have been removed from your radar.',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.redAccent,
      colorText: Colors.white,
    );
  }

  /// Direct UI hook for reporting users from the radar screen
  void reportUser(String offlineId) {
    Get.log('Reported $offlineId from radar');
    blockUser(offlineId);
  }

  // ── Broadcast & Destiny ────────────────────────────────────────────────────

  /// Refreshes the BLE broadcast payload to reflect updated profile or state.
  void refreshBroadcast() {
    if (scanning.value) {
      _ble.stopScanning();
      _ble.startScanning();
    }
  }

  /// Checks if a peer matches the user's Destiny settings
  bool isDestinyMatch(String targetHash) {
    // Destiny feature logic placeholder
    return false;
  }

  /// Force a Destiny match for demo/QA purposes
  void forceDestinyMatchAndAlert(String targetHash) {
    // Destiny alert logic placeholder
  }

  // ── Chaos QA Mock Environment ──────────────────────────────────────────

  /// Injects [count] fake users into the buffer to simulate a crowded room.
  void injectMockPeers(int count) {
    final random = math.Random();
    final chars = '0123456789abcdef';

    for (var i = 0; i < count; i++) {
      final fakeId = List.generate(
        10,
        (index) => chars[random.nextInt(16)],
      ).join();

      final peer = DiscoveredPeer(
        deviceId: 'QA_$fakeId',
        myHash: fakeId,
        avatarDna: random.nextInt(256),
        topWearColor: random.nextInt(16),
        bottomWearColor: random.nextInt(16),
        intent: BleIntent.presence,
        rssi: -40 - random.nextInt(56), // Fluctuates between -40 and -95
        lastSeen: DateTime.now(),
      );

      _onPeerDiscovered(peer); // Feed straight into the routing buffer
    }

    Get.snackbar(
      'Chaos Engine',
      'Injected $count fake users into radar buffer.',
      backgroundColor: Colors.amber,
      colorText: Colors.black,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  /// Injects a perfectly synthesized 3-byte blink request targeting me.
  void injectMockBlink() {
    final random = math.Random();
    final chars = '0123456789abcdef';
    final fakeId = List.generate(10, (_) => chars[random.nextInt(16)]).join();

    // The Blink Protocol: 0xFF + SenderHash[0] + TargetHash[0]
    final targetHash0 = _canonicalHash(myHash)[0];

    final peer = DiscoveredPeer(
      deviceId: 'Blink_$fakeId',
      myHash: fakeId,
      avatarDna: 0,
      topWearColor: 0,
      bottomWearColor: 0,
      intent: BleIntent.requestConnection,
      targetHash:
          '$targetHash0${chars[random.nextInt(16)]}', // Hijacks 1st byte routing
      rssi: -45, // Strong signal to force priority
      lastSeen: DateTime.now(),
    );

    _onPeerDiscovered(peer);

    Get.snackbar(
      'Chaos Engine',
      'Injected mock Blink Request from $fakeId.',
      backgroundColor: Colors.amber,
      colorText: Colors.black,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  // ── Session Auto-Complete Engine ───────────────────────────────────────
  //
  // When a session limit is reached, we give a short grace period (10s) for
  // any in-flight accept broadcasts to finish, then fully shut down scanning
  // and flip [sessionComplete] so the UI can show the summary screen.

  void _checkAndAutoComplete() {
    if (!_isSessionLimitReached) return;
    if (sessionComplete.value) return; // Already winding down.
    if (_autoCompleteTimer?.isActive ?? false) return; // Already scheduled.

    // Determine the reason for display.
    if (sessionMutualConnections.value >= maxMutualPerSession) {
      sessionEndReason.value =
          'You made $maxMutualPerSession connections at this place! 🎉';
    } else {
      sessionEndReason.value =
          'You used all $maxRequestsPerSession requests at this place.';
    }

    Get.log(
      'NearbyController: Session limit reached. '
      'Requests=${sessionRequestsSent.value}/$maxRequestsPerSession, '
      'Mutuals=${sessionMutualConnections.value}/$maxMutualPerSession. '
      'Auto-completing in 10s...',
    );

    // Grace period: let pending accept broadcasts finish (they take ~5s each).
    _autoCompleteTimer = Timer(const Duration(seconds: 10), () {
      if (!scanning.value) return; // User already stopped manually.
      sessionComplete.value = true;
      stopScanningAndBroadcasting();
      _startCooldownTimer(); // Prevent immediate session restart.
      Get.log('NearbyController: ✅ Session auto-completed. Cooldown started.');
    });
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _batchTimer?.cancel();
    _revertToPresenceTimer?.cancel();
    _acceptBroadcastTimer?.cancel();
    _autoCompleteTimer?.cancel();
    _requestRetryTimer?.cancel();
    _cooldownTickTimer?.cancel();
    _loadTestTimer?.cancel();
    _peerSub?.cancel();
    super.onClose();
  }
}
