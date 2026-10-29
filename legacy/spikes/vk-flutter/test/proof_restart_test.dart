import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble_flutter_proof/proof_core.dart';
import 'package:ownsemble_flutter_proof/proof_restart.dart';

void main() {
  test(
    'restart chooses the newest Dart payload despite older runner timestamps',
    () async {
      final root = await Directory.systemTemp.createTemp('ownsemble-restart-');
      try {
        final executables = <String, File>{};
        final payloads = <String, File>{};
        for (final mode in ['Debug', 'Release']) {
          final base =
              '${root.path}/spikes/vk-flutter/build/windows/x64/runner/$mode';
          final executable = File('$base/ownsemble_flutter_proof.exe');
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
            selectProofRestartExecutable(root.path),
            executables[mode]!.absolute.path,
          );
        }
        await payloads['Release']!.delete();
        expect(
          selectProofRestartExecutable(root.path),
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
        () => selectProofRestartExecutable(root.path),
        throwsA(isA<ProofFailure>()),
      );
    } finally {
      await root.delete();
    }
  });
}
