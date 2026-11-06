import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../playback/mp3_length.dart' show FileFacts, otherRecordingSeconds;

import 'file_print.dart';
import 'library_records.dart';
import 'library_schema.dart';
import 'merge_plan.dart';
import 'same_song.dart';
import 'song_version.dart';
import 'track.dart';

export 'library_records.dart';
export 'library_schema.dart'
    show NewerLibraryException, resolveAudioPath, sourceColorCount;

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
    this.coverMidUrl,
    this.coverFullUrl,
    this.tint,
    this.vkTrackId,
    this.vkAlbumKey,
    this.vkAlbumAccessKey,
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
  final String? coverMidUrl;
  final String? coverFullUrl;
  final int? tint;

  /// VK's id of the recording, for finding the song in other accounts.
  final int? vkTrackId;

  /// The VK album the song is from, "ownerId_albumId", and the key VK needs
  /// to list that album's songs.
  final String? vkAlbumKey;
  final String? vkAlbumAccessKey;

  /// This song with other cover links.
  NewTrack withCovers({
    required String? coverUrl,
    required String? coverLargeUrl,
    required String? coverMidUrl,
    required String? coverFullUrl,
  }) => NewTrack(
    artist: artist,
    title: title,
    album: album,
    durationSec: durationSec,
    addedAt: addedAt,
    sourceKey: sourceKey,
    accessKey: accessKey,
    coverUrl: coverUrl,
    coverLargeUrl: coverLargeUrl,
    coverMidUrl: coverMidUrl,
    coverFullUrl: coverFullUrl,
    tint: tint,
    vkTrackId: vkTrackId,
    vkAlbumKey: vkAlbumKey,
    vkAlbumAccessKey: vkAlbumAccessKey,
  );
}

/// The library database.
///
/// SQLite calls are synchronous; at 10,000 songs every query here takes a few
/// milliseconds, so the UI thread calls them directly.
class LibraryStore implements PlayLog {
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
      // The background sync writes through its own connection; wait for it
      // instead of failing with "database is locked".
      db.execute('PRAGMA busy_timeout = 5000');
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
  /// first account asked for takes it over, with its songs. An account removed
  /// earlier comes back with what stayed of its songs.
  int ensureSource(
    TrackSource kind, {
    required String? account,
    required String name,
  }) {
    final existing = _db.select(
      'SELECT id FROM sources WHERE kind = ? AND account IS ?',
      [kind.name, account],
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      _db.execute('UPDATE sources SET removed_at_ms = NULL WHERE id = ?', [id]);
      return id;
    }
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
    _db.execute(
      'INSERT INTO sources (kind, account, name, color) VALUES (?, ?, ?, ?)',
      [kind.name, account, name, _freeColor()],
    );
    return _db.lastInsertRowId;
  }

  /// The lowest color slot no source uses; with every slot taken they repeat.
  int _freeColor() {
    final used = _db
        .select('SELECT color FROM sources WHERE removed_at_ms IS NULL')
        .map((row) => row['color'] as int?)
        .nonNulls
        .toList();
    for (var slot = 1; slot <= sourceColorCount; slot++) {
      if (!used.contains(slot)) return slot;
    }
    return used.length % sourceColorCount + 1;
  }

  /// All sources with their song counts and last sync result. Removed accounts
  /// are left out, though songs of theirs may stay in History or Stacks.
  List<SourceInfo> sources() {
    final rows = _db.select('''
      SELECT s.id, s.kind, s.account, s.name, s.color, s.last_sync_at_ms,
             s.last_sync_error,
             count(t.id) AS songs, count(t.gone_at_ms) AS gone
      FROM sources s LEFT JOIN tracks t ON t.source_id = s.id
      WHERE s.removed_at_ms IS NULL
      GROUP BY s.id ORDER BY s.id
    ''');
    return [
      for (final row in rows)
        SourceInfo(
          id: row['id'] as int,
          kind: TrackSource.values.byName(row['kind'] as String),
          account: row['account'] as String?,
          name: row['name'] as String,
          color: row['color'] as int? ?? 1,
          lastSyncAtMs: row['last_sync_at_ms'] as int?,
          lastSyncError: row['last_sync_error'] as String?,
          songCount: row['songs'] as int,
          goneCount: row['gone'] as int,
        ),
    ];
  }

  /// Gives [sourceId] the name the user chose.
  void renameSource(int sourceId, String name) =>
      _db.execute('UPDATE sources SET name = ? WHERE id = ?', [name, sourceId]);

  /// Replaces the name of [sourceId] if it still is [placeholder], so a name
  /// the user chose stays.
  void nameSource(int sourceId, String name, {required String placeholder}) =>
      _db.execute('UPDATE sources SET name = ? WHERE id = ? AND name = ?', [
        name,
        sourceId,
        placeholder,
      ]);

