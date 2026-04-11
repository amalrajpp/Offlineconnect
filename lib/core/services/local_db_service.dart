import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/connection.dart';
import '../models/user_profile.dart';

/// Local SQLite database service for offline-first storage.
///
/// Manages two tables:
/// - `known_users`: profiles of peers we have seen via BLE.
/// - `connections`: connection records between offline identities.
class LocalDbService extends GetxService {
  static const _dbName = 'offline_connect.db';
  static const _dbVersion =
      5; // v2: UNIQUE + index, v3: bio, v4: photo_url, v5: avatar_id

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

    return openDatabase(
      path,
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

  // ── Lifecycle ────────────────────────────────────────

  @override
  void onClose() {
    _db?.close();
    _db = null;
    super.onClose();
  }
}
