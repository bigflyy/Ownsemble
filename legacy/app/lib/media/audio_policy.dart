import 'dart:convert';

class ProofFailure implements Exception {
  final String category;
  final int? code;
  const ProofFailure(this.category, {this.code});
  @override
  String toString() => category;
}

/// Describe a rejected media destination with fixed flags, never its URL.
class AudioDestinationFailure extends ProofFailure {
  // Keep only structural flags and matches against public, fixed service suffixes.
  final Map<String, Object> diagnostic;

  /// Capture safe destination shape while preserving the existing failure category.
  AudioDestinationFailure(Uri destination, {required bool redirect})
    : diagnostic = {
        'redirect': redirect,
        'https': destination.scheme == 'https',
        'http': destination.scheme == 'http',
        'userinfo': destination.userInfo.isNotEmpty,
        'port': destination.hasPort,
        'trailing_dot': destination.host.endsWith('.'),
        for (final suffix in [
          ...cdnSuffixes,
          'vk.com',
          'vk.ru',
          'mycdn.me',
          'okcdn.ru',
          'vkuser.net',
          'vkusercdn.net',
          'vkcdn.audio',
        ])
          'suffix_$suffix':
              destination.host == suffix ||
              destination.host.endsWith('.$suffix'),
      },
      super('audio_destination_rejected');
}

class Track {
  final String id, title, artist;
  final double duration;
  const Track(this.id, this.title, this.artist, this.duration);
  factory Track.fromJson(Map<String, dynamic> value) {
    final id = value['id'];
    final title = value['title'];
    final artist = value['artist'];
    final duration = value['duration'];
    if (id is! String ||
        !RegExp(r'^-?\d+_\d+$').hasMatch(id) ||
        title is! String ||
        title.length > 1000 ||
        artist is! String ||
        artist.length > 1000 ||
        duration is! num ||
        !duration.isFinite ||
        duration < 0 ||
        duration > 86400) {
      throw const ProofFailure('invalid_music_metadata');
    }
    return Track(id, title, artist, duration.toDouble());
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'duration': duration,
  };
}

const cdnSuffixes = [
  'vkuseraudio.net',
  'vkuseraudio.com',
  'vkuseraudio.ru',
  'useraudio.com',
  'userapi.com',
  'vk-cdn.net',
  'vk-cdn.me',
  'okcdn.ru',
];
bool allowedAudio(Uri uri, {int? fixturePort}) {
  if (fixturePort != null &&
      uri.scheme == 'http' &&
      uri.host == '127.0.0.1' &&
      uri.port == fixturePort) {
    return true;
  }
  return uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      cdnSuffixes.any((s) => uri.host == s || uri.host.endsWith('.$s'));
}

/// Recognize conventional audio names before using bounded content detection.
bool hasAudioFilename(Uri uri) =>
    RegExp(r'\.(mp3|m4a|m3u8|wav)$', caseSensitive: false).hasMatch(uri.path);

/// Detect HLS from a small response prefix without trusting URL extensions.
bool isHlsPrefix(List<int> bytes) => utf8
    .decode(bytes.take(64).toList(), allowMalformed: true)
    .replaceFirst('\uFEFF', '')
    .trimLeft()
    .startsWith('#EXTM3U');

/// Accept opaque OK CDN endpoints only inside the existing HTTPS authority guard.
bool audioCandidate(Uri uri) =>
    allowedAudio(uri) &&
    (RegExp(r'\.(mp3|m4a|m3u8)$', caseSensitive: false).hasMatch(uri.path) ||
        uri.host == 'okcdn.ru' ||
        uri.host.endsWith('.okcdn.ru'));
Uri selectSource(
  Set<Uri> candidates, {
  bool requireBinding = false,
  Uri? boundSource,
}) {
  if (requireBinding) {
    if (boundSource == null || !audioCandidate(boundSource)) {
      throw const ProofFailure('audio_identity_unverified');
    }
    return boundSource;
  }
  final valid = candidates.where(audioCandidate).toList();
  if (valid.isEmpty) throw const ProofFailure('audio_source_not_resolved');
  if (valid.length != 1) throw const ProofFailure('audio_source_ambiguous');
  return valid.single;
}

void verifyRecordingDuration(double actual, double expected) {
  if (!actual.isFinite ||
      actual <= 0 ||
      expected > 0 && actual < expected - 5) {
    throw const ProofFailure('audio_incomplete');
  }
  if (expected > 0 && actual > expected + 5) {
    throw const ProofFailure('audio_duration_mismatch');
  }
}

