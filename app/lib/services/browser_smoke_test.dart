import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../data/library_store.dart';
import '../media/audio_policy.dart';
import '../media/local_audio.dart';
import '../contracts/music_browser.dart';
import '../provider/guarded_input.dart';
import 'runtime_diagnostics.dart';

/// Only a generated loopback page, an isolated empty profile, and numeric
/// outcomes. This never opens VK, authenticates, or reads a browser profile.
Future<void> runBackgroundBrowserSmoke(
  LibraryStore store, {
  bool visible = false,
  required MusicBrowserFactory browserFactory,
}) async {
  final result = <String, Object>{
    'visible_control': visible,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  final reportName = visible
      ? 'browser-smoke-visible.json'
      : 'browser-smoke.json';
  var stage = 'start';
  void checkpoint(String value) {
    stage = value;
    store.report('hidden_browser_$value');
  }

  checkpoint('start');
  MusicBrowser? browser, scanner;
  HttpServer? server;
  try {
    final tone = (await rootBundle.load('assets/preview.mp3')).buffer
        .asUint8List();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    var requests = 0;
    result['started'] = 0;
    result['loaded'] = 0;
    result['intercepted'] = 0;
    result['errors'] = 0;
    final page =
        """<!doctype html><html><body style="margin:0">
      <button id="play" style="position:absolute;left:30px;top:30px;width:180px;height:80px">Generated tone</button>
      <script>window.generatedFixture=true;window.trustedCount=0;
      document.getElementById('play').onmousedown=e=>window.pointerArmed=e.isTrusted && e.buttons===1;
      document.getElementById('play').onclick=e=>{
        if(e.isTrusted)window.trustedCount++;
        if(!window.pointerArmed || !document.hasFocus() || document.visibilityState!=='visible')return;
        window.pointerArmed=false;
        const audio=new Audio('http://127.0.0.1:$port/tone.mp3');window.fixtureAudio=audio;audio.play().catch(()=>{});
      };</script></body></html>""";
    server.listen((request) async {
      requests++;
      result['server_requests'] = requests;
      if (request.uri.path == '/tone.mp3') {
        result['server_audio_requests'] =
            (result['server_audio_requests'] as int? ?? 0) + 1;
      }
      if (request.uri.path == '/fixture') {
        request.response.headers.contentType = ContentType.html;
        request.response.contentLength = utf8.encode(page).length;
        request.response.write(page);
        await request.response.close();
        result['html_sent'] = true;
        return;
      }
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = tone.length;
      if (request.uri.path == '/tone.mp3') {
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'public, max-age=3600',
        );
      }
      request.response.add(tone);
      await request.response.close();
    });
    final loaded = Completer<void>();
    var observed = 0, cdpObserved = 0;
    checkpoint('environment');
    requireMusicBrowserCapabilities(browserFactory);
    await browserFactory.prepare().timeout(const Duration(seconds: 30));
    checkpoint('playback_page');
    browser = browserFactory.create(
      BrowserEvents(
        exited: () {},
        started: (_) {
          result['started'] = (result['started'] as int) + 1;
        },
        loaded: (url) {
          result['loaded'] = (result['loaded'] as int) + 1;
          if (url?.host == '127.0.0.1' &&
              url?.path == '/fixture' &&
              !loaded.isCompleted) {
            loaded.complete();
          }
        },
        historyChanged: (_) {},
        errored: () {
          result['errors'] = (result['errors'] as int) + 1;
        },
        request: (uri) {
          result['intercepted'] = (result['intercepted'] as int) + 1;
          if (uri?.host == '127.0.0.1' &&
              uri?.port == port &&
              uri?.path == '/tone.mp3') {
            observed++;
          }
        },
        allowNavigation: (_) => true,
      ),
    );
    await browser
        .open(Uri.parse('about:blank'))
        .timeout(const Duration(seconds: 30));
    result['native_muted'] = await browser.isAudioIsolated();
    await browser.addDocumentStartScript('window.generatedStart=true;');
    await browser.navigate(Uri.parse('http://127.0.0.1:$port/fixture'));
    await loaded.future.timeout(const Duration(seconds: 30));
    result['document_start_script'] = await browser.evaluate(
      'window.generatedStart===true',
    );
    checkpoint('scanner_page');
    final scanLoaded = Completer<void>();
    scanner = browserFactory.create(
      BrowserEvents(
        exited: () {},
        loaded: (url) {
          if (url?.host == '127.0.0.1' &&
              url?.path == '/fixture' &&
              !scanLoaded.isCompleted) {
            scanLoaded.complete();
          }
        },
        started: (_) {},
        historyChanged: (_) {},
        errored: () {},
        request: (_) {},
        allowNavigation: (_) => true,
      ),
    );
    await scanner
        .open(Uri.parse('http://127.0.0.1:$port/fixture'))
        .timeout(const Duration(seconds: 30));
    await scanLoaded.future.timeout(const Duration(seconds: 30));
    final scanWork = scanner.evaluate("""(async()=>{
      window.scanTicks=0;const timer=setInterval(()=>window.scanTicks++,100);
      return await new Promise(resolve=>setTimeout(()=>{clearInterval(timer);resolve(window.scanTicks);},2500));
    })()""");
    result['hidden_before'] = await browser.isHidden();
    await browser.activate();
    result['focused_document'] = await browser.evaluate(
      "document.hasFocus() && document.visibilityState === 'visible'",
    );
    await browser.observeRequests((request) {
      final uri = request.uri;
      if (uri?.host == '127.0.0.1' &&
          uri?.port == port &&
          uri?.path == '/tone.mp3') {
        cdpObserved++;
        result['cdp_audio_requests'] = cdpObserved;
      }
    });
    checkpoint('playback_bounds');
    final point = Map<String, dynamic>.from(
      await browser.evaluate(
        '(()=>{const r=document.getElementById("play").getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()',
      ),
    );
    checkpoint('playback_input');
    Future<void> tapFixture() => dispatchGuardedTap(
      x: (point['x'] as num).toDouble(),
      y: (point['y'] as num).toDouble(),
      guard: () async {
        if (await browser!.evaluate('window.generatedFixture===true') != true) {
          throw const ProofFailure('fixture_route_changed');
        }
      },
      dispatch: (event) => browser!.pointer(event),
    );
    await tapFixture();
    checkpoint('playback_resource');
    await waitUntil(
      () => observed > 0 && requests > 0,
      'hidden_browser_resource_timeout',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tapFixture();
    final cachedFetch = await browser.evaluate("""(async()=>{
      const sizes=[];
      for(let i=0;i<2;i++) {
        const response=await fetch('http://127.0.0.1:$port/tone.mp3',{cache:'force-cache'});
        sizes.push((await response.arrayBuffer()).byteLength);
      }
      return sizes;
    })()""");
    result['cached_fetch_valid'] =
        cachedFetch is List && cachedFetch.every((size) => size == tone.length);
    await waitUntil(
      () => cdpObserved >= 4 && result['server_audio_requests'] == 1,
      'browser_cache_witness_timeout',
    );
    result['cdp_audio_requests'] = cdpObserved;
    result['cached_audio_requests_observed'] =
        cdpObserved >= 4 && result['server_audio_requests'] == 1;
    final trusted = await browser.evaluate('window.trustedCount');
    result['detached_dom_unmuted'] = await browser.evaluate(
      '!!window.fixtureAudio && !document.contains(window.fixtureAudio) && !window.fixtureAudio.muted',
    );
    final scanOutcome = await scanWork;
    final otherDocument = await scanner.evaluate('window.trustedCount');
    result['scan_progress'] = (scanOutcome as num?)?.toInt() ?? 0;
    result['scan_document_independent'] = otherDocument == 0;
    result['scanner_hidden'] = await scanner.isHidden();
    result.addAll({
      'hidden_after': await browser.isHidden(),
      'trusted': trusted == 2,
      'requests': requests,
      'observed': observed,
    });
    result['passed'] =
        result['hidden_before'] == !visible &&
        result['hidden_after'] == !visible &&
        result['trusted'] == true &&
        result['focused_document'] == true &&
        result['cached_fetch_valid'] == true &&
        result['native_muted'] == true &&
        result['document_start_script'] == true &&
        result['detached_dom_unmuted'] == true &&
        result['scanner_hidden'] == !visible &&
        result['scan_document_independent'] == true &&
        (result['scan_progress'] as int) > 0;
  } catch (e, stack) {
    result.addAll({
      ...runtimeDiagnostic(e, stack),
      'passed': false,
      'category': e is TimeoutException ? 'fixture_timeout' : categoryOf(e),
      'stage': stage,
    });
  } finally {
    await File('${store.directory.path}/$reportName')
        .writeAsString(jsonEncode(result));
    await scanner?.close().timeout(const Duration(seconds: 5));
    await browser?.close().timeout(const Duration(seconds: 5));
    await server?.close(force: true);
  }
  await File('${store.directory.path}/$reportName')
      .writeAsString(jsonEncode(result));
  store.report(
    result['passed'] == true
        ? 'hidden_browser_passed'
        : 'hidden_browser_failed',
  );
}
