import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'library_records.dart';
import 'library_schema.dart';
import 'track.dart';

export 'library_records.dart';
export 'library_schema.dart' show NewerLibraryException, resolveAudioPath;

/// A song to add or update, before it has a library id.
class NewTrack {
  const NewTrack({
    required this.artist,
    required this.title,
    required this.durationSec,
    required this.addedAt,
    required this.sourceKey,
    this.album,
    this.accessKey,
    this.coverUrl,
    this.coverLargeUrl,
    this.tint,
  });

  final String artist;
  final String title;
  final String? album;
  final int durationSec;

  /// When the song was added to its source library, Unix seconds.
  final int addedAt;

  /// Id inside the source, unique per source.
  final String sourceKey;
  final String? accessKey;
  final String? coverUrl;
  final String? coverLargeUrl;
  final int? tint;
}

/// The library database.
///
/// SQLite calls are synchronous; at 10,000 songs every query here takes a few
/// milliseconds, so the UI thread calls them directly.
class LibraryStore {
  LibraryStore._(this._db);

  /// Opens (and if needed creates or upgrades) the library at [path].
  /// Pass ':memory:' for tests. Relative audio paths are resolved against
  /// the folder of [path].
  factory LibraryStore.open(String path) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute('PRAGMA foreign_keys = ON');
      migrateLibrary(db, dataDir: path == ':memory:' ? null : p.dirname(path));
    } catch (_) {
      db.close();
      rethrow;
    }
    return LibraryStore._(db);
  }

  final Database _db;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// Runs [body] in one transaction.
  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // Sources.

  /// The library id of the source [kind] + [account], created if missing.
  ///
  /// A VK source carried over from the speed-gate library has no account; the
  /// first account asked for takes it over, with its songs.
  int ensureSource(
    TrackSource kind, {
    required String? account,
    required String name,
  }) {
    final existing = _db.select(
      'SELECT id FROM sources WHERE kind = ? AND account IS ?',
      [kind.name, account],
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;
    if (account != null) {
      final unclaimed = _db.select(
        'SELECT id FROM sources WHERE kind = ? AND account IS NULL',
        [kind.name],
      );
      if (unclaimed.isNotEmpty) {
        final id = unclaimed.first['id'] as int;
        _db.execute('UPDATE sources SET account = ? WHERE id = ?', [
          account,
          id,
        ]);
        return id;
      }
    }
    _db.execute('INSERT INTO sources (kind, account, name) VALUES (?, ?, ?)', [
      kind.name,
      account,
      name,
    ]);
    return _db.lastInsertRowId;
  }

  /// All sources with their song counts and last sync result.
  List<SourceInfo> sources() {
    final rows = _db.select('''
      SELECT s.id, s.kind, s.account, s.name, s.last_sync_at_ms,
             s.last_sync_error,
             count(t.id) AS songs, count(t.gone_at_ms) AS gone
      FROM sources s LEFT JOIN tracks t ON t.source_id = s.id
      GROUP BY s.id ORDER BY s.id
    ''');
    return [
      for (final row in rows)
        SourceInfo(
          id: row['id'] as int,
          kind: TrackSource.values.byName(row['kind'] as String),
          account: row['account'] as String?,
          name: row['name'] as String,
          lastSyncAtMs: row['last_sync_at_ms'] as int?,
          lastSyncError: row['last_sync_error'] as String?,
          songCount: row['songs'] as int,
          goneCount: row['gone'] as int,
        ),
    ];
  }

  /// Records how the last sync of [sourceId] ended; null [error] is success.
  void recordSync(int sourceId, {String? error, int? atMs}) => _db.execute(
    'UPDATE sources SET last_sync_at_ms = ?, last_sync_error = ? WHERE id = ?',
    [atMs ?? _now(), error, sourceId],
  );

  // Songs.

  /// Number of songs in the library.
  int count() =>
      _db.select('SELECT count(*) AS n FROM tracks').first['n'] as int;

  /// Adds songs of [sourceId], or updates songs already present (same source
  /// and key). An updated song is no longer marked gone. Returns library ids
  /// in input order. Runs in one transaction.
  List<int> upsertAll(int sourceId, Iterable<NewTrack> tracks) {
    final upsert = _db.prepare('''
      INSERT INTO tracks (source_id, source_key, access_key, artist, title,
                          album, duration_sec, added_at, cover_url,
                          cover_large_url, tint)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (source_id, source_key) DO UPDATE SET
        access_key = excluded.access_key,
        artist = excluded.artist,
        title = excluded.title,
        album = excluded.album,
        duration_sec = excluded.duration_sec,
        added_at = excluded.added_at,
        cover_url = excluded.cover_url,
        cover_large_url = excluded.cover_large_url,
        tint = excluded.tint,
        gone_at_ms = NULL
      RETURNING id
    ''');
    try {
      return _transaction(() {
        return [
          for (final track in tracks)
            upsert.select([
                  sourceId,
                  track.sourceKey,
                  track.accessKey,
                  track.artist,
                  track.title,
                  track.album,
                  track.durationSec,
                  track.addedAt,
                  track.coverUrl,
                  track.coverLargeUrl,
                  track.tint,
                ]).first['id']
                as int,
        ];
      });
    } finally {
      upsert.close();
    }
  }

  /// The whole library, newest first, with each song's stored audio.
  List<Track> loadAll() {
    final rows = _db.select('''
      SELECT t.id, t.source_id, s.kind, t.source_key, t.access_key, t.artist,
             t.title, t.album, t.duration_sec, t.cover_url, t.cover_large_url,
             t.tint, t.gone_at_ms, a.path, a.pinned
      FROM tracks t
      JOIN sources s ON s.id = t.source_id
      LEFT JOIN audio_files a ON a.track_id = t.id
      ORDER BY t.added_at DESC, t.id DESC
    ''');
    return [
      for (final row in rows)
        Track(
          id: row['id'] as int,
          sourceId: row['source_id'] as int,
          source: TrackSource.values.byName(row['kind'] as String),
          sourceKey: row['source_key'] as String,
          accessKey: row['access_key'] as String?,
          artist: row['artist'] as String,
          title: row['title'] as String,
          album: row['album'] as String?,
          durationSec: row['duration_sec'] as int,
          coverUrl: row['cover_url'] as String?,
          coverLargeUrl: row['cover_large_url'] as String?,
          tint: row['tint'] as int?,
          goneAtMs: row['gone_at_ms'] as int?,
          localPath: row['path'] as String?,
          pinned: row['pinned'] == 1,
        ),
    ];
  }

  // Stored audio (cache and downloads).

  /// Records that the audio of [trackId] is stored at [path] ([bytes] long).
  /// A song that is already downloaded stays downloaded.
  void saveAudioFile(
    int trackId,
    String path,
    int bytes, {
    bool pinned = false,
    int? atMs,
  }) => _db.execute(
    '''
    INSERT INTO audio_files (track_id, path, bytes, pinned, stored_at_ms)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT (track_id) DO UPDATE SET
      path = excluded.path,
      bytes = excluded.bytes,
      pinned = max(audio_files.pinned, excluded.pinned),
      stored_at_ms = excluded.stored_at_ms
    ''',
    [trackId, path, bytes, pinned ? 1 : 0, atMs ?? _now()],
  );

  /// Marks the stored audio of [trackId] as downloaded (kept) or as plain
  /// cache. Does nothing when the song has no stored audio.
  void setPinned(int trackId, bool pinned) => _db.execute(
    'UPDATE audio_files SET pinned = ? WHERE track_id = ?',
    [pinned ? 1 : 0, trackId],
  );

  /// Forgets the stored audio of [trackId]; the caller deletes the file.
  void removeAudioFile(int trackId) =>
      _db.execute('DELETE FROM audio_files WHERE track_id = ?', [trackId]);

  // History.

  /// Records a play of [trackId]; returns the History entry id.
  int addPlay(int trackId, {int? atMs}) {
    _db.execute('INSERT INTO history (track_id, played_at_ms) VALUES (?, ?)', [
      trackId,
      atMs ?? _now(),
    ]);
    return _db.lastInsertRowId;
  }

  /// Plays, newest first.
  List<HistoryEntry> history({int limit = 1000}) => [
    for (final row in _db.select(
      'SELECT id, track_id, played_at_ms FROM history '
      'ORDER BY played_at_ms DESC, id DESC LIMIT ?',
      [limit],
    ))
      HistoryEntry(
        row['id'] as int,
        row['track_id'] as int,
        row['played_at_ms'] as int,
      ),
  ];

  // Stacks.

  /// Creates an empty Stack; returns its id.
  int createStack(String name, {int? atMs}) {
    _db.execute('INSERT INTO stacks (name, created_at_ms) VALUES (?, ?)', [
      name,
      atMs ?? _now(),
    ]);
    return _db.lastInsertRowId;
  }

  /// All Stacks in creation order, with their entry counts.
  List<StackInfo> stacks() => [
    for (final row in _db.select('''
      SELECT s.id, s.name, s.created_at_ms, count(e.id) AS entries
      FROM stacks s LEFT JOIN stack_entries e ON e.stack_id = s.id
      GROUP BY s.id ORDER BY s.id
    '''))
      StackInfo(
        id: row['id'] as int,
        name: row['name'] as String,
        createdAtMs: row['created_at_ms'] as int,
        entryCount: row['entries'] as int,
      ),
  ];

  /// Puts [trackId] on top of [stackId], also when it is already on the
  /// Stack (the older entry stays where it is). Returns the entry id.
  int addToStack(int stackId, int trackId, {int? atMs}) {
    _db.execute(
      'INSERT INTO stack_entries (stack_id, track_id, added_at_ms) '
      'VALUES (?, ?, ?)',
      [stackId, trackId, atMs ?? _now()],
    );
    return _db.lastInsertRowId;
  }

  /// Removes one entry from a Stack; other entries of the same song stay.
  void removeStackEntry(int entryId) =>
      _db.execute('DELETE FROM stack_entries WHERE id = ?', [entryId]);

  /// Entries of [stackId], top (newest) first.
  List<StackEntry> stackEntries(int stackId) => [
    for (final row in _db.select(
      'SELECT id, track_id, added_at_ms FROM stack_entries '
      'WHERE stack_id = ? ORDER BY id DESC',
      [stackId],
    ))
      StackEntry(
        row['id'] as int,
        row['track_id'] as int,
        row['added_at_ms'] as int,
      ),
  ];

  // Settings.

  /// The stored value of setting [key], or null when never set.
  String? readSetting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Stores [value] for [key]; null removes the setting.
  void writeSetting(String key, String? value) => value == null
      ? _db.execute('DELETE FROM settings WHERE key = ?', [key])
      : _db.execute(
          'INSERT INTO settings (key, value) VALUES (?, ?) '
          'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
          [key, value],
        );

  void close() => _db.close();
}
