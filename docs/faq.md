# FAQ

## Do I need to add options when updating?

No. `Validate = Off`, `TypeBranding = Off`, and `DecodeStruct = Locals` remain the defaults. All new operational limits default to `0` (disabled), and events have no rate/size policy or delta compression unless requested in the schema.

Regenerate Server, Client and Types together even when the schema is unchanged. See the [migration notes](/changelog#v0-2-0).

## Does zero mean that messages are forbidden?

For file-level limits, `0` means disabled. Event-level `Rate`, `Burst`, and `Max` require positive values; omit those properties to disable them.

## Is delta compression automatic?

No. Add `Compression: Repeat` or `Compression: Fields` to a reliable event to enable it. Omit `Compression` to disable it; `Compression: Off` is not a supported value.

Repeat sends a marker for an identical serialized body. Fields can omit unchanged fixed-width arguments using a mask. Every event still reaches its handler when accepted; this does not suppress repeated callbacks.

## Can unreliable events use delta compression?

No. The compiler rejects that combination. A lost unreliable packet could otherwise leave the receiver without the required baseline.

## Does a smaller buffer mean the same percentage less bandwidth?

No. NetRay reduces the buffer before Roblox applies its own transport processing. Repetition, batching, passthrough values and call frequency affect the result. Benchmark changing data as well as repeated data.

## Do per-event rate limits stop all oversized-buffer attacks?

No. Finding the next event can require skipping its schema, and compressed records may need decoding to keep their baseline valid. Optional call/byte receive budgets reject work earlier. Limits also do not replace gameplay permission checks. See [options](/options).

## Where do I compile and find the output?

Use the [Studio plugin](/studio-plugin-workflow) or [CLI](/cli-workflow). Studio writes `Server`, `Client`, `Types` and a commented `Schema` under `ReplicatedStorage/NetRay`. The CLI writes three Luau modules, `Schema.idl`, and `CompileInfo.txt` to the chosen output folder.

## Does remote_scope change the output folder?

No. It changes the three remote names and overrides the frontend's fallback scope. Separate generated protocols need distinct remote scopes.

## Can the server target selected players?

Yes. Server event APIs provide `Fire(player, ...)`, `FireAll(...)`, `FireList(players, ...)`, and `FireExcept(player, ...)` when the schema permits server sending.

## Can I register multiple callbacks?

Use `ManySync` or `ManyAsync`. Single modes replace the current handler. `On` returns a connection with `Disconnect()`. Polling events use `Iter()` instead of `On`.

## Why do callbacks receive separate struct fields?

`DecodeStruct = Locals` is the default for top-level struct parameters. Set `DecodeStruct = Table` to receive each struct as a table. Arrays of structs remain arrays.

## Why did my polling loop change after upgrading?

The iterator now returns an index before the payload. Use `for _, value in Event.Iter() do` on a client, or `for _, player, value in Event.Iter() do` on a server. This allows nil payload arguments without ending iteration.

## Why are drop counters zero even when data is rejected?

The exposed counters cover outgoing drops. They do not count every receive-side rejection, measure delivery, or acknowledge server processing.

## Is the compiler version negotiated at runtime?

No. Both sides must use output from the same schema and compiler version. Deploy generated modules as a matching set.
