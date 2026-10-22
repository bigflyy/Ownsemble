import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../media/audio_cache.dart';
import '../media/audio_policy.dart';
import 'music_metadata.dart';

class LibraryRow {
  final Track track;
  final bool offline, pinned;
  final int? occurrence;
  final String? error;
  const LibraryRow(
    this.track,
    this.offline,
    this.pinned,
    this.occurrence,
    this.error,
  );
}

class Pile {
  final int id, count;
  final String name;
  final bool pinned;
  const Pile(this.id, this.name, this.count, this.pinned);
}

class LibraryStore {
  final Directory directory;
  late final Database db;
  LibraryStore(this.directory) {
    directory.createSync(recursive: true);
    db = sqlite3.open('${directory.path}/library.sqlite');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=3000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) throw const ProofFailure('database_version_newer');
    if (version == 0) {
      transaction(() {
        db.execute('''
          CREATE TABLE tracks(id TEXT PRIMARY KEY,title TEXT NOT NULL,artist TEXT NOT NULL,
            duration REAL NOT NULL,search_text TEXT NOT NULL,error TEXT,updated INTEGER NOT NULL);
          CREATE TABLE piles(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,pinned INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE entries(id INTEGER PRIMARY KEY AUTOINCREMENT,pile INTEGER NOT NULL REFERENCES piles(id) ON DELETE CASCADE,
            track TEXT NOT NULL REFERENCES tracks(id),added INTEGER NOT NULL);
          CREATE INDEX entries_pile ON entries(pile,id DESC);
          CREATE TABLE pins(kind TEXT NOT NULL,target TEXT NOT NULL,track TEXT NOT NULL REFERENCES tracks(id),
            PRIMARY KEY(kind,target,track));
          CREATE TABLE assets(track TEXT PRIMARY KEY REFERENCES tracks(id),entry TEXT NOT NULL,digest TEXT NOT NULL,
            bytes INTEGER NOT NULL,duration REAL NOT NULL,accessed INTEGER NOT NULL);
          CREATE TABLE plays(id INTEGER PRIMARY KEY AUTOINCREMENT,track TEXT NOT NULL REFERENCES tracks(id),
            started INTEGER NOT NULL,listened INTEGER NOT NULL DEFAULT 0,qualified INTEGER NOT NULL DEFAULT 0);
          CREATE INDEX plays_track ON plays(track,started DESC);
          CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          PRAGMA user_version=1;
        ''');
        createPile('Rediscovered');
      });
    }
    final trackColumns = db
        .select('PRAGMA table_info(tracks)')
        .map((row) => row['name'])
        .toSet();
    if (!trackColumns.contains('provider_position')) {
      transaction(() {
        db.execute('ALTER TABLE tracks ADD COLUMN provider_position INTEGER');
        db.execute('ALTER TABLE tracks ADD COLUMN provider_epoch INTEGER');
      });
    }
    // Pin membership is queried for each library row, including existing v1 data.
    db.execute('CREATE INDEX IF NOT EXISTS pins_track ON pins(track)');
    db.execute(
      'CREATE TABLE IF NOT EXISTS asset_identity('
      'track TEXT PRIMARY KEY REFERENCES assets(track) ON DELETE CASCADE,digest TEXT NOT NULL)',
    );
    // Optional provider metadata: additive and compatible with v1 readers.
    // This is a track access reference, never an account/session credential.
    db.execute(
      'CREATE TABLE IF NOT EXISTS music_refs('
      'track TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,'
      'music_key TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS track_metadata('
      'track TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,'
      'body TEXT NOT NULL DEFAULT \'{}\',artwork TEXT)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS track_lyrics('
      'track TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,body TEXT NOT NULL)',
    );
    if (setting('availability_status_version') != 2) {
      transaction(() {
        // Older releases inferred unavailability from advisory fields/empty
        // capture. Preserve each record and make those statuses retryable.
        db.execute(
          "UPDATE tracks SET error='audio_source_not_resolved' WHERE error='audio_source_unavailable'",
        );
        setSetting('availability_status_version', 2);
      });
    }
  }
  int get now => DateTime.now().millisecondsSinceEpoch;
  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final value = action();
      db.execute('COMMIT');
      return value;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // Metadata refresh clears only a former unavailable status, never a
  // playback/network error. No track, occurrence or cache is removed.
  void noteAvailability(String id, bool unavailable) {
    if (unavailable) {
      db.execute(
        "UPDATE tracks SET error='audio_restricted' WHERE id=? AND error IS NOT 'audio_restricted'",
        [id],
      );
    } else {
      db.execute(
        "UPDATE tracks SET error=NULL WHERE id=? AND (error='audio_restricted' OR error LIKE 'audio_restricted_%')",
        [id],
      );
    }
  }

  void noteProviderPosition(String id, int position, int epoch) {
    if (position < 0 || position > 50000 || epoch < 0) {
      throw const ProofFailure('invalid_music_position');
    }
    db.execute(
      'UPDATE tracks SET provider_position=?,provider_epoch=? WHERE id=?',
      [position, epoch, id],
    );
  }

  // Local music identities only. No source URLs, access references or account
  // state are part of a refresh checkpoint.
  List<String> get syncHead {
    final saved = setting('sync_head');
    if (saved is! Map || saved['version'] != 1) return const [];
    final ids = saved['ids'];
    if (ids is! List ||
        ids.isEmpty ||
        ids.length > 128 ||
        ids.any(
          (id) => id is! String || !RegExp(r'^-?\d+_\d+$').hasMatch(id),
        ) ||
        ids.toSet().length != ids.length) {
      return const [];
    }
    return ids.cast<String>();
  }

  void saveSyncHead(List<String> ids) {
    if (ids.isEmpty ||
        ids.length > 128 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !RegExp(r'^-?\d+_\d+$').hasMatch(id))) {
      throw const ProofFailure('invalid_sync_checkpoint');
    }
    setSetting('sync_head', {'version': 1, 'ids': ids});
  }

  void saveMusicReference(String id, String key) {
    if (!RegExp(r'^-?\d+_\d+$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(key)) {
      throw const ProofFailure('invalid_music_reference');
    }
    db.execute(
      'INSERT INTO music_refs VALUES(?,?) ON CONFLICT(track) DO UPDATE SET music_key=excluded.music_key',
      [id, key],
    );
  }

  String? musicReference(String id) =>
      db.select('SELECT music_key FROM music_refs WHERE track=?', [
            id,
          ]).firstOrNull?['music_key']
          as String?;

  dynamic setting(String key, [dynamic fallback]) {
    final rows = db.select('SELECT value FROM settings WHERE key=?', [key]);
    if (rows.isEmpty) return fallback;
    try {
      return jsonDecode(rows.first['value'] as String);
    } catch (_) {
      return fallback;
    }
  }

  void setSetting(String key, Object? value) => db.execute(
    'INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, jsonEncode(value)],
  );

  void merge(Iterable<Track> tracks, {int? discoveredAt}) => transaction(() {
    final stamp = discoveredAt ?? now;
    final stmt = db.prepare('''INSERT INTO tracks(id,title,artist,duration,search_text,updated) VALUES(?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title,artist=excluded.artist,
      duration=excluded.duration,search_text=excluded.search_text''');
    try {
      for (final track in tracks) {
        Track.fromJson(track.toJson());
        stmt.execute([
          track.id,
          track.title,
          track.artist,
          track.duration,
          '${track.title} ${track.artist}'.toLowerCase(),
          stamp,
        ]);
      }
    } finally {
      stmt.close();
    }
  });
  int get count =>
      db.select('SELECT COUNT(*) AS n FROM tracks').first['n'] as int;
  Track? track(String id) {
    final rows = db.select('SELECT * FROM tracks WHERE id=?', [id]);
    return rows.isEmpty ? null : Track.fromJson(rows.first);
  }

  DateTime? importedAt(String id) {
    final stamp = db.select('SELECT updated FROM tracks WHERE id=?', [
      id,
    ]).firstOrNull?['updated'];
    return stamp is int && stamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(stamp)
        : null;
  }

  Map<String, dynamic> metadata(String id) {
    final value = db.select('SELECT body FROM track_metadata WHERE track=?', [
      id,
    ]).firstOrNull?['body'];
    if (value is! String) return {};
    try {
      return sanitizeMetadata(jsonDecode(value) as Map);
    } catch (_) {
      return {};
    }
  }

  void mergeMetadata(String id, Map value) {
    final previous = metadata(id);
    final next = {...previous, ...sanitizeMetadata(value)};
    if (jsonEncode(previous) == jsonEncode(next)) return;
    db.execute(
      'INSERT INTO track_metadata(track,body) VALUES(?,?) ON CONFLICT(track) DO UPDATE SET body=excluded.body',
      [id, jsonEncode(next)],
    );
  }

  String? artworkKey(String id) {
    final key = db.select('SELECT artwork FROM track_metadata WHERE track=?', [
      id,
    ]).firstOrNull?['artwork'];
    return key is String && RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(key)
        ? key
        : null;
  }

  void saveArtwork(String id, String key) {
    if (!RegExp(r'^[a-f0-9]{64}\.img$').hasMatch(key)) {
      throw const ProofFailure('invalid_artwork_key');
    }
    db.execute(
      'INSERT INTO track_metadata(track,artwork) VALUES(?,?) ON CONFLICT(track) DO UPDATE SET artwork=excluded.artwork',
      [id, key],
    );
  }

  Map<String, dynamic> lyrics(String id) {
    final value = db.select('SELECT body FROM track_lyrics WHERE track=?', [
      id,
    ]).firstOrNull?['body'];
    try {
      if (value is String) return Map<String, dynamic>.from(jsonDecode(value));
    } catch (_) {
      /* Retry bad optional data. */
    }
    return {'state': 'unknown'};
  }

  void saveLyrics(String id, Map? content, {required String state}) {
    if (!['available', 'unknown', 'not_provided', 'failed'].contains(state)) {
      throw const ProofFailure('invalid_lyrics_state');
    }
    final clean = sanitizeLyrics(content);
    if (lyrics(id)['state'] == 'available' && clean == null) return;
    final body = {
      'state': clean != null ? 'available' : state,
      'checkedAt': now,
      ...?clean,
    };
    db.execute(
      'INSERT INTO track_lyrics VALUES(?,?) ON CONFLICT(track) DO UPDATE SET body=excluded.body',
      [id, jsonEncode(body)],
    );
  }

  List<LibraryRow> rows({
    String view = 'library',
    String query = '',
    int? pile,
  }) {
    var join = '',
        where = '1=1',
        order =
            'COALESCE(t.provider_epoch,0) DESC,COALESCE(t.provider_position,50001),t.updated DESC,t.rowid',
        occurrence = 'NULL';
    final args = <Object?>[];
    if (pile != null) {
      join = 'JOIN entries e ON e.track=t.id';
      where = 'e.pile=?';
      args.add(pile);
      order = 'e.id DESC';
      occurrence = 'e.id';
    } else if (view == 'offline') {
      where = 'a.track IS NOT NULL';
    } else if (view == 'recent') {
      join = 'JOIN (SELECT track,MAX(id) AS last_play FROM plays GROUP BY track) p ON p.track=t.id';
      order = 'p.last_play DESC';
    } else if (view == 'most') {
      join = 'JOIN (SELECT track,SUM(qualified) AS listens,MAX(id) AS last_play FROM plays GROUP BY track HAVING listens>0) p ON p.track=t.id';
      order = 'p.listens DESC,p.last_play DESC';
    }
    if (query.trim().isNotEmpty) {
      where += ' AND instr(t.search_text,?)>0';
      args.add(query.trim().toLowerCase());
    }
    return db
        .select(
          '''SELECT t.*,a.track IS NOT NULL AS offline,
      EXISTS(SELECT 1 FROM pins n WHERE n.track=t.id) AS pinned,$occurrence AS occurrence
      FROM tracks t LEFT JOIN assets a ON a.track=t.id $join WHERE $where ORDER BY $order''',
          args,
        )
        .map(
          (r) => LibraryRow(
            Track.fromJson(r),
            r['offline'] == 1,
            r['pinned'] == 1,
            r['occurrence'] as int?,
            r['error'] as String?,
          ),
        )
        .toList();
  }

  void trackError(String id, String? error) =>
      db.execute('UPDATE tracks SET error=? WHERE id=?', [error, id]);
  List<Pile> piles() => db
      .select('''SELECT p.*,(SELECT COUNT(*) FROM entries WHERE pile=p.id) AS n
    FROM piles p ORDER BY p.id''')
      .map((r) => Pile(r['id'], r['name'], r['n'], r['pinned'] == 1))
      .toList();
  String validName(String name) {
    final value = name.trim();
    if (value.isEmpty || value.length > 80) {
      throw const ProofFailure('pile_name_invalid');
    }
    return value;
  }

  int createPile(String name) {
    db.execute('INSERT INTO piles(name) VALUES(?)', [validName(name)]);
    return db.lastInsertRowId;
  }

  void renamePile(int id, String name) =>
      db.execute('UPDATE piles SET name=? WHERE id=?', [validName(name), id]);
  void deletePile(int id) => transaction(() {
    db.execute("DELETE FROM pins WHERE kind='pile' AND target=?", ['$id']);
    db.execute('DELETE FROM piles WHERE id=?', [id]);
  });
  int addToPile(int pile, String id) => transaction(() {
    db.execute('INSERT INTO entries(pile,track,added) VALUES(?,?,?)', [
      pile,
      id,
      now,
    ]);
    final entry = db.lastInsertRowId;
    if (db.select('SELECT pinned FROM piles WHERE id=?', [
          pile,
        ]).first['pinned'] ==
        1) {
      db.execute("INSERT OR IGNORE INTO pins VALUES('pile',?,?)", [
        '$pile',
        id,
      ]);
    }
    return entry;
  });
  void removeOccurrence(int entry) =>
      db.execute('DELETE FROM entries WHERE id=?', [entry]);
  bool isPinned(String id) =>
      db.select('SELECT 1 FROM pins WHERE track=? LIMIT 1', [id]).isNotEmpty;
  bool individuallyPinned(String id) => db.select(
    "SELECT 1 FROM pins WHERE kind='track' AND track=?",
    [id],
  ).isNotEmpty;
  void pinTrack(String id, bool pinned) {
    if (pinned) {
      db.execute("INSERT OR IGNORE INTO pins VALUES('track',?,?)", [id, id]);
    } else {
      db.execute("DELETE FROM pins WHERE kind='track' AND track=?", [id]);
    }
  }

  void pinPile(int id, bool pinned) => transaction(() {
    db.execute('UPDATE piles SET pinned=? WHERE id=?', [pinned ? 1 : 0, id]);
    if (pinned) {
      db.execute(
        "INSERT OR IGNORE INTO pins SELECT 'pile',?,track FROM entries WHERE pile=?",
        ['$id', id],
      );
    } else {
      db.execute("DELETE FROM pins WHERE kind='pile' AND target=?", ['$id']);
    }
  });
  List<String> get pendingPins => db
      .select(
        'SELECT DISTINCT p.track FROM pins p LEFT JOIN assets a ON a.track=p.track WHERE a.track IS NULL',
      )
      .map((r) => r['track'] as String)
      .toList();
  void saveAsset(CachedAudio a, {bool identityVerified = false}) {
    db.execute('INSERT OR REPLACE INTO assets VALUES(?,?,?,?,?,?)', [
      a.id,
      a.entry,
      a.digest,
      a.bytes,
      a.duration,
      now,
    ]);
    if (identityVerified) markAssetIdentity(a);
  }

  bool markAssetIdentity(CachedAudio asset) {
    db.execute(
      'INSERT OR REPLACE INTO asset_identity SELECT track,digest FROM assets WHERE track=? AND digest=?',
      [asset.id, asset.digest],
    );
    return db.select('SELECT changes() AS n').first['n'] == 1;
  }

  Set<String> verifiedAssetIds() => db
      .select(
        'SELECT i.track FROM asset_identity i JOIN assets a ON a.track=i.track AND a.digest=i.digest',
      )
      .map((row) => row['track'] as String)
      .toSet();
  CachedAudio? asset(String id) {
    final rows = db.select('SELECT * FROM assets WHERE track=?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return CachedAudio(id, r['entry'], r['digest'], r['bytes'], r['duration']);
  }

  void touchAsset(String id) =>
      db.execute('UPDATE assets SET accessed=? WHERE track=?', [now, id]);
  void forgetAsset(String id) =>
      db.execute('DELETE FROM assets WHERE track=?', [id]);
  int usedBytes({required bool pinned}) =>
      db.select(
            '''SELECT COALESCE(SUM(bytes),0) AS n FROM assets a
    WHERE ${pinned ? '' : 'NOT '}EXISTS(SELECT 1 FROM pins p WHERE p.track=a.track)''',
          ).first['n']
          as int;
  List<String> evictionOrder(Set<String> protected) => db
      .select(
        '''SELECT track FROM assets a
    WHERE NOT EXISTS(SELECT 1 FROM pins p WHERE p.track=a.track) ORDER BY accessed,track''',
      )
      .map((r) => r['track'] as String)
      .where((id) => !protected.contains(id))
      .toList();
  int startPlay(String id) {
    db.execute('INSERT INTO plays(track,started) VALUES(?,?)', [id, now]);
    return db.lastInsertRowId;
  }

  void listen(int event, int milliseconds, double duration) {
    final threshold = (duration > 0 ? (duration * 500).clamp(1, 30000) : 30000)
        .round();
    db.execute(
      'UPDATE plays SET listened=?,qualified=MAX(qualified,?) WHERE id=?',
      [milliseconds, milliseconds >= threshold ? 1 : 0, event],
    );
  }

  void report(String category, {int? count}) {
    if (!RegExp(r'^[a-z0-9_]{1,80}$').hasMatch(category)) {
      category = 'operation_failed';
    }
    File('${directory.path}/status.json').writeAsStringSync(
      jsonEncode({
        'category': category,
        'count': ?count,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  void close() => db.close();
}
