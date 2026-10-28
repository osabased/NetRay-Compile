-- Run as a LocalScript in StarterPlayerScripts in the benchmark place.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
assert(RunService:IsStudio(), "Run this benchmark in Studio only")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NetRay"):WaitForChild("Client"))
local Control = ReplicatedStorage:WaitForChild("NetRayBenchmarkControl")
local Reliable = ReplicatedStorage:WaitForChild("NetRay_RELIABLE")
local CONFIG = { runs = 2, steps = 600, perStep = 40, drainTimeout = 10, pingSamples = 30 }

local entities = table.create(1000)
for id = 1, 1000 do
    entities[id] = {
        brand = "NetRay", carName = "Car" .. id, carId = id,
        available = id % 2 == 0, dealers = id % 16, price = id * 123.5,
    }
end

local function percentile(values, fraction)
    if #values == 0 then return 0 end
    local sorted = table.clone(values)
    table.sort(sorted)
    return sorted[math.clamp(math.ceil(#sorted * fraction), 1, #sorted)]
end

local function sampleWindow()
    local samples = {}
    local memory = gcinfo()
    local connection = RunService.Heartbeat:Connect(function(dt) samples[#samples + 1] = dt end)
    return function()
        connection:Disconnect()
        return percentile(samples, 0.95) * 1000, gcinfo() - memory
    end
end

local function expectedState(pattern, index)
    if pattern == "repeat" then return 1, 2, 3 end
    if pattern == "sparse" then return 1, index, 3 end
    return index, index * 3, index * 7
end

local active
local wireConnection = Reliable.OnClientEvent:Connect(function(payload)
    if active and typeof(payload) == "buffer" then
        active.wireBytes += buffer.len(payload)
        active.packets += 1
    end
end)
local listeners = {}
for _, eventName in { "RawState", "RepeatState", "FieldState" } do
    listeners[#listeners + 1] = Net[eventName].On(function(x, y, z)
        if not active or active.eventName ~= eventName then return end
        active.received += 1
        local a, b, c = expectedState(active.pattern, active.received)
        if x ~= a or y ~= b or z ~= c then active.invalid += 1 end
    end)
end

local results = {}
local function report(label, attempted, received, invalid, wireBytes, packets, enqueue, flush, elapsed, frameP95, memoryDelta)
    local passed = received == attempted and invalid == 0
    local row = {
        label = label, passed = passed, attempted = attempted, received = received, invalid = invalid,
        rawBytes = wireBytes, packets = packets, enqueueSeconds = enqueue, flushSeconds = flush,
        elapsed = elapsed, clientFrameP95Ms = frameP95, clientLuaMemoryDeltaKB = memoryDelta,
    }
    results[#results + 1] = row
    print(("[%s] %s | received %d/%d, invalid %d | %.0f delivered/s | raw %.2f B/message, %d packets | enqueue %.2f us/message, flush %.2f ms total | client frame p95 %.2f ms | client Lua delta %+.1f KB")
        :format(passed and "PASS" or "FAIL", label, received, attempted, invalid, received / math.max(elapsed, 0.000001),
            wireBytes / math.max(received, 1), packets, enqueue / attempted * 1e6, flush * 1000, frameP95, memoryDelta))
end

local function runUplink(label)
    local total = CONFIG.steps * CONFIG.perStep
    Net.StepReplication()
    assert(Control:InvokeServer("Begin", total))
    local stopSamples = sampleWindow()
    local started = os.clock()
    local enqueue, flush, sent = 0, 0, 0
    for _ = 1, CONFIG.steps do
        RunService.Heartbeat:Wait()
        local t0 = os.clock()
        for _ = 1, CONFIG.perStep do
            local accepted = Net.MyEvent.Fire(entities[sent % #entities + 1])
            assert(accepted ~= false, "Benchmark message rejected by sender")
            sent += 1
        end
        enqueue += os.clock() - t0
        t0 = os.clock()
        Net.StepReplication()
        flush += os.clock() - t0
    end
    local delivery
    local deadline = os.clock() + CONFIG.drainTimeout
    repeat
        delivery = Control:InvokeServer("Finish")
        if delivery.received >= total then break end
        task.wait(0.05)
    until os.clock() >= deadline
    RunService.Heartbeat:Wait()
    delivery = Control:InvokeServer("Finish")
    local elapsed = os.clock() - started
    local frameP95, memory = stopSamples()
    report(label, total, delivery.received, delivery.invalid, delivery.wireBytes, delivery.packets, enqueue, flush, elapsed, frameP95, memory)
end

local function runDownlink(label, eventName, pattern)
    active = { eventName = eventName, pattern = pattern, received = 0, invalid = 0, wireBytes = 0, packets = 0 }
    local stopSamples = sampleWindow()
    local started = os.clock()
    local metrics = Control:InvokeServer("Downstream", eventName, CONFIG.steps, CONFIG.perStep, pattern)
    local total = CONFIG.steps * CONFIG.perStep
    local deadline = os.clock() + CONFIG.drainTimeout
    while active.received < total and os.clock() < deadline do task.wait(0.01) end
    RunService.Heartbeat:Wait()
    local elapsed = os.clock() - started
    local frameP95, memory = stopSamples()
    local delivery = active
    active = nil
    assert(metrics.sent == total, "Server did not enqueue the requested workload")
    report(label, total, delivery.received, delivery.invalid, delivery.wireBytes, delivery.packets,
        metrics.enqueueSeconds, metrics.flushSeconds, elapsed, frameP95, memory)
end

local function runPing()
    local samples, failures = {}, 0
    for index = 1, CONFIG.pingSamples + 5 do
        local start = os.clock()
        local ok, echoed = pcall(Net.Ping.Call, start)
        local elapsed = os.clock() - start
        if index > 5 then
            if ok and echoed == start then samples[#samples + 1] = elapsed else failures += 1 end
        end
        task.wait(0.05)
    end
    print(("Ping: %d valid, %d failed | median %.2f ms, p95 %.2f ms")
        :format(#samples, failures, percentile(samples, 0.5) * 1000, percentile(samples, 0.95) * 1000))
end

local function main()
    task.wait(2)
    print("NetRay benchmark: raw buffer bytes BEFORE Roblox compression; timings cover enqueue and explicit flush, not total networking CPU.")
    print("Frame times and Lua memory are client-wide. GC can make memory deltas negative. Use one Studio client for comparable results.")
    runPing()
    local cases = {}
    for _, pattern in { "repeat", "sparse", "changing" } do
        for _, eventName in { "RawState", "RepeatState", "FieldState" } do
            cases[#cases + 1] = {eventName, pattern}
        end
    end
    for run = 1, CONFIG.runs do
        runUplink("Uplink entities / run " .. run)
        task.wait(0.5)
        for index = 1, #cases do
            local case = cases[if run % 2 == 0 then #cases - index + 1 else index]
            runDownlink(case[1] .. " / " .. case[2] .. " / run " .. run, case[1], case[2])
            task.wait(0.5)
        end
    end
    local failed = 0
    for _, result in results do if not result.passed then failed += 1 end end
    print(("NetRay benchmark complete: %d cases, %d failed."):format(#results, failed))
end

local ok, failure = xpcall(main, debug.traceback)
active = nil
wireConnection:Disconnect()
for _, connection in listeners do connection:Disconnect() end
_G.NetRayBenchmarkResults = results
local saved = ReplicatedStorage:FindFirstChild("NetRayBenchmarkResults")
if saved then
    assert(saved:IsA("StringValue"), "NetRayBenchmarkResults must be a StringValue")
else
    saved = Instance.new("StringValue")
    saved.Name = "NetRayBenchmarkResults"
    saved.Parent = ReplicatedStorage
end
saved.Value = HttpService:JSONEncode(results)
print("Results saved on this client: ReplicatedStorage.NetRayBenchmarkResults.Value")
if not ok then error(failure) end
