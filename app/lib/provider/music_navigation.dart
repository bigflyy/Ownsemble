enum MusicRoute { music, feed, other }

MusicRoute classifyMusicRoute(Uri? uri) {
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !['vk.ru', 'vk.com'].contains(uri.host)) {
    return MusicRoute.other;
  }
  if (RegExp(r'^/(?:audios\d*|audio|music)(?:/|$)').hasMatch(uri.path)) {
    return MusicRoute.music;
  }
  return ['', '/', '/feed', '/feed/'].contains(uri.path)
      ? MusicRoute.feed
      : MusicRoute.other;
}

// Keep only a route category, never an authentication URL or page contents.
class MusicNavigation {
  MusicRoute route = MusicRoute.other;
  bool _redirectedFeed = false;
  bool isBlankDocument = false;
  bool get isMusic => route == MusicRoute.music;

  void observe(Uri? uri) {
    isBlankDocument =
        uri == null || uri.scheme == 'about' && uri.path == 'blank';
    route = classifyMusicRoute(uri);
    if (route != MusicRoute.feed) _redirectedFeed = false;
  }

  Future<bool> refresh({
    required Future<Uri?> Function() readUrl,
    required Future<void> Function() openMusic,
  }) async {
    observe(await readUrl());
    if (route == MusicRoute.feed && !_redirectedFeed) {
      // One attempt per feed visit prevents loops if VK redirects back.
      _redirectedFeed = true;
      await openMusic();
      observe(await readUrl());
    }
    return isMusic;
  }
}
