/// Layout counts only. Never relay arbitrary page data in diagnostics.
Map<String, int> paginationCounts(dynamic value) {
  // Reject unstructured results before examining recognized numeric fields.
  if (value is! Map) return {};
  return {
    // Retain only the known layout counters from the guarded music probe.
    for (final key in const [
      'documentScrollHeight',
      'documentClientHeight',
      'documentScrollTop',
      'scrollableMusicAncestors',
      'visibleDocument',
      'musicRows',
      'visibleMusicRows',
      'tallestMusicAncestor',
      'clippedMusicAncestors',
      'libraryRequestOK',
      'libraryResponseCharacters',
      'libraryResponseTooLarge',
      'libraryHTTPStatus',
      'libraryJSONResponse',
      'libraryShapeSupported',
      'libraryRows',
      'libraryHasMore',
      'libraryNextOffset',
      'libraryTotal',
      'libraryOwnerUnavailable',
      'libraryResponseUnsupported',
      'libraryShapeUnsupported',
      'libraryProbeFailed',
      'libraryComparedComplete',
      'libraryUniqueRecordings',
      'libraryDOMUniqueRecordings',
      'libraryDOMOutsideListing',
      'libraryListedOutsideDOM',
      'libraryOutsideRecommendationRows',
      'libraryComparisonUnavailable',
      'libraryProbeTimeout',
      'libraryProbeScriptFailed',
    ])
      // Reject invalid, negative or excessive counts before rounding to integers.
      if (value[key] is num &&
          (value[key] as num).isFinite &&
          value[key] >= 0 &&
          value[key] <= 1000000000)
        key: (value[key] as num).round(),
  };
}
