import 'dart:io';

import '../../media/audio_policy.dart';

// Only this checkout's two known application outputs can be selected. The
// public control command supplies no executable, arguments, URL or profile path.
String selectAppRestartExecutable(String repositoryRoot) {
  final candidates = <(String, DateTime)>[];
  for (final mode in ['Debug', 'Release']) {
    final base = '$repositoryRoot/app/build/windows/x64/runner/$mode';
    final executable = File('$base/ownsemble.exe');
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
