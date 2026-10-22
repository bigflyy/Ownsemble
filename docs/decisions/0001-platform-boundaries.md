# ADR 0001: tested boundaries for platform mechanisms

Status: accepted for the architecture milestone selected by the user, 2026-10-22.

Shared Flutter UI and Dart algorithms did not make VK portable: VK policy called
Windows DevTools directly, AppController constructed concrete provider/player
objects, and caches selected Windows certificate fallback themselves.

Use constructor injection and explicit provider/browser/playback/runtime/trust
contracts. Choose implementations in a composition root. Preserve current storage,
identity/privacy rules and Windows native behavior. Retain the browser package
pin/patch while extracting it. A dependency upgrade is a separately validated
adapter change, not an untested part of this refactor.

VK parsing/sync/resolution and its dependency graph remain pure Dart. Require
mandatory browser capabilities before opening a page and verify native mute at
runtime. Use typed input/playback/clock operations; hide raw plugin objects and
DevTools details inside adapters. Use connection generations and bounded cleanup
so stale or failed documents cannot resurrect or alter later connections.

Keep SQLite as the actual repository. Avoid an extra DI framework, global service
locator, generic base repository or speculative microservice. Preserve the current
controller/UI facade while extracting concrete native responsibilities. Enforce
dependency direction with tests and run shared generated policy on Linux/Windows.
Prove native capabilities independently on every target OS.

This allows a target adapter to change without duplicating queue, cache, sync or
identity logic. Tests inject provider/player implementations without inheriting
native plugins. No user data, schema or saved files are rewritten by the refactor.

Interfaces are not completed ports. Linux/Android production browser, packaging,
background playback and real-provider acceptance are not certified by this ADR.
The upstream Linux package is a feasibility candidate. Cache relocation and
multi-source identity/provenance need explicit additive contracts/migrations;
future providers must not bypass current destination and recording-ID guards.

See ARCHITECTURE.md and PLATFORM_PORTABILITY.md for implementation and acceptance.
