import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'bench/speed_bench.dart';
import 'library/day_range.dart';
import 'library/library_store.dart';
import 'library/search_index.dart';
import 'library/similar_seeds.dart';
import 'library/track.dart';
import 'lyrics/fit_model.dart';
import 'lyrics/hear_helper.dart';
import 'lyrics/hear_words.dart';
import 'lyrics/lyrics_hearer.dart';
import 'lyrics/model_bundle.dart';
import 'lyrics/stt_models.dart';
import 'lyrics/stt_worker.dart';
import 'lyrics/lyrics_controller.dart';
import 'lyrics/lyrics_fitter.dart';
import 'lyrics/lyrics_sources.dart';
import 'lyrics/recording_fit.dart';
import 'playback/playback_controller.dart';
import 'platform/end_process.dart';
import 'platform/free_space.dart';
import 'playback/player_service.dart';
import 'playback/version_book.dart';
import 'storage/audio_storage.dart';
import 'storage/cover_store.dart';
import 'storage/stored_check.dart';
import 'sync/background_sync.dart';
import 'sync/file_check.dart';
import 'ui/albums.dart';
import 'ui/artists.dart';
import 'ui/catalog_search.dart';
import 'ui/collections_controller.dart';
import 'ui/cover_tile.dart';
import 'ui/for_you.dart';
import 'ui/library_controller.dart';
import 'ui/library_screen.dart';
import 'ui/outside_songs.dart';
import 'ui/playlists.dart';
import 'ui/shell_settings.dart';
import 'ui/song_filters.dart';
import 'ui/song_remover.dart';
import 'ui/source_editor.dart';
import 'ui/sources_scope.dart';
import 'ui/sync_controller.dart';
import 'ui/theme.dart';
import 'ui/vk_accounts.dart';
import 'vk/vk_client.dart';
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
    this.vkSessions = const [],
    this.vkLoginSeed,
    this.muted = false,
    this.metricsFile,
    this.benchFile,
    this.benchParts,
    this.benchVolume = 100,
    this.benchFitKeys = const [],
    this.benchHearKeys = const [],
    this.benchEditKeys = const [],
    this.benchWordsKeys = const [],
    this.mpvOptions = const {},
    this.mpvLog = false,
    this.cacheWhileStreaming = true,
  });

  /// Parses `--data-dir DIR --vk-session FILE [--vk-session FILE] --vk-login-seed
  /// FILE --muted --metrics FILE
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
      vkSessions: [
        for (var i = 0; i + 1 < args.length; i++)
          if (args[i] == '--vk-session') args[i + 1],
      ],
      vkLoginSeed: valueOf('--vk-login-seed'),
      muted: args.contains('--muted'),
      metricsFile: valueOf('--metrics'),
      benchFile: valueOf('--bench'),
      benchParts: valueOf('--bench-parts')?.split(','),
      benchVolume: double.parse(valueOf('--bench-volume') ?? '100'),
      benchFitKeys: valueOf('--bench-fit-keys')?.split(',') ?? const [],
      benchHearKeys: valueOf('--bench-hear-keys')?.split(',') ?? const [],
      benchEditKeys: valueOf('--bench-edit-keys')?.split(',') ?? const [],
      benchWordsKeys: valueOf('--bench-words-keys')?.split(',') ?? const [],
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

  /// The test accounts' session files (cookies JSON). Without one the sessions
  /// come from the login window and are kept encrypted in the data folder.
  final List<String> vkSessions;

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

  /// The library songs ("ownerId_audioId") the fitLive part fits to their
  /// recordings (plan 10 G4).
  final List<String> benchFitKeys;

  /// The hearLive part's songs (plan 10 I2f).
  final List<String> benchHearKeys;

  /// The editLive parts' songs (plan 10 I2g4): found lyrics, heard words.
  final List<String> benchEditKeys;

  /// The wordsLive part's songs (plan 10 J8): "kind=key".
  final List<String> benchWordsKeys;

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
  // Once: songs already gone from VK that build 6511BD13D982 removed, whose
  // Undo failed, come back (user, 2026-11-16: "restore them").
  const restoredGone = 'fix.restored_gone_removed_2026_11_16';
  if (store.readSetting(restoredGone) == null) {
    final back = store.restoreGoneRemovedSince(
      DateTime(2026, 11, 16).millisecondsSinceEpoch,
    );
    store.writeSetting(restoredGone, '$back');
  }
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

  final account = VkAccounts(
    vault: options.vkSessions.isNotEmpty
        ? PlainSessionFiles([for (final path in options.vkSessions) File(path)])
        : ProtectedSessionFolder(options.dataDir),
    window: NativeLoginWindow(
      userDataDir: p.join(options.dataDir, 'webview'),
      seedFile: options.vkLoginSeed == null ? null : File(options.vkLoginSeed!),
    ),
  );
  // A song streams through the account it came from: each source's account
  // is looked up at every play, so logins, logouts and new sources count.
  late final SyncController sync;
  VkClient? clientOfSource(int sourceId) {
    final source = sync.sourceList.value
        .where((s) => s.id == sourceId)
        .firstOrNull;
    if (source == null || source.kind != TrackSource.vk) return null;
    return account.clientFor(source.account);
  }

  // One line to perf.log: times and counts only, no titles, keys or links.
  void logPerf(String line) => File(p.join(options.dataDir, 'perf.log'))
      .writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
      );

  final versions = VersionBook.vk(
    store,
    persist: options.cacheWhileStreaming,
    log: logPerf,
  );
  final player = PlayerService(
    accounts: clientOfSource,
    muted: options.muted,
    dataDir: options.dataDir,
    mpvOptions: options.mpvOptions,
    mpvLog: options.mpvLog ? File(p.join(options.dataDir, 'mpv.log')) : null,
    storage: storage,
    cacheWhileStreaming: options.cacheWhileStreaming,
  )..versions = versions;
  final filters = SongFilters(
    store,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
    isOffline: (track) => storage.stateOf(track).path != null,
    isFavorite: (track) => collections.isFavorite(track.id),
  );
  // Chips or a sort kept from the last run need the play numbers before
  // the first frame; otherwise they are read just after it.
  if (filters.active) filters.load();
  collections.onPlaysChanged = filters.playsChanged;
  final library = LibraryController(
    tracks,
    filters: filters,
    collections: collections,
    storage: storage,
    versions: player.versions,
    albums: LibraryAlbums(
      store: store,
      apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    ),
    removedSongs: store.loadRemoved,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
  );
  final playback = PlaybackController(
    player: player,
    plays: collections,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
  );
  // Before the first frame, which then already shows the song.
  playback.restoreSession(library.byId);
  // A sync or a removed account reloads the library; the play list then
  // takes over the new songs, or it would keep the old library in memory.
  library.onTracksReplaced = playback.refreshTracks;
  // The periodic save is up to 5 s old: a normal close saves the exact place,
  // then ends the process, because the engine's own shutdown crashes or hangs
  // with mpv running (see endProcessNow).
  AppLifecycleListener(
    onExitRequested: () async {
      playback
        ..saveSession()
        ..closePlay();
      endProcessNow();
      return AppExitResponse.exit;
    },
  );
  // The sync reads the sessions each time: logging in or out changes them.
  // With [only], it syncs that account alone: a new login's first sync.
  SyncRunner? syncRunner({String? only}) {
    final sessions = [
      for (final session in account.sessions)
        if (only == null || session.account == only)
          VkSyncSession(session.account, session.cookies),
    ];
    if (sessions.isEmpty) return null;
    return (onProgress) => syncVkInBackground(
      dbPath: dbPath,
      sessions: sessions,
      onProgress: onProgress,
    );
  }

  // Stage M2: after each sync, every song's VK file is checked in the
  // background, so a swapped song has its version before it is played.
  FileCheckRunner? fileChecker() {
    final sessions = [
      for (final session in account.sessions)
        VkSyncSession(session.account, session.cookies),
    ];
    if (sessions.isEmpty) return null;
    return (onProgress, stop) => checkVkFilesInBackground(
      dbPath: dbPath,
      sessions: sessions,
      onProgress: onProgress,
      stop: stop,
    );
  }

  final perfLog = File(p.join(options.dataDir, 'perf.log'));
  sync = SyncController(
    sources: sources,
    runner: syncRunner(),
    checker: fileChecker(),
    onLibraryChanged: (loaded) =>
        library.replaceTracks(loaded.tracks, loaded.index),
    onFilesChecked: (outcome) {
      if (outcome.changedChoices) player.versions?.reload();
      // Counts and times only: no titles, keys or links.
      perfLog.writeAsStringSync(
        '${DateTime.now().toIso8601String()} file check: '
        '${outcome.checked} files in ${outcome.readMs} ms, '
        '${outcome.swapped} swapped, ${outcome.decided} decided, '
        '${outcome.failed} failed, ${outcome.forgotten} fixed by VK, '
        'search ${outcome.searchMs} ms\n',
        mode: FileMode.append,
      );
    },
  );
  // The source filter offers the sources with songs, and drops a filter
  // whose source left.
  library.watchSources(sync.sourceList);
  final sourceEditor = SourceEditor(
    store: store,
    sync: sync,
    library: library,
    dataDir: options.dataDir,
  );
  // Search place A's On VK part (plan 06, C3). A song added while a sync
  // runs is confirmed by one more sync right after it: the running one
  // listed the account before the add. A song added to several accounts
  // gets a sync at once, which merges its copies.
  void reloadLibrary() {
    final tracks = store.loadAll();
    library.replaceTracks(tracks, SearchIndex(tracks));
    sync.updateSources(store.sources());
  }

  final catalog = CatalogSearch(
    library: library,
    store: store,
    sources: sync.sourceList,
    apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    onLibraryChanged: ({required severalAccounts}) {
      reloadLibrary();
      if (sync.running || severalAccounts) {
        unawaited(sync.syncAfterRunning());
      }
    },
    // A song + added while it plays goes on as the library's song.
    onAdded: playback.adoptAdded,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
    log: logPerf,
  );
  // Songs of VK's lists the library lacks: one registry for For you and
  // the playlists (plan 08), so a song is the same in both.
  final outside = OutsideSongs(libraryCopyOfSong: catalog.libraryCopyOfSong);
  // The For you place (plan 07): what VK recommends to the first account.
  final forYou = ForYou(
    accounts: () => catalog.accounts,
    apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    libraryCopyOfSong: catalog.libraryCopyOfSong,
    outside: outside,
    cacheDir: options.dataDir,
    // Own "Similar to" shelves (plan 07, Stage E): from the History of the
    // last weeks and the Favorites.
    seedsOf: ({required skipTitles}) {
      final now = DateTime.now();
      DayRange lastDays(int days) =>
          DayRange(now.subtract(Duration(days: days - 1)), now);
      return pickSimilarSeeds(
        library: library.all,
        recent: store.songPlays(range: lastDays(recentDays)),
        lastMonth: store.songPlays(range: lastDays(rediscoverAfterDays)),
        favorites: [for (final f in collections.favorites) f.trackId],
        now: now,
        skipTitles: skipTitles,
      );
    },
    log: logPerf,
  );
  // The accounts' VK playlists (plan 08), mirrored after each sync.
  final playlists = VkPlaylists(
    accounts: () => catalog.accounts,
    apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    outside: outside,
    cacheDir: options.dataDir,
    log: logPerf,
  );
  // The library's artists (plan 09): the index is built after the first
  // frame (R12), VK's pages and photos through the first account.
  final artists = LibraryArtists(
    library: library,
    credits: store.songArtistCredits,
    albumKeys: store.listedVkAlbumKeys,
    plays: () => filters.allTime,
    loadPhotos: store.artistPhotos,
    savePhotos: store.saveArtistPhotos,
    outside: outside,
    accounts: () => catalog.accounts,
    apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    readSetting: store.readSetting,
    writeSetting: store.writeSetting,
    log: logPerf,
  );
  // Lyrics of the playing song (plan 10), asked only when shown or when a
  // song is downloaded, through the song's own account.
  final lyrics = LyricsController(
    load: store.lyricsOf,
    save: store.saveLyrics,
    // Plan 10 E2: the lyrics the user chose in the chooser, per upload.
    loadPick: store.lyricsPickOf,
    savePick: store.saveLyricsPick,
    // F1: timed lines moved by hand, per upload and source.
    loadOffset: store.lyricsOffsetOf,
    saveOffset: store.saveLyricsOffset,
    // G2: lines fitted to the recording, per upload and source, used only
    // for the stored file they were fitted to.
    loadFit: store.lyricsFitOf,
    saveFit: store.saveLyricsFit,
    // I2e: what "Hear the words" heard, per upload, apart from the sources.
    loadHeard: store.heardLyricsOf,
    // I2g: the user's own edits, per upload, apart from the sources.
    edits: store,
    audioBytesOf: (track) {
      final path = storage.stateOf(track).path;
      if (path == null) return null;
      final file = storage.fileAt(path);
      return file.existsSync() ? file.lengthSync() : null;
    },
    // The upload that plays: the account that has the song, or the version
    // chosen for it; logged out, the song's own key (stored lyrics show).
    routeOf: (track) {
      final routes = player.routesFor(track);
      if (routes.isNotEmpty) {
        final route = routes.first;
        return (
          key: route.sourceKey,
          accessKey: route.accessKey,
          call: route.client.call,
        );
      }
      return lyricsRouteBySource((_) => null)(track);
    },
    // Plan 10 E1: LRCLIB, then NetEase and QQ Music, when VK has no timed
    // lyrics.
    sources: outsideLyricsSources(httpGetJson()),
    log: logPerf,
  );
  playback.onDownloaded = lyrics.keepFor;
  // Plan 10 G2: Fit to this recording. The model is downloaded into the
  // data folder on the first fit the user agrees to; onnxruntime.dll and
  // libmpv-2.dll are beside the app.
  final appDir = p.dirname(Platform.resolvedExecutable);
  final modelFile = File(
    p.join(options.dataDir, 'models', alignerModel.fileName),
  );
  String fitCacheOf(String key) =>
      p.join(options.dataDir, 'fit-cache', '${fitCacheName(key)}.emission');
  String? storedAudioOf(Track track) {
    final path = storage.stateOf(track).path;
    if (path == null) return null;
    final file = storage.fileAt(path);
    return file.existsSync() ? file.path : null;
  }

  // The song's stored file, saved first when it only streams: the fit and
  // "Hear the words" both read the file.
  Future<String> audioOf(
    Track track,
    void Function(double share) onProgress,
  ) async {
    if (!storage.hasFile(track)) {
      void heard() => onProgress(storage.savedShare(track));
      storage.progress.addListener(heard);
      try {
        final error = await playback.download(track, pin: false);
        if (error != null) throw FitAudioError(error);
      } finally {
        storage.progress.removeListener(heard);
      }
    }
    final path = storage.stateOf(track).path;
    if (path == null || !storage.fileAt(path).existsSync()) {
      throw const FitAudioError('the song is not stored');
    }
    return storage.fileAt(path).path;
  }

  final fitter = LyricsFitter(
    lyrics: lyrics,
    modelFile: modelFile,
    downloadModelTo: (onProgress, stop) => downloadModel(
      alignerModel,
      modelFile,
      freeBytes: () => freeBytesAt(options.dataDir),
      onProgress: onProgress,
      stop: stop,
    ),
    audioOf: audioOf,
    fit: (key, audioPath, lines, onProgress) {
      final tempDir = Directory(p.join(options.dataDir, 'tmp'))
        ..createSync(recursive: true);
      return fitToRecording(
        audioPath,
        lines,
        FitTools(
          onnxRuntimePath: p.join(appDir, 'onnxruntime.dll'),
          modelPath: modelFile.path,
          mpvPath: p.join(appDir, 'libmpv-2.dll'),
          tempDir: tempDir.path,
        ),
        onProgress: onProgress,
        emissionCachePath: fitCacheOf(key),
      );
    },
    // G3: the chooser's ranking, only for stored songs.
    storedAudioOf: storedAudioOf,
    hasCachedOutput: (key) => File(fitCacheOf(key)).existsSync(),
    log: logPerf,
  );
  // Plan 10 I2f: Hear the words. The hear-words bundle goes into the data
  // folder on the first run the user agrees to, the Whisper bundle when a
  // song GigaAM doubts first needs it; the worker runs on its own isolate,
  // a new one per run, closed after it so its memory goes back.
  final modelsRoot = Directory(p.join(options.dataDir, 'models'));
  // The GPU for "Hear the words" (plan 10 I2i): the user's switch, its
  // files there, and no GPU failure since the app started.
  var gpuFailed = false;
  // Hearing runs in ownsemble_hear.exe beside the app (plan 10 I2i5), so
  // the GPU drivers' memory goes back when a song is done. Without it (a
  // build that lacks it) the app hears in its own process, on the CPU only:
  // the GPU drivers would stay loaded in the player.
  final hearHelperPath = p.join(appDir, hearHelperName);
  // For measurements only: OWNSEMBLE_HEAR_IN_APP=1 hears in the app's own
  // process, the GPU included, as before the helper (an A/B of its cost).
  final hearInAppForChecks =
      Platform.environment['OWNSEMBLE_HEAR_IN_APP'] == '1';
  final hearInHelper =
      Platform.isWindows &&
      !hearInAppForChecks &&
      File(hearHelperPath).existsSync();
  if (hearInAppForChecks) {
    logPerf('hear words: OWNSEMBLE_HEAR_IN_APP=1, hearing in the app');
  } else if (!hearInHelper) {
    logPerf('hear words: no $hearHelperName, hearing in the app, CPU only');
  }
  bool hearOnGpuNow() =>
      (hearInHelper || hearInAppForChecks) &&
      settings.hearOnGpu &&
      !gpuFailed &&
      bundleReady(modelsRoot, hearGpuBundle);
  final vocalsDir = Directory(p.join(options.dataDir, 'hear-vocals'));
  // Fixed once per PC: the heard words depend on the thread count (I2c).
  var sttThreads = int.tryParse(store.readSetting(sttThreadsSetting) ?? '');
  if (sttThreads == null) {
    sttThreads = sttThreadsFor(Platform.numberOfProcessors);
    store.writeSetting(sttThreadsSetting, '$sttThreads');
  }
  // Each run gets its own scratch folder (the decoded song while it is
  // separated): a window closed mid-run ends the process at once, and the
  // next start removes what such a run left (Codex review).
  final hearScratch = Directory(p.join(options.dataDir, 'hear-tmp'));
  HearWordsPaths hearPathsIn(String tempDir) => HearWordsPaths(
    separatorModel: bundleFile(
      modelsRoot,
      hearWordsBundle,
      'Kim_Vocal_2.onnx',
    ).path,
    silero: bundleFile(
      modelsRoot,
      hearWordsBundle,
      'silero_vad_scan.onnx',
    ).path,
    gigaamFolder: bundleFile(
      modelsRoot,
      hearWordsBundle,
      'gigaam/model.json',
    ).parent.path,
    mpv: p.join(appDir, 'libmpv-2.dll'),
    tempDir: tempDir,
    whisperBridge: p.join(appDir, 'ownsemble_whisper.dll'),
    whisperLibraries: bundleFile(
      modelsRoot,
      whisperBundle,
      'whisper.cpp/whisper.dll',
    ).parent.path,
    whisperModel: bundleFile(
      modelsRoot,
      whisperBundle,
      'ggml-large-v3-turbo-q5_0.bin',
    ).path,
    threads: sttThreads!,
    bundles:
        '${hearWordsBundle.folderName} ${whisperBundle.folderName}'
        '${hearOnGpuNow() ? ' ${hearGpuBundle.folderName}' : ''}',
    gpu: hearOnGpuNow(),
    gpuBackends: bundleFile(
      modelsRoot,
      hearGpuBundle,
      'vulkan/ggml-vulkan.dll',
    ).parent.path,
  );
  ModelBundle bundleOf(HearBundle bundle) => switch (bundle) {
    HearBundle.hearWords => hearWordsBundle,
    HearBundle.whisper => whisperBundle,
    HearBundle.gpu => hearGpuBundle,
  };
  final hearer = LyricsHearer(
    lyrics: lyrics,
    bundleReady: (bundle) => bundleReady(modelsRoot, bundleOf(bundle)),
    bundleMegabytes: (bundle) => bundleOf(bundle).megabytes,
    download: (bundle, onProgress, stop) => downloadBundle(
      bundleOf(bundle),
      modelsRoot,
      freeBytes: () => freeBytesAt(options.dataDir),
      workingBytes: sttWorkingBytes,
      onProgress: onProgress,
      stop: stop,
    ),
    audioOf: audioOf,
    start:
        ({
          required ref,
          required audioPath,
          required vocalsPath,
          required audioBytes,
          required beforeWhisper,
          required language,
        }) {
          final scratch = Directory(
            p.join(
              hearScratch.path,
              '${DateTime.now().millisecondsSinceEpoch}',
            ),
          )..createSync(recursive: true);
          final gpu = hearOnGpuNow();
          final onnx = p.join(appDir, 'onnxruntime.dll');
          final gpuOnnx = gpu
              ? bundleFile(
                  modelsRoot,
                  hearGpuBundle,
                  'directml/onnxruntime.dll',
                ).path
              : null;
          // One helper (or worker isolate) per run, ended after it.
          final JobRunner worker;
          final Future<void> Function() closeWorker;
          if (hearInHelper) {
            final helper = ProcessJobRunner(
              helperPath: hearHelperPath,
              onnxRuntimePath: onnx,
              gpuOnnxRuntimePath: gpuOnnx,
              log: logPerf,
            );
            worker = helper;
            closeWorker = helper.close;
          } else {
            final inApp = SttWorker(
              onnxRuntimePath: onnx,
              gpuOnnxRuntimePath: gpuOnnx,
              log: logPerf,
            );
            worker = inApp;
            closeWorker = inApp.close;
          }
          final run =
              HearWords(
                runner: worker,
                paths: hearPathsIn(scratch.path),
                save: (ref, heard) {
                  store.saveHeardLyrics(ref, heard);
                  lyrics.heardChanged(ref);
                },
                log: logPerf,
                beforeWhisper: beforeWhisper,
                onGpuFailed: () {
                  // CPU until the app restarts; a damaged GPU file is
                  // found and deleted, so the next start downloads it.
                  gpuFailed = true;
                  unawaited(
                    bundleIntact(
                      modelsRoot,
                      hearGpuBundle,
                    ).then<void>((_) {}, onError: (Object _) {}),
                  );
                },
              ).start(
                ref: ref,
                audioPath: audioPath,
                vocalsPath: vocalsPath,
                audioBytes: audioBytes,
                language: language,
              );
          unawaited(
            run.result.then<void>((_) {}, onError: (Object _) {}).whenComplete(
              () async {
                await closeWorker();
                try {
                  scratch.deleteSync(recursive: true);
                } on FileSystemException {
                  // Removed at the next start.
                }
              },
            ),
          );
          return run;
        },
    vocalsPathOf: (key) =>
        p.join(vocalsDir.path, '${fitCacheName(key)}.vocals16.f32'),
    forgetHeard: (ref) => store.saveHeardLyrics(ref, null),
    freeBytes: () => freeBytesAt(options.dataDir),
    bundleIntact: (bundle) => bundleIntact(modelsRoot, bundleOf(bundle)),
    useGpu: () => settings.hearOnGpu && !gpuFailed,
    languageOf: store.hearLanguageOf,
    saveLanguage: store.saveHearLanguage,
    // One heavy lyrics job at a time (Codex review): a fit or a fit check
    // keeps hearing from starting, and hearing keeps them.
    busyElsewhere: () => fitter.job == null
        ? null
        : 'A fit to the recording is running; hear the words after it.',
    log: logPerf,
  );
  fitter.busyElsewhere = () => hearer.job == null
      ? null
      : 'The words of a song are being heard; fit after it.';
  // What runs of an earlier start left: their scratch folders, and vocals
  // of runs stopped long ago and never tried again. Before any run can
  // start (no click before the first frame).
  try {
    if (hearScratch.existsSync()) hearScratch.deleteSync(recursive: true);
  } on FileSystemException {
    // Still held by something; tried again next start.
  }
  final removedVocals = removeOldVocals(vocalsDir, now: DateTime.now());
  if (removedVocals > 0) {
    logPerf('hear words: removed $removedVocals old vocals files');
  }
  artists.onListChanged = library.listChanged;
  library.artistSongsOf = artists.songsOf;
  library.vkLists = CombinedLists(
    playlists: playlists,
    others: forYou,
    artists: artists,
    isArtistList: isArtistListRef,
  );
  // Each sync run hands over a new outcome: the playlists are read then,
  // once per run. (`syncing` also blinks back on when the file check after
  // the sync ends, which asked VK twice per sync.)
  var lastOutcome = sync.lastOutcome;
  sync.addListener(() {
    final outcome = sync.lastOutcome;
    if (identical(outcome, lastOutcome)) return;
    lastOutcome = outcome;
    if (outcome != null) unawaited(playlists.refresh());
  });
  // VK Mix never ends: near the end of its songs the next ones are asked.
  player.currentStream.listen((track) async {
    if (track == null || !forYou.isMixList(playback.queue.context)) return;
    final list = playback.queue.context;
    if (list.indexWhere((t) => t.id == track.id) < list.length - 2) return;
    final more = await forYou.moreMix();
    playback.extendList(forYou.isMixList, more);
    library.listChanged(forYou.mixRef);
  });
  // Remove from library and its Undo (plan 06, C5).
  final remover = SongRemover(
    store: store,
    sources: sync.sourceList,
    apiOfSource: (sourceId) => clientOfSource(sourceId)?.call,
    onLibraryChanged: reloadLibrary,
    onRestored: () {
      if (sync.running) unawaited(sync.syncAfterRunning());
    },
    log: logPerf,
  );
  // A new login is synced at once, so the library fills without another
  // step: a new account alone and first, so it shows at once and its songs
  // soon after.
  var logins = account.logins;
  account.addListener(() {
    sync.runner = syncRunner();
    sync.checker = fileChecker();
    sync.keepNewAccounts({
      for (final session in account.sessions) ?session.account,
    });
    final login = account.lastLogin;
    final alone = login == null ? null : syncRunner(only: login);
    if (account.logins != logins) {
      unawaited(
        login != null && alone != null
            ? sync.addAccount(login, alone)
            : sync.syncAfterRunning(),
      );
    }
    logins = account.logins;
  });

  // Far below Flutter's 100 MB default: decoded covers are the app's largest
  // memory use, and a screen of rows needs about 20 of them.
  PaintingBinding.instance.imageCache
    ..maximumSize = maxDecodedCovers
    ..maximumSizeBytes = maxDecodedCoverBytes;
  // Name links and the Artists count need the index: built a moment after
  // the first frame, off the cold-start path (R12). A view of an artist
  // kept from the last run builds it when the list asks.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Timer(const Duration(milliseconds: 600), artists.warmUp);
  });
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
        aloneRunner: (id) => syncRunner(only: id),
        covers: covers,
        collections: collections,
        storage: storage,
        store: store,
        forYou: forYou,
        catalog: catalog,
        remover: remover,
        artists: artists,
        lyrics: lyrics,
        fitter: fitter,
        hearer: hearer,
        hearThreads: sttThreads!,
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
      sources: sourceEditor,
      collections: collections,
      catalog: catalog,
      remover: remover,
      forYou: forYou,
      playlists: playlists,
      artists: artists,
      lyrics: lyrics,
      lyricsFitter: fitter,
      lyricsHearer: hearer,
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
  required VkAccounts account,
  required SyncController sync,
  required SyncRunner? Function(String account) aloneRunner,
  required CoverStore covers,
  required CollectionsController collections,
  required AudioStorage storage,
  required LibraryStore store,
  required ForYou forYou,
  required CatalogSearch catalog,
  required SongRemover remover,
  required LibraryArtists artists,
  required LyricsController lyrics,
  required LyricsFitter fitter,
  required LyricsHearer hearer,
  required int hearThreads,
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
  // The library syncs itself on every start, in the background. A login
  // whose first sync never ended (the app closed during it) is still a new
  // account: it shows as one and syncs first.
  sync.keepNewAccounts({
    for (final session in account.sessions) ?session.account,
  });
  for (final session in account.sessions) {
    final id = session.account;
    final alone = id == null ? null : aloneRunner(id);
    if (id == null || alone == null) continue;
    if (sync.syncedSources.any((source) => source.account == id)) continue;
    unawaited(sync.addAccount(id, alone));
  }
  final startSync = sync.syncNow();
  // The sync's own part: the file check after it runs on in the background.
  final startSynced = sync.synced;
  _logPlayTimings(player, File(p.join(options.dataDir, 'perf.log')));
  await account.identify();

  // Not in the speed gate's runs, which keep their data unchanged.
  if (options.benchFile == null && options.cacheWhileStreaming) {
    unawaited(
      startSync.then(
        (_) => _checkStoredOnce(
          library: library,
          player: player,
          playback: playback,
          storage: storage,
          store: store,
          log: File(p.join(options.dataDir, 'perf.log')),
        ),
      ),
    );
  }

  if (options.benchFile != null) {
    // Measure the library as it is after the start sync, not while the
    // sync may swap it out.
    await startSynced;
    final result = await SpeedBench(
      library: library,
      player: player,
      playback: playback,
      vk: account.client,
      covers: covers,
      collections: collections,
      forYou: forYou,
      catalog: catalog,
      remover: remover,
      artists: artists,
      resultFile: options.benchFile,
      volume: options.benchVolume,
      lyrics: lyrics,
      fitter: fitter,
      fitKeys: options.benchFitKeys,
      hearer: hearer,
      hearKeys: options.benchHearKeys,
      hearThreads: hearThreads,
      editKeys: options.benchEditKeys,
      wordsKeys: options.benchWordsKeys,
    ).run(parts: options.benchParts);
    File(options.benchFile!)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    exit(0);
  }
}

