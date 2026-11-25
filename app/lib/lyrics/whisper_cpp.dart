// whisper.cpp 1.9.5 through Ownsemble's bridge library (plan 10 I2d):
// native/whisper_bridge, built beside ownsemble.exe as ownsemble_whisper.dll.
//
// The bridge is compiled against whisper.cpp's pinned header, so it owns
// the parameter structs whisper.cpp passes by value and the abort callback
// that stops a call midway (Dart cannot answer a native callback during a
// synchronous call). It opens the whisper.cpp libraries of the downloaded
// bundle at run time; this file sees only plain functions.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The bridge's OW_BRIDGE_VERSION this binding is written for.
const _bridgeVersion = 2;

// ow_transcribe's results (whisper_bridge.h).
const _ok = 0;
const _cancelled = 1;

/// Token times (whisper_token_data.t0, t1) count in 10 ms steps.
const whisperTimeStep = 0.01;

/// Whisper's window: a chunk is at most this long.
const whisperMaxSeconds = 30.0;

/// A failure of the bridge or of whisper.cpp, with its details.
class WhisperError implements Exception {
  const WhisperError(this.message);
  final String message;

  @override
  String toString() => 'WhisperError: $message';
}

/// [WhisperModel.transcribe] stopped because its cancel flag was set.
class WhisperCancelled implements Exception {
  const WhisperCancelled();

  @override
  String toString() => 'WhisperCancelled';
}

/// One text token of a result: raw UTF-8 [bytes] (a token may hold part of
/// a character), its times in seconds from the chunk's start, and its
/// probability.
typedef WhisperToken = ({
  Uint8List bytes,
  double start,
  double end,
  double probability,
});

/// The bridge's file name on this system.
String get whisperBridgeName =>
    Platform.isWindows ? 'ownsemble_whisper.dll' : 'libownsemble_whisper.so';

/// The bridge beside the app's executable.
String get appWhisperBridgePath =>
    p.join(p.dirname(Platform.resolvedExecutable), whisperBridgeName);

typedef _IntVoidC = Int32 Function();
typedef _IntVoid = int Function();
typedef _StringVoidC = Pointer<Utf8> Function();
typedef _StringVoid = Pointer<Utf8> Function();
typedef _IntStringC = Int32 Function(Pointer<Utf8>);
typedef _IntString = int Function(Pointer<Utf8>);
typedef _StringIntC = Pointer<Utf8> Function(Int32);
typedef _StringInt = Pointer<Utf8> Function(int);
typedef _OpenOnC = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _OpenOn = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _Close = void Function(Pointer<Void>);
typedef _TranscribeC = Int32 Function(
  Pointer<Void>,
  Pointer<Float>,
  Int32,
  Pointer<Utf8>,
  Int32,
  Pointer<Int32>,
);
typedef _Transcribe = int Function(
  Pointer<Void>,
  Pointer<Float>,
  int,
  Pointer<Utf8>,
  int,
  Pointer<Int32>,
);
typedef _LanguageC = Pointer<Utf8> Function(Pointer<Void>);
typedef _CountC = Int32 Function(Pointer<Void>);
typedef _Count = int Function(Pointer<Void>);
typedef _TokenC = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Float>,
);
typedef _Token = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Float>,
);

/// The bridge, with whisper.cpp loaded from one folder.
class WhisperLibrary {
  WhisperLibrary._(DynamicLibrary bridge)
    : _error = bridge.lookupFunction<_StringVoidC, _StringVoid>('ow_error'),
      _version = bridge.lookupFunction<_StringVoidC, _StringVoid>(
        'ow_whisper_version',
      ),
      _systemInfo = bridge.lookupFunction<_StringVoidC, _StringVoid>(
        'ow_system_info',
      ),
      _backendCount = bridge.lookupFunction<_IntVoidC, _IntVoid>(
        'ow_backend_count',
      ),
      _backendName = bridge.lookupFunction<_StringIntC, _StringInt>(
        'ow_backend_name',
      ),
      _isLanguage = bridge.lookupFunction<_IntStringC, _IntString>(
        'ow_is_language',
      ),
      _gpuCount = bridge.lookupFunction<_IntVoidC, _IntVoid>('ow_gpu_count'),
      _gpuName = bridge.lookupFunction<_StringIntC, _StringInt>('ow_gpu_name'),
      _gpuIntegrated = bridge
          .lookupFunction<Int32 Function(Int32), int Function(int)>(
            'ow_gpu_integrated',
          ),
      _open = bridge.lookupFunction<_OpenOnC, _OpenOn>('ow_open_on'),
      _close = bridge.lookupFunction<_CloseC, _Close>('ow_close'),
      _transcribe = bridge.lookupFunction<_TranscribeC, _Transcribe>(
        'ow_transcribe',
      ),
      _language = bridge.lookupFunction<_LanguageC, _LanguageC>('ow_language'),
      _tokenCount = bridge.lookupFunction<_CountC, _Count>('ow_token_count'),
      _token = bridge.lookupFunction<_TokenC, _Token>('ow_token');

  final _StringVoid _error;
  final _StringVoid _version;
  final _StringVoid _systemInfo;
  final _IntVoid _backendCount;
  final _StringInt _backendName;
  final _IntString _isLanguage;
  final _IntVoid _gpuCount;
  final _StringInt _gpuName;
  final int Function(int) _gpuIntegrated;
  final _OpenOn _open;
  final _Close _close;
  final _Transcribe _transcribe;
  final Pointer<Utf8> Function(Pointer<Void>) _language;
  final _Count _tokenCount;
  final _Token _token;

