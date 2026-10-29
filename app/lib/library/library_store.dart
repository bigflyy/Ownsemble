import 'package:sqlite3/sqlite3.dart';

import 'track.dart';

/// A song to add or update, before it has a library id.
class NewTrack {
  const NewTrack({
    required this.source,
    required this.artist,
    required this.title,
    required this.durationSec,
    required this.addedAt,
    this.album,
    this.sourceKey,
    this.accessKey,
    this.localPath,
  });

  final TrackSource source;
  final String artist;
  final String title;
  final String? album;
  final int durationSec;

  /// When the song was added to its source library, Unix seconds.
  final int addedAt;
  final String? sourceKey;
  final String? accessKey;
  final String? localPath;
}

/// The library database.
///
/// SQLite calls are synchronous; at 10,000 songs every query here takes a few
/// milliseconds, so the UI thread calls them directly.
class LibraryStore {
  LibraryStore._(this._db);

  /// Opens (and if needed creates) the library at [path].
  /// Pass ':memory:' for tests.
  factory LibraryStore.open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    _createSchema(db);
    return LibraryStore._(db);
  }

  final Database _db;

  static void _createSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS tracks (
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL,
        source_key TEXT,
        access_key TEXT,
        artist TEXT NOT NULL,
        title TEXT NOT NULL,
        album TEXT,
        duration_sec INTEGER NOT NULL,
        added_at INTEGER NOT NULL,
        local_path TEXT,
        UNIQUE (source, source_key)
      )
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS tracks_by_added ON tracks (added_at DESC, id DESC)',
    );
    // Leftover from the first speed-gate build, which searched with FTS5.
    db.execute('DROP TABLE IF EXISTS tracks_fts');
  }

  /// Number of songs in the library.
  int count() =>
      _db.select('SELECT count(*) AS n FROM tracks').first['n'] as int;

  /// Adds songs, or updates songs already present (same source and key).
  /// Returns their library ids in input order. Runs in one transaction.
  List<int> upsertAll(Iterable<NewTrack> tracks) {
    final upsert = _db.prepare('''
      INSERT INTO tracks (source, source_key, access_key, artist, title, album,
                          duration_sec, added_at, local_path)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (source, source_key) DO UPDATE SET
        access_key = excluded.access_key,
        artist = excluded.artist,
        title = excluded.title,
        album = excluded.album,
        duration_sec = excluded.duration_sec,
        added_at = excluded.added_at,
        local_path = coalesce(excluded.local_path, tracks.local_path)
      RETURNING id
    ''');
    final ids = <int>[];
    _db.execute('BEGIN');
    try {
      for (final track in tracks) {
        final id =
            upsert.select([
                  track.source.name,
                  track.sourceKey,
                  track.accessKey,
                  track.artist,
                  track.title,
                  track.album,
                  track.durationSec,
                  track.addedAt,
                  track.localPath,
                ]).first['id']
                as int;
        ids.add(id);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      upsert.close();
    }
    return ids;
  }

  /// Records that a song's audio is now cached at [path].
  void setLocalPath(int id, String path) =>
      _db.execute('UPDATE tracks SET local_path = ? WHERE id = ?', [path, id]);

  /// The whole library, newest first.
  List<Track> loadAll() {
    final rows = _db.select('''
      SELECT id, source, source_key, access_key, artist, title, album,
             duration_sec, local_path
      FROM tracks ORDER BY added_at DESC, id DESC
    ''');
    return [
      for (final row in rows)
        Track(
          id: row['id'] as int,
          source: TrackSource.values.byName(row['source'] as String),
          sourceKey: row['source_key'] as String?,
          accessKey: row['access_key'] as String?,
          artist: row['artist'] as String,
          title: row['title'] as String,
          album: row['album'] as String?,
          durationSec: row['duration_sec'] as int,
          localPath: row['local_path'] as String?,
        ),
    ];
  }

  void close() => _db.close();
}
