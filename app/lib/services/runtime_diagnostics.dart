import 'dart:io';

import 'package:flutter/services.dart';

import '../media/audio_policy.dart';

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
