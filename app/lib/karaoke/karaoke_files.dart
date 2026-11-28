/// Where finished karaoke videos go and what they are called (plan 11
/// D1f): Videos\Ownsemble, "Artist - Title (karaoke).mp4" with the
/// variants named in the brackets, a free name when the file exists, and
/// the file put there only whole.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'karaoke_script.dart' show KaraokeShape;

/// The longest "Artist - Title" part of a name, in characters: with the
/// folder and the bracket the whole path stays well under Windows' 260.
const _stemMax = 150;

/// Names Windows keeps for devices. Windows compares the part before the
/// first dot with its trailing spaces removed ("con .x" is CON too).
final _reserved = RegExp(
  // The superscript digits one, two and three count as digits there.
  '^(con|prn|aux|nul|conin\\\$|conout\\\$|com[0-9¹²³]|'
  'lpt[0-9¹²³])\$',
  caseSensitive: false,
);

bool _isDeviceName(String name) {
  final dot = name.indexOf('.');
  final base = (dot < 0 ? name : name.substring(0, dot)).trimRight();
  return _reserved.hasMatch(base);
}

/// Characters Windows refuses in a file name, and control characters.
final _refused = RegExp(r'[<>:"/\\|?*\x00-\x1f]');

/// [text] made safe as part of a Windows file name: refused characters
/// become '_', runs of spaces one space, no dots or spaces at the end, at
/// most [max] UTF-16 units (whole characters, never half a pair).
String safeFileNamePart(String text, {int max = _stemMax}) {
  // Tabs and line breaks are spaces first; other control characters and
  // the refused ones become '_'.
  var safe = text
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(_refused, '_')
      .trim();
  // At most [max] UTF-16 units (NTFS counts those; an emoji is two),
  // never half a pair.
  if (safe.length > max) {
    final kept = StringBuffer();
    for (final rune in safe.runes) {
      final units = rune > 0xFFFF ? 2 : 1;
      if (kept.length + units > max) break;
      kept.writeCharCode(rune);
    }
    safe = kept.toString();
  }
  safe = safe.replaceFirst(RegExp(r'[. ]+$'), '');
  if (_isDeviceName(safe)) safe = '_$safe';
  return safe;
}

/// The file name of one video: "Artist - Title (karaoke).mp4", with
/// ", no voice" and ", vertical" in the brackets for those variants.
String karaokeFileName({
  required String artist,
  required String title,
  required bool withVoice,
  required KaraokeShape shape,
}) {
  final a = artist.trim(), t = title.trim();
  final song = a.isEmpty
      ? t
      : t.isEmpty
      ? a
      : '$a - $t';
  var stem = safeFileNamePart(song);
  if (stem.isEmpty) stem = 'Song';
  final tags = [
    'karaoke',
    if (!withVoice) 'no voice',
    if (shape == KaraokeShape.vertical) 'vertical',
  ];
  return '$stem (${tags.join(', ')}).mp4';
}

/// [name] in [folder], or "stem (2).mp4", "stem (3).mp4" ... when a file of
/// that name exists.
File freeTarget(Directory folder, String name) {
  final first = File(p.join(folder.path, name));
  if (!first.existsSync()) return first;
  final stem = p.basenameWithoutExtension(name);
  final extension = p.extension(name);
  for (var n = 2; ; n++) {
    final next = File(p.join(folder.path, '$stem ($n)$extension'));
    if (!next.existsSync()) return next;
  }
}

/// Moves [source] to a free name for [name] in [folder] and returns where
/// it went. The file appears there only whole: a rename on the same drive;
/// across drives a copy to a ".part" name, then a rename.
File moveIntoPlace(File source, Directory folder, String name) {
  folder.createSync(recursive: true);
  final target = freeTarget(folder, name);
  try {
    return source.renameSync(target.path);
  } on FileSystemException {
    // Another drive: copy beside, then rename.
  }
  final part = File('${target.path}.part');
  final File placed;
  try {
    source.copySync(part.path);
    placed = part.renameSync(target.path);
  } on FileSystemException {
    if (part.existsSync()) part.deleteSync();
    rethrow;
  }
  try {
    source.deleteSync();
  } on FileSystemException {
    // The video is in place; the job folder's copy goes with the folder.
  }
  return placed;
}

/// The folder finished videos go to: Ownsemble in the user's Videos
/// folder (the known folder, which OneDrive or the user may have moved),
/// or in USERPROFILE\Videos when Windows does not say.
Directory karaokeVideosFolder() {
  final videos =
      _knownVideosFolder() ??
      p.join(Platform.environment['USERPROFILE'] ?? '.', 'Videos');
  return Directory(p.join(videos, 'Ownsemble'));
}

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

/// FOLDERID_Videos {18989B1D-99B5-455B-841C-AB7C74E4DDFC} through
/// SHGetKnownFolderPath; null off Windows or when it fails.
String? _knownVideosFolder() {
  if (!Platform.isWindows) return null;
  try {
    final shell = DynamicLibrary.open('shell32.dll');
    final ole = DynamicLibrary.open('ole32.dll');
    final getPath = shell
        .lookupFunction<
          Int32 Function(
            Pointer<_Guid>,
            Uint32,
            IntPtr,
            Pointer<Pointer<Utf16>>,
          ),
          int Function(Pointer<_Guid>, int, int, Pointer<Pointer<Utf16>>)
        >('SHGetKnownFolderPath');
    final free = ole
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CoTaskMemFree');
    final id = calloc<_Guid>();
    final out = calloc<Pointer<Utf16>>();
    try {
      id.ref
        ..data1 = 0x18989B1D
        ..data2 = 0x99B5
        ..data3 = 0x455B;
      const tail = [0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC];
      for (var i = 0; i < 8; i++) {
        id.ref.data4[i] = tail[i];
      }
      final result = getPath(id, 0, 0, out);
      final pointer = out.value;
      if (pointer == nullptr) return null;
      // Freed even when the call failed, as its documentation asks.
      final path = result == 0 ? pointer.toDartString() : '';
      free(pointer.cast());
      return path.isEmpty ? null : path;
    } finally {
      calloc.free(id);
      calloc.free(out);
    }
  } on Object {
    return null;
  }
}
