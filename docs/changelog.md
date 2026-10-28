---
title: Changelog
---

# Changelog

## v0.2.0 {#v0-2-0}

### Defaults

Existing schemas do not need additional settings. `Validate = Off`, `TypeBranding = Off`, and `DecodeStruct = Locals` remain unchanged. New batch, receive, decode-work and polling limits default to `0` (disabled). Per-event rate/size limits and delta compression are enabled only when declared.

### Added

- Optional reliable-event `Compression: Repeat` and `Compression: Fields`, with recipient baselines and full-body fallback/reset handling.
- Optional per-event `Rate`, `Burst`, and `Max` properties, plus shared per-player call, byte and message receive budgets.
- Optional limits for batch bytes/messages, decode work, unreliable buffers and polling queues.
- CLI output now includes the original `Schema.idl` and `CompileInfo.txt` alongside the runtime modules. The plugin retains a commented `Schema` reference.

### Changed

- Scoped generated event/function declarations reduce pressure on Luau's active-local limit for larger schemas.
- Reliable server sends to individual recipients are batched while preserving targeted-send/broadcast order.
- Faster Boolean collection packing and fixed-size numeric array/struct decoding, with fewer repeated checks and table-growth operations.
- Exact-length strings/collections omit redundant length prefixes. Ranged lengths encode their offset from the minimum where supported.
- Receive-side structural checks and allocation checks apply even with validation off. Arrays enforce the supported 65,535-element maximum. Operational budgets remain optional.
- Polling iterators return an index before the player/payload arguments.

### Fixed

- Listener disconnection and slot reuse during dispatch, including reentrant handlers.
- Partial serialization failures no longer leave a partially committed outgoing event.
- Compression baseline isolation for recipients, late joins, player removal and rejected client batches.
- Yielding client reliable handlers cannot reorder compression baseline updates.
- Half-float rounding, signed zero, and numeric/vector bounds handling.
- Duplicate API names, reserved root names and invalid parameter names fail compilation.
- Studio output class conflicts stop compilation output without deleting conflicting objects.
- Extracted Unix CLI files are cleaned up after normal success or failure.

### Migration

1. Regenerate and replace **Server, Client and Types together** with v0.2.0. Some binary encodings changed; do not mix versions. There is no wire-version handshake.
2. Add the iterator index to polling loops: client `for _, value in Event.Iter() do`; server `for _, player, value in Event.Iter() do`.
3. Keep existing schemas as they are if no new limits or compression are wanted. Read [options](/options) before opting in.
4. If an application sends arrays larger than 65,535 elements, split them into supported payloads. This type-size ceiling is separate from optional traffic limits.
5. If client reliable handlers yield, do not depend on one handler finishing before the next starts. With compression present, those handlers run in protected tasks.

Performance depends on payload shape, repetition and load. Smaller NetRay buffers are measured before Roblox transport compression; this release does not promise a universal FPS or bandwidth percentage.

## v0.1.1

- Expanded IDL type coverage, event call-mode APIs, parser/analyzer capabilities, and runtime generation performance.

### Added
- New IDL type support: `f16`, `buffer`, `vector`/`vector3`, `cframe`, `brickcolor`, `color3`, `datetime`, `datetimemillis`, `instance(...)`, and `unknown`.
- `set` declarations and tagged enums (`enum Name { ... }` with default `Type` tag, or `enum Name = Tag { ... }` / `enum Name = "tag-name" { ... }`).
- Inline type declarations in schemas (`struct { ... }`, inline `enum { ... }`).
- `fixedarray<T, N>` support plus shorthand forms like `T[N]`.
- Map shorthand support (`{[K]: V}`).
- Extended bounds syntax for numeric/string/collection types (range-style and bracket forms).
- `option remote_scope = ...` support in compiler scope resolution.

### Changed
- Parser/analyzer improvements across type resolution, declaration analysis, and option handling.
- Event call-mode generation updates (`SingleSync`, `ManySync`, `SingleAsync`, `ManyAsync`, `Polling` with `Iter()`).
- Blink-style event/function block parsing is now supported alongside legacy syntax.
- Function `Yield` parsing remains restricted to `SingleSync` in current generator behavior.
- Runtime generation improvements (segmented queue batching, canonical encode/decode paths, stricter validation flow).
- Generator architecture has been split into dedicated modules (`Runtime`, `Emitters`, `EmitTypes`, `Utilities`, `Types`) for maintainability.
- Lower byte usage per payload, including reduced metadata overhead in bounded collections.

### Performance
- Lower bandwidth usage (approximately `~1-2%` for reliable and unreliable paths).
- Decoding speed has improved significantly.
- Encoding speed has improved slightly.
- Lower packet byte usage overall.

## v0.1.0

Initial public baseline for the Roblox Studio plugin workflow.

### Included
- Core IDL schema parsing for `option`, `scope`, `struct`, `enum`, `event`, and `function`.
- Generation of `Server`, `Client`, and `Types` modules under `ReplicatedStorage`.
- Reliable/unreliable event channels and request/response function APIs.
- Validation option levels (`Off`, `Basic`, `Full`) and generated typed Luau API surface.
