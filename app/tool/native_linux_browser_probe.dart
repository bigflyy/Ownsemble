// ignore_for_file: avoid_relative_lib_imports, avoid_print
// Real native adapter acceptance with generated loopback content only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/contracts/music_browser.dart';
import '../lib/media/audio_policy.dart';
import '../lib/platform/linux/linux_music_browser.dart';
import '../lib/platform/linux/browser_bridge.dart';

Future<void> waitFor(Future<bool> Function() check) async {
  final watch = Stopwatch()..start();
  while (!await check()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      throw const ProofFailure('generated_probe_timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void require(bool value, String category) {
  if (!value) throw ProofFailure(category);
}

Future<void> main(List<String> args) async {
  final checks = <String, bool>{};
  String? failure;
  var assets = 0,
      observed = 0,
      blocked = 0,
      nativeErrors = 0,
      secureRequests = 0;
  final spawned = <Process>[];
  HttpServer? secureServer;
  String? untrustedOrigin;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  final audio = await File.fromUri(
    Platform.script.resolve('../assets/preview.mp3'),
  ).readAsBytes();
  server.listen((request) async {
    final response = request.response;
    switch (request.uri.path) {
      case '/asset':
        assets++;
        response.headers.set('Cache-Control', 'public,max-age=3600');
        response.write('generated-cache-witness');
      case '/tone.mp3':
        response.headers.contentType = ContentType('audio', 'mpeg');
        response.add(audio);
      case '/blocked':
        blocked++;
        response.write('blocked generated destination');
      case '/redirect':
        response.statusCode = 302;
        response.headers.set('Location', '$origin/blocked');
      default:
        response.headers.contentType = ContentType.html;
        response.write(
          '''<!doctype html><title>Ownsemble GENERATED native fixture</title>
<button style="position:absolute;left:20px;top:20px;width:160px;height:80px">Generated play</button>
<audio src="/tone.mp3" loop></audio><script>
window.fixture={start:window.injected===true,click:false,focus:false,playing:false};
document.querySelector('button').onclick=e=>{fixture.click=e.isTrusted;fixture.focus=document.hasFocus();document.querySelector('audio').play().then(()=>fixture.playing=true);};
fetch('/asset').then(r=>r.text()).then(()=>fetch('/asset',{cache:'force-cache'}));
</script>''',
        );
    }
    await response.close();
  });
  // Fresh generated engine-owned session. Never inspect its contents.
  final profile = await Directory.systemTemp.createTemp(
    'ownsemble-generated-native-browser-',
  );
  final factory = LinuxMusicBrowserFactory(
    profile.path,
    executablePath: args.first,
    launch: () async {
      final process = await Process.start(args.first, [
        '--profile-path=${profile.path}',
      ]);
      spawned.add(process);
      return ProcessBrowserBridge(process);
    },
  );
  BrowserEvents events() => BrowserEvents(
    exited: () {},
    errored: () {
      nativeErrors++;
    },
    started: (_) {},
    loaded: (_) {},
    historyChanged: (_) {},
    request: (uri) {
      if (uri?.path == '/asset') observed++;
    },
    allowNavigation: (uri) =>
        uri?.toString() == 'about:blank' ||
        (uri?.origin == origin && uri?.path != '/blocked' ||
            untrustedOrigin != null && uri?.origin == untrustedOrigin),
  );
  final pages = <MusicBrowser>[];
  try {
    await factory.prepare();
    final first = factory.create(events()), second = factory.create(events());
    pages.addAll([first, second]);
    await Future.wait([
      first.open(Uri.parse('about:blank')),
      second.open(Uri.parse('about:blank')),
    ]);
    require(
      await first.isAudioIsolated() && await second.isAudioIsolated(),
      'native_isolation',
    );
    checks['native_isolation_and_sandbox'] = true;
    for (final page in pages) {
      await page.addDocumentStartScript('window.injected=true;');
      await page.navigate(Uri.parse('$origin/page'));
    }
    await waitFor(
      () async => await first.evaluate('window.fixture?.start===true') == true,
    );
    await waitFor(
      () async => await second.evaluate('window.fixture?.start===true') == true,
    );
    checks['document_start_and_independent_documents'] = true;
    await first.activate();
    for (final phase in PointerPhase.values) {
      require(await first.isAudioIsolated(), 'input_isolation_guard');
      await first.pointer(BrowserPointer(phase, 60, 60));
    }
    await waitFor(
      () async =>
          await first.evaluate(
            'fixture.playing&&fixture.click&&fixture.focus&&document.querySelector("audio").currentTime>0',
          ) ==
          true,
    );
    require(
      await second.evaluate('fixture.click===false') == true,
      'independent_input',
    );
    checks['hidden_trusted_focused_media'] = true;
    await first.evaluate(
      '(document.querySelector("button").onclick=()=>window.generatedPopup=window.open("/popup","generated_popup"),true)',
    );
    for (final phase in PointerPhase.values) {
      await first.pointer(BrowserPointer(phase, 60, 60));
    }
    require(
      await first.evaluate('window.generatedPopup===null') == true,
      'hidden_popup_blocked',
    );
    checks['hidden_popup_blocked'] = true;
    await first.showPrivateSignIn();
    require(!await first.isHidden(), 'show_generated_window');
    await first.activate();
    for (final phase in PointerPhase.values) {
      await first.pointer(BrowserPointer(phase, 60, 60));
    }
    await waitFor(
      () async =>
          await first.evaluate(
            '!!window.generatedPopup&&!generatedPopup.closed',
          ) ==
          true,
    );
    await first.finishPrivateSignIn();
    require(
      await first.isHidden() &&
          await first.evaluate('fixture.start&&fixture.click') == true,
      'same_document_after_hide',
    );
    checks['show_hide_preserves_document'] = true;
    require(
      await first.evaluate('generatedPopup.closed') == true,
      'private_popups_closed',
    );
    checks['private_popup_lifecycle'] = true;

    try {
      await first.evaluate('(');
      throw StateError('invalid_expression_accepted');
    } on ProofFailure catch (error) {
      require(error.category == 'music_script_failed', 'script_error_category');
    }
    checks['script_error_sanitized'] = true;
    await first.evaluate(
      '(localStorage.setItem("generated-marker","retained"),true)',
    );
    await first.evaluate('(location.href="$origin/blocked",true)');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await first.navigate(Uri.parse('$origin/redirect'));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    require(blocked == 0, 'navigation_fence');
    checks['navigation_fence_including_redirect'] = true;
    require(assets == 1 && observed >= 4, 'cached_request_observation');
    checks['cached_request_observation'] = true;
    final certificate = await Directory.systemTemp.createTemp(
      'ownsemble-generated-tls-',
    );
    final keyPath = '${certificate.path}/generated-key.pem',
        certPath = '${certificate.path}/generated-cert.pem';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-keyout',
      keyPath,
      '-out',
      certPath,
    ]);
    require(generated.exitCode == 0, 'tls_fixture_generation');
    final context = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    secureServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    untrustedOrigin = 'https://127.0.0.1:${secureServer.port}';
    secureServer.listen((request) async {
      secureRequests++;
      request.response.write('generated-untrusted');
      await request.response.close();
    }, onError: (Object _) {});
    final previousErrors = nativeErrors;
    await second.navigate(Uri.parse('$untrustedOrigin/page'));
    await waitFor(() async => nativeErrors > previousErrors);
    require(secureRequests == 0, 'tls_fail_closed');
    checks['tls_fail_closed'] = true;
    for (final page in pages) {
      await page.close();
    }
    pages.clear();
    require(await spawned.last.exitCode == 0, 'clean_helper_shutdown');
    checks['clean_helper_shutdown'] = true;
    await factory.prepare();
    final restarted = factory.create(events());
    pages.add(restarted);
    await restarted.open(Uri.parse('$origin/page'));
    await waitFor(
      () async =>
          await restarted.evaluate(
            'localStorage.getItem("generated-marker")==="retained"',
          ) ==
          true,
    );
    checks['restart_persistence'] = true;
    final stalled = restarted.evaluate('new Promise(()=>{})');
    final cancelled = stalled.then((_) => false, onError: (Object _) => true);
    await restarted.close();
    require(
      await cancelled.timeout(const Duration(seconds: 2)),
      'cancel_stalled_evaluation',
    );
    checks['cancel_stalled_evaluation'] = true;
  } catch (error) {
    failure = error is ProofFailure ? error.category : 'generated_probe_failed';
  } finally {
    for (final page in pages) {
      try {
        await page.close();
      } catch (_) {}
    }
    await secureServer?.close(force: true);
    await server.close(force: true);
  }
  final report = {
    'passed': failure == null,
    'scope': 'generated_native_linux_browser_only',
    'checks': checks,
    'asset_network_requests': assets,
    'asset_observations': observed,
    'blocked_requests': blocked,
    'error_category': failure,
  };
  if (args.length > 1) {
    await File(args[1]).writeAsString('${jsonEncode(report)}\n');
  }
  print(jsonEncode(report));
  if (failure != null) exitCode = 1;
}
