# Switching away from a stalled source

A generated regression held the first provider source callback indefinitely, then
selected a second recording through normal controller Play. The second lookup
never started until the first callback returned. The serialized download lane
therefore made a stale selection part of the next selection's startup latency.

Download generations now wake provider connection/source waits when Stop, a newer
selection, offline mode or shutdown invalidates them. Each wait unsubscribes after
completion, and late results/errors remain observed without being accepted. A new
selection also cancels pending work before downloadId exists, covering connection
preparation. Browser cleanup runs independently of the newer selection.

Late candidate callbacks cannot start network preparation; obsolete resolutions
cannot alter recording bindings or shared timing fields. Cleanup clears progress
only while it still owns the active cache. Native Stop still precedes destruction
of the playing relay. Cache verification/publication and exact recording identity
remain required, and local saved music still bypasses unrelated network work.

The failing regression preceded the implementation. It now requires the second
lookup within a bounded 500 ms fixture window while the old source callback remains
pending, and checks that late cancellation cannot erase the new lookup state.
Existing startup-deadline, failure-cleanup, unavailable-song and shutdown tests also
pass. This bounds stale-request interference, not real network response time.
