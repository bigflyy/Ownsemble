import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../storage/audio_storage.dart';
import 'collections_controller.dart';
import 'library_controller.dart';
import 'player_bar.dart';
import 'shell_settings.dart';
import 'sidebar.dart';
import 'sync_controller.dart';
import 'sync_status_bar.dart';
import 'theme.dart';

/// Height of one song row; fixed so the list can skip layout of hidden rows.
const rowHeight = 58.0;

/// Narrower than this, the side panel gives way to the bottom bar.
const sidePanelMinWidth = 980.0;

/// Narrower than this, the sidebar is always a rail.
const fullSidebarMinWidth = 720.0;

/// The B2 window: sidebar, search and the song list, the player as a side
/// panel or bottom bar, and the sync status bar at the bottom.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.playback,
    this.sync,
    this.collections,
    this._settings,
  });

  final LibraryController library;
  final PlaybackController playback;

  PlayerService get player => playback.player;

  /// Sync state for the status bar; no status bar when null.
  final SyncController? sync;

  /// History and Stacks; without them those views stay empty.
  final CollectionsController? collections;

  final ShellSettings? _settings;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchFocus = FocusNode();
  final _subscriptions = <StreamSubscription<Object?>>[];
  late final ShellSettings _settings =
      widget._settings ?? ShellSettings.inMemory();

  LibraryController get library => widget.library;
  AudioStorage? get _storage => widget.player.storage;

  @override
  void initState() {
    super.initState();
    // A song that cannot play says why at the bottom of the window.
    _subscriptions.add(
      widget.player.timings.listen((timing) {
        final error = timing.error;
        if (timing.ok || error == null || error == 'superseded' || !mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Cannot play: $error')));
      }),
    );
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// App-wide keys. Handled before focus routing, so they work wherever the
  /// focus is, including nowhere after clicking a song.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    // The physical key, so Ctrl+F also works with the Russian layout, where
    // the same key types "а".
    if (event.physicalKey == PhysicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed) {
      _searchFocus.requestFocus();
      library.searchText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: library.searchText.text.length,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.escape &&
        library.searchText.text.isNotEmpty) {
      library.searchText.clear();
      return true;
    }
    // Media keys of keyboards and headsets.
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      widget.playback.playOrPause();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      widget.playback.next();
      return true;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      widget.playback.previous();
      return true;
    }
    // Space plays or pauses, except while typing in a text field.
    if (key == LogicalKeyboardKey.space && !_typing) {
      widget.playback.playOrPause();
      return true;
    }
    return false;
  }

  /// Whether the keyboard focus is in a text field.
  bool get _typing =>
      FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  /// Plays the visible song at [index], with the visible list as the list
  /// next and previous move in; clicking the song that is already loaded
  /// pauses or resumes it instead of restarting it.
  void _play(int index) => widget.playback.playFrom(library.visible, index);

  /// A song's right-click menu: Play next and Add to queue, Download or
  /// Remove download, put on top of a Stack, and in a Stack, remove this
  /// entry.
  Future<void> _showSongMenu(int index, Offset position) async {
    final track = library.visible[index];
    final entryId = library.entryIdAt(index);
    final storage = _storage;
    final collections = widget.collections;
    final downloaded = storage?.stateOf(track).pinned ?? false;
    final inStack = library.view.kind == ViewKind.stack && entryId != null;
    final choice = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          key: ValueKey('menu-play-next'),
          value: 'play-next',
          child: Text('Play next'),
        ),
        const PopupMenuItem(
          key: ValueKey('menu-add-to-queue'),
          value: 'add-to-queue',
          child: Text('Add to queue'),
        ),
        if (storage != null || inStack) const PopupMenuDivider(),
        if (storage != null && !downloaded)
          const PopupMenuItem(
            key: ValueKey('menu-download'),
            value: 'download',
            child: Text('Download'),
          ),
        if (storage != null && downloaded)
          const PopupMenuItem(
            key: ValueKey('menu-remove-download'),
            value: 'remove',
            child: Text('Remove download'),
          ),
        if (inStack)
          const PopupMenuItem(
            key: ValueKey('menu-remove-from-stack'),
            value: 'unstack',
            child: Text('Remove from this Stack'),
          ),
        if (collections != null) ...[
          const PopupMenuDivider(),
          ...stackMenuItems(collections),
        ],
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'play-next':
        await widget.playback.playNext(track);
      case 'add-to-queue':
        await widget.playback.addToQueue(track);
      case 'download':
        final messenger = ScaffoldMessenger.of(context);
        final error = await widget.playback.download(track);
        if (error != null) {
          messenger.showSnackBar(
            SnackBar(content: Text('Download failed: $error')),
          );
        }
      case 'remove':
        widget.playback.removeDownload(track);
      case 'unstack':
        collections!.removeStackEntry(entryId!);
      case final int stackChoice:
        await addToStackChoice(context, collections!, track, stackChoice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final roomForPanel = width >= sidePanelMinWidth;
          final roomForSidebar = width >= fullSidebarMinWidth;
          final sidePanel = roomForPanel && _settings.dock == PlayerDock.side;
          final colors = OwnColors.of(context);
          final rail = _settings.rail || !roomForSidebar;
          // Messages ("Cannot play: ...") float over the song list only:
          // the insets keep them off the sidebar and the side panel, and
          // the bottom bar below is the Scaffold's, so they sit above it.
          // Covering the player for 4 s ate clicks on the seek bar.
          final theme = Theme.of(context);
          final messages = theme.snackBarTheme.copyWith(
            insetPadding: EdgeInsets.fromLTRB(
              (rail ? railWidth : sidebarWidth) + 16,
              0,
              (sidePanel ? sidePanelWidth : 0) + 16,
              16,
            ),
          );
          return Theme(
            data: theme.copyWith(snackBarTheme: messages),
            child: Scaffold(
              backgroundColor: colors.bg,
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!sidePanel)
                    DockBar(
                      playback: widget.playback,
                      collections: widget.collections,
                      thumbnails: _settings.thumbnails,
                      canDockSide: roomForPanel,
                      onDockSide: () => _settings.dockTo(PlayerDock.side),
                      compact: !roomForSidebar,
                    ),
                  if (widget.sync case final sync?) SyncStatusBar(sync: sync),
                ],
              ),
              body: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            library,
                            ?widget.collections,
                            ?_storage,
                          ]),
                          builder: (context, _) => Sidebar(
                            library: library,
                            collections: widget.collections,
                            downloads: _downloadCount(),
                            rail: rail,
                            canExpand: roomForSidebar,
                            onToggleRail: _settings.toggleRail,
                          ),
                        ),
                        Expanded(child: _main(colors)),
                        if (sidePanel)
                          NowPlayingPanel(
                            playback: widget.playback,
                            collections: widget.collections,
                            thumbnails: _settings.thumbnails,
                            onDockBottom: () =>
                                _settings.dockTo(PlayerDock.bottom),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  int _downloadCount() {
    final storage = _storage;
    var count = 0;
    for (final track in library.all) {
      if (storage == null
          ? track.isDownloaded
          : storage.stateOf(track).pinned) {
        count++;
      }
    }
    return count;
  }

  /// Search and toggles, the view's title, and its songs.
  Widget _main(OwnColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: _SearchField(
                      controller: library.searchText,
                      focusNode: _searchFocus,
                      onSubmitted: () {
                        if (library.visible.isNotEmpty) _play(0);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                key: const ValueKey('toggle-thumbnails'),
                tooltip: 'Thumbnails on or off',
                isSelected: _settings.thumbnails,
                style: IconButton.styleFrom(
                  backgroundColor: _settings.thumbnails
                      ? colors.accentBg
                      : null,
                  foregroundColor: _settings.thumbnails
                      ? colors.accent
                      : colors.dim,
                ),
                onPressed: _settings.toggleThumbnails,
                icon: const Icon(Icons.grid_view_rounded),
              ),
              IconButton(
                key: const ValueKey('toggle-theme'),
                tooltip: _settings.dark
                    ? 'Switch to light theme'
                    : 'Switch to dark theme',
                onPressed: _settings.toggleTheme,
                icon: Icon(
                  _settings.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              library,
              ?_storage,
              ?widget.collections,
            ]),
            builder: (context, _) {
              final view = library.view;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ViewHeading(
                    title: _viewTitle(view),
                    count: view.isLater
                        ? null
                        : library.visible.length == library.viewCount
                        ? '${library.viewCount} songs'
                        : '${library.visible.length} of '
                              '${library.viewCount} songs',
                  ),
                  Expanded(
                    child: view.isLater
                        ? _LaterPage(view: view)
                        : _songList(colors),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  String _viewTitle(LibraryView view) => switch (view.kind) {
    ViewKind.songs => 'All songs',
    ViewKind.artists => 'Artists',
    ViewKind.downloads => 'Downloads',
    ViewKind.stack =>
      widget.collections?.stacks
              .where((s) => s.id == view.stackId)
              .firstOrNull
              ?.name ??
          'Stacks',
    ViewKind.playlists => 'Playlists',
    ViewKind.history => 'History',
    ViewKind.charts => 'Charts',
  };

  Widget _songList(OwnColors colors) {
    if (library.visible.isEmpty) {
      final empty = library.searchText.text.isNotEmpty
          ? 'No songs match "${library.searchText.text}"'
          : switch (library.view.kind) {
              ViewKind.downloads =>
                'No downloads yet. Right-click a song and choose Download '
                    'to keep it on this computer.',
              ViewKind.history => 'Songs you play show up here.',
              ViewKind.stack =>
                'Put songs on top of a Stack from the player or a song\'s '
                    'right-click menu.',
              _ => 'No songs yet.',
            };
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Text(
          empty,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: colors.dim),
        ),
      );
    }
    return StreamBuilder<Track?>(
      stream: widget.player.currentStream,
      initialData: widget.player.current,
      builder: (context, current) => ValueListenableBuilder(
        valueListenable: widget.player.playing,
        builder: (context, playing, _) => Scrollbar(
          controller: library.scroll,
          child: ListView.builder(
            controller: library.scroll,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            itemExtent: rowHeight,
            itemCount: library.visible.length,
            itemBuilder: (context, index) {
              final track = library.visible[index];
              final entryId = library.entryIdAt(index);
              return _SongRow(
                key: ValueKey(
                  entryId == null ? 'song-${track.id}' : 'entry-$entryId',
                ),
                number: index + 1,
                track: track,
                stored:
                    _storage?.stateOf(track) ??
                    (path: track.localPath, pinned: track.pinned),
                downloading: _storage?.isDownloading(track) ?? false,
                thumbnails: _settings.thumbnails,
                isCurrent: track.id == current.data?.id,
                playing: playing,
                onTap: () => _play(index),
                onMenu: (position) => _showSongMenu(index, position),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The search box: a pill with the Ctrl F hint and a clear button.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide(color: colors.line),
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: colors.surface,
        hintText: 'Search artist, title or album',
        hintStyle: TextStyle(color: colors.dim2),
        prefixIcon: Icon(Icons.search, color: colors.dim2, size: 20),
        suffixIcon: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear search (Esc)',
                  onPressed: controller.clear,
                  icon: Icon(Icons.close, size: 18, color: colors.dim),
                ),
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: colors.line),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  'Ctrl F',
                  style: TextStyle(fontSize: 11, color: colors.dim),
                ),
              ),
            ],
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: colors.accent),
        ),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}

class _ViewHeading extends StatelessWidget {
  const _ViewHeading({required this.title, required this.count});

  final String title;
  final String? count;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 10),
            Text(count!, style: TextStyle(fontSize: 13, color: colors.dim)),
          ],
        ],
      ),
    );
  }
}

