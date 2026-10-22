import '../media/audio_policy.dart';

/// A cached manifest is usable only when it names an exact segment witnessed
/// after the requested row's capture boundary. Paths/hosts are never guessed.
class CachedSourceWitness {
  final Future<Set<Uri>> Function(Uri) segments;
  final _plans = <Uri, Future<Set<Uri>>>{};
  CachedSourceWitness(this.segments);

  Future<Set<Uri>> match(Iterable<Uri> cached, Set<Uri> witnessed) async {
    if (witnessed.isEmpty) return {};
    final candidates = cached
        .where(
          (u) => audioCandidate(u) && u.path.toLowerCase().endsWith('.m3u8'),
        )
        .toSet();
    if (candidates.length > 8) throw const ProofFailure('audio_witness_budget');
    final matches = await Future.wait(
      candidates.map((uri) async {
        final plan = await _plans.putIfAbsent(uri, () async {
          try {
            return await segments(uri).timeout(const Duration(seconds: 5));
          } catch (_) {
            return <Uri>{};
          }
        });
        return plan.any(witnessed.contains) ? uri : null;
      }),
    );
    return matches.whereType<Uri>().toSet();
  }
}

/// Resolve master playlists with the same highest-bandwidth selection and depth
/// bound used by playback/cache. Every fetch retains the media destination guard.
Future<Set<Uri>> loadManifestSegments(
  Uri source,
  Future<String> Function(Uri) load,
) async {
  var uri = source;
  for (var depth = 0; depth < 4; depth++) {
    if (!allowedAudio(uri)) {
      throw const ProofFailure('audio_destination_rejected');
    }
    final plan = parseHls(await load(uri), uri);
    if (plan.variant == null) {
      return plan.lines
          .where((line) => line.resourceKind == 'segment')
          .map((line) => line.resource!)
          .toSet();
    }
    uri = plan.variant!;
  }
  throw const ProofFailure('hls_master_depth');
}
