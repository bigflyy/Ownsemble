'use strict';

// A scan can stop on a virtualized list, a timeout, or a provider error. Missing
// rows therefore never delete existing library entries or their cached audio.
function mergeLibrary(existing, incoming) {
  const byID = new Map(existing.map((track) => [track.id, track]));
  const result = [];
  const seen = new Set();
  for (const track of incoming) {
    if (seen.has(track.id)) continue;
    seen.add(track.id);
    result.push({ ...byID.get(track.id), ...track });
  }
  return result.concat(existing.filter((track) => !seen.has(track.id)));
}

async function scanLibrary({ read, advance, reset, onProgress = () => {},
  maxPages = 250, idlePages = 4, idleTimeoutMs = 0, maxDurationMs = Infinity, now = Date.now,
  maxTracks = 50000, incremental = false, shouldStop = () => false }) {
  await reset();
  const tracks = new Map();
  let idle = 0;
  let pages = 0;
  let latest;
  const startedAt = now();
  let lastGrowthAt = now();
  let providerLoading = false;
  let stopReason = 'page_budget';
  while (pages < maxPages) {
    if (shouldStop()) { stopReason = 'cancelled'; break; }
    if (now() - startedAt >= maxDurationMs) { stopReason = 'time_budget'; break; }
    latest = await read();
    if (latest.error) throw new Error(latest.error);
    const before = tracks.size;
    for (const track of latest.tracks) {
      if (!tracks.has(track.id) && tracks.size >= maxTracks) break;
      tracks.set(track.id, track);
    }
    pages++;
    idle = before === tracks.size ? idle + 1 : 0;
    if (!idle) lastGrowthAt = now();
    const quietMs = Math.max(0, now() - lastGrowthAt);
    onProgress({ count: tracks.size, pages, idle, quietMs, loading: providerLoading });
    if (tracks.size >= maxTracks) { stopReason = 'track_budget'; break; }
    if (idle >= idlePages && quietMs >= idleTimeoutMs && !providerLoading) { stopReason = 'no_new_rows'; break; }
    if (incremental && pages >= 2) { stopReason = 'incremental'; break; }
    providerLoading = (await advance({ idle, pages, count: tracks.size }))?.loading === true;
  }
  // Repeated stable rows are useful evidence, but not proof of the provider's
  // library total. Do not label this a verified complete account import.
  return { tracks: [...tracks.values()], pages, stopReason, complete: false,
    userId: latest?.userId, userAgent: latest?.userAgent };
}

module.exports = { mergeLibrary, scanLibrary };
