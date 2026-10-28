# Runtime Model

## Transport Layout

Each generated module pair uses three remotes in `ReplicatedStorage`:

| Remote | Roblox class | Purpose |
| :--- | :--- | :--- |
| `<Scope>_RELIABLE` | `RemoteEvent` | Reliable events |
| `<Scope>_UNRELIABLE` | `UnreliableRemoteEvent` | Unreliable events |
| `<Scope>_FUNCTION` | `RemoteFunction` | Request/response calls |

The server creates missing remotes and rejects incompatible existing classes. The client waits for them. Require the server module from a server script before expecting client calls to work.

`option remote_scope` overrides the CLI/plugin scope fallback. Use distinct scopes for separate protocol instances. The plugin output folder remains `ReplicatedStorage/NetRay`; remote scope does not rename it.

## Queueing and Batching

Client event sends serialize into channel arenas and flush on `RunService.Heartbeat` or `Net.StepReplication()`. Reliable server sends to individual players are queued and grouped per recipient. Broadcast boundaries preserve the order of preceding targeted reliable sends. Some server send paths send directly; a successful `Fire*` result is not a delivery acknowledgment.

Reliable and unreliable channels remain separate. Flush compacts contiguous runs of the same event ID when doing so saves bytes. It does not combine separated runs in a way that reorders messages.

There is **no default NetRay batch-size, message-count, receive-rate, decode-work or polling-queue cap**. In particular, `2048` is an initial queue capacity, not a default message limit. The [optional limits](/options) activate only when configured.

An enabled batch limit flushes a queued batch early. A single oversized event is rejected rather than fragmented. Roblox transport restrictions still apply when NetRay limits are disabled.

## Optional Delta Compression

Compression is off unless a reliable event declares `Compression: Repeat` or `Compression: Fields`. Both directions are supported. Unreliable events reject compression at compile time because a missing baseline would make later messages undecodable.

### Repeat

`Repeat` compares the serialized event body with its previous body. An identical body becomes a one-byte repeat marker; a changed body is sent in full with a mode byte. Event IDs and batch headers still occupy space.

The receiver reconstructs the body and delivers every event normally. This is not event deduplication, and the sender still serializes each call before comparing bytes. The marker is not a zero-filled replacement buffer.

### Fields

`Fields` also detects identical bodies. For partial changes, it sends a mask plus changed top-level serialized arguments when that is smaller than a full body.

The current fixed-width layout supports numeric primitives, booleans, fixed arrays of supported fixed-width elements, and named structs made from those types. A struct supplied as one argument is one mask section; its members do not receive separate mask bits. Use a tuple such as `Data: (u32, u32, u32)` for three independent sections.

Variable-sized types and other unsupported fixed layouts, including `vector`, are rejected for `Fields`. Use `Repeat` for vector arrays, strings and other supported variable-sized payloads.

### Baselines and Cost

- Client-to-server baselines reset for each flushed batch. A rejected batch cannot invalidate the next batch's baseline.
- Server-to-client baselines persist per recipient. New recipients receive full data, and disconnected players' state is removed.
- A cache holds at most 256 event baselines and uses a reset record when needed. An enabled `MaxBatchBytes` also caps cached body bytes.
- Compression rejects passthrough/instance references and recursive payload types.
- Comparing and copying bodies costs CPU and memory. Data that changes frequently may save little or add a mode byte. Measure representative traffic before enabling compression.

These byte savings occur **before Roblox's own transport compression**. Smaller NetRay buffers do not guarantee a proportional reduction in measured network traffic.

## Receiving and Limits

Structural checks reject malformed lengths, truncated buffers and invalid tags even when `Validate = Off`. Arrays have a supported maximum of 65,535 elements. Those decoding rules are separate from optional operational limits.

Server call/byte admission runs before decoding. Per-event rate limits may still need a schema-aware skip to find the next record. Compressed events must reconstruct and validate their bodies before per-event rate rejection so later records retain a valid baseline. Use global receive budgets when the goal is to reduce work before event decoding.

A receive error stops the remainder of that invocation; it does not roll back callbacks already delivered. Runtime warnings are throttled to avoid flooding output. Drops and warnings are not an acknowledgment protocol.

## Callbacks and Polling

Events retain their configured single-listener, multi-listener or polling API. Synchronous callbacks should not yield if the application relies on completion order. With compression present, client reliable callbacks run in protected tasks so a yielding handler cannot corrupt subsequent baseline updates. This also applies to uncompressed reliable events in the same generated client module.

Polling queues should be drained regularly. Without an explicit `MaxPollingMessages`, the queue has no operational cap. See the [generated API](/generated-api#handler-model) for iterator arguments and listener disconnection.

## IDs and Compatibility

IDs are assigned in declaration order, independently for reliable events, unreliable events and functions. Their width is selected as `u8` or `u16`.

Regenerate and replace **Server, Client and Types together** using one schema and compiler version. Changing declaration order, field order, bounds, compression or other wire-affecting settings requires matching output on both ends. v0.2.0 includes changed bounded-length encodings, so do not combine its output with older generated modules. There is no version-negotiation handshake.

Keep already-running server/client pairs on their matching build; follow your game's normal deployment process for new builds.

## Stats

`Net.Stats` exposes outgoing queue sizes and drop counters:

```luau
print(Net.Stats.GetReliableQueueSize())
print(Net.Stats.GetUnreliableQueueSize())
print(Net.Stats.GetReliableDropped())
print(Net.Stats.GetUnreliableDropped())
```

They do not count all inbound rejections, prove delivery, or measure bandwidth/CPU usage.
