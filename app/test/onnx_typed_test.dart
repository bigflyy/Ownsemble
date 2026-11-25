// Plan 10 I2c: the ONNX binding with several typed inputs and outputs, on
// a tiny model (y = 2 x float, m = n + 1 int64, k = m as int32; made by
// experiments/f2-timing/make_gigaam_fixtures.py) and the real runtime,
// when the release build's onnxruntime.dll is there.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/lyrics/onnx_runtime.dart';

void main() {
  const dll = 'build/windows/x64/runner/Release/onnxruntime.dll';
  final available = File(dll).existsSync();

  test('float and int64 in, float and int64 out, in the order asked', () {
    final session = OnnxRuntime.load(
      File(dll).absolute.path,
    ).open(File('test/fixtures/gigaam/typed.onnx').absolute.path, threads: 1);
    addTearDown(session.close);
    final x = Float32List.fromList([1.5, -2, 0.25, 7]);
    final outs = session.runTensors(
      {
        'x': OnnxTensor.float(x, const [1, 4]),
        'n': OnnxTensor.int64(Int64List.fromList([1 << 40]), const [1]),
      },
      const ['m', 'y', 'k'],
    );
    expect(outs[0].shape, [1]);
    expect(outs[0].ints, [(1 << 40) + 1]);
    expect(() => outs[0].floats, throwsStateError);
    expect(outs[1].shape, [1, 4]);
    expect(outs[1].floats, [3.0, -4.0, 0.5, 14.0]);
    // int32 out: 2^40 + 1 cast to int32 keeps the low 32 bits.
    expect(outs[2].data, isA<Int32List>());
    expect(outs[2].ints, [1]);
    // The single-float run still works.
    final legacy = session.runTensors(
      {
        'x': OnnxTensor.float(Float32List(0), const [1, 0]),
        'n': OnnxTensor.int64(Int64List(1), const [1]),
      },
      const ['y'],
    );
    expect(legacy.single.shape, [1, 0]);
    expect(legacy.single.floats, isEmpty);
  }, skip: available ? false : 'no release build with onnxruntime.dll');

  test(
    'a wrong input name or type is an OnnxError, and the session lives on',
    () {
      final session = OnnxRuntime.load(
        File(dll).absolute.path,
      ).open(File('test/fixtures/gigaam/typed.onnx').absolute.path, threads: 1);
      addTearDown(session.close);
      expect(
        () => session.runTensors(
          {
            'x': OnnxTensor.float(Float32List(2), const [1, 2]),
            'n': OnnxTensor.float(Float32List(1), const [1]),
          },
          const ['y'],
        ),
        throwsA(isA<OnnxError>()),
      );
      expect(
        () => session.runTensors(
          {
            'nope': OnnxTensor.float(Float32List(2), const [1, 2]),
          },
          const ['y'],
        ),
        throwsA(isA<OnnxError>()),
      );
      final [y] = session.runTensors(
        {
          'x': OnnxTensor.float(Float32List.fromList([1, 2]), const [1, 2]),
          'n': OnnxTensor.int64(Int64List(1), const [1]),
        },
        const ['y'],
      );
      expect(y.floats, [2.0, 4.0]);
    },
    skip: available ? false : 'no release build with onnxruntime.dll',
  );

  test('the CPU build has no DirectML, and a DirectML session is refused', () {
    final runtime = OnnxRuntime.load(File(dll).absolute.path);
    expect(runtime.hasDirectMl, isFalse);
    expect(
      () => runtime.open(
        File('test/fixtures/gigaam/typed.onnx').absolute.path,
        threads: 1,
        directMlDevice: 0,
      ),
      throwsA(
        isA<OnnxError>().having(
          (e) => e.message,
          'message',
          contains('no DirectML'),
        ),
      ),
    );
  }, skip: available ? false : 'no release build with onnxruntime.dll');

  test('a shape that does not hold the values is refused before the run', () {
    expect(
      () => OnnxTensor.float(Float32List(3), const [1, 4]),
      throwsArgumentError,
    );
    expect(
      () => OnnxTensor.int64(Int64List(2), const [3]),
      throwsArgumentError,
    );
  });
}
