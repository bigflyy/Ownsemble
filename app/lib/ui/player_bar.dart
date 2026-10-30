import 'package:flutter/material.dart';

import '../library/track.dart';
import '../playback/play_queue.dart';
import '../playback/playback_controller.dart';
import '../storage/audio_storage.dart';
import 'collections_controller.dart';
import 'cover_tile.dart';
import 'filling_icon.dart';
import 'theme.dart';

/// Width of the side panel.
const sidePanelWidth = 380.0;

/// The player in the side panel (B2 "Now playing"): tile, song, source and
/// storage, Stack menu and Download, seek bar, transport, volume, Up next.
class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({
    super.key,
    required this.playback,
    required this.collections,
    required this.thumbnails,
    required this.onDockBottom,
  });

  final PlaybackController playback;
  final CollectionsController? collections;
  final bool thumbnails;
  final VoidCallback onDockBottom;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final player = playback.player;
    return Container(
      width: sidePanelWidth,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.line)),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([playback, ?player.storage]),
        builder: (context, _) => StreamBuilder<Track?>(
          stream: player.currentStream,
          initialData: player.current,
          builder: (context, snapshot) {
            final track = player.isReady ? snapshot.data : null;
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
              children: [
                Row(
                  children: [
                    const Expanded(child: SectionLabel('Now playing')),
                    IconButton(
                      key: const ValueKey('dock-bottom'),
                      tooltip: 'Move the player to the bottom',
                      onPressed: onDockBottom,
                      icon: const Icon(Icons.call_to_action_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (track == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Text(
                      'Click a song to play it',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.dim),
                    ),
                  )
                else ...[
                  if (thumbnails)
                    Center(
                      child: TrackTile(track: track, size: 220, radius: 16),
                    ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SongTitle(
                          track: track,
                          large: true,
                          storage: player.storage,
                        ),
                      ),
                      if (collections != null)
                        StackMenuButton(
                          track: track,
                          collections: collections!,
                        ),
                      if (player.storage != null)
                        DownloadButton(playback: playback, track: track),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SeekRow(playback: playback, layout: SeekLayout.panel),
                  const SizedBox(height: 10),
                  TransportRow(playback: playback, large: true),
                  const SizedBox(height: 12),
                  VolumeRow(playback: playback, showValue: true),
                  const SizedBox(height: 14),
                  Divider(height: 1, color: colors.line),
                  const SizedBox(height: 14),
                  _UpNext(playback: playback, thumbnails: thumbnails),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The player as a bar at the bottom (B2 dock): song on the left,
/// transport and seek bar in the middle, Stack menu, Download and volume on
/// the right. [canDockSide] is false when the window is too narrow for the
/// side panel.
class DockBar extends StatelessWidget {
  const DockBar({
    super.key,
    required this.playback,
    required this.collections,
    required this.thumbnails,
    required this.canDockSide,
    required this.onDockSide,
    required this.compact,
  });

  final PlaybackController playback;
  final CollectionsController? collections;
  final bool thumbnails;
  final bool canDockSide;
  final VoidCallback onDockSide;

  /// Very narrow window: the right column (volume and menus) is left out.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final player = playback.player;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: ListenableBuilder(
        listenable: Listenable.merge([playback, ?player.storage]),
        builder: (context, _) => StreamBuilder<Track?>(
          stream: player.currentStream,
          initialData: player.current,
          builder: (context, snapshot) {
            final track = player.isReady ? snapshot.data : null;
            return Row(
              children: [
                Expanded(
                  flex: 2,
                  child: track == null
                      ? Text(
                          'Click a song to play it',
                          style: TextStyle(color: colors.dim),
                        )
                      : Row(
                          children: [
                            if (thumbnails) ...[
                              TrackTile(track: track, size: 52, radius: 8),
                              const SizedBox(width: 12),
                            ],
                            Expanded(child: SongTitle(track: track)),
                            UpNextButton(
                              playback: playback,
                              thumbnails: thumbnails,
                            ),
                          ],
                        ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 3,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TransportRow(playback: playback, large: false),
                      SeekRow(playback: playback, layout: SeekLayout.dock),
                    ],
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 2,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (track != null && collections != null)
                          StackMenuButton(
                            track: track,
                            collections: collections!,
                          ),
                        if (track != null && player.storage != null)
                          DownloadButton(playback: playback, track: track),
                        Flexible(
                          child: SizedBox(
                            width: 150,
                            child: VolumeRow(
                              playback: playback,
                              showValue: false,
                            ),
                          ),
                        ),
                        if (canDockSide)
                          IconButton(
                            key: const ValueKey('dock-side'),
                            tooltip: 'Move the player to the side panel',
                            onPressed: onDockSide,
                            icon: const Icon(Icons.view_sidebar_outlined),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Small capitals heading, as the design's section labels.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 1,
      color: OwnColors.of(context).dim,
    ),
  );
}

/// Title, artist and, in the panel, where the song comes from (source dot,
/// source name and how it is stored).
class SongTitle extends StatelessWidget {
  const SongTitle({
    super.key,
    required this.track,
    this.large = false,
    this.storage,
  });

  final Track track;
  final bool large;
  final AudioStorage? storage;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final stored =
        storage?.stateOf(track) ??
        (path: track.localPath, pinned: track.pinned);
    final state = stored.pinned
        ? 'downloaded'
        : stored.path != null
        ? 'cached'
        : track.isGone
        ? 'gone from VK'
        : 'streams';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.title,
          maxLines: large ? 3 : 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 23 : 15,
            fontWeight: large ? FontWeight.w700 : FontWeight.w500,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          track.source == TrackSource.generated
              ? '${track.artist}  (test filler: plays a sample song)'
              : track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: large ? 15 : 13,
            color: large ? colors.text : colors.dim,
          ),
        ),
        if (large) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: sourceColor(colors, track),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${track.source == TrackSource.vk ? 'VK' : 'Generated'}'
                ' - $state',
                style: TextStyle(fontSize: 13, color: colors.dim),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The color of [track]'s source (source 1 is VK).
Color sourceColor(OwnColors colors, Track track) =>
    track.source == TrackSource.vk ? colors.source1 : colors.source3;

/// Shuffle, previous, play or pause, next, repeat.
class TransportRow extends StatelessWidget {
  const TransportRow({super.key, required this.playback, required this.large});

  final PlaybackController playback;

  /// The side panel's big buttons, else the bar's compact ones.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final player = playback.player;
    final hasSong = player.isReady && player.current != null;
    final repeatLabel = switch (playback.repeat) {
      Repeat.off => 'Repeat: off',
      Repeat.list => 'Repeat: list',
      Repeat.one => 'Repeat: this song',
    };
    Widget toggle({
      required Key key,
      required String tooltip,
      required bool on,
      required VoidCallback onPressed,
      required Widget icon,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: on ? colors.accentBg : null,
        foregroundColor: on ? colors.accent : colors.dim,
        fixedSize: const Size(44, 44),
      ),
      icon: icon,
    );
    return Row(
      mainAxisAlignment: large
          ? MainAxisAlignment.spaceBetween
          : MainAxisAlignment.center,
      children: [
        toggle(
          key: const ValueKey('shuffle'),
          tooltip: playback.shuffle ? 'Shuffle: on' : 'Shuffle: off',
          on: playback.shuffle,
          onPressed: playback.toggleShuffle,
          icon: const Icon(Icons.shuffle, size: 20),
        ),
        IconButton(
          key: const ValueKey('prev'),
          tooltip: 'Previous (restarts the song after 3 s)',
          onPressed: hasSong ? playback.previous : null,
          style: IconButton.styleFrom(foregroundColor: colors.text),
          icon: Icon(Icons.skip_previous_rounded, size: large ? 30 : 24),
        ),
        ValueListenableBuilder(
          valueListenable: player.playing,
          builder: (context, playing, _) => IconButton(
            key: const ValueKey('play-pause'),
            tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
            onPressed: hasSong ? playback.playOrPause : null,
            style: IconButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              disabledBackgroundColor: colors.accent.withValues(alpha: 0.4),
              fixedSize: Size.square(large ? 64 : 48),
            ),
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: large ? 34 : 28,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('next'),
          tooltip: 'Next',
          onPressed: hasSong ? playback.next : null,
          style: IconButton.styleFrom(foregroundColor: colors.text),
          icon: Icon(Icons.skip_next_rounded, size: large ? 30 : 24),
        ),
        toggle(
          key: const ValueKey('repeat'),
          tooltip: repeatLabel,
          on: playback.repeat != Repeat.off,
          onPressed: playback.cycleRepeat,
          icon: Icon(
            playback.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
            size: 20,
          ),
        ),
      ],
    );
  }
}

/// How the seek bar and its times are laid out.
enum SeekLayout {
  /// Bar on top, position left and total (or remaining) right below it.
  panel,

  /// Position, bar, total (or remaining) in one row.
  dock,
}

/// The seek bar with the position and the total or remaining time.
///
/// While the handle is dragged the bar follows the mouse, not the playing
/// position, and the song moves there when the mouse is released; a click
/// moves there at once. Clicking the time switches between total and
/// remaining.
class SeekRow extends StatefulWidget {
  const SeekRow({super.key, required this.playback, required this.layout});

  final PlaybackController playback;
  final SeekLayout layout;

  @override
  State<SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<SeekRow> {
  /// Where the handle is while dragging, in seconds; null when not dragging.
  double? _dragSeconds;

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final player = playback.player;
    final colors = OwnColors.of(context);
    final style = TextStyle(
      fontSize: 13,
      color: colors.dim,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final storage = player.storage;
    return ListenableBuilder(
      // A paused song keeps saving, so the band moves without positions.
      listenable: Listenable.merge([?storage?.progress]),
      builder: (context, _) => StreamBuilder<Duration>(
        stream: player.isReady ? player.positions : null,
        builder: (context, _) {
          final hasSong = player.isReady && player.current != null;
          final total = hasSong ? player.duration : Duration.zero;
          final totalSeconds = total.inMilliseconds / 1000;
          final playingSeconds = hasSong
              ? (player.position.inMilliseconds / 1000).clamp(0.0, totalSeconds)
              : 0.0;
          final shown = _dragSeconds ?? playingSeconds;
          final at = Duration(milliseconds: (shown * 1000).round());
          final end = playback.showRemaining
              ? '-${formatDuration(total - at)}'
              : formatDuration(total);
          final max = totalSeconds <= 0 ? 1.0 : totalSeconds;
          final slider = Slider(
            key: const ValueKey('seek'),
            value: shown,
            max: max,
            secondaryTrackValue: hasSong && storage != null
                ? storage.savedShare(player.current!) * max
                : null,
            label: formatDuration(at),
            onChangeStart: totalSeconds <= 0
                ? null
                : (value) => setState(() => _dragSeconds = value),
            onChanged: totalSeconds <= 0
                ? null
                : (value) => setState(() => _dragSeconds = value),
            onChangeEnd: (value) async {
              await playback.seek(
                Duration(milliseconds: (value * 1000).round()),
              );
              if (mounted) setState(() => _dragSeconds = null);
            },
          );
          final position = Text(formatDuration(at), style: style);
          final endButton = TextButton(
            key: const ValueKey('time'),
            onPressed: playback.toggleRemaining,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              foregroundColor: colors.dim,
            ),
            child: Text(end, style: style),
          );
          return switch (widget.layout) {
            SeekLayout.panel => Column(
              children: [
                SizedBox(height: 28, child: slider),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [position, endButton],
                  ),
                ),
              ],
            ),
            SeekLayout.dock => Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: position,
                  ),
                ),
                Expanded(child: SizedBox(height: 28, child: slider)),
                SizedBox(width: 52, child: endButton),
              ],
            ),
          };
        },
      ),
    );
  }
}

/// Mute button and volume slider (with the number in the panel).
class VolumeRow extends StatelessWidget {
  const VolumeRow({super.key, required this.playback, required this.showValue});

  final PlaybackController playback;
  final bool showValue;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final shown = playback.mutedByUser ? 0.0 : playback.volume;
    return Row(
      children: [
        IconButton(
          key: const ValueKey('mute'),
          tooltip: playback.mutedByUser ? 'Unmute' : 'Mute',
          onPressed: playback.toggleMute,
          icon: Icon(
            shown == 0
                ? Icons.volume_off_outlined
                : shown < 50
                ? Icons.volume_down_outlined
                : Icons.volume_up_outlined,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: colors.dim,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              key: const ValueKey('volume'),
              value: shown,
              max: 100,
              label: 'Volume ${shown.round()}',
              onChanged: playback.setVolume,
              onChangeEnd: (_) => playback.saveVolume(),
            ),
          ),
        ),
        if (showValue)
          SizedBox(
            width: 28,
            child: Text(
              '${shown.round()}',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13, color: colors.dim),
            ),
          ),
      ],
    );
  }
}

