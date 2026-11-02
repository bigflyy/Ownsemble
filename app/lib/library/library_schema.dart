import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Schema version this build reads and writes (`PRAGMA user_version`).
///
/// 0 is the speed-gate build's single `tracks` table (or an empty file).
const librarySchemaVersion = 3;

/// Thrown when the library was written by a newer build of the app.
class NewerLibraryException implements Exception {
  NewerLibraryException(this.version);

  final int version;

  @override
  String toString() =>
      'The library has schema version $version; this build knows up to '
      '$librarySchemaVersion.';
}

/// Where a stored song's file is: stored paths are relative to the data
/// folder, so the folder can move and the app can start from anywhere.
String resolveAudioPath(String dataDir, String storedPath) =>
    p.isAbsolute(storedPath) ? storedPath : p.join(dataDir, storedPath);

/// Brings [db] to [librarySchemaVersion] in one transaction.
///
/// [dataDir] is where relative audio paths point; the migration from version
/// 0 measures cached files there and forgets files that are missing. Null
/// (an in-memory database) skips that check.
void migrateLibrary(Database db, {String? dataDir}) {
  final version = db.select('PRAGMA user_version').first.values.first as int;
  if (version == librarySchemaVersion) return;
  if (version > librarySchemaVersion) throw NewerLibraryException(version);

  db.execute('BEGIN');
  try {
    if (version < 1) _upgradeToVersion1(db, dataDir);
    if (version < 2) _addCoverSizes(db);
    if (version < 3) _addVkAlbumTitles(db);
    db.execute('PRAGMA user_version = $librarySchemaVersion');
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Creates the version 1 tables, taking over a speed-gate `tracks` table.
void _upgradeToVersion1(Database db, String? dataDir) {
  final hasGateTracks = db
      .select(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tracks'",
      )
      .isNotEmpty;
  if (hasGateTracks) {
    // The index moves with the renamed table but keeps its name, which the
    // new tracks table needs.
    db.execute('ALTER TABLE tracks RENAME TO tracks_v0');
    db.execute('DROP INDEX IF EXISTS tracks_by_added');
  }
  _createVersion1(db);
  if (hasGateTracks) _copyFromVersion0(db, dataDir);
}

/// Version 2: two more sizes of each cover. The next sync fills them in.
void _addCoverSizes(Database db) {
  db.execute('ALTER TABLE tracks ADD COLUMN cover_mid_url TEXT');
  db.execute('ALTER TABLE tracks ADD COLUMN cover_full_url TEXT');
}

/// Version 3: the real titles of albums VK calls "unnamed" on a song, by the
/// album's "ownerId_albumId". The album's access key is left out: it may
/// change, the album does not. The next sync fills the table in.
void _addVkAlbumTitles(Database db) {
  db.execute('''
    CREATE TABLE vk_album_titles (
      album_key TEXT PRIMARY KEY,
      title TEXT NOT NULL
    )
  ''');
}

void _createVersion1(Database db) {
  // Times the app sets are Unix milliseconds (`_ms`); `tracks.added_at` is
  // the source's own date in Unix seconds.
  db.execute('''
    CREATE TABLE sources (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      account TEXT,
      name TEXT NOT NULL,
      last_sync_at_ms INTEGER,
      last_sync_error TEXT,
      UNIQUE (kind, account)
    )
  ''');
  db.execute('''
    CREATE TABLE tracks (
      id INTEGER PRIMARY KEY,
      source_id INTEGER NOT NULL REFERENCES sources (id),
      source_key TEXT NOT NULL,
      access_key TEXT,
      artist TEXT NOT NULL,
      title TEXT NOT NULL,
      album TEXT,
      duration_sec INTEGER NOT NULL,
      added_at INTEGER NOT NULL,
      cover_url TEXT,
      cover_large_url TEXT,
      tint INTEGER,
      gone_at_ms INTEGER,
      UNIQUE (source_id, source_key)
    )
  ''');
  db.execute('CREATE INDEX tracks_by_added ON tracks (added_at DESC, id DESC)');
  db.execute('''
    CREATE TABLE audio_files (
      track_id INTEGER PRIMARY KEY REFERENCES tracks (id) ON DELETE CASCADE,
      path TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      pinned INTEGER NOT NULL DEFAULT 0,
      stored_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE history (
      id INTEGER PRIMARY KEY,
      track_id INTEGER NOT NULL REFERENCES tracks (id),
      played_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX history_by_track ON history (track_id, played_at_ms)',
  );
  db.execute('''
    CREATE TABLE stacks (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE stack_entries (
      id INTEGER PRIMARY KEY,
      stack_id INTEGER NOT NULL REFERENCES stacks (id) ON DELETE CASCADE,
      track_id INTEGER NOT NULL REFERENCES tracks (id),
      added_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX stack_entries_by_stack ON stack_entries (stack_id, id)',
  );
  db.execute('''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
}

/// Moves the speed-gate library (one `tracks` table with a `source` name and
/// a `local_path`) into the version 1 tables.
void _copyFromVersion0(Database db, String? dataDir) {
  // The gate did not record which VK account it synced, so the VK source
  // gets no account; the first sync of an account claims it.
  db.execute('''
    INSERT INTO sources (kind, account, name)
    SELECT DISTINCT source,
           CASE source WHEN 'generated' THEN 'generator' END,
           CASE source WHEN 'vk' THEN 'VK' ELSE 'Generated songs' END
    FROM tracks_v0
  ''');
  db.execute('''
    INSERT INTO tracks (id, source_id, source_key, access_key, artist, title,
                        album, duration_sec, added_at)
    SELECT t.id, s.id, coalesce(t.source_key, 'v0-' || t.id), t.access_key,
           t.artist, t.title, t.album, t.duration_sec, t.added_at
    FROM tracks_v0 t JOIN sources s ON s.kind = t.source
  ''');

  final now = DateTime.now().millisecondsSinceEpoch;
  final files = db.select('''
    SELECT t.id, t.local_path, t.source
    FROM tracks_v0 t WHERE t.local_path IS NOT NULL
  ''');
  final insert = db.prepare('''
    INSERT INTO audio_files (track_id, path, bytes, pinned, stored_at_ms)
    VALUES (?, ?, ?, ?, ?)
  ''');
  try {
    for (final row in files) {
      final path = row['local_path'] as String;
      var bytes = 0;
      if (dataDir != null) {
        final file = File(resolveAudioPath(dataDir, path));
        if (!file.existsSync()) continue;
        bytes = file.lengthSync();
      }
      // Generated songs borrow real songs' files: pin them so the cache
      // limit never deletes audio that filler songs point at.
      final pinned = row['source'] == 'generated' ? 1 : 0;
      insert.execute([row['id'], path, bytes, pinned, now]);
    }
  } finally {
    insert.close();
  }
  db.execute('DROP TABLE tracks_v0');
  // Leftover from the first speed-gate build, which searched with FTS5.
  db.execute('DROP TABLE IF EXISTS tracks_fts');
}
