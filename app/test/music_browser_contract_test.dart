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
    'route poll already in flight cannot reload newly opened private sign-in',
    () async {
      final factory = GeneratedBrowserFactory();
      final vk = VkProvider(
        browserFactory: factory,
        loadAdapter: () async => 'generated-only',
        status: (_) {},
        changed: () {},
      );
      try {
        await vk.connect();
        await Future<void>.delayed(Duration.zero);
        final reading = factory.readingUrl = Completer<Uri?>();
        final polling = vk.pollRoute();
        final rejected = expectLater(
          polling,
          failure('private_signin_in_progress'),
        );
        await vk.signInPrivately();
        factory.events.clear();
        reading.complete(Uri.parse('https://vk.ru/'));
        await rejected;
        expect(factory.events, isEmpty);
        expect(vk.connected, isFalse);
      } finally {
        await vk.disconnect();
      }
    },
  );

  test(
    'only explicit completion resumes route recovery on the same session',
    () async {
      final factory = GeneratedBrowserFactory();
      final vk = VkProvider(
        browserFactory: factory,
        loadAdapter: () async => 'generated-only',
        status: (_) {},
        changed: () {},
      );
      try {
        await vk.signInPrivately();
        final page = factory.pages.single;
        page.uri = Uri.parse('https://vk.ru/');
        page.events.loaded(page.uri);
        expect(vk.privateSignInActive, isTrue);
        factory.events.clear();
        await expectLater(
          vk.sync((_) {}, fromTop: true),
          failure('private_signin_in_progress'),
        );
        await expectLater(
          vk.inspectMetadata(const Track('1_2', 'Generated', 'Fixture', 10)),
          failure('private_signin_in_progress'),
        );
        expect(factory.events, isEmpty);
        await vk.finishPrivateSignIn();
        await vk.connect();
        expect(identical(factory.pages.first, page), isTrue);
        expect(vk.privateSignInActive, isFalse);
        expect(factory.events, contains('navigate:https://vk.ru/audios'));
      } finally {
        await vk.disconnect();
      }
    },
  );

  test('private sign-in owns one page without warming or extracting', () async {
    final factory = GeneratedBrowserFactory();
    final vk = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-only',
      status: (_) {},
      changed: () {},
    );
    try {
      await vk.signInPrivately();
      await Future<void>.delayed(Duration.zero);
      expect(factory.pages, hasLength(1));
      expect(vk.connected, isFalse);
      expect(
        factory.events.where((e) => e == 'evaluate' || e == 'script'),
        isEmpty,
      );
      expect(factory.events.last, 'sign-in');
    } finally {
      await vk.disconnect();
    }
  });
  test(
    'background reconnect cannot navigate an active private sign-in',
    () async {
      final factory = GeneratedBrowserFactory();
      final vk = VkProvider(
        browserFactory: factory,
        loadAdapter: () async => 'generated-only',
        status: (_) {},
        changed: () {},
      );
      try {
        await vk.signInPrivately();
        await Future<void>.delayed(Duration.zero);
        final page = factory.pages.first;
        factory.events.clear();
        for (var i = 0; i < 4; i++) {
          // Login may visit the root/feed between transient music/blank routes.
          page.events.historyChanged(Uri.parse('https://vk.ru/audios'));
          page.uri = Uri.parse('https://vk.ru/');
          page.events.loaded(page.uri);
          await vk.connect();
          await vk.pollRoute();
        }
        expect(factory.events, isEmpty);
        expect(page.uri, Uri.parse('https://vk.ru/'));
        expect(vk.connected, isFalse);
      } finally {
        await vk.disconnect();
      }
    },
  );

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
