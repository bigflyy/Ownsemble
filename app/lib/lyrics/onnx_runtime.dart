// A small binding to ONNX Runtime's C API (onnxruntime.dll from
// Microsoft's NuGet package Microsoft.ML.OnnxRuntime, 1.31.1), enough to
// run models on the CPU with float32, int32 and int64 tensors (plan
// 10 G1; several typed inputs and outputs since I2c, for GigaAM's encoder
// and Silero's carried state). The same code drives the DirectML build
// (Microsoft.ML.OnnxRuntime.DirectML 1.24.4) to run a model on the GPU
// (plan 10 I2i).
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

/// The API version asked for: ORT_API_VERSION of 1.24, the newest
/// DirectML build on NuGet (plan 10 I2i). Every entry used here is far
/// older, and a newer library gives the same table for an older version,
/// so the CPU 1.31.1 and the DirectML 1.24.4 both load.
const _apiVersion = 24;

// Positions in struct OrtApi (counted from onnxruntime_c_api.h 1.31.1).
const _getErrorMessage = 2;
const _createEnv = 3;
const _createSession = 7;
const _run = 9;
const _createSessionOptions = 10;
const _disableMemPattern = 17;
const _disableCpuMemArena = 19;
const _setGraphOptimizationLevel = 23;
const _setIntraOpNumThreads = 24;
const _setInterOpNumThreads = 25;
const _createTensorWithDataAsOrtValue = 49;
const _getTensorMutableData = 51;
const _getTensorElementType = 60;
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
const _getExecutionProviderApi = 195;

// Positions in struct OrtDmlApi (dml_provider_factory.h of 1.24.4).
const _dmlAppend2 = 5;

// OrtDmlDeviceOptions values: OrtDmlPerformancePreference HighPerformance,
// OrtDmlDeviceFilter Gpu.
const _dmlHighPerformance = 1;
const _dmlFilterGpu = 1;

/// [OnnxRuntime.open]'s directMlDevice for "the fastest GPU": DirectML's
/// own choice by performance (a laptop's discrete GPU over the built-in
/// one), where adapter 0 is only the one Windows lists first.
const directMlBestGpu = -1;

