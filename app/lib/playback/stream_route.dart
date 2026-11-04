import 'dart:async';

import '../library/track.dart';
import '../vk/vk_client.dart';

/// The logged-in client of the account behind source [sourceId], or null
/// when that account has no session (logged out, or not a VK source).
typedef StreamAccounts = VkClient? Function(int sourceId);

/// One way to stream a song: an account that has it, with that account's own
/// key for it. A song merged from several accounts has one route per account.
class StreamRoute {
  const StreamRoute({
    required this.sourceId,
    required this.client,
    required this.sourceKey,
    this.accessKey,
  });

  /// The account's source, for perf.log (an id, never a name).
  final int sourceId;

  /// Talks to VK as that account.
  final VkClient client;

  /// The song's VK key in that account, "ownerId_audioId".
  final String sourceKey;
  final String? accessKey;
}

/// The accounts to ask for a link to [track], best first.
///
/// Copies an account still has come first, the listed row's own before the
/// others; copies an account lost come last, since VK sometimes still serves
/// them. An account with no session is skipped: asking VK as another account
/// for this account's key is what E3 removed (VK gives each account its own
/// copy, and the key belongs to that copy).
List<StreamRoute> streamRoutes(Track track, StreamAccounts accounts) {
  if (track.source != TrackSource.vk) return const [];
  final copies = track.allCopies;
  final ordered = [
    ...copies.where((copy) => copy.goneAtMs == null),
    ...copies.where((copy) => copy.goneAtMs != null),
  ];
  return [
    for (final copy in ordered)
      if (copy.sourceKey case final key?)
        if (accounts(copy.sourceId) case final client?)
          StreamRoute(
            sourceId: copy.sourceId,
            client: client,
            sourceKey: key,
            accessKey: copy.accessKey,
          ),
  ];
}

/// VK's answer for a song, and the account that gave it.
class RoutedStream {
  const RoutedStream(this.route, this.stream, {this.skipped = 0});

  /// The account whose client gave [stream].
  final StreamRoute route;
  final VkStream stream;

  /// Accounts asked before [route] that gave no link or refused.
  final int skipped;
}

/// Asks each of [routes] in turn for a link, until one gives one.
///
/// An account that gives no link, or that VK refuses (an expired session, no
/// access), hands over to the next. A dead line or an overloaded VK
/// (timeouts, transient errors) stops at once: every other account would
/// wait just as long for the same answer.
///
/// Returns null when there is no route. When no account gives a link, the
/// first account's answer comes back (its link is null, and it says why);
/// when every account was refused, the first refusal is thrown.
Future<RoutedStream?> resolveRouted(List<StreamRoute> routes) async {
  RoutedStream? noLink;
  VkException? refusal;
  StackTrace? refusalTrace;
  var skipped = 0;
  for (final route in routes) {
    try {
      final stream = await route.client.resolveStream(
        route.sourceKey,
        route.accessKey,
      );
      if (stream.link != null) {
        return RoutedStream(route, stream, skipped: skipped);
      }
      noLink ??= RoutedStream(route, stream, skipped: skipped);
    } on VkException catch (error, trace) {
      if (error.transient) rethrow;
      if (refusal == null) {
        refusal = error;
        refusalTrace = trace;
      }
    }
    skipped++;
  }
  if (noLink != null) return noLink;
  if (refusal != null) Error.throwWithStackTrace(refusal, refusalTrace!);
  return null;
}