  /// Gives [sourceId] the color slot [color].
  void setSourceColor(int sourceId, int color) => _db.execute(
    'UPDATE sources SET color = ? WHERE id = ?',
    [color, sourceId],
  );

  /// Takes the account of [sourceId] out of the library. Its songs leave the
  /// lists, except what the user made of them: a song in History, on a Stack or
  /// stored stays, marked gone, unless another account's copy takes its place.
  /// Returns stored audio that no row points at any more, for the caller to
  /// delete.
  List<String> removeSource(int sourceId) => _transaction(() {
    final unused = <String>[];
    final merged = _db.select(
      'SELECT DISTINCT t.id FROM tracks t '
      'JOIN tracks c ON c.same_as = t.id WHERE t.source_id = ?',
      [sourceId],
    );
    for (final row in merged) {
      final id = row['id'] as int;
      final heir =
          _db.select('SELECT min(id) AS id FROM tracks WHERE same_as = ?', [
                id,
              ]).first['id']
              as int;
      _db.execute('UPDATE tracks SET same_as = NULL WHERE id = ?', [heir]);
      _db.execute('UPDATE tracks SET same_as = ? WHERE same_as = ?', [
        heir,
        id,
      ]);
      final file = _moveReferences(id, heir);
      if (file != null) unused.add(file);
    }
    _db.execute(
      '''
      DELETE FROM tracks WHERE source_id = ?
        AND id NOT IN (SELECT track_id FROM history)
        AND id NOT IN (SELECT track_id FROM stack_entries)
        AND id NOT IN (SELECT track_id FROM audio_files)
      ''',
      [sourceId],
    );
    final now = _now();
    _db.execute(
      'UPDATE tracks SET gone_at_ms = coalesce(gone_at_ms, ?) '
      'WHERE source_id = ?',
      [now, sourceId],
    );
    final left = _db.select(
      'SELECT 1 FROM tracks WHERE source_id = ? LIMIT 1',
      [sourceId],
    );
    if (left.isEmpty) {
      _db.execute('DELETE FROM sources WHERE id = ?', [sourceId]);
    } else {
      _db.execute('UPDATE sources SET removed_at_ms = ? WHERE id = ?', [
        now,
        sourceId,
      ]);
    }
    return unused;
  });

  /// Makes History, Stacks and stored audio of row [from] point at row [to].
  /// When both have stored audio, [to]'s stays, kept if either was a download,
  /// and the path of [from]'s file is returned.
  String? _moveReferences(int from, int to) {
    _forgetVersion(from);
    _db.execute('UPDATE history SET track_id = ? WHERE track_id = ?', [
      to,
      from,
    ]);
    _db.execute('UPDATE stack_entries SET track_id = ? WHERE track_id = ?', [
      to,
      from,
    ]);
    final audio = _db.select(
      'SELECT path, pinned FROM audio_files WHERE track_id = ?',
      [from],
    );
    if (audio.isEmpty) return null;
    final theirs = _db.select(
      'SELECT path FROM audio_files WHERE track_id = ?',
      [to],
    );
    if (theirs.isEmpty) {
      _db.execute('UPDATE audio_files SET track_id = ? WHERE track_id = ?', [
        to,
        from,
      ]);
      return null;
    }
    _db.execute(
      'UPDATE audio_files SET pinned = max(pinned, ?) WHERE track_id = ?',
      [audio.first['pinned'], to],
    );
    _db.execute('DELETE FROM audio_files WHERE track_id = ?', [from]);
    final path = audio.first['path'] as String;
    return path == theirs.first['path'] ? null : path;
  }

  /// Forgets the version chosen for row [from] when it hands over to another
  /// row: that row has its own file, checked again when it plays.
  void _forgetVersion(int from) {
    _db.execute('DELETE FROM song_versions WHERE track_id = ?', [from]);
    _db.execute('DELETE FROM found_versions WHERE track_id = ?', [from]);
  }

  // Merging songs of several accounts (Stage L).

  /// The setting that also merges likely copies, "on" or unset.
  static const mergeLikelySetting = 'library.mergeLikely';

  /// Whether copies are also merged by the likely rule (see [planMerges]).
  /// Off by default: only the same file makes one row.
  bool get mergeLikely => readSetting(mergeLikelySetting) == 'on';

  /// How long the print of a file is trusted: VK can swap a song's file
  /// (Stage K). A song VK gave no file for is asked about again sooner.
  static const printLifetime = Duration(days: 7);
  static const noFilePrintLifetime = Duration(days: 1);

