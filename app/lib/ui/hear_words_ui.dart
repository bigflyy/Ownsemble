/// "Hear the words" on the Lyrics place (plan 10 I2f): the question before
/// the models' first download, a click's whole flow with its messages, and
/// the panel that shows a run of the song shown.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../lyrics/hear_languages.dart';
import '../lyrics/heard_lyrics.dart' show HeardLyrics, HeardOutcome;
import '../lyrics/lyrics_hearer.dart';
import 'theme.dart';

/// Asks before the models' first download; true when the user agrees.
/// [megabytes] come now; [laterMegabytes] (Whisper) only when a song not in
/// Russian first needs them, without asking again.
Future<bool> askToDownloadHearModels(
  BuildContext context, {
  required int megabytes,
  required int laterMegabytes,
}) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('hear-ask'),
      title: const Text('Hear the words of this song?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Text(
          'The app listens to the recording and writes down the words it '
          'hears, with their times. It needs models of $megabytes MB, '
          'downloaded once'
          '${laterMegabytes == 0 ? '' : ', and $laterMegabytes MB more the first time a song is not in Russian'}'
          '; after that it runs on this PC, about 2 to 5 minutes a song. A '
          'song that only streams is saved first. The words may be rough: '
          'they are marked so.\n\n'
          'The models: Kim Vocal 2 (from Ultimate Vocal Remover) separates '
          'the voice, GigaAM v3 (MIT) hears Russian, Whisper large-v3-turbo '
          '(OpenAI, MIT) other languages, Silero VAD (MIT) finds the '
          'singing.',
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('hear-ask-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('hear-ask-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Download $megabytes MB'),
        ),
      ],
    ),
  );
  return agreed ?? false;
}

