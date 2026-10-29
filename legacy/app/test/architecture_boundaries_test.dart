import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Executable dependency rules: a new OS/provider must not change shared policy.
void main() {
  final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''');
  List<String> dependencies(String file) => imports
      .allMatches(File(file).readAsStringSync())
      .map((match) => match.group(1)!)
      .toList();
  test(
    'VK policy has no plugin, OS, browser-engine or asset-loader dependency',
    () {
      final violations = dependencies('lib/provider/vk_provider.dart').where(
        (p) =>
            p.startsWith('package:flutter') ||
            p == 'dart:io' ||
            p.contains('native_browser') ||
            p.contains('background_browser') ||
            p.contains('/platform/'),
      );
      expect(
        violations,
        isEmpty,
        reason: 'VK policy must use the browser contract, not Windows APIs.',
      );
    },
  );
  test(
    'application orchestration has no concrete provider or media plugin',
    () {
      final violations = dependencies('lib/services/app_controller.dart').where(
        (p) =>
            p.contains('media_kit') ||
            p.contains('vk_provider') ||
            p.contains('local_audio') ||
            p.contains('build_restart') ||
            p.contains('/platform/'),
      );
      expect(
        violations,
        isEmpty,
        reason: 'Only the composition root chooses platform implementations.',
      );
    },
  );
  test('UI has no concrete platform or provider implementation dependency', () {
    final violations = <String>[];
    for (final file in Directory('lib/ui').listSync().whereType<File>()) {
      for (final dep in dependencies(file.path)) {
        if (dep.contains('media_kit') ||
            dep.contains('flutter_inappwebview') ||
            dep.contains('vk_provider') ||
            dep.contains('/platform/')) {
          violations.add('${file.path}: $dep');
        }
      }
    }
    expect(violations, isEmpty);
  });
  test('cache implementations do not choose a Windows TLS fallback', () {
    final violations = <String>[];
    for (final file in [
      'lib/media/audio_cache.dart',
      'lib/media/artwork_cache.dart',
    ]) {
      violations.addAll(
        dependencies(file).where(
          (p) => p.contains('windows_certificate') || p.contains('/platform/'),
        ),
      );
    }
    expect(
      violations,
      isEmpty,
      reason: 'Platform trust is injected, default trust stays strict.',
    );
  });
  test(
    'shared VK policy is transitively usable without Flutter or native IO',
    () {
      final pending = [File('lib/provider/vk_provider.dart').absolute];
      final seen = <String>{}, violations = <String>[];
      while (pending.isNotEmpty) {
        final file = pending.removeLast();
        if (!seen.add(file.path)) continue;
        for (final dep in dependencies(file.path)) {
          if (dep.startsWith('package:') ||
              dep == 'dart:io' ||
              dep == 'dart:ui' ||
              dep == 'dart:ffi') {
            violations.add('${file.path}: $dep');
          } else if (!dep.startsWith('dart:')) {
            pending.add(File.fromUri(file.uri.resolve(dep)));
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'A platform-free surface must not hide concrete dependencies one import away.',
      );
    },
  );
}
