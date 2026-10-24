import '../media/audio_policy.dart';
import '../provider/pagination_diagnostics.dart';

// Accept only application-owned stage names, never arbitrary text returned by a page.
const diagnosticStages = {
  'operation_started',
  'operation_finished',
  'operation_failed',
  'playback_status',
  'sync_status',
  'runtime_context',
  'adapter_loaded',
  'adapter_install_started',
  'adapter_install_finished',
  'standby_ready',
  'standby_failed',
  'action_failed',
  'metadata_read',
  'rows_timeout',
  'scan_pagination',
  'library_page_probe',
  'library_listing_page',
  'reference_source_unsupported',
  'reference_source',
  'source_memory_hit',
  'resolve_started',
  'resolve_finished',
  'standby_reused',
  'personal_music',
  'finding_track',
  'music_binding',
  'source_captured',
  'provider_restriction',
  'target_source_refresh',
  'capture_boundary',
  'music_search_input',
  'music_search',
  'activating_track',
  'playback_controls',
  'activated_playback_controls',
  'waiting_source',
  'source_finished',
  'lyrics_control',
  'metadata_details',
  'cache_revalidation_required',
  'witness_manifest',
  'witness_manifest_failed',
  'recording_source_bound',
  'ordinary_selection',
  'old_audio_selection',
  'audio_transfer_failed',
  'transfer_started',
  'transfer_headers',
  'transfer_first_bytes',
  'transfer_finished',
  'transfer_failed',
  'cache_stage',
  'unrecognized_stage',
};

// Whitelist numeric/boolean metrics; identifiers are never accepted as counters.
const _metricKeys = {
  'elapsed_ms',
  'code',
  'rows',
  'requests',
  'approved',
  'candidates',
  'segments',
  'age_ms',
  'page_wait_ms',
  'source_resolution_ms',
  'source_return_ms',
  'requests_seen',
  'cdp_audio_requests',
  'timing_candidates',
  'matched_candidates',
  'matched',
  'urlsFound',
  'responseNodes',
  'responseBatch',
  'personal_listing_member',
  'selection_listed',
  'same_title_listed',
  'same_artist_title_listed',
  'same_metadata_duration_listed',
  'historical_audio_sources',
  'timing_entries_before',
  'ordinal',
  'offset_from_end',
  'source_from_memory',
  'source_from_reference',
  'identity_bound',
  'hidden',
  'captured',
  'independent_page',
  'scanning',
  'standby',
  'searched',
  'preserved',
  'prepared_before_selection',
  'prefix_prepared_at_resolution',
  'prefix_source_matched',
  'loading',
  'playing',
  'buffering',
  'cached',
  'provider_connected',
  'offline',
  'private_signin_active',
  'received_bytes',
  'bytes',
  'http_status',
  'request_id',
  'hop',
  'connect_ms',
  'headers_ms',
  'first_byte_ms',
  'checkpoint_count',
  'checked',
  'new_tracks',
  'manual',
  'modernRows',
  'modernPropsFound',
  'modernAudioMatched',
  'modernURLsFound',
  'modernDOMMetadata',
  'musicUnavailable',
  'musicReloadHashes',
  'reloadReferences',
  'musicObjects',
  'musicArrays',
  'musicId',
  'musicOwner',
  'musicFullId',
  'musicURL',
  'userIdPresent',
  'encodedURLs',
  'hint_availableFalse',
  'hint_deleted',
  'hint_blocked',
  'hint_unavailable',
  'hint_restricted',
  'targetReloadAttempted',
  'targetReloadMatched',
  'targetReloadURLFound',
  'myMusicTargets',
  'selectedTargets',
  'headingMatch',
  'personalURLMatch',
  'musicSearchInputs',
  'musicSearchChangeHandler',
  'targetWidth',
  'targetHeight',
  'viewportWidth',
  'viewportHeight',
  'visibleDocument',
  'hitPresent',
  'hitInsideTarget',
  'hitSameTrack',
  'hitBlockedControl',
  'regionPresent',
  'regionClickHandlers',
  'rowClickHandlers',
  'clickHandlers',
  'mouseDownHandlers',
  'pointerDownHandlers',
  'doubleClickHandlers',
  'buttons',
  'descendants',
  'playingControls',
  'pausedControls',
  'nativeMediaElements',
  'lyricsButtons',
  'lyricsDialogs',
  'lyricsIdentity',
  'https',
  'http',
  'trailing_dot',
  'tld_ru',
  'tld_net',
  'tld_com',
  'relative',
  'port',
  'userinfo',
  'hls_component',
  'hls_path',
  'mp3_component',
  'mpd_component',
  'aac_component',
  'blob',
  'redirect',
  'vkuseraudio',
  'useraudio',
  'userapi',
  'okcdn',
  'vk-cdn',
  'vkuser',
  'vk',
  'Media',
  'Fetch',
  'XHR',
  'Other',
  'non_media',
  'media_scheme',
  'media_userinfo',
  'media_port',
  'media_host',
  'media_approved',
  'host_trailing_dot',
  'omitted_fields',
  'omitted_previous_report',
};

