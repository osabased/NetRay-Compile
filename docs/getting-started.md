# Getting Started

NetRay Compiler v0.2.0 generates matching Server, Client and Types modules from one IDL schema. You can compile through the Studio plugin or the local CLI.

## Install

### Studio Plugin

Install [NetRayCompilerPlugin](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin) from the Creator Store. Open the NetRay toolbar in Studio and click **NetRayCompiler**.

### CLI

Install a published CLI release through Rokit:

```sh
rokit add AstaWasTaken/NetRay-Compile@v0.2.0 netray
netray compile path/to/schema.idl --out-dir generated --scope NetRay
```

To compile from a local repository checkout instead:

```sh
rokit install
lune run cli/netray.luau compile path/to/schema.idl --out-dir generated --scope NetRay
```

The CLI writes `Server.luau`, `Client.luau`, `Types.luau`, an exact input copy in `Schema.idl`, and `CompileInfo.txt`. Import the three Luau modules as ModuleScripts under the same folder, for example `ReplicatedStorage/NetRay`.

## First Schema

Paste this into the plugin's IDL editor, or save it as the CLI input file:

```rust
event Greet {
  From: Client,
  Type: Reliable,
  Call: SingleSync,
  Data: string<64>,
}
```

No options are needed. Existing defaults remain `Validate = Off`, `DecodeStruct = Locals`, and `TypeBranding = Off`; all new rate limits, operational caps and delta compression are opt-in.

In the plugin, leave the scope as `NetRay` and click **Compile to ReplicatedStorage**. It writes `Server`, `Client`, `Types`, and a non-executable schema reference named `Schema` under `ReplicatedStorage/NetRay`.

## Server Script

Place a Script in `ServerScriptService`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Server)

Net.Greet.On(function(player, message)
    print(player.Name, message)
end)
```

Requiring the server module creates the remotes.

## Client Script

Place a LocalScript in `StarterPlayer/StarterPlayerScripts`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage.NetRay.Client)

Net.Greet.Fire("Hello")
```

Events automatically flush on Heartbeat. A return value of `true` means the local send/enqueue succeeded; it is not confirmation that the server handled the event.

## Scopes

A scope such as `Combat` names the remotes `Combat_RELIABLE`, `Combat_UNRELIABLE`, and `Combat_FUNCTION`. The schema's `option remote_scope = "Combat";` takes precedence over the CLI/plugin scope field. It does not change the plugin's output folder.

## Updating an Existing Game

Regenerate and replace Server, Client and Types as a matching set. v0.2.0 changes some binary encodings and polling iterator arguments. Existing schemas do not need new limits added. See the [v0.2.0 migration notes](/changelog#v0-2-0).

Continue with the [schema reference](/schema-reference), [generated API](/generated-api), [options](/options), or [CLI workflow](/cli-workflow).