  /// The VK rows of the accounts in the library, in id order, as the merge
  /// sees them, each with its access key. A print read for another listed
  /// length counts as not read.
  List<(MergeRow, String?)> _mergeRows() => [
    for (final row in _db.select('''
      SELECT t.id, t.source_id, t.source_key, t.access_key, t.artist, t.title,
             t.duration_sec, t.vk_track_id, t.same_as, t.same_likely,
             p.listed_sec, p.bytes, p.sample, p.seconds
      FROM tracks t
      JOIN sources s ON s.id = t.source_id
      LEFT JOIN vk_file_prints p ON p.track_id = t.id
      WHERE s.kind = 'vk' AND s.removed_at_ms IS NULL
      ORDER BY t.id
    '''))
      (
        MergeRow(
          SongRow(
            id: row['id'] as int,
            sourceId: row['source_id'] as int,
            sourceKey: row['source_key'] as String,
            text: songMatchText(
              row['artist'] as String,
              row['title'] as String,
            ),
            seconds: row['duration_sec'] as int,
            vkTrackId: row['vk_track_id'] as int?,
            sameAs: row['same_as'] as int?,
          ),
          print: _printOf(row),
          likely: row['same_likely'] == 1,
        ),
        row['access_key'] as String?,
      ),
  ];

  /// The stored print in [row] of [_mergeRows]; null when there is none or
  /// it was read when VK listed another length.
  static FilePrint? _printOf(Row row) {
    if (row['listed_sec'] != row['duration_sec']) return null;
    final (bytes, sample) = (row['bytes'] as int?, row['sample'] as int?);
    if (bytes == null || sample == null) return const FilePrint.noFile();
    return FilePrint(
      bytes: bytes,
      sample: sample,
      seconds: (row['seconds'] as num?)?.toDouble(),
    );
  }

  /// The rows whose VK file the sync should print now: rows that may be
  /// one song with a row of another account (see [rowsToPrint]) and have no
  /// print, or an old one, or one read for another listed length.
  List<PrintRequest> printsToRead({int? nowMs}) {
    final rows = _mergeRows();
    if ({for (final (row, _) in rows) row.song.sourceId}.length < 2) {
      return const [];
    }
    final wanted = rowsToPrint([for (final (row, _) in rows) row.song]);
    final now = nowMs ?? _now();
    final fresh = {
      for (final row in _db.select(
        'SELECT track_id, bytes, checked_at_ms FROM vk_file_prints',
      ))
        row['track_id'] as int:
            now - (row['checked_at_ms'] as int) <
            (row['bytes'] == null ? noFilePrintLifetime : printLifetime)
                .inMilliseconds,
    };
    return [
      for (final (row, accessKey) in rows)
        if (wanted.contains(row.id) &&
            (row.print == null || fresh[row.id] != true))
          (
            trackId: row.id,
            sourceId: row.song.sourceId,
            sourceKey: row.song.sourceKey,
            accessKey: accessKey,
          ),
    ];
  }

  /// Stores the prints read for rows, by row id, each with the length its
  /// row lists now.
  void savePrints(Map<int, FilePrint> prints, {int? atMs}) {
    if (prints.isEmpty) return;
    final at = atMs ?? _now();
    final save = _db.prepare('''
      INSERT INTO vk_file_prints
        (track_id, listed_sec, bytes, sample, seconds, checked_at_ms)
      SELECT id, duration_sec, ?, ?, ?, ? FROM tracks WHERE id = ?
      ON CONFLICT (track_id) DO UPDATE SET
        listed_sec = excluded.listed_sec,
        bytes = excluded.bytes,
        sample = excluded.sample,
        seconds = excluded.seconds,
        checked_at_ms = excluded.checked_at_ms
    ''');
    try {
      _transaction(() {
        for (final MapEntry(key: id, value: print) in prints.entries) {
          save.execute([print.bytes, print.sample, print.seconds, at, id]);
        }
      });
    } finally {
      save.close();
    }
  }

  // Checking every song's file (Stage M2).

  /// The listed VK songs whose file the background check reads now: every
  /// listed, not gone row of an account in the library with no print, an
  /// old one (see [printLifetime]) or one read for another listed length.
  /// Newest added first, as the songs most likely played soon.
  List<PrintRequest> filesToCheck({int? nowMs}) {
    final now = nowMs ?? _now();
    return [
      for (final row in _db.select(
        '''
        SELECT t.id, t.source_id, t.source_key, t.access_key
        FROM tracks t
        JOIN sources s ON s.id = t.source_id
        LEFT JOIN vk_file_prints p ON p.track_id = t.id
        WHERE s.kind = 'vk' AND s.removed_at_ms IS NULL
          AND t.same_as IS NULL AND t.gone_at_ms IS NULL
          AND (p.track_id IS NULL
            OR p.listed_sec != t.duration_sec
            OR p.checked_at_ms <= ? - CASE WHEN p.bytes IS NULL
                                      THEN ? ELSE ? END)
        ORDER BY t.added_at DESC, t.id
        ''',
        [now, noFilePrintLifetime.inMilliseconds, printLifetime.inMilliseconds],
      ))
        (
          trackId: row['id'] as int,
          sourceId: row['source_id'] as int,
          sourceKey: row['source_key'] as String,
          accessKey: row['access_key'] as String?,
        ),
    ];
  }

