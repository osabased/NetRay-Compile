# NetRay Studio Plugin v0.2.0

The plugin compiles IDL locally and writes `Server`, `Client`, `Types`, and a commented `Schema` reference under `ReplicatedStorage/NetRay`.

The compiler under `Compiler/` mirrors `../src/`. Only require paths differ: CLI imports use relative filesystem paths, while Studio imports use `script.Parent` references. Make compiler changes in `src/`, then mirror them. UI changes belong in `NetRayCompilerPlugin.server.luau`.

## Build the Plugin

From the repository root:

```sh
rokit install
rojo build Roblox-Plugin/plugin.project.json --output dist/NetRayCompilerPlugin.rbxm
```

The project includes the entire `Compiler/` directory, including `generator/Compression.luau`, and sets the plugin script's RunContext to Plugin. Import or publish the built model using your usual Studio plugin workflow.

`default.project.json` is for a development place containing the plugin under ReplicatedStorage; `plugin.project.json` produces the standalone plugin model.

The local compiler regression checks verify source parity after normalizing import paths. Release packaging does not run unit tests.

## Updating Generated Code

An updated plugin does not modify previously generated modules automatically. Recompile the schema and replace Server, Client and Types together. Existing schemas keep their default validation/struct modes; new rate limits, operational caps and compression are optional.

The plugin refuses output class conflicts instead of deleting existing objects.

See the [documentation](../docs/index.md), [plugin workflow](../docs/studio-plugin-workflow.md), and [release notes](../docs/changelog.md).
