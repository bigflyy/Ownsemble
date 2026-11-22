// A small binding to ONNX Runtime's C API (onnxruntime.dll from
// Microsoft's NuGet package Microsoft.ML.OnnxRuntime, 1.31.1), enough to
// run one float model on the CPU (plan 10 G1).
//
// The C API is one table of function pointers (struct OrtApi in
// onnxruntime_c_api.h), reached through OrtGetApiBase. Entries are only
// ever added at the end, so the positions below hold for every version at
// or above the one asked for. Most functions return an OrtStatus pointer:
// null on success, otherwise an error whose message is read and freed.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// The API version asked for (ORT_API_VERSION of 1.31).
const _apiVersion = 31;

// Positions in struct OrtApi (counted from onnxruntime_c_api.h 1.31.1).
const _getErrorMessage = 2;
const _createEnv = 3;
const _createSession = 7;
const _run = 9;
const _createSessionOptions = 10;
const _setGraphOptimizationLevel = 23;
const _setIntraOpNumThreads = 24;
const _setInterOpNumThreads = 25;
const _createTensorWithDataAsOrtValue = 49;
const _getTensorMutableData = 51;
const _getDimensionsCount = 61;
const _getDimensions = 62;
const _getTensorTypeAndShape = 65;
const _createCpuMemoryInfo = 69;
const _releaseEnv = 92;
const _releaseStatus = 93;
const _releaseMemoryInfo = 94;
const _releaseSession = 95;
const _releaseValue = 96;
const _releaseTensorTypeAndShapeInfo = 99;
const _releaseSessionOptions = 100;

// C enum values used here.
const _loggingLevelWarning = 2;
const _graphOptimizationAll = 99;
const _allocatorArena = 1;
const _memTypeDefault = 0;
const _elementFloat = 1;

typedef _Release = Void Function(Pointer<Void>);
typedef _ReleaseDart = void Function(Pointer<Void>);

final class _OrtApiBase extends Struct {
  external Pointer<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>>
  getApi;
  external Pointer<NativeFunction<Pointer<Utf8> Function()>> getVersionString;
}

/// An error ONNX Runtime reported.
class OnnxError implements Exception {
  const OnnxError(this.message);
  final String message;

  @override
  String toString() => 'OnnxError: $message';
}

/// A loaded onnxruntime library and its function table.
class OnnxRuntime {
  OnnxRuntime._(this._table, this.version);

  /// Loads the library from [libraryPath] (onnxruntime.dll on Windows).
  factory OnnxRuntime.load(String libraryPath) {
    final library = DynamicLibrary.open(libraryPath);
    final base = library
        .lookupFunction<
          Pointer<_OrtApiBase> Function(),
          Pointer<_OrtApiBase> Function()
        >('OrtGetApiBase')();
    final version = base.ref.getVersionString
        .asFunction<Pointer<Utf8> Function()>()()
        .toDartString();
    final table = base.ref.getApi
        .asFunction<Pointer<Pointer<Void>> Function(int)>()(_apiVersion);
    if (table == nullptr) {
      throw OnnxError('onnxruntime $version lacks API version $_apiVersion');
    }
    return OnnxRuntime._(table, version);
  }

  final Pointer<Pointer<Void>> _table;

  /// The library's own version, such as "1.31.1".
  final String version;

  Pointer<NativeFunction<T>> _entry<T extends Function>(int index) =>
      _table[index].cast<NativeFunction<T>>();

  /// Throws when [status] is an error, after freeing it.
  void _check(Pointer<Void> status) {
    if (status == nullptr) return;
    final message =
        _entry<Pointer<Utf8> Function(Pointer<Void>)>(_getErrorMessage)
            .asFunction<Pointer<Utf8> Function(Pointer<Void>)>()(status)
            .toDartString();
    _release(_releaseStatus, status);
    throw OnnxError(message);
  }

  void _release(int index, Pointer<Void> handle) {
    if (handle == nullptr) return;
    _entry<_Release>(index).asFunction<_ReleaseDart>()(handle);
  }

  /// Opens the model at [modelPath] for CPU runs with [threads] threads
  /// inside each operation.
  OnnxSession open(String modelPath, {int threads = 4}) {
    return using((arena) {
      final out = arena<Pointer<Void>>();
      _check(
        _entry<
              Pointer<Void> Function(
                Int32,
                Pointer<Utf8>,
                Pointer<Pointer<Void>>,
              )
            >(_createEnv)
            .asFunction<
              Pointer<Void> Function(int, Pointer<Utf8>, Pointer<Pointer<Void>>)
            >()(
          _loggingLevelWarning,
          'ownsemble'.toNativeUtf8(allocator: arena),
          out,
        ),
      );
      final env = out.value;
      _check(
        _entry<Pointer<Void> Function(Pointer<Pointer<Void>>)>(
          _createSessionOptions,
        ).asFunction<Pointer<Void> Function(Pointer<Pointer<Void>>)>()(out),
      );
      final options = out.value;
      try {
        final setInt = _entry<Pointer<Void> Function(Pointer<Void>, Int32)>;
        _check(
          setInt(_setIntraOpNumThreads)
              .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
            options,
            threads,
          ),
        );
        _check(
          setInt(_setInterOpNumThreads)
              .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
            options,
            1,
          ),
        );
        _check(
          setInt(_setGraphOptimizationLevel)
              .asFunction<Pointer<Void> Function(Pointer<Void>, int)>()(
            options,
            _graphOptimizationAll,
          ),
        );
        // ORTCHAR_T is wchar_t (UTF-16) on Windows and char elsewhere.
        final Pointer<Void> path = Platform.isWindows
            ? modelPath.toNativeUtf16(allocator: arena).cast()
            : modelPath.toNativeUtf8(allocator: arena).cast();
        _check(
          _entry<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Void>>,
                )
              >(_createSession)
              .asFunction<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Void>>,
                )
              >()(env, path, options, out),
        );
      } catch (_) {
        _release(_releaseSessionOptions, options);
        _release(_releaseEnv, env);
        rethrow;
      }
      final session = out.value;
      _release(_releaseSessionOptions, options);
      _check(
        _entry<Pointer<Void> Function(Int32, Int32, Pointer<Pointer<Void>>)>(
              _createCpuMemoryInfo,
            )
            .asFunction<
              Pointer<Void> Function(int, int, Pointer<Pointer<Void>>)
            >()(_allocatorArena, _memTypeDefault, out),
      );
      return OnnxSession._(this, env, session, out.value);
    });
  }
}

