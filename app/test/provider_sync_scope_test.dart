// Keep canonical contract types shared with the standalone generated browser fixture.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/contracts/music_browser.dart';
import '../lib/media/audio_policy.dart';
import '../lib/provider/vk_provider.dart';
import '../tool/fixtures/generated_browser.dart';

/// Expose generated music rows while recording only the reader's fixed options.
class LibraryScopeFactory extends GeneratedBrowserFactory {
  // Capture the import options without creating any real account or native browser.
  final readOptions = <Map<String, dynamic>>[];
  // Enable the generated personal-list endpoint independently of unverified DOM membership.
  bool listingSupported = false;
  // Simulate a generated transport failure after one accepted page.
  int? failOffset;
  // Record only fixed cursors requested by the provider.
  final offsets = <int>[];

  /// Construct the same independent generated browser for scanner and standby pages.
  @override
  MusicBrowser create(BrowserEvents events) {
    // Retain generated pages for the fixture's ordinary cleanup ownership.
    final page = LibraryScopeBrowser(this, events);
    pages.add(page);
    return page;
  }
}

/// Implement only fixed adapter operations required by one incremental head check.
class LibraryScopeBrowser extends GeneratedBrowser {
  /// Reuse generated navigation and native privacy capability behavior.
  LibraryScopeBrowser(super.factory, super.events);

  /// Return synthetic adapter results without running JavaScript or native IO.
  @override
  Future<dynamic> evaluate(String expression) async {
    // Serve the generated personal listing only through its fixed adapter action.
    if (expression.contains('"read-library-page"')) {
      // Share generated policy configuration across independent browser pages.
      final config = factory as LibraryScopeFactory;
      // Exercise fail-closed behavior when the provider listing is unsupported.
      if (!config.listingSupported) return jsonEncode({'supported': false});
      // Decode only the fixed action options emitted by the provider.
      final options = jsonDecode(
        expression.substring(
          expression.indexOf('{"waitMs"'),
          expression.lastIndexOf('}') + 1,
        ),
      ) as Map<String, dynamic>;
      // Capture the bounded pagination cursor instead of executing JavaScript.
      final offset = options['libraryOffset'] as int;
      config.offsets.add(offset);
      // Stop a full listing after the configured page without native IO.
      if (config.failOffset == offset) {
        throw const ProofFailure('music_page_timeout');
      }
      // Put three hundred genuinely new recordings before the familiar checkpoint.
      final identities = [
        ...List.generate(300, (index) => 5000 + index),
        ...List.generate(2330, (index) => index + 1),
      ];
      return jsonEncode({
        'supported': true,
        'userId': 17,
        'userAgent': 'Generated',
        'musicReferences': identities
            .sublist(offset, offset + 100)
            .map(
              (id) => {
                'id': '17_$id',
                'musicKey': 'r1_generated_action_generated_url',
              },
            )
            .toList(),
        'tracks': identities
            .sublist(offset, offset + 100)
            .map(
              (id) => {
                'id': '17_$id',
                'title': 'Generated',
                'artist': 'Fixture',
                'duration': 60,
                'url': '',
              },
            )
            .toList(),
        'pagination': {
          'offset': offset,
          'nextOffset': offset + 100,
          'total': 2630,
          'hasMore': true,
        },
      });
    }
    // Capture exactly the JSON options sent to the guarded reader.
    if (expression.contains('window.ownsembleMusic.read(')) {
      // Locate the fixed reader argument in this generated expression.
      final start =
          expression.indexOf('window.ownsembleMusic.read(') +
          'window.ownsembleMusic.read('.length;
      // Bound decoding to the options object rather than interpreting JavaScript.
      final options = jsonDecode(
        expression.substring(start, expression.lastIndexOf('}') + 1),
      ) as Map<String, dynamic>;
      (factory as LibraryScopeFactory).readOptions.add(options);
      return jsonEncode({
        'userId': 17,
        'userAgent': 'Generated',
        'tracks': List.generate(
          12,
          (index) => {
            'id': '17_${index + 1}',
            'title': 'Generated',
            'artist': 'Fixture',
            'duration': 60,
            'url': '',
          },
        ),
      });
    }
    // Accept only the personal-music witness required before extraction.
    if (expression.contains('"verify-my-music"') ||
        expression.contains('"open-my-music"')) {
      return jsonEncode({'personal': true});
    }
    // Expose enough rendered rows to finish standby preparation without extraction.
    if (expression.contains('"readiness"')) {
      return jsonEncode({'count': 12, 'loading': false});
    }
    return jsonEncode(<String, Object>{});
  }
}

