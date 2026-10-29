import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/services/runtime_diagnostics.dart';
import 'package:ownsemble/media/audio_policy.dart';

void main() {
  test('global error forwarding emits only safe diagnostics and tolerates a failed sink', () {
    // Collect one generated global error without launching Flutter/native services.
    final reports = <Map<String, Object>>[];
    recordRuntimeFailure(
      StateError('Private exception message'),
      StackTrace.fromString('private path in vk_provider.dart:10'),
      reporter: reports.add,
    );
    expect(reports.single, {
      'stage': 'operation_failed',
      'category': 'operation_failed',
      'kind': 'state',
      'component': 'provider',
    });
    // A broken optional reporter must not replace the original application failure.
    expect(
      () => recordRuntimeFailure(
        StateError('Private exception'),
        null,
        reporter: (_) => throw StateError('Generated broken sink'),
      ),
      returnsNormally,
    );
  });

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
