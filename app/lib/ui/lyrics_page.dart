/// The Lyrics place (plan 10, mockup C picked 2026-11-21): the playing
/// song's lyrics in the main area. Timed lines follow the song with the
/// current line bright, about a third down; a click on a line jumps there.
/// Scrolling by hand pauses the following for a few seconds, as in Spotify.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/scheduler.dart' show Ticker;

import '../library/track.dart';
import '../lyrics/heard_lyrics.dart';
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_edit.dart';
import '../lyrics/lyrics_hearer.dart';
import '../lyrics/lyrics_sources.dart' show lyricsSourceLabel;
import 'hear_words_ui.dart';
import 'theme.dart';

/// Below this width the lines get a smaller size.
const lyricsNarrowWidth = 640.0;

/// Below this width of the place every Lyrics heading button is an icon
/// (the heading's rule, user 2026-11-25: words for all buttons or none):
/// with words, Timing, Fit to recording, Hear the words, Edit and Choose
/// lyrics need about 700 px beside the title (measured in the shots), and
/// Words / Lines (plan 10 J6) about 100 more.
const lyricsHeadingWordsWidth = 1000.0;

/// How long a hand scroll stops the lines from following the song.
const lyricsHandScrollPause = Duration(seconds: 4);

/// A line is lit this much before its start time: the screen takes a
/// moment to show it, and singers come in a little early.
const lyricsLeadMs = 120;

/// A word is lit this much before its start time (plan 10 J6): the same
/// lead as a line's, so the line sung changes when its first word starts
/// (with a shorter lead the last word of a line lost the end of its fill
/// and the next line began with none lit: Codex review).
const lyricsWordLeadMs = lyricsLeadMs;

