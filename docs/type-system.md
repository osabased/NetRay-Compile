# Type System

## Primitive Types
NetRay supports standard primitive types for efficient binary serialization.

- **Boolean:** `bool` / `boolean`
- **Integer (Unsigned):** `u8`, `u16`, `u32`
- **Integer (Signed):** `i8`, `i16`, `i32`
- **Float:** `f16`, `f32`, `f64`
- **String:** `string`
- **Buffer:** `buffer`
- **Roblox Types:**
  - `vector`: defaults to `vector<f32>` (X/Y/Z)
  - `cframe`: Position + YXZ Euler Angles (via `ToOrientation`)
  - `color3`: RGB values quantized to u8 (0-255)
  - `brickcolor`: u16 ID
  - `datetime`: Unix timestamp (f64)
  - `datetimemillis`: Unix timestamp millis (f64)
- **Dynamic:** `unknown`

::: info Type Normalization
Type aliases are normalized internally. For example, `boolean` and `bool` are treated as identical. `vector3` is normalized to `vector`.
:::

::: warning Precision
- **Color3** is quantized to 8-bit channels (0-255). Precision loss may occur.
- **CFrame** is serialized using `ToOrientation()`. This handles rotations compactly but may introduce minor precision loss or gimbal lock near vertical orientations.
:::

## Numeric Ranges
When validation is enabled (`Validate` option), integers are checked against these ranges:

| Type | Range |
| :--- | :--- |
| `u8` | `0` to `255` |
| `i8` | `-128` to `127` |
| `u16` | `0` to `65535` |
| `i16` | `-32,768` to `32,767` |
| `u32` | `0` to `4,294,967,295` |
| `i32` | `-2,147,483,648` to `2,147,483,647` |

**Notes:**
- Bare floating-point types use IEEE 754 values. Declared numeric ranges are checked; a bounded float rejects NaN.
- `f16` rounds to the nearest representable half-precision value with ties to even and preserves signed zero.
- A standalone `bool` uses one byte. Boolean arrays, fixed arrays and sets are bit-packed.

## String Bounds
Strings can be bounded or unbounded.

- `string`: No declared maximum; the length prefix can represent up to 4,294,967,295 bytes. Actual buffer and transport limits still apply.
- `string<64>`: Max 64 bytes.
- `string(64)`: Alternative syntax for Max 64 bytes.
- `string(8, 64)`: Alternative syntax with min/max bounds.

::: warning Size Limit
Declared max length must be `<= 65535`. Without a declared max, the runtime uses varint length prefixes which support up to `4,294,967,295` bytes.
:::

## Length Encoding

Bounded strings, buffers, arrays and maps use a fixed-width count based on the allowed range. For `string(300, 310)`, the count stores `length - 300`, so one byte is enough. An exact bound such as `string(8, 8)` needs no length prefix. Unbounded lengths use a variable-width integer.

These rules are part of the wire format. Changing bounds or upgrading from an older encoding requires regenerating both runtime modules together.

## Container Types

### Optional
```rust
optional u16
optional string<32>
optional array<u8, 32>
```
- Carries a **1-byte presence tag**.
- Tag `0`: `nil`.
- Tag `1`: value follows.

### Array
```rust
array<u16>
array<u16, 128>
array<Pose, 50>
```
- **Dynamic length list.**
- Optional max bound (2nd arg).
- Without declared max, uses varint count prefix.
- Arrays are limited to 65,535 elements, including without a declared max.
  Senders enforce this limit before encoding. Receivers check the count and
  minimum required payload bytes before allocating, even with validation `Off`.
- **Optimization:** Boolean arrays are bit-packed.

### FixedArray
```rust
fixedarray<u16, 128>
fixedarray<Pose, 50>
u16[128] // Shorthand
Pose[50] // Shorthand
```
- **Fixed length list.** Length is required.
- **No length prefix** emitted in payload (saves bandwidth).
- Boolean fixed arrays are bit-packed.

### Map
```rust
map<string<32>, u16>
map<u16, Pose, 128>
{[string<32>]: u16} // Shorthand
```
- Key-Value store.
- Optional max entry bound (3rd arg).
- The encoder canonicalizes supported map keys for a stable serialized representation. Application iteration order is not part of the API contract.


## Set
```rust
set Weapons {
    Sword,
    Bow,
    Magic
}
```
- Defines a set of unique flags/identifiers.
- Emitted as a table of booleans: `export type Weapons = { Sword: boolean, Bow: boolean, Magic: boolean }`.
- Efficiently bit-packed on the wire.

## Tagged Enum (Sum Type)
```rust
enum Shape {
    Circle { radius: f32 },
    Rectangle { width: f32, height: f32 },
    Point // Unit variant
}
```
- Defines a type that can be one of several variants.
- Emitted as a Luau type union.
- **Wire Format:** 1-byte tag (or more for large enums) + variant payload.
- **Usage:**
  ```luau
  -- Generated Type
  export type Shape = 
      | { Type: "Circle", radius: number }
      | { Type: "Rectangle", width: number, height: number }
      | { Type: "Point" }
  ```

## Struct References

You can use defined structs as field types.

```rust
struct Pose {
  x: f32,
  y: f32,
}

event Move {
  Data: Pose,
}
```

::: tip Locals vs Table
If you use `option DecodeStruct = Locals;`, struct fields in callbacks will be unpacked as individual arguments instead of a single table.
:::

## Passthrough
Passthrough allows "any" type to bypass the binary serializer and be sent as a raw RemoteEvent argument.

```rust
event Example {
  Data: (u16, passthrough Player),
}
```

- `passthrough`: Treated as `any`.
- `passthrough <TypeName>`: Checked via `typeof` or `IsA` if validation is on.

::: warning Performance
Passthrough values are **not** optimized by NetRay. They use standard Roblox serialization logic and cost.
:::

## Validation Modes
Configure via `option Validate = ...;`

- **`Off`**: Minimal checks. High performance.
- **`Basic`**: Schema bounds and tag checks.
- **`Full`**: Strict shape and type checking for all values.

::: tip Recommendation
`Off` remains the default. Use `Full` to catch invalid caller values while building your game, then choose a mode based on your application's validation needs and profiling. Buffer bounds, decoding tags and array allocation checks remain active in every mode. Validation modes do not replace gameplay authorization or optional traffic limits.
:::
