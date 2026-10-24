import '../media/audio_policy.dart';
import 'library_scanner.dart';

/// Carry only validated music entries and explicit provider pagination.
class LibraryListingPage {
  // Keep basic recording data independent of playback source resolution.
  final List<Track> tracks;
  // Preserve the requested offset and explicit continuation cursor.
  final int offset, nextOffset;
  // Retain the stable advertised membership count for this enumeration.
  final int total;
  // Require an explicit provider end instead of inferring it from quiet scrolling.
  final bool hasMore;

  /// Construct one already projected page from the guarded music adapter.
  const LibraryListingPage(
    this.tracks,
    this.offset,
    this.nextOffset,
    this.total,
    this.hasMore,
  );
}

/// Retain a verified prefix across bounded full-import slices in the same session.
class LibraryListingState {
  // Deduplicate exact identities and preserve the original provider ordering.
  final identities = <String>{};
  // Resume only the next validated contiguous offset.
  int offset = 0;
  // Reject provider mutations across pages instead of declaring false completion.
  int? total;
}

/// Read the personal listing with bounded work and no catalog deletions.
class LibraryListingScanner {
  // Share a full scan's coverage witness across resumable slices.
  final LibraryListingState state;
  // Fetch only the next app-owned cursor, returning null for an unsupported shape.
  final Future<LibraryListingPage?> Function(int offset) read;
  // Merge validated partial progress without replacing the catalog.
  final void Function(List<Track>) merge;
  // Yield promptly to playback, disposal or private sign-in.
  final bool Function() cancelled;
  // Enforce a monotonic slice deadline supplied by the host.
  final Duration Function() elapsed;
  // Limit ordinary checks to a prefix ending at a familiar consecutive block.
  final bool newestOnly;
  // Keep the last verified newest-first sequence independent of the local catalog.
  final List<String> checkpoint;

  /// Inject transport, cancellation and persistence without native dependencies.
  LibraryListingScanner({
    required this.state,
    required this.read,
    required this.merge,
    required this.cancelled,
    required this.elapsed,
    this.newestOnly = false,
    this.checkpoint = const [],
  });

  /// Enumerate validated pages until a checkpoint, explicit end or bounded yield.
  Future<ScanOutcome> run() async {
    // Retain a validated page prefix even when overlap stops merging after twelve rows.
    final head = state.identities.take(128).toList();
    // Preserve the original head when a full scan finishes in a later slice.
    ScanOutcome finish(bool more, String reason) =>
        ScanOutcome(state.identities.length, more, reason, head: List.of(head));
    // Bound head polling separately from initial/manual full discovery.
    final limit = Duration(seconds: newestOnly ? 15 : 90);
    // Require adjacent positions in both the observed and saved sequences.
    final positions = {
      for (var index = 0; index < checkpoint.length; index++)
        checkpoint[index]: index,
    };
    // Permit a verified small library to use its shorter checkpoint.
    final requiredRun = checkpoint.length < 12 ? checkpoint.length : 12;
    // Carry checkpoint overlap across provider page boundaries.
    var previous = -2, run = 0;
    // Bound requests even when a provider returns many tiny pages.
    for (var pageIndex = 0; pageIndex < (newestOnly ? 8 : 32); pageIndex++) {
      // Preserve a resumable full prefix when playback needs the browser.
      if (cancelled()) return finish(!newestOnly, 'yielded');
      // End this slice before issuing another request after its deadline.
      if (elapsed() >= limit) return finish(!newestOnly, 'time_budget');
      // Read only the next validated contiguous page.
      final page = await read(state.offset);
      // Preserve partial progress when the provider shape no longer matches.
      if (page == null) return finish(false, 'listing_unsupported');
      // Recheck cancellation before persisting a response from a revoked context.
      if (cancelled()) return finish(!newestOnly, 'yielded');
      // Reject changed totals, repeated cursors, gaps and contradictory end markers.
      if (page.offset != state.offset ||
          page.total < 0 ||
          page.total > 50000 ||
          (state.total != null && state.total != page.total) ||
          page.nextOffset != page.offset + page.tracks.length ||
          page.nextOffset > page.total ||
          page.hasMore != (page.nextOffset < page.total) ||
          (page.hasMore && page.tracks.isEmpty)) {
        return finish(false, 'listing_changed');
      }
      // Validate the whole page's identity sequence before merging its first row.
      final pageIds = page.tracks.map((track) => track.id).toSet();
      // Never turn overlapping or malformed pages into complete coverage.
      if (pageIds.length != page.tracks.length ||
          pageIds.any(
            (id) =>
                !RegExp(r'^-?\d+_\d+$').hasMatch(id) ||
                state.identities.contains(id),
          )) {
        return finish(false, 'listing_changed');
      }
      state.total = page.total;
      // Keep up to 128 observed identities without requesting another page just for a checkpoint.
      for (final track in page.tracks) {
        // The entire page was validated above, so its remaining prefix is safe to remember.
        if (head.length >= 128) break;
        head.add(track.id);
      }
      // Stop merging at the exact familiar block rather than importing a fetched tail.
      final accepted = <Track>[];
      // Retain the reason for ending a bounded head page early.
      String? headReason;
      // Process recording identities independently of their display order in the UI.
      for (final track in page.tracks) {
        state.identities.add(track.id);
        accepted.add(track);
        // Bound normal polling even when no saved checkpoint remains in the source.
        if (newestOnly) {
          // Match consecutive saved positions across both page boundaries.
          final position = positions[track.id];
          run = position != null ? (position == previous + 1 ? run + 1 : 1) : 0;
          previous = position ?? -2;
          // End at an existing verified block without scanning the full library.
          if (requiredRun > 0 && run >= requiredRun) {
            headReason = 'known_head';
            break;
          }
          // Seed a bounded checkpoint for older catalogs that have no saved sequence.
          if (checkpoint.isEmpty && state.identities.length >= 128) {
            headReason = 'head_seeded';
            break;
          }
          // Keep an unresolved burst partial and preserve its previous checkpoint.
          if (state.identities.length >= 4096) {
            headReason = 'head_budget';
            break;
          }
        }
      }
      // Commit validated progress without rewriting or removing existing saved rows.
      if (accepted.isNotEmpty) merge(accepted);
      // A matched prefix is sufficient for polling but says nothing about total coverage.
      if (headReason != null) return finish(false, headReason);
      state.offset = page.nextOffset;
      // Require unique cardinality and the explicit end before marking complete coverage.
      if (!page.hasMore) {
        return finish(
          false,
          state.identities.length == page.total
              ? 'provider_end'
              : 'listing_changed',
        );
      }
    }
    return finish(!newestOnly, 'page_budget');
  }
}
