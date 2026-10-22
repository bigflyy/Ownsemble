import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:ownsemble/contracts/music_browser.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/platform/linux/browser_bridge.dart';
import 'package:ownsemble/platform/linux/linux_music_browser.dart';

class FixtureBridge implements BrowserBridge {
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final calls = <Map<String, dynamic>>[];
  final notices = <Map<String, dynamic>>[];
  Completer<dynamic>? creating;
  bool isolation = true,
      captureRequired = true,
      sandboxed = true,
      closed = false;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  void notify(Map<String, dynamic> message) => notices.add(message);
  @override
  Future<dynamic> request(String method, Map<String, dynamic> arguments) async {
    calls.add({'method': method, ...arguments});
    return switch (method) {
      'hello' => {
        'protocol': 1,
        'audio_capture_required': captureRequired,
        'sandbox_requested': true,
      },
      'create' =>
        creating == null
            ? {'audio_isolated': isolation, 'sandboxed': sandboxed}
            : creating!.future,
      'isolation' => isolation,
      'url' => 'about:blank',
      'evaluate' => 42,
      'isHidden' => true,
      _ => null,
    };
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Matcher category(String value) =>
    throwsA(isA<ProofFailure>().having((e) => e.category, 'category', value));
BrowserEvents events({
  bool Function(Uri?)? allow,
  void Function(Uri?)? request,
  void Function()? exited,
}) => BrowserEvents(
  exited: exited ?? () {},
  errored: () {},
  started: (_) {},
  loaded: (_) {},
  historyChanged: (_) {},
  request: request ?? (_) {},
  allowNavigation: allow ?? (_) => true,
);

void main() {
  test(
    'unattested renderer sandbox closes before provider navigation',
    () async {
      final bridge = FixtureBridge()..sandboxed = false;
      final factory = LinuxMusicBrowserFactory(
        'generated-only',
        launch: () async => bridge,
      );
      await factory.prepare();
      final page = factory.create(events());
      await expectLater(
        page.open(Uri.parse('https://vk.ru/audios')),
        category('browser_sandbox_unavailable'),
      );
      expect(bridge.calls.where((c) => c['method'] == 'navigate'), isEmpty);
      expect(bridge.closed, isTrue);
    },
  );

  test('native window exit releases its document and idle helper', () async {
    final bridge = FixtureBridge();
    final factory = LinuxMusicBrowserFactory(
      'generated-only',
      launch: () async => bridge,
    );
    await factory.prepare();
    final page = factory.create(events());
    await page.open(Uri.parse('about:blank'));
    final id = bridge.calls.firstWhere(
      (c) => c['method'] == 'create',
    )['browser'];
    bridge.controller.add({'event': 'closed', 'browser': id});
    await Future<void>.delayed(Duration.zero);
    expect(bridge.closed, isTrue);
    expect(factory.prepared, isFalse);
  });
  test(
    'a document cannot create a second native renderer by opening twice',
    () async {
      final bridge = FixtureBridge();
      final factory = LinuxMusicBrowserFactory(
        'generated-only',
        launch: () async => bridge,
      );
      await factory.prepare();
      final page = factory.create(events());
      await page.open(Uri.parse('about:blank'));
      await expectLater(
        page.open(Uri.parse('about:blank')),
        category('browser_already_open'),
      );
      expect(bridge.calls.where((c) => c['method'] == 'create'), hasLength(1));
      await page.close();
    },
  );

  test(
    'Linux factory deduplicates preparation and owns independent documents',
    () async {
      final bridge = FixtureBridge();
      var starts = 0;
      final factory = LinuxMusicBrowserFactory(
        'generated-only',
        launch: () async {
          starts++;
          return bridge;
        },
      );
      await Future.wait([factory.prepare(), factory.prepare()]);
      expect(starts, 1);
      final first = factory.create(events()), second = factory.create(events());
      await Future.wait([
        first.open(Uri.parse('about:blank')),
        second.open(Uri.parse('about:blank')),
      ]);
      final ids = bridge.calls
          .where((c) => c['method'] == 'create')
          .map((c) => c['browser'])
          .toSet();
      expect(ids, hasLength(2));
      await first.close();
      expect(bridge.closed, isFalse);
      await second.close();
      expect(bridge.closed, isTrue);
      expect(factory.prepared, isFalse);
    },
  );
  test('unsafe helper handshake fails closed before any renderer', () async {
    final bridge = FixtureBridge()..captureRequired = false;
    final factory = LinuxMusicBrowserFactory(
      'generated-only',
      launch: () async => bridge,
    );
    await expectLater(
      factory.prepare(),
      category('browser_capability_missing'),
    );
    expect(factory.prepared, isFalse);
    expect(bridge.calls.where((c) => c['method'] == 'create'), isEmpty);
    expect(bridge.closed, isTrue);
  });
  test('failed native isolation closes before provider navigation', () async {
    final bridge = FixtureBridge()..isolation = false;
    final factory = LinuxMusicBrowserFactory(
      'generated-only',
      launch: () async => bridge,
    );
    await factory.prepare();
    final page = factory.create(events());
    await expectLater(
      page.open(Uri.parse('https://vk.ru/audios')),
      category('browser_mute_unavailable'),
    );
    expect(bridge.calls.where((c) => c['method'] == 'navigate'), isEmpty);
    expect(bridge.calls.any((c) => c['method'] == 'close'), isTrue);
  });
  test(
    'navigation policy protects explicit and renderer-initiated navigation',
    () async {
      final bridge = FixtureBridge();
      final factory = LinuxMusicBrowserFactory(
        'generated-only',
        launch: () async => bridge,
      );
      await factory.prepare();
      final page = factory.create(
        events(allow: (uri) => uri?.scheme == 'about'),
      );
      await page.open(Uri.parse('about:blank'));
      await expectLater(
        page.navigate(Uri.parse('https://example.invalid')),
        category('browser_navigation_blocked'),
      );
      final id = bridge.calls.firstWhere(
        (c) => c['method'] == 'create',
      )['browser'];
      bridge.controller.add({
        'event': 'navigation',
        'browser': id,
        'token': 12,
        'uri': 'https://example.invalid',
      });
      expect(bridge.notices.last, {'decision': 12, 'allow': false});
      await page.close();
    },
  );
  test('close during creation disposes the late native renderer', () async {
    final bridge = FixtureBridge()..creating = Completer<dynamic>();
    final factory = LinuxMusicBrowserFactory(
      'generated-only',
      launch: () async => bridge,
    );
    await factory.prepare();
    final page = factory.create(events());
    final opening = page.open(Uri.parse('about:blank'));
    final rejected = expectLater(opening, category('cancelled'));
    await Future<void>.delayed(Duration.zero);
    final closing = page.close();
    bridge.creating!.complete({'audio_isolated': true, 'sandboxed': true});
    await rejected;
    await closing;
    expect(bridge.calls.any((c) => c['method'] == 'close'), isTrue);
    expect(bridge.calls.where((c) => c['method'] == 'navigate'), isEmpty);
  });
  test(
    'late page events cannot reach closed documents or leak request fields',
    () async {
      final bridge = FixtureBridge();
      final factory = LinuxMusicBrowserFactory(
        'generated-only',
        launch: () async => bridge,
      );
      await factory.prepare();
      var requests = 0;
      final first = factory.create(events(request: (_) => requests++));
      final second = factory.create(events());
      await first.open(Uri.parse('about:blank'));
      await second.open(Uri.parse('about:blank'));
      final id = bridge.calls.firstWhere(
        (c) => c['method'] == 'create',
      )['browser'];
      final observed = <BrowserRequest>[];
      await first.observeRequests(observed.add);
      bridge.controller.add({
        'event': 'request',
        'browser': id,
        'uri': 'https://example.invalid/fixture.mp3',
        'kind': 'Media',
        'headers': {'synthetic': 'discard'},
      });
      expect(requests, 1);
      expect(observed.single.kind, 'Media');
      await first.close();
      bridge.controller.add({
        'event': 'request',
        'browser': id,
        'uri': 'https://example.invalid/late.mp3',
      });
      expect(requests, 1);
      await expectLater(first.evaluate('true'), category('cancelled'));
      await second.close();
    },
  );
}
