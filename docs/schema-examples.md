# Schema Examples

## Minimal Event
```rust
event reliable Ping(u16 id);
```

## Block Event with Struct Payload
```rust
struct PingData {
  id: u16,
  latency: u16,
}

event Ping {
  From: Client,
  Type: Reliable,
  Call: ManySync,
  Data: PingData,
}
```

## Tuple Payload Event
```rust
event Position {
  From: Both,
  Type: Unreliable,
  Call: ManyAsync,
  Data: (u16, f32, f32),
}
```

## Function Request/Response
```rust
function GetDealers {
  Yield: SingleSync,
  Data: (u16),
  Return: (u8, string<100>),
}
```

## Polling Receive Mode
```rust
event Snapshot {
  From: Server,
  Type: Unreliable,
  Call: Polling,
  Data: (u16, f32, f32),
}
```

## Nested Scopes
```rust
scope Gameplay {
  scope Cars {
    event Spawned {
      From: Server,
      Type: Reliable,
      Data: u16,
    }
  }
}
```

## Options
```rust
option Validate = Full;
option TypeBranding = On;
option DecodeStruct = Table;
```

## Passthrough Example
```rust
function InspectPlayer {
  Data: (passthrough Player),
  Return: (string<32>),
}
```

## Full Example
```rust
option Validate = Basic;

scope Gameplay {
  struct Entities {
    brand: string<100>,
    carName: string<100>,
    carId: u16,
    available: bool,
    dealers: u8,
    price: f64,
  }

  event CarsUpdateStruct {
    From: Client,
    Type: Reliable,
    Call: SingleSync,
    Data: Entities,
  }

  event CarsTuple {
    From: Both,
    Type: Unreliable,
    Call: ManyAsync,
    Data: (u16, string<100>, bool),
  }

  function GetDealers {
    Yield: SingleSync,
    Data: (u16),
    Return: (u8, string<100>),
  }
}
```

## Single-Entity Example
```rust
struct Entities {
  brand: string,
  carName: string,
  carId: u16,
  available: boolean,
  dealers: u8,
  price: f64
}

event MyEvent {
  From: Client,
  Type: Reliable,
  Call: SingleSync,
  Data: Entities
}

function Ping {
  Yield: SingleSync,
  Data: (f64),
  Return: (f64),
}
```

## Repeat Compression (Opt-In)

```rust
event Status {
  From: Server,
  Type: Reliable,
  Compression: Repeat,
  Data: string<200>,
}
```

Each accepted event still reaches its handler. Identical serialized bodies use a repeat marker. Omit `Compression` for ordinary encoding.

## Field Masks (Opt-In)

```rust
event State {
  From: Server,
  Type: Reliable,
  Compression: Fields,
  Data: (u32, u32, u32),
}
```

Each tuple argument is a separate mask section. Fixed-width named structs can be sections too, but their members are not split into independent mask bits.

## Vectors

```rust
event Positions {
  From: Client,
  Type: Reliable,
  Data: array<vector<f32>>,
}
```

`vector3` is also accepted. This event has no delta compression or operational limits unless added explicitly.

## Per-Event Rate and Size Limits (Opt-In)

```rust
event Action {
  From: Client,
  Rate: 5,
  Burst: 10,
  Max: 128,
  Data: (u16, string<100>),
}
```

This allows an initial burst of ten accepted events per player and refills five tokens per second. `Max` limits the serialized body, including its length prefixes. These numbers are examples, not defaults.

## Shared Server Receive Budget (Opt-In)

```rust
option ReceiveCallsPerSecond = 60;
option ReceiveCallBurst = 120;
option ReceiveBytesPerSecond = 32768;
option ReceiveByteBurst = 65536;

event Input {
  From: Client,
  Data: (u16, f32),
}
```

These budgets apply across the generated module's incoming channels for each player. Omit the options or set them to zero to disable them.
