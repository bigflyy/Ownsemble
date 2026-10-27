import 'package:flutter/material.dart';

import '../services/app_controller.dart';

/// Show background sync in its own control, independent of player buffering.
class LibrarySyncControl extends StatefulWidget {
  final AppController controller;
  const LibrarySyncControl({super.key, required this.controller});

  @override
  State<LibrarySyncControl> createState() => _LibrarySyncControlState();
}

class _LibrarySyncControlState extends State<LibrarySyncControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void dispose() {
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final animate = c.syncing && !MediaQuery.disableAnimationsOf(context);
    if (animate && !spin.isAnimating) spin.repeat();
    if (!animate && spin.isAnimating) spin.stop();
    if (!animate && spin.value != 0) spin.value = 0;
    final label = c.syncing && c.syncActivity.phase == 'cancelled'
        ? 'Stopping sync'
        : c.offline
        ? 'Offline'
        : c.syncActivity.label;
    final icon = c.syncing
        ? Icons.sync_rounded
        : c.offline
        ? Icons.sync_disabled_rounded
        : switch (c.syncActivity.phase) {
            'failed' => Icons.sync_problem_rounded,
            'partial' => Icons.info_outline_rounded,
            'succeeded' => Icons.task_alt_rounded,
            _ => Icons.sync_rounded,
          };
    return IconButton(
      key: const ValueKey('library-sync-control'),
      tooltip: 'VK sync: $label',
      onPressed: () => showLibrarySyncStatus(context, c),
      icon: RotationTransition(turns: spin, child: Icon(icon, size: 21)),
    );
  }
}

/// Open a live, read-only summary; only explicit actions request provider work.
Future<void> showLibrarySyncStatus(
  BuildContext context,
  AppController c,
) => showDialog<void>(
  context: context,
  builder: (context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final activity = c.syncActivity;
      final canSync =
          !c.demo &&
          !c.offline &&
          c.provider.connected &&
          !c.syncPending &&
          !c.connecting;
      final stopping = c.syncing && activity.phase == 'cancelled';
      final stamp = activity.finishedAt?.toLocal();
      final locale = MaterialLocalizations.of(context);
      return _StatusPanel(
        title: 'VK sync',
        children: [
          Text(
            stopping ? 'Stopping sync' : activity.label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (activity.phase != 'idle')
            Text(
              '${activity.checked} ${activity.active ? 'received' : 'checked'} · ${activity.added} new',
            ),
          if (stamp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Last attempt: ${locale.formatShortDate(stamp)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(stamp))}',
              ),
            ),
          if (activity.phase == 'failed')
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(activity.failureHint),
            ),
          const SizedBox(height: 16),
          Text(c.libraryCoverageSummary),
          if (c.syncPending && !c.syncing)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'The full scan will continue shortly. You can stop it below.',
              ),
            ),
          const SizedBox(height: 12),
          Text(
            c.offline
                ? 'Offline mode. Saved music stays available.'
                : !c.provider.connected
                ? 'Connect VK to check for music.'
                : 'Check newest is a short check. Scan full library can take longer and keeps your saved music.',
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: canSync ? c.checkNewest : null,
                child: const Text('Check newest'),
              ),
              OutlinedButton(
                onPressed: canSync ? () => c.refresh(full: true) : null,
                child: const Text('Scan full library'),
              ),
              if (c.syncPending)
                TextButton(
                  onPressed: stopping ? null : c.cancelSync,
                  child: const Text('Stop sync'),
                ),
            ],
          ),
        ],
      );
    },
  ),
);

/// Make connection state actionable without disconnecting on the badge click.
class LibraryConnectionControl extends StatelessWidget {
  final AppController controller;
  const LibraryConnectionControl({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final label = c.demo
        ? 'PREVIEW'
        : c.offline
        ? 'OFFLINE'
        : c.connecting
        ? 'CONNECTING'
        : c.provider.connected
        ? 'VK CONNECTED'
        : 'LOCAL LIBRARY';
    return OutlinedButton(
      key: const ValueKey('library-connection-control'),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => ListenableBuilder(
          listenable: c,
          builder: (context, _) => _StatusPanel(
            title: 'VK connection',
            children: [
              Text(
                c.connecting
                    ? 'Connecting to VK'
                    : c.offline
                    ? 'Offline mode'
                    : c.provider.connected
                    ? 'VK is connected'
                    : 'VK is not connected',
              ),
              const SizedBox(height: 12),
              const Text(
                'Disconnecting stops VK requests and switches to offline mode. Saved music and private sign-in are retained.',
              ),
              if (c.connectionError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(friendlyError(c.connectionError!)),
                ),
              if (c.demo)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'This preview uses generated music. Open the regular app to connect VK.',
                  ),
                ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: c.demo || c.connecting || c.syncing
                        ? null
                        : c.connectVk,
                    child: Text(
                      c.provider.connected && !c.offline
                          ? 'Reconnect VK'
                          : 'Connect VK',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: c.demo || c.connecting || !c.provider.connected
                        ? null
                        : c.disconnectVk,
                    child: const Text('Disconnect VK'),
                  ),
                  TextButton(
                    onPressed: c.demo || c.connecting
                        ? null
                        : () {
                            Navigator.pop(context);
                            c.signInVk();
                          },
                    child: const Text('Sign in privately'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'After private sign-in, return here and choose Connect VK.',
              ),
            ],
          ),
        ),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: Theme.of(context).textTheme.labelSmall
            ?.copyWith(fontSize: 10, fontWeight: FontWeight.w600),
        side: const BorderSide(color: Colors.white10),
      ),
      child: Text(label),
    );
  }
}

/// Keep status surfaces compact, keyboard-dismissible and scrollable at large text sizes.
class _StatusPanel extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _StatusPanel({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Theme.of(context).popupMenuTheme.color,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: Colors.white10),
    ),
    alignment: Alignment.topRight,
    insetPadding: const EdgeInsets.fromLTRB(24, 84, 34, 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 390,
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close status (Escape)',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    ),
  );
}
