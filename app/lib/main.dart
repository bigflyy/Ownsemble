import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'bench/speed_bench.dart';
import 'library/library_store.dart';
import 'playback/playback_controller.dart';
import 'playback/player_service.dart';
import 'storage/audio_storage.dart';
import 'sync/background_sync.dart';
import 'ui/library_controller.dart';
import 'ui/library_screen.dart';
import 'ui/sync_controller.dart';
import 'vk/vk_client.dart';

/// Command-line options of the app.
class AppOptions {
  AppOptions({
    required this.dataDir,
    this.vkSession,
    this.muted = false,
    this.metricsFile,
    this.benchFile,
    this.benchParts,
    this.mpvOptions = const {},
    this.mpvLog = false,
    this.cacheWhileStreaming = true,
  });

  /// Parses `--data-dir DIR --vk-session FILE --muted --metrics FILE
  /// --bench FILE --bench-parts a,b --mpv name=value ... --mpv-log`.
  factory AppOptions.parse(List<String> args) {
    String? valueOf(String name) {
      final index = args.indexOf(name);
      return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
    }

    return AppOptions(
      dataDir:
          valueOf('--data-dir') ??
          p.join(
            Platform.environment['LOCALAPPDATA'] ?? '.',
            'Ownsemble',
            'v2',
          ),
      vkSession: valueOf('--vk-session'),
      muted: args.contains('--muted'),
      metricsFile: valueOf('--metrics'),
      benchFile: valueOf('--bench'),
      benchParts: valueOf('--bench-parts')?.split(','),
      mpvLog: args.contains('--mpv-log'),
      cacheWhileStreaming: !args.contains('--no-stream-cache'),
      mpvOptions: {
        for (var i = 0; i + 1 < args.length; i++)
          if (args[i] == '--mpv' && args[i + 1].contains('='))
            args[i + 1].substring(0, args[i + 1].indexOf('=')): args[i + 1]
                .substring(args[i + 1].indexOf('=') + 1),
      },
    );
  }

  /// Folder with library.db, cached audio and perf.log.
  final String dataDir;

  /// Saved VK session (cookies JSON); VK songs stream only when set.
  final String? vkSession;
  final bool muted;

  /// Where to write startup timings (JSON), for the speed gate.
  final String? metricsFile;

  /// Where to write benchmark results (JSON); the app exits afterwards.
  final String? benchFile;

  /// Benchmark parts to run (search, scroll, playCached, playStream); all
  /// when null.
  final List<String>? benchParts;

  /// mpv option overrides, for tuning playback start.
  final Map<String, String> mpvOptions;

  /// Write mpv's verbose log (links removed) to mpv.log in the data folder.
  final bool mpvLog;

  /// Save streamed songs to the cache while they play; off with
  /// --no-stream-cache (the speed gate, to keep its data unchanged).
  final bool cacheWhileStreaming;
}

Future<void> main(List<String> args) async {
  final mainStartedAt = DateTime.now();
  final options = AppOptions.parse(args);
  Directory(options.dataDir).createSync(recursive: true);

  // The library is read before the first frame so that frame already shows
  // the list; at 10,000 songs this takes a few milliseconds.
  final loadClock = Stopwatch()..start();
  final dbPath = p.join(options.dataDir, 'library.db');
  final store = LibraryStore.open(dbPath);
  final tracks = store.loadAll();
  final sources = store.sources();
  final loadMs = loadClock.elapsedMilliseconds;

  final sessionFile = options.vkSession == null
      ? null
      : File(options.vkSession!);
  final vk = sessionFile != null && sessionFile.existsSync()
      ? VkClient(SessionCookie.loadAll(sessionFile))
      : null;
  final player = PlayerService(
    vk: vk,
    muted: options.muted,
    dataDir: options.dataDir,
    mpvOptions: options.mpvOptions,
    mpvLog: options.mpvLog ? File(p.join(options.dataDir, 'mpv.log')) : null,
    storage: AudioStorage(dataDir: options.dataDir, store: store),
    cacheWhileStreaming: options.cacheWhileStreaming,
  );
  final library = LibraryController(tracks);
  // The store stays open while the app runs, for History and stored audio;
  // the sync uses its own connection.
  final playback = PlaybackController(
    player: player,
    recordPlay: (track) => store.addPlay(track.id),
  );
  final sync = SyncController(
    sources: sources,
    runner: vk == null
        ? null
        : (onProgress) => syncVkInBackground(
            dbPath: dbPath,
            sessionPath: sessionFile!.path,
            onProgress: onProgress,
          ),
    onLibraryChanged: (loaded) =>
        library.replaceTracks(loaded.tracks, loaded.index),
  );

  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      _afterFirstFrame(
        options: options,
        mainStartedAt: mainStartedAt,
        loadMs: loadMs,
        library: library,
        player: player,
        vk: vk,
        sync: sync,
      ),
    );
  });
  runApp(OwnsembleApp(library: library, playback: playback, sync: sync));
}

/// Startup work that must not delay the first frame: metrics, the player,
/// a VK token and the start sync, then the benchmark if requested.
Future<void> _afterFirstFrame({
  required AppOptions options,
  required DateTime mainStartedAt,
  required int loadMs,
  required LibraryController library,
  required PlayerService player,
  required VkClient? vk,
  required SyncController sync,
}) async {
  final firstFrameAt = DateTime.now();
  if (options.metricsFile != null) {
    File(options.metricsFile!).writeAsStringSync(
      jsonEncode({
        'mainStartedEpochMs': mainStartedAt.millisecondsSinceEpoch,
        'firstFrameEpochMs': firstFrameAt.millisecondsSinceEpoch,
        'libraryLoadMs': loadMs,
        'songsInFirstFrame': library.visible.length,
      }),
    );
  }

  await player.init();
  // The library syncs itself on every start, in the background.
  final startSync = sync.syncNow();
  _logPlayTimings(player, File(p.join(options.dataDir, 'perf.log')));
  try {
    await vk?.ensureToken();
  } catch (_) {
    // Offline or session expired: VK songs fail at play time with a message.
  }

  if (options.benchFile != null) {
    // Measure the library as it is after the start sync, not while the
    // sync may swap it out.
    await startSync;
    final result = await SpeedBench(
      library: library,
      player: player,
      vk: vk,
    ).run(parts: options.benchParts);
    File(options.benchFile!)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    exit(0);
  }
}

/// Appends every play's timing to perf.log (no titles, links or tokens).
void _logPlayTimings(PlayerService player, File log) {
  player.timings.listen((timing) {
    final kind = timing.cached ? 'cached' : 'stream';
    final line = timing.ok
        ? '$kind sound ${timing.toSoundMs} ms'
              '${timing.cached ? '' : ' (VK link ${timing.resolveMs} ms)'}'
        : '$kind failed after ${timing.toSoundMs} ms: ${timing.error}';
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $line\n',
      mode: FileMode.append,
    );
  });
}

class OwnsembleApp extends StatelessWidget {
  const OwnsembleApp({
    super.key,
    required this.library,
    required this.playback,
    this.sync,
  });

  final LibraryController library;
  final PlaybackController playback;
  final SyncController? sync;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ownsemble v2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6D8BFF),
        brightness: Brightness.dark,
      ),
      home: LibraryScreen(library: library, playback: playback, sync: sync),
    );
  }
}