/// "Add to a Stack": puts the song on top of a Stack, or of a new one.
class StackMenuButton extends StatelessWidget {
  const StackMenuButton({
    super.key,
    required this.track,
    required this.collections,
  });

  final Track track;
  final CollectionsController collections;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      key: const ValueKey('stack-menu'),
      tooltip: 'Add to a Stack',
      icon: const Icon(Icons.playlist_add),
      itemBuilder: (context) => stackMenuItems(collections),
      onSelected: (choice) =>
          addToStackChoice(context, collections, track, choice),
    );
  }
}

/// Menu value meaning "New Stack..."; other values are Stack ids.
const newStackChoice = -1;

/// The items of an "Add to a Stack" menu: each Stack, then New Stack.
List<PopupMenuEntry<int>> stackMenuItems(CollectionsController collections) => [
  const PopupMenuItem<int>(
    enabled: false,
    height: 28,
    child: Text('Put on top of'),
  ),
  for (final stack in collections.stacks)
    PopupMenuItem<int>(
      key: ValueKey('stack-${stack.id}'),
      value: stack.id,
      child: Row(
        children: [
          Expanded(child: Text(stack.name, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Text('${stack.entryCount}'),
        ],
      ),
    ),
  const PopupMenuItem<int>(
    key: ValueKey('new-stack'),
    value: newStackChoice,
    child: Text('New Stack...'),
  ),
];

/// Carries out a choice of [stackMenuItems] for [track]: puts it on top of
/// the chosen Stack, or asks for a name and creates a new Stack with it.
Future<void> addToStackChoice(
  BuildContext context,
  CollectionsController collections,
  Track track,
  int choice,
) async {
  var stackId = choice;
  if (choice == newStackChoice) {
    final name = await askStackName(context);
    if (name == null) return;
    stackId = collections.createStack(name);
  }
  collections.addToStack(stackId, track);
  final name = collections.stacks.firstWhere((s) => s.id == stackId).name;
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Put on top of $name')));
  }
}

/// Asks for a new Stack's name; null when cancelled or empty.
Future<String?> askStackName(BuildContext context) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => const _StackNameDialog(),
  );
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// The "New Stack" dialog; owns its text field's controller, so it lives
/// as long as the dialog (also while it animates away).
class _StackNameDialog extends StatefulWidget {
  const _StackNameDialog();

