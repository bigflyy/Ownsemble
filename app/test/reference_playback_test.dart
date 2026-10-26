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
  // Expose a current rendered source while the legacy reload returns an older link.
  bool modernSourceAvailable = false;
  // Model a recording available only through a sufficiently specific music query.
  bool requiresArtistSearch = false;
  // Keep the legacy endpoint returning a stale-looking address while current search has the usable row.
  bool legacyReturnsStaleSource = false;
  // Keep the exact recording absent after an otherwise supported music search.
  bool searchReturnsNoMatch = false;
  // Count submitted searches to reject repeated searches during one bounded lookup.
  int searchRequests = 0;
  // Measure when a supported search starts without changing the production clock.
  Stopwatch? searchStarted;
  // Record the search age when the legacy endpoint is finally requested.
  int? searchAgeAtReferenceMs;
  // Publish the exact generated recording only after the narrow search completes.
  bool searchedWithArtist = false;
  // Retain the bounded query expected by this generated search result.
  String expectedMusicQuery = 'Тестовый артист Тестовая песня';

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
      // Observe fallback ordering without exposing generated source addresses in logs.
      (factory as ReferenceBrowserFactory).searchAgeAtReferenceMs =
          (factory as ReferenceBrowserFactory)
              .searchStarted
              ?.elapsedMilliseconds;
      // Exercise search when the service has no usable saved or bare reload reference.
      if ((factory as ReferenceBrowserFactory).requiresArtistSearch &&
          !(factory as ReferenceBrowserFactory).legacyReturnsStaleSource) {
        return jsonEncode({
          'source': '',
          'counts': {'matched': 0, 'urlsFound': 0},
        });
      }
      return jsonEncode({
        'source': 'https://generated.vkuseraudio.net/exact.mp3',
        'userId': 17,
        'userAgent': 'Generated',
        'counts': {'matched': 1, 'urlsFound': 1},
      });
    }
    // Make the old search fallback fail promptly for a meaningful regression.
    if (expression.contains('"search-track"')) {
      // Model a supported search that never returns the original recording identity.
      final config = factory as ReferenceBrowserFactory;
      config.searchRequests++;
      // Leave the visible rows unchanged while production waits for its search deadline.
      if (config.searchReturnsNoMatch) {
        config.searchStarted = Stopwatch()..start();
        return jsonEncode({
          'searched': true,
          'counts': {'musicSearchInputs': 1},
        });
      }
      // Match the generated artist and title rather than a common title alone.
      if ((factory as ReferenceBrowserFactory).requiresArtistSearch &&
          expression.contains(
            '"musicQuery":${jsonEncode((factory as ReferenceBrowserFactory).expectedMusicQuery)}',
          )) {
        (factory as ReferenceBrowserFactory).searchedWithArtist = true;
        return jsonEncode({
          'searched': true,
          'counts': {'musicSearchInputs': 1},
        });
      }
      throw const ProofFailure('track_not_in_search_results');
    }
    // Model a viewport that never contains the old selected recording.
    if (expression.contains('window.ownsembleMusic.read(')) {
      // Prefer an exact current row over an obsolete legacy reload address.
      if ((factory as ReferenceBrowserFactory).modernSourceAvailable) {
        return jsonEncode({
          'userId': 17,
          'userAgent': 'Generated',
          'tracks': [
            {
              'id': '17_2630',
              'title': 'Тестовая песня',
              'artist': 'Тестовый артист',
              'duration': 60,
              'url': 'https://generated.vkuseraudio.net/modern.mp3',
            },
          ],
        });
      }
      // Keep exact owner/audio identity binding mandatory after a metadata query.
      if ((factory as ReferenceBrowserFactory).searchedWithArtist) {
        return jsonEncode({
          'userId': 17,
          'userAgent': 'Generated',
          'tracks': [
            {
              'id': '17_2630',
              'title': 'Тестовая песня',
              'artist': 'Тестовый артист',
              'duration': 60,
              'url': 'https://generated.vkuseraudio.net/exact.mp3',
            },
          ],
        });
      }
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
  // Exercise both terminal outcomes of a supported search that never finds the exact ID.
  for (final legacyAvailable in [true, false]) {
    test(
      'search timeout tries legacy exactly once, available=$legacyAvailable',
      () async {
        // Keep search usable but empty and independently control the exact legacy response.
        final factory = ReferenceBrowserFactory()
          ..searchReturnsNoMatch = true
          ..requiresArtistSearch = true
          ..legacyReturnsStaleSource = legacyAvailable;
        // Exercise the real bounded resolver without native, account or network access.
        final provider = VkProvider(
          browserFactory: factory,
          loadAdapter: () async => 'generated-only',
          status: (_) {},
          changed: () {},
        );
        try {
          await provider.connect();
          // Retain the original identity even when only the fallback supplies a URL.
          final resolution = provider.resolve(
            Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
          );
          // Accept only the exact fallback after the current search has exhausted its bound.
          if (legacyAvailable) {
            // Keep the response separate so its recording evidence can be checked.
            final result = await resolution;
            expect(result.recordingId, '17_2630');
            expect(result.evidence, 'exact_reload');
          }
          // Preserve an explicit terminal failure when neither path returns the original ID.
          else {
            await expectLater(
              resolution,
              throwsA(
                isA<ProofFailure>().having(
                  (failure) => failure.category,
                  'category',
                  'track_not_in_search_results',
                ),
              ),
            );
          }
          expect(factory.searchRequests, 1);
          expect(factory.referenceRequests, 1);
          expect(factory.searchAgeAtReferenceMs, greaterThanOrEqualTo(10000));
        } finally {
          await provider.disconnect();
        }
      },
    );
  }

  test('non-rendered recordings use current exact-ID search before an available legacy URL', () async {
    // Reproduce a legacy response that matches the ID but hides the working current row.
    final factory = ReferenceBrowserFactory()
      ..requiresArtistSearch = true
      ..legacyReturnsStaleSource = true;
    // Keep navigation and music responses generated while exercising production lookup order.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      // Require the current row to be searched before considering the legacy endpoint.
      final result = await provider.resolve(
        Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
      );
      expect(factory.searchedWithArtist, true);
      expect(factory.referenceRequests, 0);
      expect(result.recordingId, '17_2630');
      expect(result.evidence, 'metadata_row');
    } finally {
      await provider.disconnect();
    }
  });

  test(
    'an exact current rendered source takes precedence over legacy reload URLs',
    () async {
      // Keep the obsolete endpoint available to reproduce its former priority.
      final factory = ReferenceBrowserFactory()..modernSourceAvailable = true;
      // Exercise real lookup ordering without a browser profile or external IO.
      final provider = VkProvider(
        browserFactory: factory,
        loadAdapter: () async => 'generated-only',
        status: (_) {},
        changed: () {},
      );
      try {
        await provider.connect();
        // Bind the current source to the original recording, independent of title similarity.
        final result = await provider.resolve(
          Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
        );
        expect(result.source.path, '/modern.mp3');
        expect(result.recordingId, '17_2630');
        expect(factory.referenceRequests, 0);
      } finally {
        await provider.disconnect();
      }
    },
  );

  test('long artist metadata preserves the working title-only search budget', () async {
    // Keep an overlong artist from pushing a short title beyond the input budget.
    final factory = ReferenceBrowserFactory()
      ..requiresArtistSearch = true
      ..expectedMusicQuery = 'Тестовая песня';
    // Exercise the actual source resolver while keeping all content generated.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      // Preserve the existing title-only fallback for unusually long provider metadata.
      final result = await provider.resolve(
        Track('17_2630', 'Тестовая песня', 'А' * 200, 60),
      );
      expect(result.recordingId, '17_2630');
    } finally {
      await provider.disconnect();
    }
  });

  test('search fallback narrows a common title with its artist while retaining exact identity', () async {
    // Require the real provider's fallback search rather than an available reference.
    final factory = ReferenceBrowserFactory()..requiresArtistSearch = true;
    // Keep all page and transport results generated and silent.
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await provider.connect();
      // Require the exact recording to appear only for the complete metadata query.
      final result = await provider.resolve(
        Track('17_2630', 'Тестовая песня', 'Тестовый артист', 60),
      );
      expect(factory.searchedWithArtist, true);
      expect(result.recordingId, '17_2630');
      expect(result.evidence, 'metadata_row');
    } finally {
      await provider.disconnect();
    }
  });

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

  test('old recording without saved hashes retains exact reload when current search is unsupported', () async {
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
