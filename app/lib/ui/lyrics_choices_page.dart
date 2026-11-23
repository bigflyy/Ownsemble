/// The lyrics chooser (plan 10, E2; user pick 2026-11-22 "List like
/// Versions"): every source's lyrics for the playing song as rows in the
/// Versions place's style, best first. A click on a row previews its
/// lyrics (timed lines follow the song); "Use these lyrics" keeps that
/// choice for the song's upload and returns to the Lyrics place. Sources not
/// asked yet are asked when the place opens.
///
/// With the fit model downloaded and the song stored (G3), timed lyrics are
/// ranked by how well they fit this recording: tagged "fits this recording"
/// or "may not match" and listed best first. When the recording's model
/// output is cached this happens by itself; otherwise a row offers the
/// check (about 20 s).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/track.dart';
import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_fitter.dart';
import 'lyrics_page.dart';
import 'theme.dart';
import 'version_marks.dart' show lengthText;

class LyricsChoicesPage extends StatefulWidget {
  const LyricsChoicesPage({
    super.key,
    required this.lyrics,
    required this.current,
    required this.currentStream,
    required this.position,
    required this.positions,
    required this.seek,
    required this.onUsed,
    this.fitter,
  });

  final LyricsController lyrics;

  /// Ranks timed lyrics by fit (G3); no ranking when null.
  final LyricsFitter? fitter;

  /// The playing song now, and every change of it.
  final Track? Function() current;
  final Stream<Track?> currentStream;

  /// The player's position and positions, for the preview's following.
  final Duration Function() position;
  final Stream<Duration>? Function() positions;
  final Future<void> Function(Duration to) seek;

  /// Called after the user chose lyrics: the place returns to Lyrics.
  final VoidCallback onUsed;

  @override
  State<LyricsChoicesPage> createState() => _LyricsChoicesPageState();
}

class _LyricsChoicesPageState extends State<LyricsChoicesPage> {
  StreamSubscription<Track?>? _current;

  /// The source whose lyrics are previewed; null shows the list.
  String? _preview;

