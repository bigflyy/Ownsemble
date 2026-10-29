import 'dart:io';

import 'proof_core.dart';

// Only this checkout's two known application outputs can be selected. The
// public control command supplies no executable, arguments, URL or profile path.
String selectProofRestartExecutable(String repositoryRoot) {
  final candidates = <(String, DateTime)>[];
  for (final mode in ['Debug', 'Release']) {
    final base =
        '$repositoryRoot/spikes/vk-flutter/build/windows/x64/runner/$mode';
    final executable = File('$base/ownsemble_flutter_proof.exe');
    final payload = File(
      mode == 'Debug'
          ? '$base/data/flutter_assets/kernel_blob.bin'
          : '$base/data/app.so',
    );
    if (executable.existsSync() && payload.existsSync()) {
      candidates.add((executable.absolute.path, payload.lastModifiedSync()));
    }
  }
  if (candidates.isEmpty) throw const ProofFailure('restart_build_missing');
  candidates.sort((a, b) => b.$2.compareTo(a.$2));
  return candidates.first.$1;
}
