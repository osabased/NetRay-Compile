# Generated API

## Output Modules
The Studio plugin writes ModuleScripts to `ReplicatedStorage/NetRay`:
- `ReplicatedStorage/NetRay/Server`
- `ReplicatedStorage/NetRay/Client`
- `ReplicatedStorage/NetRay/Types`
- `ReplicatedStorage/NetRay/Schema`

## Requiring Modules

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Server) -- In a server Script.
```

Use the client module in a LocalScript instead:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Client)
```

`Schema` is a commented reference copy of the schema used by the plugin. The CLI instead saves raw `Schema.idl` and `CompileInfo.txt`. Import Server, Client and Types together as sibling ModuleScripts. Require only the runtime for the current side.

## Exported Types
`Types` exports:
- `NetServer`, `NetClient`, `Net`
- `NetStats`
- `Connection`
- Numeric aliases (`u8`, `i8`, `u16`, ...)
- All schema `struct`, `enum`, `set`, and tagged enum types

## Event API Surface
Methods depend on `From` and runtime side.

### Client side
- Send allowed (`From: Client` or `Both`): `Fire(...)`
- Receive allowed (`From: Server` or `Both`, `Call != Polling`): `On(callback)`
- Receive allowed (`From: Server` or `Both`, `Call == Polling`): `Iter()`

### Server side
- Send allowed (`From: Server` or `Both`): `Fire(player, ...)`
- Send allowed (`From: Server` or `Both`): `FireAll(...)`
- Send allowed (`From: Server` or `Both`): `FireList(players, ...)`
- Send allowed (`From: Server` or `Both`): `FireExcept(excludedPlayer, ...)`
- Receive allowed (`From: Client` or `Both`, `Call != Polling`): `On(callback)`
- Receive allowed (`From: Client` or `Both`, `Call == Polling`): `Iter()`

## Function API Surface
Functions generate on both sides:
- `On(callback)` for inbound handling.
- `Call(...)` for outbound request/response.

Client calls use `Net.Query.Call(...)`; server calls use `Net.Query.Call(player, ...)`. Server callbacks receive `player` before the decoded request arguments. Calls yield for the response and can raise errors; use `pcall` where the caller needs to recover.

Event `Rate`, `Burst`, `Max`, and `Compression` properties do not apply to functions. File-level receive budgets, decode work and RPC byte limits apply when enabled.

## Handler Model
Event handler behavior depends on `Call`:
- `SingleSync` / `SingleAsync`: one active handler.
- `ManySync` / `ManyAsync`: multiple active handlers.
- `Polling`: buffered receive queue via `Iter()`.

Polling iterators return an index before the event arguments. The index lets an
event with a nil first argument be consumed without ending the loop:

```luau
for index, value in NetClient.Value.Iter() do
    print(index, value) -- value may be nil
end
-- On the server: for index, player, value in NetServer.Value.Iter() do ... end
```

When updating previously generated modules, add an ignored index (`_`) before
the existing loop variables. The index is local to the queue, not a network ID.
Listener order is not guaranteed after subscriptions change. A listener added
during dispatch may receive that event if it occupies a slot not yet visited.

Function handlers are single-slot (`On` replaces the previous handler). `On` returns a connection with `Disconnect()`:

```luau
local connection = Net.Message.On(function(value)
    print(value)
end)
connection:Disconnect()
```

Synchronous handlers should not yield when completion order matters. With compression present, client reliable handlers run in protected tasks so yielding cannot disturb baseline updates, including uncompressed reliable events in that module. Async handlers may overlap; see [runtime behavior](/runtime-model#callbacks-and-polling).

## Return Value Conventions
- Event `Fire*` methods return `true` when the local enqueue/send succeeds. This does not acknowledge delivery or handler execution.
- An enabled outgoing size limit can reject a message with `false`.
- Validation/serialization failures can raise errors. A failed serialization does not commit a partial event to its outgoing queue.
- Server receive rate limits drop events at the receiver; they do not synchronously change the client's `Fire` result.

## Scope Mapping
Nested schema scopes map to nested API tables:

```rust
scope Gameplay {
  scope Cars {
    event Spawned { Data: u16 }
  }
}
```

```luau
local Spawned = Net.Gameplay.Cars.Spawned
```

## Struct Payload Shapes
Given:

```rust
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  From: Both,
  Data: Pose,
}
```

- Sender side: `Net.Move.Fire({ x = 10, y = 20 })`
- Receiver side with `DecodeStruct = Locals`: `On(function(x, y) ... end)`
- Receiver side with `DecodeStruct = Table`: `On(function(pose) ... end)`

## Optional Policies

Rate limits, byte caps and compression come from the schema and do not add required arguments to the API. Existing schemas keep their defaults; see [options](/options).

## Runtime Loop and Stats
- `Net.StepReplication()` flushes pending event queues.
- Runtime also auto-flushes from `RunService.Heartbeat`.
- `Net.Stats.GetReliableQueueSize()`
- `Net.Stats.GetUnreliableQueueSize()`
- `Net.Stats.GetReliableDropped()`
- `Net.Stats.GetUnreliableDropped()`

These counters cover outgoing queues/drops. They are not receive rejection totals, network delivery acknowledgments, CPU measurements or Roblox-compressed byte counts.
