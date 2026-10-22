import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/platform/linux/browser_bridge.dart';

class FixtureProcess implements Process {
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final ended = Completer<int>();
  final received = <Map<String, dynamic>>[];
  bool killed = false;
  FixtureProcess() {
    input.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        received.add(message);
        if (message['method'] == 'shutdown') {
          respond({'id': message['id'], 'ok': true});
          finish();
        }
      },
    );
  }
  void respond(Map<String, dynamic> value) =>
      output.add(utf8.encode('${jsonEncode(value)}\n'));
  void finish() {
    if (!ended.isCompleted) {
      ended.complete(0);
      output.close();
      errors.close();
    }
  }

  @override
  late final IOSink stdin = IOSink(input.sink);
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => ended.future;
  @override
  int get pid => 123456;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish();
    return true;
  }
}

void main() {
  test(
    'malformed native event types terminate helper without reaching UI',
    () async {
      final process = FixtureProcess();
      final bridge = ProcessBrowserBridge(process);
      final events = <Map<String, dynamic>>[];
      bridge.events.listen(events.add);
      process.respond({
        'event': 'loaded',
        'browser': 'wrong-type',
        'uri': {'generated': true},
      });
      await Future<void>.delayed(Duration.zero);
      expect(process.killed, isTrue);
      expect(events, [
        {'event': 'bridge_closed'},
      ]);
      await bridge.close();
    },
  );

  test(
    'unknown native events fail closed and request fields are projected',
    () async {
      final process = FixtureProcess();
      final bridge = ProcessBrowserBridge(process);
      final events = <Map<String, dynamic>>[];
      bridge.events.listen(events.add);
      process.respond({
        'event': 'request',
        'browser': 1,
        'uri': 'https://example.invalid/generated',
        'kind': 'Media',
        'headers': {'generated': 'drop'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.single, {
        'event': 'request',
        'browser': 1,
        'uri': 'https://example.invalid/generated',
        'kind': 'Media',
      });
      process.respond({'event': 'unknown', 'body': 'generated-only'});
      await Future<void>.delayed(Duration.zero);
      expect(process.killed, isTrue);
      expect(events.last['event'], 'bridge_closed');
      await bridge.close();
    },
  );

  test(
    'native response IDs correlate even when results arrive out of order',
    () async {
      final process = FixtureProcess();
      final bridge = ProcessBrowserBridge(process);
      final first = bridge.request('first', {'fixture': true});
      final second = bridge.request('second', {});
      await Future<void>.delayed(Duration.zero);
      expect(process.received.map((r) => r['id']), [1, 2]);
      process.respond({'id': 2, 'ok': true, 'value': 'second'});
      process.respond({'id': 1, 'ok': true, 'value': 'first'});
      expect(await first, 'first');
      expect(await second, 'second');
      await bridge.close();
    },
  );
  test(
    'invalid native framing cancels pending work and terminates only helper',
    () async {
      final process = FixtureProcess();
      final bridge = ProcessBrowserBridge(process);
      final request = bridge.request('evaluate', {});
      final failure = expectLater(
        request,
        throwsA(
          isA<ProofFailure>().having(
            (e) => e.category,
            'category',
            'browser_closed',
          ),
        ),
      );
      process.output.add(utf8.encode('invalid-json\n'));
      await failure;
      expect(process.killed, isTrue);
      await bridge.close();
    },
  );
  test(
    'native error text never becomes an application diagnostic category',
    () async {
      final process = FixtureProcess();
      final bridge = ProcessBrowserBridge(process);
      final request = bridge.request('evaluate', {});
      final failure = expectLater(
        request,
        throwsA(
          isA<ProofFailure>().having(
            (e) => e.category,
            'category',
            'browser_native_failed',
          ),
        ),
      );
      process.respond({
        'id': 1,
        'ok': false,
        'error': 'generated raw error that must not escape',
      });
      await failure;
      await bridge.close();
    },
  );
}
