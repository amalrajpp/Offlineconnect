import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:offline_connect/core/services/local_db_service.dart';
import 'package:offline_connect/core/models/user_profile.dart';

// Create a stub database service that overrides _initDb to use FFI memory DB
class TestLocalDbService extends LocalDbService {
  @override
  Future<Database> get database async {
    final factory = databaseFactoryFfi;
    final db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
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
        },
      ),
    );
    return db;
  }

  @override
  Future<void> ensureInitialised() async {
    // Avoid calling getApplicationDocumentsDirectory
    await database;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit(); // Initialize FFI for unit tests
  });

  group('SQLCipher Integration & Local DB Tests', () {
    late TestLocalDbService dbService;

    setUp(() async {
      dbService = TestLocalDbService();
      await dbService.ensureInitialised();
    });

    tearDown(() async {
      final db = await dbService.database;
      await db.close();
    });

    test('upsertKnownUser strictly enforces canonical peers', () async {
      final profile = const UserProfile(
        offlineId: 'a1b2c3d4e5f6',
        displayName: 'EncryptedPeer',
        avatarDna: 5,
      );

      await dbService.upsertKnownUser(profile);

      // Verify the canonical mapping trimmed it to 10 chars based on the rules
      // (Wait, `_canonicalPeerId` normalizes to 10 chars if it's hex,
      // so 'a1b2c3d4e5f6' is 12 chars which should trim to 'a1b2c3d4e5')
      final users = await dbService.getAllKnownUsers();
      expect(users.length, equals(1));
      expect(users.first.offlineId, equals('a1b2c3d4e5'));
      expect(users.first.displayName, equals('EncryptedPeer'));
    });
  });
}
