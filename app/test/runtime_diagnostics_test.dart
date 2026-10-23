import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/services/runtime_diagnostics.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test(
    'transfer diagnostics retain fixed categories and numeric status only',
    () {
      expect(
        audioTransferDiagnostic(
          const ProofFailure('audio_http_failed', code: 403),
        ),
        {
          'stage': 'audio_transfer_failed',
          'category': 'audio_http_failed',
          'code': 403,
        },
      );
      expect(
        audioTransferDiagnostic(StateError('generated private source URL')),
        {'stage': 'audio_transfer_failed', 'category': 'operation_failed'},
      );
    },
  );
  test(
    'runtime diagnostics project fixed types without raw exception details',
    () {
      final report = runtimeDiagnostic(
        PlatformException(
          code: 'SYNTHETIC_SECRET',
          message: 'https://private.test/temporary',
        ),
        StackTrace.fromString('private account 12345 in vk_provider.dart:99'),
      );
      expect(report, {
        'category': 'operation_failed',
        'kind': 'platform',
        'component': 'provider',
      });
      expect(report.toString(), isNot(contains('private')));
      expect(report.toString(), isNot(contains('SYNTHETIC')));
    },
  );
}
