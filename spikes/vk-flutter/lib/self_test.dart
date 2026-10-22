import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'audio_cache.dart';
import 'proof_core.dart';
import 'proof_player.dart';
import 'proof_store.dart';

typedef VisitPage = Future<void> Function(Uri url);
typedef ReadScript = Future<dynamic> Function(String script);
typedef TapPoint = Future<void> Function(double x, double y);

class LocalFixture {
  final HttpServer server;
  final Map<String, List<int>> assets;
  int requests = 0;
  LocalFixture._(this.server, this.assets);
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  static Future<LocalFixture> start() async {
    final assets = <String, List<int>>{};
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final name in manifest.listAssets().where(
      (n) => n.startsWith('assets/'),
    )) {
      assets[name.substring(7)] = (await rootBundle.load(name)).buffer
          .asUint8List();
    }
    final fixture = LocalFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      assets,
    );
    fixture.server.listen((request) async {
      fixture.requests++;
      if (request.uri.path == '/page') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('''<!doctype html><html><body style="margin:0;background:#18202a;color:white">
<button id="play" style="position:absolute;left:40px;top:60px;width:180px;height:70px">Synthetic track</button>
<script>window.trustedCount=0;document.getElementById('play').onclick=(event)=>{
 if(event.isTrusted)window.trustedCount++;const audio=new Audio('/tone.wav');audio.muted=true;audio.play().catch(()=>{});
};</script></body></html>''');
      } else {
        final bytes = assets[request.uri.path.substring(1)];
        if (bytes == null) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType =
              request.uri.path.endsWith('.m3u8')
              ? ContentType('application', 'vnd.apple.mpegurl')
              : ContentType.binary;
          request.response.add(bytes);
        }
      }
      await request.response.close();
    });
    return fixture;
  }

  Future<void> close() => server.close(force: true);
}

Future<void> runFixtureProof(
  ProofStore store,
  VisitPage visit,
  ReadScript evaluate,
  TapPoint tap, {
  required bool Function() sawResource,
  bool browser = true,
}) async {
  final fixture = await LocalFixture.start();
  try {
    if (browser) {
      store.status('synthetic_webview');
      await visit(fixture.base.resolve('/page'));
      await waitUntil(() => sawResource(), 'webview_resource_hook_failed');
      final point = decodeMap(
        await evaluate(
          'JSON.stringify((()=>{const r=document.getElementById("play").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})())',
        ),
      );
      await tap((point['x'] as num).toDouble(), (point['y'] as num).toDouble());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final trusted = await evaluate('window.trustedCount');
      if (trusted is! num || trusted < 1) {
        throw const ProofFailure('webview_native_input_failed');
      }
      store.record('webview_native_input_checked', {
        'native_trusted': true,
        'passed': true,
      });
    }
    store.merge(const [
      Track('900000000000001_1', 'Синтетический трек', 'Ownsemble', 4),
      Track('900000000000001_2', 'Second', 'Ownsemble', 4),
      Track('900000000000001_3', 'TS MP3 fixture', 'Ownsemble', 4),
    ]);
    if (store.tracks().length < 2) {
      throw const ProofFailure('sqlite_persistence_failed');
    }
    store.record('sqlite_checked', {
      'rows': store.tracks().length,
      'passed': true,
    });
    final dir = Directory('${store.directory.path}/fixture-cache');
    // This fixed directory contains generated fixture audio only, never VK data.
    if (await dir.exists()) await dir.delete(recursive: true);
    final cache = AudioCache(
      dir,
      decodeLocalAudio,
      fixturePort: fixture.server.port,
    );
    store.status('synthetic_hls_download');
    final asset = await cache.save(
      const Track('900000000000001_1', 'Fixture', 'Ownsemble', 4),
      fixture.base.resolve('/synthetic.m3u8'),
    );
    store.saveAsset(asset);
    store.record('portable_hls_cached', {
      'bytes': asset.bytes,
      'duration': asset.duration,
      'passed': true,
    });
    await checkLocalPlayer(asset.entry);
    store.record('flutter_player_checked', {'phase': 'online', 'passed': true});
    final mp3 = await cache.save(
      const Track('900000000000001_2', 'MP3 fixture', 'Ownsemble', 4),
      fixture.base.resolve('/synthetic-mp3.m3u8'),
    );
    if (!mp3.entry.endsWith('audio.mp3')) {
      throw const ProofFailure('mp3_cache_not_normalized');
    }
    store.saveAsset(mp3);
    await cache.verify(mp3);
    await checkLocalPlayer(mp3.entry);
    store.record('portable_mp3_hls_cached', {
      'bytes': mp3.bytes,
      'duration': mp3.duration,
      'codec': 'mp3',
      'passed': true,
    });
    final wrapped = await cache.save(
      const Track('900000000000001_3', 'TS MP3 fixture', 'Ownsemble', 4),
      fixture.base.resolve('/synthetic-ts-mp3.m3u8'),
    );
    if (wrapped.digest != mp3.digest) {
      throw const ProofFailure('ts_mp3_frame_integrity_failed');
    }
    store.saveAsset(wrapped);
    await cache.verify(wrapped);
    await checkLocalPlayer(wrapped.entry);
    store.record('portable_ts_mp3_cached', {
      'bytes': wrapped.bytes,
      'duration': wrapped.duration,
      'codec': 'mp3',
      'passed': true,
    });
    cache.offline = true;
    final before = fixture.requests;
    try {
      await cache.fetch(fixture.base.resolve('/tone.wav'));
      throw const ProofFailure('offline_guard_failed');
    } on ProofFailure catch (error) {
      if (error.category != 'offline_network_blocked') rethrow;
    }
    final trap = File('${store.directory.path}/remote-trap.m3u8');
    await trap.writeAsString(
      '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\n${fixture.base.resolve('/synthetic-000.ts')}\n#EXT-X-ENDLIST\n',
    );
    var rejected = false;
    try {
      await decodeLocalAudio(trap.path);
    } on ProofFailure {
      rejected = true;
    }
    if (!rejected || fixture.requests != before) {
      throw const ProofFailure('native_offline_guard_failed');
    }
    store.record('offline_network_guard_checked', {
      'requests': fixture.requests - before,
      'passed': true,
    });
    await File(
      '${store.directory.path}/resume.json',
    ).writeAsString(jsonEncode({'phase': 'offline_pending', 'id': wrapped.id}));
    store.record('offline_restart_pending');
    store.status('offline_restart_pending');
  } finally {
    await fixture.close();
  }
}

