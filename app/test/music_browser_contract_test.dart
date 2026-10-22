// Same canonical file URIs as the standalone cross-OS VM fixture.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/contracts/music_browser.dart';

import '../tool/fixtures/generated_browser.dart';

import '../lib/media/audio_policy.dart';
import '../lib/provider/vk_provider.dart';

VkProvider provider(GeneratedBrowserFactory factory) => VkProvider(
  browserFactory: factory,
  loadAdapter: () async => 'generated-only',
  status: (_) {},
  changed: () {},
  playbackOnly: true,
);
Matcher failure(String category) => throwsA(
  isA<ProofFailure>().having((e) => e.category, 'category', category),
);

void main() {
  test(
    'a missing mandatory capability rejects before environment/page access',
    () async {
      for (final capability in BrowserCapability.values) {
        final factory = GeneratedBrowserFactory()
          ..capabilities.remove(capability);
        final vk = provider(factory);
        await expectLater(vk.connect(), failure('browser_capability_missing'));
        expect(factory.prepares, 0);
        expect(factory.pages, isEmpty);
        await vk.disconnect();
      }
    },
  );
  test('any backend runs VK lifecycle without OS or plugin calls', () async {
    final factory = GeneratedBrowserFactory();
    final vk = provider(factory);
    final first = vk.connect(), second = vk.connect();
    expect(identical(first, second), isTrue);
    await first;
    expect(factory.pages, hasLength(1));
    expect(factory.events, [
      'open:about:blank',
      'mute',
      'script',
      'navigate:https://vk.ru/audios',
      'hide',
    ]);
    expect(vk.connected, isTrue);
    await vk.disconnect();
    expect(factory.pages.single.closed, isTrue);
  });
  test(
    'unconfirmed native isolation closes the renderer before music navigation',
    () async {
      final factory = GeneratedBrowserFactory()..muted = false;
      final vk = provider(factory);
      await expectLater(vk.connect(), failure('browser_mute_unavailable'));
      expect(factory.pages.single.closed, isTrue);
      expect(factory.events, ['open:about:blank', 'mute']);
      await vk.disconnect();
    },
  );
  test('an isolation API failure also closes the renderer', () async {
    final factory = GeneratedBrowserFactory()..failMute = true;
    final vk = provider(factory);
    await expectLater(vk.connect(), failure('browser_mute_unavailable'));
    expect(factory.pages.single.closed, isTrue);
    expect(factory.events, ['open:about:blank', 'mute']);
    await vk.disconnect();
  });
  test(
    'sign-in route is rejected without executing or loading adapter scripts',
    () async {
      final factory = GeneratedBrowserFactory();
      final vk = provider(factory);
      await vk.connect();
      factory.pages.single.uri = Uri.parse('https://id.vk.com/auth');
      await expectLater(
        vk.sync((_) {}, fromTop: true),
        failure('private_signin_required'),
      );
      expect(factory.events.where((e) => e == 'evaluate'), isEmpty);
      await vk.disconnect();
    },
  );
  test(
    'disconnect during environment preparation cannot open a late renderer',
    () async {
      final factory = GeneratedBrowserFactory()..preparing = Completer<void>();
      final vk = provider(factory);
      final connecting = vk.connect();
      final rejected = expectLater(connecting, failure('cancelled'));
      await Future<void>.delayed(Duration.zero);
      await vk.disconnect();
      factory.preparing!.complete();
      await rejected;
      expect(factory.pages, isEmpty);
    },
  );
  test(
    'events from a closed generation cannot disconnect a new page',
    () async {
      final factory = GeneratedBrowserFactory();
      final vk = provider(factory);
      await vk.connect();
      final old = factory.pages.single;
      await vk.disconnect();
      await vk.connect();
      expect(vk.connected, isTrue);
      old.events.exited();
      old.events.historyChanged(Uri.parse('https://id.vk.com/auth'));
      expect(vk.connected, isTrue);
      await vk.disconnect();
      expect(factory.pages.last.closed, isTrue);
    },
  );
  test('failed open disposes the renderer and allows a clean retry', () async {
    final factory = GeneratedBrowserFactory()..failOpen = true;
    final vk = provider(factory);
    await expectLater(vk.connect(), throwsStateError);
    expect(factory.pages.single.closed, isTrue);
    factory.failOpen = false;
    await vk.connect();
    expect(factory.pages, hasLength(2));
    expect(vk.connected, isTrue);
    await vk.disconnect();
  });
  test(
    'disconnect during open never installs scripts on a late renderer',
    () async {
      final factory = GeneratedBrowserFactory()..opening = Completer<void>();
      final vk = provider(factory);
      final connecting = vk.connect();
      final rejected = expectLater(connecting, failure('cancelled'));
      await Future<void>.delayed(Duration.zero);
      await vk.disconnect();
      await rejected;
      factory.opening!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(factory.pages.single.closed, isTrue);
      expect(
        factory.events.where((e) => e == 'script' || e.startsWith('navigate:')),
        isEmpty,
      );
    },
  );
}