/// Runs [StoredCheck] until it has judged every saved song once: removes
/// saved files that are not the song's own file (see stored_check.dart).
/// Runs after the start sync, so the accounts and the library are current.
Future<void> _checkStoredOnce({
  required LibraryController library,
  required PlayerService player,
  required PlaybackController playback,
  required AudioStorage storage,
  required LibraryStore store,
  required File log,
}) async {
  if (store.readSetting(storedCheckDoneSetting) != null) return;
  void write(String line) => log.writeAsStringSync(
    '${DateTime.now().toIso8601String()} $line\n',
    mode: FileMode.append,
  );
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final clock = Stopwatch()..start();
  try {
    final check = StoredCheck(
      songs: [
        for (final track in library.all)
          if (track.source == TrackSource.vk)
            if (storage.stateOf(track) case (path: _?, :final pinned))
              (track: track, pinned: pinned),
      ],
      savedBytes: (track) {
        final path = storage.stateOf(track).path;
        if (path == null) return null;
        final file = storage.fileAt(path);
        return file.existsSync() ? file.lengthSync() : null;
      },
      linksOf: (track) async {
        if (player.routesFor(track).isEmpty) {
          throw const NotNow('no logged-in account has the song');
        }
        final routed = await player.resolveStream(track);
        if (routed == null) return null;
        final route = routed.route;
        return (
          own: routed.stream.link,
          release: () => route.client.releaseLinkForCheck(
            route.sourceKey,
            route.accessKey,
          ),
        );
      },
      sizeOf: (link) => remoteAudioSize(link, http),
      remove: storage.removeStored,
      redownload: playback.download,
      // A song restored from the last run is not loaded: its file is free.
      isBusy: (track) =>
          (player.current?.id == track.id && !player.restoredOnly) ||
          storage.isSaving(track) ||
          storage.isDownloading(track),
      log: write,
    );
    final summary = await check.run();
    write(
      'stored check: $summary in ${clock.elapsed.inSeconds} s'
      '${summary.complete ? ', done' : ', runs again at the next start'}',
    );
    if (summary.complete) store.writeSetting(storedCheckDoneSetting, '1');
  } on Object catch (error) {
    write('stored check stopped: ${error.runtimeType}');
  } finally {
    http.close(force: true);
  }
}

