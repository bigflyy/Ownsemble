import 'dart:io';

import 'package:flutter/services.dart';

import '../media/audio_policy.dart';

/// Forward unexpected failures through the same safe journal without leaking raw details.
void recordRuntimeFailure(
  Object error,
  StackTrace? stack, {
  void Function(Map<String, Object>)? reporter,
}) {
  try {
    reporter?.call({
      'stage': 'operation_failed',
      ...runtimeDiagnostic(error, stack),
    });
  } catch (_) {
    /* Optional diagnostic failures cannot replace the application error. */
  }
}

/// Preserve only the original transfer category and numeric error code.
Map<String, Object> audioTransferDiagnostic(Object error) => {
  'stage': 'audio_transfer_failed',
  'category': categoryOf(error),
  // Include a typed code without copying native messages or temporary URLs.
  if (error is ProofFailure && error.code != null) 'code': error.code!,
  // Export fixed destination flags only when the allowlist rejects a fetch.
  if (error is AudioDestinationFailure) 'destination': error.diagnostic,
};

// Never export exception messages, stack traces, filenames, IDs or URLs.
Map<String, Object> runtimeDiagnostic(Object error, StackTrace? stack) {
  final text = stack?.toString() ?? '';
  return {
    'category': categoryOf(error),
    'kind': switch (error) {
      TypeError() => 'type',
      StateError() => 'state',
      PlatformException() => 'platform',
      FileSystemException() => 'filesystem',
      _ => 'other',
    },
    'component': text.contains('app_controller.dart')
        ? 'controller'
        : text.contains('vk_provider.dart')
        ? 'provider'
        : text.contains('ownsemble_app.dart')
        ? 'ui'
        : text.contains('library_store.dart')
        ? 'database'
        : 'other',
  };
}
