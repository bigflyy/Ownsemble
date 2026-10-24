import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/pagination_diagnostics.dart';
import 'package:ownsemble/services/diagnostic_schema.dart';

/// Verify that pagination diagnostics expose only bounded layout counts.
void main() {
  test('listing action failures retain their fixed action through report sanitization', () {
    // Preserve a useful fixed stage/action while dropping private-looking unknown fields.
    final event = sanitizeDiagnosticEvent({
      'stage': 'action_failed',
      'action': 'read-library-page',
      'counts': {
        'libraryRows': 100,
        'libraryNextOffset': 100,
        'privateBody': 'generated',
      },
    });
    expect(event['action'], 'read-library-page');
    expect(event['counts'], {'libraryRows': 100, 'libraryNextOffset': 100});
  });

  test(
    'library probe failure stages survive the numeric privacy projection',
    () {
      expect(
        paginationCounts({
          'libraryWindows1251': 1,
          'libraryEncodingFailed': 1,
          'libraryEncodingUnsupported': 0,
          'libraryResponseBytes': 123,
          'libraryMetadataUnsupported': 1,
          'libraryPaginationUnsupported': 0,
          'libraryProbeFailureStage': 3,
          'libraryProbePage': 1,
          'libraryJSONDecodeFailed': 1,
          'libraryDeadlineExpired': 0,
          'rawBody': 'generated private reply',
        }),
        {
          'libraryWindows1251': 1,
          'libraryEncodingFailed': 1,
          'libraryEncodingUnsupported': 0,
          'libraryResponseBytes': 123,
          'libraryMetadataUnsupported': 1,
          'libraryPaginationUnsupported': 0,
          'libraryProbeFailureStage': 3,
          'libraryProbePage': 1,
          'libraryJSONDecodeFailed': 1,
          'libraryDeadlineExpired': 0,
        },
      );
    },
  );

  test('pagination reports accept bounded layout counts only', () {
    expect(
      paginationCounts({
        'documentScrollHeight': 1200,
        'documentClientHeight': 600,
        'documentScrollTop': 12,
        'scrollableMusicAncestors': 1,
        'visibleDocument': 1,
        'musicRows': 115,
        'visibleMusicRows': 100,
        'tallestMusicAncestor': 6000,
        'clippedMusicAncestors': 1,
        'libraryRequestOK': 1,
        'libraryResponseCharacters': 2097153,
        'libraryResponseTooLarge': 1,
        'libraryHTTPStatus': 200,
        'libraryJSONResponse': 1,
        'libraryShapeSupported': 1,
        'libraryRows': 2000,
        'libraryHasMore': 1,
        'libraryNextOffset': 2000,
        'libraryTotal': 2633,
        'libraryComparedComplete': 1,
        'libraryUniqueRecordings': 2615,
        'libraryDOMUniqueRecordings': 2630,
        'libraryDOMOutsideListing': 15,
        'libraryOutsideRecommendationRows': 15,
        'title': 'generated private field',
        'url': 'https://example.invalid/private',
      }),
      {
        'documentScrollHeight': 1200,
        'documentClientHeight': 600,
        'documentScrollTop': 12,
        'scrollableMusicAncestors': 1,
        'visibleDocument': 1,
        'musicRows': 115,
        'visibleMusicRows': 100,
        'tallestMusicAncestor': 6000,
        'clippedMusicAncestors': 1,
        'libraryRequestOK': 1,
        'libraryResponseCharacters': 2097153,
        'libraryResponseTooLarge': 1,
        'libraryHTTPStatus': 200,
        'libraryJSONResponse': 1,
        'libraryShapeSupported': 1,
        'libraryRows': 2000,
        'libraryHasMore': 1,
        'libraryNextOffset': 2000,
        'libraryTotal': 2633,
        'libraryComparedComplete': 1,
        'libraryUniqueRecordings': 2615,
        'libraryDOMUniqueRecordings': 2630,
        'libraryDOMOutsideListing': 15,
        'libraryOutsideRecommendationRows': 15,
      },
    );
    // Reject unsupported types and values outside the numeric count budget.
    for (final value in [
      double.nan,
      double.infinity,
      -1,
      1000000001,
      '123',
      true,
    ]) {
      expect(paginationCounts({'documentScrollHeight': value}), isEmpty);
    }
    expect(paginationCounts(null), isEmpty);
    expect(paginationCounts(['generated']), isEmpty);
  });
}
