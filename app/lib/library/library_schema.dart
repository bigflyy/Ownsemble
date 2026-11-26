import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Schema version this build reads and writes (`PRAGMA user_version`).
///
/// 0 is the speed-gate build's single `tracks` table (or an empty file).
const librarySchemaVersion = 25;

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
    if (version < 9) _addPlayDetails(db);
    if (version < 10) _addFoundVersionAlbums(db);
    if (version < 11) _expireListsWithoutAlbumLinks(db);
    if (version < 12) _addPlaysByTime(db);
    if (version < 13) _addFavorites(db);
    if (version < 14) _addRemovedMarks(db);
    if (version < 15) _addArtistCredits(db);
    if (version < 16) _addFoundVersionArtists(db);
    if (version < 17) _addLyrics(db);
    if (version < 18) _addLyricsMeta(db);
    if (version < 19) _addLyricsPicks(db);
    if (version < 20) _addLyricsOffsets(db);
    if (version < 21) _addLyricsFits(db);
    if (version < 22) _forgetOutsideLyricsMisses(db);
    if (version < 23) _addHeardLyrics(db);
    if (version < 24) _addLyricsEdits(db);
    if (version < 25) _addHearLanguages(db);
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
///
/// Automatic "none" choices are dropped: earlier builds stored one when
/// VK's search answered with no songs at all (VK not answering, seen
/// 2026-11-06), so the next file check decides them again. Picks stay.
void _addFoundVersions(Database db) {
  db.execute("DELETE FROM song_versions WHERE state = 'none'");
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

/// Version 9: how each play started, how long it was heard and how it
/// ended (names of PlayStart / PlayEnd). Earlier plays keep nulls: nothing
/// recorded them.
void _addPlayDetails(Database db) {
  db.execute('ALTER TABLE history ADD COLUMN started TEXT');
  db.execute('ALTER TABLE history ADD COLUMN shuffle INTEGER');
  db.execute('ALTER TABLE history ADD COLUMN listened_ms INTEGER');
  db.execute('ALTER TABLE history ADD COLUMN ended TEXT');
}

/// Version 10: the album link of each found upload, so its album opens from
/// the versions place. Lists found before have none until searched again.
void _addFoundVersionAlbums(Database db) {
  db.execute('ALTER TABLE found_versions ADD COLUMN album_key TEXT');
  db.execute('ALTER TABLE found_versions ADD COLUMN album_access_key TEXT');
}

/// Version 11: lists found before version 10 name albums but have no link
/// to them, so the albums opened empty (user, 2026-11-06). Expired, they
/// are searched again the next time the song's versions open.
void _expireListsWithoutAlbumLinks(Database db) {
  db.execute('''
    UPDATE found_versions SET found_at_ms = 0
    WHERE track_id IN (
      SELECT track_id FROM found_versions
      WHERE album IS NOT NULL AND album != '' AND album_key IS NULL
    )
  ''');
}

/// Version 12: indexes for filters and stats over any days (plan 04, C1).
/// Both hold what counting needs besides the song's length, so plays are
/// read from an index alone: by time for a day range, by song for all time
/// (the old by-song index grows two columns; it serves its old uses too).
void _addPlaysByTime(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS history_by_time '
    'ON history (played_at_ms, track_id, listened_ms, ended)',
  );
  db.execute('DROP INDEX IF EXISTS history_by_track');
  db.execute(
    'CREATE INDEX history_by_track '
    'ON history (track_id, played_at_ms, listened_ms, ended)',
  );
}

/// Version 13: the user's favorite songs, with the time each was added
/// (plan 05). Kept only here: VK has no favorites of its own.
void _addFavorites(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS favorites (
      track_id INTEGER PRIMARY KEY REFERENCES tracks (id),
      added_at_ms INTEGER NOT NULL
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS favorites_by_added ON favorites (added_at_ms, track_id)',
  );
}