// C enum values used here.
const _loggingLevelWarning = 2;
const _graphOptimizationAll = 99;
const _allocatorArena = 1;
const _memTypeDefault = 0;
const _elementFloat = 1;
const _elementInt32 = 6;
const _elementInt64 = 7;

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
  OnnxRuntime._(this._library, this._table, this.version);

  /// Loads the library from [libraryPath] (onnxruntime.dll on Windows).
  ///
  /// A DirectML.dll beside it (the DirectML build's runtime, plan 10 I2i)
  /// is opened first, by its full path: onnxruntime.dll loads DirectML.dll
  /// by name only when a session first uses it, and Windows then takes a
  /// module of that name already in the process instead of the older copy
  /// in System32.
  factory OnnxRuntime.load(String libraryPath) {
    final directMl = File(
      '${File(libraryPath).parent.path}${Platform.pathSeparator}DirectML.dll',
    );
    if (Platform.isWindows && directMl.existsSync()) {
      DynamicLibrary.open(directMl.absolute.path);
    }
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
    return OnnxRuntime._(library, table, version);
  }

  final DynamicLibrary _library;
  final Pointer<Pointer<Void>> _table;

  /// Whether this is a DirectML build (it exports the provider's own
  /// append function; the CPU build does not).
  bool get hasDirectMl =>
      _library.providesSymbol('OrtSessionOptionsAppendExecutionProvider_DML');

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

  /// Adds DirectML on the fastest GPU to [options], through the OrtDmlApi
  /// table (SessionOptionsAppendExecutionProvider_DML2).
  void _appendBestDirectMl(Pointer<Void> options, Arena arena) {
    final table = arena<Pointer<Void>>();
    _check(
      _entry<
            Pointer<Void> Function(
              Pointer<Utf8>,
              Uint32,
              Pointer<Pointer<Void>>,
            )
          >(_getExecutionProviderApi)
          .asFunction<
            Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Pointer<Void>>)
          >()('DML'.toNativeUtf8(allocator: arena), _apiVersion, table),
    );
    if (table.value == nullptr) throw const OnnxError('no DirectML API');
    final device = arena<Uint32>(2)
      ..[0] = _dmlHighPerformance
      ..[1] = _dmlFilterGpu;
    final append = table.value
        .cast<Pointer<Void>>()[_dmlAppend2]
        .cast<
          NativeFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint32>)>
        >()
        .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Uint32>)>();
    _check(append(options, device));
  }

  /// Opens the model at [modelPath] for CPU runs with [threads] threads
  /// inside each operation. [memoryArena] false turns off the CPU memory
  /// arena and the memory pattern: ONNX Runtime then frees each
  /// intermediate tensor after use instead of keeping the largest set it
  /// ever needed (plan 10 I2b: the separator's peak).
  ///
  /// [directMlDevice] runs the model on that DirectML adapter (0 is the
  /// first one Windows lists; [directMlBestGpu] the fastest GPU), with the
  /// CPU only for operations DirectML lacks; it needs a DirectML build
  /// ([hasDirectMl]) and turns the memory pattern off, as DirectML
  /// requires.
  OnnxSession open(
    String modelPath, {
    int threads = 4,
    bool memoryArena = true,
    int? directMlDevice,
  }) {
    if (directMlDevice != null && !hasDirectMl) {
      throw OnnxError('onnxruntime $version has no DirectML');
    }
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
        final call = _entry<Pointer<Void> Function(Pointer<Void>)>;
        if (!memoryArena) {
          _check(
            call(_disableCpuMemArena)
                .asFunction<Pointer<Void> Function(Pointer<Void>)>()(options),
          );
        }
        if (!memoryArena || directMlDevice != null) {
          _check(
            call(_disableMemPattern)
                .asFunction<Pointer<Void> Function(Pointer<Void>)>()(options),
          );
        }
        if (directMlDevice == directMlBestGpu) {
          _appendBestDirectMl(options, arena);
        } else if (directMlDevice != null) {
          _check(
            _library.lookupFunction<
              Pointer<Void> Function(Pointer<Void>, Int32),
              Pointer<Void> Function(Pointer<Void>, int)
            >('OrtSessionOptionsAppendExecutionProvider_DML')(
              options,
              directMlDevice,
            ),
          );
        }
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

/// A tensor given to or returned by [OnnxSession.runTensors]: float32,
/// int32 or int64 values in row-major order and their shape.
class OnnxTensor {
  /// A float32 tensor.
  OnnxTensor.float(Float32List values, List<int> shape)
    : this._(values, shape, _elementFloat);

  /// An int64 tensor (lengths, token ids).
  OnnxTensor.int64(Int64List values, List<int> shape)
    : this._(values, shape, _elementInt64);

  /// An int32 tensor (GigaAM's encoder gives its frame count as one).
  OnnxTensor.int32(Int32List values, List<int> shape)
    : this._(values, shape, _elementInt32);

  OnnxTensor._(this.data, List<int> shape, this._element)
    : shape = List.unmodifiable(shape) {
    final count = shape.fold(1, (a, b) => a * b);
    final length = data.lengthInBytes ~/ data.elementSizeInBytes;
    if (count != length) {
      throw ArgumentError('shape $shape holds $count values, not $length');
    }
  }

  /// A [Float32List], an [Int32List] or an [Int64List].
  final TypedData data;
  final List<int> shape;
  final int _element;

  /// The values of a float tensor.
  Float32List get floats {
    if (data is! Float32List) throw StateError('not a float tensor');
    return data as Float32List;
  }

  /// The values of an int32 or int64 tensor.
  List<int> get ints {
    final values = data;
    if (values is Int64List) return values;
    if (values is Int32List) return values;
    throw StateError('not an integer tensor');
  }

  int get _bytes => data.lengthInBytes;
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
    final [out] = runTensors(
      {inputName: OnnxTensor.float(input, shape)},
      [outputName],
    );
    return (values: out.floats, shape: out.shape);
  }

  /// Runs the model on named [inputs] (float or int64) and returns the
  /// outputs named in [outputNames], in that order, as copies that stay
  /// valid after the call. An output of another element type than float32
  /// or int64 is an [OnnxError].
  List<OnnxTensor> runTensors(
    Map<String, OnnxTensor> inputs,
    List<String> outputNames,
  ) {
    if (_session == nullptr) throw const OnnxError('session closed');
    final ort = _ort;
    return using((arena) {
      final out = arena<Pointer<Void>>();
      final inNames = arena<Pointer<Utf8>>(inputs.length);
      final inValues = arena<Pointer<Void>>(inputs.length);
      final outNames = arena<Pointer<Utf8>>(outputNames.length);
      final outValues = arena<Pointer<Void>>(outputNames.length);
      for (var i = 0; i < outputNames.length; i++) {
        outNames[i] = outputNames[i].toNativeUtf8(allocator: arena);
        outValues[i] = nullptr;
      }
      var made = 0;
      try {
        for (final MapEntry(key: name, value: tensor) in inputs.entries) {
          // ONNX Runtime reads the data in place, so it lives in native
          // memory until the run is over.
          final bytes = tensor._bytes;
          final data = arena<Uint8>(bytes == 0 ? 1 : bytes);
          data
              .asTypedList(bytes)
              .setAll(
                0,
                tensor.data.buffer.asUint8List(
                  tensor.data.offsetInBytes,
                  bytes,
                ),
              );
          final dims = arena<Int64>(
            tensor.shape.isEmpty ? 1 : tensor.shape.length,
          );
          for (var d = 0; d < tensor.shape.length; d++) {
            dims[d] = tensor.shape[d];
          }
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
              bytes,
              dims,
              tensor.shape.length,
              tensor._element,
              out,
            ),
          );
          inNames[made] = name.toNativeUtf8(allocator: arena);
          inValues[made] = out.value;
          made++;
        }
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
              >()(
            _session,
            nullptr,
            inNames,
            inValues,
            made,
            outNames,
            outputNames.length,
            outValues,
          ),
        );
        return [
          for (var i = 0; i < outputNames.length; i++)
            _copyOut(outValues[i], arena),
        ];
      } finally {
        for (var i = 0; i < made; i++) {
          ort._release(_releaseValue, inValues[i]);
        }
        for (var i = 0; i < outputNames.length; i++) {
          ort._release(_releaseValue, outValues[i]);
        }
      }
    });
  }

  /// A Dart copy of the output tensor [value] (released by the caller).
  OnnxTensor _copyOut(Pointer<Void> value, Arena arena) {
    final ort = _ort;
    final out = arena<Pointer<Void>>();
    ort._check(
      ort
          ._entry<_StatusFnOut>(_getTensorTypeAndShape)
          .asFunction<_StatusFnOutDart>()(value, out),
    );
    final info = out.value;
    final List<int> shape;
    final int element;
    try {
      final type = arena<Int32>();
      ort._check(
        ort
            ._entry<Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)>(
              _getTensorElementType,
            )
            .asFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)
            >()(info, type),
      );
      element = type.value;
      final count = arena<Size>();
      ort._check(
        ort
            ._entry<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>(
              _getDimensionsCount,
            )
            .asFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Size>)>()(
          info,
          count,
        ),
      );
      final dims = arena<Int64>(count.value == 0 ? 1 : count.value);
      ort._check(
        ort
            ._entry<
              Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, Size)
            >(_getDimensions)
            .asFunction<
              Pointer<Void> Function(Pointer<Void>, Pointer<Int64>, int)
            >()(info, dims, count.value),
      );
      shape = [for (var i = 0; i < count.value; i++) dims[i]];
    } finally {
      ort._release(_releaseTensorTypeAndShapeInfo, info);
    }
    final length = shape.fold(1, (a, b) => a * b);
    if (length == 0) {
      switch (element) {
        case _elementFloat:
          return OnnxTensor.float(Float32List(0), shape);
        case _elementInt32:
          return OnnxTensor.int32(Int32List(0), shape);
        case _elementInt64:
          return OnnxTensor.int64(Int64List(0), shape);
      }
    }
    ort._check(
      ort
          ._entry<_StatusFnOut>(_getTensorMutableData)
          .asFunction<_StatusFnOutDart>()(value, out),
    );
    switch (element) {
      case _elementFloat:
        return OnnxTensor.float(
          Float32List.fromList(out.value.cast<Float>().asTypedList(length)),
          shape,
        );
      case _elementInt64:
        return OnnxTensor.int64(
          Int64List.fromList(out.value.cast<Int64>().asTypedList(length)),
          shape,
        );
      case _elementInt32:
        return OnnxTensor.int32(
          Int32List.fromList(out.value.cast<Int32>().asTypedList(length)),
          shape,
        );
    }
    throw OnnxError(
      'output element type $element is not float32, int32 or int64',
    );
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
