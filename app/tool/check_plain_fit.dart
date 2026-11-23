// Check for plan 10 H2a: the app's fit of plain words (lib/lyrics/
// line_fit.dart fitPlainLines, shuffleGain) against the Python research
// (experiments/f2-timing/plain_words.py), on the aligner output the
// research cached.
//
//   dart run tool/check_plain_fit.dart LINES.jsonl PAIRS.json DATA_DIR...
//       [--wrong]
//
// With --wrong, each source's words are also fitted to another song's
// recording of the same set (as plain_words.py pairs them: 7 songs on,
// skipping one that shares 30% of its words) with 5 seeds, and the gains
// that would pass are counted.
//
// LINES.jsonl is plain_words.py --out (per line: pair [set, index, source],
// line, score, star_agree, pace_one, rate_dev); PAIRS.json its .pairs.json
// (per pair the mean letter score as sung and shuffled). Each DATA_DIR holds
// songs/<index>.json, emission/<index>.npy and asr-rnnt/ or asr-whisper/
// transcripts (for the audio length). The shuffled orders differ from
// numpy's, so the gain is compared only in size and verdict. Prints only
// counts, indexes and numbers: no lyric text.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/lyrics/line_fit.dart';

import 'check_line_fit.dart' show readNpy;

double? secondsOf(Directory data, int index) {
  for (final sub in ['asr-rnnt', 'asr-whisper']) {
    final file = File('${data.path}/$sub/$index-transcript.json');
    if (!file.existsSync()) continue;
    final seconds =
        (jsonDecode(file.readAsStringSync()) as Map)['audio_seconds'];
    if (seconds is num) return seconds.toDouble();
  }
  return null;
}

