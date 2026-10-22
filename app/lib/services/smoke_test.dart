import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../media/audio_policy.dart';
import '../media/local_audio.dart';
import 'app_controller.dart';

Future<void> runSmokeTest(
  AppController c,
  GlobalKey boundary, {
  required bool resumed,
}) async {
  final report = File('${c.store.directory.path}/smoke.json');
  final checks = <String, bool>{};
  void check(String name, bool value) {
    checks[name] = value;
    if (!value) throw const ProofFailure('smoke_check_failed');
  }

  try {
    if (resumed) {
      check('mute_restart_state', c.muted && c.volumeLevel == 0);
      await c.toggleMute();
      await waitUntil(
        () => (c.player.state.volume - 23).abs() < .01,
        'smoke_unmute_timeout',
      );
      check('mute_restart_restore', c.volumeLevel == 23);
    }
    await c.volume(23);
    await waitUntil(
      () => (c.player.state.volume - 23).abs() < .01,
      'smoke_volume_timeout',
    );
    await c.toggleMute();
    await waitUntil(() => c.player.state.volume == 0, 'smoke_mute_timeout');
    check('native_mute', c.muted);
    await c.toggleMute();
    await waitUntil(
      () => (c.player.state.volume - 23).abs() < .01,
      'smoke_unmute_timeout',
    );
    check('native_unmute_restores_volume', !c.muted && c.volumeLevel == 23);
    await c.volume(0);
    check('library_1200', c.store.count == 1200);
    check('cyrillic_search', c.store.rows(query: 'СЕВЕРНЫЙ СВЕТ').isNotEmpty);
    final pile = c.store.piles().first;
    final rows = c.store.rows(pile: pile.id);
    final qualifiedBefore =
        c.store.db
                .select('SELECT COALESCE(SUM(qualified),0) AS n FROM plays')
                .first['n']
            as int;
    check(
      'independent_occurrences',
      rows
              .where((r) => r.track.id == '900000000000001_1')
              .map((r) => r.occurrence)
              .toSet()
              .length ==
          2,
    );
    c.store.pinTrack('900000000000001_1', true);
    c.store.pinPile(pile.id, true);
    c.store.pinTrack('900000000000001_1', false);
    check('overlapping_pins', c.store.isPinned('900000000000001_1'));
    await c.playRows(rows, 0);
    await waitUntil(
      () => c.player.state.position.inMilliseconds >= 200,
      'smoke_player_timeout',
    );
    await c.seek(.4);
    await waitUntil(
      () => c.player.state.position.inMilliseconds >= 2800,
      'smoke_seek_timeout',
    );
    await c.player.pause();
    await waitUntil(
      () =>
          (c.store.db
                  .select('SELECT COALESCE(SUM(qualified),0) AS n FROM plays')
                  .first['n']
              as int) >
          qualifiedBefore,
      'smoke_listen_not_qualified',
    );
    check('qualified_listen', true);
    check('native_play_seek', c.player.state.duration.inMilliseconds > 3900);
    check(
      'queue_occurrence',
      c.queue.current?.occurrence == rows.first.occurrence,
    );
    await c.next();
    await waitUntil(
      () => c.player.state.position.inMilliseconds >= 150,
      'smoke_next_timeout',
    );
    check(
      'next_selected_occurrence',
      c.queue.current?.occurrence == rows[1].occurrence,
    );
    await c.previous();
    await waitUntil(
      () => c.player.state.position.inMilliseconds >= 150,
      'smoke_previous_timeout',
    );
    await c.player.pause();
    check(
      'previous_selected_occurrence',
      c.queue.current?.occurrence == rows[0].occurrence,
    );
    await c.setQuota(1);
    check(
      'pins_survive_quota',
      c.store.asset('900000000000001_1') != null &&
          c.store.asset('900000000000001_2') != null,
    );
    check('unpinned_evicted', c.store.asset('900000000000001_3') == null);
    c.store.setSetting('quota_bytes', 2 * 1024 * 1024 * 1024);
    c.browse('library');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await render.toImage(pixelRatio: 1.0);
    final png = await picture.toByteData(format: ui.ImageByteFormat.png);
    await File('${c.store.directory.path}/preview.png')
        .writeAsBytes(png!.buffer.asUint8List());
    picture.dispose();
    check('rendered_ui', true);
    await report.writeAsString(
      jsonEncode({'passed': true, 'resumed': resumed, 'checks': checks}),
    );
    c.store.report(
      resumed ? 'smoke_restart_passed' : 'smoke_online_passed',
      count: c.store.count,
    );
    if (!resumed) {
      await c.shutdown();
      await Process.start(
        Platform.resolvedExecutable,
        ['--smoke-resume'],
        workingDirectory: Directory.current.path,
        mode: ProcessStartMode.detached,
      );
      exit(0);
    }
  } catch (e) {
    await report.writeAsString(
      jsonEncode({
        'passed': false,
        'resumed': resumed,
        'category': categoryOf(e),
        'checks': checks,
      }),
    );
    c.store.report('smoke_failed');
  }
}
