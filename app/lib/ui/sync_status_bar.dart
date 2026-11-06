import 'package:flutter/material.dart';

import '../library/library_store.dart';
import '../vk/vk_login_window.dart';
import '../vk/vk_sync.dart';
import 'accounts_dialog.dart';
import 'source_editor.dart';
import 'sync_controller.dart';
import 'theme.dart';
import 'vk_accounts.dart';

/// The bottom status bar: each synced source with its state, a thin progress
/// line while a sync runs, and the Sync now button. Logged out, or with every
/// session refused by VK, the button logs in instead. Several accounts share
/// the one line, so each shows less; its tooltip has the rest.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({
    super.key,
    required this.sync,
    this.account,
    this.sources,
  });

  final SyncController sync;

  /// The VK accounts; without them there is nothing to log in to.
  final VkAccounts? account;

  /// Renames, recolors and removes accounts.
  final SourceEditor? sources;

  /// The status of [source]. Compact, it shows the song count or what is
  /// wrong, and the whole state in its tooltip.
  Widget _state(SourceInfo source, TextStyle? style, {required bool compact}) {
    final account = this.account;
    final failed = !sync.syncing && source.lastSyncError != null;
    final full = describeSourceState(
      source,
      lastResult: sync.lastOutcome?.resultOf(source.id),
      now: DateTime.now(),
    );
    final loggedOut = account != null && !account.hasSession(source.account);
    final state = sync.syncing
        ? 'syncing...'
        : !compact
        ? full
        : loggedOut
        ? 'not logged in'
        : failed
        ? source.lastSyncError!
        : '${source.songCount} songs';
    return Builder(
      builder: (context) {
        final row = _SourceState(
          key: ValueKey('sync-source-${source.id}'),
          name: source.name,
          state: state,
          color: OwnColors.of(context).sourceColor(source.color),
          failed: failed,
          style: style,
        );
        return compact ? Tooltip(message: full, child: row) : row;
      },
    );
  }

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
        final checking = sync.checking;
        final sources = sync.syncedSources;
        final percent = progress == null
            ? 0
            : (progress.fraction * 100).round();
        // Stage M2: the check of every song's file after a sync.
        final fraction = progress?.fraction ?? checking?.fraction;
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
                    child: sources.length > 1
                        ? Row(
                            children: [
                              for (final source in sources)
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 18),
                                    child: _state(source, style, compact: true),
                                  ),
                                ),
                            ],
                          )
                        : Wrap(
                            spacing: 18,
                            runSpacing: 4,
                            children: [
                              if (sources.isEmpty)
                                _SourceState(
                                  name: 'VK',
                                  state: sync.canSync
                                      ? (sync.syncing
                                            ? 'syncing...'
                                            : 'not synced yet')
                                      : 'not logged in',
                                  color: own.source1,
                                  style: style,
                                ),
                              for (final source in sources)
                                _state(source, style, compact: false),
                            ],
                          ),
                  ),
                  const SizedBox(width: 12),
                  if (loginNeeded)
                    LogInButton(account: account)
                  else
                    Tooltip(
                      message: checking == null
                          ? ''
                          : checking.searching
                          ? 'Looking for the right version of songs whose '
                                'VK file changed: ${checking.done} of '
                                '${checking.total}'
                          : "Checking each song's file on VK for a changed "
                                'recording: ${checking.done} of '
                                '${checking.total}',
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: own.text,
                          side: BorderSide(color: own.line),
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(
                            fontFamily: appFontFamily,
                            fontSize: 13,
                          ),
                        ),
                        key: const ValueKey('sync-now'),
                        onPressed: sync.canSync && !sync.running
                            ? sync.syncNow
                            : null,
                        icon: const Icon(Icons.sync, size: 16),
                        label: Text(
                          checking != null
                              ? 'Checking files '
                                    '${(checking.fraction * 100).round()}%'
                              : sync.running
                              ? 'Syncing $percent%'
                              : 'Sync now',
                        ),
                      ),
                    ),
                  if (account != null &&
                      (account.loggedIn || sources.isNotEmpty))
                    IconButton(
                      key: const ValueKey('vk-accounts'),
                      tooltip: 'VK accounts',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.manage_accounts_outlined,
                        color: own.dim,
                      ),
                      onPressed: () => showAccountsDialog(
                        context,
                        accounts: account,
                        sync: sync,
                        sources: this.sources,
                      ),
                    ),
                ],
              ),
            ),
            if (fraction != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(
                  key: ValueKey(
                    progress != null ? 'sync-progress' : 'file-check-progress',
                  ),
                  value: fraction,
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
  const LogInButton({
    super.key,
    required this.account,
    this.buttonKey = const ValueKey('vk-log-in'),
    this.label = 'Log in to VK',
  });

  final VkAccounts account;
  final Key buttonKey;

  /// What the button says while the window is closed.
  final String label;

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
      key: buttonKey,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontFamily: appFontFamily, fontSize: 13),
      ),
      onPressed: () => _logIn(context),
      icon: const Icon(Icons.login, size: 16),
      label: Text(account.loggingIn ? 'Logging in...' : label),
    );
  }
}

/// One source in the status bar: a dot, its name and its state.
class _SourceState extends StatelessWidget {
  const _SourceState({
    super.key,
    required this.name,
    required this.state,
    required this.color,
    required this.style,
    this.failed = false,
  });

  final String name;
  final String state;

  /// The source's own color.
  final Color color;
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
            color: failed ? colors.error : color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style?.copyWith(color: colors.onSurface),
          ),
        ),
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
