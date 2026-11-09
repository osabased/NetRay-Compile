--!strict
-- Name: Runtime
-- Purpose: Runtime code generation (queues, listeners, dispatch, preamble)
local Version = "0.2.0+osa.3"
local Ast = require(script.Parent.Parent.idl.Ast)
local Analyzer = require(script.Parent.Parent.idl.Analyzer)
local Types = require(script.Parent.Types)
local Utilities = require(script.Parent.Utilities)
local Emitters = require(script.Parent.Emitters)
local Compression = require(script.Parent.Compression)

type MessageInfo = Types.MessageInfo
type EmitState = Types.EmitState
type WidthInfo = Types.WidthInfo
type DecodeStructMode = Types.DecodeStructMode

local addLine = Utilities.addLine
local appendLines = Utilities.appendLines
local concat = Utilities.concat
local join = Utilities.join
local indent = Utilities.indent
local sanitizeIdentifier = Utilities.sanitizeIdentifier
local normalizeTypeKind = Utilities.normalizeTypeKind
local isValidateFull = Utilities.isValidateFull
local isValidateBasicOrFull = Utilities.isValidateBasicOrFull
local emitError = Utilities.emitError
local nextTemp = Utilities.nextTemp
local splitParams = Utilities.splitParams
local paramNames = Utilities.paramNames
local toLuauType = Utilities.toLuauType
local pollingReturnTypes = Utilities.pollingReturnTypes
local typedParamList = Utilities.typedParamList
local returnTypeExpr = Utilities.returnTypeExpr
local callbackTypeExpr = Utilities.callbackTypeExpr
local callableTypeExpr = Utilities.callableTypeExpr
local callbackSignatureTypeExpr = Utilities.callbackSignatureTypeExpr
local messageClientCallbackTypeName = Utilities.messageClientCallbackTypeName
local messageServerCallbackTypeName = Utilities.messageServerCallbackTypeName
local messageClientApiTypeName = Utilities.messageClientApiTypeName
local messageServerApiTypeName = Utilities.messageServerApiTypeName
local collectMessages = Utilities.collectMessages
local buildScopeTables = Utilities.buildScopeTables
local getPassthroughTypeName = Utilities.getPassthroughTypeName
local canSendEvent = Utilities.canSendEvent
local canReceiveEvent = Utilities.canReceiveEvent
local getMessageIdWidthInfo = Utilities.getMessageIdWidthInfo
local widthForBound = Utilities.widthForBound
local resolveTypeBranding = Utilities.resolveTypeBranding
local resolveDecodeStruct = Utilities.resolveDecodeStruct
local expandDecodeParams = Utilities.expandDecodeParams
local buildDecodedParamPlans = Utilities.buildDecodedParamPlans
local collectDecodedLeafNames = Utilities.collectDecodedLeafNames
local getStringBoundComment = Utilities.getStringBoundComment
local fieldAccessExpr = Utilities.fieldAccessExpr
local paramsHaveVariableLength = Utilities.paramsHaveVariableLength
local fixedBytesForCanonicalParams = Utilities.fixedBytesForCanonicalParams

local emitCodecFunctions = Emitters.emitCodecFunctions
local emitSkipFunction = Emitters.emitSkipFunction
local emitPassthroughValidator = Emitters.emitPassthroughValidator
local emitCanonicalSizeForType = Emitters.emitCanonicalSizeForType
local emitFlatTopLevelSize = Emitters.emitFlatTopLevelSize
local emitSizeForType = Emitters.emitSizeForType
local emitWriteCanonicalForType = Emitters.emitWriteCanonicalForType
local emitWriteParamsWithFixedBlocks = Emitters.emitWriteParamsWithFixedBlocks
local canEmitFlatTopLevelSize = Emitters.canEmitFlatTopLevelSize

local EMPTY_PARAMS: { Ast.Param } = {}

-- Initializers that can be dropped with their local without changing behavior: literals, empty tables, aliases.
local PURE_INITIALIZERS = {
    "^%-?[%d%.]+$",
    "^%-?math%.huge$",
    '^"[^"]*"$',
    "^nil$",
    "^{}$",
    "^{} :: [%w_]+$",
    "^table%.create%([%w_]+%)$",
    "^table%.create%([%w_]+, [%w_]+%)$",
    '^setmetatable%({}, { __mode = "k" }%)$',
    "^[%a_][%w_]*$",
    "^[%a_][%w_]*%.[%a_][%w_]*$",
}

local function isPureInitializer(expression: string): boolean
    for _, pattern in PURE_INITIALIZERS do
        if string.match(expression, pattern) then
            return true
        end
    end
    return false
end

local function countTokens(lines: { string }): { [string]: number }
    local counts: { [string]: number } = {}
    for _, line in lines do
        for position, token in string.gmatch(line, "()([%a_][%w_]*)") do
            -- `a.b` and `a:b` name fields, not locals; `a..b` still names b.
            local before = string.sub(line, position - 2, position - 1)
            local isField = string.match(before, "[^%.][%.:]$") ~= nil or before == "." or before == ":"
            if not isField then
                counts[token] = (counts[token] or 0) + 1
            end
        end
    end
    return counts
end

