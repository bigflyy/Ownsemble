/// This process's memory as Windows counts it (plan 10 I2b: a heard-words
/// job logs its peak and what is left after it).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// PROCESS_MEMORY_COUNTERS_EX (psapi.h).
final class _Counters extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @Size()
  external int peakWorkingSetSize;
  @Size()
  external int workingSetSize;
  @Size()
  external int quotaPeakPagedPoolUsage;
  @Size()
  external int quotaPagedPoolUsage;
  @Size()
  external int quotaPeakNonPagedPoolUsage;
  @Size()
  external int quotaNonPagedPoolUsage;
  @Size()
  external int pagefileUsage;
  @Size()
  external int peakPagefileUsage;
  @Size()
  external int privateUsage;
}

/// Working set and private bytes, in bytes.
typedef ProcessMemory = ({int workingSet, int private});

int Function(int, Pointer<_Counters>, int)? _query;
int Function()? _process;

/// The process's working set and private bytes now; null when not on
/// Windows or the call fails.
ProcessMemory? processMemory() {
  if (!Platform.isWindows) return null;
  try {
    _query ??= DynamicLibrary.open('psapi.dll')
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<_Counters>, Uint32),
          int Function(int, Pointer<_Counters>, int)
        >('GetProcessMemoryInfo');
    _process ??= DynamicLibrary.open('kernel32.dll')
        .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  } on ArgumentError {
    return null;
  }
  return using((arena) {
    final counters = arena<_Counters>();
    counters.ref.cb = sizeOf<_Counters>();
    if (_query!(_process!(), counters, sizeOf<_Counters>()) == 0) return null;
    return (
      workingSet: counters.ref.workingSetSize,
      private: counters.ref.privateUsage,
    );
  });
}
