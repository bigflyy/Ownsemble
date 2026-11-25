/// "Hear the words" on the Lyrics place (plan 10 I2f): the question before
/// the models' first download, a click's whole flow with its messages, and
/// the panel that shows a run of the song shown.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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
Future<void> hearShownWords(
  BuildContext context,
  LyricsHearer hearer, {
  String? forKey,
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
  final outcome = await hearer.hearShown(forKey: key);
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
  });

  final LyricsHearer hearer;
  final HearStage stage;

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
                'Hearing again: $text',
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
