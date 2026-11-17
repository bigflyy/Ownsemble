/// What a person does to the account's VK playlists from the app (plan 08,
/// C4): add a song (a second menu with New playlist... and the made
/// playlists, one that has the song greyed), take a song out (an Undo bar,
/// sent when it closes), rename, delete (asked first), unfollow (an Undo
/// bar), and make a new playlist. The work is [VkPlaylists]'; this file
/// holds the menus, dialogs and bars.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/library_records.dart';
import '../library/track.dart';
import '../vk/vk_playlists.dart';
import 'albums.dart';
import 'playlists.dart';

/// How long an Undo bar of a playlist edit stays, as removing a song's.
const playlistUndoTime = Duration(seconds: 6);

/// Says [note] in the bar at the bottom, in place of the one there.
void showPlaylistNote(ScaffoldMessengerState messenger, String note) {
  if (note.isEmpty) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(note)));
}

/// Shows [note] with Undo; Undo takes [held] back, the bar closing any
/// other way sends it to VK (a note follows only when VK did not take it).
void showHeldEdit(
  ScaffoldMessengerState messenger,
  String note,
  HeldEdit held,
) {
  messenger.hideCurrentSnackBar();
  final bar = messenger.showSnackBar(
    SnackBar(
      content: Text(note),
      duration: playlistUndoTime,
      // A note with an action stays until closed unless told not to.
      persist: false,
      action: SnackBarAction(
        key: const ValueKey('playlist-undo'),
        label: 'Undo',
        onPressed: held.undo,
      ),
    ),
  );
  unawaited(
    bar.closed.then((reason) async {
      if (reason == SnackBarClosedReason.action) return;
      final edit = await held.commit();
      if (!edit.ok) showPlaylistNote(messenger, edit.note);
    }),
  );
}

/// The accounts whose playlists can be changed now (logged in).
List<SourceInfo> _editingAccounts(VkPlaylists playlists) => [
  for (final account in playlists.accounts())
    if (playlists.apiOfSource(account.id) != null) account,
];

/// Whether [track] can go into a VK playlist: a VK song and an account to
/// write with.
bool canAddToPlaylist(VkPlaylists? playlists, Track track) =>
    playlists != null &&
    track.source == TrackSource.vk &&
    _editingAccounts(playlists).isNotEmpty;

/// The second menu of "Add to playlist...", at [position]: New playlist...
/// and the made playlists of each account (a heading per account when
/// there are two), one that has [track] greyed with "already in". Says in
/// the bar what happened.
Future<void> showAddToPlaylist(
  BuildContext context, {
  required VkPlaylists playlists,
  required Track track,
  required Offset position,
}) async {
  final accounts = _editingAccounts(playlists);
  final several = accounts.length > 1;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showMenu<({int sourceId, String? key})>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
    items: [
      const PopupMenuItem(enabled: false, height: 28, child: Text('Add to')),
      for (final account in accounts) ...[
        if (several)
          PopupMenuItem(
            enabled: false,
            height: 28,
            child: Text(
              account.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        PopupMenuItem(
          key: ValueKey('new-playlist-${account.id}'),
          value: (sourceId: account.id, key: null),
          child: const Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 8),
              Text('New playlist...'),
            ],
          ),
        ),
        for (final list in playlists.editableOf(account.id))
          _listItem(playlists, account.id, list, track),
      ],
    ],
  );
  if (choice == null || !context.mounted) return;
  if (choice.key case final key?) {
    final edit = await playlists.addSong(choice.sourceId, key, track);
    showPlaylistNote(messenger, edit.note);
    return;
  }
  final name = await askPlaylistName(context);
  if (name == null) return;
  final edit = await playlists.create(choice.sourceId, name, first: track);
  showPlaylistNote(messenger, edit.note);
}

