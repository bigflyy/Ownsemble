// Plan 11 C2/C3: render 20 s karaoke clips of real test-account songs in
// both shapes, to look at the picture before the export exists in the app.
// Runs under flutter test (it needs Flutter's text layout and painting):
//
//   KARAOKE_DATA=../.local/v2-test/gate-words KARAOKE_OUT=../.local/v2-test/karaoke-c2 \
//   KARAOKE_FFMPEG=ffmpeg KARAOKE_SONGS=660306161_456239025:heard,... \
//   flutter test tool/karaoke_clips.dart
//
// KARAOKE_SONGS: upload keys, each with where its lines come from: heard
// (Hear the words: own word times) or lrclib (line times only, so the words
// are guessed), and optionally :nocover (render as if the song had no
// cover). Two clips per song: 20 s from 15 s before the first line (title
// card, count-down) and 20 s from the line nearest 45 % of the song. For each clip and shape it writes
// the mp4 and a sheet of four frames (2, 6, 10, 14 s) into KARAOKE_OUT.
// The decoder for the song's audio is always ffmpeg from PATH (the trimmed
// build has no mp3 decoder); KARAOKE_FFMPEG renders the video.
// Prints only keys, numbers and file names (no song names: they may be
// Russian, and the chat stays English).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/karaoke/karaoke_background.dart';
import 'package:ownsemble/karaoke/karaoke_measure.dart';
import 'package:ownsemble/karaoke/karaoke_script.dart';
import 'package:ownsemble/lyrics/heard_lyrics.dart';
import 'package:ownsemble/lyrics/lyrics.dart';
import 'package:ownsemble/storage/cover_store.dart' show coverKey;
import 'package:ownsemble/ui/lyrics_page.dart' show lyricsLeadMs;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const clipMs = 20000;
const rate = 44100;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render karaoke clips', () async {
    final env = Platform.environment;
    final data = p.absolute(env['KARAOKE_DATA']!);
    final outDir = Directory(p.absolute(env['KARAOKE_OUT']!))
      ..createSync(recursive: true);
    final ffmpeg = env['KARAOKE_FFMPEG'] ?? 'ffmpeg';
    final songs = env['KARAOKE_SONGS']!.split(',');

    // Segoe UI Bold under its own name, as DirectWrite gives it to libass.
    final font = File(r'C:\Windows\Fonts\segoeuib.ttf').readAsBytesSync();
    await (FontLoader(
      'KaraokeSegoe',
    )..addFont(Future.value(ByteData.sublistView(font)))).load();
    final measure = KaraokeMeasure(fontFamily: 'KaraokeSegoe');

    final db = sqlite3.open(
      p.join(data, 'library.db'),
      mode: OpenMode.readOnly,
    );
    for (final song in songs) {
      final [ref, from, ...flags] = song.split(':');
      final track = db.select(
        'SELECT artist, title, duration_sec, cover_full_url, cover_large_url, '
        'cover_mid_url, cover_url FROM tracks WHERE source_key = ?',
        [ref],
      ).first;
      final lines = _linesOf(db, ref, from);
      final durationMs = (track['duration_sec'] as int) * 1000;
      Uint8List? cover;
      for (final column in [
        'cover_full_url',
        'cover_large_url',
        'cover_mid_url',
        'cover_url',
      ]) {
        if (flags.contains('nocover')) break;
        final url = track[column] as String?;
        final key = url == null ? null : coverKey(url);
        final file = File(p.join(data, 'covers', '$key.jpg'));
        if (key != null && file.existsSync()) {
          cover = file.readAsBytesSync();
          break;
        }
      }
      final audio = p.join(data, 'cache', 'vk_$ref.mp3');
      final timed = lines.where((line) => line.startMs != null).toList();
      final middle = timed.isEmpty
          ? 0
          : timed
                .reduce(
                  (a, b) =>
                      (a.startMs! - durationMs * 0.45).abs() <=
                          (b.startMs! - durationMs * 0.45).abs()
                      ? a
                      : b,
                )
                .startMs!;
      stdout.writeln(
        '== $ref ($from): ${timed.length} timed lines, '
        'cover ${cover == null ? 'none' : '${cover.length} bytes'}',
      );
      // The first clip starts 15 s before the first line, so a long intro
      // shows its title card and count-down dots.
      final first = timed.isEmpty ? 0 : timed.first.startMs!;
      final opening = first > 15000 ? first - 15000 : 0;
      for (final (clip, startMs) in [('start', opening), ('mid', middle)]) {
        final job = Directory(p.join(outDir.path, 'job'))
          ..createSync(recursive: true);
        // The song's audio from startMs, as raw float like the app's.
        final decoded = await Process.run('ffmpeg', [
          '-hide_banner', '-loglevel', 'error', '-y', //
          '-ss', '${startMs / 1000}', '-t', '${clipMs / 1000}', '-i', audio,
          '-f', 'f32le', '-ar', '$rate', '-ac', '2', 'audio.f32',
        ], workingDirectory: job.path);
        if (decoded.exitCode != 0) {
          throw StateError('decode: ${decoded.stderr}');
        }
        final samples = File(p.join(job.path, 'audio.f32')).lengthSync() ~/ 8;
        // Lines of the window, moved so the clip starts at 0; the shift
        // also carries the Lyrics page's lead, as the export will.
        final window = KaraokeLines.of([
          for (final line in lines)
            if (line.startMs == null || line.startMs! >= startMs) line,
        ], shiftMs: -lyricsLeadMs - startMs);
        for (final shape in KaraokeShape.values) {
          final watch = Stopwatch()..start();
          final script = karaokeScript(
            lines: window,
            shape: shape,
            title: track['title'] as String,
            artist: track['artist'] as String,
            durationMs: samples * 1000 ~/ rate,
            measure: measure.call,
          );
          final scriptMs = watch.elapsedMilliseconds;
          File(p.join(job.path, 'karaoke.ass')).writeAsStringSync(script);
          watch.reset();
          final background = await karaokeBackground(cover, shape);
          File(p.join(job.path, 'bg.png')).writeAsBytesSync(background);
          final backgroundMs = watch.elapsedMilliseconds;
          watch.reset();
          final rendered = await Process.run(ffmpeg, [
            '-hide_banner', '-nostdin', '-y', '-loglevel', 'error', //
            '-threads', '2',
            '-f', 'f32le', '-ar', '$rate', '-ac', '2', '-i', 'audio.f32',
            '-f', 'image2', '-loop', '1', '-framerate', '30', '-i', 'bg.png',
            '-filter_complex', '[1:v]ass=karaoke.ass,format=yuv420p[v]',
            '-map', '[v]', '-map', '0:a',
            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
            '-threads', '2', '-pix_fmt', 'yuv420p', '-r', '30',
            '-c:a', 'aac', '-b:a', '192k',
            '-t', (samples / rate).toStringAsFixed(6),
            '-movflags', '+faststart', 'out.mp4',
          ], workingDirectory: job.path);
          if (rendered.exitCode != 0) {
            throw StateError('render: ${rendered.stderr}');
          }
          final renderMs = watch.elapsedMilliseconds;
          final name = '${ref.split('_').last}-$clip-${shape.name}';
          final mp4 = p.join(outDir.path, '$name.mp4');
          File(p.join(job.path, 'out.mp4')).renameSync(mp4);
          File(p.join(job.path, 'karaoke.ass'))
              .copySync(p.join(outDir.path, '$name.ass'));
          final tile = shape == KaraokeShape.landscape
              ? 'scale=960:-1,tile=2x2'
              : 'scale=540:-1,tile=4x1';
          final sheet = await Process.run('ffmpeg', [
            '-hide_banner', '-loglevel', 'error', '-y', //
            '-ss', '2', '-i', mp4, '-vf', 'fps=1/4,$tile',
            '-frames:v', '1', p.join(outDir.path, '$name.png'),
          ]);
          if (sheet.exitCode != 0) throw StateError('sheet: ${sheet.stderr}');
          stdout.writeln(
            '$name: ${window.lines.length} lines '
            '(${window.guessedLines} guessed), script $scriptMs ms, '
            'background $backgroundMs ms, render $renderMs ms',
          );
        }
      }
    }
    db.close();
  }, timeout: const Timeout(Duration(minutes: 15)));
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
