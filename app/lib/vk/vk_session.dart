import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'vk_client.dart';

/// Where the VK session is kept between runs.
abstract class VkSessionStore {
  /// The saved session, or null when there is none that can be read.
  List<SessionCookie>? load();

  void save(List<SessionCookie> cookies);

  /// Forgets the session.
  void clear();
}

/// One saved login.
class SavedSession {
  const SavedSession(this.id, this.account, this.cookies);

  /// Which saved session this is, for [VkSessionVault].
  final String id;

  /// VK user id; null until VK says whose session this is, which only happens
  /// for a session saved before there could be several.
  final String? account;
  final List<SessionCookie> cookies;
}

/// All VK sessions kept between runs, one per VK account.
abstract class VkSessionVault {
  /// The saved sessions that can be read.
  List<SavedSession> load();

  /// Keeps [cookies] as the session of [account], in place of an older one.
  /// Returns the session's id.
  String save(String account, List<SessionCookie> cookies);

  /// Notes that [session], saved with no owner, belongs to [account]. Returns
  /// its id from now on.
  String adopt(SavedSession session, String account);

  /// Forgets the session [id].
  void remove(String id);
}

/// Sessions of the login window: one encrypted file per VK account in the
/// `sessions` folder, named by the VK user id. A single `session.dpapi` is what
/// earlier builds wrote; it moves into the folder once VK says whose it is.
class ProtectedSessionFolder implements VkSessionVault {
  ProtectedSessionFolder(String dataDir)
    : _single = File(p.join(dataDir, 'session.dpapi')),
      _folder = Directory(p.join(dataDir, 'sessions'));

  static const _singleId = 'session.dpapi';

  final File _single;
  final Directory _folder;

  File _fileOf(String id) =>
      id == _singleId ? _single : File(p.join(_folder.path, '$id.dpapi'));

  @override
  List<SavedSession> load() {
    final saved = <SavedSession>[];
    final files = _folder.existsSync()
        ? (_folder.listSync().whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        : const <File>[];
    for (final file in files) {
      if (p.extension(file.path) != '.dpapi') continue;
      final cookies = ProtectedSessionFile(file).load();
      final account = p.basenameWithoutExtension(file.path);
      if (cookies != null) saved.add(SavedSession(account, account, cookies));
    }
    if (ProtectedSessionFile(_single).load() case final cookies?) {
      saved.add(SavedSession(_singleId, null, cookies));
    }
    return saved;
  }

  @override
  String save(String account, List<SessionCookie> cookies) {
    _folder.createSync(recursive: true);
    ProtectedSessionFile(_fileOf(account)).save(cookies);
    return account;
  }

  @override
  String adopt(SavedSession session, String account) {
    save(account, session.cookies);
    remove(session.id);
    return account;
  }

  @override
  void remove(String id) => ProtectedSessionFile(_fileOf(id)).clear();
}

/// Session files of the agent's test accounts, plain JSON made by the login
/// helper (`--vk-session`). The files are only ever read: logging out forgets
/// a session for this run, and a new login lasts for this run.
class PlainSessionFiles implements VkSessionVault {
  PlainSessionFiles(this.files);

  final List<File> files;
  final _forgotten = <String>{};
  final _added = <String, SavedSession>{};

  @override
  List<SavedSession> load() => [
    for (final file in files)
      if (file.existsSync() && !_forgotten.contains(file.path))
        SavedSession(file.path, null, SessionCookie.loadAll(file)),
    ..._added.values,
  ];

  @override
  String save(String account, List<SessionCookie> cookies) {
    final id = 'login-$account';
    _added[id] = SavedSession(id, account, cookies);
    return id;
  }

  @override
  String adopt(SavedSession session, String account) => session.id;

  @override
  void remove(String id) {
    _forgotten.add(id);
    _added.remove(id);
  }
}

/// One session in a file, encrypted by Windows for this Windows user.
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
