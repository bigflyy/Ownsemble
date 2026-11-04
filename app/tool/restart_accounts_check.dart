// Restart check of two VK accounts in the release build: both sessions are
// kept encrypted in the data folder, the way a login keeps them, and two
// separate runs of the app must each load both, sync both and stream through
// each one.
//
// Run from app/, with the release built:
//   OWNSEMBLE_BACKGROUND_WINDOW=1 dart run tool/restart_accounts_check.dart \
//       --data-dir ../.local/v2-test/restart-accounts \
//       --session ../.local/v2-test/session.json \
//       --session ../.local/v2-test/session-2.json
//
// The data folder is emptied first; it must be a folder of its own. The
// second account is read-only: the app only syncs it and streams it muted.
// The output holds source ids, row ids and counts, never a title, an account
// name, an account id or a session value, so a second account's songs stay
// out of it.

import 'dart:convert';
import 'dart:io';

import 'package:ownsemble/library/library_store.dart';
import 'package:ownsemble/library/track.dart';
import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_session.dart';
import 'package:path/path.dart' as p;

// ignore: avoid_print
void say(String line) => print(line);

/// Problems found so far; the check fails when any are left at the end.
final problems = <String>[];

void check(bool ok, String what) {
  if (!ok) problems.add(what);
  say('${ok ? 'ok  ' : 'FAIL'} $what');
}

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final dataDir = valueOf('--data-dir');
  final sessions = [
    for (var i = 0; i + 1 < args.length; i++)
      if (args[i] == '--session') File(args[i + 1]),
  ];
  // Absolute: Windows does not find a relative exe path for Process.start.
  final exe = p.absolute(
    valueOf('--exe') ?? 'build/windows/x64/runner/Release/ownsemble.exe',
  );
  if (dataDir == null || sessions.length != 2) {
    stderr.writeln('needs --data-dir and two --session files');
    exit(2);
  }
  if (p.basename(dataDir) != 'restart-accounts') {
    // The folder is emptied: refuse anything but this check's own folder.
    stderr.writeln('the data folder must be named restart-accounts');
    exit(2);
  }

  final data = Directory(p.absolute(dataDir));
  if (data.existsSync()) data.deleteSync(recursive: true);
  data.createSync(recursive: true);

  // 1. Keep both sessions encrypted, the way a finished login does: under
  // the VK user id VK gives for the session.
  final vault = ProtectedSessionFolder(data.path);
  final secrets = <String>[];
  for (final (index, file) in sessions.indexed) {
    final cookies = SessionCookie.loadAll(file);
    secrets.addAll(cookies.map((c) => c.value).where((v) => v.length >= 8));
    final client = VkClient(cookies);
    try {
      await client.ensureToken();
      check(client.userId > 0, 'session ${index + 1} gets a VK token');
      vault.save('${client.userId}', cookies);
    } finally {
      client.close();
    }
  }
  final sealed = Directory(p.join(data.path, 'sessions'))
      .listSync()
      .whereType<File>()
      .toList();
  check(sealed.length == 2, 'two session files in the data folder');
  for (final file in sealed) {
    final bytes = latin1.decode(file.readAsBytesSync());
    check(
      !secrets.any(bytes.contains),
      'session file ${sealed.indexOf(file) + 1} holds no cookie in plain text',
    );
  }

  // 2. Two runs of the release on that folder: the first syncs both accounts
  // into an empty library, the second is the restart.
  List<SourceInfo>? before;
  for (final run in [1, 2]) {
    say('--- run $run');
    final result = File(p.join(data.path, 'bench-$run.json'));
    final clock = Stopwatch()..start();
    final app = await Process.start(exe, [
      '--data-dir',
      data.path,
      '--muted',
      '--no-stream-cache',
      '--bench',
      result.path,
      '--bench-parts',
      'playEachSource',
    ]);
    app.stdout.drain<void>();
    app.stderr.drain<void>();
    final code = await app.exitCode.timeout(
      const Duration(minutes: 20),
      onTimeout: () {
        app.kill();
        return -1;
      },
    );
    say('run $run exited $code after ${clock.elapsed.inSeconds} s');
    check(code == 0, 'run $run ends by itself');
    if (!result.existsSync()) {
      check(false, 'run $run wrote its result');
      continue;
    }

    // Read by named fields only.
    final store = LibraryStore.open(p.join(data.path, 'library.db'));
    final sources = store.sources();
    final rows = store.loadAll();
    store.close();
    final merged = rows.where((t) => t.copies.isNotEmpty).length;
    say('rows ${rows.length}, merged $merged');
    final vkSources = sources.where((s) => s.kind == TrackSource.vk).toList();
    check(vkSources.length == 2, 'run $run: two VK sources');
    for (final source in vkSources) {
      final at = source.lastSyncAtMs;
      say(
        'source ${source.id}: ${source.songCount} songs, '
        '${source.goneCount} gone, synced ${at == null ? 'never' : DateTime.fromMillisecondsSinceEpoch(at).toIso8601String()}',
      );
      check(source.songCount > 0, 'run $run: source ${source.id} has songs');
      check(
        source.lastSyncError == null,
        'run $run: source ${source.id} synced without an error'
        '${source.lastSyncError == null ? '' : ' (${source.lastSyncError})'}',
      );
      final earlier = before?.where((s) => s.id == source.id).firstOrNull;
      if (earlier != null) {
        check(
          (at ?? 0) > (earlier.lastSyncAtMs ?? 0),
          'run $run: source ${source.id} synced again after the restart',
        );
        check(
          source.songCount == earlier.songCount,
          'run $run: source ${source.id} keeps its ${earlier.songCount} songs',
        );
      }
    }
    final sealedNow = Directory(p.join(data.path, 'sessions'))
        .listSync()
        .whereType<File>()
        .length;
    check(sealedNow == 2, 'run $run: still two session files');
    check(
      !File(p.join(data.path, 'session.dpapi')).existsSync(),
      'run $run: no single-session file',
    );

    final bench = jsonDecode(result.readAsStringSync()) as Map<String, Object?>;
    final played = bench['playEachSource'] as Map<String, Object?>? ?? {};
    for (final source in vkSources) {
      final part = played['${source.id}'] as Map<String, Object?>?;
      if (part == null) {
        check(false, 'run $run: source ${source.id} has songs to stream');
        continue;
      }
      final samples = (part['samples'] as List).cast<Map<String, Object?>>();
      for (final s in samples) {
        say(
          '  source ${source.id} row ${s['row']}: '
          '${s['ok'] == true ? 'sound ${s['toSoundMs']} ms, ${s['sampleRate']} Hz, '
                    'via source ${s['sourceId']}, skipped ${s['skippedAccounts']}, '
                    'playing after 1 s ${s['stillPlayingAfter1s']}' : 'no sound: ${s['error']}'}',
        );
      }
      final throughOwn = samples.where(
        (s) =>
            s['ok'] == true &&
            s['stillPlayingAfter1s'] == true &&
            s['sourceId'] == source.id &&
            (s['sampleRate'] as num? ?? 0) > 0,
      );
      check(
        throughOwn.length >= 3,
        'run $run: 3 songs only in source ${source.id} streamed through it '
        '(${throughOwn.length} of ${samples.length} tried, '
        '${part['onlyHere']} such songs)',
      );
      check(
        samples.every((s) => s['ok'] != true || s['sourceId'] == source.id),
        'run $run: no song of source ${source.id} went through another account',
      );
    }
    before = vkSources;
  }

  say(problems.isEmpty ? 'PASSED' : 'FAILED: ${problems.length} problem(s)');
  exit(problems.isEmpty ? 0 : 1);
}