  @override
  State<_StackNameDialog> createState() => _StackNameDialogState();
}

class _StackNameDialogState extends State<_StackNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New Stack'),
    content: TextField(
      key: const ValueKey('new-stack-name'),
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Name'),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('new-stack-create'),
        onPressed: () => Navigator.pop(context, _name.text),
        child: const Text('Create'),
      ),
    ],
  );
}

/// Downloads the current song, or removes its download.
class DownloadButton extends StatelessWidget {
  const DownloadButton({
    super.key,
    required this.playback,
    required this.track,
  });

  final PlaybackController playback;
  final Track track;

  @override
  Widget build(BuildContext context) {
    final storage = playback.player.storage!;
    final colors = OwnColors.of(context);
    final downloading = storage.isDownloading(track);
    final downloaded = storage.stateOf(track).pinned;
    return IconButton(
      key: const ValueKey('download'),
      tooltip: downloading
          ? 'Downloading...'
          : downloaded
          ? 'Downloaded. Click to remove the download'
          : 'Download: keep this song on this computer',
      onPressed: downloading
          ? null
          : () async {
              if (downloaded) {
                playback.removeDownload(track);
                return;
              }
              final messenger = ScaffoldMessenger.of(context);
              final error = await playback.download(track);
              if (error != null) {
                messenger.showSnackBar(
                  SnackBar(content: Text('Download failed: $error')),
                );
              }
            },
      icon: downloading
          ? FillingIcon(
              storage: storage,
              track: track,
              icon: Icons.download_outlined,
              filled: Icons.download,
              size: 24,
              color: colors.accent,
            )
          : Icon(
              downloaded ? Icons.download_done : Icons.download_outlined,
              color: downloaded ? colors.accent : null,
            ),
    );
  }
}

