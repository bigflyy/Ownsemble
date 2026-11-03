import 'package:flutter/material.dart';

import '../library/library_store.dart';
import 'source_editor.dart';
import 'sync_controller.dart';
import 'sync_status_bar.dart';
import 'theme.dart';
import 'vk_accounts.dart';

/// Opens the list of VK accounts: add one, or rename, recolor, log out of or
/// remove one.
Future<void> showAccountsDialog(
  BuildContext context, {
  required VkAccounts accounts,
  required SyncController sync,
  required SourceEditor? sources,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
      child: ListenableBuilder(
        listenable: Listenable.merge([accounts, sync]),
        builder: (context, _) =>
            _AccountList(accounts: accounts, sync: sync, sources: sources),
      ),
    ),
  ),
);

class _AccountList extends StatelessWidget {
  const _AccountList({
    required this.accounts,
    required this.sync,
    required this.sources,
  });

  final VkAccounts accounts;
  final SyncController sync;
  final SourceEditor? sources;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final known = sync.syncedSources;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'VK accounts',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Each account syncs into one library. A song in several accounts '
            'shows once.',
            style: TextStyle(fontSize: 13, color: colors.dim),
          ),
          const SizedBox(height: 12),
          if (known.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                accounts.loggedIn
                    ? 'Syncing the account for the first time.'
                    : 'No account yet.',
                style: TextStyle(fontSize: 14, color: colors.dim),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final source in known)
                    _AccountRow(
                      key: ValueKey('account-${source.id}'),
                      source: source,
                      accounts: accounts,
                      sync: sync,
                      sources: sources,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              LogInButton(
                account: accounts,
                buttonKey: const ValueKey('vk-add-account'),
                label: 'Add VK account',
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey('accounts-close'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _AccountAction { rename, logOut, remove }

/// One account: its color, name and state, and its menu.
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    super.key,
    required this.source,
    required this.accounts,
    required this.sync,
    required this.sources,
  });

  final SourceInfo source;
  final VkAccounts accounts;
  final SyncController sync;
  final SourceEditor? sources;

  Future<void> _act(BuildContext context, _AccountAction action) async {
    switch (action) {
      case _AccountAction.rename:
        final name = await _askName(context, source.name);
        if (name != null) sources?.rename(source.id, name);
      case _AccountAction.logOut:
        accounts.logOut(source.account);
      case _AccountAction.remove:
        if (!await _confirmRemove(context, source)) return;
        if (accounts.hasSession(source.account)) {
          accounts.logOut(source.account);
        }
        await sources?.remove(source.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final loggedIn = accounts.hasSession(source.account);
    final state = describeSourceState(
      source,
      lastResult: sync.lastOutcome?.resultOf(source.id),
      now: DateTime.now(),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          PopupMenuButton<int>(
            key: ValueKey('account-color-${source.id}'),
            tooltip: 'Color',
            enabled: sources != null,
            onSelected: (color) => sources?.setColor(source.id, color),
            itemBuilder: (context) => [
              for (var slot = 1; slot <= sourceColorCount; slot++)
                PopupMenuItem(
                  key: ValueKey('account-color-${source.id}-$slot'),
                  value: slot,
                  height: 36,
                  child: _ColorDot(colors.sourceColor(slot), size: 14),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: _ColorDot(colors.sourceColor(source.color), size: 14),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  loggedIn ? state : 'not logged in · $state',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.dim),
                ),
              ],
            ),
          ),
          PopupMenuButton<_AccountAction>(
            key: ValueKey('account-menu-${source.id}'),
            tooltip: 'Account',
            icon: Icon(Icons.more_vert, size: 18, color: colors.dim),
            onSelected: (action) => _act(context, action),
            itemBuilder: (context) => [
              const PopupMenuItem(
                key: ValueKey('account-rename'),
                value: _AccountAction.rename,
                child: Text('Rename...'),
              ),
              if (loggedIn)
                const PopupMenuItem(
                  key: ValueKey('vk-log-out'),
                  value: _AccountAction.logOut,
                  child: Text('Log out'),
                ),
              const PopupMenuItem(
                key: ValueKey('account-remove'),
                value: _AccountAction.remove,
                child: Text('Remove from the library...'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot(this.color, {required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Asks for a new name; null when the user cancels.
Future<String?> _askName(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(current: current),
    );

/// Owns its text field's controller, because the field outlives the answer:
/// it stays on screen through the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.current});

  final String current;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _text = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Account name'),
    content: TextField(
      key: const ValueKey('account-name'),
      controller: _text,
      autofocus: true,
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('account-name-save'),
        onPressed: () => Navigator.of(context).pop(_text.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Asks before an account leaves the library; it says what stays.
Future<bool> _confirmRemove(BuildContext context, SourceInfo source) async {
  final remove = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove ${source.name}?'),
      content: Text(
        'Its ${source.songCount} songs leave this library. Songs that are also '
        'in another account stay, and so do songs in History, on a Stack or '
        'stored on this computer. Nothing changes on VK.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('account-remove-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return remove ?? false;
}
