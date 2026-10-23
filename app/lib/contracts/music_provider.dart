import '../media/audio_policy.dart';

class ResolvedAudio {
  final Uri source;
  final String userAgent;
  final Map<String, Object> timings;
  final String? recordingId;
  final String evidence;
  const ResolvedAudio(
    this.source,
    this.userAgent, {
    this.timings = const {},
    this.recordingId,
    this.evidence = 'unverified',
  });
  void requireTrack(Track track) {
    if (recordingId != track.id ||
        !recordingEvidenceKinds.contains(evidence) ||
        !audioCandidate(source)) {
      throw const ProofFailure('audio_identity_mismatch');
    }
  }
}

class SyncResult {
  final int discovered;
  final bool continueSweep;
  final String reason;
  final List<String> head;
  const SyncResult(
    this.discovered,
    this.continueSweep, {
    this.reason = 'quiet_boundary',
    this.head = const [],
  });
}

/// Optional read-only diagnostics, separate from importing or resolving music.
abstract interface class LibraryMembershipDiagnostics {
  /// Emit sanitized membership counters through the provider's diagnostic observer.
  Future<void> inspectLibraryMembership();
}

/// Application-facing music operations; implementations own provider policy.
/// References and optional fields are opaque provider data, never credentials.
abstract interface class MusicProvider {
  bool get connected;
  bool get privateSignInActive;
  Future<void> connect();
  Future<void> signInPrivately();

  /// Only an explicit application action may resume background work.
  Future<void> finishPrivateSignIn();
  Future<void> disconnect();
  Future<void> cancelResolution();
  Map<String, dynamic> observedMetadata(String id);
  Uri? artworkSource(String id);
  String musicAgeBucket(String id);
  int? libraryPosition(String id);
  bool? trackUnavailable(String id);
  String? musicReference(String id);
  Future<SyncResult> sync(
    void Function(List<Track>) merge, {
    required bool fromTop,
    bool newestOnly = false,
    List<String> checkpoint = const [],
  });
  Future<ResolvedAudio> resolve(
    Track track, {
    String? musicKey,
    bool Function()? cancelled,
    void Function(Uri, String)? prepareCandidate,
    Future<Set<Uri>> Function(Uri, String)? manifestSegments,
  });
  Future<Map<String, dynamic>> inspectMetadata(
    Track track, {
    bool force = false,
    bool includeLyrics = true,
    bool Function()? cancelled,
  });
}
