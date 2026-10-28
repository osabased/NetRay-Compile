# CLI Workflow

The CLI and Studio plugin use the same compiler. v0.2.0 output includes production runtime modules and a record of the input used to generate them.

## Install a Published Release

```sh
rokit add AstaWasTaken/NetRay-Compile@v0.2.0 netray
netray compile path/to/schema.idl --out-dir generated --scope NetRay
```

Release downloads bundle Lune. They do not require a separate Lune installation.

## Compile a Local Checkout

Run from the repository root:

```sh
rokit install
lune run cli/netray.luau compile path/to/schema.idl --out-dir generated --scope NetRay
```

Quote paths containing spaces. For example, in PowerShell:

```powershell
lune run cli/netray.luau compile "schemas/my network.idl" --out-dir "generated/my network" --scope NetRay
```

## Arguments and Options

| Argument | Required | Meaning |
| :--- | :--- | :--- |
| `<schema-path>` | Yes | Input IDL file |
| `--out-dir <dir>` | Yes | Output folder, created if missing |
| `--scope <name>` | No | Fallback remote prefix; defaults to `NetRay` |
| `-h`, `--help` | No | Usage and compiler version |

`option remote_scope` in the schema overrides `--scope`.

## Output Files

| File | Contents |
| :--- | :--- |
| `Server.luau` | Server runtime |
| `Client.luau` | Client runtime |
| `Types.luau` | Generated Luau types |
| `Schema.idl` | Exact input schema text |
| `CompileInfo.txt` | Compiler version, resolved scope, validation, limits and explicit schema options |

The three Luau files are a matching set. Import them as sibling ModuleScripts. The schema and metadata are reference files and do not need to run in the game.

Existing files with these names are overwritten. Schema compilation finishes before output writing begins, but writes are not a filesystem transaction: a write failure can leave partial output. Recompile successfully before importing any files.

## Failures

Missing input, invalid schema, invalid output path or write failure produces exit code `1` and an error on stderr. Success produces exit code `0`.

On macOS/Linux, the bundled launcher's extracted temporary files are cleaned up when it exits normally after success or failure.

## Upgrading

Do not replace only one runtime module. Regenerate Server, Client and Types together and apply the [migration notes](/changelog#v0-2-0). No rate limits or compression settings are required in an existing schema.
