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
import 'storage/cover_store.dart';
import 'sync/background_sync.dart';
import 'ui/collections_controller.dart';
import 'ui/cover_tile.dart';
import 'ui/library_controller.dart';
import 'ui/library_screen.dart';
import 'ui/shell_settings.dart';
import 'ui/sync_controller.dart';
import 'ui/theme.dart';
import 'ui/vk_account.dart';
import 'vk/vk_login_window.dart';
import 'vk/vk_session.dart';

/// How many decoded covers stay in memory.
const maxDecodedCovers = 600;

/// How many bytes of decoded covers stay in memory.
const maxDecodedCoverBytes = 24 * 1024 * 1024;

/// Command-line options of the app.
class AppOptions {
  AppOptions({
    required this.dataDir,
    this.vkSession,
    this.vkLoginSeed,
    this.muted = false,
    this.metricsFile,
    this.benchFile,
    this.benchParts,
    this.benchVolume = 100,
    this.mpvOptions = const {},
    this.mpvLog = false,
    this.cacheWhileStreaming = true,
  });

  /// Parses `--data-dir DIR --vk-session FILE --vk-login-seed FILE --muted
  /// --metrics FILE
  /// --bench FILE --bench-parts a,b --bench-volume N --mpv name=value ...
  /// --mpv-log`.
  factory AppOptions.parse(List<String> args) {
    String? valueOf(String name) {
      final index = args.indexOf(name);
      return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
    }

    return AppOptions(
      dataDir:
          valueOf('--data-dir') ??
          p.join(Platform.environment['APPDATA'] ?? '.', 'Ownsemble', 'v2'),
      vkSession: valueOf('--vk-session'),
      vkLoginSeed: valueOf('--vk-login-seed'),
      muted: args.contains('--muted'),
      metricsFile: valueOf('--metrics'),
      benchFile: valueOf('--bench'),
      benchParts: valueOf('--bench-parts')?.split(','),
      benchVolume: double.parse(valueOf('--bench-volume') ?? '100'),
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

  /// The test account's session file (cookies JSON). Without it the session
  /// comes from the login window and is kept encrypted in the data folder.
  final String? vkSession;

  /// Test account cookies for the login window: the agent's login check puts
  /// them there because it never types into a login page.
  final String? vkLoginSeed;
  final bool muted;

  /// Where to write startup timings (JSON), for the speed gate.
  final String? metricsFile;

  /// Where to write benchmark results (JSON); the app exits afterwards.
  final String? benchFile;

  /// Benchmark parts to run (search, scroll, playCached, playStream,
  /// seekStream); all when null. See [SpeedBench.run] for saveVolume and
  /// savedVolume, which only run when named.
  final List<String>? benchParts;

  /// Player volume during the benchmark, under mute.
  final double benchVolume;

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
  // First: the login window's channel below needs the binding.
  WidgetsFlutterBinding.ensureInitialized();
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
  // The store stays open while the app runs, for History, Stacks, stored
  // audio and settings; the sync uses its own connection.
  final storage = AudioStorage(dataDir: options.dataDir, store: store);
  final covers = CoverStore(dataDir: options.dataDir);
  unawaited(covers.load());
  final collections = CollectionsController(store);
  final settings = ShellSettings(
    read: store.readSetting,
    write: store.writeSetting,
  );

  final sessionFile = options.vkSession;
  final account = VkAccount(
    sessions: sessionFile != null
        ? PlainSessionFile(File(sessionFile))
        : ProtectedSessionFile(File(p.join(options.dataDir, 'session.dpapi'))),
    window: NativeLoginWindow(
      userDataDir: p.join(options.dataDir, 'webview'),
      seedFile: options.vkLoginSeed == null ? null : File(options.vkLoginSeed!),
    ),
  );
  final player = PlayerService(
    vk: account.client,
    muted: options.muted,
    dataDir: options.dataDir,
    mpvOptions: options.mpvOptions,
    mpvLog: options.mpvLog ? File(p.join(options.dataDir, 'mpv.log')) : null,
    storage: storage,
    cacheWhileStreaming: options.cacheWhileStreaming,
  );
  final library = LibraryController(
    tracks,
    collections: collections,
    storage: storage,
  );
  final playback = PlaybackController(
    player: player,
    recordPlay: collections.recordPlay,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
  );
  // The sync reads the session each time: logging in or out changes it.
  SyncRunner? syncRunner() {
    final cookies = account.cookies;
    if (cookies == null) return null;
    return (onProgress) => syncVkInBackground(
      dbPath: dbPath,
      cookies: cookies,
      onProgress: onProgress,
    );
  }

  final sync = SyncController(
    sources: sources,
    runner: syncRunner(),
    onLibraryChanged: (loaded) =>
        library.replaceTracks(loaded.tracks, loaded.index),
  );
  // A new login is synced at once, so the library fills without another step.
  var loggedIn = account.loggedIn;
  account.addListener(() {
    player.vk = account.client;
    sync.runner = syncRunner();
    if (account.loggedIn && !loggedIn) unawaited(sync.syncNow());
    loggedIn = account.loggedIn;
  });

  // Far below Flutter's 100 MB default: decoded covers are the app's largest
  // memory use, and a screen of rows needs about 20 of them.
  PaintingBinding.instance.imageCache
    ..maximumSize = maxDecodedCovers
    ..maximumSizeBytes = maxDecodedCoverBytes;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      _afterFirstFrame(
        options: options,
        mainStartedAt: mainStartedAt,
        loadMs: loadMs,
        library: library,
        player: player,
        playback: playback,
        account: account,
        sync: sync,
        covers: covers,
      ),
    );
  });
  runApp(
    OwnsembleApp(
      covers: covers,
      library: library,
      playback: playback,
      sync: sync,
      account: account,
      collections: collections,
      settings: settings,
    ),
  );
}

/// Startup work that must not delay the first frame: metrics, the player,
/// a VK token and the start sync, then the benchmark if requested.
Future<void> _afterFirstFrame({
  required AppOptions options,
  required DateTime mainStartedAt,
  required int loadMs,
  required LibraryController library,
  required PlayerService player,
  required PlaybackController playback,
  required VkAccount account,
  required SyncController sync,
  required CoverStore covers,
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

  await player.init(volume: playback.volume, mute: playback.mutedByUser);
  // The library syncs itself on every start, in the background.
  final startSync = sync.syncNow();
  _logPlayTimings(player, File(p.join(options.dataDir, 'perf.log')));
  try {
    await account.client?.ensureToken();
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
      playback: playback,
      vk: account.client,
      covers: covers,
      volume: options.benchVolume,
    ).run(parts: options.benchParts);
    File(options.benchFile!)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    exit(0);
  }
}

/// Appends every play's timing and every proxied stream request's timing
/// to perf.log (no titles, links or tokens).
void _logPlayTimings(PlayerService player, File log) {
  player.proxyRequests.listen((request) {
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $request\n',
      mode: FileMode.append,
    );
  });
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
    required this.collections,
    required this.settings,
    required this.covers,
    this.sync,
    this.account,
  });

  final CoverStore covers;
  final LibraryController library;
  final PlaybackController playback;
  final CollectionsController collections;
  final ShellSettings settings;
  final SyncController? sync;
  final VkAccount? account;

  @override
  Widget build(BuildContext context) {
    return CoverScope(
      store: covers,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => MaterialApp(
          title: 'Ownsemble v2',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(settings.dark ? OwnColors.dark : OwnColors.light),
          home: LibraryScreen(
            library: library,
            playback: playback,
            sync: sync,
            account: account,
            collections: collections,
            settings: settings,
          ),
        ),
      ),
    );
  }
}
