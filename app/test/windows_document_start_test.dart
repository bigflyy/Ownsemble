import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/platform/windows/document_start_script.dart';

/// Check that navigation cannot overtake document-start script registration.
void main() {
  test('registration waits for the native acknowledgement', () async {
    // Hold the generated native reply until its registration finishes.
    final acknowledgement = Completer<dynamic>();
    // Record whether the caller is already allowed to navigate.
    var finished = false;
    // Start registration without completing its native acknowledgement.
    final registration = registerWindowsDocumentStartScript(
      'window.generatedStart=true;',
      callProtocol: (method, parameters) {
        expect(method, 'Page.addScriptToEvaluateOnNewDocument');
        expect(parameters, {'source': 'window.generatedStart=true;'});
        return acknowledgement.future;
      },
    ).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    acknowledgement.complete({'identifier': 'generated-registration'});
    await registration;
    expect(finished, isTrue);
  });

  test('registration accepts the native JSON reply', () async {
    await registerWindowsDocumentStartScript(
      'window.generatedStart=true;',
      callProtocol: (_, _) async => '{"identifier":"generated-registration"}',
    );
  });

  test('missing or malformed native acknowledgements fail closed', () async {
    // Exercise controlled failures without storing any script or page content.
    for (final reply in [
      null,
      {},
      {'identifier': ''},
      [],
      'invalid-json',
    ]) {
      await expectLater(
        registerWindowsDocumentStartScript(
          'window.generatedStart=true;',
          callProtocol: (_, _) async => reply,
        ),
        throwsA(
          isA<ProofFailure>().having(
            (error) => error.category,
            'category',
            'browser_document_start_failed',
          ),
        ),
      );
    }
  });
}