// Keep only fixed string enums, even when a page supplies a recognized field name.
const _enums = {
  'component': {'controller', 'provider', 'ui', 'database', 'other'},
  'kind': {'type', 'state', 'platform', 'filesystem', 'other'},
  'phase': {
    'stopping_previous',
    'resolving_source',
    'opening_native_player',
    'waiting_first_audio',
    'playing',
    'failed',
    'running',
    'finished',
  },
  'download_stage': {
    'finding_source',
    'receiving',
    'materializing',
    'decoding',
    'publishing',
  },
  'identity_evidence': {'metadata_row', 'exact_reload', 'native_player'},
  'music_age_bucket': {
    'before2010',
    '2010to2014',
    '2015to2019',
    '2020plus',
    'unknown',
  },
  'mode': {'full', 'head'},
  'transport': {'mp3', 'mpegts', 'isobmff', 'other'},
  'action': {
    'open-my-music',
    'verify-my-music',
    'play',
    'play-position',
    'verify-play-hit',
    'probe-playback',
    'begin-audio-capture',
    'audio-resources',
    'current-audio-source',
    'search-track',
    'pause',
    'probe-library-page',
    'read-library-page',
    'lyrics-position',
    'verify-lyrics-hit',
    'lyrics-hover-position',
    'verify-lyrics-hover',
    'read-lyrics',
    'readiness',
    'scroll-more',
    'scroll-top',
  },
};

// Preserve only fixed structural groups; unknown nested objects are discarded.
const _groups = {
  'counts',
  'controls',
  'source_shape',
  'destination',
  'request_kinds',
  'network_kinds',
  'labels',
};

// Include non-literal transport and provider categories generated by fixed branches.
const _additionalCategories = {
  'operation_failed',
  'unrecognized_category',
  'audio_restricted',
  'audio_restricted_copyright',
  'audio_restricted_region',
  'audio_restricted_subscription',
  'audio_restricted_age',
  'audio_certificate_failed',
  'audio_tls_failed',
  'audio_socket_failed',
  'audio_connection_failed',
  'audio_network_timeout',
  'audio_network_failed',
  'metadata_request_timeout',
  'diagnostics_export_failed',
};

/// Bound fixed scalar metrics without retaining arbitrary page-provided names.
bool _knownMetric(String key) =>
    _metricKeys.contains(key) ||
    paginationCounts({key: 0}).containsKey(key) ||
    [
      for (final suffix in const [
        ...cdnSuffixes,
        'vk.com',
        'vk.ru',
        'mycdn.me',
        'vkuser.net',
        'vkusercdn.net',
        'vkcdn.audio',
      ])
        'suffix_$suffix',
    ].contains(key) ||
    [
      for (final ext in const [
        'mp3',
        'm3u8',
        'm4a',
        'ts',
        'aac',
        'm4s',
        'other',
      ])
        'extension_$ext',
    ].contains(key);

/// Allow fixed failure categories; an unknown exception never exports its text.
String safeDiagnosticCategory(Object? category) =>
    category is String &&
        (diagnosticFailureCategories.contains(category) ||
            _additionalCategories.contains(category) ||
            decoderCategories.contains(category))
    ? category
    : 'unrecognized_category';

/// Separate terminal/transport failures from observations of recoverable fallbacks.
bool diagnosticEventIsFailure(Map event) =>
    event['category'] != null &&
    event['category'] != 'cancelled' &&
    (const {
          'operation_failed',
          'transfer_failed',
          'audio_transfer_failed',
          'standby_failed',
          'provider_restriction',
        }.contains(event['stage']) ||
        event['stage'] == 'playback_status' && event['phase'] == 'failed');

