import 'dart:convert';

import '../media/audio_policy.dart';

// VK's public music-link encoding, also used by the preserved Python reference:
// https://github.com/python273/vk_api/blob/master/vk_api/audio_url_decoder.py
// All work stays in app memory. A decoded value must still pass the CDN guard.
Uri? decodeAudioSource(String value, int userId) {
  if (value.length > 16000) return null;
  var uri = Uri.tryParse(value);
  if (uri != null && uri.host.endsWith('.')) {
    uri = uri.replace(host: uri.host.substring(0, uri.host.length - 1));
  }
  if (uri == null) return null;
  if (audioCandidate(uri)) return uri;
  if (uri.scheme != 'https' ||
      !['vk.ru', 'vk.com'].contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.path != '/mp3/audio_api_unavailable.mp3') {
    return null;
  }
  try {
    final payload = RegExp(r'(?:^|&)extra=([^&]+)')
        .firstMatch(uri.query)
        ?.group(1);
    if (payload == null) return null;
    var decoded = _decode(Uri.decodeComponent(payload));
    final operations = _decode(Uri.decodeComponent(uri.fragment));
    if (operations.length > 2048) return null;
    for (final operation in operations.split('\t').reversed) {
      if (operation.isEmpty) continue;
      final fields = operation.split('\v');
      final arg = fields.length == 2 ? fields[1] : null;
      switch (fields[0]) {
        case 'v':
          if (fields.length != 1) return null;
          decoded = decoded.split('').reversed.join();
        case 'x':
          if (arg == null || arg.isEmpty) return null;
          decoded = String.fromCharCodes(
            decoded.codeUnits.map((c) => c ^ arg.codeUnitAt(0)),
          );
        case 'r':
          final amount = int.tryParse(arg ?? '');
          if (amount == null || amount < 0 || amount >= _alphabet.length) {
            return null;
          }
          decoded = decoded.split('').map((c) {
            final index = _alphabet.indexOf(c);
            return index < 0
                ? c
                : _alphabet[(index - amount) % _alphabet.length];
          }).join();
        case 's':
        case 'i':
          var seed = int.tryParse(arg ?? '');
          if (seed == null || fields[0] == 'i' && userId <= 0) return null;
          if (fields[0] == 'i') seed = (seed ^ userId).toSigned(32);
          final n = decoded.length;
          if (n == 0) return null;
          final swaps = List<int>.filled(n, 0);
          for (var i = n - 1; i >= 0; i--) {
            seed = ((n * (i + 1)) ^ (seed! + i)) % n;
            swaps[i] = seed;
          }
          final letters = decoded.split('');
          for (var i = 1; i < n; i++) {
            final other = swaps[n - 1 - i];
            final old = letters[other];
            letters[other] = letters[i];
            letters[i] = old;
          }
          decoded = letters.join();
        default:
          return null;
      }
    }
    final source = Uri.tryParse(decoded);
    return source != null && audioCandidate(source) ? source : null;
  } catch (_) {
    return null;
  }
}

const _alphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN0PQRSTUVWXYZO123456789+/=';
String _decode(String value) {
  if (value.isEmpty) return '';
  const standard =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  final translated = StringBuffer();
  for (final c in value.split('')) {
    final index = _alphabet.indexOf(c);
    if (index < 0) throw const FormatException('Invalid music encoding');
    translated.write(standard[index]);
  }
  return String.fromCharCodes(
    base64Decode(base64.normalize(translated.toString())),
  );
}
