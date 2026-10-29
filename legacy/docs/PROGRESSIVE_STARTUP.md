# Progressive MP3 startup

The 2026-10-24 generated native regression reproduced a complete-download wait
even though 64 KiB of valid MP3 frames were already available. Native requests
started at byte 0, then sought to the final 128 bytes, then returned to byte 0.
With the response tail held for six seconds, first native playback took 6,343 ms.

This matches FFmpeg's optional ID3v1 lookup: when the input is seekable and its
total size is known, it reads the final 128 bytes before returning to the beginning.
The relay supports byte ranges over a shared sequential download, so that probe
waited for every intervening byte. See the primary
[FFmpeg ID3v1 reader](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/id3v1.c).

For an unfinished progressive MP3's initial unbounded request, the relay now sends
a growing, chunked 200 response without advertising a complete content length.
HTTP permits ignoring a Range request and returning 200. Explicit bounded/nonzero
ranges still receive standard 206 responses. Completed resources, M4A and HLS keep
their existing framing. No bytes are changed, no second upstream request is made,
and full decoding, duration, recording identity and integrity still gate offline
publication. TLS, destination and token-scoped loopback checks are unchanged.

The same native fixture then started in 343 ms before the held tail was released.
Buffered seeking before tail release and seeking after completion both passed;
the native output driver was null and volume zero throughout. Encrypted HLS early
start, shared requests, complete validation and offline/local reopening also passed.
The existing nonfatal HLS decoder signal 4096 remains recorded.

The fixture is part of `--streaming-smoke`. It uses generated bundled audio only,
with a loopback proxy recording bounded numeric range offsets. Real account data
and private browser storage are never involved. The six-second gate is a controlled
regression, not a claim of identical savings for every VK song or network. Source
resolution, cold browser readiness and network latency remain separate costs.

## Silent Windows validation

Tests first reproduced the native stalled-tail and response-framing failures.
Additional native seek checks qualified both the growing and completed response.
All 238 Flutter tests, 68 adapter/diagnostic Node tests and 66 preserved probe/CLI
tests passed; Dart analysis was clean. Debug and Release builds passed. The Release
generated fixture started in 285 ms and passed early/late seeks, one upstream request,
encrypted HLS, full validation and offline/local reopening.

App-owned controls then tested real recordings with native volume confirmed zero.
No browser profiles, credentials, titles, recording IDs, media contents or temporary
URLs were inspected. These are sampled measurements on this host/network:

| Sample | Native playback startup | Additional evidence |
| --- | ---: | --- |
| Warm uncached | 1,584 ms | 96 KiB received at startup; 9.2 MB completed later |
| Uncached near old end | 3,287 ms | Exact binding; 17.6 MB completed later; source lookup 1,726 ms |
| Cached old samples | 530/618 ms | No upstream bytes; controls/local reopening passed |
| Fresh Release, uncached | 9,891 ms | Page readiness 6,519 ms; first network bytes 2,680 ms after transfer began |

The last row still has substantial cold browser/network latency. It must not be
represented as instant playback or a fixed upper bound for all environments.
Native volume remains zero and playback is stopped after verification.
