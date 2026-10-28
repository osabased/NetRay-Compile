# Errors and Troubleshooting

## Parse & Schema Errors

### Token/Structure Errors
- `Unexpected token at line:column`
- `Unexpected token in scope`
- `Expected event parameter list or event block`
- `Expected function parameter list or function block`

### Event/Function Key Errors
- `E_EVENT_KEY`: unknown key in event block.
- `E_EVENT_FROM`: invalid `From` value.
- `E_EVENT_TYPE`: invalid `Type` value.
- `E_EVENT_CALL`: invalid `Call`/`Yield` call-mode token.
- `E_FUNCTION_KEY`: unknown key in function block.
- `E_UNSUPPORTED_YIELD`: function block `Yield` not supported (currently only `SingleSync`).

### Analyzer/Option Errors
- `E_DUP_STRUCT`: duplicate struct name.
- `E_DUP_ENUM`: duplicate enum name.
- `E_DUP_SET`: duplicate set name.
- `E_DUP_DECL`: name collision between struct/enum/set declarations.
- `Invalid Validate option value ...`
- `Invalid TypeBranding option value ...`
- `Invalid DecodeStruct option value ...`
- `Duplicate option ...` / `Duplicate event property ...`
- `Event compression requires a reliable event`
- `Event compression does not support passthrough or instance references`
- `Field compression requires fixed serialized fields`
- `Event rate is only supported for client-originated events`
- `Event burst requires rate`
- Numeric limit values must be zero (disabled file-level limit) or valid positive values. See [options](/options).

## Runtime Error Codes
Generated runtime uses short error strings to save binary size & string constants:

| Error | Meaning |
| :--- | :--- |
| `E_BOUNDS` | Buffer read/write bounds violation. |
| `E_SCHEMA` | Invalid payload schema or message shape. There is no explicit wire-version handshake. |
| `E_TAG` | Invalid optional/boolean tag values. |
| `E_TYPE` | Lua type mismatch at runtime boundary. |
| `E_PASS` | Passthrough argument validation failure. |

## Plugin-Side Failures
| Error | Context |
| :--- | :--- |
| `Schema is empty` | Schema editor has no content. |
| `Compile failed: ...` | Parser/analyzer/generator error. |
| `Compiled, but write failed: ...` | Module write path failed; resolve it and regenerate the whole set. |
| `Output conflict: ...` | An output name belongs to a different class; it is not automatically deleted. |
| `Select exactly one Script...` | Invalid selection count or non-source object selected. |

## Quick Troubleshooting
::: tip Fixes
1. **Validation**: Start with `option Validate = Full;` while authoring schema.
2. **Direction**: Confirm `From` and call direction match your runtime usage.
3. **Uniqueness**: Keep schema names unique, especially structs.
4. **Callbacks**: If callbacks receive unexpected params, check `option DecodeStruct`.
5. **Replication**: If remotes fail on client, verify plugin scope name matches server text.
:::

## Messages Missing After Enabling Limits

Check the byte size of one full event, batch size and burst capacities. A token bucket cannot admit a call/packet/segment larger than its capacity. Per-event limits can drop records without preventing later records from being delivered; a malformed compressed record stops the current batch.

`Fire` returning true only confirms local acceptance. Outgoing drop counters do not report all receive rejections. Warnings are throttled and some policy drops are silent. Check handler counts when diagnosing delivery.

## Compression Errors

A missing baseline, truncated mask or invalid mode indicates malformed traffic or mismatched generated code. Regenerate both sides from the same schema. Do not manually reconnect only one generated receiver to an already-active compressed stream without also resetting its sender.

Use `Repeat` for variable-length data. `Fields` supports only layouts whose fixed size the compiler can determine, and treats each top-level argument as one section.

## Errors After Updating

Replace Server, Client and Types together. Check the version headers and saved schema, then update polling loops to include their leading index. An older peer can interpret a changed length prefix as a different value.

## Vector Type Syntax

Use `vector`, `vector<f32>` or `vector3` in IDL; generated Luau uses Roblox's `Vector3` type. Do not infer IDL syntax from the generated Luau type name.
