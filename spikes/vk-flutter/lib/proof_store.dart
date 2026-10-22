import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'audio_cache.dart';
import 'proof_core.dart';

class ProofStore {
  final Directory directory;
  late final Database db;
  final List<Map<String, dynamic>> events = [];
  ProofStore(this.directory) {
    directory.createSync(recursive: true);
    final evidence = File('${directory.path}/evidence.json');
    if (evidence.existsSync()) {
      try {
        final old = jsonDecode(evidence.readAsStringSync())['events'] as List;
        events.addAll(
          old.whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
        );
      } catch (_) {
        /* A malformed public report cannot prevent app startup. */
      }
    }
    db = sqlite3.open('${directory.path}/proof.sqlite');
    db.execute(
      'CREATE TABLE IF NOT EXISTS tracks(id TEXT PRIMARY KEY,title TEXT,artist TEXT,duration REAL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY,entry TEXT,digest TEXT,bytes INTEGER,duration REAL)',
    );
  }
  void merge(List<Track> tracks) {
    db.execute('BEGIN');
    final statement = db.prepare(
      'INSERT INTO tracks VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,artist=excluded.artist,duration=excluded.duration',
    );
    try {
      for (final track in tracks) {
        statement.execute([
          track.id,
          track.title,
          track.artist,
          track.duration,
        ]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      statement.close();
    }
  }

  List<Track> tracks() => db
      .select('SELECT * FROM tracks ORDER BY rowid')
      .map((r) => Track.fromJson(r))
      .toList();
  void saveAsset(CachedAudio asset) => db.execute(
    'INSERT OR REPLACE INTO assets VALUES(?,?,?,?,?)',
    [asset.id, asset.entry, asset.digest, asset.bytes, asset.duration],
  );
  List<CachedAudio> assets() => db
      .select('SELECT * FROM assets')
      .map(
        (r) => CachedAudio(
          r['id'],
          r['entry'],
          r['digest'],
          r['bytes'],
          r['duration'],
        ),
      )
      .toList();
  CachedAudio? offlineAsset(String? preferredId) {
    final cached = assets();
    if (preferredId != null) {
      return cached.where((asset) => asset.id == preferredId).firstOrNull;
    }
    // Older completed checkpoints discarded their sample ID. Prefer a real
    // cached song when reopening those checkpoints, then a generated fixture.
    return cached
            .where((asset) => !asset.id.startsWith('900000000000001_'))
            .lastOrNull ??
        cached.lastOrNull;
  }

  void record(String event, [Map<String, dynamic> fields = const {}]) {
    const allowed = {
      'count',
      'bytes',
      'duration',
      'passed',
      'phase',
      'category',
      'rows',
      'candidates',
      'offline',
      'native_trusted',
      'platform',
      'requests',
      'complete',
      'stage',
      'codec',
      'attempt',
      'kind',
      'code',
    };
    final clean = <String, dynamic>{};
    for (final item in fields.entries) {
      if (!allowed.contains(item.key)) continue;
      final value = item.value;
      if (value is bool ||
          value is num && value.isFinite ||
          value is String && RegExp(r'^[a-z0-9_]{1,80}$').hasMatch(value)) {
        clean[item.key] = value;
      }
    }
    events.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      ...clean,
    });
    final file = File('${directory.path}/evidence.json');
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'platform': Platform.operatingSystem,
        'events': events.length > 600
            ? events.sublist(events.length - 600)
            : events,
      }),
    );
    temporary.renameSync(file.path);
  }

  void status(String stage, {bool passed = false, String? category}) {
    File('${directory.path}/status.json').writeAsStringSync(
      jsonEncode({
        'stage': stage,
        'passed': passed,
        'category': ?category,
        'platform': Platform.operatingSystem,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  void close() => db.close();
}
