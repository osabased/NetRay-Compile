local RunService = game:GetService("RunService")
assert(RunService:IsStudio(), "NetRay benchmark must only run in Studio")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NetRay"):WaitForChild("Server"))
local reliable = ReplicatedStorage:WaitForChild("NetRay_RELIABLE")
local sessions = {}
local downstreamBusy = {}

Net.MyEvent.On(function(player, brand, carName, carId, available, dealers, price)
	local session = sessions[player]
	if not session then return end
	session.received += 1
	local id = 1 + (session.received - 1) % 1000
	if brand ~= "NetRay" or carName ~= "Car" .. id or carId ~= id
		or available ~= (id % 2 == 0) or dealers ~= id % 16 or price ~= id * 123.5 then
		session.invalid += 1
	end
end)

reliable.OnServerEvent:Connect(function(player, payload)
	local session = sessions[player]
	if session and typeof(payload) == "buffer" then
		session.wireBytes += buffer.len(payload)
		session.packets += 1
	end
end)

Net.Ping.On(function(_player, t0) return t0 end)

local control = Instance.new("RemoteFunction")
control.Name = "NetRayBenchmarkControl"
control.OnServerInvoke = function(player, action, eventName, steps, perStep, pattern)
	if action == "Begin" then
		assert(type(eventName) == "number" and eventName % 1 == 0 and eventName >= 1 and eventName <= 120000, "Invalid expected message count")
		sessions[player] = { received = 0, invalid = 0, wireBytes = 0, packets = 0 }
		return true
	elseif action == "Finish" then
		local session = sessions[player]
		assert(session, "Begin must run before Finish")
		return table.clone(session)
	end
	assert(action == "Downstream", "Unknown benchmark command")
	assert(eventName == "RawState" or eventName == "RepeatState" or eventName == "FieldState", "Unknown benchmark event")
	assert(type(steps) == "number" and steps % 1 == 0 and steps >= 1 and steps <= 600, "Invalid steps")
	assert(type(perStep) == "number" and perStep % 1 == 0 and perStep >= 1 and perStep <= 200, "Invalid messages per step")
	assert(pattern == "repeat" or pattern == "sparse" or pattern == "changing", "Invalid pattern")
	assert(not downstreamBusy[player], "A downstream benchmark is already running")
	downstreamBusy[player] = true
	local started = os.clock()
	local ok, result = pcall(function()
		local sent, enqueueSeconds, flushSeconds = 0, 0, 0
		for _ = 1, steps do
			RunService.Heartbeat:Wait()
			if player.Parent ~= Players then break end
			local enqueueStart = os.clock()
			for _ = 1, perStep do
				local index = sent + 1
				local x, y, z = 1, 2, 3
				if pattern == "sparse" then y = index
				elseif pattern == "changing" then x, y, z = index, index * 3, index * 7 end
				assert(Net[eventName].Fire(player, x, y, z) ~= false, "Benchmark send rejected")
				sent += 1
			end
			enqueueSeconds += os.clock() - enqueueStart
			local flushStart = os.clock()
			Net.StepReplication()
			flushSeconds += os.clock() - flushStart
		end
		return { sent = sent, enqueueSeconds = enqueueSeconds, flushSeconds = flushSeconds, elapsed = os.clock() - started }
	end)
	downstreamBusy[player] = nil
	if not ok then error(result) end
	return result
end
control.Parent = ReplicatedStorage

Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
	downstreamBusy[player] = nil
end)
