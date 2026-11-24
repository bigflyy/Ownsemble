/// Reads float32 arrays from a NumPy .npz file (plan 10 I2c: GigaAM's
/// head.npz, the RNNT prediction and joint weights).
///
/// An .npz is a zip archive of .npy files. numpy.savez stores them
/// uncompressed and marks each with zip64 sizes (0xFFFFFFFF in the local
/// header, the real sizes in an extra field), so the reader goes through
/// the central directory and its zip64 fields. Each .npy is a magic
/// string, a version, a header length and a Python dict literal naming
/// the dtype, the order and the shape, followed by the raw values. Only
/// what numpy.savez writes for float32 weights is accepted: stored
/// (method 0) entries, little-endian '<f4', C order.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One array: its values in row-major order and its shape.
typedef NpyArray = ({Float32List values, List<int> shape});

/// An archive or an array this reader does not take.
class NpzFormatError implements Exception {
  const NpzFormatError(this.message);
  final String message;

  @override
  String toString() => 'NpzFormatError: $message';
}

/// Every array in the .npz [bytes], by name without the ".npy" ending.
Map<String, NpyArray> readNpz(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final end = _findEndOfDirectory(bytes);
  var entries = data.getUint16(end + 10, Endian.little);
  var directorySize = data.getUint32(end + 12, Endian.little);
  var directoryOffset = data.getUint32(end + 16, Endian.little);
  if (entries == 0xFFFF ||
      directorySize == 0xFFFFFFFF ||
      directoryOffset == 0xFFFFFFFF) {
    // The zip64 end record, found through its locator just before.
    final locator = end - 20;
    if (locator < 0 || data.getUint32(locator, Endian.little) != 0x07064b50) {
      throw const NpzFormatError('zip64 locator missing');
    }
    final record = data.getUint64(locator + 8, Endian.little);
    if (data.getUint32(record, Endian.little) != 0x06064b50) {
      throw const NpzFormatError('zip64 end record missing');
    }
    entries = data.getUint64(record + 32, Endian.little);
    directorySize = data.getUint64(record + 40, Endian.little);
    directoryOffset = data.getUint64(record + 48, Endian.little);
  }
  final arrays = <String, NpyArray>{};
  var at = directoryOffset;
  for (var i = 0; i < entries; i++) {
    if (data.getUint32(at, Endian.little) != 0x02014b50) {
      throw NpzFormatError('bad directory entry at $at');
    }
    final method = data.getUint16(at + 10, Endian.little);
    var compressed = data.getUint32(at + 20, Endian.little);
    var size = data.getUint32(at + 24, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    var localOffset = data.getUint32(at + 42, Endian.little);
    final name = utf8.decode(
      Uint8List.sublistView(bytes, at + 46, at + 46 + nameLength),
    );
    // Zip64 extra field (id 1): the 64-bit values, in this order, of only
    // those fields that are 0xFFFFFFFF above.
    var extra = at + 46 + nameLength;
    final extraEnd = extra + extraLength;
    while (extra + 4 <= extraEnd) {
      final id = data.getUint16(extra, Endian.little);
      final length = data.getUint16(extra + 2, Endian.little);
      if (id == 1) {
        var field = extra + 4;
        if (size == 0xFFFFFFFF) {
          size = data.getUint64(field, Endian.little);
          field += 8;
        }
        if (compressed == 0xFFFFFFFF) {
          compressed = data.getUint64(field, Endian.little);
          field += 8;
        }
        if (localOffset == 0xFFFFFFFF) {
          localOffset = data.getUint64(field, Endian.little);
        }
      }
      extra += 4 + length;
    }
    if (method != 0 || compressed != size) {
      throw NpzFormatError('$name is compressed (method $method)');
    }
    if (data.getUint32(localOffset, Endian.little) != 0x04034b50) {
      throw NpzFormatError('bad local header of $name');
    }
    final start =
        localOffset +
        30 +
        data.getUint16(localOffset + 26, Endian.little) +
        data.getUint16(localOffset + 28, Endian.little);
    if (start + size > bytes.length) {
      throw NpzFormatError('$name runs past the end');
    }
    final key = name.endsWith('.npy')
        ? name.substring(0, name.length - 4)
        : name;
    arrays[key] = readNpy(Uint8List.sublistView(bytes, start, start + size));
    at += 46 + nameLength + extraLength + commentLength;
  }
  return arrays;
}

int _findEndOfDirectory(Uint8List bytes) {
  // The end record is 22 bytes plus a comment of at most 65535 bytes.
  final data = ByteData.sublistView(bytes);
  final lowest = bytes.length - 22 - 0xFFFF < 0
      ? 0
      : bytes.length - 22 - 0xFFFF;
  for (var at = bytes.length - 22; at >= lowest; at--) {
    if (data.getUint32(at, Endian.little) == 0x06054b50) return at;
  }
  throw const NpzFormatError('not a zip archive');
}

final _descr = RegExp(r"""'descr'\s*:\s*'([^']*)'""");
final _fortran = RegExp(r"""'fortran_order'\s*:\s*(True|False)""");
final _shape = RegExp(r"""'shape'\s*:\s*\(([^)]*)\)""");

/// One .npy file's float32 array.
NpyArray readNpy(Uint8List bytes) {
  const magic = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]; // "\x93NUMPY"
  if (bytes.length < 10 ||
      Iterable.generate(6).any((i) => bytes[i] != magic[i])) {
    throw const NpzFormatError('not an .npy file');
  }
  final data = ByteData.sublistView(bytes);
  final major = bytes[6];
  final int headerLength;
  final int headerStart;
  if (major == 1) {
    headerLength = data.getUint16(8, Endian.little);
    headerStart = 10;
  } else if (major == 2 || major == 3) {
    headerLength = data.getUint32(8, Endian.little);
    headerStart = 12;
  } else {
    throw NpzFormatError('.npy version $major');
  }
  final header = latin1.decode(
    Uint8List.sublistView(bytes, headerStart, headerStart + headerLength),
  );
  final descr = _descr.firstMatch(header)?.group(1);
  if (descr != '<f4') throw NpzFormatError('dtype $descr, not <f4');
  if (_fortran.firstMatch(header)?.group(1) != 'False') {
    throw const NpzFormatError('Fortran order');
  }
  final dims = _shape.firstMatch(header)?.group(1);
  if (dims == null) throw const NpzFormatError('no shape');
  final shape = [
    for (final part in dims.split(','))
      if (part.trim().isNotEmpty) int.parse(part.trim()),
  ];
  final count = shape.fold(1, (a, b) => a * b);
  final start = headerStart + headerLength;
  if (start + count * 4 > bytes.length) {
    throw const NpzFormatError('array data cut short');
  }
  // A copy: the archive's bytes need not be 4-byte aligned.
  final values = Float32List(count);
  values.buffer.asUint8List().setAll(
    0,
    Uint8List.sublistView(bytes, start, start + count * 4),
  );
  if (Endian.host != Endian.little) {
    throw const NpzFormatError('big-endian host');
  }
  return (values: values, shape: shape);
}
