/// The Lyrics place (plan 10, mockup C picked 2026-11-21): the playing
/// song's lyrics in the main area. Timed lines follow the song with the
/// current line bright, about a third down; a click on a line jumps there.
/// Scrolling by hand pauses the following for a few seconds, as in Spotify.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import 'theme.dart';

/// Below this width the lines get a smaller size.
const lyricsNarrowWidth = 640.0;

/// How long a hand scroll stops the lines from following the song.
const lyricsHandScrollPause = Duration(seconds: 4);

/// A line is lit this much before its start time: the screen takes a
/// moment to show it, and singers come in a little early.
const lyricsLeadMs = 120;

class LyricsPage extends StatefulWidget {
  const LyricsPage({
    super.key,
    required this.lyrics,
    required this.current,
    required this.currentStream,
    required this.position,
    required this.positions,
    required this.seek,
  });

  final LyricsController lyrics;

  /// The playing song now, and every change of it.
  final Track? Function() current;
  final Stream<Track?> currentStream;

  /// Where the playing song is now, and every position while it plays:
  /// null until the player is ready, so it is asked again until it comes.
  final Duration Function() position;
  final Stream<Duration>? Function() positions;
  final Future<void> Function(Duration to) seek;

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  final _scroll = ScrollController();
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// The lyrics the line keys below belong to.
  Lyrics? _shown;
  List<GlobalKey> _lineKeys = const [];

  /// The line sung now; -1 before the first or for plain lyrics.
  int _line = -1;

  /// Until when a hand scroll keeps the lines where the user put them.
  DateTime _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Shows the spinner only when an answer takes a while.
  Timer? _spinnerTimer;
  bool _spinnerDue = false;

  /// Ends the pause a hand scroll made; one at a time.
  Timer? _handScrollTimer;

  /// Asks for the player's positions until it is ready (the place can open
  /// on a restored song while the player still starts: Codex review).
  Timer? _positionsTimer;
  StreamSubscription<Duration>? _positions;

