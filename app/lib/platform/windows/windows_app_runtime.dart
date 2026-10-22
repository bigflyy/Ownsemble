import 'dart:io';

import '../../contracts/app_runtime.dart';
import 'restart_executable.dart';

class WindowsAppRuntime implements AppRuntime {
  final String repositoryRoot;
  const WindowsAppRuntime(this.repositoryRoot);
  @override
  Future<void> restartAfter(Future<void> Function() shutdown) async {
    final exe = selectAppRestartExecutable(repositoryRoot);
    await shutdown();
    await Process.start(
      exe,
      ['--restart-parent=$pid'],
      workingDirectory: repositoryRoot,
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
