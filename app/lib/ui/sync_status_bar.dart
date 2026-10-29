import 'package:flutter/material.dart';

import '../library/library_store.dart';
import '../vk/vk_sync.dart';
import 'sync_controller.dart';

/// The bottom status bar: each synced source with its state, a thin progress
/// line while a sync runs, and the Sync now button.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({super.key, required this.sync});

  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final progress = sync.progress;
        final sources = sync.syncedSources;
        final percent = progress == null
            ? 0
            : (progress.fraction * 100).round();
        return Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 18,
                      runSpacing: 4,
                      children: [
                        if (sources.isEmpty)
                          _SourceState(
                            name: 'VK',
                            state: sync.canSync
                                ? (sync.running
                                      ? 'syncing...'
                                      : 'not synced yet')
                                : 'not logged in',
                            style: style,
                          ),
                        for (final source in sources)
                          _SourceState(
                            key: ValueKey('sync-source-${source.id}'),
                            name: source.name,
                            state: sync.running
                                ? 'syncing...'
                                : describeSourceState(
                                    source,
                                    lastResult: sync.lastOutcome?.result,
                                    now: DateTime.now(),
                                  ),
                            failed:
                                !sync.running && source.lastSyncError != null,
                            style: style,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('sync-now'),
                    onPressed: sync.canSync && !sync.running
                        ? sync.syncNow
                        : null,
                    icon: const Icon(Icons.sync, size: 16),
                    label: Text(
                      sync.running ? 'Syncing $percent%' : 'Sync now',
                    ),
                  ),
                ],
              ),
            ),
            if (progress != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(
                  key: const ValueKey('sync-progress'),
                  value: progress.fraction,
                  minHeight: 2,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One source in the status bar: a dot, its name and its state.
class _SourceState extends StatelessWidget {
  const _SourceState({
    super.key,
    required this.name,
    required this.state,
    required this.style,
    this.failed = false,
  });

  final String name;
  final String state;
  final TextStyle? style;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: failed ? colors.error : colors.primary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Text(name, style: style?.copyWith(color: colors.onSurface)),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            state,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: failed ? style?.copyWith(color: colors.error) : style,
          ),
        ),
      ],
    );
  }
}

/// What the status bar says about [source] when no sync runs: its songs,
/// how many are gone from it and when it last synced. [lastResult] is the
/// last sync of this session; when it was this source's, what it changed is
/// added.
String describeSourceState(
  SourceInfo source, {
  required VkSyncResult? lastResult,
  required DateTime now,
}) {
  final at = source.lastSyncAtMs;
  if (at == null) return '${source.songCount} songs, not synced yet';
  final when = formatSyncTime(DateTime.fromMillisecondsSinceEpoch(at), now);
  final error = source.lastSyncError;
  if (error != null) return 'sync failed $when: $error';
  final parts = [
    '${source.songCount} songs',
    if (source.goneCount > 0) '${source.goneCount} gone from VK',
    'synced $when',
  ];
  if (lastResult != null && lastResult.sourceId == source.id) {
    final changes = [
      if (lastResult.added > 0) '${lastResult.added} new',
      if (lastResult.updated > 0) '${lastResult.updated} updated',
      if (lastResult.newlyGone > 0) '${lastResult.newlyGone} newly gone',
      if (lastResult.back > 0) '${lastResult.back} back',
    ];
    parts.add(changes.isEmpty ? 'no changes' : changes.join(', '));
  }
  return parts.join(' · ');
}

/// "today 14:02", "yesterday 09:30" or "2026-10-28 18:15".
String formatSyncTime(DateTime at, DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  // Rounded, because a day with a clock change has 23 or 25 hours.
  final daysAgo = (today.difference(day).inHours / 24).round();
  if (daysAgo == 0) return 'today $time';
  if (daysAgo == 1) return 'yesterday $time';
  return '${at.year}-${two(at.month)}-${two(at.day)} $time';
}
