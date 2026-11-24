// Plan 10 I2e real check: the "Hear the words" pipeline (hear_words.dart)
// on the worker with the real models, stage by stage, as the app will run
// it, and the heard version it saves (into an in-memory library, read
// back).
//
// Run from app/ (a model run: through agg-queue):
//   dart run tool/check_hear_words.dart --models DIR --bridge DLL --out DIR
//       [--vocals DIR] [--audio DIR] [--threads 8] SONGS...
//
// A SONG is NAME (its kept vocals DIR/NAME.vocals16.f32, copied first so
// separation is skipped), full:NAME (from the song file --audio
// DIR/NAME.mp3, separation included) or force:NAME (kept vocals, the router
// set above 1 so even a Russian song goes to Whisper: the Russian
// re-hearing). Writes OUT/NAME[.full|.force].json (the saved heard version:
// lines, words, numbers) and prints one line of numbers per song, no words.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/lyrics/gigaam.dart' show russianConfidence;
import 'package:ownsemble/lyrics/hear_words.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';
import 'package:ownsemble/lyrics/stt_worker.dart';
import 'package:path/path.dart' as p;

final _cyrillic = RegExp(r'\p{Script=Cyrillic}', unicode: true);
final _latin = RegExp(r'\p{Script=Latin}', unicode: true);
final _cjk = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]',
  unicode: true,
);