/// A view planned after the MVP: says what it will hold.
class _LaterPage extends StatelessWidget {
  const _LaterPage({required this.view});

  final LibraryView view;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final text = switch (view.kind) {
      ViewKind.artists =>
        'Every artist with their songs from all sources, and a page per '
            'artist. Planned after the MVP.',
      ViewKind.playlists =>
        'Ordered lists you arrange and edit freely, next to Stacks, which '
            'only grow on top. Planned after the MVP; this page will host '
            'them.',
      _ =>
        'Listening stats from History, for example top artists per month. '
            'Planned after the MVP; charts get the whole page, not a list.',
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, height: 1.5, color: colors.dim),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    super.key,
    required this.number,
    required this.track,
    required this.stored,
    required this.downloading,
    required this.thumbnails,
    required this.isCurrent,
    required this.playing,
    required this.onTap,
    required this.onMenu,
  });

  /// Position in the list, shown when thumbnails are off.
  final int number;
  final Track track;

  /// How the song's audio is stored now (may be newer than [track]).
  final StoredState stored;
  final bool downloading;
  final bool thumbnails;
  final bool isCurrent;

  /// Whether the player is playing (not paused), for the current row.
  final bool playing;
  final VoidCallback onTap;

  /// Opens the song's menu at a position on screen (right click).
  final void Function(Offset position) onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    // A song gone from VK without stored audio cannot play: shown faded.
    final unplayable = track.isGone && stored.path == null;
    final (icon, meaning) = switch (stored) {
      _ when downloading => (Icons.downloading, 'Downloading'),
      (path: String _, pinned: true) => (
        Icons.download_done,
        'Downloaded: kept until you remove it',
      ),
      (path: String _, pinned: false) => (
        Icons.cloud_done_outlined,
        'Cached: plays without the network',
      ),
      _ when track.source == TrackSource.vk => (
        Icons.cloud_outlined,
        'Streams from VK',
      ),
      _ => (Icons.music_note_outlined, 'Generated test song'),
    };
    final dimStyle = TextStyle(fontSize: 13, color: colors.dim);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: isCurrent ? colors.accentBg : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: colors.hover,
          onTap: onTap,
          onSecondaryTapUp: (details) => onMenu(details.globalPosition),
          child: Opacity(
            opacity: unplayable ? 0.5 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: thumbnails
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              TrackTile(track: track, size: 44, radius: 8),
                              if (isCurrent)
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: const Color(0x990A0C10),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    playing
                                        ? Icons.graphic_eq
                                        : Icons.pause_rounded,
                                    size: 18,
                                    color: Colors.white,
                                  ),
                                ),
                            ],
                          )
                        : Align(
                            alignment: Alignment.centerRight,
                            child: isCurrent
                                ? Icon(
                                    playing
                                        ? Icons.graphic_eq
                                        : Icons.pause_rounded,
                                    size: 16,
                                    color: colors.accent,
                                  )
                                : Text(
                                    '$number',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: colors.dim2,
                                    ),
                                  ),
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 16,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: isCurrent ? colors.currentText : null,
                          ),
                        ),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: dimStyle,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Album, with the gone and filler tags at its end, so
                  // a tag never shifts the columns. In a narrow column the
                  // tags shrink to an icon with the same explanation.
                  Expanded(
                    flex: 10,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final roomy = box.maxWidth >= 150;
                        return Row(
                          children: [
                            Expanded(
                              child: Text(
                                track.album ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: dimStyle,
                              ),
                            ),
                            if (track.isGone) ...[
                              const SizedBox(width: 8),
                              _Tag(
                                key: const ValueKey('gone-tag'),
                                label: 'gone from VK',
                                icon: Icons.cloud_off_outlined,
                                compact: !roomy,
                                explanation: stored.path != null
                                    ? 'VK no longer has this song. It stays '
                                          'in your library and plays from the '
                                          'stored copy.'
                                    : 'VK no longer has this song. It stays '
                                          'in your library, History and '
                                          'Stacks, but there is no stored '
                                          'copy to play.',
                              ),
                            ],
                            if (track.source == TrackSource.generated) ...[
                              const SizedBox(width: 8),
                              _Tag(
                                key: const ValueKey('filler-tag'),
                                label: 'filler',
                                icon: Icons.science_outlined,
                                compact: !roomy,
                                explanation:
                                    'Generated speed-test song: made-up '
                                    'name, plays one of a few cached real '
                                    'songs.',
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 14),
                  Tooltip(
                    message: meaning,
                    child: Icon(
                      icon,
                      key: ValueKey('mark-${track.id}-${icon.codePoint}'),
                      size: 18,
                      color: sourceColor(colors, track),
                    ),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 44,
                    child: Text(
                      formatDuration(Duration(seconds: track.durationSec)),
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 13, color: colors.dim2),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small outlined label on a song row, explained on hover.
class _Tag extends StatelessWidget {
  const _Tag({
    super.key,
    required this.label,
    required this.explanation,
    required this.icon,
    this.compact = false,
  });

  final String label;
  final String explanation;

  /// Shown instead of the label when [compact].
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Tooltip(
      message: explanation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(6),
        ),
        child: compact
            ? Icon(icon, size: 13, color: colors.dim)
            : Text(
                label,
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: colors.dim),
              ),
      ),
    );
  }
}
