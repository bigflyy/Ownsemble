String? metadataText(Object? value, [int limit = 1000]) {
  if (value is! String) return null;
  final text = value.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  return text.isEmpty || text.length > limit ? null : text;
}

Map<String, dynamic> sanitizeMetadata(Map value) {
  final result = <String, dynamic>{};
  for (final key in ['album', 'subtitle']) {
    final text = metadataText(value[key]);
    if (text != null) result[key] = text;
  }
  final artists = value['artists'];
  if (artists is List) {
    final names = artists
        .take(20)
        .map((a) => metadataText(a, 300))
        .whereType<String>()
        .toSet()
        .toList();
    if (names.isNotEmpty) result['artists'] = names;
  }
  for (final key in ['explicit', 'lyricsAvailable']) {
    if (value[key] is bool) result[key] = value[key];
  }
  final uploaded = value['uploadedAt'];
  if (uploaded is int &&
      uploaded >= 315532800 &&
      uploaded <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
    result['uploadedAt'] = uploaded;
  }
  final year = value['releaseYear'];
  if (year is int && year >= 1900 && year <= DateTime.now().year + 1) {
    result['releaseYear'] = year;
  }
  final lyricsId = value['lyricsId'];
  if (lyricsId is int && lyricsId > 0) result['lyricsId'] = lyricsId;
  // VK's generic date is upload time. No verified collection-addition field
  // exists in the current adapter; never relabel it as added/released.
  return result;
}

Map<String, dynamic>? sanitizeLyrics(Map? value) {
  if (value == null) return null;
  final text = metadataText(value['text'], 100000);
  if (text == null) return null;
  final lines = <Map<String, dynamic>>[];
  final raw = value['lines'];
  if (raw is List) {
    for (final line in raw.take(2000).whereType<Map>()) {
      final at = line['time_ms'], content = metadataText(line['text'], 2000);
      if (at is int && at >= 0 && at <= 86400000 && content != null) {
        lines.add({'time_ms': at, 'text': content});
      }
    }
    lines.sort((a, b) => (a['time_ms'] as int).compareTo(b['time_ms'] as int));
  }
  return {'text': text, 'lines': lines};
}

String displayMusicDate(DateTime? date) {
  if (date == null) return 'Unknown';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