/// Appends every play's timing, every proxied stream request's timing and
/// every streamed song not saved whole to perf.log (no titles, links or
/// tokens).
void _logPlayTimings(PlayerService player, File log) {
  player.proxyRequests.listen((request) {
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $request\n',
      mode: FileMode.append,
    );
  });
  player.lostSaves.listen((lost) {
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $lost\n',
      mode: FileMode.append,
    );
  });
  player.timings.listen((timing) {
    final kind = timing.cached ? 'cached' : 'stream';
    // Which account's session gave the link: a source id, never a name.
    final via = switch (timing.sourceId) {
      null => '',
      final source when timing.skippedAccounts == 0 => ', source $source',
      final source =>
        ', source $source after ${timing.skippedAccounts} other account(s)',
    };
    final skipped = timing.playlistLinks == 0
        ? ''
        : ', ${timing.playlistLinks} HLS links from VK';
    // Stage K: how long the file plays, and which version it is when VK
    // swapped the song's own file.
    final file = [
      if (timing.fileSeconds case final seconds?)
        ', file ${seconds.toStringAsFixed(1)} s',
      if (timing.version case final version?) ', version ${version.name}',
      if (timing.versionNews != null) ', own file found swapped',
    ].join();
    final line = timing.ok
        ? '$kind sound ${timing.toSoundMs} ms'
              '${timing.cached ? '' : ' (VK link ${timing.resolveMs} ms$skipped$via)'}'
              '$file'
        : '$kind failed after ${timing.toSoundMs} ms$skipped$via: ${timing.error}';
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
    this.sources,
    this.catalog,
    this.remover,
    this.forYou,
    this.playlists,
    this.artists,
    this.lyrics,
    this.lyricsFitter,
    this.lyricsHearer,
  });

  final CoverStore covers;
  final LibraryController library;
  final PlaybackController playback;
  final CollectionsController collections;
  final ShellSettings settings;
  final SyncController? sync;
  final VkAccounts? account;
  final SourceEditor? sources;
  final CatalogSearch? catalog;
  final SongRemover? remover;
  final ForYou? forYou;
  final VkPlaylists? playlists;
  final LibraryArtists? artists;
  final LyricsController? lyrics;
  final LyricsFitter? lyricsFitter;
  final LyricsHearer? lyricsHearer;

  @override
  Widget build(BuildContext context) {
    final app = CoverScope(
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
            sources: sources,
            collections: collections,
            catalog: catalog,
            remover: remover,
            forYou: forYou,
            playlists: playlists,
            artists: artists,
            lyrics: lyrics,
            lyricsFitter: lyricsFitter,
            lyricsHearer: lyricsHearer,
            settings: settings,
          ),
        ),
      ),
    );
    final syncing = sync;
    return syncing == null
        ? app
        : SourcesScope(sources: syncing.sourceList, child: app);
  }
}
