<img width="5391" height="1167" alt="NetRay Compiler" src="https://github.com/user-attachments/assets/a4235325-fe07-4630-8053-6990c06b8241" />

# NetRay Compiler v0.2.0 [BETA]

Compile IDL schemas into typed Roblox Luau networking modules through the Studio plugin or CLI.

## Documentation

- [Getting started](docs/getting-started.md)
- [Schema reference](docs/schema-reference.md) and [options](docs/options.md)
- [Generated API](docs/generated-api.md) and [runtime model](docs/runtime-model.md)
- [v0.2.0 changes and migration](docs/changelog.md)

## Compile

Install the [Studio plugin](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin), or use a published CLI release:

```sh
rokit add AstaWasTaken/NetRay-Compile@v0.2.0 netray
netray compile path/to/schema.idl --out-dir generated --scope NetRay
```

From a local checkout:

```sh
rokit install
lune run cli/netray.luau compile path/to/schema.idl --out-dir generated --scope NetRay
```

The CLI writes Server, Client and Types modules, `Schema.idl`, and `CompileInfo.txt`. The plugin writes the modules and a commented `Schema` reference under `ReplicatedStorage/NetRay`.

## Schema and Runtime

Legacy declarations and block syntax are supported:

```rust
event Message {
  From: Client,
  Type: Reliable,
  Call: SingleSync,
  Data: string<64>,
}
```

- Events support reliable/unreliable delivery, single or multiple listeners, and polling.
- Server APIs include `Fire(player, ...)`, `FireAll`, `FireList`, and `FireExcept`.
- Functions use request/response `Call` and `On` APIs.
- Boolean collections and sets are packed into bits.
- Reliable events can opt into repeat or field-mask compression.
- Batch, receive, decode-work, polling, and per-event limits are optional.

**Defaults remain unchanged:** validation and type branding are off, top-level struct callbacks use `DecodeStruct = Locals`, and new limits and compression stay disabled unless configured.

## Upgrading

Generate and replace **Server, Client and Types together**. v0.2.0 changes some bounded-length encodings; older generated modules must not be mixed with new output. Polling loops now receive an index before their payload arguments. See the [changelog](docs/changelog.md).

## Contributing

Compiler changes belong in `src/`. Keep `Roblox-Plugin/Compiler/` synchronized, adapting only the module import paths. Plugin UI code lives in `Roblox-Plugin/NetRayCompilerPlugin.server.luau`.

[Plugin build instructions](Roblox-Plugin/README.md)
