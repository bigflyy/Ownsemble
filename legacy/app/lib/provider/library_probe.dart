import 'dart:async';

import '../media/audio_policy.dart';
import 'pagination_diagnostics.dart';

/// Run optional library diagnostics with a deadline and fixed failure counters.
Future<void> runLibraryProbe({
  required Future<Map<String, dynamic>> Function() read,
  required void Function(Map<String, int>) report,
  Duration deadline = const Duration(seconds: 21),
}) async {
  try {
    // Bound the browser operation independently of its network deadline.
    final result = await read().timeout(deadline);
    report(paginationCounts(result['counts']));
  } on TimeoutException {
    // Report a stalled probe instead of silently losing the diagnostic outcome.
    report({'libraryProbeTimeout': 1});
  } on ProofFailure catch (error) {
    // Preserve access revocation and cancellation without emitting page details.
    if ([
      'cancelled',
      'private_signin_required',
      'private_signin_in_progress',
    ].contains(error.category)) {
      rethrow;
    }
    report({'libraryProbeScriptFailed': 1});
  } catch (_) {
    // Replace arbitrary native exception text with a fixed numeric category.
    report({'libraryProbeScriptFailed': 1});
  }
}