/// Between two position reports the lit words move on by the clock, for at
/// most this long: a paused song stops reporting, and its words stop soon.
const lyricsWordGlideMs = 300;

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
    this.onWrite,
    this.hearer,
    this.byWord = true,
    this.isPlaying,
  });

  final LyricsController lyrics;

  /// Whether the song plays now; the lit words move on between position
  /// reports only while it does. Null counts as playing.
  final bool Function()? isPlaying;

  /// Lyrics with word times light each word as it is sung (plan 10 J6);
  /// false follows by whole lines.
  final bool byWord;

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

  /// Opens the editor empty from the "No lyrics found" message (I2g).
  final VoidCallback? onWrite;

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
          HearProgressStrip(
            hearer: hearer,
            stage: hearing,
            again: switch (widget.lyrics.state) {
              LyricsShown(:final lyrics) => lyrics.source == heardSource,
              _ => false,
            },
          ),
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
        final write = widget.onWrite == null
            ? null
            : OutlinedButton(
                key: const ValueKey('lyrics-write'),
                onPressed: widget.onWrite,
                child: const Text('Write them yourself'),
              );
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
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('hear-words'),
                      onPressed: canHear
                          ? () => unawaited(hearShownWords(context, hearer))
                          : null,
                      icon: const Icon(Icons.hearing, size: 20),
                      label: Text(
                        hearButtonLabel(
                          heard,
                          hearer.languageFor(widget.lyrics.shownKey),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // The language for this song (plan 10 I2j).
                  HearLanguageArrow(hearer: hearer, enabled: canHear),
                ],
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
                  'down what is sung, about '
                  '${hearer.onGpu ? '15 to 40 seconds' : '1 to 6 minutes'} '
                  'a song.'
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
            ?write,
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
          byWord: widget.byWord,
          isPlaying: widget.isPlaying,
          header: Text(
            heardCredit(heard, yours: yours, refreshing: refreshing),
            key: const ValueKey('lyrics-credit'),
            style: TextStyle(color: colors.dim2, fontSize: 13),
          ),
        );
      case LyricsShown(:final lyrics) when lyrics.source == editedSource:
        final fitted = widget.lyrics.isFitted(lyrics);
        return LyricsLines(
          lyrics: widget.lyrics.timedOf(lyrics),
          offsetMs: widget.lyrics.offsetOf(lyrics.source),
          position: widget.position,
          positions: widget.positions,
          seek: widget.seek,
          byWord: widget.byWord,
          isPlaying: widget.isPlaying,
          header: Text(
            '${editCredit(widget.lyrics.edit?.basedOn)}'
            '${fitted
                ? ', fitted to this recording'
                : lyrics.timed
                ? ''
                : '; words only'}',
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
          byWord: widget.byWord,
          isPlaying: widget.isPlaying,
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
    '${heardLanguageNote(heard)}'
    '${yours ? ' (your choice)' : ''}'
    '${heard?.rough ?? false ? '; rough: some words may be wrong' : ''}'
    '${refreshing ? '; asking the sources for lyrics...' : ''}';

/// The credit line over the user's edit (I2g): what it started from.
String editCredit(String? basedOn) => switch (basedOn) {
  null => 'Written by you',
  heardSource => 'Edited by you, from the words the app heard',
  final source => "Edited by you, from ${lyricsSourceLabel(source)}'s lyrics",
};

/// The user's moved timing in words (F1): "lines 1.5 s later".
String lyricsOffsetText(int offsetMs) {
  final seconds = (offsetMs.abs() / 1000).toStringAsFixed(1);
  return 'lines $seconds s ${offsetMs > 0 ? 'later' : 'earlier'}';
}

/// The Lyrics heading's timing stepper (F1): earlier, the moved time (a
/// click there goes back to the source's timing), later; each press moves
/// the lines [lyricsOffsetStepMs], like a player's subtitle delay.
class LyricsTimingControl extends StatelessWidget {
  const LyricsTimingControl({
    super.key,
    required this.lyrics,
    this.compact = false,
  });

  final LyricsController lyrics;

  /// Icons only (the heading's rule): the middle word "Timing" goes; a
  /// moved time still shows, as it says how far the lines are moved.
  final bool compact;

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
        if (!compact || offset != 0)
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

/// The Lyrics heading's Lines / Words button (plan 10 J6, user 2026-11-26:
/// "In the Lyrics heading"): shown only for lyrics with word times; its
/// label says how the lyrics follow the song now, a click switches.
class LyricsFollowButton extends StatelessWidget {
  const LyricsFollowButton({
    super.key,
    required this.byWord,
    required this.onChanged,
    this.compact = false,
  });

  final bool byWord;
  final ValueChanged<bool> onChanged;

  /// An icon alone (the heading's rule), its words in the tooltip.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = byWord ? 'Words' : 'Lines';
    final tip = byWord
        ? 'Each word lights as it is sung. Click to light whole lines'
        : 'Whole lines light as they are sung. Click to light each word';
    final icon = byWord ? Icons.short_text : Icons.view_headline;
    return compact
        ? IconButton(
            key: const ValueKey('lyrics-follow'),
            tooltip: '$label. $tip',
            onPressed: () => onChanged(!byWord),
            icon: Icon(icon),
          )
        : Tooltip(
            message: tip,
            child: TextButton.icon(
              key: const ValueKey('lyrics-follow'),
              onPressed: () => onChanged(!byWord),
              icon: Icon(icon, size: 20),
              label: Text(label),
            ),
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
    this.byWord = true,
    this.isPlaying,
  });

  final Lyrics lyrics;
  final Widget header;

  /// The current line's words light as they are sung where it has word
  /// times (plan 10 J6).
  final bool byWord;

  /// Whether the song plays now (null: playing): a paused song's words do
  /// not move on by the clock (Codex review).
  final bool Function()? isPlaying;

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

  /// The last position the player reported, and the clock since: the lit
  /// words move on between reports (plan 10 J6).
  int? _reportedMs;
  final _sinceReport = Stopwatch();

  /// Counts the reports, so a word-lit line wakes its clock on each.
  final _reports = ValueNotifier<int>(0);

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
    _reports.dispose();
    super.dispose();
  }

  /// The song's time now for lighting words: the last report moved on by
  /// the clock (at most [lyricsWordGlideMs]), with the word lead and the
  /// user's offset.
  int _wordNowMs() {
    final reported = _reportedMs;
    final playing = widget.isPlaying?.call() ?? true;
    final at = reported == null
        ? widget.position().inMilliseconds
        : reported +
              (playing
                  ? math.min<int>(
                      _sinceReport.elapsedMilliseconds,
                      lyricsWordGlideMs,
                    )
                  : 0);
    return at + lyricsWordLeadMs - widget.offsetMs;
  }

  /// Whether the clock still moves the words: a report came lately.
  bool _wordsMoving() =>
      _reportedMs != null &&
      (widget.isPlaying?.call() ?? true) &&
      _sinceReport.elapsedMilliseconds <= lyricsWordGlideMs;

  /// New lyrics get new line keys and start at the line sung now.
  void _takeLyrics() {
    final lyrics = widget.lyrics;
    _lineKeys = [for (final _ in lyrics.lines) GlobalKey()];
    _line = _lineAt(widget.position());
    _handScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _revealLine(animate: false);
  }

  void _follow(Duration at) {
    _reportedMs = at.inMilliseconds;
    _sinceReport
      ..reset()
      ..start();
    _reports.value++;
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
                      words:
                          i == _line &&
                              widget.byWord &&
                              lyrics.lines[i].hasWordTimes
                          ? (
                              nowMs: _wordNowMs,
                              moving: _wordsMoving,
                              reports: _reports,
                              unsung: colors.dim,
                            )
                          : null,
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
    this.words,
  });

  final int index;
  final LyricLine line;
  final double size;
  final Color color;
  final bool current;
  final VoidCallback onTap;

  /// For the line sung now with word times (plan 10 J6): the song's time
  /// for its words, whether that time still moves, the position reports,
  /// and the color of the words not sung yet. Null lights the whole line.
  final _WordClock? words;

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
            child: words == null || line.isGap
                ? Text(line.isGap ? '...' : line.text)
                : _WordLitLine(line: line, clock: words!, sung: color),
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

