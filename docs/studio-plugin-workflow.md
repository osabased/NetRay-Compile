# Studio Plugin Workflow

Install [NetRayCompilerPlugin](https://create.roblox.com/store/asset/100322227279356/NetRayCompilerPlugin) from the Creator Store. The plugin compiles locally without HTTP requests.

## Compile

1. Set the **Remote Scope Name**, or keep `NetRay`.
2. Enter IDL in the schema editor.
3. Click **Compile to ReplicatedStorage**.

The plugin writes four ModuleScripts under `ReplicatedStorage/NetRay`:

| Module | Purpose |
| :--- | :--- |
| `Server` | Server networking runtime |
| `Client` | Client networking runtime |
| `Types` | Matching Luau type definitions |
| `Schema` | Commented copy of the compiled IDL; returns an empty table |

`option remote_scope` overrides the scope textbox for remote names. The output folder stays `ReplicatedStorage/NetRay`.

## Editor Controls

- **Load Selection** loads the entire source of exactly one selected Script, LocalScript or ModuleScript.
- **Clear** clears the editor.
- Scope and schema text are saved in plugin settings and restored when reopened.
- The status line reports compile or write errors.

The generated `Schema` module is a reference copy, not raw IDL. To reuse it in the editor, copy the schema and remove the generated leading `-- ` comment prefix from each schema line. Loading the complete reference module directly does not recover raw IDL.

## Write Behavior

The plugin checks the output folder and all four output names before changing them. A non-Folder `ReplicatedStorage/NetRay`, or a non-ModuleScript with an output name, causes an **Output conflict** error. Existing conflicting objects are not deleted.

Matching ModuleScripts are updated in place. A missing output folder or module is created. Compilation errors do not replace existing output. If a later write fails, resolve the error and compile again before using the generated modules.

## Updating the Plugin

The plugin compiler mirrors `src/`; only its module imports differ for Studio. Build it using the [repository instructions](https://github.com/AstaWasTaken/NetRay-Compile/blob/main/Roblox-Plugin/README.md).

Updating the plugin does not regenerate code already in a place. Recompile each schema and replace Server, Client and Types together. Check the generated version header and the [v0.2.0 migration notes](/changelog#v0-2-0).

## Common Errors

| Message | Action |
| :--- | :--- |
| `Schema is empty` | Enter schema text first. |
| `Compile failed: ...` | Fix the reported IDL or option error. |
| `Output conflict: ...` | Rename or move the conflicting object yourself. |
| `Compiled, but write failed: ...` | Resolve the write failure, then recompile the whole output set. |
| `Select exactly one Script...` | Select one supported source object for Load Selection. |