/// Project each event through an explicit schema before it reaches any file.
Map<String, Object> sanitizeDiagnosticEvent(Map input) {
  // Limit the whole event, including nested groups, to 64 accepted scalar values.
  var remaining = 64;
  // Count dropped fields without storing their names or values.
  var omitted = 0;

  /// Recursively retain only fixed metric names and bounded primitive values.
  Map<String, Object> project(Map value, int depth) {
    // Accumulate a fresh map so later caller mutations cannot alter saved evidence.
    final output = <String, Object>{};
    for (final entry in value.entries) {
      // Treat malformed keys and exhausted budgets as omissions.
      if (entry.key is! String || remaining <= 0) {
        omitted++;
        continue;
      }
      // Keep the validated key separate from its potentially private value.
      final key = entry.key as String;
      // Inspect only primitive values or recognized structural groups.
      final item = entry.value;
      // Preserve the event stage as a fixed enum, never raw page text.
      if (depth == 0 && key == 'stage') {
        output[key] = diagnosticStages.contains(item)
            ? item as String
            : 'unrecognized_stage';
      }
      // Preserve only registered error categories.
      else if (depth == 0 && key == 'category') {
        output[key] = safeDiagnosticCategory(item);
      }
      // Permit only a digest generated from the bundled public adapter source.
      else if (depth == 0 &&
          key == 'adapter_sha256' &&
          item is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(item)) {
        output[key] = item;
      }
      // Keep fixed string dimensions without allowing free-form text.
      else if (depth == 0 && _enums[key]?.contains(item) == true) {
        output[key] = item as String;
      }
      // Keep bounded numeric counters and boolean structural flags.
      else if (_knownMetric(key) &&
          (item is bool ||
              item is num &&
                  item.isFinite &&
                  item >= -2147483648 &&
                  item <= 1000000000000)) {
        output[key] = item is bool ? item : (item as num).round();
      }
      // Bound nested groups and reject arbitrary page objects.
      else if (_groups.contains(key) && item is Map && depth < 2) {
        output[key] = project(item, depth + 1);
      }
      // Drop every other field, including URLs, identifiers, titles and messages.
      else {
        omitted++;
        continue;
      }
      remaining--;
    }
    return output;
  }

  // Always expose a known stage so future adapter/schema drift is visible.
  final result = project(input, 0);
  result.putIfAbsent('stage', () => 'unrecognized_stage');
  // Report schema drift as a count without recording the unknown fields.
  if (omitted > 0) result['omitted_fields'] = omitted;
  return result;
}

/// Suggest an investigation area from the observed category, without guessing a cause.
String diagnosticFailureArea(String category, String? phase) {
  // Keep ordinary cancellation distinct from provider or playback failures.
  if (category == 'cancelled') return 'cancelled';
  // Point destination rejections at policy/redirect compatibility first.
  if (category.contains('destination')) return 'cdn_destination';
  // Preserve privacy and private-login boundaries during diagnosis.
  if (category.startsWith('private_') || category == 'vk_not_connected') {
    return 'connection_or_private_signin';
  }
  // Never treat provider restrictions as an unavailable extraction format.
  if (category.startsWith('audio_restricted')) return 'provider_restriction';
  // Keep exact recording mismatches separate from transport problems.
  if (category.contains('identity')) return 'recording_identity';
  // Separate HTTP/TLS/socket failures from generic native decoder symptoms.
  if (RegExp(r'^audio_(?:http|tls|socket|connection|network|certificate)')
      .hasMatch(category)) {
    return 'media_transport';
  }
  // Identify unsupported playlists or packed segment formats.
  if (category.startsWith('hls_')) return 'playlist_or_segment_format';
  // Point local publication/integrity issues at the cache implementation.
  if (category.startsWith('cache_') || category == 'legacy_hash_mismatch') {
    return 'local_cache';
  }
  // Locate source lookup deadlines before investigating native playback.
  if (category == 'player_start_timeout' && phase == 'resolving_source') {
    return 'source_resolution';
  }
  // Distinguish native startup/decoder failures from page extraction failures.
  if (category.startsWith('decoder_') ||
      category.startsWith('native_') ||
      category.startsWith('player_') ||
      category == 'audio_duration_mismatch') {
    return 'native_playback_or_integrity';
  }
  // Investigate page contract/capability changes with the matching adapter fingerprint.
  if (category.startsWith('music_') ||
      category.startsWith('browser_') ||
      category.startsWith('adapter_') ||
      category.startsWith('track_') ||
      category.startsWith('personal_') ||
      category.startsWith('play_control_')) {
    return 'page_or_adapter_contract';
  }
  return 'unclassified';
}

