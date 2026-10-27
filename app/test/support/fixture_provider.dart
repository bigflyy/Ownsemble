import 'package:ownsemble/contracts/music_provider.dart';
import 'package:ownsemble/media/audio_policy.dart';

/// Explicit offline double. Tests needing VK policy inject a generated browser.
class FixtureProvider implements MusicProvider {
  @override
  bool connected = false;
  @override
  bool get privateSignInActive => false;
  @override
  Future<void> finishPrivateSignIn() async {}
  @override
  Future<void> connect() async =>
      throw const ProofFailure('fixture_network_disabled');
  @override
  Future<void> signInPrivately() => connect();
  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<void> cancelResolution() async {}
  @override
  Future<void> cancelSync() async {}
  @override
  Map<String, dynamic> observedMetadata(String id) => {};
  @override
  Uri? artworkSource(String id) => null;
  @override
  String musicAgeBucket(String id) => 'unknown';
  @override
  int? libraryPosition(String id) => null;
  @override
  bool? trackUnavailable(String id) => null;
  @override
  String? musicReference(String id) => null;
  @override
  Future<SyncResult> sync(
    void Function(List<Track>) merge, {
    required bool fromTop,
    bool newestOnly = false,
    List<String> checkpoint = const [],
  }) async => throw const ProofFailure('fixture_network_disabled');
  @override
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  }) async => throw const ProofFailure('fixture_network_disabled');
  @override
  Future<Map<String, dynamic>> inspectMetadata(
    Track track, {
    bool force = false,
    bool includeLyrics = true,
    bool Function()? cancelled,
  }) async => {};
}
