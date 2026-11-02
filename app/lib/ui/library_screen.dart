import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import '../playback/player_service.dart';
import '../storage/audio_storage.dart';
import 'collections_controller.dart';
import 'cover_tile.dart';
import 'cover_viewer.dart';
import 'filling_icon.dart';
import 'library_controller.dart';
import 'player_bar.dart';
import 'shell_settings.dart';
import 'shortcuts_help.dart';
import 'sidebar.dart';
import 'sync_controller.dart';
import 'sync_status_bar.dart';
import 'theme.dart';
import 'type_jump.dart';
import 'vk_account.dart';

/// Narrower than this, the side panel gives way to the bottom bar.
const sidePanelMinWidth = 980.0;

/// Narrower than this, the sidebar is always a rail.
const fullSidebarMinWidth = 720.0;

/// How far Left and Right move within a song.
const seekKeyStep = Duration(seconds: 5);

/// How far Up and Down move the volume.
const volumeKeyStep = 5.0;

/// The B2 window: sidebar, search and the song list, the player as a side
/// panel or bottom bar, and the sync status bar at the bottom.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.playback,
    this.sync,
    this.account,
    this.collections,
    this._settings,
  });

  final LibraryController library;
  final PlaybackController playback;

  PlayerService get player => playback.player;

  /// Sync state for the status bar; no status bar when null.
  final SyncController? sync;

  /// The VK account, for logging in and out.
  final VkAccount? account;

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
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    _searchFocus.addListener(_endJumpInSearch);
  }

  /// Going to the search box ends a jump: typing now filters instead.
  void _endJumpInSearch() {
    if (_searchFocus.hasFocus) library.jump.clear();
  }

  /// App-wide keys. They run before the focus tree, so they work wherever the
  /// focus is, including nowhere after clicking a song. A key used here stops
  /// here: Flutter's own bindings would also move the focus onto a button
  /// with the arrows, scroll with Ctrl+arrows and press that button with Space.
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// Acts on [event]; true when the key was used.
  bool _onKey(KeyEvent event) {
    if (_onJumpKey(event)) return true;
    // A held key repeats only for the volume, see _onPlayerKey.
    if (event is KeyRepeatEvent) return _onPlayerKey(event);
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    // The physical key, so Ctrl+F also works with the Russian layout, where
    // the same key types "а".
    if (event.physicalKey == PhysicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed &&
        !_covered) {
      _searchFocus.requestFocus();
      library.searchText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: library.searchText.text.length,
      );
      return true;
    }
    if (_onPlaceKey(event)) return true;
    if (key == LogicalKeyboardKey.escape &&
        library.searchText.text.isNotEmpty &&
        !_covered) {
      library.searchText.clear();
      return true;
    }
    // Esc in an empty search box leaves it, so the player keys work again.
    if (key == LogicalKeyboardKey.escape && _typing && !_covered) {
      _searchFocus.unfocus();
      return true;
    }
    if (key == LogicalKeyboardKey.f1 && !_covered) {
      unawaited(showShortcutsHelp(context));
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
    return _onPlayerKey(event);
  }

  /// Going to the playing song and to the previous or next place. They work
  /// from the search box too, like a browser's. The physical key, so Ctrl+L
  /// also works with the Russian layout.
  bool _onPlaceKey(KeyEvent event) {
    if (_covered) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        event.physicalKey == PhysicalKeyboardKey.keyL) {
      _goToPlayingSong();
      return true;
    }
    if (!keyboard.isAltPressed) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      library.goBack();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      library.goForward();
      return true;
    }
    return false;
  }

  /// The mouse's back and forward side buttons.
  void _onPointerDown(PointerDownEvent event) {
    if (_covered) return;
    if (event.buttons & kBackMouseButton != 0) library.goBack();
    if (event.buttons & kForwardMouseButton != 0) library.goForward();
  }

  /// Shows the playing song in the list it came from. Leaves the search box,
  /// so Enter and letters work on the row found.
  void _goToPlayingSong() {
    final track = widget.player.current;
    if (track == null) return;
    _searchFocus.unfocus();
    library.goToSong(track, listRow: widget.playback.queue.contextIndex);
  }

  /// Keys of the jump to a song by typing. They come before the app's other
  /// keys, since Up, Down, Space and Esc mean something else during a jump.
  /// Letters come from Windows' text, so any layout works: Cyrillic has no
  /// physical key of its own. Ctrl and Alt keep their shortcuts, and AltGr
  /// reads as both, so its letters do not jump.
  bool _onJumpKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    if (_typing || _covered) return false;
    if (library.view.isLater || library.visible.isEmpty) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final jump = library.jump;
    final key = event.logicalKey;
    if (jump.isTyping) {
      if (key == LogicalKeyboardKey.arrowDown) {
        jump.next();
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        jump.previous();
        return true;
      }
      if (key == LogicalKeyboardKey.backspace) {
        jump.backspace();
        return true;
      }
    }
    // A held key is not many letters, and it stays with the player below.
    if (event is! KeyDownEvent) return false;
    if (key == LogicalKeyboardKey.escape &&
        (jump.isTyping || jump.row != null)) {
      jump.clear();
      return true;
    }
    final row = jump.row;
    if (key == LogicalKeyboardKey.enter && row != null) {
      jump.clear();
      _play(row);
      return true;
    }
    final character = event.character;
    if (character == null || !_isPrintable(character)) return false;
    // Space only joins letters: on its own it stays play and pause.
    if (key == LogicalKeyboardKey.space && !jump.isTyping) return false;
    jump.type(character);
    return true;
  }

  /// Whether [character] is text, not a control character such as the ones
  /// Enter, Esc, Tab and Backspace come with.
  bool _isPrintable(String character) {
    final code = character.runes.first;
    return code >= 0x20 && code != 0x7F;
  }

  /// The player's keys, listed in [shortcuts]. Not while typing, where they
  /// edit text, nor under a dialog or menu, where the arrows choose. Letters
  /// always need Ctrl: plain letters stay free for jumping to a song by typing.
  bool _onPlayerKey(KeyEvent event) {
    if (_typing || _covered || !widget.player.isReady) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isShiftPressed) return false;
    final playback = widget.playback;
    final key = event.logicalKey;
    if (!keyboard.isControlPressed) {
      // A slider reached with Tab keeps the arrows for itself.
      if (_onSlider) return false;
      if (key == LogicalKeyboardKey.arrowUp) {
        playback.stepVolume(volumeKeyStep);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        playback.stepVolume(-volumeKeyStep);
        return true;
      }
      // A held arrow would send a seek every few milliseconds, each of them
      // a new request to the audio server on a stream.
      if (event is KeyRepeatEvent) return false;
      if (key == LogicalKeyboardKey.arrowRight) {
        playback.seekBy(seekKeyStep);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        playback.seekBy(-seekKeyStep);
        return true;
      }
      return false;
    }
    if (event is KeyRepeatEvent) return false;
    if (key == LogicalKeyboardKey.arrowRight) {
      playback.next();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      playback.previous();
      return true;
    }
    // Physical keys, so these also work with the Russian layout.
    final physical = event.physicalKey;
    if (physical == PhysicalKeyboardKey.keyM) {
      playback.toggleMute();
      return true;
    }
    if (physical == PhysicalKeyboardKey.keyS) {
      playback.toggleShuffle();
      return true;
    }
    if (physical == PhysicalKeyboardKey.keyR) {
      playback.cycleRepeat();
      return true;
    }
    return false;
  }

  /// Whether a dialog, a menu or the cover viewer is open over this screen:
  /// Esc is theirs then, and the search box is out of reach.
  bool get _covered => Navigator.of(context).canPop();

  /// Whether the keyboard focus is in a text field. The focus belongs to a
  /// Focus widget inside the EditableText, so the field is an ancestor.
  bool get _typing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  /// Whether the keyboard focus is on a slider.
  bool get _onSlider =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Slider>() !=
      null;

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _searchFocus.removeListener(_endJumpInSearch);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _searchFocus.dispose();
    super.dispose();
  }

  /// Plays the visible song at [index], with the visible list as the list
  /// next and previous move in; clicking the song that is already loaded
  /// pauses or resumes it instead of restarting it.
  void _play(int index) {
    library.notePlayedFrom();
    widget.playback.playFrom(library.visible, index);
  }

  /// A song's right-click menu: Play next and Add to queue, View cover,
  /// Download or Remove download, put on top of a Stack, and in a Stack,
  /// remove this entry.
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
        if (track.hasCover || storage != null || inStack)
          const PopupMenuDivider(),
        if (track.hasCover)
          const PopupMenuItem(
            key: ValueKey('menu-view-cover'),
            value: 'view-cover',
            child: Text('View cover'),
          ),
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
      case 'view-cover':
        await showCoverViewer(context, track);
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
            child: Listener(
              onPointerDown: _onPointerDown,
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
                        onGoToSong: _goToPlayingSong,
                        compact: !roomForSidebar,
                      ),
                    if (widget.sync case final sync?)
                      SyncStatusBar(sync: sync, account: widget.account),
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
                              onGoToSong: _goToPlayingSong,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                key: const ValueKey('keyboard-help'),
                tooltip: 'Keyboard shortcuts (F1)',
                onPressed: () => showShortcutsHelp(context),
                icon: const Icon(Icons.keyboard_outlined),
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
              library.jump,
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
                    jump: library.jump,
                  ),
                  if (!view.isLater && library.visible.isNotEmpty)
                    _ListHeader(numbered: !_settings.thumbnails),
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
      final message = Text(
        empty,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 15, color: colors.dim),
      );
      // A first start: the library fills from the VK account.
      final account = widget.account;
      final firstStart =
          account != null &&
          library.view.kind == ViewKind.songs &&
          library.searchText.text.isEmpty;
      return Padding(
        padding: const EdgeInsets.all(48),
        child: !firstStart
            ? message
            : ListenableBuilder(
                listenable: account,
                builder: (context, _) => account.loggedIn
                    ? message
                    : Column(
                        children: [
                          Text(
                            'Log in to VK and your songs come here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 15, color: colors.dim),
                          ),
                          const SizedBox(height: 16),
                          LogInButton(account: account),
                        ],
                      ),
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
                saving: _storage?.isSaving(track) ?? false,
                storage: _storage,
                thumbnails: _settings.thumbnails,
                isCurrent: track.id == current.data?.id,
                isJump: index == library.jump.row,
                playing: playing,
                onTap: () {
                  library.jump.clear();
                  _play(index);
                },
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
      // Not focused at the start: Space must resume the song, not type.
      focusNode: focusNode,
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
  const _ViewHeading({
    required this.title,
    required this.count,
    required this.jump,
  });

  final String title;
  final String? count;
  final TypeJump jump;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Row(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    count!,
                    style: TextStyle(fontSize: 13, color: colors.dim),
                  ),
                ],
              ],
            ),
          ),
          if (jump.isTyping) ...[
            const SizedBox(width: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: _JumpPill(jump: jump),
            ),
          ],
        ],
      ),
    );
  }
}