/// Verify that synchronization trusts only the personal listing and scoped continuation state.
void main() {
  test('actual provider imports a large new prefix from the personal listing instead of stale DOM rows', () async {
    // Expose a supported endpoint while keeping the DOM at the old saved head.
    final factory = LibraryScopeFactory()..listingSupported = true;
    // Retain only generated recordings merged by the actual provider policy.
    final merged = <Track>[];
    // Verify numeric page diagnostics without exposing music content.
    final events = <Map<String, dynamic>>[];
    // Inject the same production provider contracts used on Windows and Linux.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
      diagnostic: events.add,
    );
    try {
      await provider.connect();
      // A familiar DOM head must not hide three hundred new provider entries.
      final result = await provider.sync(
        merged.addAll,
        fromTop: true,
        newestOnly: true,
        checkpoint: List.generate(128, (index) => '17_${index + 1}'),
      );
      expect(result.reason, 'known_head');
      expect(
        merged
            .where((track) => int.parse(track.id.split('_').last) >= 5000)
            .length,
        300,
      );
      expect(factory.offsets, [0, 100, 200, 300]);
      expect(factory.readOptions, isEmpty);
      // Retain references from non-rendered listing pages before the controller persists them.
      expect(
        provider.musicReference('17_5299'),
        'r1_generated_action_generated_url',
      );
      expect(
        events
            .where((event) => event['stage'] == 'library_listing_page')
            .length,
        4,
      );
    } finally {
      await provider.disconnect();
    }
  });

  test('reconnection discards an interrupted listing cursor before a continuation request', () async {
    // Fail after one accepted page to retain a partial witness in the same provider object.
    final factory = LibraryScopeFactory()
      ..listingSupported = true
      ..failOffset = 100;
    // Keep real provider lifecycle policy under generated browser contracts.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      await expectLater(
        provider.sync((_) {}, fromTop: true),
        throwsA(isA<ProofFailure>()),
      );
      expect(factory.offsets, [0, 100]);
      await provider.disconnect();
      await provider.connect();
      factory.offsets.clear();
      // A controller's stale continuation flag cannot reuse a witness from the old session.
      await expectLater(
        provider.sync((_) {}, fromTop: false),
        throwsA(isA<ProofFailure>()),
      );
      expect(factory.offsets, [0, 100]);
    } finally {
      await provider.disconnect();
    }
  });

  test('unsupported personal listing stays partial without importing unverified DOM membership', () async {
    // Keep generated rendered rows available, but reject the provider listing contract.
    final factory = LibraryScopeFactory();
    // Record merges to prove that rendered lookalikes never become personal membership.
    final merged = <Track>[];
    // Exercise the actual guarded provider rather than a sync stub.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      // Preserve saved data when VK changes its listing response instead of guessing membership.
      final result = await provider.sync(
        merged.addAll,
        fromTop: true,
        newestOnly: true,
        checkpoint: List.generate(12, (index) => '17_${index + 1}'),
      );
      expect(result.reason, 'listing_unsupported');
      expect(result.continueSweep, isFalse);
      expect(merged, isEmpty);
      expect(factory.readOptions, isEmpty);
    } finally {
      await provider.disconnect();
    }
  });
}