const recordingEvidenceKinds = [
  'metadata_row',
  'exact_reload',
  'native_player',
];

// Return only fixed categories. Never serialize an exception/HTTP response URL.
String categoryOf(Object error) =>
    error is ProofFailure ? error.category : 'operation_failed';
Map<String, dynamic> decodeMap(dynamic result) {
  if (result is String) result = jsonDecode(result);
  if (result is! Map) throw const ProofFailure('adapter_response_invalid');
  final map = Map<String, dynamic>.from(result);
  if (map['error'] != null) {
    final text = map['error'].toString();
    throw ProofFailure(
      RegExp(
            r'sign.in|login|Open the VK music',
            caseSensitive: false,
          ).hasMatch(text)
          ? 'private_signin_required'
          : 'music_adapter_unsupported',
    );
  }
  return map;
}

(String, String)? parseControl(String text, String? previous) {
  if (text.length > 1024) return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map ||
        value.length != 2 ||
        value.keys.any((k) => !['command', 'nonce'].contains(k)) ||
        !['run', 'selftest', 'stop', 'restart'].contains(value['command']) ||
        value['nonce'] is! String ||
        !RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['nonce']) ||
        value['nonce'] == previous) {
      return null;
    }
    return (value['command'] as String, value['nonce'] as String);
  } catch (_) {
    return null;
  }
}

// Native libraries can include local paths/temporary URLs in their errors.
// Return only fixed categories and retain the most specific observed issue.
const decoderCategories = [
  'decoder_media_error',
  'decoder_no_audio_stream',
  'decoder_open_failed',
  'decoder_format_unrecognized',
  'decoder_option_invalid',
  'decoder_file_missing',
  'decoder_file_denied',
  'decoder_invalid_data',
  'decoder_codec_unavailable',
  'decoder_segment_unreadable',
  'decoder_decryption_failed',
  'decoder_key_unreadable',
  'decoder_extension_rejected',
  'decoder_protocol_rejected',
];
String classifyDecoderFailure(String message, [String? previous]) {
  final text = decoderMessageText(message);
  final category = text.contains('whitelist')
      ? 'decoder_protocol_rejected'
      : text.contains('extension') &&
            (text.contains('allowed') ||
                text.contains('mismatch') ||
                text.contains('blocked'))
      ? 'decoder_extension_rejected'
      : text.contains('key') &&
            (text.contains('unable') ||
                text.contains('failed') ||
                text.contains('could not'))
      ? 'decoder_key_unreadable'
      : text.contains('decrypt') || text.contains('bad decrypt')
      ? 'decoder_decryption_failed'
      : text.contains('segment') &&
            (text.contains('failed') ||
                text.contains('error') ||
                text.contains('unable'))
      ? 'decoder_segment_unreadable'
      : text.contains('decoder') &&
            (text.contains('not found') ||
                text.contains('not available') ||
                text.contains('unsupported'))
      ? 'decoder_codec_unavailable'
      : text.contains('invalid data')
      ? 'decoder_invalid_data'
      : text.contains('permission denied') || text.contains('access denied')
      ? 'decoder_file_denied'
      : text.contains('no such file')
      ? 'decoder_file_missing'
      : text.contains('option') &&
            (text.contains('error') ||
                text.contains('not found') ||
                text.contains('unknown'))
      ? 'decoder_option_invalid'
      : text.contains('failed to recognize')
      ? 'decoder_format_unrecognized'
      : text.contains('failed to open') ||
            text.contains('cannot open') ||
            text.contains('could not open')
      ? 'decoder_open_failed'
      : text.contains('no video or audio') || text.contains('no audio or video')
      ? 'decoder_no_audio_stream'
      : 'decoder_media_error';
  return previous != null &&
          decoderCategories.indexOf(previous) >
              decoderCategories.indexOf(category)
      ? previous
      : category;
}

// A fixed vocabulary encoded as bits preserves context without exporting native
// text, file paths, URLs, identifiers, or any words outside this list.
const decoderSignals = [
  'failed to recognize',
  'file format',
  'lavf',
  'hls',
  'key',
  'decrypt',
  'segment',
  'protocol',
  'whitelist',
  'extension',
  'option',
  'permission denied',
  'not found',
  'no such file',
  'open',
  'invalid',
  'cache',
  'codec',
  'audio',
  'video',
  'stream',
  'duration',
  'eof',
  'header',
];
int decoderSignalMask(String message) {
  final text = decoderMessageText(message);
  var mask = 0;
  for (var i = 0; i < decoderSignals.length; i++) {
    if (text.contains(decoderSignals[i])) mask |= 1 << i;
  }
  return mask;
}

