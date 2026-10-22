import 'dart:io';

import 'package:flutter/services.dart';

import '../contracts/app_runtime.dart';
import '../contracts/music_browser.dart';
import '../data/library_store.dart';
import '../platform/media_kit_audio.dart';
import '../platform/media_kit_playback.dart';
import '../platform/windows/windows_app_runtime.dart';
import '../platform/windows/windows_music_browser.dart';
import '../platform/windows/windows_certificate.dart';
import '../contracts/certificate_verifier.dart';
import '../provider/vk_provider.dart';
import '../services/app_controller.dart';

/// Composition root: shared services never select plugins or inspect the OS.
AppController createApplication(
  LibraryStore store, {
  required String profilePath,
  bool demo = false,
  String? repositoryRoot,
}) {
  late final AppController controller;
  final browserFactory = Platform.isWindows
      ? WindowsMusicBrowserFactory(profilePath)
      : const UnsupportedMusicBrowserFactory();
  final provider = VkProvider(
    browserFactory: browserFactory,
    loadAdapter: () => rootBundle.loadString('assets/vk_adapter.js'),
    status: (text) => controller.providerStatus(text),
    changed: () => controller.providerChanged(),
    diagnostic: (report) => controller.providerDiagnostic(report),
  );
  controller = AppController(
    store,
    demo: demo,
    enableLocalControls: repositoryRoot != null,
    musicProvider: provider,
    playbackPlayer: MediaKitPlayback(newProofPlayer()),
    decodeAudio: decodeLocalAudio,
    certificateVerifierFactory: Platform.isWindows
        ? WindowsCertificateVerifier.new
        : strictCertificateVerifier,
    runtime: Platform.isWindows && repositoryRoot != null
        ? WindowsAppRuntime(repositoryRoot)
        : const UnsupportedAppRuntime(),
  );
  return controller;
}
