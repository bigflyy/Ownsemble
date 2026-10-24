// Generated browser contracts also use relative imports for standalone probes.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/contracts/music_browser.dart';
import '../lib/media/audio_policy.dart';
import '../lib/provider/vk_provider.dart';

import '../tool/fixtures/generated_browser.dart';

/// Resolve a generated recording that is absent from the rendered music rows.
class ReferenceBrowserFactory extends GeneratedBrowserFactory {
  // Count exact-ID requests without relying on a search result or list position.
  int referenceRequests = 0;
  // Model a busy main document while the isolated playback page has valid consent.
  bool mainWitnessMissing = false;

  /// Create isolated generated documents without any account or native IO.
  @override
  MusicBrowser create(BrowserEvents events) {
    // Retain ordinary fixture lifecycle ownership for each document.
    final page = ReferenceBrowser(this, events);
    pages.add(page);
    return page;
  }
}

/// Expose the fixed exact-ID endpoint while rejecting title search as a substitute.
class ReferenceBrowser extends GeneratedBrowser {
  /// Reuse the generated navigation and native audio isolation contracts.
  ReferenceBrowser(super.factory, super.events);

  /// Return generated music results for the same expressions used by production.
  @override
  Future<dynamic> evaluate(String expression) async {
    // Confirm personal-library consent independently of rendered recording rows.
    if (expression.contains('"verify-my-music"') ||
        expression.contains('"open-my-music"')) {
      // Reject extraction from the main document only after its initial connection.
      final config = factory as ReferenceBrowserFactory;
      return jsonEncode({
        'personal':
            !(config.mainWitnessMissing && identical(this, config.pages.first)),
      });
    }
    // Keep standby readiness independent of whether the selected row is visible.
    if (expression.contains('"readiness"')) {
      return jsonEncode({'count': 12, 'loading': false});
    }
    // Resolve only the requested recording, even without a saved reload hash.
    if (expression.contains('"resolve-reference","17_2630"')) {
      (factory as ReferenceBrowserFactory).referenceRequests++;
      return jsonEncode({
        'source': 'https://generated.vkuseraudio.net/exact.mp3',
        'userId': 17,
        'userAgent': 'Generated',
        'counts': {'matched': 1, 'urlsFound': 1},
      });
    }
    // Make the old search fallback fail promptly for a meaningful regression.
    if (expression.contains('"search-track"')) {
      throw const ProofFailure('track_not_in_search_results');
    }
    // Model a viewport that never contains the old selected recording.
    if (expression.contains('window.ownsembleMusic.read(')) {
      return jsonEncode({
        'userId': 17,
        'userAgent': 'Generated',
        'tracks': [
          {
            'id': '17_1',
            'title': 'Other',
            'artist': 'Fixture',
            'duration': 60,
            'url': '',
          },
        ],
      });
    }
    return jsonEncode(<String, Object>{});
  }
}

/// Cover exact-ID playback independently of viewport, title search and saved hashes.
void main() {
  test('missing main-page witness does not skip exact reload on the prepared personal page', () async {
    // Prepare the ordinary connection before simulating an unrelated main-page state.
    final factory = ReferenceBrowserFactory();
    // Capture safe lookup shape to distinguish absent hashes from provider rejection.
    final events = <Map<String, Object>>[];
    // Keep source lookup on the production provider's independent playback document.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
      diagnostic: events.add,
    );
    try {
      await provider.connect();
      factory.mainWitnessMissing = true;
      // Require an exact-ID request after consent is confirmed on the prepared page.
      final result = await provider.resolve(
        Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
      );
      expect(result.recordingId, '17_2630');
      expect(result.evidence, 'exact_reload');
      expect(factory.referenceRequests, 1);
      expect(
        (events.firstWhere(
              (event) => event['stage'] == 'reference_source',
            )['counts']
            as Map)['reloadReferences'],
        0,
      );
    } finally {
      await provider.disconnect();
    }
  });

  test('old recording without saved hashes uses exact reload before title search', () async {
    // Keep the entire provider lifecycle under generated browser contracts.
    final factory = ReferenceBrowserFactory();
    // Exercise production policy rather than an isolated helper implementation.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      // Keep generated Cyrillic metadata while resolving by stable identity only.
      final result = await provider.resolve(
        Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
      );
      expect(result.recordingId, '17_2630');
      expect(result.evidence, 'exact_reload');
      expect(factory.referenceRequests, 1);
    } finally {
      await provider.disconnect();
    }
  });
}