/// Version 14: the time the user removed a song from the library (plan 06,
/// C2). A removed row stays, so its plays still count in History and Stats,
/// but it is no longer listed; Undo clears the mark.
void _addRemovedMarks(Database db) {
  // Guarded so a step run again on a newer file (the older steps' tests
  // lower the version of a current library) does not fail.
  final columns = {
    for (final row in db.select('PRAGMA table_info(tracks)')) row['name'],
  };
  if (columns.contains('removed_at_ms')) return;
  db.execute('ALTER TABLE tracks ADD COLUMN removed_at_ms INTEGER');
}

/// Version 15: the artists VK names on each row (plan 09), main ones first,
/// then featured ones, and the photos of VK artists. Every sync writes the
/// artists of every row it reads, so the first one after the upgrade fills
/// them in. A photo row with `missing` set means VK's page of that artist had
/// no photo when it was read.
void _addArtistCredits(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS track_artists (
      track_id INTEGER NOT NULL REFERENCES tracks (id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      vk_artist_id TEXT NOT NULL,
      name TEXT NOT NULL,
      domain TEXT,
      featured INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (track_id, position)
    )
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS track_artists_by_artist '
    'ON track_artists (vk_artist_id)',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS artist_photos (
      vk_artist_id TEXT PRIMARY KEY,
      small_url TEXT,
      large_url TEXT,
      fetched_at_ms INTEGER NOT NULL,
      missing INTEGER NOT NULL DEFAULT 0
    )
  ''');
}

/// Version 16: the artists of each found upload (JSON, as the list caches
/// keep them), so + on a stored upload stores them too (plan 09, C2 review).
/// Lists found before have none: expired, they are searched again the next
/// time the song's versions open.
void _addFoundVersionArtists(Database db) {
  final columns = {
    for (final row in db.select('PRAGMA table_info(found_versions)'))
      row['name'] as String,
  };
  if (columns.contains('artists')) return;
  db.execute('ALTER TABLE found_versions ADD COLUMN artists TEXT');
  db.execute('UPDATE found_versions SET found_at_ms = 0');
}

/// Version 17: songs' lyrics as fetched (plan 10), kept for offline use.
/// `source` is where they came from ('vk'), `ref` the song there (VK: the
/// song's key "ownerId_id"). `found` 0 records that the source has none, so
/// it is not asked again at once. `body` is the lines as JSON
/// (Lyrics.linesToJson); `md5` is VK's mark that changes with its lyrics.
/// Version 18 (plan 10, E1): the facts of an outside source's song whose
/// lyrics a row holds (JSON: id, artist, title, seconds, exact, diff), for
/// the automatic pick and the chooser. VK rows leave it empty.
void _addLyricsMeta(Database db) {
  final columns = db.select('PRAGMA table_info(lyrics)');
  if (columns.any((column) => column['name'] == 'meta')) return;
  db.execute('ALTER TABLE lyrics ADD COLUMN meta TEXT');
}

/// Version 19 (plan 10, E2): the lyrics the user chose for a song in the
/// chooser, by the upload's key (`ref`, as in `lyrics`): `source` is the
/// row of `lyrics` to show instead of the automatic pick.
void _addLyricsPicks(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS lyrics_picks (
      ref TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      picked_at_ms INTEGER NOT NULL
    )
  ''');
}

/// Version 20 (plan 10, F1): how far the user moved one source's timed
/// lines for a song, by the upload's key (`ref`) and the source: a live or
/// acoustic version is sung later or earlier than the lines say.
/// `offset_ms` > 0 lights each line later; no row means 0.
void _addLyricsOffsets(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS lyrics_offsets (
      ref TEXT NOT NULL,
      source TEXT NOT NULL,
      offset_ms INTEGER NOT NULL,
      set_at_ms INTEGER NOT NULL,
      PRIMARY KEY (ref, source)
    )
  ''');
}

/// Version 21 (plan 10, G2): one source's timed lines fitted to the
/// recording of an upload ("Fit to this recording"), by the upload's key
/// (`ref`) and the source, beside the hand offset of version 20.
/// `lyrics_hash` names the lyrics that were fitted (a fit of older lyrics
/// is not used), `audio_bytes` the size of the recording's file (a fit of
/// a file VK swapped since is not used); `starts` is a JSON list with every
/// line's new start in milliseconds, null when the lyrics did not fit the
/// recording.
void _addLyricsFits(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS lyrics_fits (
      ref TEXT NOT NULL,
      source TEXT NOT NULL,
      lyrics_hash TEXT NOT NULL,
      audio_bytes INTEGER NOT NULL,
      starts TEXT,
      sure_share REAL NOT NULL,
      fitted_at_ms INTEGER NOT NULL,
      PRIMARY KEY (ref, source)
    )
  ''');
}