-- Generated blocks close with `end` at the indentation that opened them.
local function findBlockEnd(lines: { string }, startIndex: number, indentation: string): number?
    for index = startIndex + 1, #lines do
        local line = lines[index]
        if string.sub(line, 1, #indentation) == indentation and string.match(string.sub(line, #indentation + 1), "^end[%),]*$") then
            return index
        end
    end
    return nil
end

-- Returns the parameter list of a multi-line function header, or nil when the line opens no function body.
local function functionHeaderParams(line: string): (string?, number?, number?)
    local openIndex = string.find(line, "%f[%w_]function%f[^%w_][%w_%.:%s]*%(")
    if openIndex == nil or string.find(line, "end[%),]*$") then
        return nil
    end
    local first = (string.find(line, "(", openIndex, true) :: number) + 1
    local depth = 1
    for index = first, #line do
        local char = string.sub(line, index, index)
        if char == "(" then
            depth += 1
        elseif char == ")" then
            depth -= 1
            if depth == 0 then
                return string.sub(line, first, index - 1), first, index - 1
            end
        end
    end
    return nil
end

local function splitTopLevel(text: string): { string }
    local parts: { string } = {}
    local depth = 0
    local start = 1
    for index = 1, #text do
        local char = string.sub(text, index, index)
        if char == "(" or char == "{" then
            depth += 1
        elseif char == ")" or char == "}" then
            depth -= 1
        elseif char == "," and depth == 0 then
            parts[#parts + 1] = string.sub(text, start, index - 1)
            start = index + 1
        end
    end
    parts[#parts + 1] = string.sub(text, start)
    return parts
end

-- Dispatch and decode functions share one positional signature per category, so a message that needs no budget or
-- payload still receives them. Unused names get Luau's `_` prefix and an unused trailing `...` is dropped.
local function markUnusedParameters(lines: { string })
    for headerIndex, line in lines do
        local loopIndent, loopVariable = string.match(line, "^(%s*)for ([%a_][%w_]*) = ")
        if loopVariable ~= nil and string.sub(loopVariable, 1, 1) ~= "_" then
            local closeIndex = findBlockEnd(lines, headerIndex, loopIndent)
            if closeIndex ~= nil and countTokens({ table.concat(lines, " ", headerIndex + 1, closeIndex - 1) })[loopVariable] == nil then
                lines[headerIndex] = string.gsub(line, "for " .. loopVariable .. " = ", "for _ = ", 1)
            end
            continue
        end
        local params, first, last = functionHeaderParams(line)
        if params == nil or params == "" then
            continue
        end
        local indentation = string.match(line, "^%s*") :: string
        local closeIndex = findBlockEnd(lines, headerIndex, indentation)
        if closeIndex == nil then
            continue
        end
        local body = table.concat(lines, "\n", headerIndex + 1, closeIndex - 1)
        local counts = countTokens({ body })
        local parts = splitTopLevel(params)
        local kept: { string } = {}
        for partIndex, part in parts do
            local trimmed = string.match(part, "^%s*(.-)%s*$") :: string
            local name = string.match(trimmed, "^[%a_][%w_]*") or string.match(trimmed, "^%.%.%.") or trimmed
            if name == "..." then
                if partIndex < #parts or string.find(body, "...", 1, true) then
                    kept[#kept + 1] = trimmed
                end
            elseif counts[name] == nil and string.sub(name, 1, 1) ~= "_" then
                kept[#kept + 1] = "_" .. trimmed
            else
                kept[#kept + 1] = trimmed
            end
        end
        lines[headerIndex] = string.sub(line, 1, (first :: number) - 1) .. table.concat(kept, ", ") .. string.sub(line, (last :: number) + 1)
    end
end

-- Emitters declare every helper a message might need; this drops the locals and local functions nothing references,
-- repeating until removals stop exposing new ones (an unused encoder leaves its message id unused).
local function pruneUnusedRuntimeSymbols(lines: { string })
    local split: { string } = {}
    for _, line in lines do
        for _, part in string.split(line, "\n") do
            split[#split + 1] = part
        end
    end
    table.clear(lines)
    table.move(split, 1, #split, 1, lines)

    local removed = true
    while removed do
        removed = false
        local counts = countTokens(lines)
        local index = 1
        while index <= #lines do
            local line = lines[index]
            local functionIndent, functionName = string.match(line, "^(%s*)local function ([%a_][%w_]*)%(")
            local localName, annotation, initializer = string.match(line, "^%s*local ([%a_][%w_]*)([^=]*) = (.+)$")
            local lastIndex: number? = nil
            if functionName ~= nil and counts[functionName] == 1 then
                lastIndex = findBlockEnd(lines, index, functionIndent)
            elseif localName ~= nil and counts[localName] == 1 and (annotation == "" or string.sub(annotation, 1, 1) == ":") and isPureInitializer(initializer) then
                lastIndex = index
            end
            if lastIndex ~= nil then
                for _ = index, lastIndex do
                    table.remove(lines, index)
                end
                if lines[index] == "" and (index == 1 or lines[index - 1] == "") then
                    table.remove(lines, index)
                end
                removed = true
            else
                index += 1
            end
        end
    end
end

local function limitLiteral(value)
    return value == 0 and "math.huge" or tostring(value)
end

local function emitQueue(
    lines: { string },
    prefix: string,
    remoteVar: string,
    fireMethod: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    _validateLevel: Analyzer.ValidateLevel,
    compressOutgoing: boolean?
)
    local upper = string.upper(prefix)
    addLine(lines, 0, ("local %s_ARENA_CAPACITY = 0"):format(upper))
    addLine(lines, 0, ("local %s_ARENA = create(%s_ARENA_CAPACITY)"):format(upper, upper))
    addLine(lines, 0, ("local %s_CURSOR = 0"):format(upper))
    addLine(lines, 0, ("local %s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 0, ("local %s_DROPPED = 0"):format(upper))
    if maxPassArgs > 0 then
        addLine(lines, 0, ("local %s_PASS_VALUES: { unknown } = table.create(DEFAULT_BATCH_CAPACITY)"):format(upper))
        addLine(lines, 0, ("local %s_PASS_SIZE = 0"):format(upper))
    end
    addLine(lines, 0, ("local %s_ENDS: { number } = {}"):format(upper))
    addLine(lines, 0, ("local %s_IDS: { number } = {}"):format(upper))
    local flushSource = [[
local function FlushPREFIX()
    if UPPER_QUEUE_SIZE == 0 then return end
    PREPARE_COMPRESSION
    local outputSize = OUTPUT_SIZE
    local index = 1
    while index <= UPPER_QUEUE_SIZE do
        local last = index
        local messageId = UPPER_IDS[index]
        while last < UPPER_QUEUE_SIZE and UPPER_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        local savings = count * ID_BYTES - (2 * ID_BYTES + VarUIntSize(count))
        if savings > 0 then outputSize -= savings end
        index = last + 1
    end
    local payloadToSend = create(outputSize)
    local outputOffset = 0
    local sourceOffset = 0
    index = 1
    while index <= UPPER_QUEUE_SIZE do
        local last = index
        local messageId = UPPER_IDS[index]
        while last < UPPER_QUEUE_SIZE and UPPER_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        if count * ID_BYTES > 2 * ID_BYTES + VarUIntSize(count) then
            WRITER(payloadToSend, outputOffset, SEGMENT_MARKER_ID)
            WRITER(payloadToSend, outputOffset + ID_BYTES, messageId)
            outputOffset = WriteVarUInt(payloadToSend, outputOffset + 2 * ID_BYTES, count)
            for bodyIndex = index, last do
                local bodyStart = sourceOffset + ID_BYTES
                local bodyEnd = UPPER_ENDS[bodyIndex]
                local bodySize = bodyEnd - bodyStart
                COPY_BODY
                sourceOffset = bodyEnd
            end
        else
            COPY_RUN
        end
        index = last + 1
    end]]
    flushSource = string.gsub(flushSource, "PREPARE_COMPRESSION", compressOutgoing and [[local compressedBodies = {}
    -- Each client batch starts a new history so rejected batches cannot desynchronize later ones.
    local nextState: CompressionState? = __nr_cloneCompressionState(nil)
    local sourceOffset, compressedSize = 0, UPPER_CURSOR
    for index = 1, UPPER_QUEUE_SIZE do
        local id = UPPER_IDS[index]
        local recordEnd = UPPER_ENDS[index]
        local widths: FieldWidths? = CompressionWidths[id]
        if widths ~= nil then
            local body
            body, nextState = __nr_compress(nextState, id, UPPER_ARENA, widths, sourceOffset + ID_BYTES, recordEnd - sourceOffset - ID_BYTES)
            compressedBodies[index] = body
            compressedSize += len(body) - (recordEnd - sourceOffset - ID_BYTES)
        end
        sourceOffset = recordEnd
    end]] or "")
    flushSource = string.gsub(flushSource, "OUTPUT_SIZE", compressOutgoing and "compressedSize" or "UPPER_CURSOR")
    local copyBody = compressOutgoing and [[local body = compressedBodies[bodyIndex]
                if body then
                    copy(payloadToSend, outputOffset, body)
                    outputOffset += len(body)
                else
                    copy(payloadToSend, outputOffset, UPPER_ARENA, bodyStart, bodySize)
                    outputOffset += bodySize
                end]] or [[copy(payloadToSend, outputOffset, UPPER_ARENA, bodyStart, bodySize)
                outputOffset += bodySize]]
    flushSource = string.gsub(flushSource, "COPY_RUN", compressOutgoing and [[for bodyIndex = index, last do
                WRITER(payloadToSend, outputOffset, messageId)
                outputOffset += ID_BYTES
                local bodyStart = sourceOffset + ID_BYTES
                local bodyEnd = UPPER_ENDS[bodyIndex]
                local bodySize = bodyEnd - bodyStart
                COPY_BODY
                sourceOffset = bodyEnd
            end]] or [[local runEnd = UPPER_ENDS[last]
            local runSize = runEnd - sourceOffset
            copy(payloadToSend, outputOffset, UPPER_ARENA, sourceOffset, runSize)
            outputOffset += runSize
            sourceOffset = runEnd]])
    flushSource = string.gsub(flushSource, "COPY_BODY", copyBody)
    flushSource = string.gsub(flushSource, "UPPER", upper)
    flushSource = string.gsub(flushSource, "PREFIX", prefix)
    flushSource = string.gsub(flushSource, "WRITER", messageIdWidth.writer)
    flushSource = string.gsub(flushSource, "ID_BYTES", tostring(messageIdWidth.bytes))
    for _, line in string.split(flushSource, "\n") do
        lines[#lines + 1] = line
    end
    if maxPassArgs == 0 then
        addLine(lines, 1, ("%s:%s(payloadToSend)"):format(remoteVar, fireMethod))
    else
        addLine(lines, 1, ("%s:%s(payloadToSend, table.unpack(%s_PASS_VALUES, 1, %s_PASS_SIZE))"):format(remoteVar, fireMethod, upper, upper))
        addLine(lines, 1, ("table.clear(%s_PASS_VALUES)"):format(upper))
        addLine(lines, 1, ("%s_PASS_SIZE = 0"):format(upper))
    end

    addLine(lines, 1, ("%s_CURSOR = 0"):format(upper))
    addLine(lines, 1, ("%s_QUEUE_SIZE = 0"):format(upper))
    addLine(lines, 1, ("table.clear(%s_ENDS)"):format(upper))
    addLine(lines, 1, ("table.clear(%s_IDS)"):format(upper))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitEventListener(
    lines: { string },
    isServer: boolean,
    prefix: string,
    remoteVar: string,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    local upper = string.upper(prefix)
    if isServer then
        if maxPassArgs > 0 then
            addLine(lines, 0, ("local function Receive%s(player: Player, payload: unknown, ...: unknown)"):format(prefix))
        else
            addLine(lines, 0, ("local function Receive%s(player: Player, payload: unknown)"):format(prefix))
        end
    else
        if maxPassArgs > 0 then
            addLine(lines, 0, ("local function Receive%s(payload: unknown, ...: unknown)"):format(prefix))
        else
            addLine(lines, 0, ("local function Receive%s(payload: unknown)"):format(prefix))
        end
    end
    if isServer then
        addLine(lines, 1, "if not Admit(player, typeof(payload) == \"buffer\" and len(payload) or 0, 0) then return end")
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, ("if payloadLength > %s then return end"):format(prefix == "Unreliable" and "MaxUnreliableBytes" or "MaxBatchBytes"))
    addLine(lines, 1, ("if payloadLength < %d then"):format(messageIdWidth.bytes))
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        -- Each message takes its schema's passthrough count from these arguments, in batch order.
        addLine(lines, 1, "local passTotal = select(\"#\", ...)")
        addLine(lines, 1, "local passValues = { ... }")
        addLine(lines, 1, "local passCursor = 0")
    end
    addLine(lines, 1, "local offset = 0")
    addLine(lines, 1, "local remainingMessages = MAX_BATCH_MESSAGES")
    if isServer then
        addLine(lines, 1, "local decodeBudget = { remaining = MaxDecodeWork }")
    end
    addLine(lines, 1, "while offset < payloadLength do")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 2, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
        addLine(lines, 3, "return")
        addLine(lines, 2, "end")
    end
    addLine(lines, 2, ("local messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 2, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 2, "local segmentCount = 1")
    addLine(lines, 2, "local dispatch")
    addLine(lines, 2, "if messageId == SEGMENT_MARKER_ID then")
    if messageIdWidth.bytes > 1 then
        addLine(lines, 3, ("if offset + %d > payloadLength then"):format(messageIdWidth.bytes))
    else
        addLine(lines, 3, "if offset >= payloadLength then")
    end
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, ("messageId = %s(payload, offset)"):format(messageIdWidth.reader))
    addLine(lines, 3, ("offset += %d"):format(messageIdWidth.bytes))
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 3, "segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)")
    addLine(lines, 3, "if segmentCount < 1 then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "else")
    addLine(lines, 3, ("dispatch = %s_DISPATCH[messageId]"):format(upper))
    addLine(lines, 3, "if dispatch == nil then")
    addLine(lines, 4, "return")
    addLine(lines, 3, "end")
    addLine(lines, 2, "end")
    addLine(lines, 2, "if segmentCount > remainingMessages then return end")
    if isServer then
        addLine(lines, 2, "if not Admit(player, nil, segmentCount) then return end")
    end
    addLine(lines, 2, "remainingMessages -= segmentCount")
    if maxPassArgs > 0 then
        addLine(lines, 2, ("local passWidth = %s_PASS_WIDTH[messageId]"):format(upper))
    end
    addLine(lines, 2, "for _segmentIndex = 1, segmentCount do")
    if maxPassArgs > 0 then
        -- A short call gives the message fewer values than its width, which its validator rejects.
        addLine(lines, 3, "local passCount = math.clamp(passTotal - passCursor, 0, passWidth)")
    end

    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    callArgs[#callArgs + 1] = "offset"
    if isServer then
        callArgs[#callArgs + 1] = "decodeBudget"
    end
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("passValues[passCursor + %d]"):format(passIndex)
    end
    addLine(lines, 3, ("local nextOffset = dispatch(%s)"):format(join(callArgs)))
    if maxPassArgs > 0 then
        -- The cursor moves by the schema width even when dispatch drops the message, so later messages keep their values.
        addLine(lines, 3, "passCursor += passWidth")
    end
    do
        addLine(lines, 3, "if type(nextOffset) ~= \"number\" then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
        addLine(lines, 3, "if nextOffset < offset or nextOffset > payloadLength then")
        addLine(lines, 4, "return")
        addLine(lines, 3, "end")
    end
    addLine(lines, 3, "offset = nextOffset")
    addLine(lines, 2, "end")
    addLine(lines, 1, "end")
    addLine(lines, 0, "end")
    addLine(lines, 0, ("%s.%s:Connect(function(...)"):format(remoteVar, isServer and "OnServerEvent" or "OnClientEvent"))
    addLine(lines, 1, ("xpcall(Receive%s, ReportError, ...)"):format(prefix))
    addLine(lines, 0, "end)")
    addLine(lines, 0, "")
end

local function emitFunctionInvoke(
    lines: { string },
    isServer: boolean,
    maxPassArgs: number,
    messageIdWidth: WidthInfo,
    validateLevel: Analyzer.ValidateLevel
)
    if isServer then
        addLine(lines, 0, "FunctionRemote.OnServerInvoke = function(player, payload, ...)")
    else
        addLine(lines, 0, "FunctionRemote.OnClientInvoke = function(payload, ...)")
    end
    if isServer then
        addLine(lines, 1, "if not Admit(player, typeof(payload) == \"buffer\" and len(payload) or 0, 1) then error(ERR_BOUNDS) end")
    end
    addLine(lines, 1, "if typeof(payload) ~= \"buffer\" then")
    emitError(lines, 2, validateLevel, "Function payload must be a buffer", "ERR_TYPE")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local payloadLength = len(payload)")
    addLine(lines, 1, "if payloadLength > MaxBatchBytes then error(ERR_BOUNDS) end")
    addLine(lines, 1, ("if payloadLength < %d then"):format(messageIdWidth.bytes))
    emitError(lines, 2, validateLevel, "Function payload too short", "ERR_BOUNDS")
    addLine(lines, 1, "end")
    addLine(lines, 1, ("local messageId = %s(payload, 0)"):format(messageIdWidth.reader))
    addLine(lines, 1, "local dispatch = FUNCTION_DISPATCH[messageId]")
    addLine(lines, 1, "if dispatch == nil then")
    emitError(lines, 2, validateLevel, "No function dispatch for message ID", "ERR_SCHEMA")
    addLine(lines, 1, "end")
    if maxPassArgs > 0 then
        addLine(lines, 1, "local passCount = select(\"#\", ...)")
    end
    local passArgs: { string } = {}
    for passIndex = 1, maxPassArgs do
        passArgs[#passArgs + 1] = ("pass%d"):format(passIndex)
    end
    if #passArgs > 0 then
        addLine(lines, 1, ("local %s = ..."):format(join(passArgs)))
    end
    local callArgs: { string } = {}
    if isServer then
        callArgs[#callArgs + 1] = "player"
    end
    callArgs[#callArgs + 1] = "payload"
    callArgs[#callArgs + 1] = "payloadLength"
    if maxPassArgs > 0 then
        callArgs[#callArgs + 1] = "passCount"
    end
    for passIndex = 1, maxPassArgs do
        callArgs[#callArgs + 1] = ("pass%d"):format(passIndex)
    end
    addLine(lines, 1, ("return dispatch(%s)"):format(join(callArgs)))
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
end

local function emitCommonRuntimePreamble(lines: { string }, schema: Analyzer.AnalyzedSchema, isServer: boolean)
    addLine(lines, 0, "local RunService = game:GetService(\"RunService\")")
    addLine(lines, 0, "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")")
    if isServer then
        addLine(lines, 0, "local Players = game:GetService(\"Players\")")
    end
    addLine(lines, 0, "")

    if isServer then
        addLine(lines, 0, "local function FindOrCreateRemote(className: string, remoteName: string): Instance")
        addLine(lines, 1, "local existing = ReplicatedStorage:FindFirstChild(remoteName)")
        addLine(lines, 1, "if existing ~= nil then")
        addLine(lines, 2, "if existing.ClassName ~= className then")
        addLine(lines, 3, "error((\"Remote '%s' exists as '%s', expected '%s'\"):format(remoteName, existing.ClassName, className))")
        addLine(lines, 2, "end")
        addLine(lines, 2, "return existing")
        addLine(lines, 1, "end")
        addLine(lines, 1, "local remote = Instance.new(className)")
        addLine(lines, 1, "remote.Name = remoteName")
        addLine(lines, 1, "remote.Parent = ReplicatedStorage")
        addLine(lines, 1, "return remote")
        addLine(lines, 0, "end")
        addLine(lines, 0, "")
        addLine(lines, 0, ("local Reliable = FindOrCreateRemote(\"RemoteEvent\", %q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = FindOrCreateRemote(\"UnreliableRemoteEvent\", %q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = FindOrCreateRemote(\"RemoteFunction\", %q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    else
        addLine(lines, 0, ("local Reliable = ReplicatedStorage:WaitForChild(%q) :: RemoteEvent"):format(schema.remoteScope .. "_RELIABLE"))
        addLine(lines, 0, ("local Unreliable = ReplicatedStorage:WaitForChild(%q) :: UnreliableRemoteEvent"):format(schema.remoteScope .. "_UNRELIABLE"))
        addLine(lines, 0, ("local FunctionRemote = ReplicatedStorage:WaitForChild(%q) :: RemoteFunction"):format(schema.remoteScope .. "_FUNCTION"))
    end

    addLine(lines, 0, "")
    addLine(lines, 0, "local function WithCount(...)")
    addLine(lines, 1, "return select(\"#\", ...), ...")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local DEFAULT_BATCH_CAPACITY = 2048")
    addLine(lines, 0, ("local MAX_BATCH_MESSAGES = %s"):format(limitLiteral(schema.limits.MaxBatchMessages)))
    addLine(lines, 0, "local DEFAULT_ARENA_CAPACITY = 256")
    for _, name in { "MaxBatchBytes", "MaxUnreliableBytes", "MaxPollingMessages", "MaxDecodeWork" } do
        addLine(lines, 0, ("local %s = %s"):format(name, limitLiteral(schema.limits[name])))
    end
    addLine(lines, 0, "local LastErrorTime = -math.huge")
    addLine(lines, 0, "local function ReportError(message: unknown)")
    addLine(lines, 1, "local now = os.clock()")
    addLine(lines, 1, "if now - LastErrorTime >= 1 then LastErrorTime = now; warn(message) end")
    addLine(lines, 0, "end")
    if isServer then
        local metrics = { { "calls", "ReceiveCallBurst", "ReceiveCallsPerSecond" }, { "bytes", "ReceiveByteBurst", "ReceiveBytesPerSecond" }, { "messages", "ReceiveMessageBurst", "ReceiveMessagesPerSecond" } }
        local enabled = false
        for _, metric in metrics do
            if schema.limits[metric[2]] > 0 or schema.limits[metric[3]] > 0 then enabled = true end
        end
        local budgetFields: { string } = { "time: number" }
        local budgetInit: { string } = { "time = now" }
        for _, metric in metrics do
            local burst, rate = schema.limits[metric[2]], schema.limits[metric[3]]
            if burst > 0 or rate > 0 then
                budgetFields[#budgetFields + 1] = metric[1] .. ": number"
                budgetInit[#budgetInit + 1] = ("%s = %s"):format(metric[1], burst > 0 and burst or rate)
            end
        end
        if enabled then
            addLine(lines, 0, ("type ReceiveBudget = { %s }"):format(join(budgetFields)))
            addLine(lines, 0, "local ReceiveBudgets: { [Player]: ReceiveBudget } = setmetatable({}, { __mode = \"k\" })")
        end
        addLine(lines, 0, "local function Admit(player: Player, byteCost: number?, messageCost: number): boolean")
        if enabled then
            addLine(lines, 1, "local now = os.clock()")
            addLine(lines, 1, "local state = ReceiveBudgets[player]")
            addLine(lines, 1, ("if state == nil then state = { %s }; ReceiveBudgets[player] = state end"):format(join(budgetInit)))
            addLine(lines, 1, "local elapsed = math.max(0, now - state.time)")
            addLine(lines, 1, "state.time = now")
            for _, metric in metrics do
                local burst, rate = schema.limits[metric[2]], schema.limits[metric[3]]
                if burst > 0 or rate > 0 then
                    if burst == 0 then burst = rate end
                    if rate == 0 then rate = burst end
                    addLine(lines, 1, ("state.%s = math.min(%s, state.%s + elapsed * %s)"):format(metric[1], burst, metric[1], rate))
                    local cost = metric[1] == "calls" and "(byteCost ~= nil and 1 or 0)" or (metric[1] == "bytes" and "(byteCost or 0)" or "messageCost")
                    addLine(lines, 1, ("if state.%s < %s then return false end"):format(metric[1], cost))
                    addLine(lines, 1, ("state.%s -= %s"):format(metric[1], cost))
                end
            end
        end
        addLine(lines, 1, "return true")
        addLine(lines, 0, "end")
    end
    addLine(lines, 0, "local create = buffer.create")
    addLine(lines, 0, "local copy = buffer.copy")
    addLine(lines, 0, "local len = buffer.len")
    addLine(lines, 0, "local writeu8 = buffer.writeu8")
    addLine(lines, 0, "local writei8 = buffer.writei8")
    addLine(lines, 0, "local writeu16 = buffer.writeu16")
    addLine(lines, 0, "local writei16 = buffer.writei16")
    addLine(lines, 0, "local writeu32 = buffer.writeu32")
    addLine(lines, 0, "local writei32 = buffer.writei32")
    addLine(lines, 0, "local function writef16(payload: buffer, offset: number, value: number)")
    addLine(lines, 1, "local sign = 0")
    addLine(lines, 1, "if value < 0 or (value == 0 and 1 / value < 0) then")
    addLine(lines, 2, "sign = 32768")
    addLine(lines, 2, "value = -value")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value ~= value then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 32256)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value == math.huge then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value == 0 then")
    addLine(lines, 2, "writeu16(payload, offset, sign)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local fraction, exponent = math.frexp(value)")
    addLine(lines, 1, "local exp = exponent - 1")
    addLine(lines, 1, "local mant = fraction * 2 - 1")
    addLine(lines, 1, "local halfExp = exp + 15")
    addLine(lines, 1, "local halfMant")
    addLine(lines, 1, "if halfExp <= 0 then")
    addLine(lines, 2, "local scaled = value / (2 ^ -24)")
    addLine(lines, 2, "halfMant = math.floor(scaled)")
    addLine(lines, 2, "local remainder = scaled - halfMant")
    addLine(lines, 2, "if remainder > 0.5 or (remainder == 0.5 and halfMant % 2 ~= 0) then halfMant += 1 end")
    addLine(lines, 2, "writeu16(payload, offset, sign + halfMant)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if halfExp >= 31 then")
    addLine(lines, 2, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 2, "return")
    addLine(lines, 1, "end")
    addLine(lines, 1, "local scaled = mant * 1024")
    addLine(lines, 1, "halfMant = math.floor(scaled)")
    addLine(lines, 1, "local remainder = scaled - halfMant")
    addLine(lines, 1, "if remainder > 0.5 or (remainder == 0.5 and halfMant % 2 ~= 0) then halfMant += 1 end")
    addLine(lines, 1, "if halfMant >= 1024 then")
    addLine(lines, 2, "halfMant = 0")
    addLine(lines, 2, "halfExp += 1")
    addLine(lines, 2, "if halfExp >= 31 then")
    addLine(lines, 3, "writeu16(payload, offset, sign + 31744)")
    addLine(lines, 3, "return")
    addLine(lines, 2, "end")
    addLine(lines, 1, "end")
    addLine(lines, 1, "writeu16(payload, offset, sign + halfExp * 1024 + halfMant)")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local writef32 = buffer.writef32")
    addLine(lines, 0, "local writef64 = buffer.writef64")
    addLine(lines, 0, "local writestring = buffer.writestring")
    addLine(lines, 0, "local readu8 = buffer.readu8")
    addLine(lines, 0, "local readi8 = buffer.readi8")
    addLine(lines, 0, "local readu16 = buffer.readu16")
    addLine(lines, 0, "local readi16 = buffer.readi16")
    addLine(lines, 0, "local readu32 = buffer.readu32")
    addLine(lines, 0, "local readi32 = buffer.readi32")
    addLine(lines, 0, "local function readf16(payload: buffer, offset: number): number")
    addLine(lines, 1, "local bits = readu16(payload, offset)")
    addLine(lines, 1, "local sign = if bit32.band(bits, 32768) ~= 0 then -1 else 1")
    addLine(lines, 1, "local exp = bit32.band(bit32.rshift(bits, 10), 31)")
    addLine(lines, 1, "local mant = bit32.band(bits, 1023)")
    addLine(lines, 1, "if exp == 0 then")
    addLine(lines, 2, "if mant == 0 then")
    addLine(lines, 3, "return sign * 0")
    addLine(lines, 2, "end")
    addLine(lines, 2, "return sign * (mant / 1024) * (2 ^ -14)")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if exp == 31 then")
    addLine(lines, 2, "if mant == 0 then")
    addLine(lines, 3, "return sign * math.huge")
    addLine(lines, 2, "end")
    addLine(lines, 2, "return math.huge * 0")
    addLine(lines, 1, "end")
    addLine(lines, 1, "return sign * (1 + mant / 1024) * (2 ^ (exp - 15))")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local readf32 = buffer.readf32")
    addLine(lines, 0, "local readf64 = buffer.readf64")
    addLine(lines, 0, "local readstring = buffer.readstring")
    addLine(lines, 0, "local band = bit32.band")
    addLine(lines, 0, "local bor = bit32.bor")
    addLine(lines, 0, "local rshift = bit32.rshift")
    addLine(lines, 0, "local lshift = bit32.lshift")
    addLine(lines, 0, "")
end

local function generateRuntime(schema: Analyzer.AnalyzedSchema, isServer: boolean): string
    local validateLevel = schema.validateLevel
    local decodeStructMode = resolveDecodeStruct(schema.options)
    local messages: { MessageInfo } = {}
    local symbolByMessage: { [Analyzer.AnalyzedMessage]: string } = {}
    collectMessages(schema.root, schema.root.name, messages, symbolByMessage)
    local lines: { string } = {
        "--!strict",
        "--!native",
        "--!optimize 2",
        "--!nolint LocalShadow",
        "--#selene: allow(shadowing)",
        isServer and "-- Name: Server" or "-- Name: Client",
        isServer and "-- Purpose: Generated runtime for server networking" or "-- Purpose: Generated runtime for client networking",
        "-- Generated-by: NetRay-Compiler",
        "-- Version: "..Version,
        "",
    }

    addLine(lines, 0, "local Types = require(script.Parent.Types)")
    addLine(lines, 0, "type u8 = Types.u8")
    addLine(lines, 0, "type i8 = Types.i8")
    addLine(lines, 0, "type u16 = Types.u16")
    addLine(lines, 0, "type i16 = Types.i16")
    addLine(lines, 0, "type u32 = Types.u32")
    addLine(lines, 0, "type i32 = Types.i32")
    addLine(lines, 0, "type f16 = Types.f16")
    addLine(lines, 0, "type f32 = Types.f32")
    addLine(lines, 0, "type f64 = Types.f64")
    addLine(lines, 0, ("type NetRoot = Types.%s"):format(isServer and "NetServer" or "NetClient"))
    addLine(lines, 0, "type NetStats = Types.NetStats")
    addLine(lines, 0, "type Connection = Types.Connection")
    addLine(lines, 0, "type DecodeBudget = { remaining: number, compression: any }")
    addLine(lines, 0, "type Dispatch = (...any) -> ...any")
    for structIndex = 1, #schema.structs do
        local structName = schema.structs[structIndex].name
        addLine(lines, 0, ("type %s = Types.%s"):format(structName, structName))
    end
    for messageIndex = 1, #messages do
        local messageInfo = messages[messageIndex]
        local message = messageInfo.message
        local apiTypeName = isServer and messageServerApiTypeName(messageInfo.apiBase) or messageClientApiTypeName(messageInfo.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(messageInfo.apiBase, message.category)
            or messageClientCallbackTypeName(messageInfo.apiBase, message.category)
        addLine(lines, 0, ("type %s = Types.%s"):format(apiTypeName, apiTypeName))
        addLine(lines, 0, ("type %s = Types.%s"):format(callbackTypeName, callbackTypeName))
    end
    addLine(lines, 0, "")

    emitCommonRuntimePreamble(lines, schema, isServer)

    addLine(lines, 0, "local ERR_BOUNDS = \"E_BOUNDS\"")
    addLine(lines, 0, "local ERR_SCHEMA = \"E_SCHEMA\"")
    addLine(lines, 0, "local ERR_TAG = \"E_TAG\"")
    addLine(lines, 0, "local ERR_TYPE = \"E_TYPE\"")
    addLine(lines, 0, "local ERR_PASS = \"E_PASS\"")
    addLine(lines, 0, "local SEGMENT_MARKER_ID = 0")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function VarUIntSize(value: number): number")
    addLine(lines, 1, "if value < 128 then return 1 end")
    addLine(lines, 1, "if value < 16384 then return 2 end")
    addLine(lines, 1, "if value < 2097152 then return 3 end")
    addLine(lines, 1, "if value < 268435456 then return 4 end")
    addLine(lines, 1, "return 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function WriteVarUInt(payload: buffer, offset: number, value: number): number")
    addLine(lines, 1, "if value < 128 then")
    addLine(lines, 2, "writeu8(payload, offset, value)")
    addLine(lines, 2, "return offset + 1")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 16384 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, band(rshift(value, 7), 127))")
    addLine(lines, 2, "return offset + 2")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 2097152 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, band(rshift(value, 14), 127))")
    addLine(lines, 2, "return offset + 3")
    addLine(lines, 1, "end")
    addLine(lines, 1, "if value < 268435456 then")
    addLine(lines, 2, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 2, "writeu8(payload, offset + 3, band(rshift(value, 21), 127))")
    addLine(lines, 2, "return offset + 4")
    addLine(lines, 1, "end")
    addLine(lines, 1, "writeu8(payload, offset, bor(band(value, 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 3, bor(band(rshift(value, 21), 127), 128))")
    addLine(lines, 1, "writeu8(payload, offset + 4, band(rshift(value, 28), 15))")
    addLine(lines, 1, "return offset + 5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "local function ReadVarUInt(payload: buffer, payloadLength: number, offset: number): (number, number)")
    addLine(lines, 1, "local next1 = offset + 1")
    addLine(lines, 1, "if next1 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b1 = readu8(payload, offset)")
    addLine(lines, 1, "if b1 < 128 then return b1, next1 end")
    addLine(lines, 1, "local next2 = next1 + 1")
    addLine(lines, 1, "if next2 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b2 = readu8(payload, next1)")
    addLine(lines, 1, "local value = band(b1, 127) + lshift(band(b2, 127), 7)")
    addLine(lines, 1, "if b2 < 128 then return value, next2 end")
    addLine(lines, 1, "local next3 = next2 + 1")
    addLine(lines, 1, "if next3 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b3 = readu8(payload, next2)")
    addLine(lines, 1, "value += lshift(band(b3, 127), 14)")
    addLine(lines, 1, "if b3 < 128 then return value, next3 end")
    addLine(lines, 1, "local next4 = next3 + 1")
    addLine(lines, 1, "if next4 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b4 = readu8(payload, next3)")
    addLine(lines, 1, "value += lshift(band(b4, 127), 21)")
    addLine(lines, 1, "if b4 < 128 then return value, next4 end")
    addLine(lines, 1, "local next5 = next4 + 1")
    addLine(lines, 1, "if next5 > payloadLength then error(ERR_BOUNDS) end")
    addLine(lines, 1, "local b5 = readu8(payload, next4)")
    addLine(lines, 1, "if b5 >= 16 then error(ERR_SCHEMA) end")
    addLine(lines, 1, "value += lshift(b5, 28)")
    addLine(lines, 1, "return value, next5")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    addLine(lines, 0, "local function CreateConnection(disconnectFn: () -> ()): Connection")
    addLine(lines, 1, "local active = true")
    addLine(lines, 1, "local connection = {} :: any")
    addLine(lines, 1, "connection.Connected = true")
    addLine(lines, 1, "function connection:Disconnect()")
    addLine(lines, 2, "if not active then")
    addLine(lines, 3, "return")
    addLine(lines, 2, "end")
    addLine(lines, 2, "active = false")
    addLine(lines, 2, "connection.Connected = false")
    addLine(lines, 2, "disconnectFn()")
    addLine(lines, 1, "end")
    addLine(lines, 1, "return connection :: Connection")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")

    local maxReliableId = 0
    local maxUnreliableId = 0
    local maxFunctionId = 0
    addLine(lines, 0, "local APIs: { any } = {}")
    for index = 1, #messages do
        local info = messages[index]
        local category = info.message.category
        if category == "reliable" then
            if info.message.id > maxReliableId then
                maxReliableId = info.message.id
            end
        elseif category == "unreliable" then
            if info.message.id > maxUnreliableId then
                maxUnreliableId = info.message.id
            end
        elseif category == "function" then
            if info.message.id > maxFunctionId then
                maxFunctionId = info.message.id
            end
        end
    end

    local reliableMessageIdWidth = getMessageIdWidthInfo(maxReliableId)
    local unreliableMessageIdWidth = getMessageIdWidthInfo(maxUnreliableId)
    local functionMessageIdWidth = getMessageIdWidthInfo(maxFunctionId)

    addLine(lines, 0, ("local MAX_RELIABLE_ID = %d"):format(maxReliableId))
    addLine(lines, 0, ("local MAX_UNRELIABLE_ID = %d"):format(maxUnreliableId))
    addLine(lines, 0, ("local MAX_FUNCTION_ID = %d"):format(maxFunctionId))
    addLine(lines, 0, "local RELIABLE_DISPATCH = table.create(MAX_RELIABLE_ID) :: { Dispatch }")
    addLine(lines, 0, "local UNRELIABLE_DISPATCH = table.create(MAX_UNRELIABLE_ID) :: { Dispatch }")
    addLine(lines, 0, "local FUNCTION_DISPATCH = table.create(MAX_FUNCTION_ID) :: { Dispatch }")
    if schema.maxPassArgs.reliable > 0 or schema.maxPassArgs.unreliable > 0 then
        -- Passthrough values travel as the remote call's own arguments; Studio delivered 4096 of them in one call.
        addLine(lines, 0, "local MAX_PASS_VALUES = 4096")
    end
    if schema.maxPassArgs.reliable > 0 then
        addLine(lines, 0, "local RELIABLE_PASS_WIDTH: { number } = table.create(MAX_RELIABLE_ID, 0)")
    end
    if schema.maxPassArgs.unreliable > 0 then
        addLine(lines, 0, "local UNRELIABLE_PASS_WIDTH: { number } = table.create(MAX_UNRELIABLE_ID, 0)")
    end
    addLine(lines, 0, "")

    local hasCompression = false
    for _, info in messages do if info.message.compression ~= nil then hasCompression = true end end
    if hasCompression then
        Compression.emit(lines)
        addLine(lines, 0, "local CompressionWidths: { [number]: FieldWidths } = {}")
        if not isServer then addLine(lines, 0, "local ReceiveCompression: CompressionState? = nil") end
        for _, info in messages do
            if info.message.compression ~= nil then
                local widths = {}
                if info.message.compression == "Fields" then
                    for _, param in info.serializedParams do
                        local width = Utilities.computeFixedByteSize(param.type, schema.structByName, {})
                        if width == nil then error("Field compression requires fixed serialized fields") end
                        widths[#widths + 1] = tostring(width)
                    end
                end
                addLine(lines, 0, ("CompressionWidths[%d] = %s"):format(info.message.id, info.message.compression == "Fields" and ("{" .. table.concat(widths, ", ") .. "}") or "false"))
            end
        end
    end

    emitQueue(
        lines,
        "Reliable",
        "Reliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel,
        hasCompression and not isServer
    )
    emitQueue(
        lines,
        "Unreliable",
        "Unreliable",
        isServer and "FireAllClients" or "FireServer",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )


    if isServer then
        local targetedSource = [[
TARGET_QUEUE_TYPE
local Targeted: { [Player]: TargetQueue } = {}
local TargetedBytes = 0
local TargetedCount = 0
COMPRESSION_DECL
local function FlushTargeted()
    local pending = Targeted
    Targeted = {}
    TargetedBytes, TargetedCount = 0, 0
    for player, queue in pending do
        local records: { buffer } = {}
        local outputBytes = 0
        COMPRESSION_STATE
        for index = 1, #queue do
            local record = queue[index][1]
            COMPRESSION_RECORD
            records[index] = record
            outputBytes += len(record)
        end
        local payload = create(outputBytes)
        local offset = 0
        PASS_SETUP
        for index = 1, #queue do
            local bytes = len(records[index])
            copy(payload, offset, records[index], 0, bytes)
            offset += bytes
            PASS_COLLECT
        end
        local ok = xpcall(Reliable.FireClient, ReportError, Reliable, player, payload PASS_ARGS)
        COMPRESSION_COMMIT
        if not ok then
            RELIABLE_DROPPED += #queue
        end
    end
end
local function QueueTarget(player: Player, payload: buffer, ...: any): boolean
    FlushReliable()
    local bytes = len(payload) COMPRESSION_RESERVE
    if bytes > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    TARGET_FLUSH
    local queue = Targeted[player]
    TARGET_QUEUE_PUSH
    queue.bytes += bytes
    TargetedBytes += bytes
    TargetedCount += 1
    return true
end
Players.PlayerRemoving:Connect(function(player: Player)
    local queue = Targeted[player]
    if queue then TargetedBytes -= queue.bytes; TargetedCount -= #queue; Targeted[player] = nil end
    COMPRESSION_REMOVE
end)
]]
        -- With no passthrough arguments the passthrough bookkeeping would be dead code, so it is left out.
        local maxPass = schema.maxPassArgs.reliable
        if maxPass > 0 then
            targetedSource = string.gsub(targetedSource, "TARGET_QUEUE_TYPE", "type TargetQueue = { bytes: number, passes: number, [number]: { any } }")
            -- A record keeps its passthrough count, since values that are nil under Validate Off leave no length.
            targetedSource = string.gsub(targetedSource, "TARGET_FLUSH", [[local passCount = select("#", ...)
    local pending = Targeted[player]
    if TargetedBytes + bytes > MaxBatchBytes or TargetedCount >= MAX_BATCH_MESSAGES or (pending ~= nil and pending.passes + passCount > MAX_PASS_VALUES) then FlushTargeted() end]])
            targetedSource = string.gsub(targetedSource, "TARGET_QUEUE_PUSH", [[if queue == nil then queue = { bytes = 0, passes = 0 }; Targeted[player] = queue end
    queue[#queue + 1] = { payload, passCount, ... }
    queue.passes += passCount]])
            targetedSource = string.gsub(targetedSource, "PASS_SETUP", [[local passValues: { unknown } = table.create(queue.passes)
        local passCount = 0]])
            targetedSource = string.gsub(targetedSource, "PASS_COLLECT", [=[local message = queue[index]
            for passIndex = 1, message[2] do
                passValues[passCount + passIndex] = message[passIndex + 2]
            end
            passCount += message[2]]=])
            targetedSource = string.gsub(targetedSource, " PASS_ARGS", ", table.unpack(passValues, 1, passCount)")
        else
            targetedSource = string.gsub(targetedSource, "TARGET_QUEUE_TYPE", "type TargetQueue = { bytes: number, [number]: { any } }")
            targetedSource = string.gsub(targetedSource, "TARGET_FLUSH", "if TargetedBytes + bytes > MaxBatchBytes or TargetedCount >= MAX_BATCH_MESSAGES then FlushTargeted() end")
            targetedSource = string.gsub(targetedSource, "TARGET_QUEUE_PUSH", [[if queue == nil then queue = { bytes = 0 }; Targeted[player] = queue end
    queue[#queue + 1] = { payload, ... }]])
            targetedSource = string.gsub(targetedSource, "PASS_SETUP", "")
            targetedSource = string.gsub(targetedSource, "PASS_COLLECT", "")
            targetedSource = string.gsub(targetedSource, " PASS_ARGS", "")
        end
        targetedSource = string.gsub(targetedSource, "COMPRESSION_DECL", hasCompression and 'local TargetCompression: { [Player]: CompressionState } = setmetatable({}, { __mode = "k" })' or "")
        targetedSource = string.gsub(targetedSource, "COMPRESSION_STATE", hasCompression and "local nextState: CompressionState? = __nr_cloneCompressionState(TargetCompression[player])" or "")
        targetedSource = string.gsub(targetedSource, "COMPRESSION_RECORD", hasCompression and ([[local id = %s(record, 0)
            local widths: FieldWidths? = CompressionWidths[id]
            if widths ~= nil then
                local encoded
                encoded, nextState = __nr_compress(nextState, id, record, widths, %d)
                local framed = create(%d + len(encoded))
                %s(framed, 0, id)
                copy(framed, %d, encoded, 0, len(encoded))
                record = framed
            end]]):format(reliableMessageIdWidth.reader, reliableMessageIdWidth.bytes, reliableMessageIdWidth.bytes, reliableMessageIdWidth.writer, reliableMessageIdWidth.bytes) or "")
        targetedSource = string.gsub(targetedSource, "COMPRESSION_COMMIT", hasCompression and "if ok then TargetCompression[player] = nextState end" or "")
        targetedSource = string.gsub(targetedSource, "COMPRESSION_RESERVE", hasCompression and ("+ (CompressionWidths[%s(payload, 0)] ~= nil and 1 or 0)"):format(reliableMessageIdWidth.reader) or "")
        targetedSource = string.gsub(targetedSource, "COMPRESSION_REMOVE", hasCompression and "TargetCompression[player] = nil" or "")
        for _, line in string.split(targetedSource, "\n") do lines[#lines + 1] = line end
    end

    for index = 1, #messages do
        local info = messages[index]
        local symbol = info.symbol
        local message = info.message
        local messageIdWidth: WidthInfo
        if message.category == "reliable" then
            messageIdWidth = reliableMessageIdWidth
        elseif message.category == "unreliable" then
            messageIdWidth = unreliableMessageIdWidth
        else
            messageIdWidth = functionMessageIdWidth
        end
        local requestNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughParams > 0
        local returnNeedsPassValidation = validateLevel ~= "Off" and #info.passthroughReturns > 0
        local includeRequestEncode = message.category == "function" or canSendEvent(message.from, isServer)
        local includeRequestDecode = message.category == "function" or canReceiveEvent(message.from, isServer)
        local messageIdConst = "MESSAGE_ID_" .. symbol
        local encodeRequestName = "Encode_" .. symbol
        local decodeRequestName = "Decode_" .. symbol
        local requestPassValidator = "ValidatePass_" .. symbol
        local handlerName = "Handler_" .. symbol
        local handlerTokenName = "HandlerToken_" .. symbol
        local responsePassValidator = "ValidateReturnPass_" .. symbol
        local encodeResponseName = "EncodeReturn_" .. symbol
        local decodeResponseName = "DecodeReturn_" .. symbol
        local apiTypeName = isServer and messageServerApiTypeName(info.apiBase) or messageClientApiTypeName(info.apiBase)
        local callbackTypeName = isServer and messageServerCallbackTypeName(info.apiBase, message.category)
            or messageClientCallbackTypeName(info.apiBase, message.category)
        local requestDecodePlans = buildDecodedParamPlans(info.serializedParams, schema.structByName, decodeStructMode)
        local requestDecodedVars = collectDecodedLeafNames(requestDecodePlans)

        addLine(lines, 0, "do")
        addLine(lines, 0, ("local %s: %s = {} :: %s"):format(symbol, apiTypeName, apiTypeName))
        addLine(lines, 0, ("local %s = %d"):format(messageIdConst, message.id))
        addLine(lines, 0, "")

        if requestNeedsPassValidation then
            emitPassthroughValidator(lines, requestPassValidator, info.passthroughParams, validateLevel)
        end
        emitCodecFunctions(
            lines,
            encodeRequestName,
            decodeRequestName,
            messageIdConst,
            messageIdWidth,
            info.serializedParams,
            info.fullName,
            validateLevel,
            schema.structByName,
            includeRequestEncode,
            includeRequestDecode,
            decodeStructMode
        )

        if message.category == "function" then
            if returnNeedsPassValidation then
                emitPassthroughValidator(lines, responsePassValidator, info.passthroughReturns, validateLevel)
            end
            emitCodecFunctions(
                lines,
                encodeResponseName,
                decodeResponseName,
                messageIdConst,
                messageIdWidth,
                info.serializedReturns,
                info.fullName .. " return",
                validateLevel,
                schema.structByName,
                true,
                true,
                "Table"
            )
        end

        local handlerReturnParams: { Ast.Param } = {}
        if message.category == "function" then
            handlerReturnParams = message.returns or {}
        end
        local handlerParams = expandDecodeParams(message.params, schema.structByName, decodeStructMode)
        local handlerType = callbackTypeExpr(handlerParams, isServer, handlerReturnParams)
        addLine(lines, 0, ("local %s: (%s)? = nil"):format(handlerName, handlerType))
        addLine(lines, 0, ("local %s = 0"):format(handlerTokenName))
        addLine(lines, 0, "")

        if message.category == "reliable" or message.category == "unreliable" then
            local methodName = isServer and "FireAll" or "Fire"
            local allParamSignature = typedParamList(message.params)
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local queueUpper = message.category == "unreliable" and "UNRELIABLE" or "RELIABLE"
            local targetCall = message.category == "unreliable" and "Unreliable:FireClient" or "QueueTarget"
            local categoryMaxPass = schema.maxPassArgs[message.category]
            local eventCallbackType = callbackTypeName
            local usesCanonicalLayout = paramsHaveVariableLength(info.serializedParams, schema.structByName)
            local canonicalFixedSize = usesCanonicalLayout and fixedBytesForCanonicalParams(info.serializedParams, schema.structByName) or 0
            local canUseFlatSize = (not usesCanonicalLayout) and canEmitFlatTopLevelSize(info.serializedParams, schema.structByName)
            local canEmitFire = includeRequestEncode
            local canEmitOn = includeRequestDecode
            local skipName = "Skip_" .. symbol
            local eventCall = message.call or "ManySync"
            local eventIsSingle = eventCall == "SingleSync" or eventCall == "SingleAsync"
            local eventIsMany = eventCall == "ManySync" or eventCall == "ManyAsync"
            local eventIsAsync = eventCall == "SingleAsync" or eventCall == "ManyAsync"
            local eventIsPolling = eventCall == "Polling"
            local handlerListName = "Handlers_" .. symbol
            local handlerFreeSlotsName = "HandlerFreeSlots_" .. symbol
            local handlerCountName = "HandlerCount_" .. symbol

            local callbackArgs: { string } = {}
            local callbackArgTypes: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
                callbackArgTypes[#callbackArgTypes + 1] = "Player"
            end
            local serializedIndex = 0
            local passthroughIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    passthroughIndex += 1
                    -- The passthrough validator has already checked the value against this type.
                    local passType = toLuauType(param.type)
                    callbackArgs[#callbackArgs + 1] = ("pass%d :: %s"):format(passthroughIndex, passType)
                    callbackArgTypes[#callbackArgTypes + 1] = passType
                else
                    serializedIndex += 1
                    local leaves = requestDecodePlans[serializedIndex].leaves
                    for leafIndex = 1, #leaves do
                        callbackArgs[#callbackArgs + 1] = leaves[leafIndex].targetName
                        callbackArgTypes[#callbackArgTypes + 1] = toLuauType(leaves[leafIndex].typeDef)
                    end
                end
            end
            local callbackArgList = join(callbackArgs)

            local pollingHeadName = "PollHead_" .. symbol
            local pollingTailName = "PollTail_" .. symbol
            local pollingArgNames: { string } = {}
            if canEmitOn and isServer and message.rate ~= nil then
                addLine(lines, 0, 'local EventBudgets: { [Player]: { time: number, tokens: number } } = setmetatable({}, { __mode = "k" })')
            end
            if canEmitOn and eventIsPolling then
                addLine(lines, 0, ("local %s = 1"):format(pollingHeadName))
                addLine(lines, 0, ("local %s = 0"):format(pollingTailName))
                for argIndex = 1, #callbackArgs do
                    local pollArgName = ("PollArg_%d_%s"):format(argIndex, symbol)
                    pollingArgNames[#pollingArgNames + 1] = pollArgName
                    addLine(lines, 0, ("local %s = table.create(DEFAULT_BATCH_CAPACITY) :: { %s }"):format(pollArgName, callbackArgTypes[argIndex]))
                end
                addLine(lines, 0, "")
            end

            if canEmitOn and eventIsMany then
                addLine(lines, 0, ("local %s: { %s } = {}"):format(handlerListName, eventCallbackType))
                addLine(lines, 0, ("local %s: { number } = {}"):format(handlerFreeSlotsName))
                addLine(lines, 0, ("local %s = 0"):format(handlerCountName))
                addLine(lines, 0, "")
            end

            if canEmitFire or (canEmitOn and (message.max ~= nil or (isServer and message.rate ~= nil))) then
                emitSkipFunction(lines, skipName, info.serializedParams, info.fullName, validateLevel, schema.structByName)
                addLine(lines, 0, "")
            end

            if canEmitFire then
                addLine(lines, 0, ("function %s.%s(%s): boolean"):format(symbol, methodName, allParamSignature))
                if isServer and message.compression ~= nil then
                    addLine(lines, 1, ("return %s.FireList(Players:GetPlayers()%s%s)"):format(symbol, #message.params > 0 and ", " or "", join(paramNames(message.params))))
                else
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                local fireSizeState: EmitState = { tempIndex = 0 }
                local fireStringLenHints: { [string]: string } = {}
                if usesCanonicalLayout then
                    addLine(lines, 1, "local __nr_prefixSize = 0")
                    addLine(lines, 1, "local __nr_varSize = 0")
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitCanonicalSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_prefixSize",
                            "__nr_varSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, ("local __nr_totalSize = %d + __nr_prefixSize + __nr_varSize"):format(messageIdWidth.bytes))
                    else
                        addLine(
                            lines,
                            1,
                            ("local __nr_totalSize = %d + __nr_prefixSize + %d + __nr_varSize"):format(
                                messageIdWidth.bytes,
                                canonicalFixedSize
                            )
                        )
                    end
                elseif canUseFlatSize then
                    emitFlatTopLevelSize(
                        lines,
                        fireSizeState,
                        info.serializedParams,
                        serializedNames,
                        info.fullName,
                        "__nr_totalSize",
                        messageIdWidth.bytes,
                        validateLevel,
                        fireStringLenHints,
                        schema.structByName
                    )
                else
                    addLine(lines, 1, ("local __nr_totalSize = %d"):format(messageIdWidth.bytes))
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitSizeForType(
                            lines,
                            fireSizeState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            info.fullName .. "." .. serializedParam.name,
                            "__nr_totalSize",
                            1,
                            validateLevel,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                end

                local byteLimit = message.category == "unreliable" and "MaxUnreliableBytes" or "MaxBatchBytes"
                local compressionReserve = not isServer and message.compression ~= nil and 1 or 0
                addLine(lines, 1, ("if __nr_totalSize > %s then %s_DROPPED += 1; ReportError(\"NetRay outgoing message exceeds byte limit\"); return false end"):format(compressionReserve == 1 and "(MaxBatchBytes - 1)" or byteLimit, queueUpper))
                if message.max ~= nil then
                    addLine(lines, 1, ("if __nr_totalSize - %d > %d then %s_DROPPED += 1; ReportError(%q); return false end"):format(messageIdWidth.bytes, message.max, queueUpper, info.fullName .. " exceeds max body bytes"))
                end
                if isServer and message.category == "reliable" then addLine(lines, 1, "FlushTargeted()") end
                local batchReserve = hasCompression and not isServer and message.category == "reliable" and " + RELIABLE_QUEUE_SIZE + 1" or ""
                local passReserve = #info.passthroughParams > 0 and (" or %s_PASS_SIZE + %d > MAX_PASS_VALUES"):format(queueUpper, #info.passthroughParams) or ""
                addLine(lines, 1, ("if %s_QUEUE_SIZE >= MAX_BATCH_MESSAGES or %s_CURSOR + __nr_totalSize%s > %s%s then Flush%s() end"):format(queueUpper, queueUpper, batchReserve, byteLimit, passReserve, message.category == "unreliable" and "Unreliable" or "Reliable"))
                addLine(lines, 1, ("local __nr_base = %s_CURSOR"):format(queueUpper))
                addLine(lines, 1, "local __nr_required = __nr_base + __nr_totalSize")
                addLine(lines, 1, ("if __nr_required > %s_ARENA_CAPACITY then"):format(queueUpper))
                addLine(lines, 2, ("local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, %s_ARENA_CAPACITY)"):format(queueUpper))
                addLine(lines, 2, "while nextCapacity < __nr_required do")
                addLine(lines, 3, "nextCapacity *= 2")
                addLine(lines, 2, "end")
                addLine(lines, 2, ("nextCapacity = math.min(nextCapacity, %s)"):format(byteLimit))
                addLine(lines, 2, "local nextArena = create(nextCapacity)")
                addLine(lines, 2, ("if %s_CURSOR > 0 then"):format(queueUpper))
                addLine(lines, 3, ("copy(nextArena, 0, %s_ARENA, 0, %s_CURSOR)"):format(queueUpper, queueUpper))
                addLine(lines, 2, "end")
                addLine(lines, 2, ("%s_ARENA = nextArena"):format(queueUpper))
                addLine(lines, 2, ("%s_ARENA_CAPACITY = nextCapacity"):format(queueUpper))
                addLine(lines, 1, "end")

                addLine(lines, 1, ("local __nr_payload = %s_ARENA"):format(queueUpper))
                addLine(lines, 1, ("%s(__nr_payload, __nr_base, %s)"):format(messageIdWidth.writer, messageIdConst))
                local fireWriteState: EmitState = { tempIndex = fireSizeState.tempIndex }
                if usesCanonicalLayout then
                    addLine(lines, 1, ("local __nr_prefix = __nr_base + %d"):format(messageIdWidth.bytes))
                    addLine(lines, 1, "local __nr_fixed = __nr_prefix + __nr_prefixSize")
                    if canonicalFixedSize == 0 then
                        addLine(lines, 1, "local __nr_var = __nr_fixed")
                    else
                        addLine(lines, 1, ("local __nr_var = __nr_fixed + %d"):format(canonicalFixedSize))
                    end
                    for serializedIndex = 1, #info.serializedParams do
                        local serializedParam = info.serializedParams[serializedIndex]
                        emitWriteCanonicalForType(
                            lines,
                            fireWriteState,
                            serializedParam.type,
                            serializedNames[serializedIndex],
                            "__nr_payload",
                            "__nr_prefix",
                            "__nr_fixed",
                            "__nr_var",
                            1,
                            schema.structByName,
                            fireStringLenHints
                        )
                    end
                else
                    addLine(lines, 1, ("local __nr_p = __nr_base + %d"):format(messageIdWidth.bytes))
                    emitWriteParamsWithFixedBlocks(
                        lines,
                        fireWriteState,
                        info.serializedParams,
                        serializedNames,
                        "__nr_payload",
                        "__nr_p",
                        1,
                        schema.structByName,
                        fireStringLenHints
                    )
                end
                addLine(lines, 1, ("%s_CURSOR = __nr_required"):format(queueUpper))
                addLine(lines, 1, ("%s_QUEUE_SIZE += 1"):format(queueUpper))
                addLine(lines, 1, ("%s_ENDS[%s_QUEUE_SIZE] = __nr_required"):format(queueUpper, queueUpper))
                addLine(lines, 1, ("%s_IDS[%s_QUEUE_SIZE] = %s"):format(queueUpper, queueUpper, messageIdConst))
                if #passthroughNames > 0 then
                    addLine(lines, 1, ("local __nr_pass = %s_PASS_SIZE"):format(queueUpper))
                    for passIndex = 1, #passthroughNames do
                        addLine(lines, 1, ("%s_PASS_VALUES[__nr_pass + %d] = %s"):format(queueUpper, passIndex, passthroughNames[passIndex]))
                    end
                    addLine(lines, 1, ("%s_PASS_SIZE = __nr_pass + %d"):format(queueUpper, #passthroughNames))
                end
                addLine(lines, 1, "return true")
                end
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end

            if canEmitFire and isServer then
                local passArgSuffix = #passthroughNames > 0 and (", " .. join(passthroughNames)) or ""
                local fireSignatureParts: { string } = { "player: Player" }
                local fireListSignatureParts: { string } = { "players: { Player }" }
                local fireExceptSignatureParts: { string } = { "excludedPlayer: Player" }
                for paramIndex = 1, #message.params do
                    local param = message.params[paramIndex]
                    local typedParam = ("%s: %s"):format(param.name, toLuauType(param.type))
                    fireSignatureParts[#fireSignatureParts + 1] = typedParam
                    fireListSignatureParts[#fireListSignatureParts + 1] = typedParam
                    fireExceptSignatureParts[#fireExceptSignatureParts + 1] = typedParam
                end

                addLine(lines, 0, ("function %s.Fire(%s): boolean"):format(symbol, join(fireSignatureParts)))
                addLine(lines, 1, "if typeof(player) ~= \"Instance\" or not player:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " Fire requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                local targetLimit = message.category == "unreliable" and "MaxUnreliableBytes" or (message.compression ~= nil and "(MaxBatchBytes - 1)" or "MaxBatchBytes")
                addLine(lines, 1, ("if len(__nr_payload) > %s then %s_DROPPED += 1; return false end"):format(targetLimit, queueUpper))
                if message.max ~= nil then
                    addLine(lines, 1, ("if len(__nr_payload) - %d > %d then %s_DROPPED += 1; return false end"):format(messageIdWidth.bytes, message.max, queueUpper))
                end
                addLine(lines, 1, ("%s(player, __nr_payload%s)"):format(targetCall, passArgSuffix))
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")

                addLine(lines, 0, ("function %s.FireList(%s): boolean"):format(symbol, join(fireListSignatureParts)))
                addLine(lines, 1, "if type(players) ~= \"table\" then")
                emitError(lines, 2, validateLevel, info.fullName .. " FireList requires {Player}", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                local targetLimit = message.category == "unreliable" and "MaxUnreliableBytes" or (message.compression ~= nil and "(MaxBatchBytes - 1)" or "MaxBatchBytes")
                addLine(lines, 1, ("if len(__nr_payload) > %s then %s_DROPPED += 1; return false end"):format(targetLimit, queueUpper))
                if message.max ~= nil then
                    addLine(lines, 1, ("if len(__nr_payload) - %d > %d then %s_DROPPED += 1; return false end"):format(messageIdWidth.bytes, message.max, queueUpper))
                end
                addLine(lines, 1, "for __nr_index = 1, #players do")
                addLine(lines, 2, "local __nr_target = players[__nr_index]")
                addLine(lines, 2, "if typeof(__nr_target) ~= \"Instance\" or not __nr_target:IsA(\"Player\") then")
                emitError(lines, 3, validateLevel, info.fullName .. " FireList requires Player values", "ERR_TYPE")
                addLine(lines, 2, "end")
                addLine(lines, 2, ("%s(__nr_target, __nr_payload%s)"):format(targetCall, passArgSuffix))
                addLine(lines, 1, "end")
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")

                addLine(lines, 0, ("function %s.FireExcept(%s): boolean"):format(symbol, join(fireExceptSignatureParts)))
                addLine(lines, 1, "if typeof(excludedPlayer) ~= \"Instance\" or not excludedPlayer:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " FireExcept requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
                if requestNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            requestPassValidator,
                            #info.passthroughParams,
                            #passthroughNames > 0 and ", " or "",
                            join(passthroughNames)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local __nr_payload = %s(%s)"):format(encodeRequestName, join(serializedNames)))
                local targetLimit = message.category == "unreliable" and "MaxUnreliableBytes" or (message.compression ~= nil and "(MaxBatchBytes - 1)" or "MaxBatchBytes")
                addLine(lines, 1, ("if len(__nr_payload) > %s then %s_DROPPED += 1; return false end"):format(targetLimit, queueUpper))
                if message.max ~= nil then
                    addLine(lines, 1, ("if len(__nr_payload) - %d > %d then %s_DROPPED += 1; return false end"):format(messageIdWidth.bytes, message.max, queueUpper))
                end
                addLine(lines, 1, "local __nr_players = Players:GetPlayers()")
                addLine(lines, 1, "for __nr_index = 1, #__nr_players do")
                addLine(lines, 2, "local __nr_target = __nr_players[__nr_index]")
                addLine(lines, 2, "if __nr_target ~= excludedPlayer then")
                addLine(lines, 3, ("%s(__nr_target, __nr_payload%s)"):format(targetCall, passArgSuffix))
                addLine(lines, 2, "end")
                addLine(lines, 1, "end")
                addLine(lines, 1, "return true")
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end

            if canEmitOn then
                if eventIsPolling then
                    local iterReturns = pollingReturnTypes(callbackArgTypes)
                    local emptyReturns: { string } = table.create(#callbackArgTypes + 1, "nil")
                    addLine(lines, 0, ("function %s.Iter(): () -> (%s)"):format(symbol, iterReturns))
                    addLine(lines, 1, ("return function(): (%s)"):format(iterReturns))
                    addLine(lines, 2, ("local __nr_head = %s"):format(pollingHeadName))
                    addLine(lines, 2, ("if __nr_head > %s then"):format(pollingTailName))
                    addLine(lines, 3, ("return %s"):format(join(emptyReturns)))
                    addLine(lines, 2, "end")
                    addLine(lines, 2, schema.limits.MaxPollingMessages == 0 and "local __nr_slot = __nr_head" or "local __nr_slot = (__nr_head - 1) % MaxPollingMessages + 1")
                    local pollReturnVars: { string } = {}
                    for argIndex = 1, #pollingArgNames do
                        local pollVarName = ("__nr_arg%d"):format(argIndex)
                        pollReturnVars[#pollReturnVars + 1] = pollVarName
                        addLine(lines, 2, ("local %s = %s[__nr_slot]"):format(pollVarName, pollingArgNames[argIndex]))
                        addLine(lines, 2, ("%s[__nr_slot] = nil"):format(pollingArgNames[argIndex]))
                    end
                    addLine(lines, 2, ("%s = __nr_head + 1"):format(pollingHeadName))
                    addLine(lines, 2, ("if %s > %s then"):format(pollingHeadName, pollingTailName))
                    addLine(lines, 3, ("%s = 1"):format(pollingHeadName))
                    addLine(lines, 3, ("%s = 0"):format(pollingTailName))
                    addLine(lines, 2, "end")
                    if #pollReturnVars > 0 then
                        addLine(lines, 2, ("return __nr_head, %s"):format(join(pollReturnVars)))
                    else
                        addLine(lines, 2, "return __nr_head")
                    end
                    addLine(lines, 1, "end")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                elseif eventIsSingle then
                    addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, eventCallbackType))
                    addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
                    addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
                    addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
                    addLine(lines, 1, ("%s = callback"):format(handlerName))
                    addLine(lines, 1, "return CreateConnection(function()")
                    addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
                    addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
                    addLine(lines, 3, ("%s = nil"):format(handlerName))
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end)")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                elseif eventIsMany then
                    addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, eventCallbackType))
                    addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
                    addLine(lines, 1, ("local slot = %s[#%s]"):format(handlerFreeSlotsName, handlerFreeSlotsName))
                    addLine(lines, 1, ("while slot ~= nil and slot > %s do"):format(handlerCountName))
                    addLine(lines, 2, ("%s[#%s] = nil"):format(handlerFreeSlotsName, handlerFreeSlotsName))
                    addLine(lines, 2, ("slot = %s[#%s]"):format(handlerFreeSlotsName, handlerFreeSlotsName))
                    addLine(lines, 1, "end")
                    addLine(lines, 1, "if slot == nil then")
                    addLine(lines, 2, ("%s += 1"):format(handlerCountName))
                    addLine(lines, 2, ("slot = %s"):format(handlerCountName))
                    addLine(lines, 1, "else")
                    addLine(lines, 2, ("%s[#%s] = nil"):format(handlerFreeSlotsName, handlerFreeSlotsName))
                    addLine(lines, 1, "end")
                    addLine(lines, 1, ("%s[slot] = callback"):format(handlerListName))
                    addLine(lines, 1, "return CreateConnection(function()")
                    addLine(lines, 2, "-- Stable slots keep disconnection safe during dispatch; On reuses holes.")
                    addLine(lines, 2, ("%s[slot] = nil"):format(handlerListName))
                    addLine(lines, 2, ("if slot == %s then"):format(handlerCountName))
                    addLine(lines, 3, ("while %s > 0 and %s[%s] == nil do"):format(handlerCountName, handlerListName, handlerCountName))
                    addLine(lines, 4, ("%s -= 1"):format(handlerCountName))
                    addLine(lines, 3, "end")
                    addLine(lines, 2, "else")
                    addLine(lines, 3, ("%s[#%s + 1] = slot"):format(handlerFreeSlotsName, handlerFreeSlotsName))
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end)")
                    addLine(lines, 0, "end")
                    addLine(lines, 0, "")
                end
            end

            if canEmitOn then
                local dispatchVar = message.category == "unreliable" and "UNRELIABLE_DISPATCH" or "RELIABLE_DISPATCH"
                local signatureArgs: { string } = {}
                if isServer then
                    signatureArgs[#signatureArgs + 1] = "player: Player"
                end
                signatureArgs[#signatureArgs + 1] = "payload: buffer"
                signatureArgs[#signatureArgs + 1] = "payloadLength: number"
                signatureArgs[#signatureArgs + 1] = "offset: number"
                if isServer then
                    signatureArgs[#signatureArgs + 1] = "decodeBudget: DecodeBudget"
                end
                if categoryMaxPass > 0 then
                    signatureArgs[#signatureArgs + 1] = "passCount: number"
                end
                for passIndex = 1, categoryMaxPass do
                    signatureArgs[#signatureArgs + 1] = ("pass%d: unknown"):format(passIndex)
                end

                if #info.passthroughParams > 0 then
                    local widthVar = message.category == "unreliable" and "UNRELIABLE_PASS_WIDTH" or "RELIABLE_PASS_WIDTH"
                    addLine(lines, 0, ("%s[%d] = %d"):format(widthVar, message.id, #info.passthroughParams))
                end
                addLine(lines, 0, ("%s[%d] = function(%s)"):format(dispatchVar, message.id, join(signatureArgs)))
                local decodeBudgetArg = if isServer then ", decodeBudget" else ""
                if message.max ~= nil and message.compression == nil then
                    addLine(lines, 1, ("local bodyEnd = %s(payload, payloadLength, offset%s)"):format(skipName, decodeBudgetArg))
                    addLine(lines, 1, ("if bodyEnd - offset > %d then return bodyEnd end"):format(message.max))
                end
                if isServer and message.rate ~= nil and message.compression == nil then
                    addLine(lines, 1, "local now = os.clock()")
                    addLine(lines, 1, "local budget = EventBudgets[player]")
                    addLine(lines, 1, ("if budget == nil then budget = { time = now, tokens = %s }; EventBudgets[player] = budget end"):format(tostring(message.burst)))
                    addLine(lines, 1, ("budget.tokens = math.min(%s, budget.tokens + math.max(0, now - budget.time) * %s)"):format(tostring(message.burst), tostring(message.rate)))
                    addLine(lines, 1, "budget.time = now")
                    addLine(lines, 1, ("if budget.tokens < 1 then return %s(payload, payloadLength, offset%s) end"):format(skipName, decodeBudgetArg))
                    addLine(lines, 1, "budget.tokens -= 1")
                end

                local decodeResultVars: { string } = {}
                for idxVar = 1, #requestDecodedVars do
                    decodeResultVars[#decodeResultVars + 1] = requestDecodedVars[idxVar]
                end
                decodeResultVars[#decodeResultVars + 1] = "nextOffset"
                if message.compression ~= nil then
                    if isServer then addLine(lines, 1, "local ReceiveCompression = decodeBudget.compression") end
                    addLine(lines, 1, "if offset >= payloadLength then error(ERR_BOUNDS) end")
                    addLine(lines, 1, "local mode = readu8(payload, offset)")
                    addLine(lines, 1, ("local %s"):format(join(decodeResultVars)))
                    addLine(lines, 1, "if mode == 0 or mode == 3 then")
                    if message.max ~= nil then
                        addLine(lines, 2, ("local bodyEnd = %s(payload, payloadLength, offset + 1%s)"):format(skipName, decodeBudgetArg))
                        addLine(lines, 2, ("if bodyEnd - offset - 1 > %d then error(ERR_BOUNDS) end"):format(message.max))
                    end
                    addLine(lines, 2, ("%s = %s(payload, payloadLength, offset + 1%s)"):format(join(decodeResultVars), decodeRequestName, decodeBudgetArg))
                    addLine(lines, 2, ("ReceiveCompression = __nr_commitFull(ReceiveCompression, %d, payload, offset + 1, nextOffset, mode == 3)"):format(message.id))
                    addLine(lines, 1, "else")
                    addLine(lines, 2, ("local body, incomingNext, nextState = __nr_decompress(ReceiveCompression, %d, payload, payloadLength, offset, CompressionWidths[%d])"):format(message.id, message.id))
                    if message.max ~= nil then
                        addLine(lines, 2, ("if len(body) > %d then error(ERR_BOUNDS) end"):format(message.max))
                    end
                    addLine(lines, 2, ("%s = %s(body, len(body), 0%s)"):format(join(decodeResultVars), decodeRequestName, decodeBudgetArg))
                    addLine(lines, 2, "if nextOffset ~= len(body) then error(ERR_BOUNDS) end")
                    addLine(lines, 2, "nextOffset = incomingNext")
                    addLine(lines, 2, "ReceiveCompression = nextState")
                    addLine(lines, 1, "end")
                    if isServer then addLine(lines, 1, "decodeBudget.compression = ReceiveCompression") end
                else
                    addLine(lines, 1, ("local %s = %s(payload, payloadLength, offset%s)"):format(join(decodeResultVars), decodeRequestName, decodeBudgetArg))
                end
                if requestNeedsPassValidation then
                    -- Validated after decoding, which yields the next record's offset, so only this message is dropped.
                    local passVarsForValidation: { string } = { "passCount" }
                    for passIndex = 1, #info.passthroughParams do
                        passVarsForValidation[#passVarsForValidation + 1] = ("pass%d"):format(passIndex)
                    end
                    addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(passVarsForValidation)))
                    addLine(lines, 2, ("ReportError(%q)"):format(info.fullName .. " passthrough arguments are missing or invalid; message dropped"))
                    addLine(lines, 2, "return nextOffset")
                    addLine(lines, 1, "end")
                end

                if isServer and message.rate ~= nil and message.compression ~= nil then
                    addLine(lines, 1, "local now = os.clock()")
                    addLine(lines, 1, "local budget = EventBudgets[player]")
                    addLine(lines, 1, ("if budget == nil then budget = { time = now, tokens = %s }; EventBudgets[player] = budget end"):format(tostring(message.burst)))
                    addLine(lines, 1, ("budget.tokens = math.min(%s, budget.tokens + math.max(0, now - budget.time) * %s)"):format(tostring(message.burst), tostring(message.rate)))
                    addLine(lines, 1, "budget.time = now")
                    addLine(lines, 1, "if budget.tokens < 1 then return nextOffset end")
                    addLine(lines, 1, "budget.tokens -= 1")
                end
                if message.max ~= nil and message.compression == nil then
                    addLine(lines, 1, ("if nextOffset - offset > %d then return nextOffset end"):format(message.max))
                end
                if eventIsPolling then
                    addLine(lines, 1, ("if %s - %s + 1 >= MaxPollingMessages then return nextOffset end"):format(pollingTailName, pollingHeadName))
                    addLine(lines, 1, ("local __nr_tail = %s + 1"):format(pollingTailName))
                    addLine(lines, 1, ("%s = __nr_tail"):format(pollingTailName))
                    addLine(lines, 1, schema.limits.MaxPollingMessages == 0 and "local __nr_slot = __nr_tail" or "local __nr_slot = (__nr_tail - 1) % MaxPollingMessages + 1")
                    for argIndex = 1, #pollingArgNames do
                        addLine(lines, 1, ("%s[__nr_slot] = %s"):format(pollingArgNames[argIndex], callbackArgs[argIndex]))
                    end
                    addLine(lines, 1, "return nextOffset")
                elseif eventIsSingle then
                    addLine(lines, 1, ("local callback = %s"):format(handlerName))
                    addLine(lines, 1, "if callback == nil then")
                    addLine(lines, 2, "return nextOffset")
                    addLine(lines, 1, "end")
                    if eventIsAsync then
                        if #callbackArgs > 0 then
                            addLine(lines, 1, ("task.spawn(callback, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 1, "task.spawn(callback)")
                        end
                    else
                        if #callbackArgs > 0 then
                            addLine(lines, 1, (hasCompression and not isServer and message.category == "reliable" and "task.spawn(xpcall, callback, ReportError, %s)" or "xpcall(callback, ReportError, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 1, hasCompression and not isServer and message.category == "reliable" and "task.spawn(xpcall, callback, ReportError)" or "xpcall(callback, ReportError)")
                        end
                    end
                    addLine(lines, 1, "return nextOffset")
                elseif eventIsMany then
                    addLine(lines, 1, ("for __nr_index = 1, %s do"):format(handlerCountName))
                    addLine(lines, 2, ("local callback = %s[__nr_index]"):format(handlerListName))
                    addLine(lines, 2, "if callback ~= nil then")
                    if eventIsAsync then
                        if #callbackArgs > 0 then
                            addLine(lines, 3, ("task.spawn(callback, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 3, "task.spawn(callback)")
                        end
                    else
                        if #callbackArgs > 0 then
                            addLine(lines, 3, (hasCompression and not isServer and message.category == "reliable" and "task.spawn(xpcall, callback, ReportError, %s)" or "xpcall(callback, ReportError, %s)"):format(callbackArgList))
                        else
                            addLine(lines, 3, hasCompression and not isServer and message.category == "reliable" and "task.spawn(xpcall, callback, ReportError)" or "xpcall(callback, ReportError)")
                        end
                    end
                    addLine(lines, 2, "end")
                    addLine(lines, 1, "end")
                    addLine(lines, 1, "return nextOffset")
                else
                    addLine(lines, 1, "return nextOffset")
                end
                addLine(lines, 0, "end")
                addLine(lines, 0, "")
            end
        elseif message.category == "function" then
            local serializedNames = paramNames(info.serializedParams)
            local passthroughNames = paramNames(info.passthroughParams)
            local allReturnNames = paramNames(message.returns or {})
            local passthroughReturnNames = paramNames(info.passthroughReturns)
            local functionCallbackType = callbackTypeName
            local functionReturnType = returnTypeExpr(message.returns or {})

            addLine(lines, 0, ("function %s.On(callback: %s): Connection"):format(symbol, functionCallbackType))
            addLine(lines, 1, "if type(callback) ~= \"function\" then error(ERR_TYPE) end")
            addLine(lines, 1, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 1, ("local token = %s"):format(handlerTokenName))
            addLine(lines, 1, ("%s = callback"):format(handlerName))
            addLine(lines, 1, "return CreateConnection(function()")
            addLine(lines, 2, ("if %s == token then"):format(handlerTokenName))
            addLine(lines, 3, ("%s += 1"):format(handlerTokenName))
            addLine(lines, 3, ("%s = nil"):format(handlerName))
            addLine(lines, 2, "end")
            addLine(lines, 1, "end)")
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local callSignature: { string } = {}
            if isServer then
                callSignature[#callSignature + 1] = "player: Player"
            end
            for indexParam = 1, #message.params do
                local param = message.params[indexParam]
                callSignature[#callSignature + 1] = ("%s: %s"):format(param.name, toLuauType(param.type))
            end
            addLine(lines, 0, ("function %s.Call(%s): %s"):format(symbol, join(callSignature), functionReturnType))
            if isServer then
                addLine(lines, 1, "if typeof(player) ~= \"Instance\" or not player:IsA(\"Player\") then")
                emitError(lines, 2, validateLevel, info.fullName .. " server call requires Player", "ERR_TYPE")
                addLine(lines, 1, "end")
            end
            if requestNeedsPassValidation then
                addLine(
                    lines,
                    1,
                    ("if not %s(%d%s%s) then"):format(
                        requestPassValidator,
                        #info.passthroughParams,
                        #passthroughNames > 0 and ", " or "",
                        join(passthroughNames)
                    )
                )
                emitError(lines, 2, validateLevel, info.fullName .. " passthrough arguments are invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, ("local requestPayload = %s(%s)"):format(encodeRequestName, join(serializedNames)))

            local responseCaptureVars: { string } = { "responseCount", "responsePayload" }
            for passIndex = 1, #passthroughReturnNames do
                responseCaptureVars[#responseCaptureVars + 1] = ("responsePass%d"):format(passIndex)
            end

            local invokeArgs: { string } = {}
            if isServer then
                invokeArgs[#invokeArgs + 1] = "player"
            end
            invokeArgs[#invokeArgs + 1] = "requestPayload"
            for passIndex = 1, #passthroughNames do
                invokeArgs[#invokeArgs + 1] = passthroughNames[passIndex]
            end

            if isServer then
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeClient(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            else
                addLine(lines, 1, ("local %s = WithCount(FunctionRemote:InvokeServer(%s))"):format(join(responseCaptureVars), join(invokeArgs)))
            end
            addLine(lines, 1, "if responseCount < 1 then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response missing payload", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            if returnNeedsPassValidation then
                addLine(lines, 1, "local responsePassCount = responseCount - 1")
            end

            if returnNeedsPassValidation then
                local passValidationArgs: { string } = { "responsePassCount" }
                for passIndex = 1, #passthroughReturnNames do
                    passValidationArgs[#passValidationArgs + 1] = ("responsePass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(responsePassValidator, join(passValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " return passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end
            addLine(lines, 1, "if typeof(responsePayload) ~= \"buffer\" then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload must be buffer", "ERR_TYPE")
            addLine(lines, 1, "end")
            addLine(lines, 1, "local responseLength = len(responsePayload)")
            addLine(lines, 1, "if responseLength > MaxBatchBytes then error(ERR_BOUNDS) end")
            addLine(lines, 1, ("if responseLength < %d then"):format(messageIdWidth.bytes))
            emitError(lines, 2, validateLevel, info.fullName .. " function response payload too short", "ERR_BOUNDS")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local responseId = %s(responsePayload, 0)"):format(messageIdWidth.reader))
            addLine(lines, 1, ("if responseId ~= %s then"):format(messageIdConst))
            emitError(lines, 2, validateLevel, info.fullName .. " function response message ID mismatch", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local decodedReturnVars: { string } = {}
            for indexReturn = 1, #info.serializedReturns do
                decodedReturnVars[#decodedReturnVars + 1] = ("decoded_%s"):format(sanitizeIdentifier(info.serializedReturns[indexReturn].name))
            end
            local decodeReturnCapture: { string } = {}
            for indexVar = 1, #decodedReturnVars do
                decodeReturnCapture[#decodeReturnCapture + 1] = decodedReturnVars[indexVar]
            end
            decodeReturnCapture[#decodeReturnCapture + 1] = "responseOffset"
            addLine(
                lines,
                1,
                ("local %s = %s(responsePayload, responseLength, %d)"):format(
                    join(decodeReturnCapture),
                    decodeResponseName,
                    messageIdWidth.bytes
                )
            )
            addLine(lines, 1, "if responseOffset ~= responseLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " function response has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            if #allReturnNames > 0 then
                local returnArgs: { string } = {}
                local serialIndex = 0
                local passIndex = 0
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        passIndex += 1
                        returnArgs[#returnArgs + 1] = ("responsePass%d"):format(passIndex)
                    else
                        serialIndex += 1
                        returnArgs[#returnArgs + 1] = decodedReturnVars[serialIndex]
                    end
                end
                addLine(lines, 1, ("return %s"):format(join(returnArgs)))
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")

            local signatureArgs: { string } = {}
            if isServer then
                signatureArgs[#signatureArgs + 1] = "player: Player"
            end
            signatureArgs[#signatureArgs + 1] = "payload: buffer"
            signatureArgs[#signatureArgs + 1] = "payloadLength: number"
            if schema.maxPassArgs.Function > 0 then
                signatureArgs[#signatureArgs + 1] = "passCount: number"
            end
            for passIndex = 1, schema.maxPassArgs.Function do
                signatureArgs[#signatureArgs + 1] = ("pass%d: unknown"):format(passIndex)
            end
            addLine(lines, 0, ("FUNCTION_DISPATCH[%d] = function(%s)"):format(message.id, join(signatureArgs)))
            if requestNeedsPassValidation then
                local inboundPassValidationArgs: { string } = { "passCount" }
                for passIndex = 1, #passthroughNames do
                    inboundPassValidationArgs[#inboundPassValidationArgs + 1] = ("pass%d"):format(passIndex)
                end
                addLine(lines, 1, ("if not %s(%s) then"):format(requestPassValidator, join(inboundPassValidationArgs)))
                emitError(lines, 2, validateLevel, info.fullName .. " inbound passthrough is invalid", "ERR_PASS")
                addLine(lines, 1, "end")
            end

            local inboundDecodeCapture: { string } = {}
            for indexVar = 1, #requestDecodedVars do
                inboundDecodeCapture[#inboundDecodeCapture + 1] = requestDecodedVars[indexVar]
            end
            inboundDecodeCapture[#inboundDecodeCapture + 1] = "offset"
            addLine(
                lines,
                1,
                ("local %s = %s(payload, payloadLength, %d)"):format(join(inboundDecodeCapture), decodeRequestName, messageIdWidth.bytes)
            )
            addLine(lines, 1, "if offset ~= payloadLength then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function payload has trailing bytes", "ERR_SCHEMA")
            addLine(lines, 1, "end")
            addLine(lines, 1, ("local callback = %s"):format(handlerName))
            addLine(lines, 1, "if callback == nil then")
            emitError(lines, 2, validateLevel, info.fullName .. " inbound function has no handler", "ERR_SCHEMA")
            addLine(lines, 1, "end")

            local callbackArgs: { string } = {}
            if isServer then
                callbackArgs[#callbackArgs + 1] = "player"
            end
            local callbackSerialIndex = 0
            local callbackPassIndex = 0
            for paramIndex = 1, #message.params do
                local param = message.params[paramIndex]
                if param.type.kind == "passthrough" then
                    callbackPassIndex += 1
                    -- The passthrough validator has already checked the value against this type.
                    callbackArgs[#callbackArgs + 1] = ("pass%d :: %s"):format(callbackPassIndex, toLuauType(param.type))
                else
                    callbackSerialIndex += 1
                    local leafNames = requestDecodePlans[callbackSerialIndex].leafNames
                    for leafIndex = 1, #leafNames do
                        callbackArgs[#callbackArgs + 1] = leafNames[leafIndex]
                    end
                end
            end

            if #allReturnNames > 0 then
                local callbackResultVars: { string } = {}
                for returnIndex = 1, #allReturnNames do
                    callbackResultVars[#callbackResultVars + 1] = ("callbackRet_%d"):format(returnIndex)
                end
                addLine(lines, 1, ("local %s = callback(%s)"):format(join(callbackResultVars), join(callbackArgs)))

                local responseSerializedArgs: { string } = {}
                local responsePassthroughArgs: { string } = {}
                local returnParamList = message.returns or {}
                for returnIndex = 1, #returnParamList do
                    local returnParam = returnParamList[returnIndex]
                    if returnParam.type.kind == "passthrough" then
                        responsePassthroughArgs[#responsePassthroughArgs + 1] = callbackResultVars[returnIndex]
                    else
                        responseSerializedArgs[#responseSerializedArgs + 1] = callbackResultVars[returnIndex]
                    end
                end

                if returnNeedsPassValidation then
                    addLine(
                        lines,
                        1,
                        ("if not %s(%d%s%s) then"):format(
                            responsePassValidator,
                            #responsePassthroughArgs,
                            #responsePassthroughArgs > 0 and ", " or "",
                            join(responsePassthroughArgs)
                        )
                    )
                    emitError(lines, 2, validateLevel, info.fullName .. " handler returned invalid passthrough", "ERR_PASS")
                    addLine(lines, 1, "end")
                end
                addLine(lines, 1, ("local responsePayload = %s(%s)"):format(encodeResponseName, join(responseSerializedArgs)))
                if #responsePassthroughArgs > 0 then
                    local returnPayload: { string } = { "responsePayload" }
                    for passIndex = 1, #responsePassthroughArgs do
                        returnPayload[#returnPayload + 1] = responsePassthroughArgs[passIndex]
                    end
                    addLine(lines, 1, ("return %s"):format(join(returnPayload)))
                else
                    addLine(lines, 1, "return responsePayload")
                end
            else
                addLine(lines, 1, ("callback(%s)"):format(join(callbackArgs)))
                addLine(lines, 1, ("local responsePayload = %s()"):format(encodeResponseName))
                addLine(lines, 1, "return responsePayload")
            end
            addLine(lines, 0, "end")
            addLine(lines, 0, "")
        else
            error(("Unsupported message category '%s' for message '%s'"):format(message.category, info.fullName))
        end
        addLine(lines, 0, ("APIs[%d] = %s"):format(index, symbol))
        addLine(lines, 0, "end")
        symbolByMessage[message] = ("APIs[%d]"):format(index)
    end

    addLine(lines, 0, "local function StepReplication()")
    addLine(lines, 1, "FlushReliable()")
    if isServer then addLine(lines, 1, "FlushTargeted()") end
    addLine(lines, 1, "FlushUnreliable()")
    addLine(lines, 0, "end")
    addLine(lines, 0, "")
    addLine(lines, 0, "RunService.Heartbeat:Connect(StepReplication)")
    addLine(lines, 0, "")

    emitEventListener(
        lines,
        isServer,
        "Reliable",
        "Reliable",
        schema.maxPassArgs.reliable,
        reliableMessageIdWidth,
        validateLevel
    )
    emitEventListener(
        lines,
        isServer,
        "Unreliable",
        "Unreliable",
        schema.maxPassArgs.unreliable,
        unreliableMessageIdWidth,
        validateLevel
    )
    emitFunctionInvoke(lines, isServer, schema.maxPassArgs.Function, functionMessageIdWidth, validateLevel)

    addLine(lines, 0, "local Stats: NetStats = {")
    addLine(lines, 1, "GetReliableDropped = function() return RELIABLE_DROPPED end,")
    addLine(lines, 1, "GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,")
    addLine(lines, 1, "GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE" .. (isServer and " + TargetedCount" or "") .. " end,")
    addLine(lines, 1, "GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,")
    addLine(lines, 0, "}")
    addLine(lines, 0, "")

    local scopeLines = buildScopeTables(schema.root, 0, true, symbolByMessage, "NetRoot")
    table.insert(scopeLines, #scopeLines, "    StepReplication = StepReplication,")
    table.insert(scopeLines, #scopeLines, "    Stats = Stats,")
    appendLines(lines, scopeLines)
    addLine(lines, 0, "")
    addLine(lines, 0, ("return table.freeze(%s)"):format(schema.root.name))

    pruneUnusedRuntimeSymbols(lines)
    markUnusedParameters(lines)

    return concat(lines)
end

local function generateServer(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, true)
end

local function generateClient(schema: Analyzer.AnalyzedSchema): string
    return generateRuntime(schema, false)
end
return {
    emitQueue = emitQueue,
    emitEventListener = emitEventListener,
    emitFunctionInvoke = emitFunctionInvoke,
    emitCommonRuntimePreamble = emitCommonRuntimePreamble,
    generateRuntime = generateRuntime,
    generateServer = generateServer,
    generateClient = generateClient,
}
