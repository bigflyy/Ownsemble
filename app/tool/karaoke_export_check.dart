// Plan 11 D1c real check: the KaraokeExporter end to end on real test-account
// songs, with the video maker downloaded from the public release into a
// scratch models folder (D1t), the song decoded by the app's own libmpv,
// the real background and line layout, and the downloaded ffmpeg.exe.
// Runs under flutter test (it needs Flutter's text layout and painting):
//
//   KARAOKE_DATA=../.local/v2-test/gate-words KARAOKE_OUT=../.local/v2-test/karaoke-d1 \
//   KARAOKE_MPV=build/windows/x64/runner/Release/libmpv-2.dll \
//   KARAOKE_SONGS=660306161_456239025:heard,660306161_456239134:lrclib \
//   flutter test tool/karaoke_export_check.dart
//
// Videos go to KARAOKE_OUT/videos (never the user's Videos folder). Prints
// only keys, numbers and shapes (no song names: they may be Russian).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/karaoke/karaoke_audio.dart';
import 'package:ownsemble/karaoke/karaoke_background.dart';
import 'package:ownsemble/karaoke/karaoke_exporter.dart';
import 'package:ownsemble/karaoke/karaoke_measure.dart';
import 'package:ownsemble/karaoke/karaoke_script.dart';
import 'package:ownsemble/karaoke/video_tools.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/storage/cover_store.dart' show coverKey;
import 'package:ownsemble/ui/lyrics_page.dart' show lyricsLeadMs;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export real songs', () async {
    // The test binding answers every HTTP request with 400; this check
    // downloads the real video maker.
    HttpOverrides.global = null;
    final env = Platform.environment;
    final data = p.absolute(env['KARAOKE_DATA']!);
    final outDir = Directory(p.absolute(env['KARAOKE_OUT']!))
      ..createSync(recursive: true);
    final mpv = p.absolute(env['KARAOKE_MPV']!);
    final songs = env['KARAOKE_SONGS']!.split(',');
    final models = Directory(p.join(outDir.path, 'models'));
    final videos = Directory(p.join(outDir.path, 'videos'));
    final scratch = Directory(p.join(outDir.path, 'tmp'));

    final font = File(r'C:\Windows\Fonts\segoeuib.ttf').readAsBytesSync();
    await (FontLoader(
      'KaraokeSegoe',
    )..addFont(Future.value(ByteData.sublistView(font)))).load();
    final measure = KaraokeMeasure(fontFamily: 'KaraokeSegoe');

    var downloaded = 0;
    final exporter = KaraokeExporter(
      toolReady: () => bundleReady(models, videoToolsBundle),
      downloadTool: (onProgress, stop) async {
        final clock = Stopwatch()..start();
        await downloadBundle(
          videoToolsBundle,
          models,
          onProgress: (bytes, total) {
            downloaded = bytes;
            onProgress(bytes, total);
          },
          stop: stop,
        );
        stdout.writeln(
          'tool downloaded: $downloaded bytes in ${clock.elapsedMilliseconds} ms',
        );
      },
      ffmpegPath: () =>
          bundleFile(models, videoToolsBundle, ffmpegFileName).path,
      audioOf: (track, onProgress) async =>
          p.join(data, 'cache', 'vk_${track.sourceKey}.mp3'),
      routeKeyOf: (track) => track.sourceKey,
      decode: (audioPath, outPath) => decodeForKaraoke(mpv, audioPath, outPath),
      background: karaokeBackground,
      measure: measure.call,
      scratchRoot: () => scratch,
      outputFolder: () => videos,
      log: (line) => stdout.writeln('log: $line'),
    );
    var lastStage = '';
    exporter.addListener(() {
      final job = exporter.job;
      if (job == null) return;
      final text = karaokeStageText(job.stage);
      // Only step changes and every 25 %.
      final head = text.replaceFirst(RegExp(r', \d+%.*'), '');
      final share = RegExp(r'(\d+)%').firstMatch(text)?.group(1);
      final mark = '$head ${share == null ? '' : int.parse(share) ~/ 25}';
      if (mark != lastStage) {
        lastStage = mark;
        stdout.writeln('stage: $text');
      }
    });

    final db = sqlite3.open(
      p.join(data, 'library.db'),
      mode: OpenMode.readOnly,
    );
    for (final song in songs) {
      final [ref, from] = song.split(':');
      final row = db.select(
        'SELECT id, artist, title, duration_sec, cover_full_url, '
        'cover_large_url, cover_mid_url, cover_url FROM tracks '
        'WHERE source_key = ?',
        [ref],
      ).first;
      Uint8List? cover;
      for (final column in [
        'cover_full_url',
        'cover_large_url',
        'cover_mid_url',
        'cover_url',
      ]) {
        final url = row[column] as String?;
        final key = url == null ? null : coverKey(url);
        final file = File(p.join(data, 'covers', '$key.jpg'));
        if (key != null && file.existsSync()) {
          cover = file.readAsBytesSync();
          break;
        }
      }
      final track = Track(
        id: row['id'] as int,
        sourceId: 1,
        source: TrackSource.vk,
        artist: row['artist'] as String,
        title: row['title'] as String,
        durationSec: row['duration_sec'] as int,
        sourceKey: ref,
      );
      final clock = Stopwatch()..start();
      final outcome = await exporter.export(
        KaraokeRequest(
          track: track,
          key: ref,
          lines: _linesOf(db, ref, from),
          shiftMs: -lyricsLeadMs,
          shapes: KaraokeShape.values,
          voices: const [KaraokeVoice.withVoice],
          cover: cover,
        ),
      );
      stdout.writeln(
        '== $ref ($from): ${outcome.runtimeType} in '
        '${clock.elapsedMilliseconds} ms',
      );
      if (outcome is KaraokeFailed)
        stdout.writeln('failed: ${outcome.message}');
      expect(outcome, isA<KaraokeDone>());
      final files = (outcome as KaraokeDone).files;
      expect(files, hasLength(2));
      for (final (i, file) in files.indexed) {
        final probe = await Process.run('ffprobe', [
          '-v', 'error', '-print_format', 'json', //
          '-show_entries',
          'stream=codec_name,width,height,pix_fmt,r_frame_rate,duration,'
              'sample_rate,channels',
          file.path,
        ], stdoutEncoding: utf8);
        final streams =
            (jsonDecode(probe.stdout as String)
                    as Map<String, Object?>)['streams']
                as List<Object?>;
        final shape = KaraokeShape.values[i];
        stdout.writeln(
          '$ref ${shape.name}: ${file.lengthSync()} bytes, '
          '${streams.map((s) => (s as Map).values.join('/')).join(' + ')}',
        );
        // Copied to an ASCII name for looking at frames later.
        file.copySync(
          p.join(outDir.path, '${ref.split('_').last}-${shape.name}.mp4'),
        );
      }
    }
    db.close();
    expect(scratch.existsSync() ? scratch.listSync() : const [], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// The song's lines: what Hear the words heard (with its word times), or
/// lrclib's timed lines (no word times).
List<LyricLine> _linesOf(Database db, String ref, String from) {
  if (from == 'heard') {
    final row = db.select(
      'SELECT body, words FROM heard_lyrics WHERE ref = ?',
      [ref],
    ).first;
    return withHeardWordTimes(
      Lyrics.linesFromJson(row['body'] as String),
      HeardLyrics.wordsFromJson(row['words'] as String?),
    );
  }
  final row = db.select(
    'SELECT body FROM lyrics WHERE ref = ? AND source = ?',
    [ref, from],
  ).first;
  return Lyrics.linesFromJson(row['body'] as String);
}
