// Plan 10 I2a real check: the "Hear the words" bundles from their real
// addresses, into a test data folder (never the user's), through the app's
// own downloader; then the whisper.cpp libraries loaded from the bundle
// folder alone.
//
// Run from app/:
//   dart run tool/check_stt_bundles.dart --models DIR [--stop-after-mb N]
//       [--verify] [--load-whisper]
//
//  --stop-after-mb N  stops the download after N MB of a bundle (an
//                     interrupt); run again without it to resume.
//  --only NAME        only the bundle NAME (hear-words or whisper-turbo).
//  --verify           reads every file and compares the hashes.
//  --dlls-only DIR    downloads only the whisper.cpp files of the Whisper
//                     bundle into DIR/whisper.cpp (each checked by its
//                     hash) and loads them from there, without the model.
//  --load-whisper     opens ggml-base, ggml and whisper from the bundle's
//                     whisper.cpp folder, loads the CPU backends from there,
//                     and prints the version, the backends and where every
//                     ggml library came from. Run it with PATH cut down to
//                     the Windows folders to prove nothing else is needed.

// ignore_for_file: avoid_print

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:ownsemble/lyrics/fit_model.dart';
import 'package:ownsemble/lyrics/model_bundle.dart';
import 'package:ownsemble/lyrics/stt_models.dart';
import 'package:ownsemble/platform/free_space.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  String? valueOf(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final modelsPath = valueOf('--models');
  if (modelsPath == null) {
    print(
      'usage: --models DIR [--stop-after-mb N] [--verify] '
      '[--load-whisper]',
    );
    exit(2);
  }
  final root = Directory(modelsPath);
  final dllsOnly = valueOf('--dlls-only');
  if (dllsOnly != null) {
    final folder = Directory(p.join(dllsOnly, 'whisper.cpp'));
    for (final file in whisperBundle.files) {
      if (!file.fileName.startsWith('whisper.cpp/')) continue;
      final target = File(p.join(dllsOnly, file.fileName));
      await downloadModel(file, target);
      print('${file.fileName}: ${await modelIntact(target, file)}');
    }
    _loadWhisper(folder.path);
    return;
  }
  final stopAfter = int.tryParse(valueOf('--stop-after-mb') ?? '');
  final only = valueOf('--only');
  final bundles = [
    for (final bundle in [hearWordsBundle, whisperBundle])
      if (only == null || bundle.name == only) bundle,
  ];
  final loadOnly = args.contains('--load-whisper') && !args.contains('--get');

  if (!loadOnly) {
    for (final bundle in bundles) {
      final left = bundleBytesLeft(root, bundle);
      print(
        '${bundle.folderName}: ready ${bundleReady(root, bundle)}, '
        '${bundle.megabytes} MB, left ${(left / 1e6).toStringAsFixed(1)} MB',
      );
      if (bundleReady(root, bundle)) continue;
      final stop = DownloadStop();
      final clock = Stopwatch()..start();
      var shown = 0;
      try {
        await downloadBundle(
          bundle,
          root,
          freeBytes: () => freeBytesAt(root.parent.path),
          workingBytes: sttWorkingBytes,
          stop: stop,
          onProgress: (bytes, total) {
            if (stopAfter != null && bytes >= stopAfter * 1000000) {
              stop.stop();
            }
            if (bytes - shown >= 50000000 || bytes == total) {
              shown = bytes;
              print(
                '  ${(bytes / 1e6).toStringAsFixed(0)} of '
                '${(total / 1e6).toStringAsFixed(0)} MB, '
                '${clock.elapsed.inSeconds} s',
              );
            }
          },
        );
        print(
          '  done in ${clock.elapsed.inSeconds} s, ready '
          '${bundleReady(root, bundle)}',
        );
      } on DownloadStopped {
        print(
          '  stopped at about ${stopAfter ?? 0} MB, ready '
          '${bundleReady(root, bundle)}, left '
          '${(bundleBytesLeft(root, bundle) / 1e6).toStringAsFixed(1)} MB',
        );
        exit(3);
      } on ModelDownloadError catch (error) {
        print('  failed: ${error.message}');
        exit(1);
      }
    }
  }

  if (args.contains('--verify')) {
    for (final bundle in bundles) {
      final clock = Stopwatch()..start();
      final intact = await bundleIntact(root, bundle);
      print(
        '${bundle.folderName}: intact $intact '
        '(${clock.elapsed.inMilliseconds} ms)',
      );
      if (!intact) exit(1);
    }
  }

  if (args.contains('--load-whisper')) {
    if (!bundleReady(root, whisperBundle)) {
      print('whisper bundle not ready');
      exit(1);
    }
    _loadWhisper(
      bundleFile(root, whisperBundle, 'whisper.cpp/whisper.dll').parent.path,
    );
  }
}

