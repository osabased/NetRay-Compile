# Options

No options are required. An existing schema keeps `Validate = Off`, `TypeBranding = Off`, and `DecodeStruct = Locals`. New operational limits default to **0 (disabled)**. Delta compression is also off unless an event declares it.

## Validation and Types

| Option | Values | Default | Effect |
| :--- | :--- | :--- | :--- |
| `Validate` | `Off`, `Basic`, `Full` | `Off` | Controls additional payload validation. |
| `TypeBranding` | `Off`, `On` | `Off` | Emits plain numeric aliases or branded numeric types. |
| `DecodeStruct` | `Locals`, `Table` | `Locals` | Expands top-level struct arguments into callback arguments, or preserves their tables. |
| `remote_scope` | String or identifier | Compiler fallback, then `NetRay` | Names the three remotes; overrides the CLI/plugin fallback scope. |

`Validate = Off` still checks buffer boundaries, encoded lengths and tags needed to decode safely. `Basic` adds schema checks; `Full` adds type and shape checks. These checks do not validate gameplay permissions.

For a `struct Pose { x: f32, y: f32 }` argument, `Locals` receives `x, y`; `Table` receives one pose table. Structs inside arrays remain array elements.

```rust
option Validate = Full;
option DecodeStruct = Table;
option remote_scope = "Combat";
```

## Optional Batch and Work Limits

Omit these options, or set them to `0`, to disable the corresponding NetRay limit. Positive values must be integers no greater than `2,147,483,647`, subject to the additional restrictions below.

| Option | What a positive value limits |
| :--- | :--- |
| `MaxBatchBytes` | Bytes in reliable event buffers and RPC request/response buffers. Also bounds compression baseline bytes per cache. |
| `MaxBatchMessages` | Event messages per incoming batch and per outgoing queued batch. |
| `MaxDecodeWork` | Aggregate collection-element work while decoding/skipping an incoming server packet. Nested collections consume the same packet budget. |
| `MaxUnreliableBytes` | Bytes in an unreliable event buffer. Must be at most `1000`, and at most `MaxBatchBytes` when that limit is enabled. |
| `MaxPollingMessages` | Pending messages per polling event queue. A full queue drops newly arriving messages until it is drained. |

Outgoing queued batches flush early when an enabled batch limit would be exceeded. A single message larger than its enabled byte limit is rejected; NetRay does not split one event payload across packets. Incoming over-budget data can be dropped after earlier valid messages in the same batch have already been delivered.

These options limit NetRay buffers and work, not all Roblox transport overhead or passthrough arguments. Disabling a limit does not remove Roblox's own transport restrictions or the supported sizes of IDL types.

## Optional Server Receive Budgets

These budgets are per player and shared across that generated module's reliable events, unreliable events and RPC requests. They do not throttle outgoing server sends.

| Refill rate per second | Burst capacity | Unit |
| :--- | :--- | :--- |
| `ReceiveCallsPerSecond` | `ReceiveCallBurst` | Incoming remote invocations |
| `ReceiveBytesPerSecond` | `ReceiveByteBurst` | Bytes in incoming NetRay buffers |
| `ReceiveMessagesPerSecond` | `ReceiveMessageBurst` | Event records and RPC requests |

All six options default to `0`. Setting either member of a pair enables that budget; an omitted/zero counterpart takes the positive member's value. Rates may be fractional; explicit burst capacities must be integers. Tokens start at burst capacity and refill continuously using elapsed seconds.

Call and byte budgets are checked before payload decoding. Message budgets use each record or segment header before its payload is decoded. Rejected events are dropped; rejected RPC requests raise an error. Configure a burst large enough for a legitimate packet or segment to fit.

For example, this schema deliberately opts into limits; the numbers are an application policy, not NetRay defaults:

```rust
option MaxBatchBytes = 8192;
option MaxBatchMessages = 256;
option MaxDecodeWork = 4096;
option MaxUnreliableBytes = 900;
option MaxPollingMessages = 128;
option ReceiveCallsPerSecond = 60;
option ReceiveCallBurst = 120;
option ReceiveBytesPerSecond = 32768;
option ReceiveByteBurst = 65536;
option ReceiveMessagesPerSecond = 1000;
option ReceiveMessageBurst = 2000;

event Input {
  From: Client,
  Data: (u16, f32),
}
```

Budgets reduce application work after Roblox receives an invocation. They are not a guarantee against all denial-of-service traffic. Validate permissions and game rules in handlers.

## Optional Event Settings

Event blocks support `Rate`, `Burst`, `Max`, and `Compression`. All are omitted by default. See [event properties](/schema-reference#events) and [compression behavior](/runtime-model#optional-delta-compression).

`Rate` is always measured per second. There is no `RateTimer`, `token_budget`, or `refill_timer` setting.

## Option Matching

Option names are case-insensitive. Duplicate option names are rejected. Use only the supported names above: unrecognized file-level options are currently preserved as metadata but have no runtime effect.
