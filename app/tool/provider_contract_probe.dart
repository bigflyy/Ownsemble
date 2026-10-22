// Standalone VM probes deliberately avoid a Flutter package resolution step.
// ignore_for_file: avoid_relative_lib_imports, avoid_print
// Platform-free generated acceptance: runs with the Dart VM on each target OS.
// This does not instantiate an OS browser, contact VK, or inspect real data.
import 'dart:async';
import 'dart:convert';

import '../lib/contracts/music_browser.dart';
import '../lib/media/audio_policy.dart';
import '../lib/provider/vk_provider.dart';
import '../lib/provider/guarded_input.dart';
import '../lib/services/playback_queue.dart';
import 'fixtures/generated_browser.dart';

void require(bool value, String label) {
  if (!value) throw StateError(label);
}

VkProvider provider(GeneratedBrowserFactory factory) => VkProvider(
  browserFactory: factory,
  loadAdapter: () async => 'generated-only',
  playbackOnly: true,
  status: (_) {},
  changed: () {},
);
Future<void> failure(Future<void> operation, String category) async {
  try {
    await operation;
  } on ProofFailure catch (error) {
    require(error.category == category, 'unexpected_category');
    return;
  }
  throw StateError('failure_not_raised');
}

Future<void> main() async {
  final checks = <String, bool>{};
  for (final missing in BrowserCapability.values) {
    final factory = GeneratedBrowserFactory()..capabilities.remove(missing);
    final vk = provider(factory);
    await failure(vk.connect(), 'browser_capability_missing');
    require(factory.pages.isEmpty && factory.prepares == 0, 'capability_gate');
    await vk.disconnect();
  }
  checks['capability_gate'] = true;
  final factory = GeneratedBrowserFactory();
  final vk = provider(factory);
  await vk.connect();
  require(vk.connected && factory.pages.length == 1, 'connection');
  require(
    factory.events.join('|') ==
        'open:about:blank|mute|script|navigate:https://vk.ru/audios|hide',
    'mute_before_music',
  );
  checks['shared_lifecycle'] = true;
  factory.pages.single.uri = Uri.parse('https://id.vk.com/auth');
  await failure(vk.sync((_) {}, fromTop: true), 'private_signin_required');
  require(!factory.events.contains('evaluate'), 'login_script_guard');
  checks['login_script_guard'] = true;
  final old = factory.pages.single;
  await vk.disconnect();
  await vk.connect();
  old.events.exited();
  old.events.historyChanged(Uri.parse('https://id.vk.com/auth'));
  require(vk.connected, 'stale_event');
  await vk.disconnect();
  checks['generation_isolation'] = true;
  final slow = GeneratedBrowserFactory()..preparing = Completer<void>();
  final pending = provider(slow);
  final rejected = failure(pending.connect(), 'cancelled');
  await Future<void>.delayed(Duration.zero);
  await pending.disconnect();
  slow.preparing!.complete();
  await rejected;
  require(slow.pages.isEmpty, 'late_renderer');
  checks['cancel_before_create'] = true;
  for (final throws in [false, true]) {
    final unmuted = GeneratedBrowserFactory()
      ..muted = false
      ..failMute = throws;
    final unsafe = provider(unmuted);
    await failure(unsafe.connect(), 'browser_mute_unavailable');
    require(unmuted.pages.single.closed, 'mute_cleanup');
    await unsafe.disconnect();
  }
  checks['mute_fail_closed'] = true;
  final phases = <PointerPhase>[];
  var guards = 0;
  await dispatchGuardedTap(
    x: 1,
    y: 2,
    guard: () async {
      guards++;
    },
    dispatch: (event) async {
      phases.add(event.phase);
    },
  );
  require(
    guards == 3 && phases.join(',') == PointerPhase.values.join(','),
    'trusted_input_guards',
  );
  checks['guard_each_input'] = true;
  final queue = PlaybackQueue()
    ..replace([const QueueEntry('1_2', 1), const QueueEntry('1_2', 2)], 0);
  require(
    queue.current!.occurrence == 1 && queue.next()!.occurrence == 2,
    'occurrence_identity',
  );
  checks['duplicate_occurrences'] = true;
  print(
    jsonEncode({
      'passed': true,
      'checks': checks,
      'scope':
          'generated_shared_policy_only_no_native_browser_no_live_provider',
    }),
  );
}
