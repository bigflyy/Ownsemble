/// The Lyrics place (plan 10, mockup C picked 2026-11-21): the playing
/// song's lyrics in the main area. Timed lines follow the song with the
/// current line bright, about a third down; a click on a line jumps there.
/// Scrolling by hand pauses the following for a few seconds, as in Spotify.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../lyrics/heard_lyrics.dart';
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_hearer.dart';
import '../lyrics/lyrics_sources.dart' show lyricsSourceLabel;
import 'hear_words_ui.dart';
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
    this.onChoose,
    this.hearer,
  });

  final LyricsController lyrics;

  /// "Hear the words" for songs no source has lyrics for (I2f); no button
  /// when null.
  final LyricsHearer? hearer;

  /// The playing song now, and every change of it.
  final Track? Function() current;
  final Stream<Track?> currentStream;

  /// Where the playing song is now, and every position while it plays:
  /// null until the player is ready, so it is asked again until it comes.
  final Duration Function() position;
  final Stream<Duration>? Function() positions;
  final Future<void> Function(Duration to) seek;

  /// Opens the chooser of every source's lyrics (E2) from the "No lyrics
  /// found" message; the place's heading has its own button (a link by the
  /// credit line scrolled away with following lines: shots-41).
  final VoidCallback? onChoose;

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  StreamSubscription<Track?>? _current;

  /// Shows the spinner only when an answer takes a while.
  Timer? _spinnerTimer;
  bool _spinnerDue = false;

  @override
  void initState() {
    super.initState();
    widget.lyrics.addListener(_onLyrics);
    widget.hearer?.addListener(_onLyrics);
    _current = widget.currentStream.listen(widget.lyrics.show);
    // The controller tells its listeners at once; not while building. A
    // place opened anew looks again at a song whose ask failed before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.lyrics.show(widget.current(), again: true);
    });
    _takeState();
  }

  @override
  void dispose() {
    widget.lyrics.removeListener(_onLyrics);
    widget.hearer?.removeListener(_onLyrics);
    unawaited(_current?.cancel());
    _spinnerTimer?.cancel();
    super.dispose();
  }

  void _onLyrics() {
    _takeState();
    if (mounted) setState(() {});
  }

  void _takeState() {
    _spinnerTimer?.cancel();
    _spinnerDue = false;
    if (widget.lyrics.state is LyricsLoading) {
      _spinnerTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _spinnerDue = true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hearer = widget.hearer;
    final hearing = hearer?.stageOf(widget.lyrics.shownKey);
    final content = _content(context);
    // Words on show while the song is heard (again): Stop stays at hand
    // above them (Codex review of I2f).
    if (hearer != null &&
        hearing != null &&
        widget.lyrics.state is LyricsShown) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HearProgressStrip(hearer: hearer, stage: hearing),
          Expanded(child: content),
        ],
      );
    }
    return content;
  }

  Widget _content(BuildContext context) {
    final colors = OwnColors.of(context);
    final state = widget.lyrics.state;
    final track = widget.lyrics.track;
    final choose = widget.onChoose;
    if (track == null) {
      return lyricsMessage(context, 'Play a song to see its lyrics.');
    }
    final hearer = widget.hearer;
    final hearing = hearer?.stageOf(widget.lyrics.shownKey);
    // A run of this song shows instead of "no lyrics" (its words are not
    // there yet); heard words being heard again stay on show.
    if (hearer != null && hearing != null && state is! LyricsShown) {
      return HearProgressPanel(hearer: hearer, stage: hearing);
    }
    switch (state) {
      case LyricsLoading():
        return _spinnerDue
            ? LayoutBuilder(
                builder: (context, constraints) => Padding(
                  padding: EdgeInsets.fromLTRB(
                    constraints.maxWidth < lyricsNarrowWidth ? 24 : 56,
                    48,
                    24,
                    24,
                  ),
                  child: const Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      key: ValueKey('lyrics-loading'),
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink();
      case LyricsMissing(:final heard):
        final seeAll = choose == null
            ? null
            : OutlinedButton(
                key: const ValueKey('lyrics-choose'),
                onPressed: choose,
                child: const Text('See every source'),
              );
        final other = hearer?.job;
        final canHear = hearer != null && track.inLibrary && other == null;
        final hear = hearer == null
            ? null
            : FilledButton.tonalIcon(
                key: const ValueKey('hear-words'),
                onPressed: canHear
                    ? () => unawaited(hearShownWords(context, hearer))
                    : null,
                icon: const Icon(Icons.hearing, size: 20),
                label: Text(heard == null ? 'Hear the words' : 'Hear again'),
              );
        final note = hearer == null
            ? null
            : other != null
            ? 'Another song is being heard now'
                  '${other.track.title.isEmpty ? '' : ': ${other.track.title}'}'
                  '. One song at a time.'
            : !track.inLibrary
            ? 'Add the song to your library to hear its words.'
            : heard == null
            ? 'Hear the words listens to the recording on this PC and writes '
                  'down what is sung, about 2 to 5 minutes a song.'
            : null;
        return lyricsMessage(
          context,
          switch (heard?.outcome) {
            HeardOutcome.noSinging =>
              'No singing found in this song: the app listened to the '
                  'recording and heard no voice.',
            HeardOutcome.noWords =>
              'The app heard a voice in this song but could not make out '
                  'the words.',
            _ => 'No lyrics found for this song.',
          },
          actions: [
            // Hearing again finds no voice where none was found.
            if (hear != null && heard?.outcome != HeardOutcome.noSinging) hear,
            ?seeAll,
          ],
          note: note,
        );
      case LyricsFailed(:final reason):
        return lyricsMessage(
          context,
          reason,
          action: FilledButton.tonal(
            key: const ValueKey('lyrics-retry'),
            onPressed: widget.lyrics.retry,
            child: const Text('Try again'),
          ),
        );
      case LyricsShown(:final lyrics, :final refreshing)
          when lyrics.source == heardSource:
        final heard = widget.lyrics.heard;
        final yours = widget.lyrics.chosen == heardSource;
        return LyricsLines(
          lyrics: widget.lyrics.timedOf(lyrics),
          offsetMs: widget.lyrics.offsetOf(lyrics.source),
          position: widget.position,
          positions: widget.positions,
          seek: widget.seek,
          header: Text(
            heardCredit(heard, yours: yours, refreshing: refreshing),
            key: const ValueKey('lyrics-credit'),
            style: TextStyle(color: colors.dim2, fontSize: 13),
          ),
        );
      case LyricsShown(:final lyrics, :final refreshing):
        final label = lyricsSourceLabel(lyrics.source);
        final yours = widget.lyrics.chosen == lyrics.source;
        final fitted = widget.lyrics.isFitted(lyrics);
        final other = widget.lyrics.otherVersionOf(lyrics);
        final version = other == null
            ? ''
            : 'another version (${LyricsController.otherLengthText(other)})';
        // Plain words of another version say whether a fit timed them
        // (Codex review of H2).
        final credit = other != null && !lyrics.timed
            ? fitted
                  ? 'Words of $version, from $label, timed by fitting to this '
                        'recording'
                  : widget.lyrics.fitFor(lyrics) != null
                  ? 'Words of $version, from $label: they could not be '
                        'matched to this recording'
                  : 'Words of $version, from $label'
            : other != null
            ? fitted
                  ? 'From $label, $version, fitted to this recording'
                  : widget.lyrics.fitFor(lyrics) != null
                  ? 'Words of $version, from $label: they do not fit this '
                        'recording'
                  : 'Words of $version, from $label. Fit them to this '
                        'recording to time them.'
            : lyrics.timed
            ? 'From $label${yours ? ' (your choice)' : ''}'
                  '${fitted ? ', fitted to this recording' : ''}'
            // Plain words timed by a fit, or a fit that did not match (H2).
            : fitted
            ? 'Words from $label${yours ? ' (your choice)' : ''}, timed by '
                  'fitting to this recording'
            : widget.lyrics.fitFor(lyrics) != null
            ? 'Words only, from $label: they could not be matched to this '
                  'recording'
            : yours
            ? 'Words only, from $label (your choice)'
            : refreshing
            ? 'Words only, from $label; looking for timed lyrics...'
            : 'Words only, from $label: no source has times for this song';
        return LyricsLines(
          lyrics: widget.lyrics.timedOf(lyrics),
          offsetMs: widget.lyrics.offsetOf(lyrics.source),
          position: widget.position,
          positions: widget.positions,
          seek: widget.seek,
          header: Text(
            credit,
            key: const ValueKey('lyrics-credit'),
            style: TextStyle(color: colors.dim2, fontSize: 13),
          ),
        );
    }
  }
}

/// The credit line over heard words (I2f): where they come from, and the
/// rough mark of words the models were not sure of.
String heardCredit(
  HeardLyrics? heard, {
  bool yours = false,
  bool refreshing = false,
}) =>
    'Heard by the app from this recording'
    '${yours ? ' (your choice)' : ''}'
    '${heard?.rough ?? false ? '; rough: some words may be wrong' : ''}'
    '${refreshing ? '; asking the sources for lyrics...' : ''}';

/// The user's moved timing in words (F1): "lines 1.5 s later".
String lyricsOffsetText(int offsetMs) {
  final seconds = (offsetMs.abs() / 1000).toStringAsFixed(1);
  return 'lines $seconds s ${offsetMs > 0 ? 'later' : 'earlier'}';
}

/// The Lyrics heading's timing stepper (F1): earlier, the moved time (a
/// click there goes back to the source's timing), later; each press moves
/// the lines [lyricsOffsetStepMs], like a player's subtitle delay.
class LyricsTimingControl extends StatelessWidget {
  const LyricsTimingControl({super.key, required this.lyrics});

  final LyricsController lyrics;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final offset = lyrics.shownOffset;
    final step = (lyricsOffsetStepMs / 1000).toStringAsFixed(1);
    final seconds = (offset.abs() / 1000).toStringAsFixed(1);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('lyrics-earlier'),
          tooltip: 'Lines earlier by $step s',
          onPressed: offset <= -lyricsOffsetLimitMs
              ? null
              : () => lyrics.shiftShown(-lyricsOffsetStepMs),
          icon: const Icon(Icons.remove),
        ),
        Tooltip(
          message: offset == 0
              ? 'Move the lines when they come too early or too late'
              : "Back to the source's timing",
          child: TextButton(
            key: const ValueKey('lyrics-offset'),
            style: TextButton.styleFrom(
              minimumSize: const Size(56, 40),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              foregroundColor: colors.text,
              disabledForegroundColor: colors.dim,
            ),
            onPressed: offset == 0
                ? null
                : () => lyrics.setOffset(lyrics.shownSource!, 0),
            child: Text(
              offset == 0 ? 'Timing' : '${offset > 0 ? '+' : '-'}$seconds s',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('lyrics-later'),
          tooltip: 'Lines later by $step s',
          onPressed: offset >= lyricsOffsetLimitMs
              ? null
              : () => lyrics.shiftShown(lyricsOffsetStepMs),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// A message in the lyrics places' style (no song, none, a failure), with
/// an optional button under it. It scrolls in a window too short for the
/// text and its button (the smallest window over For You left 132 px: B25's
/// test).
Widget lyricsMessage(
  BuildContext context,
  String text, {
  Widget? action,
  List<Widget> actions = const [],
  String? note,
}) {
  final buttons = [?action, ...actions];
  final colors = OwnColors.of(context);
  return LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < lyricsNarrowWidth;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(narrow ? 24 : 56, 48, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              key: const ValueKey('lyrics-message'),
              style: TextStyle(color: colors.dim, fontSize: narrow ? 16 : 18),
            ),
            if (buttons.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 12, runSpacing: 8, children: buttons),
            ],
            if (note != null) ...[
              const SizedBox(height: 12),
              Text(
                note,
                key: const ValueKey('lyrics-note'),
                style: TextStyle(color: colors.dim2, fontSize: 13),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// One source's lyrics under a [header] line: timed lines follow the song
/// with the current line bright, about a third down, and a click on a line
/// jumps there; plain lines scroll by hand and can be selected. Scrolling
/// by hand pauses the following for a few seconds, as in Spotify. Used by
/// the Lyrics place and the chooser's preview.
class LyricsLines extends StatefulWidget {
  const LyricsLines({
    super.key,
    required this.lyrics,
    required this.header,
    required this.position,
    required this.positions,
    required this.seek,
    this.offsetMs = 0,
  });

  final Lyrics lyrics;
  final Widget header;

  /// How far the user moved the lines (F1), milliseconds: > 0 lights each
  /// line later than its start time, and a click on it jumps later too.
  final int offsetMs;
  final Duration Function() position;
  final Stream<Duration>? Function() positions;
  final Future<void> Function(Duration to) seek;

  @override
  State<LyricsLines> createState() => _LyricsLinesState();
}

class _LyricsLinesState extends State<LyricsLines> {
  final _scroll = ScrollController();
  List<GlobalKey> _lineKeys = const [];

  /// The line sung now; -1 before the first or for plain lyrics.
  int _line = -1;

  /// Until when a hand scroll keeps the lines where the user put them.
  DateTime _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Ends the pause a hand scroll made; one at a time.
  Timer? _handScrollTimer;

  /// Asks for the player's positions until it is ready (the place can open
  /// on a restored song while the player still starts: Codex review).
  Timer? _positionsTimer;
  StreamSubscription<Duration>? _positions;

  @override
  void initState() {
    super.initState();
    if (!_listenToPositions()) {
      _positionsTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) {
        if (_listenToPositions()) timer.cancel();
      });
    }
    _takeLyrics();
  }

  @override
  void didUpdateWidget(LyricsLines old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _takeLyrics();
    } else if (old.offsetMs != widget.offsetMs) {
      // Moved timing: the line sung now changes at once, even when paused.
      _line = _lineAt(widget.position());
      _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _revealLine();
    }
  }

  /// The line sung at [at] with the lead and the user's offset.
  int _lineAt(Duration at) =>
      widget.lyrics.lineAt(at.inMilliseconds + lyricsLeadMs - widget.offsetMs);

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
    unawaited(_positions?.cancel());
    _positionsTimer?.cancel();
    _handScrollTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// New lyrics get new line keys and start at the line sung now.
  void _takeLyrics() {
    final lyrics = widget.lyrics;
    _lineKeys = [for (final _ in lyrics.lines) GlobalKey()];
    _line = _lineAt(widget.position());
    _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _revealLine(animate: false);
  }

  void _follow(Duration at) {
    final lyrics = widget.lyrics;
    if (!lyrics.timed) return;
    final line = _lineAt(at);
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
    final line = widget.lyrics.lines[index];
    final start = line.startMs;
    if (start == null || line.label || line.passed) return;
    _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
    setState(() => _line = index);
    _revealLine();
    final to = start + widget.offsetMs;
    unawaited(widget.seek(Duration(milliseconds: to < 0 ? 0 : to)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < lyricsNarrowWidth;
        final side = narrow ? 24.0 : 56.0;
        final lyrics = widget.lyrics;
        return lyrics.timed
            ? _timed(lyrics, colors, narrow, side, constraints.maxHeight)
            : _plain(lyrics, colors, narrow, side);
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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: widget.header,
                  ),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.header,
              const SizedBox(height: 14),
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
            ],
          ),
        ),
      ),
    );
  }
}

// One timed line: a button that jumps to it; a gap shows three dots.
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
    if (line.label) return _label(context);
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

  /// A label row (a section header in fitted plain words, H5): small and
  /// dim, never lit, nothing to click.
  Widget _label(BuildContext context) {
    final colors = OwnColors.of(context);
    return Semantics(
      header: true,
      child: Padding(
        key: ValueKey('lyrics-label-$index'),
        padding: EdgeInsets.only(top: size * 0.5, bottom: size * 0.12),
        child: Text(
          line.text,
          style: DefaultTextStyle.of(context).style.copyWith(
            color: colors.dim,
            fontSize: size * 0.55,
            height: 1.3,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}
