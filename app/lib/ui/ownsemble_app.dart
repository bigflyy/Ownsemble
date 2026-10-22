import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../media/audio_policy.dart';
import '../services/app_controller.dart';
import '../services/playback_queue.dart';
import 'track_details.dart';
import 'artwork_viewport.dart';
import 'artwork_preview.dart';
import 'app_shortcuts.dart';

const accent = Color(0xFFD5E9A4);
const canvas = Color(0xFF171918);
const panel = Color(0xFF111312);
const muted = Color(0xFF9DA49D);
const _playColumn = 40.0, _artworkColumn = 55.0;
const _savedColumn = 95.0, _durationColumn = 55.0, _actionsColumn = 120.0;

class OwnsembleApp extends StatelessWidget {
  final AppController controller;
  const OwnsembleApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ownsemble',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        primary: accent,
        surface: canvas,
      ),
      fontFamily: 'Segoe UI',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14),
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      dividerColor: Colors.white10,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .045),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    ),
    home: LibraryScreen(controller: controller),
  );
}

class LibraryScreen extends StatefulWidget {
  final AppController controller;
  const LibraryScreen({super.key, required this.controller});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  AppController get c => widget.controller;
  final search = TextEditingController();
  final searchFocus = FocusNode();
  Timer? debounce;
  void _details(Track track) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 660,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: 'Close details (Escape)',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Flexible(
                child: TrackDetails(controller: c, track: track),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void browse(String view, {int? pile}) {
    search.clear();
    c.browse(view, pile: pile);
  }

  KeyEventResult _keyEvent(FocusNode node, KeyEvent event) {
    if (ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final command = appShortcuts.entries
        .where((entry) => entry.value.matches(event))
        .firstOrNull;
    if (command == null) return KeyEventResult.ignored;
    if (command.key == AppCommand.leaveSearch && !searchFocus.hasFocus) {
      return KeyEventResult.ignored;
    }
    final editing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editing != null &&
        command.key != AppCommand.search &&
        command.key != AppCommand.leaveSearch &&
        command.key != AppCommand.help) {
      return KeyEventResult.ignored;
    }
    // Let Flutter activate focused buttons with Space instead of stealing it.
    if (command.key == AppCommand.playPause && !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent && !command.value.repeats) {
      return KeyEventResult.handled;
    }
    switch (command.key) {
      case AppCommand.playPause:
        unawaited(c.togglePlay());
      case AppCommand.mute:
        unawaited(c.toggleMute());
      case AppCommand.previous:
        if (c.current != null) unawaited(c.previous());
      case AppCommand.next:
        if (c.current != null) unawaited(c.next());
      case AppCommand.volumeUp:
        unawaited(c.volume(c.volumeLevel + 5));
      case AppCommand.volumeDown:
        unawaited(c.volume(c.volumeLevel - 5));
      case AppCommand.seekBackward:
        _seekBy(-5);
      case AppCommand.seekForward:
        _seekBy(5);
      case AppCommand.stop:
        if (c.current != null || c.loading) unawaited(c.stopPlayback());
      case AppCommand.shuffle:
        c.shuffle();
      case AppCommand.repeat:
        c.repeat();
      case AppCommand.queue:
        _showQueue();
      case AppCommand.search:
        searchFocus.requestFocus();
      case AppCommand.leaveSearch:
        searchFocus.unfocus();
        node.requestFocus();
      case AppCommand.help:
        unawaited(showShortcutHelp(context));
    }
    return KeyEventResult.handled;
  }

  void _seekBy(double seconds) {
    if (c.loading || c.current == null) return;
    final native = c.player.state.duration.inMilliseconds / 1000;
    final duration = native > 0 ? native : c.current!.duration;
    if (!duration.isFinite || duration <= 0) return;
    final position = c.player.state.position.inMilliseconds / 1000;
    unawaited(c.seek((position + seconds).clamp(0, duration)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Focus(
      autofocus: true,
      onKeyEvent: _keyEvent,
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _sidebar(),
                  Expanded(child: _content()),
                ],
              ),
            ),
            _player(),
          ],
        ),
      ),
    ),
  );

  Widget _sidebar() => Container(
    width: 224,
    color: panel,
    padding: const EdgeInsets.fromLTRB(18, 28, 18, 16),
    child: Material(
      color: panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.graphic_eq_rounded, color: accent, size: 30),
              SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'ownsemble',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.only(left: 40),
            child: Text(
              'KEEP WHAT MOVES YOU',
              style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.3),
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _label('YOUR MUSIC'),
                _nav(Icons.library_music_outlined, 'Library', 'library'),
                _nav(Icons.history_rounded, 'Recently played', 'recent'),
                _nav(Icons.bar_chart_rounded, 'Most played', 'most'),
                _nav(
                  Icons.offline_pin_outlined,
                  'Available offline',
                  'offline',
                ),
                const SizedBox(height: 14),
                _label('CONNECTED SOURCES'),
                _nav(Icons.cloud_queue_rounded, 'VK music', 'vk'),
                Padding(
                  padding: const EdgeInsets.only(left: 38),
                  child: Text(
                    c.offline
                        ? 'Offline mode'
                        : c.provider.connected
                        ? 'Connected'
                        : c.autoSync
                        ? 'Waiting for VK'
                        : 'Not connected',
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _label('YOUR PILES')),
                    IconButton(
                      tooltip: 'Create a Pile',
                      onPressed: () => _pileDialog(),
                      icon: const Icon(Icons.add_rounded, size: 19),
                    ),
                  ],
                ),
                ...c.piles.map(
                  (p) => ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -2),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    selected: c.pileId == p.id,
                    selectedTileColor: accent.withValues(alpha: .10),
                    selectedColor: accent,
                    leading: Icon(
                      p.pinned
                          ? Icons.push_pin_outlined
                          : Icons.layers_outlined,
                      size: 19,
                    ),
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      '${p.count}',
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                    onTap: () => browse('pile', pile: p.id),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.tune_rounded, size: 20),
            title: const Text('Settings'),
            onTap: _settings,
          ),
        ],
      ),
    ),
  );
  Widget _label(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: muted,
        letterSpacing: 1.4,
      ),
    ),
  );
  Widget _nav(IconData icon, String title, String view) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: c.view == view && c.pileId == null,
      selectedTileColor: accent.withValues(alpha: .10),
      selectedColor: accent,
      leading: Icon(icon, size: 21),
      title: Text(title),
      onTap: () => browse(view),
    ),
  );
  Widget _content() {
    final rows = c.rows;
    final pile = c.piles.where((p) => p.id == c.pileId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 28, 34, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message:
                      '${shortcutHint(AppCommand.search)} · Escape leaves search without clearing it',
                  child: TextField(
                    controller: search,
                    focusNode: searchFocus,
                    onChanged: (s) {
                      debounce?.cancel();
                      debounce = Timer(
                        const Duration(milliseconds: 150),
                        () => c.search(s),
                      );
                    },
                    decoration: const InputDecoration(
                      hintText: 'Search your music',
                      prefixIcon: Icon(Icons.search, size: 21),
                      suffixIcon: Padding(
                        padding: EdgeInsets.all(14),
                        child: Text(
                          'Ctrl K',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              _badge(
                c.demo
                    ? 'PREVIEW'
                    : c.offline
                    ? 'OFFLINE'
                    : c.provider.connected
                    ? 'VK CONNECTED'
                    : 'LOCAL LIBRARY',
                c.offline ? muted : accent,
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: shortcutHint(AppCommand.help),
                onPressed: () => showShortcutHelp(context),
                icon: const Icon(Icons.keyboard_alt_outlined, size: 21),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: _settings,
                icon: const Icon(Icons.tune_rounded, size: 21),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            c.pileId != null
                ? 'A PILE OF GOOD FINDS'
                : 'MAKE ROOM FOR YOUR MUSIC',
            style: const TextStyle(
              color: accent,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  c.heading,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.3,
                  ),
                ),
              ),
              if (pile != null)
                PopupMenuButton<String>(
                  tooltip: 'Pile options',
                  onSelected: (v) {
                    if (v == 'rename') _pileDialog(pile: pile);
                    if (v == 'pin') unawaited(c.pinPile(pile.id, !pile.pinned));
                    if (v == 'delete') _deletePile(pile);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('Rename Pile'),
                    ),
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(
                        pile.pinned ? 'Unpin Pile' : 'Keep Pile offline',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete Pile'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            pile != null
                ? '${rows.length} entries · each rediscovery has its own place'
                : '${rows.length} songs${c.query.isEmpty ? ' in your collection' : ' matching your search'}',
            style: const TextStyle(color: muted),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                onPressed: rows.isEmpty ? null : () => c.playLibrary(rows),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 25,
                    vertical: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: rows.isEmpty
                    ? null
                    : () {
                        if (!c.queue.shuffle) c.shuffle();
                        c.playRows(rows, Random().nextInt(rows.length));
                      },
                icon: const Icon(Icons.shuffle_rounded, size: 18),
                label: const Text('Shuffle'),
              ),
              const Spacer(),
              if (c.view == 'vk' || c.store.count == 0)
                TextButton.icon(
                  onPressed: c.connecting ? null : c.connectVk,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: Text(
                    c.provider.connected ? 'Reconnect' : 'Connect VK',
                  ),
                ),
              IconButton(
                tooltip: 'Refresh VK · scan full library',
                onPressed: c.syncing || c.offline || !c.provider.connected
                    ? null
                    : c.refresh,
                icon: Icon(
                  Icons.refresh_rounded,
                  color: c.syncing ? accent : muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (c.view == 'vk')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Automatic refresh checks newest entries. Refresh VK scans deeper; library coverage remains partial.',
                style: TextStyle(
                  color: muted.withValues(alpha: .85),
                  fontSize: 12,
                ),
              ),
            ),
          if (c.syncing) const LinearProgressIndicator(minHeight: 2),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
            child: Row(
              children: [
                const SizedBox(
                  width: _playColumn,
                  child: Text(
                    '#',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ),
                const SizedBox(width: _artworkColumn),
                const Expanded(
                  child: Text(
                    'TITLE / ARTIST',
                    style: TextStyle(
                      color: muted,
                      fontSize: 10,
                      letterSpacing: 1.3,
                    ),
                  ),
                ),
                const SizedBox(
                  width: _savedColumn,
                  child: Text(
                    'SAVED',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: muted,
                      fontSize: 10,
                      letterSpacing: 1.3,
                    ),
                  ),
                ),
                const SizedBox(
                  width: _durationColumn,
                  child: Icon(Icons.schedule_rounded, color: muted, size: 15),
                ),
                const SizedBox(width: _actionsColumn),
              ],
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? _empty()
                : ListView.builder(
                    key: ValueKey('${c.view}:${c.pileId}:${c.query}'),
                    itemCount: rows.length,
                    itemExtent: 66,
                    itemBuilder: (context, index) => _trackRow(rows, index),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(
                  c.downloadId != null
                      ? Icons.downloading_rounded
                      : c.syncing
                      ? Icons.sync_rounded
                      : Icons.circle,
                  size: c.downloadId != null || c.syncing ? 15 : 6,
                  color: c.offline ? muted : accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    c.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 11),
                  ),
                ),
                if (c.downloadId != null) ...[
                  Text(
                    c.downloadLabel,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  IconButton(
                    tooltip: 'Cancel download',
                    onPressed: c.cancelDownload,
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .06),
            shape: BoxShape.circle,
          ),
          child: Icon(
            c.pileId != null
                ? Icons.layers_outlined
                : Icons.library_music_outlined,
            size: 38,
            color: accent,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          c.query.isNotEmpty
              ? 'No matching songs'
              : c.pileId != null
              ? 'Every Pile starts with one song'
              : c.view == 'offline'
              ? 'Take a little music with you'
              : c.view == 'recent' || c.view == 'most'
              ? 'Your listening story starts here'
              : 'Your music belongs here',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Text(
          c.query.isNotEmpty
              ? 'Try another title or artist.'
              : c.pileId != null
              ? 'Use a song’s menu to add it. Add it again whenever you like.'
              : c.view == 'offline'
              ? 'Play a song to cache it, or choose Keep offline.'
              : 'Connect VK once. Your library refreshes automatically.',
          style: const TextStyle(color: muted),
        ),
        if (c.store.count == 0 && !c.demo) ...[
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: c.connecting ? null : c.connectVk,
            icon: const Icon(Icons.link_rounded),
            label: const Text('Connect VK'),
          ),
        ],
      ],
    ),
  );
  Widget _trackRow(List<LibraryRow> rows, int index) {
    final row = rows[index], t = row.track;
    final selected =
        c.queue.current?.id == t.id &&
        (c.pileId == null || c.queue.current?.occurrence == row.occurrence);
    final playLabel = selected && c.loading
        ? 'Stop loading'
        : selected && c.player.state.playing
        ? 'Pause ${t.title}'
        : 'Play ${t.title}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? accent.withValues(alpha: .07) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onDoubleTap: () => c.playRows(rows, index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                SizedBox(
                  width: _playColumn,
                  child: IconButton(
                    tooltip: selected
                        ? shortcutHint(AppCommand.playPause, playLabel)
                        : playLabel,
                    onPressed: selected
                        ? c.togglePlay
                        : () => c.playRows(rows, index),
                    icon: selected && c.loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            selected && c.player.state.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 19,
                            color: selected ? accent : muted,
                          ),
                  ),
                ),
                _cover(t.title, t.artist, 42, controller: c, id: t.id),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? accent : Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (isProviderRestricted(row.error))
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Text(
                                'Restricted in VK',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFE9AD8A),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: _savedColumn,
                  child: Center(child: _savedStatus(row)),
                ),
                SizedBox(
                  width: _durationColumn,
                  child: Text(
                    _time(t.duration),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                SizedBox(
                  width: _actionsColumn,
                  child: Row(
                    children: [
                      Expanded(
                        child: IconButton(
                          tooltip: 'Add to Pile',
                          onPressed: () => _addToPile(row),
                          icon: const Icon(
                            Icons.playlist_add_rounded,
                            size: 21,
                            color: muted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: IconButton(
                          tooltip: c.store.individuallyPinned(t.id)
                              ? 'Release individual pin'
                              : 'Keep offline',
                          onPressed: () => c.pinTrack(t.id),
                          icon: Icon(
                            c.store.individuallyPinned(t.id)
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                            size: 18,
                            color: row.pinned ? accent : muted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: PopupMenuButton<String>(
                          tooltip: 'Song options',
                          onSelected: (value) {
                            if (value == 'details') _details(row.track);
                            if (value == 'queue') c.enqueue(row);
                            if (value == 'pile') _addToPile(row);
                            if (value == 'remove' && row.occurrence != null) {
                              c.removeOccurrence(row.occurrence!);
                            }
                            if (value == 'retry') c.playRows(rows, index);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'details',
                              child: Text('Song details & lyrics'),
                            ),
                            const PopupMenuItem(
                              value: 'queue',
                              child: Text('Add to queue'),
                            ),
                            const PopupMenuItem(
                              value: 'pile',
                              child: Text('Add to Pile'),
                            ),
                            if (row.error != null)
                              const PopupMenuItem(
                                value: 'retry',
                                child: Text('Retry playback'),
                              ),
                            if (row.occurrence != null)
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove this occurrence'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _savedStatus(LibraryRow row) {
    if (c.downloadId == row.track.id) {
      return Tooltip(
        message: c.downloadLabel.isEmpty
            ? 'Preparing saved audio'
            : c.downloadLabel,
        child: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (row.error != null) {
      return Tooltip(
        message:
            '${friendlyError(row.error!)}${row.offline ? ' Saved copy retained.' : ''}',
        child: const Icon(
          Icons.error_outline,
          size: 16,
          color: Color(0xFFE9AD8A),
        ),
      );
    }
    if (row.offline) {
      return Tooltip(
        message: row.pinned
            ? 'Complete audio saved · kept offline'
            : 'Complete audio saved',
        child: const Icon(Icons.check_circle_outline, size: 16, color: accent),
      );
    }
    return const Text('—', style: TextStyle(color: muted, fontSize: 12));
  }

  Widget _player() {
    final t = c.current, playing = c.player.state.playing;
    final nativeDuration = c.player.state.duration.inMilliseconds / 1000;
    final duration = !c.loading && nativeDuration > 0
        ? nativeDuration
        : t?.duration ?? 0;
    final position = c.loading
        ? 0.0
        : c.player.state.position.inMilliseconds / 1000;
    final buffered = c.player.state.buffer.inMilliseconds / 1000;
    return Container(
      height: 116,
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
      decoration: const BoxDecoration(
        color: panel,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 270,
            child: Row(
              children: [
                _cover(
                  t?.title ?? '♪',
                  t?.artist ?? '',
                  52,
                  controller: c,
                  id: t?.id,
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t?.title ?? 'Pick something you love',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        t?.artist ?? 'Your next rediscovery is waiting',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: shortcutHint(AppCommand.shuffle, 'Shuffle'),
                      onPressed: c.shuffle,
                      icon: Icon(
                        Icons.shuffle_rounded,
                        color: c.queue.shuffle ? accent : muted,
                        size: 19,
                      ),
                    ),
                    IconButton(
                      tooltip: shortcutHint(AppCommand.previous, 'Previous'),
                      onPressed: t == null ? null : c.previous,
                      icon: const Icon(Icons.skip_previous_rounded, size: 28),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: Tooltip(
                        message: shortcutHint(
                          AppCommand.playPause,
                          c.loading
                              ? 'Cancel loading'
                              : playing
                              ? 'Pause'
                              : 'Play',
                        ),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                          ),
                          onPressed: t == null ? null : c.togglePlay,
                          child: c.loading
                              ? const Icon(Icons.stop_rounded, size: 25)
                              : c.player.state.buffering
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 29,
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: shortcutHint(AppCommand.next, 'Next'),
                      onPressed: t == null ? null : c.next,
                      icon: const Icon(Icons.skip_next_rounded, size: 28),
                    ),
                    IconButton(
                      tooltip: shortcutHint(
                        AppCommand.repeat,
                        'Repeat: ${c.queue.repeat.name}',
                      ),
                      onPressed: c.repeat,
                      icon: Icon(
                        c.queue.repeat == QueueRepeat.one
                            ? Icons.repeat_one_rounded
                            : Icons.repeat_rounded,
                        color: c.queue.repeat == QueueRepeat.off
                            ? muted
                            : accent,
                        size: 19,
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      Text(
                        _time(position),
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                      Expanded(
                        child: Tooltip(
                          message:
                              'Seek (${appShortcuts[AppCommand.seekBackward]!.hint} / ${appShortcuts[AppCommand.seekForward]!.hint}, 5 seconds)',
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 4,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                            ),
                            child: Slider(
                              value: position.clamp(
                                0,
                                duration > 0 ? duration : 1,
                              ),
                              max: duration > 0 ? duration : 1,
                              secondaryTrackValue: buffered.clamp(
                                position.clamp(0, duration > 0 ? duration : 1),
                                duration > 0 ? duration : 1,
                              ),
                              onChanged: duration > 0 && !c.loading
                                  ? (s) => c.seek(s)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        _time(duration),
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          SizedBox(
            width: 224,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: shortcutHint(AppCommand.queue, 'Queue'),
                  onPressed: _showQueue,
                  icon: const Icon(
                    Icons.queue_music_rounded,
                    color: muted,
                    size: 22,
                  ),
                ),
                IconButton(
                  tooltip: shortcutHint(
                    AppCommand.mute,
                    c.muted ? 'Unmute' : 'Mute',
                  ),
                  isSelected: c.muted,
                  onPressed: c.toggleMute,
                  icon: Icon(
                    c.muted
                        ? Icons.volume_off_outlined
                        : Icons.volume_up_outlined,
                    color: muted,
                    size: 19,
                  ),
                ),
                SizedBox(
                  width: 115,
                  child: Tooltip(
                    message:
                        'Volume (${appShortcuts[AppCommand.volumeUp]!.hint} / ${appShortcuts[AppCommand.volumeDown]!.hint}, 5%)',
                    child: Slider(
                      value: c.volumeLevel,
                      max: 100,
                      onChanged: c.volume,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pileDialog({Pile? pile}) async {
    final field = TextEditingController(text: pile?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(pile == null ? 'Create a Pile' : 'Rename Pile'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'A name for your discoveries',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(ctx, value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (field.text.trim().isNotEmpty) Navigator.pop(ctx, field.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      if (pile == null) {
        final id = c.createPile(result);
        browse('pile', pile: id);
      } else {
        c.renamePile(pile.id, result);
      }
    }
    // Dialog exit animations may still refer to the controller this frame.
  }

  Future<void> _addToPile(LibraryRow row) async {
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add to Pile'),
        children: [
          ...c.piles.map(
            (p) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.id),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(p.name),
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('+ New Pile', style: TextStyle(color: accent)),
            ),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    if (result == -1) {
      await _pileDialog();
      if (c.pileId != null) c.addToPile(c.pileId!, row.track.id);
    } else {
      c.addToPile(result, row.track.id);
    }
  }

  Future<void> _deletePile(Pile pile) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${pile.name}?'),
        content: const Text(
          'This removes the Pile and its retention pins. Your library and other Piles remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) c.deletePile(pile.id);
  }

  Future<void> _settings() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Make yourself at home'),
          content: SizedBox(
            width: 470,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Work offline'),
                    subtitle: const Text(
                      'Play saved music without contacting VK',
                    ),
                    value: c.offline,
                    onChanged: (v) async {
                      await c.setOffline(v);
                      update(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Automatic VK refresh'),
                    subtitle: const Text(
                      'Check for music while the app is open',
                    ),
                    value: c.autoSync,
                    onChanged: (v) {
                      c.setAutoSync(v);
                      update(() {});
                    },
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('VK account'),
                    subtitle: const Text(
                      'Playback and refresh run in the background.',
                    ),
                    trailing: TextButton(
                      onPressed: c.demo
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              c.signInVk();
                            },
                      child: const Text('Sign in privately'),
                    ),
                  ),
                  const Divider(height: 28),
                  const Text(
                    'Automatic cache budget',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<int>(
                    isExpanded: true,
                    value:
                        [
                          256,
                          512,
                          1024,
                          2048,
                          4096,
                        ].contains(c.quota ~/ 1048576)
                        ? c.quota ~/ 1048576
                        : 2048,
                    items: [256, 512, 1024, 2048, 4096]
                        .map(
                          (mb) => DropdownMenuItem(
                            value: mb,
                            child: Text(
                              mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (mb) async {
                      if (mb != null) await c.setQuota(mb * 1048576);
                      update(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Automatic: ${_size(c.store.usedBytes(pinned: false))}\nPinned: ${_size(c.store.usedBytes(pinned: true))}',
                    style: const TextStyle(color: muted, height: 1.7),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Pins stay outside this budget. Playing songs and active downloads are protected.',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  const Divider(height: 28),
                  const Text(
                    'VK playlists',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Playlist browsing and playlist-wide pins are awaiting verification of VK’s playlist format. Local Piles and individual pins are available.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showQueue() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Up next',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: c.queue.order.isEmpty
                ? const Center(child: Text('Your queue is empty.'))
                : ListView.builder(
                    itemCount: c.queue.order.length,
                    itemBuilder: (ctx, index) {
                      final entry = c.queue.entries[c.queue.order[index]],
                          track = c.store.track(entry.id);
                      return ListTile(
                        leading: Icon(
                          index == c.queue.cursor
                              ? Icons.graphic_eq
                              : Icons.music_note,
                          color: index == c.queue.cursor ? accent : muted,
                        ),
                        title: Text(track?.title ?? 'Unavailable track'),
                        subtitle: Text(track?.artist ?? ''),
                        onTap: () {
                          c.queue.cursor = index;
                          Navigator.pop(ctx);
                          c.playCurrent();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Widget _badge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .08),
    border: Border.all(color: color.withValues(alpha: .17)),
    borderRadius: BorderRadius.circular(20),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 5, color: color),
      const SizedBox(width: 7),
      Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: .8,
        ),
      ),
    ],
  ),
);
Widget _cover(
  String title,
  String artist,
  double size, {
  AppController? controller,
  String? id,
}) {
  final hash = artist.runes.fold<int>(0, (a, b) => a + b);
  final colors = [
    const Color(0xFF384B41),
    const Color(0xFF5A453C),
    const Color(0xFF49435B),
    const Color(0xFF394D56),
    const Color(0xFF605634),
  ];
  final placeholder = Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          colors[hash % colors.length],
          colors[hash % colors.length].withValues(alpha: .25),
        ],
      ),
    ),
    child: Center(
      child: Text(
        title.isEmpty
            ? '♪'
            : String.fromCharCode(title.runes.first).toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: .7),
          fontSize: size * .45,
          fontWeight: FontWeight.w300,
        ),
      ),
    ),
  );
  if (controller == null || id == null) return placeholder;
  final file = controller.artworkFile(id);
  return ArtworkViewport(
    key: ValueKey(id),
    identity: id,
    onVisible: (owner) =>
        controller.watchArtwork(id, owner, priority: size > 42 ? 10 : 1),
    onHidden: (owner) => controller.unwatchArtwork(id, owner),
    child: file == null
        ? placeholder
        : Builder(
            builder: (context) => Tooltip(
              message: 'View artwork for $title',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showArtworkPreview(
                  context,
                  file,
                  title: title,
                  artist: artist,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    file,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    cacheWidth: (size * 2).round(),
                    errorBuilder: (_, _, _) => placeholder,
                  ),
                ),
              ),
            ),
          ),
  );
}

String _time(double seconds) {
  final n = seconds.isFinite ? seconds.floor().clamp(0, 86400) : 0;
  return '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}';
}

String _size(int bytes) => bytes >= 1073741824
    ? '${(bytes / 1073741824).toStringAsFixed(1)} GB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';
