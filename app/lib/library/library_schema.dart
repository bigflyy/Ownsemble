import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Schema version this build reads and writes (`PRAGMA user_version`).
///
/// 0 is the speed-gate build's single `tracks` table (or an empty file).
const librarySchemaVersion = 8;

/// How many colors sources can have; the theme has one per slot, from 1.
const sourceColorCount = 6;

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
    if (version < 4) _addAccounts(db);
    if (version < 5) _addVkAlbumLinks(db);
    if (version < 6) _addSongVersions(db);
    if (version < 7) _addFilePrints(db);
    if (version < 8) _addFoundVersions(db);
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

/// Version 4: several VK accounts. A source gets a color, and the time its
/// account was removed while songs in History, Stacks or on disk kept it
/// alive. A song gets VK's `track_id`, which the next sync fills in, and
/// `same_as`: the row it is a copy of when another account has the same song.
/// Copies stay in the table, each with its own account's key, so a merged song
/// streams through whichever account still has it; only the row they point at
/// is listed, and History, Stacks and stored audio point at that row.
void _addAccounts(Database db) {
  db.execute('ALTER TABLE sources ADD COLUMN color INTEGER');
  db.execute('ALTER TABLE sources ADD COLUMN removed_at_ms INTEGER');
  db.execute('ALTER TABLE tracks ADD COLUMN vk_track_id INTEGER');
  db.execute(
    'ALTER TABLE tracks ADD COLUMN same_as INTEGER REFERENCES tracks (id)',
  );
  db.execute(
    'CREATE INDEX tracks_copies ON tracks (same_as) WHERE same_as IS NOT NULL',
  );
  final vkSources = db.select(
    "SELECT id FROM sources WHERE kind = 'vk' ORDER BY id",
  );
  for (final (index, source) in vkSources.indexed) {
    db.execute('UPDATE sources SET color = ? WHERE id = ?', [
      index % sourceColorCount + 1,
      source['id'],
    ]);
  }
}

/// Version 5: which VK album a song is from, so the album can be opened:
/// the album's "ownerId_albumId" and the access key VK needs to list it.
/// Kept on every row, copies too, since each account's reply carries it. The
/// next sync fills them in, without counting the songs as changed.
void _addVkAlbumLinks(Database db) {
  db.execute('ALTER TABLE tracks ADD COLUMN vk_album_key TEXT');
  db.execute('ALTER TABLE tracks ADD COLUMN vk_album_access_key TEXT');
  db.execute(
    'CREATE INDEX tracks_by_album ON tracks (vk_album_key) '
    'WHERE vk_album_key IS NOT NULL',
  );
}

/// Version 6: which file plays for a song whose VK file was swapped for
/// another recording (Stage K): VK kept the length it listed for the old
/// one, and the file plays more than 3 s longer or shorter.
///
/// `state` is how the file was chosen: "suggested" (found by the app, an
/// upload within 1 s of the listed length), "picked" (by the user) or
/// "none" (nothing matches: VK's file plays, marked as another recording).
/// `file_key` and `file_access_key` name the upload that plays ("ownerId_
/// audioId"; null for "none") and `file_seconds` how long its file plays;
/// `own_seconds` and `own_bytes` describe VK's file for the song when the
/// swap was found, and `listed_sec` the length listed then: when a sync
/// brings another listed length, the choice no longer applies.
void _addSongVersions(Database db) {
  db.execute('''
    CREATE TABLE song_versions (
      track_id INTEGER PRIMARY KEY REFERENCES tracks (id) ON DELETE CASCADE,
      state TEXT NOT NULL,
      file_key TEXT,
      file_access_key TEXT,
      file_seconds REAL,
      own_seconds REAL NOT NULL,
      own_bytes INTEGER,
      listed_sec INTEGER NOT NULL,
      decided_at_ms INTEGER NOT NULL
    )
  ''');
}

/// Version 7: merging songs of several accounts only when they are one file
/// (Stage L). `vk_file_prints` holds a print of VK's file for each row worth
/// comparing (see `file_print.dart`): its size, a hash of a few samples and
/// how long it plays; size and hash are null when VK gave no file.
/// `listed_sec` is the length listed when it was read: another one means
/// the print is old. `tracks.same_likely` is 1 on a copy merged only by the
/// likely rule, which the user can switch off. Old merges stay until the
/// next sync has read both files.
void _addFilePrints(Database db) {
  db.execute('''
    CREATE TABLE vk_file_prints (
      track_id INTEGER PRIMARY KEY REFERENCES tracks (id) ON DELETE CASCADE,
      listed_sec INTEGER NOT NULL,
      bytes INTEGER,
      sample INTEGER,
      seconds REAL,
      checked_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute(
    'ALTER TABLE tracks ADD COLUMN same_likely INTEGER NOT NULL DEFAULT 0',
  );
}

/// Version 8: the uploads of a song that VK's search found, kept so that
/// the song's versions open at once (user, 2026-11-06: "didnt you say you
/// prefind them? why does it still load them?"). One row per upload,
/// `position` in the order they were found; `seconds` and `bytes` describe
/// its file as measured (null: VK gave no file or it could not be read).
/// The whole list of a song is replaced at each search; no link is kept.
void _addFoundVersions(Database db) {
  db.execute('''
    CREATE TABLE found_versions (
      track_id INTEGER NOT NULL REFERENCES tracks (id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      file_key TEXT NOT NULL,
      access_key TEXT,
      artist TEXT NOT NULL,
      title TEXT NOT NULL,
      album TEXT,
      cover_url TEXT,
      cover_large_url TEXT,
      listed_sec INTEGER NOT NULL,
      seconds REAL,
      bytes INTEGER,
      official INTEGER NOT NULL DEFAULT 0,
      vk_track_id INTEGER,
      found_at_ms INTEGER NOT NULL,
      PRIMARY KEY (track_id, file_key)
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
