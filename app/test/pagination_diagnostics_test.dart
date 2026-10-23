import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/provider/pagination_diagnostics.dart';

/// Verify that pagination diagnostics expose only bounded layout counts.
void main() {
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