Future<void> main(List<String> args) async {
  final values = <String, String>{};
  final songs = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length) {
      values[args[i]] = args[++i];
    } else {
      songs.add(args[i]);
    }
  }
  final models = values['--models'];
  final bridge = values['--bridge'];
  final outDir = values['--out'];
  if (models == null || bridge == null || outDir == null || songs.isEmpty) {
    print(
      'usage: --models DIR --bridge DLL --out DIR [--vocals DIR] '
      '[--audio DIR] [--threads N] NAME|full:NAME|force:NAME...',
    );
    exit(2);
  }
  final root = Directory(models);
  if (!bundleReady(root, hearWordsBundle) ||
      !bundleReady(root, whisperBundle)) {
    print('hear-words or whisper-turbo bundle not ready in $models');
    exit(1);
  }
  final threads = int.tryParse(values['--threads'] ?? '') ?? 8;
  final release = p.join('build', 'windows', 'x64', 'runner', 'Release');
  final out = Directory(outDir)..createSync(recursive: true);
  final temp = Directory(p.join(out.path, 'temp'))..createSync();
  final paths = HearWordsPaths(
    separatorModel: bundleFile(root, hearWordsBundle, 'Kim_Vocal_2.onnx').path,
    silero: bundleFile(root, hearWordsBundle, 'silero_vad_scan.onnx').path,
    gigaamFolder: bundleFile(
      root,
      hearWordsBundle,
      'gigaam/model.json',
    ).parent.path,
    mpv: p.absolute(release, 'libmpv-2.dll'),
    tempDir: temp.path,
    whisperBridge: bridge,
    whisperLibraries: bundleFile(
      root,
      whisperBundle,
      'whisper.cpp/whisper.dll',
    ).parent.path,
    whisperModel: bundleFile(
      root,
      whisperBundle,
      'ggml-large-v3-turbo-q5_0.bin',
    ).path,
    threads: threads,
    bundles:
        '${hearWordsBundle.name}-${hearWordsBundle.version} '
        '${whisperBundle.name}-${whisperBundle.version}',
  );
  // An AOT build has no native assets: SQLite from the app's folder,
  // found by the process lookup once loaded.
  DynamicLibrary.open(p.absolute(release, 'sqlite3.dll'));
  final store = LibraryStore.open(':memory:');
  final worker = SttWorker(
    onnxRuntimePath: p.absolute(release, 'onnxruntime.dll'),
    log: print,
  );
  var failed = false;
  try {
    for (final song in songs) {
      final (mode, name) = switch (song.split(':')) {
        [final mode, final name] => (mode, name),
        _ => ('kept', song),
      };
      final tag = mode == 'kept' ? name : '$name.$mode';
      final vocals = p.join(out.path, '$tag.vocals16.f32');
      final vocalsFile = File(vocals);
      if (vocalsFile.existsSync()) vocalsFile.deleteSync();
      String audio = '';
      if (mode == 'full') {
        audio = p.join(values['--audio'] ?? '.', '$name.mp3');
      } else {
        File(p.join(values['--vocals'] ?? '.', '$name.vocals16.f32'))
            .copySync(vocals);
        // Marked as made from no file: the run reuses them.
        File(vocalsMarkerOf(vocals))
            .writeAsStringSync(jsonEncode({'audio': audio, 'bytes': null}));
      }
      final hear = HearWords(
        runner: worker,
        paths: paths,
        save: store.saveHeardLyrics,
        log: print,
        russianAt: mode == 'force' ? 1.01 : russianConfidence,
      );
      final clock = Stopwatch()..start();
      final run = hear.start(
        ref: 'check_$tag',
        audioPath: audio,
        vocalsPath: vocals,
        audioBytes: mode == 'full' ? File(audio).lengthSync() : null,
      );
      final steps = <String>[];
      run.progress.listen((unit) {
        if (steps.isEmpty || steps.last != unit.step) steps.add(unit.step);
      });
      try {
        await run.result;
      } on Object catch (error) {
        print('$tag: FAILED $error');
        failed = true;
        continue;
      }
      final ms = clock.elapsedMilliseconds;
      final heard = store.heardLyricsOf('check_$tag')!;
      final text = heard.words.map((word) => word.text).join(' ');
      final letters =
          _cyrillic.allMatches(text).length +
          _latin.allMatches(text).length +
          _cjk.allMatches(text).length;
      String share(RegExp script) => letters == 0
          ? '0'
          : (script.allMatches(text).length / letters).toStringAsFixed(2);
      File(p.join(out.path, '$tag.json')).writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert({
          'song': tag,
          'steps': steps,
          'ms': ms,
          'outcome': heard.outcome.name,
          'model': heard.model?.name,
          'language': heard.language,
          'confidence': heard.confidence,
          'ru_confidence': heard.russianConfidence,
          'rough': heard.rough,
          'word_count': heard.wordCount,
          'loud_s': heard.loudSeconds,
          'vocals_left': vocalsFile.existsSync(),
          'lines': [
            for (final line in heard.lines)
              {'t': line.text, 's': line.startMs, 'e': line.endMs},
          ],
          'words': jsonDecode(heard.wordsToJson()),
        }),
      );
      final sung = heard.lines.where((line) => !line.isGap).toList();
      final sizes = [for (final line in sung) line.text.split(' ').length]
        ..sort();
      print(
        '$tag: ${heard.outcome.name} by ${heard.model?.name ?? 'none'} '
        '${heard.language ?? '-'}, steps ${steps.join('>')}, '
        'GigaAM ${heard.russianConfidence.toStringAsFixed(3)}, '
        'confidence ${heard.confidence.toStringAsFixed(3)}, '
        'rough ${heard.rough}, ${heard.wordCount} words, '
        '${sung.length} lines (+${heard.lines.length - sung.length} gaps, '
        'words per line median ${sizes.isEmpty ? 0 : sizes[sizes.length ~/ 2]}'
        ', max ${sizes.isEmpty ? 0 : sizes.last}), '
        'Cyrillic ${share(_cyrillic)} Latin ${share(_latin)} '
        'CJK ${share(_cjk)}, loud ${heard.loudSeconds.toStringAsFixed(1)} s, '
        'vocals left ${vocalsFile.existsSync()}, $ms ms',
      );
    }
  } finally {
    await worker.close();
    store.close();
    temp.deleteSync(recursive: true);
  }
  exit(failed ? 1 : 0);
}