/// One opened model. Not shared between isolates: open one per isolate.
class OnnxSession {
  OnnxSession._(this._ort, this._env, this._session, this._memory);

  final OnnxRuntime _ort;
  final Pointer<Void> _env;
  Pointer<Void> _session;
  final Pointer<Void> _memory;

  /// Runs the model on one float tensor [input] of [shape] (input named
  /// [inputName]) and returns the float output [outputName] with its shape.
  ({Float32List values, List<int> shape}) run(
    String inputName,
    Float32List input,
    List<int> shape,
    String outputName,
  ) {
    if (_session == nullptr) throw const OnnxError('session closed');
    final ort = _ort;
    return using((arena) {
      final data = arena<Float>(input.length);
      data.asTypedList(input.length).setAll(0, input);
      final dims = arena<Int64>(shape.length);
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      final out = arena<Pointer<Void>>();
      ort._check(
        ort
            ._entry<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Size,
                Pointer<Int64>,
                Size,
                Int32,
                Pointer<Pointer<Void>>,
              )
            >(_createTensorWithDataAsOrtValue)
            .asFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                int,
                Pointer<Int64>,
                int,
                int,
                Pointer<Pointer<Void>>,
              )
            >()(
          _memory,
          data.cast(),
          input.length * sizeOf<Float>(),
          dims,
          shape.length,
          _elementFloat,
          out,
        ),
      );
      final inputValue = out.value;
      final inNames = arena<Pointer<Utf8>>()
        ..value = inputName.toNativeUtf8(allocator: arena);
      final outNames = arena<Pointer<Utf8>>()
        ..value = outputName.toNativeUtf8(allocator: arena);
      final inputs = arena<Pointer<Void>>()..value = inputValue;
      final outputs = arena<Pointer<Void>>()..value = nullptr;
      try {
        ort._check(
          ort
              ._entry<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Utf8>>,
                  Pointer<Pointer<Void>>,
                  Size,
                  Pointer<Pointer<Utf8>>,
                  Size,
                  Pointer<Pointer<Void>>,
                )
              >(_run)
              .asFunction<
                Pointer<Void> Function(
                  Pointer<Void>,
                  Pointer<Void>,
                  Pointer<Pointer<Utf8>>,
                  Pointer<Pointer<Void>>,
                  int,
                  Pointer<Pointer<Utf8>>,
                  int,
                  Pointer<Pointer<Void>>,
                )
              >()(_session, nullptr, inNames, inputs, 1, outNames, 1, outputs),
        );
      } finally {
        ort._release(_releaseValue, inputValue);
      }
      final outputValue = outputs.value;
      try {
        ort._check(
          ort
              ._entry<_StatusFnOut>(_getTensorTypeAndShape)
              .asFunction<_StatusFnOutDart>()(outputValue, out),
        );
        final info = out.value;
        final count = arena<Size>();
        ort._check(
          ort
              ._entry<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>(
                _getDimensionsCount,
              )
              .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Size>)
              >()(info, count),
        );
        final outDims = arena<Int64>(count.value);
        ort._check(
          ort
              ._entry<
                Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)
              >(_getDimensions)
              .asFunction<
                Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, int)
              >()(info, outDims, count.value),
        );
        ort._release(_releaseTensorTypeAndShapeInfo, info);
        final outShape = [for (var i = 0; i < count.value; i++) outDims[i]];
        final length = outShape.fold(1, (a, b) => a * b);
        ort._check(
          ort
              ._entry<_StatusFnOut>(_getTensorMutableData)
              .asFunction<_StatusFnOutDart>()(outputValue, out),
        );
        final values = Float32List.fromList(
          out.value.cast<Float>().asTypedList(length),
        );
        return (values: values, shape: outShape);
      } finally {
        ort._release(_releaseValue, outputValue);
      }
    });
  }

  /// Frees the model and its runtime state.
  void close() {
    if (_session == nullptr) return;
    _ort._release(_releaseSession, _session);
    _ort._release(_releaseMemoryInfo, _memory);
    _ort._release(_releaseEnv, _env);
    _session = nullptr;
  }
}

typedef _StatusFnOut = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _StatusFnOutDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
