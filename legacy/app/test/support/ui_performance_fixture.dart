import 'dart:async';

import 'package:ownsemble/contracts/playback_engine.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';

import 'fixture_provider.dart';

/// Count synchronous catalog reads while exercising the real generated SQLite store.
class MeasuredLibraryStore extends LibraryStore {
  // Count point lookups independently of batch catalog reads.
  int trackReads = 0;
  // Count complete filtered-library queries.
  int rowReads = 0;
  // Count sidebar Pile reads.
  int pileReads = 0;
  // Count individual pin lookups on visible rows.
  int pinReads = 0;
  // Count aggregate catalog-size queries.
  int countReads = 0;
  // Count cover-key lookups independently of image decoding and network work.
  int artworkReads = 0;

  /// Use a generated directory, never the application's normal catalog.
  MeasuredLibraryStore(super.directory);

  /// Read one generated recording through the production query.
  @override
  Track? track(String id) {
    trackReads++;
    return super.track(id);
  }

  /// Read filtered rows through the production join and ordering.
  @override
  List<LibraryRow> rows({
    String view = 'library',
    String query = '',
    int? pile,
  }) {
    rowReads++;
    return super.rows(view: view, query: query, pile: pile);
  }

  /// Read Piles through the production store.
  @override
  List<Pile> piles() {
    pileReads++;
    return super.piles();
  }

  /// Count reads that used to occur twice per visible song per rebuild.
  @override
  bool individuallyPinned(String id) {
    pinReads++;
    return super.individuallyPinned(id);
  }

  /// Observe artwork metadata reads without requesting or decoding any image.
  @override
  String? artworkKey(String id) {
    artworkReads++;
    return super.artworkKey(id);
  }

  /// Count the header's aggregate reads.
  @override
  int get count {
    countReads++;
    return super.count;
  }

  /// Start a measurement after initial catalog loading and layout have settled.
  void resetReads() {
    trackReads = rowReads = pileReads = pinReads = countReads = artworkReads =
        0;
  }

  /// Export only generated operation counts, without metadata or identifiers.
  Map<String, int> get reads => {
    'tracks': trackReads,
    'rows': rowReads,
    'piles': pileReads,
    'pins': pinReads,
    'count': countReads,
    'artwork': artworkReads,
  };
}

/// Supply deterministic clock events without loading media or opening an audio device.
class UiBenchmarkPlayback implements PlaybackEngine {
  // Emit only generated position updates to the real controller listener.
  final positions = StreamController<Duration>.broadcast(sync: true);
  // Retain the generated clock value for rendering.
  Duration position = Duration.zero;
  // Keep every fixture silent, including accidental volume changes.
  double volume = 0;

  /// Return a stable three-minute generated recording.
  @override
  PlaybackState get state => PlaybackState(
    position: position,
    duration: const Duration(minutes: 3),
    volume: volume,
  );

  /// Expose no media, network or error events.
  @override
  PlaybackEvents get stream => PlaybackEvents(
    playing: const Stream.empty(),
    buffering: const Stream.empty(),
    completed: const Stream.empty(),
    position: positions.stream,
    error: const Stream.empty(),
    log: const Stream.empty(),
  );

  /// Advance a rendered clock without starting playback.
  void advance(int seconds) {
    position = Duration(seconds: seconds);
    positions.add(position);
  }

  /// Reject file access so benchmarks cannot accidentally use real media.
  @override
  Future<void> openLocal(String path, {bool play = true}) async =>
      throw StateError('Generated UI benchmark cannot open media');

  /// Reject network access rather than timing external services.
  @override
  Future<void> openStream(Uri uri, {bool play = true}) async =>
      throw StateError('Generated UI benchmark cannot open a stream');

  /// Keep play silent and deterministic.
  @override
  Future<void> play() async {}

  /// Keep pause independent of a native backend.
  @override
  Future<void> pause() async {}

  /// Stop only the generated clock.
  @override
  Future<void> stop() async => position = Duration.zero;

  /// Seek only the generated clock.
  @override
  Future<void> seek(Duration target) async => position = target;

  /// Retain the controller's volume intent without an output device.
  @override
  Future<void> setVolume(double value) async => volume = value;

  /// Report that the fixture never plays sound.
  @override
  Future<bool> isPaused() async => true;

  /// Return the deterministic clock for controller cleanup.
  @override
  Future<double?> clockSeconds() async => position.inMilliseconds / 1000;

  /// Release only the generated event stream.
  @override
  Future<void> dispose() => positions.close();
}

/// Exercise real controller reads while recording queue selection without playing sound.
class UiPerformanceController extends AppController {
  // Count deliberate row/queue playback requests without playing media.
  int playRequests = 0;
  // Retain the selected generated occurrence for queue-action regression checks.
  int? selectedOccurrence;
  // Count explicit requests to inspect optional metadata.
  int metadataRequests = 0;

  /// Keep all persistence in a generated store and disable provider access.
  UiPerformanceController(super.store, UiBenchmarkPlayback playback)
    : super(
        demo: true,
        playbackPlayer: playback,
        musicProvider: FixtureProvider(),
        decodeAudio: (_) async => 180,
        diagnosticStore: DiagnosticStore.memory(),
      ) {
    offline = true;
  }

  /// Verify the chosen queue occurrence without opening a decoder or changing history.
  @override
  Future<void> playCurrent({bool diagnostic = false}) async {
    playRequests++;
    selectedOccurrence = queue.current?.occurrence;
  }

  /// Observe explicit details actions without performing optional network work.
  @override
  Future<void> enrichTrack(String id, {bool force = false}) async {
    metadataRequests++;
  }
}

/// Populate a large catalog entirely from generated recording identities and text.
void seedUiPerformanceLibrary(MeasuredLibraryStore store, int count) {
  store.merge(
    List.generate(
      count,
      (index) => Track(
        '900000000000002_${index + 1}',
        'Generated song $index',
        'Generated artist ${index % 20}',
        180,
      ),
    ),
  );
  store.setSetting('volume', 0);
}
