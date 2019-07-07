local filesystem = {}
local drives = {}

local function readAll(node, path)
	local handle = node.open(path)
	local buf = ""
	local data = ""
	while data ~= nil do
		buf = buf .. data
		data = node.read(handle, math.huge)
	end
	node.close(handle)
end

local function writeAllTo(node, path, content)
	local handle = node.open(path)
	node.write(handle, content)
	node.close(handle)
end

local function segments(path)
	local parts = {}
	for part in path:gmatch("[^\\/]+") do
		local current, up = part:find("^%.?%.$")
		if current then
			if up == 2 then
				table.remove(parts)
			end
		else
			table.insert(parts, part)
		end
	end
	return parts
end

local function findNode(path)
	checkArg(1, path, "string")
	local seg = segments(path)
	if #seg > 0 then
		local let = seg[1]:sub(1, 1)
		if seg[1]:sub(2, 2) ~= ":" then
			error("no drive separator found (missing \":\", " .. seg[1] .. ") in " .. path)
		end
		if not drives[let] then
			error("Invalid drive letter: " .. let)
		end
		local d = drives[let]
		return d.fs, path:sub(3, path:len()), d
	end
end

-------------------------------------------------------------------------------

function filesystem.canonical(path)
	return table.concat(segments(path), "/")
end

function filesystem.concat(...)
	local set = table.pack(...)
	for index, value in ipairs(set) do
		checkArg(index, value, "string")
	end
	return filesystem.canonical(table.concat(set, "/"))
end

function filesystem.get(path)
	local node, rest = findNode(path)
	if node then
		path = filesystem.canonical(path)
		return node, rest
	end
	return nil, "no such file system"
end

function filesystem.realPath(path)
	local p = filesystem.path(path)
	p = node.letter .. ":/" .. p
	return p
end

function filesystem.unmountDrive(letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	drives[letter:upper()] = nil
	return true
end

function filesystem.isDriveFormatted(letter)
	local drive = drives[letter:upper()]
	if drive == nil then
		error("invalid drive: " .. letter .. ":/")
	end
	if drive.unmanaged then
		return (drive.fs.readSector(0) == string.rep(string.char(0), drive.fs.getSectorSize()))
	else
		return true
	end
end

function filesystem.mountDrive(proxy, letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	drives[letter:upper()] = {
		fs = proxy,
		unmanaged = (proxy.type == "drive"),
		letter = letter
	}
	return true
end

function filesystem.getProxy(letter)
	if letter:len() ~= 1 then
		return false, "invalid length"
	end
	return drives[letter:upper()]
end

function filesystem.path(path)
	local parts = segments(path)
	local result = table.concat(parts, "/", 1, #parts - 1) .. "/"
	return result
end

function filesystem.name(path)
	checkArg(1, path, "string")
	local parts = segments(path)
	return parts[#parts]
end

function filesystem.exists(path)
	if path:len() < 2 then
		return false
	else
		if path:sub(2, 2) ~= ":" then
			return false
		end
	end
	local node, rest = findNode(path)
	if node then
		return node.exists(rest)
	end
	return false
end

function filesystem.isDirectory(path)
	if not filesystem.exists(path) then return false end
	local node, rest = findNode(path)
	if node == nil then return false end
	return node.isDirectory(rest)
end

function filesystem.list(path)
	local node, rest = findNode(path)
	local result = {}
	if node then
		result = node.list(rest)
	end
	local set = {}
	local keys = {}
	for _,name in ipairs(result) do
		local key = filesystem.canonical(name)
		set[key] = name
		table.insert(keys, key)
	end
	local i = 1
	return function()
		if i == #keys+1 then
			return nil
		end
		i = i + 1
		return keys[i-1], set[keys[i-1]]
	end
end

function filesystem.makeDirectory(path)
	local node, rest = findNode(path)
	if node then
		if not node.makeDirectory(rest) then
			error("could not create directory")
		end
	else
		error("no drive")
	end
end

function filesystem.remove(path)
	local node, rest = findNode(path)
	if not node then
		return false
	end
	return node.remove(rest)
end

function filesystem.rename(oldPath, newPath)
	local oldNode, oldRest = findNode(oldPath)
	local newNode, newRest = findNode(newPath)
	if oldNode == newNode then
		return oldNode.rename(oldRest, newRest)
	else
		if not oldNode.exists(oldRest) then
			return false
		end
		local content = readAll(oldNode, oldRest)
		writeAllTo(newNode, newRest, content)
	end
end

function filesystem.unmanagedFilesystems()
	return {}
end

function filesystem.open(path, mode)
	checkArg(1, path, "string")
	mode = tostring(mode or "r")
	checkArg(2, mode, "string")
	assert(({r=true, rb=true, w=true, wb=true, a=true, ab=true})[mode],
		"bad argument #2 (r[b], w[b] or a[b] expected, got " .. mode .. ")")
	local node, rest = findNode(path)
	local segs = segments(path)
	table.remove(segs, 1)
	if not node then
		return nil, "drive not found"
	end
	if (({r=true,rb=true})[mode] and not node.exists(rest)) then
		return nil, "file not found"
	end
	local handle, reason = node.open(rest, mode)
	if not handle then
		return nil, reason
	end

	local function create_handle_method(key)
		return function(self, ...)
			if not self.handle then
				return nil, "file is closed"
			end
			return self.fs[key](self.handle, ...)
		end
	end
	local cproc = nil
	if shin32 then cproc = shin32.getCurrentProcess() end
	local stream =
	{
		fs = node,
		handle = handle,
		proc = cproc,
		close = function(self)
			if self.handle then
				self.fs.close(self.handle)
				self.handle = nil
				if self.proc ~= nil then
					for k, v in pairs(self.proc.closeables) do
						if v == self then
							table.remove(self.proc.closeables, k)
						end
					end
				end
			end
		end
	}
	stream.read = create_handle_method("read")
	stream.seek = create_handle_method("seek")
	stream.write = create_handle_method("write")
	if stream.proc ~= nil then
		table.insert(stream.proc.closeables, stream)
	end
	return stream
end

filesystem.findNode = findNode
filesystem.segments = segments

-------------------------------------------------------------------------------

return filesystem
