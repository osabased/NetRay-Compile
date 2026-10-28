--!strict
-- Name: AST
-- Purpose: AST type definitions for NetRay IDL

export type Token = {
    kind: string,
    value: string,
    line: number,
    column: number,
}

export type Type = {
    kind: string,
    name: string?,
    value: any?,
    key: any?,
    min: number?,
    max: number?,
    values: { string }?,
    fields: { any }?,
    variants: { any }?,
    tag: string?,
}

export type Param = {
    name: string,
    type: Type,
}

export type Struct = {
    name: string,
    fields: { Param },
}

export type Enum = {
    name: string,
    values: { string }?,
    tag: string?,
    variants: { any }?,
}

export type Set = {
    name: string,
    values: { string },
}

export type Event = {
    name: string,
    params: { Param },
    reliability: string,
    from: string?,
    call: string?,
    compression: string?,
    rate: number?, -- Client-originated messages per second.
    burst: number?, -- Client-originated messages available at once.
    max: number?, -- Serialized body bytes, excluding IDs, framing, and passthrough arguments.
}

export type Function = {
    name: string,
    params: { Param },
    returns: { Param },
    yieldMode: string?,
}

export type Scope = {
    name: string,
    declarations: { Decl },
}

export type Option = {
    name: string,
    value: string,
}

export type Decl = Struct | Enum | Set | Event | Function | Scope

export type Schema = {
    options: { Option },
    declarations: { Decl },
}

local LUAU_KEYWORDS: { [string]: boolean } = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
    ["continue"] = true,
    ["export"] = true,
    ["type"] = true,
}

return { LUAU_KEYWORDS = LUAU_KEYWORDS }
