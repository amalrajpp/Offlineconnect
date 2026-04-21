import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/connection.dart';
import '../models/message.dart';
import '../models/user_profile.dart';
import 'identity_service.dart';

/// Local SQLite database service for offline-first storage.
///
/// Manages two tables:
/// - `known_users`: profiles of peers we have seen via BLE.
/// - `connections`: connection records between offline identities.
class LocalDbService extends GetxService {
  static const _dbName = 'offline_connect_secure.db';
  static const _dbVersion =
      7; // v2: UNIQUE + index, v3: bio, v4: photo_url, v5: avatar_id, v6: destiny_matches, v7: messages

  Database? _db;

  /// Provides the initialised database instance.
  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  /// Pre-warms the database so the first query is not delayed.
  Future<void> ensureInitialised() async {
    _db ??= await _initDb();
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$_dbName';

    final encryptionKey = Get.find<IdentityService>().dbEncryptionKey;

    return openDatabase(
      path,
      password: encryptionKey,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE known_users (
            offline_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            bio TEXT,
            photo_url TEXT,
            avatar_id INTEGER DEFAULT 0,
            last_seen TEXT,
            last_rssi INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE connections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            my_offline_id TEXT NOT NULL,
            other_offline_id TEXT NOT NULL,
            status INTEGER NOT NULL,
            first_met_at TEXT NOT NULL,
            UNIQUE(my_offline_id, other_offline_id)
          )
        ''');

        // Index for fast lookups by other party's ID.
        await db.execute('''
          CREATE INDEX idx_connections_other
          ON connections(other_offline_id)
        ''');

        await db.execute('''
          CREATE TABLE destiny_matches (
            offline_id TEXT PRIMARY KEY,
            match_score REAL NOT NULL,
            synced_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            read_at TEXT,
            status TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_messages_conv 
          ON messages(conversation_id, created_at)
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Migration: add UNIQUE constraint by recreating the table.
          await db.execute('''
            CREATE TABLE connections_new (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              my_offline_id TEXT NOT NULL,
              other_offline_id TEXT NOT NULL,
              status INTEGER NOT NULL,
              first_met_at TEXT NOT NULL,
              UNIQUE(my_offline_id, other_offline_id)
            )
          ''');
          await db.execute('''
            INSERT OR IGNORE INTO connections_new
              (id, my_offline_id, other_offline_id, status, first_met_at)
            SELECT id, my_offline_id, other_offline_id, status, first_met_at
            FROM connections
          ''');
          await db.execute('DROP TABLE connections');
          await db.execute('ALTER TABLE connections_new RENAME TO connections');
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_connections_other
            ON connections(other_offline_id)
          ''');
        }
        if (oldVersion < 3) {
          // Add bio column to known_users.
          await db.execute('ALTER TABLE known_users ADD COLUMN bio TEXT');
        }
        if (oldVersion < 4) {
          // Add photo_url column to known_users.
          await db.execute('ALTER TABLE known_users ADD COLUMN photo_url TEXT');
        }
        if (oldVersion < 5) {
          // Add avatar_id column to known_users.
          await db.execute(
            'ALTER TABLE known_users ADD COLUMN avatar_id INTEGER DEFAULT 0',
          );
        }
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE destiny_matches (
              offline_id TEXT PRIMARY KEY,
              match_score REAL NOT NULL,
              synced_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              sender_id TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at TEXT NOT NULL,
              read_at TEXT,
              status TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE INDEX idx_messages_conv 
            ON messages(conversation_id, created_at)
          ''');
        }
      },
    );
  }

  // ──────────────────── Known Users ────────────────────

  /// Normalizes peer IDs coming from BLE hashes.
  ///
  /// - Short hex IDs (<= 12 chars) are canonicalized to the first 10 chars
  ///   to unify Android (6-byte hash) and iOS UUID mode (5-byte hash).
  /// - Longer IDs (for example full 32-char offline IDs) are preserved.
  String _canonicalPeerId(String id) {
    final clean = id.trim().toLowerCase();
    final isHex = RegExp(r'^[0-9a-f]+$').hasMatch(clean);
    if (isHex && clean.length <= 12) {
      return clean.length <= 10 ? clean : clean.substring(0, 10);
    }
    return clean;
  }

  bool _samePeerId(String a, String b) {
    return _canonicalPeerId(a) == _canonicalPeerId(b);
  }

  /// Bulk injects fake users and connections to test scrolling and DB load.
  Future<void> runDeveloperLoadTest(String myOfflineId) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now();
    for (int i = 0; i < 1000; i++) {
      final offlineId = 'mock_peer_${i.toString().padLeft(6, '0')}';
      batch.insert('known_users', {
        'offline_id': offlineId,
        'display_name': 'Stress Bot $i',
        'bio': 'Simulated profile for load testing.',
        'photo_url': null,
        'avatar_id': i % 10,
        'last_seen': now.toIso8601String(),
        'last_rssi': -40 - (i % 50),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      if (i < 500) {
        batch.insert('connections', {
          'my_offline_id': myOfflineId,
          'other_offline_id': offlineId,
          'status': i % 10 == 0 ? 1 : 2, // 1=pendingIncoming, 2=accepted
          'first_met_at': now
              .subtract(Duration(days: i % 30, hours: i % 24))
              .toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Inserts or updates a known user profile.
  Future<void> upsertKnownUser(
    UserProfile profile, {
    int? rssi,
    DateTime? lastSeen,
  }) async {
    final db = await database;
    final canonicalOfflineId = _canonicalPeerId(profile.offlineId);
    final profileMap = profile.toMap();
    profileMap['offline_id'] = canonicalOfflineId;
    await db.insert('known_users', {
      ...profileMap,
      'last_seen': (lastSeen ?? DateTime.now()).toIso8601String(),
      'last_rssi': rssi ?? 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Returns all known user profiles.
  Future<List<UserProfile>> getAllKnownUsers() async {
    final db = await database;
    final rows = await db.query('known_users');
    return rows.map((r) => UserProfile.fromMap(r)).toList();
  }

  /// Returns a specific known user profile by offline ID (canonical).
  Future<UserProfile?> getKnownUser(String offlineId) async {
    final db = await database;
    final canonicalId = _canonicalPeerId(offlineId);
    final rows = await db.query(
      'known_users',
      where: 'offline_id = ?',
      whereArgs: [canonicalId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return UserProfile.fromMap(rows.first);
    }
    return null;
  }

  // ──────────────────── Connections ────────────────────

  /// Inserts a new connection record. Uses REPLACE to handle the UNIQUE
  /// constraint — if the same (my, other) pair exists, updates in place.
  Future<int> insertConnection(Connection conn) async {
    final db = await database;
    final canonicalOther = _canonicalPeerId(conn.otherOfflineId);
    final connMap = conn.toMap();
    connMap['other_offline_id'] = canonicalOther;
    return db.insert(
      'connections',
      connMap,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Updates an existing connection's status.
  Future<void> updateConnectionStatus(int id, ConnectionStatus status) async {
    final db = await database;
    await db.update(
      'connections',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Returns all connections, optionally filtered by [status].
  Future<List<Connection>> getConnections({ConnectionStatus? status}) async {
    final db = await database;
    final rows = status != null
        ? await db.query(
            'connections',
            where: 'status = ?',
            whereArgs: [status.index],
          )
        : await db.query('connections');
    return rows.map((r) => Connection.fromMap(r)).toList();
  }

  /// Looks up a connection by the other party's offline ID.
  Future<Connection?> findConnectionByOther(String otherOfflineId) async {
    final db = await database;
    final canonicalOther = _canonicalPeerId(otherOfflineId);

    // First, try canonical exact lookup.
    final rows = await db.query(
      'connections',
      where: 'other_offline_id = ?',
      whereArgs: [canonicalOther],
      limit: 1,
    );
    if (rows.isNotEmpty) return Connection.fromMap(rows.first);

    // Backward compatibility: older rows may contain 12-char hash values.
    // We fetch candidates and match by canonical form in Dart.
    if (canonicalOther.length == 10) {
      final legacyCandidates = await db.query(
        'connections',
        where: 'other_offline_id LIKE ?',
        whereArgs: ['$canonicalOther%'],
      );

      for (final row in legacyCandidates) {
        final conn = Connection.fromMap(row);
        if (_samePeerId(conn.otherOfflineId, canonicalOther)) {
          // Heal legacy row in-place to canonical key when possible.
          try {
            await db.update(
              'connections',
              {'other_offline_id': canonicalOther},
              where: 'id = ?',
              whereArgs: [conn.id],
            );
            return Connection(
              id: conn.id,
              myOfflineId: conn.myOfflineId,
              otherOfflineId: canonicalOther,
              status: conn.status,
              firstMetAt: conn.firstMetAt,
            );
          } catch (_) {
            // If update conflicts due to UNIQUE constraint, keep the found one.
            return conn;
          }
        }
      }
    }

    return null;
  }

  // ──────────────────── Destiny Matches ────────────────────

  /// Saves a list of IDs strictly found via cloud >90% calculation.
  Future<void> saveDestinyMatches(Map<String, double> matches) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final entry in matches.entries) {
        final offlineId = _canonicalPeerId(entry.key);
        await txn.insert('destiny_matches', {
          'offline_id': offlineId,
          'match_score': entry.value,
          'synced_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Checks if a given BLE hash/offline ID is a cached Destiny match.
  Future<bool> isDestinyMatch(String id) async {
    final db = await database;
    final canonicalId = _canonicalPeerId(id);
    final results = await db.query(
      'destiny_matches',
      where: 'offline_id = ?',
      whereArgs: [canonicalId],
      limit: 1,
    );
    return results.isNotEmpty;
  }

  /// Returns the match score if they exist, otherwise null
  Future<double?> getDestinyMatchScore(String id) async {
    final db = await database;
    final canonicalId = _canonicalPeerId(id);
    final results = await db.query(
      'destiny_matches',
      columns: ['match_score'],
      where: 'offline_id = ?',
      whereArgs: [canonicalId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first['match_score'] as double?;
  }

  /// Retrieves all cached destiny IDs
  Future<List<String>> getAllDestinyMatchIds() async {
    final db = await database;
    final results = await db.query('destiny_matches', columns: ['offline_id']);
    return results.map((row) => row['offline_id'] as String).toList();
  }

  // ──────────────────── Messages (Ghost Queue) ────────────────────

  /// Inserts a chat message directly to local database for instant offline UI.
  Future<void> insertMessage(String conversationId, Message message) async {
    final db = await database;
    final map = message.toMap(conversationId);
    if (!map.containsKey('id') || map['id'] == null) {
      map['id'] = DateTime.now().millisecondsSinceEpoch.toString();
    }
    await db.insert(
      'messages',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Updates the status of a specific message in the local database.
  Future<void> updateMessageStatus(String messageId, String status) async {
    final db = await database;
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Retrieves all messages for a specific conversation, ordered by creation time.
  Future<List<Message>> getMessages(String conversationId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => Message.fromMap(r)).toList();
  }

  /// Retrieves the latest message across all conversations, or for a specific one.
  Future<Message?> getLastMessage(String conversationId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return Message.fromMap(rows.first);
    }
    return null;
  }

  // ── Lifecycle ────────────────────────────────────────

  @override
  void onClose() {
    _db?.close();
    _db = null;
    super.onClose();
  }

  /// Wipes all local data.
  Future<void> wipeDatabase() async {
    final db = await database;
    await db.delete('connections');
    await db.delete('known_users');
    await db.delete('messages');
    await db.delete('destiny_matches');
  }
}