/// A click on "Hear the words" (or Hear again) for the song shown: the
/// question when the models are missing, the run, and a message for what
/// came of it when the place does not show it by itself. [forKey]: the
/// upload a menu or message was opened for; nothing starts when the place
/// shows another by now (Codex review).
///
/// With [pick] the song is heard in [language] (null: Automatic), which is
/// kept for the song (plan 10 I2j); without it, in the song's kept pick.
Future<void> hearShownWords(
  BuildContext context,
  LyricsHearer hearer, {
  String? forKey,
  bool pick = false,
  String? language,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final key = forKey ?? hearer.lyrics.shownKey;
  final title = hearer.lyrics.track?.title ?? '';
  if (hearer.lyrics.shownKey != key) return;
  if (hearer.mustAsk) {
    final agreed = await askToDownloadHearModels(
      context,
      megabytes: hearer.nowMegabytes,
      laterMegabytes: hearer.laterMegabytes,
    );
    if (!agreed || !context.mounted) return;
  }
  final outcome = pick
      ? await hearer.hearShownAs(language, forKey: key)
      : await hearer.hearShown(forKey: key);
  final SnackBar? bar = switch (outcome) {
    // The place shows the result; a song moved away from hears of it here.
    HearDone() when hearer.lyrics.shownKey == key => null,
    HearDone() => SnackBar(
      content: Text(
        title.isEmpty ? 'The words were heard.' : 'Heard the words of $title.',
      ),
    ),
    HearStopped(download: true) => const SnackBar(
      content: Text('Download stopped. The next try goes on from there.'),
    ),
    HearStopped() => const SnackBar(
      content: Text('Stopped. Nothing was saved.'),
    ),
    HearFailed(:final message, :final retry) => SnackBar(
      content: Text(message),
      action: retry && context.mounted
          ? SnackBarAction(
              label: 'Try again',
              // The song that failed is the one tried again, or none.
              onPressed: () {
                if (context.mounted) {
                  unawaited(hearShownWords(context, hearer, forKey: key));
                }
              },
            )
          : null,
    ),
  };
  if (bar != null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(bar);
  }
}

/// The run of the song shown: what it does now, a bar, and Stop.
class HearProgressPanel extends StatelessWidget {
  const HearProgressPanel({
    super.key,
    required this.hearer,
    required this.stage,
  });

  final LyricsHearer hearer;
  final HearStage stage;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final share = switch (stage) {
      HearDownloading(:final bytes, :final total) =>
        total == 0 ? null : bytes / total,
      HearSaving(:final share) => share == 0 ? null : share,
      HearRunning(:final share) => share,
      HearStopping() => null,
    };
    final text = hearStageText(stage);
    final stopping = stage is HearStopping;
    final downloading = stage is HearDownloading;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        return SingleChildScrollView(
          key: const ValueKey('hear-progress'),
          padding: EdgeInsets.fromLTRB(narrow ? 24 : 56, 48, 24, 24),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hearing the words of this song',
                    style: TextStyle(
                      color: colors.text,
                      fontSize: narrow ? 16 : 18,
                    ),
                  ),
                  const SizedBox(height: 14),
                  LinearProgressIndicator(
                    key: const ValueKey('hear-bar'),
                    value: share,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${text[0].toUpperCase()}${text.substring(1)}',
                    key: const ValueKey('hear-stage'),
                    style: TextStyle(
                      color: colors.dim,
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    key: const ValueKey('hear-stop'),
                    onPressed: stopping ? null : hearer.stop,
                    child: Text(stopping ? 'Stopping...' : 'Stop'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    downloading
                        ? 'Stopping keeps what came: the download goes on '
                              'next time.'
                        : 'Other songs can play meanwhile; the words are '
                              'kept for this song.',
                    style: TextStyle(color: colors.dim2, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One line over words on show while their song is heard (again): what the
/// run does now and Stop.
class HearProgressStrip extends StatelessWidget {
  const HearProgressStrip({
    super.key,
    required this.hearer,
    required this.stage,
    this.again = true,
  });

  final LyricsHearer hearer;
  final HearStage stage;

  /// Heard words on show are heard again; other lyrics on show (found or
  /// the user's edit) stay while the song is heard (I2g heading button).
  final bool again;

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final text = hearStageText(stage);
    final stopping = stage is HearStopping;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        key: const ValueKey('hear-strip'),
        padding: EdgeInsets.fromLTRB(
          constraints.maxWidth < 640 ? 24 : 56,
          8,
          24,
          0,
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${again ? 'Hearing again' : 'Hearing the words'}: $text',
                key: const ValueKey('hear-strip-stage'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.dim, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('hear-stop'),
              onPressed: stopping ? null : hearer.stop,
              child: Text(stopping ? 'Stopping...' : 'Stop'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Hear the words" in the Lyrics heading (I2g, user pick 2026-11-25:
/// mockup "Hear icon A"): for every song in the library, also when found
/// lyrics show (to check or replace wrong ones: the heard words then go to
/// the chooser's "Heard by the app" row). While the song shown is heard it
/// says how far it is, and a click stops it. With [compact] an icon with
/// its words in the tooltip (the heading's rule: words for all or none).
class HearHeadingButton extends StatelessWidget {
  const HearHeadingButton({
    super.key,
    required this.hearer,
    required this.compact,
  });

  final LyricsHearer hearer;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([hearer, hearer.lyrics]),
    builder: (context, _) {
      final lyrics = hearer.lyrics;
      final track = lyrics.track;
      final key = lyrics.shownKey;
      if (track == null || key == null) return const SizedBox.shrink();
      final stage = hearer.stageOf(key);
      if (stage != null) return _running(context, stage);
      final heard = lyrics.heard;
      final noSinging = heard?.outcome == HeardOutcome.noSinging;
      final other = hearer.job != null;
      final label = hearButtonLabel(heard, hearer.languageFor(key));
      final tooltip = !track.inLibrary
          ? 'Add the song to your library to hear its words'
          : other
          ? 'Another song is being heard now. One song at a time.'
          : noSinging
          ? 'No singing was found in this song'
          : 'Listen to this recording and write down what is sung';
      final onPressed = track.inLibrary && !other && !noSinging
          ? () => unawaited(hearShownWords(context, hearer))
          : null;
      // The language arrow beside it (plan 10 I2j): also for a song with
      // no singing found, which may have been heard in the wrong language.
      final arrow = HearLanguageArrow(
        hearer: hearer,
        enabled: track.inLibrary && !other,
        compact: compact,
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compact)
            IconButton(
              key: const ValueKey('lyrics-hear'),
              tooltip: '$label: $tooltip',
              onPressed: onPressed,
              icon: const Icon(Icons.hearing),
            )
          else
            Tooltip(
              message: tooltip,
              child: TextButton.icon(
                key: const ValueKey('lyrics-hear'),
                onPressed: onPressed,
                icon: const Icon(Icons.hearing, size: 20),
                label: Text(label),
              ),
            ),
          arrow,
        ],
      );
    },
  );

  Widget _running(BuildContext context, HearStage stage) {
    final share = switch (stage) {
      HearDownloading(:final bytes, :final total) =>
        total == 0 ? null : bytes / total,
      HearSaving(:final share) => share == 0 ? null : share,
      HearRunning(:final share) => share,
      HearStopping() => null,
    };
    final stopping = stage is HearStopping;
    final spinner = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2.2, value: share),
    );
    final tooltip = stopping
        ? 'Stopping...'
        : 'Hearing: ${hearStageText(stage)}. Click to stop.';
    if (compact) {
      return IconButton(
        key: const ValueKey('lyrics-hear-progress'),
        tooltip: tooltip,
        onPressed: stopping ? null : hearer.stop,
        icon: spinner,
      );
    }
    final percent = share == null ? '' : ' ${(share * 100).round()}%';
    return Tooltip(
      message: tooltip,
      child: FilledButton.tonalIcon(
        key: const ValueKey('lyrics-hear-progress'),
        onPressed: stopping ? null : hearer.stop,
        icon: spinner,
        label: Text(
          stopping ? 'Stopping...' : 'Hearing$percent · Stop',
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}

/// The Hear button's words: "Hear the words" or "Hear again", with the
/// song's picked language when it has one ("Hear again in English").
String hearButtonLabel(HeardLyrics? heard, String? language) =>
    '${heard == null ? 'Hear the words' : 'Hear again'}'
    '${language == null ? '' : ' in ${hearLanguageName(language)}'}';

/// What the heard words were asked to be heard as, for their credit line:
/// ", in English as you asked"; empty when the app chose.
String heardLanguageNote(HeardLyrics? heard) {
  final asked = heard?.askedLanguage;
  return asked == null ? '' : ', in ${hearLanguageName(asked)} as you asked';
}

/// The arrow beside a Hear button (plan 10 I2j): Automatic, Russian,
/// English and Another language..., the song's pick checked; choosing one
/// keeps it for the song and hears the song in it.
class HearLanguageArrow extends StatelessWidget {
  const HearLanguageArrow({
    super.key,
    required this.hearer,
    required this.enabled,
    this.compact = false,
  });

  final LyricsHearer hearer;
  final bool enabled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final key = hearer.lyrics.shownKey;
    final current = hearer.languageFor(key);
    // Outlives this arrow: the place can swap arrows while the list is open
    // (lyrics found meanwhile), and the pick must still be heard.
    final stable = Navigator.of(context).context;
    final other =
        current != null && current != hearRussian && current != hearEnglish;
    void hearIn(String? language) => unawaited(
      hearShownWords(
        context,
        hearer,
        forKey: key,
        pick: true,
        language: language,
      ),
    );
    Widget item(String id, String text, bool checked, VoidCallback onTap) =>
        MenuItemButton(
          key: ValueKey('hear-language-$id'),
          leadingIcon: SizedBox(
            width: 18,
            child: checked ? const Icon(Icons.check, size: 18) : null,
          ),
          onPressed: onTap,
          child: Text(text),
        );
    return MenuAnchor(
      menuChildren: [
        item('auto', 'Automatic', current == null, () => hearIn(null)),
        item(
          hearRussian,
          'Russian',
          current == hearRussian,
          () => hearIn(hearRussian),
        ),
        item(
          hearEnglish,
          'English',
          current == hearEnglish,
          () => hearIn(hearEnglish),
        ),
        const Divider(height: 8),
        item(
          'other',
          other
              ? 'Another language: ${hearLanguageName(current)}...'
              : 'Another language...',
          other,
          () async {
            final picked = await pickHearLanguage(context, current: current);
            if (picked == null || !stable.mounted) return;
            unawaited(
              hearShownWords(
                stable,
                hearer,
                forKey: key,
                pick: true,
                language: picked.language,
              ),
            );
          },
        ),
      ],
      builder: (context, menu, _) => IconButton(
        key: const ValueKey('hear-language-arrow'),
        tooltip: current == null
            ? 'Hear in a language you pick'
            : 'Heard in ${hearLanguageName(current)}, as you picked. Change it',
        // Narrow: hugs the ear button, so the heading keeps room for its
        // title.
        padding: compact ? EdgeInsets.zero : null,
        constraints: compact
            ? const BoxConstraints(minWidth: 22, minHeight: 40)
            : null,
        style: compact
            ? IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )
            : null,
        onPressed: enabled
            ? () => menu.isOpen ? menu.close() : menu.open()
            : null,
        icon: const Icon(Icons.arrow_drop_down),
      ),
    );
  }
}

/// The searchable list of every language Hear the words knows (plan 10
/// I2j): Automatic, Russian and English first, then the rest by name.
/// Null when closed without a pick; else the pick (its language null for
/// Automatic).
Future<({String? language})?> pickHearLanguage(
  BuildContext context, {
  String? current,
}) => showDialog<({String? language})>(
  context: context,
  builder: (context) => _HearLanguageDialog(current: current),
);

class _HearLanguageDialog extends StatefulWidget {
  const _HearLanguageDialog({required this.current});
  final String? current;

  @override
  State<_HearLanguageDialog> createState() => _HearLanguageDialogState();
}

class _HearLanguageDialogState extends State<_HearLanguageDialog> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = OwnColors.of(context);
    final query = _query.trim().toLowerCase();
    final top = searchHearLanguages(query, const [hearRussian, hearEnglish]);
    final rest = searchHearLanguages(query, otherHearLanguages);
    final auto = query.isEmpty || 'automatic'.startsWith(query);
    Widget row(String id, String? code, String text, {String? note}) =>
        ListTile(
          key: ValueKey('hear-pick-$id'),
          dense: true,
          leading: SizedBox(
            width: 18,
            child: widget.current == code
                ? const Icon(Icons.check, size: 18)
                : null,
          ),
          title: Text(text),
          subtitle: note == null
              ? null
              : Text(note, style: TextStyle(color: colors.dim)),
          onTap: () => Navigator.of(context).pop((language: code)),
        );
    final rows = [
      if (auto)
        row(
          'auto',
          null,
          'Automatic',
          note: 'The app decides: Russian or another language',
        ),
      for (final code in top)
        row(
          code,
          code,
          hearLanguageName(code),
          note: code == hearRussian ? 'Heard by GigaAM' : null,
        ),
      if ((auto || top.isNotEmpty) && rest.isNotEmpty) const Divider(height: 8),
      for (final code in rest) row(code, code, hearLanguageName(code)),
    ];
    return AlertDialog(
      key: const ValueKey('hear-language-dialog'),
      title: const Text('Hear the words in'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('hear-language-search'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search languages',
                isDense: true,
              ),
              onChanged: (text) => setState(() => _query = text),
              // Enter takes the first language the search shows.
              onSubmitted: (_) {
                if (auto) {
                  Navigator.of(context).pop((language: null));
                } else if (top.isNotEmpty) {
                  Navigator.of(context).pop((language: top.first));
                } else if (rest.isNotEmpty) {
                  Navigator.of(context).pop((language: rest.first));
                }
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        'No language by that name',
                        style: TextStyle(color: colors.dim),
                      ),
                    )
                  : ListView(children: rows),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('hear-language-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
