'use strict';

function parseControl(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some((key) => !['command', 'nonce'].includes(key)) ||
      !['run', 'stop'].includes(value.command) ||
      typeof value.nonce !== 'string' || !/^[a-f0-9-]{36}$/.test(value.nonce)) return null;
  return { command: value.command, nonce: value.nonce };
}

function failureCategory(error) {
  const message = String(error?.message || '');
  const hlsCategory = ['hls_http_400', 'hls_http_401', 'hls_http_403', 'hls_http_404', 'hls_http_429',
    'hls_protocol_rejected', 'hls_extension_rejected', 'hls_key_unavailable', 'hls_tls_failed',
    'hls_invalid_data', 'hls_option_unsupported', 'hls_codec_unsupported', 'hls_segment_unavailable',
    'hls_access_denied', 'hls_dns_failed', 'hls_connection_failed', 'hls_output_failed',
    'hls_input_failed', 'hls_download_failed'].find((category) => message.includes(category));
  if (hlsCategory) return hlsCategory;
  if (/Full offline audio decoding failed/i.test(message)) return 'audio_full_decode_failed';
  if (/not a readable audio file/i.test(message)) return 'audio_container_unreadable';
  if (/contains no audio stream/i.test(message)) return 'audio_stream_missing';
  if (/shorter than VK metadata/i.test(message)) return 'audio_incomplete_or_preview';
  if (/hash differs/i.test(message)) return 'audio_hash_mismatch';
  if (/(?:FFprobe|FFmpeg).*(?:not found|required)/i.test(message)) return 'decoder_unavailable';
  if (/cancelled/i.test(message)) return 'cancelled';
  if (/sign.in|login|outside music|Open My music/i.test(message)) return 'private_signin_or_music_page_required';
  if (/multiple|ambiguous/i.test(message)) return 'audio_source_ambiguous';
  if (/obscured|outside the viewport|viewport changed/i.test(message)) return 'playback_control_not_visible';
  if (/play control|playback region/i.test(message)) return 'playback_control_unsupported';
  if (/did not expose|audio source/i.test(message)) return 'audio_source_unavailable';
  if (/player_/i.test(message)) {
    return ['player_timeout', 'player_decode_failed', 'player_did_not_advance', 'player_seek_failed']
      .find((category) => message.includes(category)) || 'player_failed';
  }
  if (/decode|duration|audio file|cache|hash/i.test(message)) return 'audio_validation_failed';
  if (/timed out|timeout/i.test(message)) return 'timed_out';
  return 'operation_failed';
}

async function onlineProof({ candidates, download, verify, player, emit, shouldStop = () => false }) {
  let lastCategory = 'no_music_tracks';
  for (const [index, track] of candidates.slice(0, 3).entries()) {
    const checkStop = () => { if (shouldStop()) throw new Error('cancelled'); };
    try {
      checkStop();
      emit('automated_proof_stage', { stage: 'source_and_cache', attempt: index + 1 });
      await download(track);
      checkStop();
      emit('automated_proof_stage', { stage: 'local_decode', attempt: index + 1 });
      await verify(track);
      checkStop();
      emit('automated_proof_stage', { stage: 'player_online', attempt: index + 1 });
      const result = await player(track);
      if (!result.passed) throw new Error(result.category || 'player_failed');
      return { track, attempts: index + 1 };
    } catch (error) {
      lastCategory = failureCategory(error);
      emit('automated_proof_attempt_failed', { attempt: index + 1, category: lastCategory });
      if (['cancelled', 'private_signin_or_music_page_required'].includes(lastCategory)) break;
    }
  }
  return { failed: true, category: lastCategory };
}

module.exports = { parseControl, failureCategory, onlineProof };
