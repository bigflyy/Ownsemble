// Shows how often each layer of a "same song" key hits on real VK libraries,
// for deciding how one song in two accounts becomes one row (plan stage E).
//
// Layers, strongest first: same VK key (owner_id + id), VK's track_id, VK's
// release_audio_id, then the text of artist + title with the song's length.
// Each song is counted at the first layer that finds a partner. The same text
// with another length is listed but is not a match: those are the songs a text
// key could wrongly merge.
//
// With one session it compares that account with itself; with two it also
// compares them. Prints only named fields: titles, lengths and counts. Never a
// link, a key or any other part of a raw reply: VK's replies hold signed links.
//
// Run from app/:
//   dart run tool/probe_duplicate_layers.dart --vk-session FILE
//       [--vk-session-2 FILE]

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ownsemble/vk/vk_client.dart';
import 'package:ownsemble/vk/vk_sync.dart';

/// How far apart two lengths may be and still count as one recording.
const _lengthToleranceSeconds = 2;

/// How many songs to name per layer.
const _sampleLimit = 30;

/// The layers, in the order they are tried.
enum Layer {
  vkKey('same VK key'),
  trackId('track_id'),
  releaseKey('release_audio_id'),
  textExact('text + exact length'),
  textNear('text + length within $_lengthToleranceSeconds s'),
  textOnly('same text, other length (NOT a match)');

  const Layer(this.label);
  final String label;

  bool get usesText => index >= Layer.textExact.index;
}

/// The fields of one song this probe reads from VK's reply.
class Song {
  Song(Map<String, dynamic> item)
    : key = vkSourceKey(item),
      trackId = _idOrNull(item['track_id']),
      releaseKey = _idOrNull(item['release_audio_id']),
      text = _matchText('${item['artist']} - ${item['title']}'),
      seconds = item['duration'] as int? ?? 0,
      label = '${item['artist']} - ${item['title']}';

  final String key;
  final String? trackId;
  final String? releaseKey;
  final String text;
  final int seconds;
  final String label;
}

String? _idOrNull(Object? value) {
  final text = value?.toString() ?? '';
  return text.isEmpty || text == '0' ? null : text;
}

/// Lower case, ё as е, and every run of other characters as one space, so
/// "Artist - Title" and "ARTIST  -  Title!" read the same.
String _matchText(String text) => text
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// The songs already seen, looked up by each layer.
class SongIndex {
  final _keys = <String, Song>{};
  final _trackIds = <String, Song>{};
  final _releaseKeys = <String, Song>{};
  final _texts = <String, List<Song>>{};

  void add(Song song) {
    _keys[song.key] = song;
    if (song.trackId case final id?) _trackIds[id] = song;
    if (song.releaseKey case final id?) _releaseKeys[id] = song;
    (_texts[song.text] ??= []).add(song);
  }

  /// The first layer that finds a partner of [song], and that partner.
  (Layer, Song)? find(Song song) {
    if (_keys[song.key] case final partner?) return (Layer.vkKey, partner);
    if (_trackIds[song.trackId] case final partner?) {
      return (Layer.trackId, partner);
    }
    if (_releaseKeys[song.releaseKey] case final partner?) {
      return (Layer.releaseKey, partner);
    }
    final sameText = _texts[song.text] ?? const <Song>[];
    if (sameText.isEmpty) return null;
    Song closest = sameText.first;
    for (final other in sameText) {
      if (_gap(other, song) < _gap(closest, song)) closest = other;
    }
    final gap = _gap(closest, song);
    if (gap == 0) return (Layer.textExact, closest);
    if (gap <= _lengthToleranceSeconds) return (Layer.textNear, closest);
    return (Layer.textOnly, closest);
  }
}

int _gap(Song a, Song b) => (a.seconds - b.seconds).abs();