  @override
  void initState() {
    super.initState();
    widget.lyrics.addListener(_onLyrics);
    widget.fitter?.addListener(_onLyrics);
    _current = widget.currentStream.listen((track) {
      if (!mounted) return;
      // Another song: its own list, a preview of the old one closes.
      setState(() => _preview = null);
      _showAndAsk(track);
    });
    // The controller tells its listeners at once; not while building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showAndAsk(widget.current());
    });
  }

  void _showAndAsk(Track? track) {
    widget.lyrics.show(track);
    final fitter = widget.fitter;
    // Ranks what is stored at once, and again once the sources answered.
    unawaited(fitter?.rankChoices());
    unawaited(
      widget.lyrics.askAll().then((_) {
        if (mounted) unawaited(fitter?.rankChoices());
      }),
    );
  }

  @override
  void dispose() {
    widget.lyrics.removeListener(_onLyrics);
    widget.fitter?.removeListener(_onLyrics);
    unawaited(_current?.cancel());
    super.dispose();
  }

  void _onLyrics() {
    if (mounted) setState(() {});
  }

  void _use(String source) {
    widget.lyrics.use(source);
    widget.onUsed();
  }

  Future<void> _menu(LyricsChoice choice, Offset at) async {
    final chosen = widget.lyrics.chosen;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (chosen != choice.source)
          const PopupMenuItem(
            key: ValueKey('menu-use-lyrics'),
            value: 'use',
            child: Text('Use these lyrics'),
          ),
        if (chosen != null)
          const PopupMenuItem(
            key: ValueKey('menu-lyrics-automatic'),
            value: 'automatic',
            child: Text('Back to automatic'),
          ),
        const PopupMenuItem(
          key: ValueKey('menu-preview-lyrics'),
          value: 'preview',
          child: Text('Preview'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'use':
        _use(choice.source);
      case 'automatic':
        widget.lyrics.useAutomatic();
      case 'preview':
        setState(() => _preview = choice.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lyrics.track == null) {
      return lyricsMessage(context, 'Play a song to see its lyrics.');
    }
    final fitter = widget.fitter;
    final choices = _ranked(widget.lyrics.choices);
    final previewed = choices
        .where((choice) => choice.source == _preview && choice.lyrics != null)
        .firstOrNull;
    if (previewed != null) return _previewOf(previewed);
    final chosen = widget.lyrics.chosen;
    final automatic = widget.lyrics.automatic;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < lyricsNarrowWidth;
        return ListView(
          key: const ValueKey('lyrics-choices'),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (fitter != null) ?_checkRow(fitter, narrow),
            for (final choice in choices)
              _ChoiceRow(
                key: ValueKey('lyrics-choice-${choice.source}'),
                choice: choice,
                score: choice.lyrics == null
                    ? null
                    : fitter?.scoreOf(choice.lyrics!),
                inUse: choice.source == (chosen ?? automatic),
                automatic: choice.source == automatic,
                yours: choice.source == chosen,
                narrow: narrow,
                onPreview: () => setState(() => _preview = choice.source),
                onMenu: (at) => _menu(choice, at),
                onRetry: () => unawaited(widget.lyrics.askAll()),
              ),
          ],
        );
      },
    );
  }

  /// [choices] with the timed lyrics that have a fit score first, best
  /// first; the rest keep their order.
  List<LyricsChoice> _ranked(List<LyricsChoice> choices) {
    final fitter = widget.fitter;
    if (fitter == null) return choices;
    double? scoreOf(LyricsChoice choice) =>
        choice.lyrics == null ? null : fitter.scoreOf(choice.lyrics!);
    final scored = [
      for (final choice in choices)
        if (scoreOf(choice) != null) choice,
    ]..sort((a, b) => scoreOf(b)!.compareTo(scoreOf(a)!));
    if (scored.isEmpty) return choices;
    return [
      ...scored,
      for (final choice in choices)
        if (scoreOf(choice) == null) choice,
    ];
  }

  /// The row that offers the fit check (or shows it running); null when
  /// there is nothing to check or it would run by itself.
  Widget? _checkRow(LyricsFitter fitter, bool narrow) {
    final colors = OwnColors.of(context);
    final stage = fitter.stageOf(widget.lyrics.shownKey, LyricsFitter.rankJob);
    if (stage == null && (!fitter.canRank || fitter.job != null)) return null;
    final share = stage is FitRunning ? stage.share : 0.0;
    return Padding(
      key: const ValueKey('lyrics-rank-row'),
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 24, 8, 24, 8),
      child: Row(
        children: [
          Icon(Icons.auto_fix_high, size: 20, color: colors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              stage == null
                  ? 'Find which lyrics fit this recording'
                        '${fitter.rankIsQuick ? '' : ' (about 20 s)'}'
                  : 'Checking which lyrics fit this recording, '
                        '${(share * 100).floor()}%',
              style: TextStyle(color: colors.dim, fontSize: 13),
            ),
          ),
          if (stage == null)
            TextButton(
              key: const ValueKey('lyrics-rank'),
              onPressed: () => unawaited(fitter.rankChoices(runModel: true)),
              child: const Text('Check'),
            )
          else
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: share == 0 ? null : share,
              ),
            ),
        ],
      ),
    );
  }

  /// One source's full lyrics under a bar: back to the list, what they
  /// are, and Use.
  Widget _previewOf(LyricsChoice choice) {
    final colors = OwnColors.of(context);
    final lyrics = choice.lyrics!;
    final chosen = widget.lyrics.chosen;
    final inUse = choice.source == (chosen ?? widget.lyrics.automatic);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < lyricsNarrowWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(narrow ? 12 : 44, 4, 24, 0),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    key: const ValueKey('lyrics-preview-back'),
                    onPressed: () => setState(() => _preview = null),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('All sources'),
                  ),
                  Text(
                    '${choice.label}, ${widget.lyrics.timedOf(lyrics).timed
                        ? 'timed'
                        : choice.otherVersion && lyrics.timed
                        ? 'words of another version'
                        : 'words only'}'
                    ' · ${_lengthNote(choice)}'
                    '${widget.lyrics.isFitted(lyrics) ? ' · fitted to this recording' : ''}'
                    '${_offsetNote(lyrics.timed ? widget.lyrics.offsetOf(choice.source) : 0)}',
                    key: const ValueKey('lyrics-preview-what'),
                    style: TextStyle(color: colors.dim, fontSize: 13),
                  ),
                  if (inUse)
                    const OutlinedButton(
                      key: ValueKey('lyrics-in-use'),
                      onPressed: null,
                      child: Text('In use'),
                    )
                  else
                    FilledButton(
                      key: const ValueKey('lyrics-use'),
                      onPressed: () => _use(choice.source),
                      child: const Text('Use these lyrics'),
                    ),
                  if (chosen == choice.source)
                    TextButton(
                      key: const ValueKey('lyrics-automatic'),
                      onPressed: widget.lyrics.useAutomatic,
                      child: const Text('Back to automatic'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: LyricsLines(
                key: ValueKey('lyrics-preview-${choice.source}'),
                lyrics: widget.lyrics.timedOf(lyrics),
                offsetMs: widget.lyrics.offsetOf(choice.source),
                header: const SizedBox.shrink(),
                position: widget.position,
                positions: widget.positions,
                seek: widget.seek,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// How the source's song's length compares with the played song's.
String _lengthNote(LyricsChoice choice) => switch (choice.lengthDiff) {
  null => 'length unknown',
  0 => 'same length',
  final diff => '$diff s off',
};

/// The user's moved timing (F1) after the preview's facts; empty when none.
String _offsetNote(int offsetMs) =>
    offsetMs == 0 ? '' : ' · ${lyricsOffsetText(offsetMs)}';

/// How many lines have words.
int _wordLines(Lyrics lyrics) =>
    lyrics.lines.where((line) => !line.isGap).length;

/// The first two lines with words, for a row's preview.
String _firstLines(Lyrics lyrics) => lyrics.lines
    .where((line) => !line.isGap)
    .take(2)
    .map((line) => line.text.trim())
    .join(' / ');

/// One source's row: its name and tags, the song its lyrics belong to, the
/// first lines, and the length; or why it has none.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.choice,
    this.score,
    required this.inUse,
    required this.automatic,
    required this.yours,
    required this.narrow,
    required this.onPreview,
    required this.onMenu,
    required this.onRetry,
  });

  final LyricsChoice choice;

  /// The share of the lyrics' lines found in this recording (G3); null
  /// when not checked.
  final double? score;
  final bool inUse;
  final bool automatic;
  final bool yours;
  final bool narrow;
  final VoidCallback onPreview;
  final void Function(Offset at) onMenu;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final lyrics = choice.lyrics;
    final found = lyrics != null;
    final tags = <(String, String)>[
      if (lyrics != null)
        lyrics.timed
            ? ('timed', 'Lines follow the music.')
            : ('words only', 'No times: the words scroll by hand.'),
      if (score case final sure?)
        sure >= 0.5
            ? (
                'fits this recording',
                '${(sure * 100).round()}% of the lines were found in this '
                    'recording.',
              )
            : (
                'may not match',
                'Only ${(sure * 100).round()}% of the lines were found in '
                    'this recording: these lyrics may be of another version.',
              ),
      if (found && choice.otherVersion)
        (
          'another version',
          'From a song of another length (${_lengthNote(choice)}), such as '
              'the studio song of a live upload: the words show without '
              'timing until you fit them to this recording.',
        ),
      if (inUse) ('in use', 'The Lyrics place shows these.'),
      if (yours)
        ('your choice', 'You chose these; the app keeps them for this song.')
      else if (automatic)
        (
          'automatic pick',
          'What the app picks by itself: timed lyrics first, then the '
              'closest names and length.',
        ),
      if (found && choice.source != 'vk' && !choice.exact)
        (
          'similar names',
          'The names match only roughly (other spelling or alphabet): '
              'check that these are the right song.',
        ),
    ];
    final detail = switch (choice.status) {
      LyricsChoiceStatus.found =>
        choice.source == 'vk'
            ? "This upload's own lyrics · ${_wordLines(lyrics!)} lines"
            : [
                if (choice.title != null)
                  (choice.artist ?? '').isEmpty
                      ? choice.title!
                      : '${choice.title} - ${choice.artist}',
                _lengthNote(choice),
                '${_wordLines(lyrics!)} lines',
              ].join(' · '),
      LyricsChoiceStatus.asking => 'Asking...',
      LyricsChoiceStatus.none => 'No lyrics for this song',
      LyricsChoiceStatus.failed => 'Could not reach ${choice.label}',
      LyricsChoiceStatus.notAsked => 'Not asked yet',
    };
    final icon = switch (choice.status) {
      LyricsChoiceStatus.found =>
        lyrics!.timed ? Icons.lyrics_outlined : Icons.notes,
      LyricsChoiceStatus.none => Icons.block,
      LyricsChoiceStatus.failed => Icons.error_outline,
      LyricsChoiceStatus.asking ||
      LyricsChoiceStatus.notAsked => Icons.more_horiz,
    };
    final seconds = choice.seconds;
    return InkWell(
      onTap: found ? onPreview : null,
      onSecondaryTapDown: found
          ? (details) => onMenu(details.globalPosition)
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: narrow ? 16 : 24,
          vertical: 9,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.raised,
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: choice.status == LyricsChoiceStatus.asking || choice.asking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      icon,
                      size: 20,
                      color: found ? colors.accent : colors.dim2,
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        choice.label,
                        style: TextStyle(
                          color: found ? colors.text : colors.dim,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final (label, explanation) in tags)
                        _Tag(label: label, explanation: explanation),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.dim, fontSize: 13),
                  ),
                  if (lyrics != null)
                    Text(
                      _firstLines(lyrics),
                      key: ValueKey('lyrics-choice-lines-${choice.source}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.dim2,
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (choice.status == LyricsChoiceStatus.failed)
              TextButton(
                key: ValueKey('lyrics-choice-retry-${choice.source}'),
                onPressed: onRetry,
                child: const Text('Try again'),
              )
            else if (found && seconds != null)
              Text(
                lengthText(seconds.toDouble()),
                style: TextStyle(color: colors.dim, fontSize: 13),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small outlined label on a row, explained on hover (the Versions
/// place's tags).
class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.explanation});

  final String label;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    return Tooltip(
      message: explanation,
      child: Container(
        key: ValueKey('lyrics-tag-$label'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(fontSize: 11, color: colors.dim),
        ),
      ),
    );
  }
}
