--!strict
-- Senders stage one cache copy per flush; receivers commit after codec validation.
local SOURCE = [=[
-- false marks a message compressed whole, without per-field deltas.
type FieldWidths = { number } | false
type CompressionState = { values: { [number]: buffer }, bytes: number, count: number, staged: boolean? }

local __nr_repeatMarker = buffer.create(1)
buffer.writeu8(__nr_repeatMarker, 0, 1)

local function __nr_cloneCompressionState(state: CompressionState?): CompressionState
    return { values = state and table.clone(state.values) or {}, bytes = state and state.bytes or 0, count = state and state.count or 0, staged = true }
end

local function __nr_copyBody(source: buffer, offset: number, length: number): buffer
    local result = buffer.create(length)
    buffer.copy(result, 0, source, offset, length)
    return result
end

local function __nr_commitFull(
    state: CompressionState?,
    id: number,
    source: buffer,
    startOffset: number,
    endOffset: number,
    reset: boolean?,
    owned: boolean?
): CompressionState?
    local length = endOffset - startOffset
    local staged = state and state.staged
    if reset then state = nil end
    if length > MaxBatchBytes then return state end
    local values = state and (staged and state.values or table.clone(state.values)) or {}
    local previous = values[id]
    local count = (state and state.count or 0) + (previous and 0 or 1)
    local bytes = (state and state.bytes or 0) - (previous and buffer.len(previous) or 0) + length
    assert(bytes <= MaxBatchBytes, "Compression baseline budget exceeded")
    assert(count <= 256, "Compression baseline entry budget exceeded")
    values[id] = owned and source or __nr_copyBody(source, startOffset, length)
    if state and staged then
        state.bytes, state.count = bytes, count
        return state
    end
    return { values = values, bytes = bytes, count = count, staged = staged }
end

local function __nr_equalBytes(a: buffer, aOffset: number, b: buffer, bOffset: number, length: number): boolean
    local index = 0
    while index + 4 <= length do
        if buffer.readu32(a, aOffset + index) ~= buffer.readu32(b, bOffset + index) then return false end
        index += 4
    end
    while index < length do
        if buffer.readu8(a, aOffset + index) ~= buffer.readu8(b, bOffset + index) then return false end
        index += 1
    end
    return true
end

local function __nr_compress(
    state: CompressionState?,
    id: number,
    body: buffer,
    widths: FieldWidths?,
    startOffset: number?,
    bodyLength: number?
): (buffer, CompressionState?)
    local bodyOffset = startOffset or 0
    local length = bodyLength or (buffer.len(body) - bodyOffset)
    local previous = state and state.values[id]
    if previous and buffer.len(previous) == length and __nr_equalBytes(previous, 0, body, bodyOffset, length) then
        return __nr_repeatMarker, state
    end
    local reset = length <= MaxBatchBytes and ((state and state.bytes or 0) - (previous and buffer.len(previous) or 0) + length > MaxBatchBytes or (not previous and state and state.count >= 256))
    local nextState = __nr_commitFull(state, id, body, bodyOffset, bodyOffset + length, reset)
    if widths and previous and buffer.len(previous) == length and not reset then
        local maskBytes = math.ceil(#widths / 8)
        local changed: { [number]: boolean } = {}
        local offset = 0
        local encodedLength = 1 + maskBytes
        for index, width in widths do
            if not __nr_equalBytes(previous, offset, body, bodyOffset + offset, width) then
                changed[index] = true
                encodedLength += width
            end
            offset += width
        end
        assert(offset == length, "Compression field layout mismatch")
        if encodedLength < length + 1 then
            local encoded = buffer.create(encodedLength)
            buffer.writeu8(encoded, 0, 2)
            local readOffset, writeOffset = 0, 1 + maskBytes
            for index, width in widths do
                if changed[index] then
                    local maskOffset = 1 + (index - 1) // 8
                    buffer.writeu8(encoded, maskOffset, bit32.bor(buffer.readu8(encoded, maskOffset), bit32.lshift(1, (index - 1) % 8)))
                    buffer.copy(encoded, writeOffset, body, bodyOffset + readOffset, width)
                    writeOffset += width
                end
                readOffset += width
            end
            return encoded, nextState
        end
    end
    local encoded = buffer.create(length + 1)
    buffer.writeu8(encoded, 0, reset and 3 or 0)
    buffer.copy(encoded, 1, body, bodyOffset, length)
    return encoded, nextState
end

local function __nr_decompress(
    state: CompressionState?,
    id: number,
    payload: buffer,
    payloadLength: number,
    offset: number,
    widths: FieldWidths?
): (buffer, number, CompressionState?)
    assert(offset < payloadLength, "Missing compression mode")
    local mode = buffer.readu8(payload, offset)
    local previous = state and state.values[id]
    assert(previous, "Missing compression baseline")
    if mode == 1 then return previous, offset + 1, state end
    assert(mode == 2 and widths, "Invalid compression mode")
    local maskBytes = math.ceil(#widths / 8)
    local readOffset = offset + 1 + maskBytes
    assert(readOffset <= payloadLength, "Truncated compression mask")
    if #widths % 8 ~= 0 then
        assert(buffer.readu8(payload, offset + maskBytes) < 2 ^ (#widths % 8), "Invalid compression mask bits")
    end
    local length = buffer.len(previous)
    local body = __nr_copyBody(previous, 0, length)
    local writeOffset = 0
    for index, width in widths do
        assert(writeOffset + width <= length, "Compression field layout mismatch")
        local mask = buffer.readu8(payload, offset + 1 + (index - 1) // 8)
        if bit32.band(mask, bit32.lshift(1, (index - 1) % 8)) ~= 0 then
            assert(readOffset + width <= payloadLength, "Truncated compressed field")
            buffer.copy(body, writeOffset, payload, readOffset, width)
            readOffset += width
        end
        writeOffset += width
    end
    assert(writeOffset == length, "Compression field layout mismatch")
    return body, readOffset, __nr_commitFull(state, id, body, 0, length, false, true)
end
]=]

return {
    source = SOURCE,
    emit = function(lines: { string })
        for _, line in string.split(SOURCE, "\n") do
            lines[#lines + 1] = line
        end
    end,
}
