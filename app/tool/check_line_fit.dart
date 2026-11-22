// Check for plan 10 G1: the app's forced alignment and line signals
// (lib/lyrics/ctc_align.dart, line_fit.dart) against the Python research
// (experiments/f2-timing/line_confidence.py), on the aligner output the
// research cached.
//
//   dart run tool/check_line_fit.dart DATA_DIR ASR_SUBDIR LINES.jsonl SET
//
// DATA_DIR holds songs/<index>.json and emission/<index>.npy (written by
// timing_probe.py); ASR_SUBDIR/<index>-transcript.json gives the audio
// length; LINES.jsonl is line_confidence.py --out, whose rows with "set"
// equal to SET are compared. Prints only counts, indexes and numbers: no
// lyric text.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ownsemble/lyrics/ctc_align.dart';
import 'package:ownsemble/lyrics/line_fit.dart';

/// A float32 2-D .npy file (numpy's own format) as an [Emission].
Emission readNpy(File file) {
  final bytes = file.readAsBytesSync();
  final major = bytes[6];
  final view = ByteData.sublistView(bytes);
  final headerLength = major == 1
      ? view.getUint16(8, Endian.little)
      : view.getUint32(8, Endian.little);
  final headerStart = major == 1 ? 10 : 12;
  final header = latin1.decode(
    bytes.sublist(headerStart, headerStart + headerLength),
  );
  if (!header.contains("'<f4'") || header.contains("'fortran_order': True")) {
    throw FormatException('not a C-order float32 array: $header');
  }
  final shape = RegExp(r"'shape': \((\d+), (\d+)\)").firstMatch(header)!;
  final columns = int.parse(shape.group(2)!);
  final dataStart = headerStart + headerLength;
  final values = Float32List.fromList(
    Float32List.sublistView(bytes.buffer.asUint8List().sublist(dataStart)),
  );
  return Emission(values, columns);
}

void main(List<String> args) {
  final data = Directory(args[0]);
  final asrDir = Directory('${data.path}/${args[1]}');
  final wanted = args[3];
  final expected = <String, Map<String, dynamic>>{};
  for (final line in File(args[2]).readAsLinesSync()) {
    final row = jsonDecode(line) as Map<String, dynamic>;
    if (row['set'] != wanted) continue;
    final pair = row['pair'] as List;
    expected['${pair[1]}/${pair[2]}/${row['line']}'] = row;
  }

  var compared = 0;
  var startOff = 0;
  var maxScore = 0.0;
  var maxLocal = 0.0;
  var maxStep = 0.0;
  var maxStar = 0.0;
  var maxSure = 0.0;
  final clock = Stopwatch();
  var alignMs = 0;
  var songs = 0;
  for (final key in expected.keys.map((k) => k.split('/').first).toSet()) {
    final index = int.parse(key);
    final npy = File('${data.path}/emission/$index.npy');
    final asr = File('${asrDir.path}/$index-transcript.json');
    if (!npy.existsSync() || !asr.existsSync()) continue;
    final seconds =
        ((jsonDecode(asr.readAsStringSync()) as Map)['audio_seconds'] as num)
            .toDouble();
    final emission = readNpy(npy);
    final song = jsonDecode(
      File('${data.path}/songs/$index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    songs++;
    for (final entry in (song['sources'] as Map<String, dynamic>).entries) {
      final lines = [
        for (final l in entry.value as List)
          (
            startMs: (l as Map)['s'] as int?,
            endMs: l['e'] as int?,
            text: l['t'] as String,
          ),
      ];
      final sung = sungLines(lines);
      if (sung.length < 3) continue;
      clock
        ..reset()
        ..start();
      final fitted = fitLines(emission, sung, seconds / emission.frames);
      alignMs += clock.elapsedMilliseconds;
      for (final line in fitted) {
        final row = expected['$index/${entry.key}/${line.index}'];
        if (row == null) continue;
        compared++;
        if ((line.start - (row['start'] as num)).abs() > 0.001) startOff++;
        double off(String name, double mine) =>
            (mine - (row[name] as num).toDouble()).abs();
        maxScore = [maxScore, off('score', line.score)].reduce(_max);
        maxLocal = [maxLocal, off('local_dev', line.localDev)].reduce(_max);
        maxStep = [maxStep, off('step_dev', line.stepDev)].reduce(_max);
        maxStar = [maxStar, off('star_agree', line.starAgree)].reduce(_max);
        final pythonSure =
            FittedLine(
                index: 0,
                lyricStart: 0,
                start: 0,
                score: (row['score'] as num).toDouble(),
                starAgree: (row['star_agree'] as num).toDouble(),
              )
              ..localDev = (row['local_dev'] as num).toDouble()
              ..stepDev = (row['step_dev'] as num).toDouble();
        maxSure = [maxSure, (line.sure - pythonSure.sure).abs()].reduce(_max);
      }
    }
  }
  print(
    '$wanted: $songs songs, ${expected.length} expected lines, $compared '
    'compared; starts off by > 1 ms: $startOff; largest differences: score '
    '${maxScore.toStringAsFixed(5)}, local_dev ${maxLocal.toStringAsFixed(4)}'
    ', step_dev ${maxStep.toStringAsFixed(4)}, star_agree '
    '${maxStar.toStringAsFixed(4)}, sure ${maxSure.toStringAsFixed(4)}; '
    'both alignments ${alignMs ~/ songs} ms a song on average',
  );
}

double _max(double a, double b) => a > b ? a : b;