// Register literal application failure categories so diagnostics never accept raw text.
const diagnosticFailureCategories = <String>{
  'adapter_response_invalid',
  'artwork_cache_path',
  'artwork_decode_failed',
  'artwork_destination_rejected',
  'artwork_dimensions',
  'artwork_http_failed',
  'artwork_invalid',
  'artwork_redirect_budget',
  'artwork_size_budget',
  'audio_destination_rejected',
  'audio_duration_mismatch',
  'audio_empty',
  'audio_format_unsupported',
  'audio_http_failed',
  'audio_identity_mismatch',
  'audio_identity_unverified',
  'audio_incomplete',
  'audio_play_control_disabled',
  'audio_redirect_budget',
  'audio_redirect_invalid',
  'audio_size_budget',
  'audio_source_ambiguous',
  'audio_source_not_resolved',
  'audio_transfer_failed',
  'audio_witness_budget',
  'browser_already_open',
  'browser_capability_missing',
  'browser_closed',
  'browser_document_start_failed',
  'browser_mute_unavailable',
  'browser_native_timeout',
  'browser_navigation_blocked',
  'browser_not_prepared',
  'browser_sandbox_unavailable',
  'cache_already_exists',
  'cache_identity_unverified',
  'cache_integrity_failed',
  'cache_mismatch_not_unique',
  'cache_path_invalid',
  'cancelled',
  'database_version_newer',
  'diagnostics_export_failed',
  'fixture_route_changed',
  'hls_byte_ranges_unsupported',
  'hls_decryption_failed',
  'hls_encryption_unsupported',
  'hls_feature_unsupported',
  'hls_invalid_manifest',
  'hls_iv_invalid',
  'hls_key_invalid',
  'hls_local_reference_invalid',
  'hls_master_depth',
  'hls_mp3_frame_incomplete',
  'hls_mp3_frame_invalid',
  'hls_mp3_frame_unsupported',
  'hls_mp3_no_frames',
  'hls_mp3_tag_invalid',
  'hls_no_segments',
  'hls_not_complete_vod',
  'hls_segment_budget',
  'hls_segment_duration_invalid',
  'hls_timestamp_invalid',
  'hls_transport_changed',
  'hls_ts_audio_ambiguous',
  'hls_ts_audio_changed',
  'hls_ts_packet_invalid',
  'hls_ts_pes_incomplete',
  'hls_ts_pes_unsupported',
  'invalid_artwork_key',
  'invalid_lyrics_state',
  'invalid_music_metadata',
  'invalid_music_position',
  'invalid_music_reference',
  'invalid_sync_checkpoint',
  'legacy_hash_mismatch',
  'local_play_used_stream',
  'main_control_pause_failed',
  'main_control_stop_failed',
  'metadata_request_timeout',
  'music_adapter_unsupported',
  'music_input_timeout',
  'music_page_timeout',
  'music_rows_timeout',
  'music_script_failed',
  'music_search_unsupported',
  'native_decoder_failed',
  'native_player_failed',
  'offline_network_blocked',
  'personal_music_unconfirmed',
  'pile_name_invalid',
  'play_control_outside_viewport',
  'play_control_unsupported',
  'player_decode_failed',
  'player_start_timeout',
  'preview_requires_checkout',
  'preview_track_not_cached',
  'private_signin_in_progress',
  'private_signin_required',
  'restart_build_missing',
  'restart_platform_unavailable',
  'smoke_check_failed',
  'stream_destination_rejected',
  'stream_native_error',
  'stream_waited_for_complete',
  'track_not_cached',
  'track_not_in_search_results',
  'track_not_loaded',
  'user_agent_invalid',
  'vk_not_connected',
};