typedef _LoadAllC = Void Function(Pointer<Utf8>);
typedef _LoadAll = void Function(Pointer<Utf8>);
typedef _CountC = Size Function();
typedef _Count = int Function();
typedef _GetC = Pointer<Void> Function(Size);
typedef _Get = Pointer<Void> Function(int);
typedef _NameC = Pointer<Utf8> Function(Pointer<Void>);
typedef _TypeC = Int32 Function(Pointer<Void>);
typedef _Type = int Function(Pointer<Void>);
typedef _VersionC = Pointer<Utf8> Function();

void _loadWhisper(String folder) {
  print('PATH: ${Platform.environment['PATH']}');
  // The order whisper.dll needs them in: the loader then finds ggml-base
  // and ggml by name among the modules already loaded.
  final base = DynamicLibrary.open(p.join(folder, 'ggml-base.dll'));
  final ggml = DynamicLibrary.open(p.join(folder, 'ggml.dll'));
  final whisper = DynamicLibrary.open(p.join(folder, 'whisper.dll'));
  final loadAll = ggml.lookupFunction<_LoadAllC, _LoadAll>(
    'ggml_backend_load_all_from_path',
  );
  using((arena) => loadAll(folder.toNativeUtf8(allocator: arena)));
  final version = whisper
      .lookupFunction<_VersionC, _VersionC>('whisper_version')()
      .toDartString();
  print('whisper_version: $version');
  final regCount = ggml.lookupFunction<_CountC, _Count>(
    'ggml_backend_reg_count',
  )();
  final regGet = ggml.lookupFunction<_GetC, _Get>('ggml_backend_reg_get');
  // ggml's functions are split between ggml (the registry) and ggml-base.
  final regName = base.lookupFunction<_NameC, _NameC>('ggml_backend_reg_name');
  for (var i = 0; i < regCount; i++) {
    print('backend $i: ${regName(regGet(i)).toDartString()}');
  }
  DynamicLibrary has(String symbol) =>
      ggml.providesSymbol(symbol) ? ggml : base;
  final devCount = has('ggml_backend_dev_count')
      .lookupFunction<_CountC, _Count>('ggml_backend_dev_count')();
  final devGet = has('ggml_backend_dev_get')
      .lookupFunction<_GetC, _Get>('ggml_backend_dev_get');
  final devDescription = has('ggml_backend_dev_description')
      .lookupFunction<_NameC, _NameC>('ggml_backend_dev_description');
  final devType = has('ggml_backend_dev_type')
      .lookupFunction<_TypeC, _Type>('ggml_backend_dev_type');
  for (var i = 0; i < devCount; i++) {
    final device = devGet(i);
    print(
      'device $i: type ${devType(device)} (0 = CPU), '
      '${devDescription(device).toDartString()}',
    );
  }
  _printModules();
}

/// Every loaded library whose name starts with ggml or whisper, with its
/// path: all must be in the bundle folder.
void _printModules() {
  final psapi = DynamicLibrary.open('psapi.dll');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final enumModules = psapi
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<IntPtr>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<IntPtr>, int, Pointer<Uint32>)
      >('EnumProcessModules');
  final currentProcess = kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final fileName = kernel
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Utf16>, Uint32),
        int Function(int, Pointer<Utf16>, int)
      >('GetModuleFileNameW');
  using((arena) {
    const most = 1024;
    final modules = arena<IntPtr>(most);
    final needed = arena<Uint32>();
    final process = currentProcess();
    if (enumModules(process, modules, most * sizeOf<IntPtr>(), needed) == 0) {
      print('EnumProcessModules failed');
      return;
    }
    final count = needed.value ~/ sizeOf<IntPtr>();
    final name = arena<Uint16>(1024).cast<Utf16>();
    for (var i = 0; i < count && i < most; i++) {
      final length = fileName(modules[i], name, 1024);
      if (length == 0) continue;
      final path = name.toDartString(length: length);
      final file = p.basename(path).toLowerCase();
      if (file.startsWith('ggml') ||
          file.startsWith('whisper') ||
          file.startsWith('msvcp') ||
          file.startsWith('vcruntime')) {
        print('module: $path');
      }
    }
  });
}
