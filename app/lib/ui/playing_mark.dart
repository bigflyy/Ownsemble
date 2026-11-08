import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../playback/playback_controller.dart';
import 'cover_tile.dart';

/// Which song the player is on, from which list, and whether it plays, for
/// rows and Play buttons deep inside a page (Stats, the Calendar panel, the
/// year report).
class NowPlaying extends InheritedWidget {
  const NowPlaying({
    super.key,
    required this.trackId,
    required this.playing,
    this.contextIds = const [],
    this.onPlayOrPause,
    required super.child,
  });

  /// The current song's id; null when nothing is loaded.
  final int? trackId;

  /// Whether sound plays (false while paused).
  final bool playing;

  /// The ids of the list the current song was started from (next and
  /// previous move in it).
  final List<int> contextIds;

  /// Pauses or resumes the current song.
  final VoidCallback? onPlayOrPause;

  static NowPlaying? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NowPlaying>();

  /// For a row of song [id]: null when it is not the current song (or there
  /// is no scope), true when it plays, false when it is paused.
  static bool? stateFor(BuildContext context, int id) {
    final now = _of(context);
    if (now == null || now.trackId != id) return null;
    return now.playing;
  }

  /// For a button that plays [songs] as a list: null when the current song
  /// was not started from this same list, else whether it plays. As in
  /// Spotify, such a button shows Pause while its list plays.
  static bool? listStateFor(BuildContext context, List<Track> songs) {
    final now = _of(context);
    if (now == null || now.trackId == null) return null;
    final ids = now.contextIds;
    if (ids.length != songs.length) return null;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != songs[i].id) return null;
    }
    if (!ids.contains(now.trackId)) return null;
    return now.playing;
  }

  /// Pauses or resumes the current song; false when there is no scope.
  static bool playOrPause(BuildContext context) {
    final now = context.getInheritedWidgetOfExactType<NowPlaying>();
    final toggle = now?.onPlayOrPause;
    if (toggle == null) return false;
    toggle();
    return true;
  }

  @override
  bool updateShouldNotify(NowPlaying oldWidget) =>
      trackId != oldWidget.trackId ||
      playing != oldWidget.playing ||
      !_sameIds(contextIds, oldWidget.contextIds);

  static bool _sameIds(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Puts a [NowPlaying] over [child] that follows [playback]. The child is
/// the same widget across changes, so only the rows that read the scope
/// rebuild.
class NowPlayingScope extends StatefulWidget {
  const NowPlayingScope({
    super.key,
    required this.playback,
    required this.child,
  });

  final PlaybackController playback;
  final Widget child;

  @override
  State<NowPlayingScope> createState() => _NowPlayingScopeState();
}

class _NowPlayingScopeState extends State<NowPlayingScope> {
  /// The list the ids below were read from, so a new list is read once.
  List<Track>? _context;
  List<int> _contextIds = const [];

  List<int> _idsOf(List<Track> context) {
    if (!identical(context, _context)) {
      _context = context;
      _contextIds = List.unmodifiable([for (final t in context) t.id]);
    }
    return _contextIds;
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final player = playback.player;
    return StreamBuilder<Track?>(
      stream: player.currentStream,
      initialData: player.current,
      builder: (context, current) => ListenableBuilder(
        listenable: Listenable.merge([player.playing, playback]),
        builder: (context, _) => NowPlaying(
          trackId: current.data?.id,
          playing: player.playing.value,
          contextIds: _idsOf(playback.queue.context),
          onPlayOrPause: playback.playOrPause,
          child: widget.child,
        ),
      ),
    );
  }
}

/// The mark of the current song: three bars that move while it plays, as
/// Spotify's, and a still pause sign while it is paused. With reduced motion
/// (the system's "show animations" off) the bars stand still.
class PlayingMark extends StatefulWidget {
  const PlayingMark({
    super.key,
    required this.playing,
    required this.size,
    required this.color,
  });

  final bool playing;
  final double size;
  final Color color;

  /// One loop of the bars. Each bar moves a whole number of times per loop,
  /// so the loop joins without a jump.
  static const period = Duration(milliseconds: 2400);

  @override
  State<PlayingMark> createState() => _PlayingMarkState();
}

class _PlayingMarkState extends State<PlayingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: PlayingMark.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _follow();
  }

  @override
  void didUpdateWidget(PlayingMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _follow();
  }

  /// Runs the loop only while the song plays and motion is allowed.
  void _follow() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.playing && !still) {
      if (!_loop.isAnimating) _loop.repeat();
    } else if (_loop.isAnimating) {
      _loop.stop();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.playing) {
      return Icon(Icons.pause_rounded, size: widget.size, color: widget.color);
    }
    // Its own layer: the bars repaint every frame, the row around them not.
    return RepaintBoundary(
      child: CustomPaint(
        key: const ValueKey('playing-bars'),
        size: Size.square(widget.size),
        painter: PlayingBarsPainter(_loop, widget.color),
      ),
    );
  }
}

/// Paints the three bars at the loop's point in time.
class PlayingBarsPainter extends CustomPainter {
  PlayingBarsPainter(this.loop, this.color) : super(repaint: loop);

  final Animation<double> loop;
  final Color color;

  /// Moves per loop and starting phase of each bar: different speeds, so
  /// the bars never move together.
  static const _moves = [3, 4, 5];
  static const _phases = [0.0, 0.35, 0.7];

  /// Each bar's height as a share of the mark's height (0.2 to 1).
  List<double> heights() {
    final t = loop.value;
    return [
      for (var i = 0; i < 3; i++)
        0.6 + 0.4 * math.sin(2 * math.pi * (_moves[i] * t + _phases[i])),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final barWidth = size.width * 0.22;
    final gap = (size.width - 3 * barWidth) / 4;
    final tall = size.height * 0.8;
    final bottom = size.height * 0.9;
    final radius = Radius.circular(barWidth / 2);
    for (final (i, share) in heights().indexed) {
      final left = gap + i * (barWidth + gap);
      final height = tall * share;
      canvas.drawRRect(
        RRect.fromLTRBR(left, bottom - height, left + barWidth, bottom, radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(PlayingBarsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.loop != loop;
}

/// A song's cover with the playing mark over it while it is the current song
/// ([NowPlaying] decides, unless [current] is given).
class MarkedTile extends StatelessWidget {
  const MarkedTile({
    super.key,
    required this.track,
    required this.size,
    required this.radius,
    this.cover,
  });

  /// The song the row stands for.
  final Track track;

  /// The tile to show when it differs from the song's own (an album's
  /// cover in an album's place).
  final Track? cover;

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final state = NowPlaying.stateFor(context, track.id);
    final tile = TrackTile(track: cover ?? track, size: size, radius: radius);
    if (state == null) return tile;
    return Stack(
      alignment: Alignment.center,
      children: [
        tile,
        Container(
          key: const ValueKey('playing-mark'),
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xB30A0C10),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: PlayingMark(
            playing: state,
            size: (size * 0.5).clamp(16, 22),
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
