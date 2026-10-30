import 'package:flutter/material.dart';

import '../library/library_store.dart';
import '../vk/vk_login_window.dart';
import '../vk/vk_sync.dart';
import 'sync_controller.dart';
import 'theme.dart';
import 'vk_account.dart';

/// The bottom status bar: each synced source with its state, a thin progress
/// line while a sync runs, and the Sync now button. Logged out, or with a
/// session VK no longer takes, the button logs in instead.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({super.key, required this.sync, this.account});

  final SyncController sync;

  /// The VK account; without one there is nothing to log in to.
  final VkAccount? account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final account = this.account;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, ?account]),
      builder: (context, _) {
        final loginNeeded =
            account != null && (!account.loggedIn || sync.loginExpired);
        final progress = sync.progress;
        final sources = sync.syncedSources;
        final percent = progress == null
            ? 0
            : (progress.fraction * 100).round();
        final own = OwnColors.of(context);
        return Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: own.surface,
                border: Border(top: BorderSide(color: own.line)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
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
                  if (loginNeeded)
                    LogInButton(account: account)
                  else
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: own.text,
                        side: BorderSide(color: own.line),
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      key: const ValueKey('sync-now'),
                      onPressed: sync.canSync && !sync.running
                          ? sync.syncNow
                          : null,
                      icon: const Icon(Icons.sync, size: 16),
                      label: Text(
                        sync.running ? 'Syncing $percent%' : 'Sync now',
                      ),
                    ),
                  if (account != null && account.loggedIn)
                    PopupMenuButton<String>(
                      key: const ValueKey('vk-account-menu'),
                      tooltip: 'VK account',
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: Icon(Icons.more_vert, color: own.dim),
                      onSelected: (_) => account.logOut(),
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          key: ValueKey('vk-log-out'),
                          value: 'log-out',
                          child: Text('Log out of VK'),
                        ),
                      ],
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

/// Opens the VK login window. While it is open the button says so; a click
/// then brings the window back to the front. A window that cannot open says
/// why in a message.
class LogInButton extends StatelessWidget {
  const LogInButton({super.key, required this.account});

  final VkAccount account;

  Future<void> _logIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await account.logIn();
    } on LoginWindowException catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Cannot log in: ${error.reason}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const ValueKey('vk-log-in'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 13),
      ),
      onPressed: () => _logIn(context),
      icon: const Icon(Icons.login, size: 16),
      label: Text(account.loggingIn ? 'Logging in...' : 'Log in to VK'),
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
    final own = OwnColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: failed ? colors.error : own.source1,
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
