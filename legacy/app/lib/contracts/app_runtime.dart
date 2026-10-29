import '../media/audio_policy.dart';

/// Checkout restart is optional; ordinary application state never selects an exe.
abstract interface class AppRuntime {
  Future<void> restartAfter(Future<void> Function() shutdown);
}

class UnsupportedAppRuntime implements AppRuntime {
  const UnsupportedAppRuntime();
  @override
  Future<void> restartAfter(Future<void> Function() shutdown) async {
    throw const ProofFailure('restart_platform_unavailable');
  }
}
