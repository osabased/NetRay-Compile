---
layout: home

hero:
  name: "NetRay Compiler"
  text: "Next-Gen Roblox Networking"
  tagline: Generate type-safe, optimized networking code through the Studio plugin or a standalone CLI. Stop writing boilerplate. Start shipping features.
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started
    - theme: alt
      text: CLI Workflow
      link: /cli-workflow
    - theme: alt
      text: View Schema Reference
      link: /schema-reference
  image:
    src: /Vector.png
    alt: NetRay Compiler Logo

features:
  - title: End-to-End Type Safety
    details: Define your network protocol once in IDL. Get fully typed Luau code for both Client and Server instantly.
  - title: High Performance
    details: Generated buffer serializers, batching, packed booleans and optional delta compression help reduce networking overhead.
  - title: Plugin + CLI
    details: Use the same compiler core inside Roblox Studio or from a standalone CLI installed through Rokit.
---

## v0.2.0 Update

Optional reliable-event compression, opt-in traffic/work limits, faster collection codecs and saved compile inputs are now documented. Existing defaults stay unchanged; regenerate Server, Client and Types together when upgrading.

[Read the update log and migration notes](/changelog#v0-2-0).

## Why NetRay?

NetRay Compiler bridges the gap between complex networking requirements and developer experience. By using a specialized Interface Definition Language (IDL), it eliminates category errors and manual remote management.

### Key Capabilities
- **Strict Schema Definitions**: Define events, functions, and structs in a clear, concise syntax.
- **Generated Modules**: Compile your schema into matching server, client and type modules.
- **Runtime Optimization**: Built-in support for reliable/unreliable channels, segmented batching, and order preservation.
- **Optional Policies**: Enable repeat/field-mask compression and receive limits only where your application needs them.
- **Modern Event Modes**: `Call` supports single-handler, multi-handler, and polling receive APIs.

## Example Schema

```rust
struct PlayerData {
    Health: u8,
    Inventory: array<u16>
}

event PlayerAction {
    From: Client,
    Type: Reliable,
    Call: SingleAsync,
    Data: (vector<f32>, string<64>)
}
```