void main(List<String> args) {
  final expected = <String, Map<String, dynamic>>{};
  for (final line in File(args[0]).readAsLinesSync()) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    final pair = row['pair'] as List;
    expected['${pair[0]}/${pair[1]}/${pair[2]}/${row['line']}'] = row;
  }
  final gains = <String, double>{};
  final goodOf = <String, double?>{};
  for (final row in jsonDecode(File(args[1]).readAsStringSync()) as List) {
    final pair = (row as Map)['pair'] as List;
    final key = '${pair[0]}/${pair[1]}/${pair[2]}';
    gains[key] =
        ((row['own'] as Map)['score'] as num).toDouble() -
        ((row['own_null'] as Map)['score'] as num).toDouble();
    goodOf[key] = (row['good'] as num?)?.toDouble();
  }
  final shufflesAt = args.indexOf('--shuffles');
  final shuffles = shufflesAt < 0 ? 3 : int.parse(args[shufflesAt + 1]);
  // Per fit: the gain (null: cannot tell), the sure share and, for the
  // song's own recording, the share of lines right (null: no truth).
  final ownFits = <({double? gain, double share, double? good})>[];
  final wrongFits = <({double? gain, double share})>[];
  double shareOf(List<PlainFittedLine> fitted) => fitted.isEmpty
      ? 0
      : fitted.where((line) => line.sure >= sureAt).length / fitted.length;

  var compared = 0;
  final worst = <String, double>{
    'score': 0,
    'star_agree': 0,
    'pace_one': 0,
    'rate_dev': 0,
    'sure': 0,
  };
  var pairs = 0;
  var gainDiff = 0.0;
  var verdictsDiffer = 0;
  var fitMs = 0;
  final clock = Stopwatch();
  final wrong = args.contains('--wrong');
  final dirs = [
    for (var i = 2; i < args.length; i++)
      if (!args[i].startsWith('--') && args[i - 1] != '--shuffles') args[i],
  ];
  for (final dir in dirs) {
    final data = Directory(dir);
    final name = data.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final indexes = [
      for (final npy in Directory('${data.path}/emission').listSync())
        if (npy is File && npy.path.endsWith('.npy'))
          int.parse(npy.uri.pathSegments.last.split('.').first),
    ]..sort();
    final wordsOf = <int, Set<String>>{};
    for (final index in indexes) {
      final songFile = File('${data.path}/songs/$index.json');
      if (!songFile.existsSync()) continue;
      final song = jsonDecode(songFile.readAsStringSync()) as Map;
      for (final lines in (song['sources'] as Map).values) {
        for (final l in lines as List) {
          (wordsOf[index] ??= {}).addAll(
            romanize((l as Map)['t'] as String).words,
          );
        }
      }
    }
    for (final index in indexes) {
      final npy = File('${data.path}/emission/$index.npy');
      final seconds = secondsOf(data, index);
      final songFile = File('${data.path}/songs/$index.json');
      if (seconds == null || !songFile.existsSync()) continue;
      final emission = readNpy(npy);
      final song = jsonDecode(songFile.readAsStringSync()) as Map;
      for (final entry in (song['sources'] as Map).entries) {
        final key = '$name/$index/${entry.key}';
        final lines = [
          for (final l in entry.value as List)
            (
              startMs: (l as Map)['s'] as int?,
              endMs: l['e'] as int?,
              text: l['t'] as String,
            ),
        ];
        final texts = [for (final line in sungLines(lines)) line.text];
        if (texts.length < 3) continue;
        clock
          ..reset()
          ..start();
        final fitted = fitPlainLines(
          emission,
          texts,
          seconds / emission.frames,
        );
        final gain = shuffleGain(
          emission,
          texts,
          fitted,
          seed: plainSeedOf(texts),
          shuffles: shuffles,
        );
        if (gains.containsKey(key)) {
          ownFits.add((gain: gain, share: shareOf(fitted), good: goodOf[key]));
        }
        fitMs += clock.elapsedMilliseconds;
        for (final line in fitted) {
          final row = expected['$key/${line.index}'];
          if (row == null) continue;
          compared++;
          double off(String field, double mine) =>
              (mine - (row[field] as num).toDouble()).abs();
          void note(String field, double value) {
            if (value > worst[field]!) worst[field] = value;
          }

          note('score', off('score', line.score));
          note('star_agree', off('star_agree', line.starAgree));
          note('pace_one', off('pace_one', line.paceOne));
          note('rate_dev', off('rate_dev', line.rateDev));
          final python =
              PlainFittedLine(
                  index: 0,
                  start: 0,
                  end: 1,
                  letters: 1,
                  at: 0,
                  score: (row['score'] as num).toDouble(),
                  starAgree: (row['star_agree'] as num).toDouble(),
                )
                ..paceOne = (row['pace_one'] as num).toDouble()
                ..rateDev = (row['rate_dev'] as num).toDouble();
          note('sure', (line.sure - python.sure).abs());
        }
        if (wrong && gains.containsKey(key)) {
          final own = {for (final t in texts) ...romanize(t).words};
          final pos = indexes.indexOf(index);
          int? other;
          for (var step = 7; step < 7 + indexes.length; step++) {
            final cand = indexes[(pos + step) % indexes.length];
            if (cand == index || wordsOf[cand] == null) continue;
            final union = own.union(wordsOf[cand]!).length;
            if (own.intersection(wordsOf[cand]!).length / union < 0.3) {
              other = cand;
              break;
            }
          }
          final otherSeconds = other == null ? null : secondsOf(data, other);
          if (other != null && otherSeconds != null) {
            final em = readNpy(File('${data.path}/emission/$other.npy'));
            final placed = fitPlainLines(em, texts, otherSeconds / em.frames);
            // Five seeds stand for five sets of words of that kind.
            for (var k = 0; k < 5; k++) {
              wrongFits.add((
                gain: shuffleGain(
                  em,
                  texts,
                  placed,
                  seed: plainSeedOf(texts) + k,
                  shuffles: shuffles,
                ),
                share: shareOf(placed),
              ));
            }
          }
        }
        final pythonGain = gains[key];
        if (pythonGain != null && gain != null) {
          pairs++;
          gainDiff += (gain - pythonGain).abs();
          if ((gain >= plainGainAt) != (pythonGain >= plainGainAt)) {
            verdictsDiffer++;
          }
        }
      }
    }
  }
  bool fits(double? gain, double share, double cut) =>
      gain != null && gain >= cut && share >= 0.5;
  final fitting = ownFits.where((f) => (f.good ?? 0) >= 0.7).toList();
  print(
    '$shuffles shuffles; own recordings ${ownFits.length} (${fitting.length} '
    'fitting, >= 70% of lines right), ${ownFits.where((f) => f.gain == null).length}'
    ' cannot tell; wrong songs ${wrongFits.length} (5 seeds each), '
    '${wrongFits.where((f) => f.gain == null).length} cannot tell',
  );
  for (final cut in [0.03, 0.035, 0.04, 0.05]) {
    print(
      '  cut $cut with sure share >= 0.5: wrong pass '
      '${wrongFits.where((f) => fits(f.gain, f.share, cut)).length}, fitting '
      'fail ${fitting.where((f) => !fits(f.gain, f.share, cut)).length}, own '
      'fail ${ownFits.where((f) => !fits(f.gain, f.share, cut)).length}',
    );
  }
  final top = [for (final f in wrongFits) ?f.gain]..sort();
  print(
    '  largest wrong gains '
    '${top.reversed.take(5).map((g) => g.toStringAsFixed(4)).join(' ')}',
  );
  print(
    '${expected.length} expected lines, $compared compared; largest '
    'differences: ${[for (final e in worst.entries) '${e.key} ${e.value.toStringAsFixed(4)}'].join(', ')}'
    '; shuffle gain over $pairs pairs: mean difference '
    '${(gainDiff / pairs).toStringAsFixed(4)}, verdicts at $plainGainAt differ '
    'for $verdictsDiffer; fit + $shuffles shuffles ${fitMs ~/ pairs} ms a pair',
  );
}
