import 'package:media_kit/media_kit.dart';

import '../contracts/playback_engine.dart';
import 'media_kit_audio.dart';

/// media_kit supports native desktop/mobile; its concrete API stays here.
class MediaKitPlayback implements PlaybackEngine {
  final Player _player;
  MediaKitPlayback(this._player);
  @override
  PlaybackState get state => PlaybackState(
    playing: _player.state.playing,
    buffering: _player.state.buffering,
    completed: _player.state.completed,
    position: _player.state.position,
    duration: _player.state.duration,
    buffer: _player.state.buffer,
    volume: _player.state.volume,
  );
  @override
  PlaybackEvents get stream => PlaybackEvents(
    playing: _player.stream.playing,
    buffering: _player.stream.buffering,
    completed: _player.stream.completed,
    position: _player.stream.position,
    error: _player.stream.error,
    log: _player.stream.log.map(
      (entry) => PlaybackLog(entry.level, entry.text),
    ),
  );
  @override
  Future<void> openLocal(String path, {bool play = true}) =>
      openLocalAudio(_player, path, play: play);
  @override
  Future<void> openStream(Uri uri, {bool play = true}) =>
      openStreamingAudio(_player, uri, play: play);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<bool> isPaused() async =>
      await (_player.platform as NativePlayer).getProperty('pause') == 'yes';
  @override
  Future<double?> clockSeconds() async => double.tryParse(
    await (_player.platform as NativePlayer).getProperty('time-pos'),
  );
  @override
  Future<void> dispose() => _player.dispose();
}