  static final _loaded = <String, WhisperLibrary>{};

  /// Opens the bridge at [bridgePath] and through it whisper.cpp's
  /// libraries in [libraryFolder] (the bundle's whisper.cpp folder) with
  /// the CPU backends there. The same pair again gives the same library;
  /// whisper.cpp can be loaded from one folder per process only.
  static WhisperLibrary load(String bridgePath, String libraryFolder) {
    final key = '$bridgePath|$libraryFolder';
    final known = _loaded[key];
    if (known != null) return known;
    final DynamicLibrary bridge;
    try {
      bridge = DynamicLibrary.open(bridgePath);
    } on ArgumentError catch (error) {
      throw WhisperError('could not open the bridge $bridgePath: $error');
    }
    final version = bridge.lookupFunction<_IntVoidC, _IntVoid>(
      'ow_bridge_version',
    )();
    if (version != _bridgeVersion) {
      throw WhisperError(
        'bridge $bridgePath is version $version, this app needs '
        '$_bridgeVersion',
      );
    }
    final library = WhisperLibrary._(bridge);
    final load = bridge.lookupFunction<_IntStringC, _IntString>('ow_load');
    final result = using(
      (arena) => load(libraryFolder.toNativeUtf8(allocator: arena)),
    );
    if (result != 0) throw WhisperError(library._lastError());
    return _loaded[key] = library;
  }

  String _lastError() {
    final text = _error().toDartString();
    return text.isEmpty ? 'no details' : text;
  }

  /// whisper_version(): '1.9.5'.
  String get version => _version().toDartString();

  /// whisper_print_system_info(): the CPU features ggml uses.
  String get systemInfo => _systemInfo().toDartString();

  /// The registered ggml backends, such as ['CPU'].
  List<String> get backends => [
    for (var i = 0; i < _backendCount(); i++) _backendName(i).toDartString(),
  ];

  /// Whether Whisper knows the language [code] ('ru', 'en', ...).
  bool isLanguage(String code) =>
      using((arena) => _isLanguage(code.toNativeUtf8(allocator: arena))) != 0;

  /// The GPUs the loaded backends offer (ggml-vulkan.dll in the folder,
  /// plan 10 I2i), in whisper.cpp's gpu_device order.
  List<({String name, bool integrated})> get gpus => [
    for (var i = 0; i < _gpuCount(); i++)
      (name: _gpuName(i).toDartString(), integrated: _gpuIntegrated(i) != 0),
  ];

  /// Loads the ggml model file at [modelPath] on the CPU, or on GPU [gpu]
  /// (an index into [gpus]).
  WhisperModel open(String modelPath, {int? gpu}) {
    final handle = using(
      (arena) => _open(modelPath.toNativeUtf8(allocator: arena), gpu ?? -1),
    );
    if (handle == nullptr) throw WhisperError(_lastError());
    return WhisperModel._(this, handle);
  }
}

/// A loaded Whisper model. One [transcribe] at a time.
class WhisperModel {
  WhisperModel._(this._library, this._handle);

  final WhisperLibrary _library;
  Pointer<Void> _handle;

  /// The language of the last result ('ru', 'en', ...; '' if none).
  String lastLanguage = '';

  /// Recognises one chunk of 16 kHz mono [samples] (up to 30 s): greedy,
  /// with whisper.cpp's fallback to higher temperatures for a failing
  /// window, nothing carried over from the chunk before. [language] is a
  /// code, or null to detect it. The call stops early when the int32 at
  /// [cancel] becomes non-zero, and then throws [WhisperCancelled].
  /// Gives the text tokens (special tokens left out) with times from the
  /// chunk's start.
  List<WhisperToken> transcribe(
    Float32List samples, {
    String? language,
    required int threads,
    Pointer<Int32>? cancel,
  }) {
    if (_handle == nullptr) throw const WhisperError('the model is closed');
    if (samples.isEmpty) throw const WhisperError('no samples');
    // As gigaam_app's set_language: None, '' and 'auto' all detect.
    if (language == '' || language == 'auto') language = null;
    if (language != null && !_library.isLanguage(language)) {
      throw WhisperError('Whisper does not know the language $language');
    }
    return using((arena) {
      final native = arena<Float>(samples.length);
      native.asTypedList(samples.length).setAll(0, samples);
      final result = _library._transcribe(
        _handle,
        native,
        samples.length,
        (language ?? 'auto').toNativeUtf8(allocator: arena),
        threads,
        cancel ?? nullptr,
      );
      if (result == _cancelled) throw const WhisperCancelled();
      if (result != _ok) throw WhisperError(_library._lastError());
      lastLanguage = _library._language(_handle).toDartString();
      final bytes = arena<Pointer<Uint8>>();
      final length = arena<Int32>();
      final t0 = arena<Int64>();
      final t1 = arena<Int64>();
      final probability = arena<Float>();
      final count = _library._tokenCount(_handle);
      return [
        for (var i = 0; i < count; i++)
          if (_library._token(_handle, i, bytes, length, t0, t1, probability) ==
              0)
            (
              bytes: length.value == 0
                  ? Uint8List(0)
                  : Uint8List.fromList(bytes.value.asTypedList(length.value)),
              start: t0.value * whisperTimeStep,
              end: t1.value * whisperTimeStep,
              probability: probability.value,
            ),
      ];
    });
  }

  /// Frees the model (about 600 MB for turbo q5_0).
  void close() {
    if (_handle == nullptr) return;
    _library._close(_handle);
    _handle = nullptr;
  }
}
