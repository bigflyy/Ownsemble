# VK pagination repair checkpoint

Music pages can scroll a nested pane rather than the outer document. Hidden
player copies can also appear after the actual music list in DOM order. Moving
the outer window or the final DOM node can therefore leave import at the same
small batch indefinitely.

Pagination now considers rendered recognized recording rows, finds their nearest
scrollable ancestors and selects the pane containing the largest row group.
Retry movements and forward movements use that same pane. Layouts using the
document scrollbar retain their existing behavior. Hidden player copies are not
chosen as the final row.

At most three stalled-pagination probes per scan slice report numeric layout
counts. The Dart boundary accepts only named, finite, nonnegative counters within
the fixed numeric budget. Counts describe rows, scroll geometry, clipping and
document visibility; diagnostics exclude recording identities, titles, account
details and temporary URLs. Each diagnostic request has a two-second deadline.

## Validation and limits

The nested-pane and trailing-hidden-row regressions failed before their respective
corrections. The bounded-diagnostics tests also failed before implementation.
All 51 Node adapter tests and all 207 Windows Flutter tests pass at the combined
checkpoint; the Windows analyzer is clean. The adapter asset is regenerated from
its reviewed sources.

An additional generated native Linux check verified IntersectionObserver delivery
in an inactive document that had never been shown. It supplements the earlier
browser qualification; it does not certify actual VK import or audible output.
The preceding Linux candidate built and passed its generated browser check.
The latest Windows-specific registration repair has not been rebuilt on Linux.

Authorized Windows verification retained all 2,633 existing records. The new scan
progressed through rendered music rows beyond the earlier 115-row boundary, but a
later slice stopped after 895 distinct recordings at a quiet boundary. The result
remains partial. Neither a quiet boundary nor a stored catalog count proves a
complete current provider listing, and unseen records are never deleted.

Native Ubuntu audio acceptance is deferred. WSLg's audio service independently
became unresponsive; restarting it restored cached playback, but the user still
reported intermittent pauses. No WSLg workaround has been installed in the app.
The incomplete-listing problem remains open independently of that audio failure.