/// Version 22 (plan 10, G4a): forgets the outside sources' "none" answers.
/// Before, a source answered none for every song whose lyrics it has only
/// at another length (a live upload); now it answers another version's
/// lyrics, so those songs are asked again instead of waiting out the 7
/// days. VK's answers are its own and stay.
void _forgetOutsideLyricsMisses(Database db) {
  db.execute("DELETE FROM lyrics WHERE found = 0 AND source != 'vk'");
}

/// Version 23 (plan 10, I2e): the words "Hear the words" heard in a
/// recording, by the upload's key (`ref`, as in `lyrics`), kept apart from
/// `lyrics` so no source's refresh or "none" can touch them. `outcome` is
/// 'words', 'noSinging' or 'noWords'; `body` the timed lines (as
/// `lyrics.body`) and `words` every heard word with times and confidence,
/// both null without words; `model` 'gigaam' or 'whisper'; `confidence` the
/// model's mean word confidence, `ru_confidence` GigaAM's (the router's
/// number); `loud_s` the vocals' seconds with sound; `audio_bytes` the
/// size of the file heard; `bundles` the model bundles' names and versions.
void _addHeardLyrics(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS heard_lyrics (
      ref TEXT PRIMARY KEY,
      outcome TEXT NOT NULL,
      body TEXT,
      words TEXT,
      model TEXT,
      language TEXT,
      confidence REAL NOT NULL,
      ru_confidence REAL NOT NULL,
      rough INTEGER NOT NULL,
      word_count INTEGER NOT NULL,
      loud_s REAL NOT NULL,
      audio_bytes INTEGER,
      bundles TEXT NOT NULL,
      heard_at_ms INTEGER NOT NULL
    )
  ''');
}

/// Version 24 (plan 10, I2g): the user's own edits of a song's lyrics, by
/// the upload's key (`ref`, as in `lyrics`), kept apart from `lyrics` so no
/// source's refresh can touch them. One row per save: `seq` counts up per
/// upload, the newest row is the edit and older ones are undo steps (the
/// store keeps the last 10). `body` holds the lines as `lyrics.body` does,
/// a start left out where the user gave none; `based_on` the source the
/// edit started from, null when written from nothing.
void _addLyricsEdits(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS lyrics_edits (
      ref TEXT NOT NULL,
      seq INTEGER NOT NULL,
      body TEXT NOT NULL,
      based_on TEXT,
      saved_at_ms INTEGER NOT NULL,
      PRIMARY KEY (ref, seq)
    )
  ''');
}

void _addLyrics(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS lyrics (
      source TEXT NOT NULL,
      ref TEXT NOT NULL,
      found INTEGER NOT NULL,
      timed INTEGER NOT NULL DEFAULT 0,
      body TEXT,
      md5 TEXT,
      fetched_at_ms INTEGER NOT NULL,
      PRIMARY KEY (source, ref)
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

/// Version 25 (plan 10, I2j): the language the user picked for a song's
/// "Hear the words", by the upload's key (`ref`), kept until they go back to
/// Automatic: 'ru' (GigaAM) or a Whisper language code. `heard_lyrics`
/// keeps the language a heard version was asked for, null for Automatic.
void _addHearLanguages(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS hear_languages (
      ref TEXT PRIMARY KEY,
      language TEXT NOT NULL,
      chosen_at_ms INTEGER NOT NULL
    )
  ''');
  final columns = db.select('PRAGMA table_info(heard_lyrics)');
  if (columns.any((column) => column['name'] == 'asked_language')) return;
  db.execute('ALTER TABLE heard_lyrics ADD COLUMN asked_language TEXT');
}
