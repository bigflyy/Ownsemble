# Keyboard usability

Requested 2026-10-22 as an extension of the completed controls/UI slice. This adds
application-focused shortcuts, discoverable hover hints and an F1 reference. It
does not register system-wide hotkeys or start another backlog milestone.

## Bindings

| Action | Shortcut |
| --- | --- |
| Play/pause; cancel current loading | Space |
| Mute/unmute | Ctrl+M |
| Previous/next song | Ctrl+Left / Ctrl+Right |
| Volume down/up by 5% | Ctrl+Down / Ctrl+Up |
| Seek back/forward 5 seconds | Alt+Left / Alt+Right |
| Stop | Ctrl+. |
| Toggle shuffle | Ctrl+Shift+S |
| Cycle repeat mode | Ctrl+Shift+R |
| Open queue | Ctrl+Shift+Q |
| Focus search | Ctrl+K |
| Leave search without clearing the query | Escape |
| Show shortcut reference | F1 or the keyboard icon beside Settings |
| Close a dialog or queue | Escape |

Definitions, control hints and reference rows share app_shortcuts.dart. The main
player, selected row, seek/volume sliders, search and queue show applicable hints.
Library-level Play/Shuffle do not claim the current-player shortcuts because those
buttons start a library selection instead of toggling the current transport mode.

## Input behavior

- Playback shortcuts yield to all focused text editors, including word-navigation
  chords. Search and Pile naming retain spaces and normal editing behavior.
- Ctrl+K and F1 remain reserved on the active library screen while typing. Escape
  leaves the search editor and returns keyboard focus to the library, preserving
  the query, pending debounce and filtered results. Ctrl+K restores search focus.
  A front dialog/popup keeps Escape priority; a second press can leave search
  after the surface closes. Escape does not clear another editor or change songs.
  Other modal routes keep their own keyboard handling; no actions run behind a dialog.
- Space activates a focused button normally; the global playback action applies
  when focus is on the library surface. It does not steal text-entry Space.
- Only volume and seek repeat when held. Mute, next/previous, shuffle, repeat mode,
  Stop and opening surfaces do not repeat accidentally.
- Modifier combinations match exactly; AltGr/extra Shift/Meta do not accidentally
  trigger another command. Physical letter-key fallbacks support the same chord
  with Cyrillic logical labels; this is covered by a synthetic matching fixture,
  not a claim of automated OS keyboard-layout switching.
- Seeking is bounded to the current duration and disabled during preparation or
  without a selected recording. Previous/next/Stop honor selection availability.
- All commands call existing controller actions and retain recording/cache/privacy
  contracts. Optional metadata never participates in keyboard dispatch.

## Acceptance

Meaningful regression tests were observed failing before implementation in
.local/ownsemble/shortcuts-red.txt, including the pre-existing Ctrl+Left word-editing
and focused-button Space conflicts. Subsequent tests also cover dialog naming,
unavailable transport actions, physical-key matching, held keys and actual hover
hint rendering. Final suite/build/native evidence belongs in the latest handoff;
source edits are not accepted merely because a shortcut table exists.

Follow-up 2026-10-22: two Escape regressions were observed failing before the
focus change (search-escape-red.txt). The tests cover a still-pending search,
query/results retention, Space returning to playback, Ctrl+K returning to editing,
and front-dialog priority.166 Flutter tests now pass; analyzer/format clean. The
adapter source is unchanged; all 48 adapter tests were rerun and passed. See the latest
handoff for final rebuilt-app evidence.

Final keyboard-slice checks: 164 Flutter tests and 48 adapter tests pass; analyzer
and formatter clean. Both Debug and Release builds match the bundled adapter and
are newer than production Dart. Both modes passed generated native playback,
mute/unmute, remembered-volume restart, queue and retention checks. The generated
reference preview .local/ownsemble-smoke/shortcuts-preview.png was viewed. These
combine widget/key-dispatch and native-controller checks; they are not an automated
OS keyboard-layout change or a guarantee about every provider recording.

Final normal Release cached main-player controls/replay also passed: 721 ms first
audio, zero received bytes, paused afterward with the original volume preserved.
This is a cached regression sample, not a fix or timing claim for the separately
reported uncached-start delay. Consolidated evidence is
.local/ownsemble/shortcuts-validation.json.

## Recommended next stage

Stage 2 is a measured responsiveness pass: reproduce large-queue scrolling and
three-dot-menu latency using generated large libraries; record local click/frame
baselines before optimization. The user additionally reported several MB received
without sound and requested earlier streaming startup as a logged proposal. Add
first-audio stage measurements (source, prefix, verification, native buffering,
output, cache completion), then optimize the proven bottleneck. Separate network
conditions from local overhead and retain recording identity/offline integrity.

This performance stage and the confirmed VK-lyrics extraction bug remain queued;
logging either request did not interrupt keyboard usability work.