  @override
  void initState() {
    super.initState();
    widget.lyrics.addListener(_onLyrics);
    _subscriptions.add(widget.currentStream.listen(widget.lyrics.show));
    if (!_listenToPositions()) {
      _positionsTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) {
        if (_listenToPositions()) timer.cancel();
      });
    }
    // The controller tells its listeners at once; not while building. A
    // place opened anew looks again at a song whose ask failed before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.lyrics.show(widget.current(), again: true);
    });
    _takeState();
  }

  /// Listens to the player's positions once it has them; true when it does.
  bool _listenToPositions() {
    if (_positions != null) return true;
    final positions = widget.positions();
    if (positions == null) return false;
    _positions = positions.listen(_follow);
    return true;
  }

  @override
  void dispose() {
    widget.lyrics.removeListener(_onLyrics);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_positions?.cancel());
    _positionsTimer?.cancel();
    _handScrollTimer?.cancel();
    _spinnerTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onLyrics() {
    _takeState();
    if (mounted) setState(() {});
  }

  /// Takes in the controller's state: new lyrics get new line keys and
  /// start at the line sung now.
  void _takeState() {
    final state = widget.lyrics.state;
    _spinnerTimer?.cancel();
    _spinnerDue = false;
    if (state is LyricsLoading) {
      _spinnerTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _spinnerDue = true);
      });
    }
    final lyrics = state is LyricsShown ? state.lyrics : null;
    if (lyrics != _shown) {
      _shown = lyrics;
      _lineKeys = [for (final _ in lyrics?.lines ?? const []) GlobalKey()];
      _line =
          lyrics?.lineAt(widget.position().inMilliseconds + lyricsLeadMs) ?? -1;
      _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _revealLine(animate: false);
    }
  }

  void _follow(Duration at) {
    final lyrics = _shown;
    if (lyrics == null || !lyrics.timed) return;
    final line = lyrics.lineAt(at.inMilliseconds + lyricsLeadMs);
    if (line == _line) return;
    setState(() => _line = line);
    _revealLine();
  }

  /// Scrolls the current line to about a third down, after this frame.
  void _revealLine({bool animate = true}) {
    if (_line < 0 || DateTime.now().isBefore(_handScrollUntil)) return;
    final line = _line;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || line >= _lineKeys.length) return;
      final lineContext = _lineKeys[line].currentContext;
      if (lineContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          lineContext,
          alignment: 0.33,
          duration: animate ? const Duration(milliseconds: 350) : Duration.zero,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  bool _onScroll(ScrollNotification notification) {
    // Scrolls the app makes itself (following) are not the user's.
    if (notification is UserScrollNotification ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null)) {
      _handScrollUntil = DateTime.now().add(lyricsHandScrollPause);
      _handScrollTimer?.cancel();
      _handScrollTimer = Timer(lyricsHandScrollPause, () {
        if (!mounted) return;
        _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
        _revealLine();
        // A paused song draws no frames by itself: ask for one.
        WidgetsBinding.instance.scheduleFrame();
      });
    }
    return false;
  }

  void _seekTo(int index) {
    final start = _shown?.lines[index].startMs;
    if (start == null) return;
    _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
    setState(() => _line = index);
    _revealLine();
    unawaited(widget.seek(Duration(milliseconds: start)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final state = widget.lyrics.state;
    final track = widget.lyrics.track;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < lyricsNarrowWidth;
        final side = narrow ? 24.0 : 56.0;
        Widget message(String text, {Widget? action}) => Padding(
          padding: EdgeInsets.fromLTRB(side, 48, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                key: const ValueKey('lyrics-message'),
                style: TextStyle(color: colors.dim, fontSize: narrow ? 16 : 18),
              ),
              if (action != null) ...[const SizedBox(height: 16), action],
            ],
          ),
        );
        if (track == null) return message('Play a song to see its lyrics.');
        switch (state) {
          case LyricsLoading():
            return _spinnerDue
                ? Padding(
                    padding: EdgeInsets.fromLTRB(side, 48, 24, 24),
                    child: const Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        key: ValueKey('lyrics-loading'),
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  )
                : const SizedBox.shrink();
          case LyricsMissing():
            return message(
              track.source == TrackSource.vk
                  ? 'VK has no lyrics for this song.'
                  : 'No lyrics for this song.',
            );
          case LyricsFailed(:final reason):
            return message(
              reason,
              action: FilledButton.tonal(
                key: const ValueKey('lyrics-retry'),
                onPressed: widget.lyrics.retry,
                child: const Text('Try again'),
              ),
            );
          case LyricsShown(:final lyrics):
            return lyrics.timed
                ? _timed(lyrics, colors, narrow, side, constraints.maxHeight)
                : _plain(lyrics, colors, narrow, side);
        }
      },
    );
  }

  Widget _timed(
    Lyrics lyrics,
    OwnColors colors,
    bool narrow,
    double side,
    double height,
  ) {
    final size = narrow ? 24.0 : 30.0;
    // Lines fade out at the top and the bottom instead of being cut.
    final top = (36 / height).clamp(0.0, 0.3);
    final bottom = (1 - 64 / height).clamp(0.7, 1.0);
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0, top, bottom, 1],
      ).createShader(rect),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: SingleChildScrollView(
          key: const ValueKey('lyrics-timed'),
          controller: _scroll,
          // Room below the last line so it can come up to the reading place.
          padding: EdgeInsets.fromLTRB(side, 24, 24, height * 0.6),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < lyrics.lines.length; i++)
                    _TimedLine(
                      key: _lineKeys[i],
                      index: i,
                      line: lyrics.lines[i],
                      size: size,
                      color: i == _line
                          ? colors.text
                          : i < _line
                          ? colors.dim2.withValues(alpha: 0.7)
                          : colors.dim,
                      current: i == _line,
                      onTap: () => _seekTo(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _plain(Lyrics lyrics, OwnColors colors, bool narrow, double side) {
    final size = narrow ? 18.0 : 22.0;
    return SingleChildScrollView(
      key: const ValueKey('lyrics-plain'),
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(side, 20, 24, 64),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Words only: VK has no times for this song',
                  style: TextStyle(color: colors.dim2, fontSize: 13),
                ),
                const SizedBox(height: 14),
                for (final line in lyrics.lines)
                  line.isGap
                      ? SizedBox(height: size * 0.8)
                      : Text(
                          line.text,
                          style: TextStyle(
                            color: colors.text.withValues(alpha: 0.86),
                            fontSize: size,
                            height: 1.55,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One timed line: a button that jumps to it; a gap shows three dots.
class _TimedLine extends StatelessWidget {
  const _TimedLine({
    super.key,
    required this.index,
    required this.line,
    required this.size,
    required this.color,
    required this.current,
    required this.onTap,
  });

  final int index;
  final LyricLine line;
  final double size;
  final Color color;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: current,
      child: InkWell(
        key: ValueKey('lyrics-line-$index'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: size * 0.22),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            // This style replaces the inherited one, so it starts from it:
            // otherwise the app's font family is lost.
            style: DefaultTextStyle.of(context).style.copyWith(
              color: color,
              fontSize: size,
              height: 1.3,
              fontWeight: current ? FontWeight.w700 : FontWeight.w600,
              letterSpacing: -0.2,
            ),
            child: Text(line.isGap ? '...' : line.text),
          ),
        ),
      ),
    );
  }
}
