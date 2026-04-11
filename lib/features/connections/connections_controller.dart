import 'package:get/get.dart';

import '../../core/models/connection.dart';
import '../../core/services/firebase_sync_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/local_db_service.dart';

/// Manages the list of accepted (and pending) connections from the local DB.
class ConnectionsController extends GetxController {
  final LocalDbService _db = Get.find<LocalDbService>();
  final FirebaseSyncService _firebase = Get.find<FirebaseSyncService>();
  final IdentityService _identity = Get.find<IdentityService>();

  /// Observable list of all connections (drives the UI via Obx).
  final RxList<Connection> connections = <Connection>[].obs;

  /// Tracks in-flight request actions to prevent double taps.
  final RxSet<int> _requestActionBusyIds = <int>{}.obs;

  bool isRequestActionBusy(int? connectionId) {
    if (connectionId == null) return false;
    return _requestActionBusyIds.contains(connectionId);
  }

  String _canonicalPeerId(String id) {
    final clean = id.trim().toLowerCase();
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
    if (isHex && clean.length <= 12) {
      return clean.length <= 10 ? clean : clean.substring(0, 10);
    }
    if (isHex && clean.length >= 10) {
      return clean.substring(0, 10);
    }
    return clean;
  }

  Future<List<Connection>> _hidePeersAlreadyInChats(
    List<Connection> all,
  ) async {
    // Keep non-accepted statuses visible in Connections.
    final hasAccepted = all.any((c) => c.status == ConnectionStatus.accepted);
    if (!hasAccepted || !_firebase.isFirebaseAvailable) return all;

    if (!_firebase.isSignedIn) {
      await _firebase.signInAnonymously(_identity.identity);
    }
    if (!_firebase.isSignedIn) return all;

    final startedPeers = await _firebase.startedChatPeerKeys(
      _identity.identity.offlineId,
    );
    if (startedPeers.isEmpty) return all;

    return all.where((conn) {
      if (conn.status != ConnectionStatus.accepted) return true;
      final peerKey = _canonicalPeerId(conn.otherOfflineId);
      return !startedPeers.contains(peerKey);
    }).toList();
  }

  @override
  void onInit() {
    super.onInit();
    loadConnections();
  }

  /// Loads all connections from the local database.
  Future<void> loadConnections() async {
    try {
      final all = await _db.getConnections();
      final filtered = await _hidePeersAlreadyInChats(all);
      connections.assignAll(filtered);
    } catch (e) {
      Get.log('ConnectionsController: loadConnections failed – $e');
    }
  }

  /// Loads only accepted connections.
  Future<void> loadAcceptedConnections() async {
    try {
      final accepted = await _db.getConnections(
        status: ConnectionStatus.accepted,
      );
      final filtered = await _hidePeersAlreadyInChats(accepted);
      connections.assignAll(filtered);
    } catch (e) {
      Get.log('ConnectionsController: loadAccepted failed – $e');
    }
  }

  /// Refreshes the connection list (called after a new connection is made).
  Future<void> reloadConnections() async => loadConnections();

  /// Accepts an incoming pending request and prepares chat conversation.
  Future<void> acceptIncomingRequest(Connection conn) async {
    if (conn.id == null) return;
    if (conn.status != ConnectionStatus.pendingIncoming) return;
    if (isRequestActionBusy(conn.id)) return;

    _requestActionBusyIds.add(conn.id!);

    try {
      await _db.updateConnectionStatus(conn.id!, ConnectionStatus.accepted);

      if (_firebase.isFirebaseAvailable) {
        if (!_firebase.isSignedIn) {
          await _firebase.signInAnonymously(_identity.identity);
        }
        if (_firebase.isSignedIn) {
          await _firebase.ensureConversation(
            _identity.identity.offlineId,
            conn.otherOfflineId,
          );
        }
      }

      await loadConnections();
      Get.snackbar(
        'Request Accepted',
        'You are now connected.',
        snackPosition: SnackPosition.BOTTOM,
      );
    } catch (e) {
      Get.log('ConnectionsController: acceptIncomingRequest failed – $e');
      Get.snackbar(
        'Error',
        'Could not accept request.',
        snackPosition: SnackPosition.BOTTOM,
      );
    } finally {
      _requestActionBusyIds.remove(conn.id!);
    }
  }

  /// Ignores an incoming request by moving it to blocked.
  Future<void> ignoreIncomingRequest(Connection conn) async {
    if (conn.id == null) return;
    if (conn.status != ConnectionStatus.pendingIncoming) return;
    if (isRequestActionBusy(conn.id)) return;

    _requestActionBusyIds.add(conn.id!);

    try {
      await _db.updateConnectionStatus(conn.id!, ConnectionStatus.blocked);
      await loadConnections();
      Get.snackbar(
        'Request Ignored',
        'This request has been ignored.',
        snackPosition: SnackPosition.BOTTOM,
      );
    } catch (e) {
      Get.log('ConnectionsController: ignoreIncomingRequest failed – $e');
      Get.snackbar(
        'Error',
        'Could not ignore request.',
        snackPosition: SnackPosition.BOTTOM,
      );
    } finally {
      _requestActionBusyIds.remove(conn.id!);
    }
  }
}