/// What a word-lit line needs from the lines' state (plan 10 J6).
typedef _WordClock = ({
  int Function() nowMs,
  bool Function() moving,
  ValueListenable<int> reports,
  Color unsung,
});

/// The line sung now with its words lit as they are sung (plan 10 J6, user
/// 2026-11-26: try the smooth fill first): the words sung are in the line's
/// own color, the word being sung fills from its left to its right, the
/// rest are in the color of lines not sung yet. Two [Text]s of the same
/// words and style lie on each other, so they lay out alike (bold text and
/// spacing overrides of the system included: Codex review); the lower one
/// is in the unsung color and carries the line's semantics, the upper one
/// in the sung color is clipped to the sung words. A clock re-clips only
/// this line (its own repaint layer), and only while the song moves.
class _WordLitLine extends StatefulWidget {
  const _WordLitLine({
    required this.line,
    required this.clock,
    required this.sung,
  });

  final LyricLine line;
  final _WordClock clock;
  final Color sung;

  @override
  State<_WordLitLine> createState() => _WordLitLineState();
}

class _WordLitLineState extends State<_WordLitLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final ValueNotifier<int> _now = ValueNotifier(widget.clock.nowMs());
  final _sungText = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.clock.reports.addListener(_wake);
    _wake();
  }

  @override
  void didUpdateWidget(_WordLitLine old) {
    super.didUpdateWidget(old);
    if (old.clock.reports != widget.clock.reports) {
      old.clock.reports.removeListener(_wake);
      widget.clock.reports.addListener(_wake);
    }
    _now.value = widget.clock.nowMs();
  }

  @override
  void dispose() {
    widget.clock.reports.removeListener(_wake);
    _ticker.dispose();
    _now.dispose();
    super.dispose();
  }

  /// The clock's time at the last report, and its time now: frame times,
  /// so the stop below follows the frames (and a test's fake time).
  Duration _reportAt = Duration.zero;
  Duration _tickAt = Duration.zero;

  /// A report came: the clock runs until the reports stop. The first one
  /// may have come just before this line became the one sung.
  void _wake() {
    _now.value = widget.clock.nowMs();
    if (_ticker.isActive) {
      _reportAt = _tickAt;
    } else if (widget.clock.moving()) {
      _reportAt = _tickAt = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    _tickAt = elapsed;
    _now.value = widget.clock.nowMs();
    // No report for longer than the glide, or paused: the clock stops, and
    // a paused song asks for no frames.
    if (!widget.clock.moving() ||
        elapsed - _reportAt >
            const Duration(milliseconds: lyricsWordGlideMs + 100)) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.line.text;
    return RepaintBoundary(
      child: Stack(
        children: [
          Text(text, style: TextStyle(color: widget.clock.unsung)),
          Positioned.fill(
            child: ExcludeSemantics(
              child: ClipPath(
                clipper: _SungClip(
                  paragraph: _sungText,
                  text: text,
                  words: widget.line.words!,
                  now: _now,
                ),
                child: Text(
                  text,
                  key: _sungText,
                  style: TextStyle(color: widget.sung),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The part of the sung [Text] ([paragraph]) to show at [now]: whole words
/// that ended, and the word being sung up to the share of its time gone
/// ([sungWordShares]), measured on that Text's own layout.
class _SungClip extends CustomClipper<Path> {
  _SungClip({
    required this.paragraph,
    required this.text,
    required this.words,
    required this.now,
  }) : super(reclip: now);

  final GlobalKey paragraph;
  final String text;
  final List<WordTime?> words;
  final ValueListenable<int> now;

  @override
  Path getClip(Size size) {
    final clip = Path();
    final render = paragraph.currentContext?.findRenderObject();
    if (render is! RenderParagraph || !render.hasSize) return clip;
    final spans = RegExp(r'\S+').allMatches(text).toList();
    if (spans.length != words.length) return clip;
    final shares = sungWordShares(words, now.value);
    for (var i = 0; i < words.length; i++) {
      final share = shares[i];
      if (share <= 0) continue;
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: spans[i].start, extentOffset: spans[i].end),
      );
      final width = boxes.fold<double>(
        0,
        (sum, box) => sum + box.right - box.left,
      );
      var left = width * share;
      for (final box in boxes) {
        if (left <= 0) break;
        final take = math.min(left, box.right - box.left);
        clip.addRect(
          Rect.fromLTRB(box.left, box.top, box.left + take, box.bottom),
        );
        left -= take;
      }
    }
    return clip;
  }

  @override
  bool shouldReclip(_SungClip old) =>
      old.text != text || old.words != words || old.paragraph != paragraph;
}

/// How much of each word of a line is sung at [ms], 0..1 (plan 10 J6): a
/// timed word fills over its own time; a word without a time (a dash,
/// digits) lights once the timed word before it has ended, or (none
/// before) once the next timed word starts.
List<double> sungWordShares(List<WordTime?> words, int ms) {
  final shares = List<double>.filled(words.length, 0);
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (word == null) continue;
    final length = word.endMs - word.startMs;
    shares[i] = ms >= word.endMs
        ? 1
        : ms <= word.startMs
        ? 0
        : length <= 0
        ? 1
        : (ms - word.startMs) / length;
  }
  // Untimed words: lit once the timed word before has ended, or (none
  // before) once the next timed word starts.
  int? lastEnd;
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (word != null) {
      lastEnd = word.endMs;
      continue;
    }
    var lit = lastEnd != null && ms >= lastEnd;
    if (lastEnd == null) {
      for (var j = i + 1; j < words.length; j++) {
        final next = words[j];
        if (next != null) {
          lit = ms >= next.startMs;
          break;
        }
      }
    }
    shares[i] = lit ? 1 : 0;
  }
  return shares;
}
