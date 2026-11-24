/// A set of model files that only work together (plan 10 I2a): the files
/// of "Hear the words" (separator, recogniser, speech gate) or of Whisper
/// (model and whisper.cpp libraries).
///
/// Each file goes through fit_model.downloadModel (a resumable `.part`,
/// size and SHA-256 checked before it gets its name). The bundle is ready
/// only when a marker file written last says so, and that marker holds the
/// app's own list of names, sizes and hashes for this version: a folder
/// left by another version, a half-finished download or a changed list is
/// never ready, so the app never loads a mix of old and new files.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fit_model.dart';

/// Models that only work together, kept in one folder per version.
class ModelBundle {
  const ModelBundle({
    required this.name,
    required this.version,
    required this.files,
    required this.notices,
  });

  /// Folder name without the version: 'hear-words'.
  final String name;

  /// Raised whenever any file changes; another version's folder is removed
  /// after this one is ready.
  final int version;

  /// The files; [ModelFile.fileName] may hold a subfolder ('gigaam/x.onnx').
  final List<ModelFile> files;

  /// Where each file comes from and its licence, written beside the files
  /// as NOTICES.txt.
  final String notices;

  String get folderName => '$name-$version';

  /// The whole download in bytes.
  int get bytes => files.fold(0, (sum, file) => sum + file.bytes);

  /// The size in whole megabytes, for the question before the download.
  int get megabytes => (bytes / 1e6).round();

  /// What the marker must hold.
  Map<String, Object> get manifest => {
    'name': name,
    'version': version,
    'files': {
      for (final file in files)
        file.fileName: {'bytes': file.bytes, 'sha256': file.sha256},
    },
  };
}

/// Name of the file written last, once every file checked out.
const bundleMarkerName = 'bundle.json';

/// The folder of [bundle] under [root] (DATA/models).
Directory bundleFolder(Directory root, ModelBundle bundle) =>
    Directory(p.join(root.path, bundle.folderName));

/// The path of one of [bundle]'s files under [root].
File bundleFile(Directory root, ModelBundle bundle, String fileName) =>
    File(p.joinAll([bundleFolder(root, bundle).path, ...fileName.split('/')]));

File _marker(Directory root, ModelBundle bundle) =>
    bundleFile(root, bundle, bundleMarkerName);

/// Whether every file of [bundle] is there for this version: the marker
/// matches the app's list and each file has its size (the bytes were
/// checked once, before the marker was written).
bool bundleReady(Directory root, ModelBundle bundle) {
  try {
    final marker = _marker(root, bundle);
    if (!marker.existsSync()) return false;
    final saved = jsonDecode(marker.readAsStringSync());
    if (jsonEncode(saved) != jsonEncode(bundle.manifest)) return false;
    return bundle.files.every(
      (file) => hasModel(bundleFile(root, bundle, file.fileName), file),
    );
  } on FormatException {
    return false;
  } on FileSystemException {
    return false;
  }
}

/// Bytes still to fetch: a file not there counts in full less what its
/// `.part` holds.
int bundleBytesLeft(Directory root, ModelBundle bundle) {
  var left = 0;
  for (final file in bundle.files) {
    final target = bundleFile(root, bundle, file.fileName);
    if (hasModel(target, file)) continue;
    final part = File('${target.path}.part');
    final have = part.existsSync() ? part.lengthSync() : 0;
    left += have <= file.bytes ? file.bytes - have : file.bytes;
  }
  return left;
}

/// Reads every file of [bundle] whole and compares the hashes (seconds per
/// file): after a model failed to load. A bundle that fails is no longer
/// ready, and its damaged files are deleted, so the next download fetches
/// only those again.
Future<bool> bundleIntact(Directory root, ModelBundle bundle) async {
  var intact = true;
  for (final file in bundle.files) {
    final target = bundleFile(root, bundle, file.fileName);
    if (await modelIntact(target, file)) continue;
    intact = false;
    _deleteQuietly(target);
  }
  if (!intact) _deleteQuietly(_marker(root, bundle));
  return intact;
}

/// Downloads every file of [bundle] that is missing, then marks it ready.
///
/// [freeBytes] says how much room the drive has (null: not checked); the
/// download, [workingBytes] (room the job using the models needs, such as
/// decoded audio) and fit_model.modelSpareBytes must fit. [onProgress] gets
/// the bundle's bytes so far and its whole size. Throws
/// [ModelDownloadError], or [DownloadStopped] after [stop]; the files that
/// finished stay for the next try.
Future<void> downloadBundle(
  ModelBundle bundle,
  Directory root, {
  HttpClient? client,
  int? Function()? freeBytes,
  int workingBytes = 0,
  void Function(int bytes, int total)? onProgress,
  DownloadStop? stop,
  Duration stallTimeout = const Duration(seconds: 30),
}) async {
  if (bundleReady(root, bundle)) {
    _removeOtherVersions(root, bundle);
    return;
  }
  final folder = bundleFolder(root, bundle)..createSync(recursive: true);
  _deleteQuietly(_marker(root, bundle));
  final left = bundleBytesLeft(root, bundle);
  final free = freeBytes?.call();
  if (free != null && free < left + workingBytes + modelSpareBytes) {
    throw ModelDownloadError(
      'Not enough free space: this needs '
      '${_gb(left + workingBytes + modelSpareBytes)} GB free, the drive has '
      '${_gb(free)} GB.',
      retry: false,
    );
  }
  final total = bundle.bytes;
  var done = 0;
  for (final file in bundle.files) {
    if (stop?.stopped ?? false) throw const DownloadStopped();
    final target = bundleFile(root, bundle, file.fileName);
    // A whole file not yet vouched for by the marker is read once: it may
    // be from a try whose list differed.
    if (hasModel(target, file) && !await modelIntact(target, file)) {
      target.deleteSync();
    }
    final before = done;
    await downloadModel(
      file,
      target,
      client: client,
      freeBytes: freeBytes,
      onProgress: (bytes, _) => onProgress?.call(before + bytes, total),
      stop: stop,
      stallTimeout: stallTimeout,
    );
    done += file.bytes;
    onProgress?.call(done, total);
  }
  File(p.join(folder.path, 'NOTICES.txt')).writeAsStringSync(bundle.notices);
  final marker = _marker(root, bundle);
  final temporary = File('${marker.path}.tmp')
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(bundle.manifest),
    );
  temporary.renameSync(marker.path);
  _removeOtherVersions(root, bundle);
}

/// Deletes the folders of [bundle]'s other versions ('hear-words-1' once
/// 'hear-words-2' is ready). A folder still in use (a loaded library) stays
/// until the next time.
void _removeOtherVersions(Directory root, ModelBundle bundle) {
  if (!root.existsSync()) return;
  final pattern = RegExp('^${RegExp.escape(bundle.name)}-(\\d+)\$');
  for (final entry in root.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    final match = pattern.firstMatch(p.basename(entry.path));
    if (match == null || int.parse(match.group(1)!) == bundle.version) {
      continue;
    }
    try {
      entry.deleteSync(recursive: true);
    } on FileSystemException {
      // In use; tried again after the next download.
    }
  }
}

void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Gone already or in use; the marker check still refuses it.
  }
}

String _gb(int bytes) => (bytes / 1e9).toStringAsFixed(1);