String decoderMessageText(String message) => message
    .replaceAll(RegExp(r'\b(?:https?|file)://\S+', caseSensitive: false), '')
    .replaceAll(RegExp(r'\b[A-Za-z]:[\\/]\S+'), '')
    .toLowerCase();

class HlsLine {
  final String text;
  final Uri? resource;
  final String? resourceKind;
  const HlsLine(this.text, [this.resource, this.resourceKind]);
}

class HlsPlan {
  final List<HlsLine> lines;
  final Uri? variant;
  const HlsPlan(this.lines, [this.variant]);
}

HlsPlan parseHls(String text, Uri source) {
  if (text.length > 2 * 1024 * 1024 || !text.trimLeft().startsWith('#EXTM3U')) {
    throw const ProofFailure('hls_invalid_manifest');
  }
  final lines = const LineSplitter()
      .convert(text)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final variants = <(int, Uri)>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('#EXT-X-STREAM-INF:')) {
      final bandwidth =
          int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '',
          ) ??
          0;
      if (++i >= lines.length || lines[i].startsWith('#')) {
        throw const ProofFailure('hls_invalid_manifest');
      }
      variants.add((bandwidth, source.resolve(lines[i])));
    }
  }
  if (variants.isNotEmpty) {
    variants.sort((a, b) => b.$1.compareTo(a.$1));
    return HlsPlan(const [], variants.first.$2);
  }
  if (!lines.contains('#EXT-X-ENDLIST')) {
    throw const ProofFailure('hls_not_complete_vod');
  }
  final output = <HlsLine>[];
  var segments = 0;
  for (final line in lines) {
    if (!line.startsWith('#')) {
      if (++segments > 2000) throw const ProofFailure('hls_segment_budget');
      output.add(HlsLine(line, source.resolve(line), 'segment'));
    } else if (line.startsWith('#EXT-X-KEY:') ||
        line.startsWith('#EXT-X-MAP:')) {
      if (line.contains('BYTERANGE=')) {
        throw const ProofFailure('hls_byte_ranges_unsupported');
      }
      if (line.startsWith('#EXT-X-KEY:') &&
          !RegExp(r'(?:[:,])METHOD=(?:AES-128|NONE)(?:,|$)').hasMatch(line)) {
        throw const ProofFailure('hls_encryption_unsupported');
      }
      final match = RegExp(r'URI="([^"]+)"').firstMatch(line);
      if (match == null && !line.contains('METHOD=NONE')) {
        throw const ProofFailure('hls_invalid_manifest');
      }
      output.add(
        HlsLine(
          line,
          match == null ? null : source.resolve(match.group(1)!),
          line.startsWith('#EXT-X-KEY:') ? 'key' : 'init',
        ),
      );
    } else if (RegExp(
      r'^#(?:EXTM3U|EXTINF:|EXT-X-(?:VERSION:|TARGETDURATION:|MEDIA-SEQUENCE:|DISCONTINUITY(?:-SEQUENCE:)?$|DISCONTINUITY-SEQUENCE:|ENDLIST$|PLAYLIST-TYPE:|INDEPENDENT-SEGMENTS$))',
    ).hasMatch(line)) {
      output.add(HlsLine(line));
    } else if (RegExp(
      r'^#EXT-X-(?:BYTERANGE|GAP|I-FRAMES-ONLY|PART|PART-INF|SKIP|PRELOAD-HINT|RENDITION-REPORT|SERVER-CONTROL|SESSION-KEY|DEFINE)(?::|$)',
    ).hasMatch(line)) {
      // Known features that change fetching, completeness or decryption need
      // explicit support. Never silently turn a partial stream into a full one.
      throw const ProofFailure('hls_feature_unsupported');
    } else {
      // RFC 8216 section 6.3.1 requires ignoring unrecognized tags. Discard
      // advisory/vendor tags and comments rather than passing their possible
      // remote URI attributes to the local decoder. Only supported resource
      // types above are fetched and rewritten to complete local files.
      continue;
    }
  }
  if (segments == 0) throw const ProofFailure('hls_no_segments');
  return HlsPlan(output);
}
