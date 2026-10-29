/// Keep sync progress independent of playback and retain only bounded result data.
class SyncActivity {
  final String phase;
  final String mode;
  final int checked;
  final int added;
  final DateTime? finishedAt;
  final String? reason;

  const SyncActivity({
    this.phase = 'idle',
    this.mode = 'head',
    this.checked = 0,
    this.added = 0,
    this.finishedAt,
    this.reason,
  });

  String get failureHint => switch (reason) {
    'private_signin_required' || 'private_signin_in_progress' => 'VK needs private sign-in. Open the connection controls, sign in privately, then choose Connect VK. Saved music stays available.',
    'music_adapter_unsupported' =>
      'VK changed its music page. Your library and saved music are safe.',
    'music_page_timeout' || 'music_rows_timeout' || 'music_input_timeout' => 'VK did not finish loading the library. Try checking newest entries again. Saved music stays available.',
    _ => 'VK could not be checked. Try again when connected; your saved library is retained.',
  };

  bool get active => phase == 'running' || phase == 'stopping';

  String get label => switch (phase) {
    'running' =>
      mode == 'full' ? 'Scanning full library' : 'Checking newest entries',
    'stopping' => 'Stopping sync',
    'succeeded' =>
      mode == 'full' ? 'Full scan complete' : 'Newest entries checked',
    'partial' =>
      mode == 'full' ? 'Partial library scan' : 'Newest check incomplete',
    'failed' => 'Sync failed',
    'cancelled' => 'Sync stopped',
    _ => 'No sync result yet',
  };

  /// Reject malformed or interrupted legacy state instead of restoring a spinner.
  factory SyncActivity.restore(dynamic value) {
    if (value is! Map ||
        ![
          'succeeded',
          'partial',
          'failed',
          'cancelled',
        ].contains(value['phase'])) {
      return const SyncActivity();
    }
    final finished = value['finishedAt'];
    final stamp = finished is String ? DateTime.tryParse(finished) : null;
    final checked = value['checked'];
    final added = value['added'];
    if (stamp == null ||
        checked is! int ||
        checked < 0 ||
        added is! int ||
        added < 0 ||
        !['head', 'full'].contains(value['mode'])) {
      return const SyncActivity();
    }
    final reason = safeReason(value['reason']);
    final success =
        reason == 'provider_end' ||
        (value['mode'] == 'head' &&
            ['known_head', 'head_seeded'].contains(reason));
    return SyncActivity(
      phase: value['phase'] == 'succeeded' && !success
          ? 'partial'
          : value['phase'] as String,
      mode: value['mode'] as String,
      checked: checked,
      added: added,
      finishedAt: stamp,
      reason: reason,
    );
  }

  /// Store no provider text, track identities or temporary media addresses.
  Map<String, Object?> toJson() => {
    'phase': phase,
    'mode': mode,
    'checked': checked,
    'added': added,
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'reason': safeReason(reason),
  };

  /// Restrict public result categories to known application outcomes.
  static String? safeReason(dynamic value) => switch (value) {
    null => null,
    'provider_end' ||
    'known_head' ||
    'head_seeded' ||
    'time_budget' ||
    'head_budget' ||
    'quiet_boundary' ||
    'page_limit' ||
    'cancelled' ||
    'music_adapter_unsupported' ||
    'music_page_timeout' ||
    'music_rows_timeout' ||
    'private_signin_required' ||
    'private_signin_in_progress' ||
    'vk_not_connected' ||
    'music_input_timeout' ||
    'browser_mute_unavailable' => value as String,
    _ => 'operation_failed',
  };
}
