import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/library_listing_scanner.dart';

/// Build generated recordings whose identities remain stable across page boundaries.
List<Track> recordings(int start, int count) => List.generate(
  count,
  (index) => Track('17_${start + index}', 'Generated', 'Fixture', 60),
);

/// Exercise bounded listing scans without a browser or a real account.
void main() {
  test('unchanged head reads one page, not all 2630 recordings', () async {
    // Record only requested offsets from the generated listing.
    final offsets = <int>[];
    // Keep the familiar checkpoint independent of page size.
    final checkpoint = recordings(1, 128).map((track) => track.id).toList();
    // Run the production scanner on a generated one-hundred-record page.
    final result = await LibraryListingScanner(
      state: LibraryListingState(),
      newestOnly: true,
      checkpoint: checkpoint,
      read: (offset) async {
        offsets.add(offset);
        return LibraryListingPage(recordings(1, 100), offset, 100, 2630, true);
      },
      merge: (_) {},
      cancelled: () => false,
      elapsed: () => Duration.zero,
    ).run();
    expect(result.reason, 'known_head');
    expect(offsets, [0]);
    expect(result.count, 12);
    // Keep the validated page head for resilient future overlap after removals/reorders.
    expect(result.head.length, 100);
  });

  test('300 newly added recordings are merged before the saved head', () async {
    // Put a prefix larger than the old 256-row limit ahead of a familiar block.
    final listing = [...recordings(5000, 300), ...recordings(1, 2330)];
    // Retain generated merge results for identity assertions.
    final merged = <Track>[];
    // Capture page requests to prove a bounded head check.
    final offsets = <int>[];
    // Run with one-hundred-row provider pages.
    final result = await LibraryListingScanner(
      state: LibraryListingState(),
      newestOnly: true,
      checkpoint: recordings(1, 128).map((track) => track.id).toList(),
      read: (offset) async {
        offsets.add(offset);
        return LibraryListingPage(
          listing.sublist(offset, offset + 100),
          offset,
          offset + 100,
          listing.length,
          true,
        );
      },
      merge: merged.addAll,
      cancelled: () => false,
      elapsed: () => Duration.zero,
    ).run();
    expect(result.reason, 'known_head');
    expect(offsets, [0, 100, 200, 300]);
    expect(
      merged.take(300).map((track) => track.id),
      recordings(5000, 300).map((track) => track.id),
    );
    expect(result.head.length, 128);
    expect(result.count, 312);
  });

  test(
    'full import ends only after unique pages match a stable total',
    () async {
      // Keep a large listing split across the observed provider page boundary.
      final listing = recordings(1, 2630);
      // Capture all safely merged recordings.
      final merged = <Track>[];
      // Read exactly two pages without DOM scrolling.
      final result = await LibraryListingScanner(
        state: LibraryListingState(),
        read: (offset) async => LibraryListingPage(
          listing.sublist(offset, offset == 0 ? 2000 : 2630),
          offset,
          offset == 0 ? 2000 : 2630,
          2630,
          offset == 0,
        ),
        merge: merged.addAll,
        cancelled: () => false,
        elapsed: () => Duration.zero,
      ).run();
      expect(result.reason, 'provider_end');
      expect(result.count, 2630);
      expect(result.continueSweep, isFalse);
      expect(merged.length, 2630);
    },
  );

  test('overlapping pages and changed totals preserve partial rows without claiming completion', () async {
    // Exercise provider mutation and duplicated boundary records independently.
    for (final changedTotal in [false, true]) {
      // Keep already merged rows when a later page invalidates the listing witness.
      final merged = <Track>[];
      // Reject the second page before it can overwrite good saved music.
      final result = await LibraryListingScanner(
        state: LibraryListingState(),
        read: (offset) async => offset == 0
            ? LibraryListingPage(recordings(1, 2), 0, 2, 3, true)
            : LibraryListingPage(
                recordings(changedTotal ? 3 : 2, 1),
                2,
                3,
                changedTotal ? 4 : 3,
                changedTotal,
              ),
        merge: merged.addAll,
        cancelled: () => false,
        elapsed: () => Duration.zero,
      ).run();
      expect(result.reason, 'listing_changed');
      expect(result.continueSweep, isFalse);
      expect(merged.length, 2);
    }
  });

  test(
    'yielded full scan resumes its cursor and original head in the next slice',
    () async {
      // Keep continuation state solely inside the provider, with no account export.
      final state = LibraryListingState();
      // Yield immediately after the first generated page was merged.
      var yielded = false;
      // Share a generated reader across the two bounded slices.
      Future<LibraryListingPage> read(int offset) async => LibraryListingPage(
        recordings(offset + 1, offset == 0 ? 2 : 1),
        offset,
        offset == 0 ? 2 : 3,
        3,
        offset == 0,
      );
      // Stop safely before requesting the continuation.
      final first = await LibraryListingScanner(
        state: state,
        read: read,
        merge: (_) => yielded = true,
        cancelled: () => yielded,
        elapsed: () => Duration.zero,
      ).run();
      expect(first.reason, 'yielded');
      expect(first.continueSweep, isTrue);
      // Resume the same verified prefix instead of forgetting its coverage witness.
      final second = await LibraryListingScanner(
        state: state,
        read: read,
        merge: (_) {},
        cancelled: () => false,
        elapsed: () => Duration.zero,
      ).run();
      expect(second.reason, 'provider_end');
      expect(second.count, 3);
      expect(second.head, ['17_1', '17_2', '17_3']);
    },
  );

  test('empty library requires an explicit zero-total end', () async {
    // Accept an empty personal listing without deleting any historical local rows.
    final result = await LibraryListingScanner(
      state: LibraryListingState(),
      read: (_) async => const LibraryListingPage([], 0, 0, 0, false),
      merge: (_) => fail('No empty merge is needed'),
      cancelled: () => false,
      elapsed: () => Duration.zero,
    ).run();
    expect(result.reason, 'provider_end');
    expect(result.count, 0);
  });
}