/// Names the columns of [_SongRow] above the list, where scrolling leaves it
/// in place. Its widths and gaps are the row's, or the two would drift apart.
class _ListHeader extends StatelessWidget {
  const _ListHeader({required this.numbered});

  /// Whether the rows show numbers instead of tiles.
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: colors.dim2,
    );
    return Container(
      key: const ValueKey('list-header'),
      // The list's side padding plus the row's.
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: numbered
                ? Text('#', textAlign: TextAlign.right, style: style)
                : null,
          ),
          const SizedBox(width: 14),
          Expanded(flex: 16, child: Text('Title', style: style)),
          const SizedBox(width: 14),
          Expanded(flex: 10, child: Text('Album', style: style)),
          // The stored mark has no header: its tooltip explains it.
          const SizedBox(width: 14 + 18 + 14),
          SizedBox(
            width: 44,
            child: Text('Time', textAlign: TextAlign.right, style: style),
          ),
        ],
      ),
    );
  }
}

/// What was typed for a jump and how it went: "mad  2 of 3" or "mad  no
/// match". It sits in the heading so that it never covers a row.
class _JumpPill extends StatelessWidget {
  const _JumpPill({required this.jump});

  final TypeJump jump;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final found = jump.matchCount > 0;
    return Container(
      key: const ValueKey('jump-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: found ? colors.accentBg : colors.surface,
        border: Border.all(color: found ? colors.accent : colors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: jump.text.trimRight(),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: found
                  ? '  ${jump.matchNumber} of ${jump.matchCount}'
                  : '  no match',
              style: TextStyle(color: colors.dim),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
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
    required this.saving,
    required this.storage,
    required this.thumbnails,
    required this.isCurrent,
    required this.isJump,
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

  /// Being saved to the cache while it streams.
  final bool saving;
  final AudioStorage? storage;
  final bool thumbnails;
  final bool isCurrent;

  /// The row reached by typing: outlined, so that it reads apart from the
  /// current song's fill and can be the same row.
  final bool isJump;

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
      _ when downloading => (Icons.download_outlined, 'Downloading'),
      _ when saving => (Icons.cloud_outlined, 'Saving to the cache'),
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
        // Material fades a new shape in over 200 ms: too slow for an outline
        // that moves with every key.
        animationDuration: Duration.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: isJump
              ? BorderSide(color: colors.accent, width: 1.5)
              : BorderSide.none,
        ),
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
                    child: storage != null && (downloading || saving)
                        ? FillingIcon(
                            key: ValueKey('filling-${track.id}'),
                            storage: storage!,
                            track: track,
                            icon: icon,
                            filled: downloading ? Icons.download : Icons.cloud,
                            size: 18,
                            color: sourceColor(colors, track),
                          )
                        : Icon(
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