  /// The listed VK songs whose stored print plays more than 3 s off the
  /// listed length and that have no version chosen for that length: the
  /// background check searches VK for their uploads.
  List<SwappedSong> swappedToDecide() {
    final rows = _db.select(
      '''
      SELECT t.id, t.source_id, t.source_key, t.access_key, t.artist,
             t.title, t.duration_sec, t.vk_track_id, p.seconds, p.bytes
      FROM tracks t
      JOIN sources s ON s.id = t.source_id
      JOIN vk_file_prints p
        ON p.track_id = t.id AND p.listed_sec = t.duration_sec
      LEFT JOIN song_versions v
        ON v.track_id = t.id AND v.listed_sec = t.duration_sec
      WHERE s.kind = 'vk' AND s.removed_at_ms IS NULL
        AND t.same_as IS NULL AND t.gone_at_ms IS NULL
        AND p.seconds IS NOT NULL AND abs(p.seconds - t.duration_sec) > ?
        AND v.track_id IS NULL
      ORDER BY t.added_at DESC, t.id
      ''',
      [otherRecordingSeconds],
    );
    final copies = _db.prepare(
      'SELECT source_key FROM tracks WHERE same_as = ?',
    );
    try {
      return [
        for (final row in rows)
          SwappedSong(
            trackId: row['id'] as int,
            sourceId: row['source_id'] as int,
            sourceKey: row['source_key'] as String,
            accessKey: row['access_key'] as String?,
            artist: row['artist'] as String,
            title: row['title'] as String,
            listedSec: row['duration_sec'] as int,
            vkTrackId: row['vk_track_id'] as int?,
            ownSeconds: (row['seconds'] as num).toDouble(),
            ownBytes: row['bytes'] as int?,
            ownKeys: {
              row['source_key'] as String,
              for (final copy in copies.select([row['id']]))
                copy['source_key'] as String,
            },
          ),
      ];
    } finally {
      copies.close();
    }
  }

  /// Forgets the automatic choices (suggested or none) of songs whose
  /// stored print now plays within 3 s of the listed length: VK gave the
  /// listed recording back. A version the user picked stays. Returns how
  /// many were forgotten.
  int forgetFixedChoices() {
    _db.execute(
      '''
      DELETE FROM song_versions
      WHERE state != 'picked' AND track_id IN (
        SELECT t.id FROM tracks t
        JOIN vk_file_prints p
          ON p.track_id = t.id AND p.listed_sec = t.duration_sec
        WHERE p.seconds IS NOT NULL
          AND abs(p.seconds - t.duration_sec) <= ?)
      ''',
      [otherRecordingSeconds],
    );
    return _db.updatedRows;
  }