Future<void> runOfflineProof(ProofStore store) async {
  store.status('offline_verification');
  final checkpoint = File('${store.directory.path}/resume.json');
  final resume = checkpoint.existsSync()
      ? jsonDecode(await checkpoint.readAsString()) as Map
      : <String, dynamic>{};
  final asset = store.offlineAsset(resume['id'] as String?);
  if (asset == null) throw const ProofFailure('offline_asset_missing');
  final cache = AudioCache(File(asset.entry).parent.parent, decodeLocalAudio)
    ..offline = true;
  await cache.verify(asset);
  await checkLocalPlayer(asset.entry);
  store.record('flutter_player_checked', {'phase': 'offline', 'passed': true});
  store.record('sqlite_restart_checked', {
    'rows': store.tracks().length,
    'passed': store.tracks().length >= 2,
  });
  await checkpoint.writeAsString(
    jsonEncode({'phase': 'finished', 'id': asset.id}),
  );
  store.record('flutter_proof_finished', {'passed': true, 'offline': true});
  store.status('technical_checks_finished', passed: true);
}

// Only the reference probe's public catalog/index and completed audio are read.
// Its browser/session directories are never opened or copied.
Future<void> checkReferenceSample(ProofStore store, String repository) async {
  if (!Platform.isWindows) return;
  final base = '$repository/.local/vk-proof';
  final catalog = File('$base/library.json');
  final index = File('$base/cache-index.json');
  if (!catalog.existsSync() || !index.existsSync()) return;
  final tracks = (jsonDecode(await catalog.readAsString()) as List)
      .map((v) => Track.fromJson(Map<String, dynamic>.from(v)))
      .toList();
  store.merge(tracks);
  store.record('reference_catalog_imported', {'count': tracks.length});
  final cached = jsonDecode(await index.readAsString()) as Map;
  for (final track in tracks) {
    final item = cached[track.id];
    if (item is! Map) continue;
    final filename = item['filename'], digest = item['sha256'];
    if (filename is! String ||
        digest is! String ||
        !RegExp(r'^-?\d+_\d+\.(?:mp3|m4a)$').hasMatch(filename) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      continue;
    }
    final cache = AudioCache(
      Directory('${store.directory.path}/vk-cache'),
      decodeLocalAudio,
    );
    final existing = store.assets().where((a) => a.id == track.id).firstOrNull;
    final asset =
        existing ??
        await cache.importLocal(track, File('$base/audio/$filename'), digest);
    await cache.verify(asset);
    await checkLocalPlayer(asset.entry);
    store.saveAsset(asset);
    store.record('reference_real_audio_checked', {
      'bytes': asset.bytes,
      'duration': asset.duration,
      'passed': true,
    });
    await File(
      '${store.directory.path}/resume.json',
    ).writeAsString(jsonEncode({'phase': 'offline_pending', 'id': asset.id}));
    return;
  }
}
