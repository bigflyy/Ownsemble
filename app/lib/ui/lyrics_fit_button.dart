/// The Lyrics heading's "Fit to recording" button (plan 10 G2): moves the
/// shown timed lines to where they are sung in the song's own audio.
///
/// Before the first fit it asks to download the model (its size, where it
/// comes from, that it runs on this PC). While a fit runs it shows how far
/// it is (a click during the model's download stops it, to be continued
/// later). Fitted lines offer the source's own timing back; lyrics that do
/// not fit the recording open the chooser.
library;

import 'package:flutter/material.dart';

import '../lyrics/lyrics.dart';
import '../lyrics/lyrics_controller.dart';
import '../lyrics/lyrics_fitter.dart';
import '../lyrics/lyrics_sources.dart' show lyricsSourceLabel;

/// Below this width of the place the button is an icon alone.
const lyricsFitLabelWidth = 860.0;

class LyricsFitButton extends StatelessWidget {
  const LyricsFitButton({
    super.key,
    required this.fitter,
    required this.compact,
    required this.onChoose,
  });

  final LyricsFitter fitter;

  /// An icon alone, for a narrow place.
  final bool compact;

  /// Opens the chooser of every source's lyrics.
  final VoidCallback onChoose;

  LyricsController get _lyrics => fitter.lyrics;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([fitter, _lyrics]),
    builder: (context, _) {
      final state = _lyrics.state;
      if (state is! LyricsShown || !state.lyrics.timed) {
        return const SizedBox.shrink();
      }
      final shown = state.lyrics;
      final stage = fitter.stageOf(_lyrics.shownKey, shown.source);
      if (stage != null) return _progress(context, stage);
      final fit = _lyrics.fitFor(shown);
      if (fit != null && fit.fits) return _fitted(context, shown);
      if (fit != null) return _noMatch();
      final busy = fitter.job != null;
      // Fitting needs the song saved, and only library songs are saved.
      if (!(_lyrics.track?.inLibrary ?? false)) {
        return _button(
          key: const ValueKey('lyrics-fit'),
          icon: Icons.auto_fix_high,
          label: 'Fit to recording',
          tooltip: 'Add the song to your library to fit its lyrics',
          onPressed: null,
        );
      }
      return _button(
        key: const ValueKey('lyrics-fit'),
        icon: Icons.auto_fix_high,
        label: 'Fit to recording',
        tooltip: busy
            ? 'Another fit is running'
            : 'Move the lines to where they are sung in this recording',
        onPressed: busy ? null : () => _fit(context),
      );
    },
  );

  Widget _button({
    required Key key,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback? onPressed,
    bool on = false,
  }) => compact
      ? on
            // Fitted: the icon alone looks switched on, as the bar's mic
            // button does while Lyrics is open.
            ? IconButton.filledTonal(
                key: key,
                tooltip: '$label. $tooltip',
                onPressed: onPressed,
                icon: Icon(icon),
              )
            : IconButton(
                key: key,
                tooltip: '$label. $tooltip',
                onPressed: onPressed,
                icon: Icon(icon),
              )
      : Tooltip(
          message: tooltip,
          child: TextButton.icon(
            key: key,
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: Text(label),
          ),
        );

  Widget _progress(BuildContext context, FitStage stage) {
    final share = switch (stage) {
      FitDownloading(:final bytes, :final total) =>
        total == 0 ? null : bytes / total,
      FitSaving(:final share) => share == 0 ? null : share,
      FitRunning(:final share) => share == 0 ? null : share,
    };
    final text = fitStageText(stage);
    final downloading = stage is FitDownloading;
    final spinner = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, value: share),
    );
    final percent = share == null ? '' : ' ${(share * 100).floor()}%';
    final label = switch (stage) {
      FitDownloading() => 'Downloading$percent',
      FitSaving() => 'Saving song$percent',
      FitRunning() => 'Fitting$percent',
    };
    final tip =
        '${text[0].toUpperCase()}${text.substring(1)}'
        '${downloading ? '. Click to stop; the download goes on next time.' : ''}';
    return Tooltip(
      message: tip,
      child: compact
          ? IconButton(
              key: const ValueKey('lyrics-fit-progress'),
              onPressed: downloading ? fitter.stopDownload : null,
              icon: spinner,
            )
          : TextButton.icon(
              key: const ValueKey('lyrics-fit-progress'),
              onPressed: downloading ? fitter.stopDownload : null,
              icon: spinner,
              label: Text(
                label,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
    );
  }

  Widget _fitted(BuildContext context, Lyrics shown) {
    final label = lyricsSourceLabel(shown.source);
    final upload = _lyrics.shownKey;
    return PopupMenuButton<void>(
      key: const ValueKey('lyrics-fitted'),
      tooltip: 'Lines fitted to this recording',
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          key: const ValueKey('lyrics-unfit'),
          // The upload the menu was opened for, even if the song moves on.
          onTap: () => _lyrics.forgetFit(shown.source, key: upload),
          child: Text("Use $label's own timing"),
        ),
      ],
      child: IgnorePointer(
        child: _button(
          key: const ValueKey('lyrics-fitted-button'),
          icon: Icons.auto_fix_high,
          label: 'Fitted',
          tooltip: 'Lines fitted to this recording',
          onPressed: () {},
          on: true,
        ),
      ),
    );
  }

  Widget _noMatch() => _button(
    key: const ValueKey('lyrics-fit-no-match'),
    icon: Icons.report_outlined,
    label: 'Does not fit',
    tooltip:
        'These lyrics may not match this recording: most lines could not be '
        'found in it. Choose other lyrics.',
    onPressed: onChoose,
  );

  Future<void> _fit(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final key = _lyrics.shownKey;
    if (!fitter.modelReady) {
      final agreed = await askToDownloadFitModel(
        context,
        megabytes: fitter.modelMegabytes,
      );
      if (!agreed) return;
    }
    final outcome = await fitter.fitShown(forKey: key);
    final SnackBar? bar = switch (outcome) {
      FitDone() => null,
      FitStopped() => const SnackBar(
        content: Text('Download stopped. The next fit goes on from there.'),
      ),
      FitNoMatch() => SnackBar(
        content: const Text(
          'These lyrics may not match this recording: most lines could not '
          'be found in it.',
        ),
        action: SnackBarAction(label: 'Choose lyrics', onPressed: onChoose),
      ),
      FitFailed(:final message, :final retry) => SnackBar(
        content: Text(message),
        action: retry && context.mounted
            ? SnackBarAction(label: 'Try again', onPressed: () => _fit(context))
            : null,
      ),
    };
    if (bar != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(bar);
    }
  }
}

/// Asks before the fit model's first download; true when the user agrees.
Future<bool> askToDownloadFitModel(
  BuildContext context, {
  required int megabytes,
}) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('lyrics-fit-ask'),
      title: const Text('Fit the lines to this recording?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(
          'This moves each line to where it is sung in this song. It needs a '
          'model of $megabytes MB, downloaded once from Ownsemble on GitHub; '
          'after that it runs on this PC, about half a minute a song. A song '
          'that only streams is saved first.\n\n'
          'The model is MMS_FA (Pratap et al., Meta AI, 2023), for '
          'non-commercial use (CC BY-NC 4.0).',
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('lyrics-fit-ask-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('lyrics-fit-ask-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Download $megabytes MB'),
        ),
      ],
    ),
  );
  return agreed ?? false;
}