/// Counts each song of [songs] at its first layer against [index], names the
/// text layers' songs, and says where VK's own ids contradict the text.
void report(
  String title,
  List<Song> songs,
  SongIndex index, {
  bool grow = false,
}) {
  final counts = {for (final layer in Layer.values) layer: 0};
  final samples = {for (final layer in Layer.values) layer: <String>[]};
  var conflicts = 0;
  var none = 0;
  for (final song in songs) {
    final hit = index.find(song);
    if (grow) index.add(song);
    if (hit == null) {
      none++;
      continue;
    }
    final (layer, partner) = hit;
    counts[layer] = counts[layer]! + 1;
    final differentIds =
        song.trackId != null &&
        partner.trackId != null &&
        song.trackId != partner.trackId;
    if (layer.usesText && differentIds) conflicts++;
    if (layer.usesText && samples[layer]!.length < _sampleLimit) {
      samples[layer]!.add(
        '${song.label} (${song.seconds} s) ~ ${partner.label} '
        '(${partner.seconds} s)${differentIds ? ' [other track_id]' : ''}',
      );
    }
  }
  print('\n$title: ${songs.length} songs');
  for (final layer in Layer.values) {
    print('  ${layer.label}: ${counts[layer]}');
  }
  print('  no partner: $none');
  print('  text layers where both have a track_id and they differ: $conflicts');
  for (final layer in Layer.values) {
    if (samples[layer]!.isEmpty) continue;
    print('  -- ${layer.label}:');
    for (final line in samples[layer]!) {
      print('     $line');
    }
  }
}

/// Says whether songs that share one of VK's ids really are one song: groups
/// them by [idOf], then counts the groups whose text and length agree. A group
/// that disagrees would show as the wrong song if it were merged.
void reportIdGroups(
  String title,
  List<Song> songs,
  String? Function(Song) idOf,
) {
  final groups = <String, List<Song>>{};
  for (final song in songs) {
    if (idOf(song) case final id?) (groups[id] ??= []).add(song);
  }
  var agree = 0;
  var otherLength = 0;
  var otherText = 0;
  final samples = <String>[];
  for (final group in groups.values.where((group) => group.length > 1)) {
    final first = group.first;
    final sameText = group.every((song) => song.text == first.text);
    final longest = group.fold(
      0,
      (gap, song) => gap > _gap(song, first) ? gap : _gap(song, first),
    );
    final near = longest <= _lengthToleranceSeconds;
    if (sameText && near) {
      agree++;
      continue;
    }
    sameText ? otherLength++ : otherText++;
    if (samples.length < _sampleLimit) {
      samples.add(
        group.map((song) => '${song.label} (${song.seconds} s)').join(' ~ '),
      );
    }
  }
  print('\n$title: ${agree + otherLength + otherText} groups');
  print('  same text and length: $agree');
  print('  same text, length differs: $otherLength');
  print('  other text: $otherText');
  for (final line in samples) {
    print('     $line');
  }
}

/// Reads one account's whole library and prints what its songs carry.
Future<(int, List<Song>)> readAccount(String label, String sessionPath) async {
  final vk = VkClient(SessionCookie.loadAll(File(sessionPath)));
  await vk.ensureToken();
  final library = await fetchVkLibrary(vk.call, vk.userId);
  final songs = [for (final item in library.items) Song(item)];
  final blocked = library.items.where((item) => item['url'] == '').length;
  print(
    '$label: ${songs.length} listed of ${library.declaredCount} declared, '
    '$blocked with no stream, '
    '${songs.where((song) => song.trackId != null).length} with track_id, '
    '${songs.where((song) => song.releaseKey != null).length} with '
    'release_audio_id',
  );
  return (vk.userId, songs);
}

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final firstPath = option('--vk-session');
  if (firstPath == null) {
    stderr.writeln('--vk-session is required');
    exit(64);
  }
  final (firstId, first) = await readAccount('First account', firstPath);
  report('Inside the first account', first, SongIndex(), grow: true);

  final secondPath = option('--vk-session-2');
  if (secondPath != null) {
    final (secondId, second) = await readAccount('Second account', secondPath);
    if (secondId == firstId) {
      print('\nBOTH SESSIONS ARE THE SAME VK ACCOUNT: nothing to compare.');
      exit(1);
    }
    report('Inside the second account', second, SongIndex(), grow: true);
    final firstIndex = SongIndex();
    first.forEach(firstIndex.add);
    report('Second account against the first', second, firstIndex);
    final all = [...first, ...second];
    reportIdGroups('Songs sharing a track_id', all, (song) => song.trackId);
    reportIdGroups(
      'Songs sharing a release_audio_id',
      all,
      (song) => song.releaseKey,
    );
  }
  exit(0);
}