/// Opens Up next from the bottom bar, which has no room for the list; the
/// count says how many songs are queued.
class UpNextButton extends StatelessWidget {
  const UpNextButton({
    super.key,
    required this.playback,
    required this.thumbnails,
  });

  final PlaybackController playback;
  final bool thumbnails;

  @override
  Widget build(BuildContext context) {
    final count = playback.queue.queued.length;
    return IconButton(
      key: const ValueKey('up-next-open'),
      tooltip: 'Up next',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, maxHeight: 460),
            child: ListenableBuilder(
              listenable: playback,
              builder: (context, _) => ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                children: [_UpNext(playback: playback, thumbnails: thumbnails)],
              ),
            ),
          ),
        ),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.queue_music),
      ),
    );
  }
}

/// The songs that play next: first the queued ones, each removable, then
/// the list the current song was started from.
class _UpNext extends StatelessWidget {
  const _UpNext({required this.playback, required this.thumbnails});

  final PlaybackController playback;
  final bool thumbnails;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final queue = playback.queue;
    final queued = queue.queued;
    final upcoming = queue.upcoming(5);
    final note = TextStyle(fontSize: 14, color: colors.dim);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: SectionLabel('Up next'),
        ),
        for (final (i, track) in queued.indexed)
          _UpNextRow(
            key: ValueKey('queued-$i'),
            track: track,
            thumbnails: thumbnails,
            onTap: () => playback.playQueued(i),
            onRemove: () => playback.removeQueued(i),
            removeKey: ValueKey('queued-remove-$i'),
          ),
        if (queued.isNotEmpty) const SizedBox(height: 8),
        if (queue.shuffle)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              queued.isEmpty
                  ? 'Shuffle is on: the next song is picked at random from '
                        'the list you started.'
                  : 'Then shuffle picks at random from the list you started.',
              style: note,
            ),
          )
        else if (upcoming.isEmpty && queued.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              queue.repeat == Repeat.one
                  ? 'This song plays again.'
                  : 'Nothing after this song.',
              style: note,
            ),
          )
        else
          for (final (i, index) in upcoming.indexed)
            _UpNextRow(
              key: ValueKey('up-next-$i'),
              track: queue.context[index],
              thumbnails: thumbnails,
              onTap: () => playback.playFrom(queue.context, index),
            ),
      ],
    );
  }
}

class _UpNextRow extends StatelessWidget {
  const _UpNextRow({
    super.key,
    required this.track,
    required this.thumbnails,
    required this.onTap,
    this.onRemove,
    this.removeKey,
  });

  final Track track;
  final bool thumbnails;
  final VoidCallback onTap;

  /// Takes a queued song out of the queue; null for songs of the list.
  final VoidCallback? onRemove;
  final Key? removeKey;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            if (thumbnails) ...[
              TrackTile(track: track, size: 34, radius: 6),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.dim),
                  ),
                ],
              ),
            ),
            Text(
              formatDuration(Duration(seconds: track.durationSec)),
              style: TextStyle(fontSize: 13, color: colors.dim2),
            ),
            if (onRemove != null)
              IconButton(
                key: removeKey,
                tooltip: 'Remove from queue',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
      ),
    );
  }
}

/// Formats a duration as m:ss.
String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
