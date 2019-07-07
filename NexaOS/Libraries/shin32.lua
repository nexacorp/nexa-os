local dll = {}
local processes = {}
local sysvars = {}
local currentProc = nil
local activeProcesses = 0

function table.getn(table)
	local i = 0
	for k, v in pairs(table) do
		if type(k) == "number" then
			i = math.max(i, k)
		else
			i = i + 1
		end
	end
	return i
end

table.maxn = table.getn

function string.split(str, sep)
	if not sep then sep = "%s" end
	local t = {}
	for part in string.gmatch(str, "([^" .. sep .. "]+)") do
		table.insert(t, part)
	end
	return t
end

-- Obsolete I/O methods
function io.fromu16(x)
	local b1=string.char(x%256) x=(x-x%256)/256
	local b2=string.char(x%256)
	return {b1, b2}
end

function io.fromu32(x)
	local b1=string.char(x%256) x=(x-x%256)/256
	local b2=string.char(x%256) x=(x-x%256)/256
	local b3=string.char(x%256) x=(x-x%256)/256
	local b4=string.char(x%256)
	return {b1, b2, b3, b4}
end

function io.tou16(arr, off)
	local v1 = arr[off + 1]
	local v2 = arr[off]
	return v1 + (v2*256)
end

function io.tou32(arr, off)
	local v1 = io.tou16(arr, off + 2)
	local v2 = io.tou16(arr, off)
	return v1 + (v2*65536)
end

-- New I/O methods

-- To unsigned number (max 32-bit)
function io.tounum(number, count, littleEndian)
	local data = {}
	
	if count > 4 then
		error("lua bit32 only supports 32-bit numbers")
	end
	
	if littleEndian then
		local i = count
		while i > 1 do
			data[i] = bit32.band(number, 0x000000FF)
			number = bit32.rshift(number, 8)
			i = i - 1
		end
	else
		local i = 1
		while i < count+1 do
			data[i] = bit32.band(number, 0x000000FF)
			number = bit32.rshift(number, 8)
			i = i + 1
		end
	end
	return data
end

-- From unsigned number (max 32-bit)
function io.fromunum(data, littleEndian, count)
	count = count or 0
	if count == 0 then
		if type(data) == "string" then
			count = data:len()
		else
			count = #data
		end
	end
	
	if count > 4 then
		error("lua bit32 only supports 32-bit numbers")
	end
	
	if count == 1 then
		if data then
			return string.byte(data)
		else
			return nil
		end
	else
		-- use 4 bytes max as Lua's bit32 scale the number between [0, 2^32-1] which makes the number impossible to
		-- go beyond ‭4,294,967,295‬
		local bytes, result = {string.byte(data or "\x00", 1, 4)}, 0
		if littleEndian then
			local i = #bytes -- just do it in inverse order
			while i > 1 do
				result = bit32.bor(bit32.lshift(result, 8), bytes[i])
				i = i - 1
			end
		else
			local i = 1
			while i < #bytes do
				result = bit32.bor(bit32.lshift(result, 8), bytes[i])
				i = i + 1
			end
		end
		return result
	end
end

function dll.getenvs() 
	return sysvars
end
dll.getSystemVars = dll.getenvs

function dll.getenv(var)
	return sysvars[var]
end
dll.getSystemVar = dll.getenv

function dll.setenv(var, value)
	sysvars[var] = value
end
dll.setSystemVar = dll.setenv

function dll.newProcess(name, func)
	local pid = table.getn(processes) + 1
	local proc = {
		name = name,
		func = func,
		pid = pid,
		status = "created",
		closeables = {}, -- used for file streams
		detach = function(self)
			self.parent = nil
		end,
		kill = function(self)
			dll.safeKill(self)
		end,
		join = function(self)
			dll.waitFor(self)
		end
	}
	processes[pid] = proc
	if dll.getCurrentProcess() ~= nil then
		proc.parent = dll.getCurrentProcess()
	else -- else it's launched by system, so it's a system process
		require("security").requestPermission("*", pid)
	end
	return proc
end

