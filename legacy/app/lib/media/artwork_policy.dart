bool allowedArtwork(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    [
      'userapi.com',
      'vkuserphoto.ru',
      'vk-cdn.net',
      'vk-cdn.me',
    ].any((host) => uri.host == host || uri.host.endsWith('.$host'));