PopupMenuItem<({int sourceId, String? key})> _listItem(
  VkPlaylists playlists,
  int sourceId,
  VkPlaylist list,
  Track track,
) {
  final has = playlists.hasSong(list.key, track);
  return PopupMenuItem(
    key: ValueKey('add-to-playlist-${list.key}'),
    value: (sourceId: sourceId, key: list.key),
    enabled: !has,
    child: Row(
      children: [
        Expanded(child: Text(list.title, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        Text(has ? 'already in' : '${playlists.songsOf(list.key).length}'),
      ],
    ),
  );
}

/// Takes the entry [songKey] out of the playlist [ref] now, with an Undo
/// bar; VK is told when the bar closes.
void removeFromPlaylist(
  BuildContext context, {
  required VkPlaylists playlists,
  required AlbumRef ref,
  required String songKey,
}) {
  final list = playlists.playlistOf(ref);
  if (list == null) return;
  final held = playlists.removeSong(ref.link!.sourceId, list.key, songKey);
  showHeldEdit(
    ScaffoldMessenger.of(context),
    'Taken out of ${list.title}',
    held,
  );
}

/// Asks for a playlist's name; null when cancelled or empty.
Future<String?> askPlaylistName(
  BuildContext context, {
  String initial = '',
  String title = 'New playlist',
  String action = 'Make',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) =>
        _PlaylistNameDialog(initial: initial, title: title, action: action),
  );
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.initial,
    required this.title,
    required this.action,
  });

  final String initial;
  final String title;
  final String action;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('playlist-name'),
      controller: _name,
      autofocus: true,
      maxLength: 128,
      decoration: const InputDecoration(hintText: 'Name'),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('playlist-name-ok'),
        onPressed: () => Navigator.pop(context, _name.text),
        child: Text(widget.action),
      ),
    ],
  );
}

/// The menu button of an open playlist's heading: Rename and Delete for
/// one the account made, Unfollow for a followed one. [onGone] leaves the
/// place (after Delete or Unfollow).
class PlaylistHeadingMenu extends StatelessWidget {
  const PlaylistHeadingMenu({
    super.key,
    required this.playlists,
    required this.ref,
    required this.onGone,
  });

  final VkPlaylists playlists;
  final AlbumRef ref;
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) {
    final list = playlists.playlistOf(ref);
    if (list == null || playlists.apiOfSource(ref.link!.sourceId) == null) {
      return const SizedBox.shrink();
    }
    final made = list.editable && list.kind == VkPlaylistKind.made;
    return PopupMenuButton<String>(
      key: const ValueKey('playlist-menu'),
      tooltip: 'Playlist',
      icon: const Icon(Icons.more_horiz),
      itemBuilder: (context) => [
        if (made) ...[
          const PopupMenuItem(
            key: ValueKey('playlist-rename'),
            value: 'rename',
            child: Text('Rename...'),
          ),
          const PopupMenuItem(
            key: ValueKey('playlist-delete'),
            value: 'delete',
            child: Text('Delete...'),
          ),
        ] else
          const PopupMenuItem(
            key: ValueKey('playlist-unfollow'),
            value: 'unfollow',
            child: Text('Unfollow'),
          ),
      ],
      onSelected: (choice) => _act(context, list, choice),
    );
  }

  Future<void> _act(
    BuildContext context,
    VkPlaylist list,
    String choice,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final sourceId = ref.link!.sourceId;
    switch (choice) {
      case 'rename':
        final name = await askPlaylistName(
          context,
          initial: list.title,
          title: 'Rename playlist',
          action: 'Rename',
        );
        if (name == null || name == list.title) return;
        final edit = await playlists.rename(sourceId, list.key, name);
        if (!edit.ok) showPlaylistNote(messenger, edit.note);
      case 'delete':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete ${list.title}?'),
            content: const Text(
              'It is deleted on VK too and cannot come back. Its songs stay '
              'in your library.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('playlist-delete-yes'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (sure != true) return;
        onGone();
        final edit = await playlists.delete(sourceId, list.key);
        showPlaylistNote(messenger, edit.note);
      case 'unfollow':
        final held = playlists.unfollow(sourceId, list.key);
        onGone();
        showHeldEdit(messenger, 'Unfollowed ${list.title}', held);
    }
  }
}

/// The Playlists page's "New playlist" button (one per account when there
/// are two): asks for a name, makes it on VK and opens it.
class NewPlaylistButton extends StatelessWidget {
  const NewPlaylistButton({
    super.key,
    required this.playlists,
    required this.onMade,
  });

  final VkPlaylists playlists;

  /// Opens the new playlist.
  final void Function(AlbumRef ref) onMade;

  @override
  Widget build(BuildContext context) {
    final accounts = _editingAccounts(playlists);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final several = accounts.length > 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final account in accounts)
          TextButton.icon(
            key: ValueKey('playlists-new-${account.id}'),
            onPressed: () => _make(context, account),
            icon: const Icon(Icons.add, size: 18),
            label: Text(
              several ? 'New playlist on ${account.name}' : 'New playlist',
            ),
          ),
      ],
    );
  }

  Future<void> _make(BuildContext context, SourceInfo account) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await askPlaylistName(context);
    if (name == null) return;
    final edit = await playlists.create(account.id, name);
    if (!edit.ok) {
      showPlaylistNote(messenger, edit.note);
      return;
    }
    final made = playlists
        .allOf(account.id)
        .where((list) => list.key == edit.key)
        .firstOrNull;
    if (made != null) onMade(playlists.refOf(account.id, made));
  }
}