function dll.getSharedUserPath()
	return "A:/Users/Shared"
end

function dll.getUserPath()
	if dll.getSystemVar("USER") == "Guest" then
		return dll.getSharedUserPath()
	else
		return "A:/Users/" .. dll.getSystemVar("USER")
	end
end

function dll.getUser()
	local configStream = io.open(dll.getUserPath() .. "/account.lon")
	local config = require("liblon").loadlon(configStream)
	configStream:close()
	return {
		name = config.name,
		hasPassword = config.security ~= "none"
	}
end

local function systemEvent(pack)
	local id = pack[1]
	if id == "component_added" then
		if pack[3] == "filesystem" then
			require("filesystem").mountDrive(component.proxy(pack[2]), "B")
		end
	end
	if id == "component_removed" then
		if pack[3] == "filesystem" then
			require("filesystem").unmountDrive("B")
		end
	end
	return true
end

local eventlib = require("event")
function dll.scheduler()
	if dll.getCurrentProcess() ~= nil then
		error("only system can use shin32.scheduler()")
	end
	
	-- System Event Handling
	local lastEvent = table.pack(eventlib.handlers(0.05)) -- call for a tick
	if not systemEvent(lastEvent) then
		lastEvent = nil -- if not propagating
	end
	if lastEvent[1] ~= nil then
		eventlib.exechandlers(lastEvent)
	end
	
	for k, p in pairs(processes) do
		if p.status == "created" then
			p.thread = coroutine.create(p.func)
			activeProcesses = activeProcesses + 1
			p.status = "ready"
		end
		if coroutine.status(p.thread) == "dead" then
			dll.kill(p, true)
		else
			if p.status == "wait_event" then
				if lastEvent ~= nil then
					if lastEvent[1] ~= nil then
						p.result = lastEvent
						p.status = "ready"
					end
				end
			end
			if p.status == "ready" then
				p.status = "running"
				local ok, ret, a1, a2, a3
				currentProc = p
				if p.result then
					ok, ret, a1, a2, a3 = coroutine.resume(p.thread, p.result)
					p.result = nil
				else
					ok, ret, a1, a2, a3 = coroutine.resume(p.thread)
				end
				currentProc = nil
				p.status = "ready"
				if not ok then
					if p.parent ~= nil then
						if p.parent.childErrorHandler ~= nil then
							p.parent.childErrorHandler(p, ret)
						else
							error(ret)
						end
					else
						print("PANIC!")
						error(ret) -- just panic if it's system process
					end
				end
				if ret then
					if type(ret) == "function" then
						currentProc = p -- make thinks it's during process execution
						local cont, val = true, nil
						while cont do
							cont, val = ret(val)
						end
						p.result = val
						currentProc = nil
					end
					if type(ret) == "string" then
						if ret == "pull event" then
							p.arg1 = a1
							p.status = "wait_event"
						end
					end
				end
			end
		end
	end
end

function dll.getCurrentProcess()
	return currentProc
end

function dll.getProcess(pid)
	return processes[pid]
end

function dll.waitFor(proc)
	while proc.status ~= "dead" do
		coroutine.yield()
	end
end

function dll.safeKill(proc)
	if proc.safeKillHandler then
		local doKill = proc.safeKillHandler()
		if doKill then
			dll.kill(proc, true) -- bypass because having program agreement over killing
		end
	else
		dll.kill(proc, false)
	end
end

--- bypass = Bypasses the current process protection
function dll.kill(proc, bypass)
	-- Protection due to expected behavior being "instant" kill of the process. But if it is running it needs to
	-- finish its process tick.
	if currentProc == proc and not bypass then -- only current process is in state "running"
		error("cannot kill current process")
	end
	proc.status = "dead"
	activeProcesses = activeProcesses - 1
	if require("security").isRegistered(proc.pid) then
		require("security").revoke(proc.pid)
	end
	for k, v in pairs(proc.closeables) do
		v:close()
	end
	processes[proc.pid] = nil
end

function dll.getActiveProcesses()
	return activeProcesses
end

function dll.getProcesses()
	return processes
end

return dll