import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/audio_policy.dart';
import 'package:ownsemble/services/build_restart.dart';

void main() {
  test(
    'restart chooses the newest Dart payload despite older runner timestamps',
    () async {
      final root = await Directory.systemTemp.createTemp('ownsemble-restart-');
      try {
        final executables = <String, File>{};
        final payloads = <String, File>{};
        for (final mode in ['Debug', 'Release']) {
          final base = '${root.path}/app/build/windows/x64/runner/$mode';
          final executable = File('$base/ownsemble.exe');
          await executable.create(recursive: true);
          final payload = File(
            mode == 'Debug'
                ? '$base/data/flutter_assets/kernel_blob.bin'
                : '$base/data/app.so',
          );
          await payload.create(recursive: true);
          executables[mode] = executable;
          payloads[mode] = payload;
        }
        final newer = DateTime.utc(2026, 1, 2);
        final older = DateTime.utc(2026, 1, 1);
        for (final mode in ['Debug', 'Release']) {
          final other = mode == 'Debug' ? 'Release' : 'Debug';
          await payloads[mode]!.setLastModified(newer);
          await payloads[other]!.setLastModified(older);
          await executables[mode]!.setLastModified(older);
          await executables[other]!.setLastModified(newer);
          expect(
            selectAppRestartExecutable(root.path),
            executables[mode]!.absolute.path,
          );
        }
        await payloads['Release']!.delete();
        expect(
          selectAppRestartExecutable(root.path),
          executables['Debug']!.absolute.path,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('restart rejects missing app payloads', () async {
    final root = await Directory.systemTemp.createTemp('ownsemble-restart-');
    try {
      expect(
        () => selectAppRestartExecutable(root.path),
        throwsA(isA<ProofFailure>()),
      );
    } finally {
      await root.delete();
    }
  });
}
