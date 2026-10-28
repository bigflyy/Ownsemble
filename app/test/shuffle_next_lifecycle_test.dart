import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/contracts/music_browser.dart';
import 'package:ownsemble/data/library_store.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/provider/vk_provider.dart';
import 'package:ownsemble/services/app_controller.dart';
import 'package:ownsemble/services/diagnostic_store.dart';

import 'rejected_source_recovery_test.dart'
    show FixtureHttpOverrides, SilentRelayPlayback, deleteGeneratedFolder;
import 'legacy_cache_streaming_test.dart' show GeneratedAudioClient;

class SequentialBrowserFactory implements MusicBrowserFactory {
  @override
  final capabilities = Set<BrowserCapability>.of(BrowserCapability.values);
  @override
  bool prepared = false;
  final pages = <SequentialBrowser>[];
  @override
  Future<void> prepare() async {
    prepared = true;
  }

  @override
  MusicBrowser create(BrowserEvents events) {
    final page = SequentialBrowser(events);
    pages.add(page);
    return page;
  }
}

class SequentialBrowser implements MusicBrowser {
  final BrowserEvents events;
  Uri? uri;
  bool adapterPresent = false;
  int installs = 0;
  SequentialBrowser(this.events);
  void visit(Uri target) {
    adapterPresent = false;
    uri = target;
    events.started(target);
    events.loaded(target);
  }

  @override
  Future<void> open(Uri uri) async {
    visit(uri);
  }

  @override
  Future<void> navigate(Uri uri) async {
    visit(uri);
  }

  @override
  Future<void> reload() async {
    visit(uri!);
  }

  @override
  Future<Uri?> currentUrl() async => uri;
  @override
  Future<bool> isAudioIsolated() async => true;
  @override
  Future<void> addDocumentStartScript(String source) async {}
  @override
  Future<void> activate() async {}
  @override
  Future<void> pointer(BrowserPointer event) async {}
  @override
  Future<void> observeRequests(void Function(BrowserRequest) observed) async {}
  @override
  Future<void> showPrivateSignIn() async {}
  @override
  Future<void> finishPrivateSignIn() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<bool> isHidden() async => true;
  @override
  Future<void> close() async {
    events.exited();
  }

  @override
  Future<dynamic> evaluate(String expression) async {
    if (expression.contains('generated-adapter-install-marker')) {
      adapterPresent = true;
      installs++;
      return true;
    }
    if (expression.contains('window.ownsembleMusic.') && !adapterPresent) {
      throw const ProofFailure('music_script_failed');
    }
    if (expression.contains('"verify-my-music"') ||
        expression.contains('"open-my-music"')) {
      return jsonEncode({'personal': true});
    }
    if (expression.contains('"readiness"')) {
      return jsonEncode({'count': 2, 'loading': false});
    }
    if (expression.contains('window.ownsembleMusic.read(')) {
      final id = RegExp(r'"targetId":"(17_263[01])"')
          .firstMatch(expression)
          ?.group(1);
      return jsonEncode({
        'userId': 17,
        'userAgent': 'Generated',
        'tracks': [
          if (id != null)
            {
              'id': id,
              'title': 'Generated',
              'artist': 'Fixture',
              'duration': 10,
              'url': 'https://generated.vkuseraudio.net/$id.mp3',
            },
        ],
      });
    }
    return jsonEncode(<String, Object>{});
  }
}

void main() {
  test('real shuffled Next starts once after adapter loss while prior audio is downloading', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ownsemble-shuffle-next-',
    );
    final tail = Completer<void>();
    final firstPrefix = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((request) async {
      try {
        requests.add(request.uri.path);
        request.response.bufferOutput = false;
        request.response.contentLength = 8;
        request.response.add([1, 2, 3, 4]);
        await request.response.flush();
        if (request.uri.path == '/17_2630.mp3') {
          if (!firstPrefix.isCompleted) firstPrefix.complete();
          await tail.future;
        }
        request.response.add([5, 6, 7, 8]);
        await request.response.close();
      } catch (_) {
        /* The previous transfer is deliberately cancelled by Next. */
      }
    });
    final baseHttp = HttpOverrides.current ?? FixtureHttpOverrides();
    final clients = <HttpClient>[];
    final factory = SequentialBrowserFactory();
    final provider = VkProvider(
      browserFactory: factory,
      loadAdapter: () async => 'generated-adapter-install-marker',
      status: (_) {},
      changed: () {},
    );
    final store = LibraryStore(folder)
      ..merge([
        const Track('17_2630', 'Generated first', 'Fixture', 10),
        const Track('17_2631', 'Generated old recording', 'Fixture', 10),
      ])
      ..setSetting('auto_sync', false);
    final player = SilentRelayPlayback();
    try {
      await HttpOverrides.runZoned(
        () async {
          await provider.connect();
          final controller = AppController(
            store,
            playbackPlayer: player,
            musicProvider: provider,
            decodeAudio: (_) async => 10,
            diagnosticStore: DiagnosticStore.memory(),
          );
          try {
            controller.queue.setShuffle(true);
            await controller
                .playRows(store.rows(), 0)
                .timeout(const Duration(seconds: 3));
            await firstPrefix.future;
            expect(store.asset('17_2630'), isNull);
            final main = factory.pages.first;
            main.adapterPresent = false;
            await controller.next().timeout(const Duration(seconds: 3));
            expect(controller.current!.id, '17_2631');
            expect(player.state.playing, isTrue);
            expect(controller.loading, isFalse);
            expect(store.rows().last.error, isNull);
            expect(main.installs, 2);
            expect(requests, ['/17_2630.mp3', '/17_2631.mp3']);
            expect(
              store.db.select('SELECT COUNT(*) AS n FROM plays').first['n'],
              2,
            );
            tail.complete();
            await Future<void>.delayed(const Duration(milliseconds: 30));
            expect(controller.current!.id, '17_2631');
            expect(store.asset('17_2630'), isNull);
          } finally {
            if (!tail.isCompleted) tail.complete();
            await controller.shutdown();
          }
        },
        createHttpClient: (context) {
          final client = baseHttp.createHttpClient(context)
            ..findProxy = (_) => 'DIRECT';
          clients.add(client);
          return GeneratedAudioClient(client, server.port);
        },
      );
    } finally {
      if (!tail.isCompleted) tail.complete();
      for (final client in clients) {
        client.close(force: true);
      }
      await server.close(force: true);
      await deleteGeneratedFolder(folder);
    }
  });
}
