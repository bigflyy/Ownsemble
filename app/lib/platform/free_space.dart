/// Free space on the drive of a folder, before a big download.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The bytes free for this user on the drive that holds [folder]; null when
/// it cannot be told (not Windows, or the call failed).
int? freeBytesAt(String folder) {
  if (!Platform.isWindows) return null;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final getFree = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');
  return using((arena) {
    final path = folder.toNativeUtf16(allocator: arena);
    final free = arena<Uint64>();
    final total = arena<Uint64>();
    final allFree = arena<Uint64>();
    if (getFree(path, free, total, allFree) == 0) return null;
    return free.value;
  });
}
