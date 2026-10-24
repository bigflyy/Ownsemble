# Progressive MP3 startup

The 2026-10-24 generated native regression reproduced a complete-download wait
even though64KiB of valid MP3 frames were already available. Native requests
started at byte0, then sought to the final128 bytes, then returned to byte0.
With the response tail held for six seconds, first native playback took6343ms.

This matches FFmpeg's optional ID3v1 lookup: when the input is seekable and its
total size is known, it reads the final128 bytes before returning to the beginning.
The relay supports byte ranges over a shared sequential download, so that probe
waited for every intervening byte. See the primary
[FFmpeg ID3v1 reader](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/id3v1.c).

For an unfinished progressive MP3's initial unbounded request, the relay now sends
a growing, chunked200 response without advertising a complete content length.
HTTP permits ignoring a Range request and returning200. Explicit bounded/nonzero
ranges still receive standard206 responses. Completed resources, M4A and HLS keep
their existing framing. No bytes are changed, no second upstream request is made,
and full decoding, duration, recording identity and integrity still gate offline
publication. TLS, destination and token-scoped loopback checks are unchanged.

The same native fixture then started in343ms before the held tail was released.
Buffered seeking before tail release and seeking after completion both passed;
the native output driver was null and volume zero throughout. Encrypted HLS early
start, shared requests, complete validation and offline/local reopening also passed.
The existing nonfatal HLS decoder signal4096 remains recorded.

The fixture is part of `--streaming-smoke`. It uses generated bundled audio only,
with a loopback proxy recording bounded numeric range offsets. Real account data
and private browser storage are never involved. The six-second gate is a controlled
regression, not a claim of identical savings for every VK song or network. Source
resolution, cold browser readiness and network latency remain separate costs.