  /// Makes the stored merges of songs that several accounts share what
  /// [planMerges] decides now: new copies join their listed row, and copies
  /// whose rule no longer holds are listed on their own again (what had
  /// moved to their listed row stays there). Does nothing with fewer than
  /// two accounts. Needs no network: it reads the stored prints.
  MergeResult mergeSameSongs() {
    final rows = [for (final (row, _) in _mergeRows()) row];
    if ({for (final row in rows) row.song.sourceId}.length < 2) {
      return const MergeResult(0, []);
    }
    final plan = planMerges(rows, mergeLikely: mergeLikely);
    final changed = [
      for (final row in rows)
        if (plan.copies[row.id] != row.song.sameAs ||
            plan.likely.contains(row.id) != row.likely)
          row,
    ];
    if (changed.isEmpty) return const MergeResult(0, []);
    return _transaction(() {
      final unused = <String>[];
      var merged = 0;
      var unmerged = 0;
      for (final row in changed) {
        final listed = plan.copies[row.id];
        _db.execute(
          'UPDATE tracks SET same_as = ?, same_likely = ? WHERE id = ?',
          [listed, plan.likely.contains(row.id) ? 1 : 0, row.id],
        );
        if (listed == null) {
          unmerged++;
        } else if (listed != row.song.sameAs) {
          merged++;
          final file = _moveReferences(row.id, listed);
          if (file != null) unused.add(file);
        }
      }
      // A copy kept from a removed account points at its listed row, which
      // may have become a copy itself just now.
      _db.execute('''
        UPDATE tracks SET same_as =
          (SELECT h.same_as FROM tracks h WHERE h.id = tracks.same_as)
        WHERE same_as IN (SELECT id FROM tracks WHERE same_as IS NOT NULL)
      ''');
      return MergeResult(
        merged,
        unused,
        unmerged: unmerged,
        marked: changed.length - merged - unmerged,
      );
    });
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
  List<int> upsertAll(int sourceId, Iterable<NewTrack> tracks) =>
      upsertTracks(sourceId, tracks).ids;

  /// Like [upsertAll], and also tells which songs were added or changed.
  ///
  /// A song whose stored fields already match is not written again, so a
  /// sync that finds nothing new leaves the database untouched.
  UpsertResult upsertTracks(int sourceId, Iterable<NewTrack> tracks) {
    // The WHERE clause skips the update when nothing differs; RETURNING then
    // yields no row and the id is looked up instead.
    final upsert = _db.prepare('''
      INSERT INTO tracks (source_id, source_key, access_key, artist, title,
                          album, duration_sec, added_at, cover_url,
                          cover_large_url, cover_mid_url, cover_full_url, tint,
                          vk_track_id, vk_album_key, vk_album_access_key)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (source_id, source_key) DO UPDATE SET
        access_key = excluded.access_key,
        artist = excluded.artist,
        title = excluded.title,
        album = excluded.album,
        duration_sec = excluded.duration_sec,
        added_at = excluded.added_at,
        cover_url = excluded.cover_url,
        cover_large_url = excluded.cover_large_url,
        cover_mid_url = excluded.cover_mid_url,
        cover_full_url = excluded.cover_full_url,
        tint = excluded.tint,
        vk_album_key = excluded.vk_album_key,
        vk_album_access_key = excluded.vk_album_access_key,
        gone_at_ms = NULL
      WHERE tracks.access_key IS NOT excluded.access_key
         OR tracks.artist IS NOT excluded.artist
         OR tracks.title IS NOT excluded.title
         OR tracks.album IS NOT excluded.album
         OR tracks.duration_sec IS NOT excluded.duration_sec
         OR tracks.added_at IS NOT excluded.added_at
         OR tracks.cover_url IS NOT excluded.cover_url
         OR tracks.cover_large_url IS NOT excluded.cover_large_url
         OR tracks.cover_mid_url IS NOT excluded.cover_mid_url
         OR tracks.cover_full_url IS NOT excluded.cover_full_url
         OR tracks.tint IS NOT excluded.tint
         OR tracks.gone_at_ms IS NOT NULL
      RETURNING id
    ''');
    final findId = _db.prepare(
      'SELECT id FROM tracks WHERE source_id = ? AND source_key = ?',
    );
    try {
      return _transaction(() {
        final ids = <int>[];
        final changedIds = <int>[];
        for (final track in tracks) {
          final written = upsert.select([
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
            track.coverMidUrl,
            track.coverFullUrl,
            track.tint,
            track.vkTrackId,
            track.vkAlbumKey,
            track.vkAlbumAccessKey,
          ]);
          if (written.isNotEmpty) {
            final id = written.first['id'] as int;
            ids.add(id);
            changedIds.add(id);
          } else {
            ids.add(
              findId.select([sourceId, track.sourceKey]).first['id'] as int,
            );
          }
        }
        return UpsertResult(ids, changedIds);
      });
    } finally {
      upsert.close();
      findId.close();
    }
  }

  /// Stores the cover links, VK track ids and album links of [tracks], for
  /// songs that exist already. No change the UI has to know about: a new host
  /// of the same image only matters the next time the library loads, a track
  /// id only to [mergeSameSongs], and an album link only when the album is
  /// opened, which reads it from here.
  void updateQuietDetails(int sourceId, Iterable<NewTrack> tracks) {
    final update = _db.prepare('''
      UPDATE tracks SET cover_url = ?, cover_large_url = ?, cover_mid_url = ?,
                        cover_full_url = ?, vk_track_id = ?, vk_album_key = ?,
                        vk_album_access_key = ?
      WHERE source_id = ? AND source_key = ?
    ''');
    try {
      _transaction(() {
        for (final track in tracks) {
          update.execute([
            track.coverUrl,
            track.coverLargeUrl,
            track.coverMidUrl,
            track.coverFullUrl,
            track.vkTrackId,
            track.vkAlbumKey,
            track.vkAlbumAccessKey,
            sourceId,
            track.sourceKey,
          ]);
        }
      });
    } finally {
      update.close();
    }
  }

  /// Every song key of [sourceId] with its gone mark, VK access key and
  /// cover links, for comparing the library with what the source lists now.
  Map<String, KnownTrack> trackKeys(int sourceId) => {
    for (final row in _db.select(
      'SELECT source_key, access_key, cover_url, cover_large_url, '
      'cover_mid_url, cover_full_url, gone_at_ms '
      'FROM tracks WHERE source_id = ?',
      [sourceId],
    ))
      row['source_key'] as String: (
        accessKey: row['access_key'] as String?,
        coverUrl: row['cover_url'] as String?,
        coverLargeUrl: row['cover_large_url'] as String?,
        coverMidUrl: row['cover_mid_url'] as String?,
        coverFullUrl: row['cover_full_url'] as String?,
        goneAtMs: row['gone_at_ms'] as int?,
      ),
  };

  /// The VK album the listed song [trackId] is from, as one of its rows
  /// knows it: the row itself first, then a copy another account still has.
  /// Null when no row has an album link (not synced since version 5, or VK
  /// names no album).
  VkAlbumLink? vkAlbumOf(int trackId) {
    final rows = _db.select(
      '''
      SELECT source_id, vk_album_key, vk_album_access_key FROM tracks
      WHERE (id = ? OR same_as = ?) AND vk_album_key IS NOT NULL
      ORDER BY id = ? DESC, gone_at_ms IS NOT NULL, id
      LIMIT 1
      ''',
      [trackId, trackId, trackId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      sourceId: row['source_id'] as int,
      key: row['vk_album_key'] as String,
      accessKey: row['vk_album_access_key'] as String?,
    );
  }

  /// Ids of the listed songs that some row (the song's own or a copy's) puts
  /// in the VK album [albumKey], in library order.
  List<int> listedIdsInVkAlbum(String albumKey) => [
    for (final row in _db.select(
      '''
      SELECT l.id FROM tracks l
      WHERE l.same_as IS NULL AND l.id IN (
        SELECT coalesce(same_as, id) FROM tracks WHERE vk_album_key = ?)
      ORDER BY l.added_at DESC, l.id DESC
      ''',
      [albumKey],
    ))
      row['id'] as int,
  ];

  /// Ids of the listed songs with album title [album] and artist [artist], in
  /// library order: an album for songs without an album link.
  List<int> listedIdsWithAlbum(String album, String artist) => [
    for (final row in _db.select(
      'SELECT id FROM tracks '
      'WHERE same_as IS NULL AND album = ? AND artist = ? '
      'ORDER BY added_at DESC, id DESC',
      [album, artist],
    ))
      row['id'] as int,
  ];

  /// The listed song of each of [vkTrackIds] the library has, by VK track
  /// id: the row itself, or the row a copy with that id belongs to.
  Map<int, int> listedIdsByVkTrackId(Iterable<int> vkTrackIds) {
    final wanted = vkTrackIds.toSet();
    if (wanted.isEmpty) return const {};
    final found = <int, int>{};
    // In chunks: SQLite allows a limited number of parameters per statement.
    final ids = wanted.toList();
    for (var at = 0; at < ids.length; at += 500) {
      final chunk = ids.sublist(at, (at + 500).clamp(0, ids.length));
      for (final row in _db.select(
        'SELECT vk_track_id, coalesce(same_as, id) AS listed FROM tracks '
        'WHERE vk_track_id IN (${List.filled(chunk.length, '?').join(', ')}) '
        'ORDER BY same_as IS NOT NULL, id',
        chunk,
      )) {
        found.putIfAbsent(
          row['vk_track_id'] as int,
          () => row['listed'] as int,
        );
      }
    }
    return found;
  }

  /// The album titles VK gave so far, by "ownerId_albumId".
  Map<String, String> vkAlbumTitles() => {
    for (final row in _db.select(
      'SELECT album_key, title FROM vk_album_titles',
    ))
      row['album_key'] as String: row['title'] as String,
  };

  /// Keeps the [title] of the album [albumKey].
  void saveVkAlbumTitle(String albumKey, String title) => _db.execute(
    'INSERT INTO vk_album_titles (album_key, title) VALUES (?, ?) '
    'ON CONFLICT (album_key) DO UPDATE SET title = excluded.title',
    [albumKey, title],
  );

  /// Marks the songs [keys] of [sourceId] as gone from their source. Songs
  /// stay in the library (with their History, Stacks and stored audio);
  /// songs already marked keep their first mark. Returns how many were
  /// newly marked.
  int markGone(int sourceId, Iterable<String> keys, {int? atMs}) {
    final at = atMs ?? _now();
    final mark = _db.prepare(
      'UPDATE tracks SET gone_at_ms = ? '
      'WHERE source_id = ? AND source_key = ? AND gone_at_ms IS NULL',
    );
    try {
      return _transaction(() {
        var marked = 0;
        for (final key in keys) {
          mark.execute([at, sourceId, key]);
          marked += _db.updatedRows;
        }
        return marked;
      });
    } finally {
      mark.close();
    }
  }

  /// The whole library, newest first, with each song's stored audio and its
  /// copies in other accounts. Copies themselves are not listed.
  List<Track> loadAll() {
    final copies = <int, List<TrackCopy>>{};
    for (final row in _db.select('''
      SELECT same_as, source_id, source_key, access_key, gone_at_ms,
             same_likely
      FROM tracks WHERE same_as IS NOT NULL ORDER BY id
    ''')) {
      (copies[row['same_as'] as int] ??= []).add(
        TrackCopy(
          sourceId: row['source_id'] as int,
          sourceKey: row['source_key'] as String,
          accessKey: row['access_key'] as String?,
          goneAtMs: row['gone_at_ms'] as int?,
          likely: row['same_likely'] == 1,
        ),
      );
    }
    final rows = _db.select('''
      SELECT t.id, t.source_id, s.kind, t.source_key, t.access_key, t.artist,
             t.title, t.album, t.duration_sec, t.cover_url, t.cover_large_url,
             t.cover_mid_url, t.cover_full_url, t.tint, t.gone_at_ms, a.path,
             a.pinned
      FROM tracks t
      JOIN sources s ON s.id = t.source_id
      LEFT JOIN audio_files a ON a.track_id = t.id
      WHERE t.same_as IS NULL
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
          coverMidUrl: row['cover_mid_url'] as String?,
          coverFullUrl: row['cover_full_url'] as String?,
          tint: row['tint'] as int?,
          goneAtMs: row['gone_at_ms'] as int?,
          localPath: row['path'] as String?,
          pinned: row['pinned'] == 1,
          copies: copies[row['id'] as int] ?? const [],
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

  /// Bytes of stored audio that is plain cache (not downloaded), counting
  /// each file once even when several songs point at it.
  int cachedBytes() =>
      _db.select('''
        SELECT coalesce(sum(bytes), 0) AS total FROM (
          SELECT path, max(bytes) AS bytes FROM audio_files
          WHERE pinned = 0 AND path NOT IN (
            SELECT path FROM audio_files WHERE pinned = 1
          )
          GROUP BY path
        )
      ''').first['total']
          as int;

  /// Cached (not downloaded) songs in the order the cache limit removes
  /// them: played longest ago first; never played counts from when the
  /// file was stored. Files a downloaded song also uses are left out: they
  /// stay anyway.
  List<CachedAudio> evictionOrder() => [
    for (final row in _db.select('''
      SELECT a.track_id, a.path, a.bytes,
             max(coalesce(max(h.played_at_ms), 0), a.stored_at_ms) AS used
      FROM audio_files a LEFT JOIN history h ON h.track_id = a.track_id
      WHERE a.pinned = 0 AND a.path NOT IN (
        SELECT path FROM audio_files WHERE pinned = 1
      )
      GROUP BY a.track_id
      ORDER BY used, a.track_id
    '''))
      CachedAudio(
        trackId: row['track_id'] as int,
        path: row['path'] as String,
        bytes: row['bytes'] as int,
        lastUsedMs: row['used'] as int,
      ),
  ];

  /// How many songs' stored audio is the file at [path].
  int audioPathUsers(String path) =>
      _db.select('SELECT count(*) AS n FROM audio_files WHERE path = ?', [
            path,
          ]).first['n']
          as int;

  // History.

  /// Records a play of [trackId]; returns the History entry id.
  int addPlay(int trackId, {int? atMs}) {
    _db.execute('INSERT INTO history (track_id, played_at_ms) VALUES (?, ?)', [
      trackId,
      atMs ?? _now(),
    ]);
    return _db.lastInsertRowId;
  }

  @override
  int beginPlay(
    int trackId, {
    required PlayStart start,
    required bool shuffle,
    int? atMs,
  }) {
    _db.execute(
      'INSERT INTO history (track_id, played_at_ms, started, shuffle, '
      'listened_ms) VALUES (?, ?, ?, ?, 0)',
      [trackId, atMs ?? _now(), start.name, shuffle ? 1 : 0],
    );
    return _db.lastInsertRowId;
  }

  @override
  void updatePlay(int playId, {required int listenedMs, PlayEnd? ended}) =>
      _db.execute(
        'UPDATE history SET listened_ms = ?, ended = ? WHERE id = ?',
        [listenedMs, ended?.name, playId],
      );

  @override
  HistoryEntry? lastPlay() => history(limit: 1).firstOrNull;

  /// Plays, newest first.
  List<HistoryEntry> history({int limit = 1000}) => [
    for (final row in _db.select(
      'SELECT id, track_id, played_at_ms, started, shuffle, listened_ms, '
      'ended FROM history ORDER BY played_at_ms DESC, id DESC LIMIT ?',
      [limit],
    ))
      HistoryEntry(
        row['id'] as int,
        row['track_id'] as int,
        row['played_at_ms'] as int,
        started: PlayStart.values.asNameMap()[row['started']],
        shuffle: switch (row['shuffle']) {
          final int value => value != 0,
          _ => null,
        },
        listenedMs: row['listened_ms'] as int?,
        ended: PlayEnd.values.asNameMap()[row['ended']],
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

  // Song versions (Stage K).

  /// The version chosen for each song whose VK file was swapped.
  Map<int, VersionChoice> versionChoices() => {
    for (final row in _db.select('SELECT * FROM song_versions'))
      row['track_id'] as int: VersionChoice(
        trackId: row['track_id'] as int,
        state: VersionState.values.byName(row['state'] as String),
        fileKey: row['file_key'] as String?,
        fileAccessKey: row['file_access_key'] as String?,
        fileSeconds: (row['file_seconds'] as num?)?.toDouble(),
        ownSeconds: (row['own_seconds'] as num).toDouble(),
        ownBytes: row['own_bytes'] as int?,
        listedSec: row['listed_sec'] as int,
        decidedAtMs: row['decided_at_ms'] as int,
      ),
  };

  /// Stores [choice], replacing the song's earlier one.
  void saveVersionChoice(VersionChoice choice) => _db.execute(
    '''
    INSERT OR REPLACE INTO song_versions (track_id, state, file_key,
      file_access_key, file_seconds, own_seconds, own_bytes, listed_sec,
      decided_at_ms)
    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (
      SELECT 1 FROM tracks WHERE id = ?1)
    ''',
    [
      choice.trackId,
      choice.state.name,
      choice.fileKey,
      choice.fileAccessKey,
      choice.fileSeconds,
      choice.ownSeconds,
      choice.ownBytes,
      choice.listedSec,
      choice.decidedAtMs,
    ],
  );

  /// Forgets the version chosen for [trackId]: its own file plays again.
  void removeVersionChoice(int trackId) => _forgetVersion(trackId);

  /// How long a song's found versions are shown without searching again.
  static const foundVersionsLifetime = Duration(days: 7);

  /// Replaces the uploads of [trackId]'s song that VK's search found with
  /// [versions] (VK's current file for the row itself is not kept: its
  /// print says how it plays).
  void saveFoundVersions(int trackId, List<SongVersion> versions, {int? atMs}) {
    final at = atMs ?? _now();
    _transaction(() {
      _db.execute('DELETE FROM found_versions WHERE track_id = ?', [trackId]);
      final insert = _db.prepare('''
        INSERT OR IGNORE INTO found_versions (track_id, position, file_key,
          access_key, artist, title, album, cover_url, cover_large_url,
          listed_sec, seconds, bytes, official, vk_track_id, found_at_ms)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        WHERE EXISTS (SELECT 1 FROM tracks WHERE id = ?1)
      ''');
      try {
        var position = 0;
        for (final version in versions) {
          if (version.isCurrentFile) continue;
          insert.execute([
            trackId,
            position++,
            version.key,
            version.accessKey,
            version.artist,
            version.title,
            version.album,
            version.coverUrl,
            version.coverLargeUrl,
            version.listedSec,
            version.file?.seconds,
            version.file?.bytes,
            version.official ? 1 : 0,
            version.vkTrackId,
            at,
          ]);
        }
      } finally {
        insert.close();
      }
    });
  }

  /// The uploads of [trackId]'s song found last, in the order found, and
  /// when; null when it was never searched.
  ({List<SongVersion> versions, int foundAtMs})? foundVersions(int trackId) {
    final rows = _db.select(
      'SELECT * FROM found_versions WHERE track_id = ? ORDER BY position',
      [trackId],
    );
    if (rows.isEmpty) return null;
    return (
      versions: [
        for (final row in rows)
          SongVersion(
            key: row['file_key'] as String,
            accessKey: row['access_key'] as String?,
            artist: row['artist'] as String,
            title: row['title'] as String,
            album: row['album'] as String?,
            coverUrl: row['cover_url'] as String?,
            coverLargeUrl: row['cover_large_url'] as String?,
            listedSec: row['listed_sec'] as int,
            file: switch ((row['seconds'], row['bytes'])) {
              (final num seconds, final int bytes) => FileFacts(
                bytes: bytes,
                seconds: seconds.toDouble(),
              ),
              _ => null,
            },
            official: row['official'] == 1,
            vkTrackId: row['vk_track_id'] as int?,
          ),
      ],
      foundAtMs: rows.first['found_at_ms'] as int,
    );
  }

  /// How VK's file for row [trackId] plays, from its stored print; null
  /// when there is none, it found no file, or it was read when VK listed
  /// another length.
  FileFacts? printedFileOf(int trackId) {
    final rows = _db.select(
      '''
      SELECT p.bytes, p.seconds FROM vk_file_prints p
      JOIN tracks t ON t.id = p.track_id AND t.duration_sec = p.listed_sec
      WHERE p.track_id = ?
      ''',
      [trackId],
    );
    if (rows.isEmpty) return null;
    return switch ((rows.first['seconds'], rows.first['bytes'])) {
      (final num seconds, final int bytes) => FileFacts(
        bytes: bytes,
        seconds: seconds.toDouble(),
      ),
      _ => null,
    };
  }

  /// VK's `track_id` of row [trackId]; null when VK gave none.
  int? vkTrackIdOf(int trackId) =>
      _db.select('SELECT vk_track_id FROM tracks WHERE id = ?', [
            trackId,
          ]).firstOrNull?['vk_track_id']
          as int?;

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
