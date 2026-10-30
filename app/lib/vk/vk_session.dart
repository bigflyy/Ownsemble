import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'vk_client.dart';

/// Where the VK session is kept between runs.
abstract class VkSessionStore {
  /// The saved session, or null when there is none that can be read.
  List<SessionCookie>? load();

  void save(List<SessionCookie> cookies);

  /// Forgets the session.
  void clear();
}

/// A session file of the agent's test account, plain JSON made by the login
/// helper (`--vk-session`). It is only ever read: logging out forgets it for
/// this run and leaves the file alone.
class PlainSessionFile implements VkSessionStore {
  PlainSessionFile(this.file);

  final File file;
  bool _forgotten = false;
  List<SessionCookie>? _saved;

  @override
  List<SessionCookie>? load() {
    if (_forgotten) return _saved;
    return file.existsSync() ? SessionCookie.loadAll(file) : null;
  }

  @override
  void save(List<SessionCookie> cookies) {
    _forgotten = true;
    _saved = cookies;
  }

  @override
  void clear() {
    _forgotten = true;
    _saved = null;
  }
}

/// The session of the login window: `session.dpapi` in the data folder,
/// encrypted by Windows for this Windows user.
///
/// These cookies are as good as the account's password, so they are never
/// stored as plain text. Another Windows user, or a copy of the file on
/// another computer, cannot read them; such a file counts as no session.
class ProtectedSessionFile implements VkSessionStore {
  ProtectedSessionFile(this.file);

  final File file;

  @override
  List<SessionCookie>? load() {
    if (!file.existsSync()) return null;
    final Uint8List plain;
    try {
      plain = unprotectForThisUser(file.readAsBytesSync());
    } on DpapiException {
      return null;
    }
    return SessionCookie.listFromJson(utf8.decode(plain));
  }

  @override
  void save(List<SessionCookie> cookies) {
    final encrypted = protectForThisUser(
      utf8.encode(SessionCookie.listToJson(cookies)),
    );
    final partial = File('${file.path}.part');
    partial.writeAsBytesSync(encrypted, flush: true);
    partial.renameSync(file.path);
  }

  @override
  void clear() {
    if (file.existsSync()) file.deleteSync();
  }
}

/// Windows refused to encrypt or decrypt.
class DpapiException implements Exception {
  DpapiException(this.operation, this.code);

  final String operation;

  /// The value of GetLastError.
  final int code;

  @override
  String toString() => 'DpapiException: $operation failed, error $code';
}

/// Windows' DATA_BLOB: a length and a pointer.
final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob> input,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> output,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob> input,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> output,
);

/// Never show a Windows prompt: the app runs this without a user at hand.
const _cryptProtectUiForbidden = 1;

/// Encrypts [plain] so only this Windows user can decrypt it.
Uint8List protectForThisUser(Uint8List plain) =>
    _crypt('CryptProtectData', plain);

/// Decrypts what [protectForThisUser] made.
Uint8List unprotectForThisUser(Uint8List encrypted) =>
    _crypt('CryptUnprotectData', encrypted);

// Both calls have the same shape, except that decrypting writes the
// description to its second parameter; null means it is not wanted.
Uint8List _crypt(String function, Uint8List bytes) {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final crypt = crypt32.lookupFunction<_CryptNative, _CryptDart>(function);
  final localFree = kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  final getLastError = kernel32
      .lookupFunction<Uint32 Function(), int Function()>(
        'GetLastError',
        isLeaf: true,
      );

  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    input.ref
      ..length = bytes.length
      ..data = buffer;
    final ok = crypt(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      _cryptProtectUiForbidden,
      output,
    );
    if (ok == 0) throw DpapiException(function, getLastError());
    final result = Uint8List.fromList(
      output.ref.data.asTypedList(output.ref.length),
    );
    localFree(output.ref.data.cast());
    return result;
  } finally {
    // The plain text must not stay around in freed memory.
    buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
    calloc.free(buffer);
    calloc.free(input);
    calloc.free(output);
  }
}
