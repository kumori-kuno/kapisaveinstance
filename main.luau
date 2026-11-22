--[[
	kUSI (kAPI Universal Save Instance) — kAPI's take on UniversalSynSaveInstance, built only on executor globals.

	local saveinstance = loadstring(readfile("kUSI.lua"))()  -- or paste and call directly
	saveinstance(game)                       → place file (.rbxlx) of game's children
	saveinstance(workspace.Model)            → model file (.rbxmx) of that instance
	saveinstance(game, { noscripts = true }) → with options
	saveinstance({ Object = part, ... })     → USSI's table style also works

	Options (USSI names): mode ("optimized" | "full" | "scripts"), noscripts, Decompile,
	DecompileIgnore, IgnoreList, IgnoreProperties, IgnoreNotArchivable, NilInstances,
	RemovePlayerCharacters, SavePlayers, IsolateLocalPlayer, ExtraInstances, FilePath,
	SaveBytecode, ShowStatus, Callback, ReadMe
]]

--------------------------------------------------------------- globals → locals
-- every executor global is looked up ONCE, by any of its common names, type-checked,
-- with a fallback when it's missing
local genv = (typeof(getgenv) == "function" and getgenv()) or getfenv(0)
local function exists(names, kind, fallback)
	if type(names) == "string" then names = { names } end
	for _, name in names do
		local value = genv[name]
		if value == nil then value = getfenv(0)[name] end
		-- dotted names: "crypt.base64encode"
		if value == nil and name:find(".", 1, true) then
			local lib, member = name:match("^([^.]+)%.(.+)$")
			local t = genv[lib] or getfenv(0)[lib]
			if type(t) == "table" then value = t[member] end
		end
		if value ~= nil and (kind == nil or type(value) == kind) then return value end
	end
	return fallback
end

local identifyexecutor  = exists({ "identifyexecutor", "getexecutorname", "whatexecutor" }, "function", function() return "Unknown", "" end)
local gethiddenproperty = exists({ "gethiddenproperty", "get_hidden_property" }, "function")
local isscriptable      = exists("isscriptable", "function")
local decompile         = exists({ "decompile", "Decompile" }, "function")
local getscriptbytecode = exists({ "getscriptbytecode", "dumpstring", "getscriptbytecodes" }, "function")
local getnilinstances   = exists({ "getnilinstances", "get_nil_instances" }, "function", function() return {} end)
local base64encode      = exists({ "crypt.base64encode", "base64encode", "base64.encode", "crypt.base64.encode" }, "function")
local writefile         = exists("writefile", "function")
local gethui            = exists({ "gethui", "get_hidden_gui" }, "function")
local protectgui        = exists({ "protectgui", "protect_gui", "syn.protect_gui" }, "function")
local setclipboard      = exists({ "setclipboard", "toclipboard", "set_clipboard" }, "function")
-- downloads: executor request → game:HttpGet → HttpService:GetAsync (plain server scripts
-- with HTTP requests enabled), first one that works
local requestFn = exists({ "request", "http_request", "http.request", "syn.request" }, "function")
local function httpget(url)
	local errors = {}
	if requestFn then
		local ok, r = pcall(requestFn, { Url = url, Method = "GET" })
		if ok and type(r) == "table" and type(r.Body) == "string" and (r.StatusCode == nil or r.StatusCode < 400) then return r.Body end
		table.insert(errors, "request: " .. tostring(ok and (type(r) == "table" and r.StatusCode) or r))
	end
	local ok1, body1 = pcall(function() return game:HttpGet(url, true) end)
	if ok1 and type(body1) == "string" then return body1 end
	table.insert(errors, "HttpGet: " .. tostring(body1))
	local ok2, body2 = pcall(function() return game:GetService("HttpService"):GetAsync(url) end)
	if ok2 and type(body2) == "string" then return body2 end
	table.insert(errors, "GetAsync: " .. tostring(body2))
	error("[kUSI] couldn't download " .. url .. " (" .. table.concat(errors, " / ") .. ")", 0)
end

-- no writefile (plain script, script builder...): the file text is handed back instead
if not base64encode then
	-- pure-Luau fallback
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	base64encode = function(data)
		return ((data:gsub(".", function(x)
			local r, b = "", x:byte()
			for i = 8, 1, -1 do r ..= (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
			return r
		end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
			if #x < 6 then return "" end
			local c = 0
			for i = 1, 6 do c += (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
			return chars:sub(c + 1, c + 1)
		end) .. ({ "", "==", "=" })[#data % 3 + 1])
	end
end
local function base64(s) if s == "" then return "" end return base64encode(s) end

-- own buffer-based base64 for big binary blobs (terrain): doesn't depend on how an
-- executor's base64encode copes with megabytes of raw bytes
local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64BYTES = {}
for i = 1, 64 do B64BYTES[i - 1] = B64CHARS:byte(i) end
local function base64big(s)
	local n = #s
	if n == 0 then return "" end
	local src = buffer.fromstring(s)
	local out = buffer.create(((n + 2) // 3) * 4)
	local o = 0
	for i = 0, n - 1, 3 do
		local b1 = buffer.readu8(src, i)
		local b2 = i + 1 < n and buffer.readu8(src, i + 1) or 0
		local b3 = i + 2 < n and buffer.readu8(src, i + 2) or 0
		local v = b1 * 65536 + b2 * 256 + b3
		buffer.writeu8(out, o, B64BYTES[v // 262144])
		buffer.writeu8(out, o + 1, B64BYTES[(v // 4096) % 64])
		buffer.writeu8(out, o + 2, i + 1 < n and B64BYTES[(v // 64) % 64] or 61)
		buffer.writeu8(out, o + 3, i + 2 < n and B64BYTES[v % 64] or 61)
		o += 4
	end
	return buffer.tostring(out)
end

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local DEFAULTS = {
	mode = "optimized", noscripts = false, Decompile = true, DecompileIgnore = {},
	IgnoreList = {}, IgnoreProperties = {}, IgnoreNotArchivable = true, NilInstances = false,
	RemovePlayerCharacters = true, SavePlayers = false, IsolateLocalPlayer = false,
	ExtraInstances = {}, FilePath = nil, SaveBytecode = false, ShowStatus = true,
	Callback = nil, ReadMe = true, YieldEvery = 400, Debug = false,
	-- terrain: the real SmoothGrid when the executor can read it, otherwise a rebuild module
	SaveTerrain = true, TerrainBackup = "auto", -- "auto" | "always" | "never"
	TerrainMinY = -2048, TerrainMaxY = 2048, -- height range the backup looks in (X/Z is found automatically)
}

--------------------------------------------------------------- API dump (cached between calls)
local classes
local propCache = {}
-- an executor can hand kUSI its own API dump for offline use (kAPI does: __kusi_localdump)
local localDumpFn = exists("__kusi_localdump", "function")
local classesLocal
local function loadDump()
	-- getgenv().KUSI_LOCALDUMP = true: use the executor's own dump even when online (testing)
	local wantLocal = localDumpFn ~= nil and genv.KUSI_LOCALDUMP == true
	if classes and classesLocal == wantLocal then return end
	classes, classesLocal = nil, wantLocal
	table.clear(propCache)
	local okH, dump = pcall(function()
		if wantLocal then error("KUSI_LOCALDUMP is on", 0) end
		return HttpService:JSONDecode(httpget("https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Full-API-Dump.json"))
	end)
	if not okH then
		if not localDumpFn then error(dump, 0) end
		warn("[kUSI] couldn't download the API dump, using the executor's built-in one")
		dump = localDumpFn()
	end
	classes = {}
	for _, c in dump.Classes do classes[c.Name] = c end
end

local function tagged(list, t)
	for _, x in list or {} do if x == t then return true end end
	return false
end

-- properties that load back, with their serialized name (xml names win over script names)
local SKIP = { Parent = true, Archivable = true, UniqueId = true, HistoryId = true, ScriptGuid = true, Capabilities = true, DefinesCapabilities = true, SourceAssetId = true }
local function propsOf(className)
	local cached = propCache[className]
	if cached then return cached end
	local list, seen, class = {}, {}, classes[className] or classes.Instance
	while class do
		for _, m in class.Members do
			if m.MemberType == "Property" and not seen[m.Name] then
				seen[m.Name] = true
				local ser = m.Serialization or {}
				if ser.CanLoad and ser.CanSave and not SKIP[m.Name] then
					table.insert(list, {
						name = m.Name, vt = m.ValueType.Name, cat = m.ValueType.Category,
						hidden = tagged(m.Tags, "NotScriptable"),
					})
				end
			end
		end
		class = classes[class.Superclass]
	end
	-- old ContentId props that now have a Content twin (Image → ImageContent, SoundId → AudioContent):
	-- Studio wants only one of each pair, so the newer Content one is kept
	local contentNames = {}
	for _, p in list do if p.vt == "Content" then contentNames[p.name] = true end end
	local SPECIAL = {
		SoundId = "AudioContent", SkyboxBk = "SkyboxBackContent", SkyboxDn = "SkyboxDownContent",
		SkyboxFt = "SkyboxFrontContent", SkyboxLf = "SkyboxLeftContent", SkyboxRt = "SkyboxRightContent",
		SkyboxUp = "SkyboxUpContent", MoonTextureId = "MoonTextureContent", SunTextureId = "SunTextureContent",
	}
	local function twinOf(n)
		for _, c in { SPECIAL[n], n .. "Content", (n:gsub("I[dD]$", "Content")), (n:gsub("TextureI[dD]$", "TextureContent")) } do
			if c and contentNames[c] then return c end
		end
		return nil
	end
	local final = {}
	for _, p in list do
		-- any legacy property with a Content twin is dropped, whatever its type
		-- (CharacterMesh.MeshId is an int64 asset id, not a ContentId, but it still conflicts)
		if not (p.vt ~= "Content" and twinOf(p.name)) then table.insert(final, p) end
	end
	list = final
	propCache[className] = list
	return list
end
local function isCreatable(className)
	local c = classes[className]
	-- a class the dump doesn't know (newer than the dump): saved, with the properties it can read
	if c == nil then return true end
	return not tagged(c.Tags, "NotCreatable")
end
local function isService(className)
	local c = classes[className]
	return c ~= nil and tagged(c.Tags, "Service")
end


---------------------------------------------------------------- text cleaning
-- valid UTF-8 only, no control characters except tab/newline/CR (XML 1.0 rejects them)
local function clean(s)
	s = tostring(s)
	if utf8.len(s) == nil then
		local out = {}
		local i, n = 1, #s
		while i <= n do
			local ok, cp = pcall(utf8.codepoint, s, i)
			if ok then
				local ch = utf8.char(cp)
				table.insert(out, ch)
				i += #ch
			else
				i += 1
			end
		end
		s = table.concat(out)
	end
	return (s:gsub("[%z\1-\8\11\12\14-\31\127]", ""))
end
local function esc(s)
	return (clean(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
local CLOSE = "]" .. "]>"
local function cdata(s)
	return "<![CDATA[" .. clean(s):gsub(CLOSE, "]" .. "]" .. CLOSE .. "<![CDATA[>") .. CLOSE
end
local function num(x)
	if x ~= x then return "NAN" elseif x == math.huge then return "INF" elseif x == -math.huge then return "-INF" end
	if x % 1 == 0 and math.abs(x) < 2^53 then return string.format("%d", x) end
	return string.format("%.9g", x)
end
local function int(x) return string.format("%d", math.floor(x + 0.5)) end
local function T(tag, name, inner) return ('<%s name="%s">%s</%s>'):format(tag, esc(name), inner, tag) end

---------------------------------------------------------------- binary blobs
local function packStr(s) return string.pack("<I4", #s) .. s end
local function attrValue(v)
	local t = typeof(v)
	if t == "string" then return "\2" .. packStr(v)
	elseif t == "boolean" then return "\3" .. string.char(v and 1 or 0)
	elseif t == "number" then return "\6" .. string.pack("<d", v)
	elseif t == "UDim" then return "\9" .. string.pack("<fi4", v.Scale, v.Offset)
	elseif t == "UDim2" then return "\10" .. string.pack("<fi4fi4", v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
	elseif t == "BrickColor" then return "\14" .. string.pack("<I4", v.Number)
	elseif t == "Color3" then return "\15" .. string.pack("<fff", v.R, v.G, v.B)
	elseif t == "Vector2" then return "\16" .. string.pack("<ff", v.X, v.Y)
	elseif t == "Vector3" then return "\17" .. string.pack("<fff", v.X, v.Y, v.Z)
	elseif t == "CFrame" then
		local c = { v:GetComponents() }
		return "\20" .. string.pack("<fff", c[1], c[2], c[3]) .. "\0" .. string.pack("<fffffffff", c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	elseif t == "EnumItem" then return "\21" .. packStr(tostring(v.EnumType)) .. string.pack("<I4", v.Value)
	elseif t == "NumberSequence" then
		local out = { string.pack("<I4", #v.Keypoints) }
		for _, k in v.Keypoints do table.insert(out, string.pack("<fff", k.Envelope, k.Time, k.Value)) end
		return "\23" .. table.concat(out)
	elseif t == "ColorSequence" then
		local out = { string.pack("<I4", #v.Keypoints) }
		for _, k in v.Keypoints do table.insert(out, string.pack("<fffff", 0, k.Time, k.Value.R, k.Value.G, k.Value.B)) end
		return "\25" .. table.concat(out)
	elseif t == "NumberRange" then return "\27" .. string.pack("<ff", v.Min, v.Max)
	elseif t == "Rect" then return "\28" .. string.pack("<ffff", v.Min.X, v.Min.Y, v.Max.X, v.Max.Y)
	elseif t == "Font" then return "\33" .. string.pack("<I2B", v.Weight.Value, v.Style.Value) .. packStr(v.Family) .. packStr("")
	end
	return nil
end
local function attributesBlob(obj)
	local ok, attrs = pcall(obj.GetAttributes, obj)
	if not ok or next(attrs) == nil then return nil end
	local keys = {}
	for k in attrs do table.insert(keys, k) end
	table.sort(keys)
	local parts, count = {}, 0
	for _, k in keys do
		local enc = attrValue(attrs[k])
		if enc then
			count += 1
			table.insert(parts, packStr(k) .. enc)
		end
	end
	if count == 0 then return nil end
	return string.pack("<I4", count) .. table.concat(parts)
end


--------------------------------------------------------------- status label
local function makeStatus(enabled)
	if not enabled then return function() end, function() end end
	local gui = Instance.new("ScreenGui")
	gui.Name = "kUSI"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1e6
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 26)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = 16
	label.Text = "kUSI: starting"
	label.Parent = gui
	if protectgui then pcall(protectgui, gui) end
	local parent = gethui and select(2, pcall(gethui))
	if typeof(parent) ~= "Instance" and type(parent) ~= "userdata" then parent = game:GetService("CoreGui") end
	if not pcall(function() gui.Parent = parent end) then gui.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") end
	return function(text) label.Text = "kUSI: " .. text end, function() task.delay(2, gui.Destroy, gui) end
end

--------------------------------------------------------------- the saver
local PLACE_SERVICES = { "Workspace", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "StarterGui", "StarterPack",
	"StarterPlayer", "SoundService", "Teams", "Chat", "TextChatService", "MaterialService", "LocalizationService" }

--------------------------------------------------------------- options, every executor's way
-- Accepts USSI's names, Madium/kAPI's SaveInstanceOptions names, and the common aliases
-- executors use, in any letter case. Inverted ones are flipped (SavePlayerCharacters → not RemovePlayerCharacters).
local OPTION_ALIASES = {
	-- name (lowercased) = { kUSI option, invert? }
	mode = { "mode" }, savemode = { "mode" },
	noscripts = { "noscripts" }, ignorescripts = { "noscripts" },
	decompile = { "Decompile" }, decompilescripts = { "Decompile" }, decomp = { "Decompile" },
	decompileignore = { "DecompileIgnore" },
	ignorelist = { "IgnoreList" }, ignoreinstances = { "IgnoreList" },
	ignoreproperties = { "IgnoreProperties" },
	ignorenotarchivable = { "IgnoreNotArchivable" }, ignorearchivable = { "IgnoreNotArchivable", true },
	nilinstances = { "NilInstances" }, savenilinstances = { "NilInstances" }, nilinstancesfix = { "NilInstances" },
	removeplayercharacters = { "RemovePlayerCharacters" }, saveplayercharacters = { "RemovePlayerCharacters", true },
	saveplayers = { "SavePlayers" }, isolateplayers = { "SavePlayers" },
	isolatelocalplayer = { "IsolateLocalPlayer" }, isolatelocalplayercharacter = { "IsolateLocalPlayer" },
	extrainstances = { "ExtraInstances" },
	object = { "Object" }, instance = { "Object" },
	filepath = { "FilePath" }, filename = { "FilePath" }, file = { "FilePath" },
	savebytecode = { "SaveBytecode" },
	showstatus = { "ShowStatus" },
	callback = { "Callback" },
	readme = { "ReadMe" },
	debug = { "Debug" }, __debug_mode = { "Debug" },
	yieldevery = { "YieldEvery" },
	savenoncreatable = { "SaveNonCreatable" },
	copytoclipboard = { "CopyToClipboard" },
	saveterrain = { "SaveTerrain" }, terrainbackup = { "TerrainBackup" },
	terrainminy = { "TerrainMinY" }, terrainmaxy = { "TerrainMaxY" },
	-- accepted so scripts written for other savers don't break; nothing to do here
	disablecompression = { false }, decompileroptions = { false }, antiidle = { false },
	safemode = { false }, shutdownwhendone = { false }, timeout = { false }, decompiletimeout = { false },
	avoidfilenamecollision = { false }, alternativewritefile = { false }, ignoredefaultproperties = { false },
	ignorespecialproperties = { false }, ignoresharedstrings = { false }, sharedstringoverwrite = { false },
	treatunionsasparts = { false }, isolatestarterplayer = { false },
}
local function normalizeOptions(options)
	local OPTIONS = table.clone(DEFAULTS)
	OPTIONS.SaveNonCreatable, OPTIONS.CopyToClipboard = false, false
	for key, value in options or {} do
		local alias = type(key) == "string" and OPTION_ALIASES[key:lower()]
		if alias then
			if alias[1] then
				if alias[2] and type(value) == "boolean" then value = not value end
				OPTIONS[alias[1]] = value
			end
		elseif type(key) == "string" then
			OPTIONS[key] = value -- unknown: kept as-is
		end
	end
	if OPTIONS.noscripts then OPTIONS.Decompile = false end
	if type(OPTIONS.mode) == "string" then OPTIONS.mode = OPTIONS.mode:lower() end
	return OPTIONS
end

local function saveinstance(target, options)
	local START = os.clock()
	-- USSI table style: saveinstance({ Object = x, ... })
	if type(target) == "table" and options == nil then
		local obj
		for k, v in target do
			if type(k) == "string" and (k:lower() == "object" or k:lower() == "instance") then obj = v end
		end
		options, target = target, obj or game
	end
	local OPTIONS = normalizeOptions(options)
	if typeof(target) ~= "Instance" and type(target) ~= "userdata" then error("[kUSI] expected an Instance to save", 2) end

	local status, done = makeStatus(OPTIONS.ShowStatus)
	status("downloading the API dump")
	loadDump()

	local isPlace = target == game
	local ignore, ignoreClass = {}, {}
	for _, v in OPTIONS.IgnoreList do if type(v) == "string" then ignoreClass[v] = true else ignore[v] = true end end
	local ignoreProp = {}
	for k, v in OPTIONS.IgnoreProperties do if type(k) == "string" then ignoreProp[k] = true elseif type(v) == "string" then ignoreProp[v] = true end end
	local decompileIgnore = {}
	for _, v in OPTIONS.DecompileIgnore do decompileIgnore[v] = true end
	local scriptsOnly = OPTIONS.mode == "scripts"

	------------------------------------------------ reading
	local function read(obj, p)
		if not p.hidden then
			local ok, v = pcall(function() return obj[p.name] end)
			if ok then return true, v end
		elseif isscriptable then
			local ok, s = pcall(isscriptable, obj, p.name)
			if ok and s then
				local okV, v = pcall(function() return obj[p.name] end)
				if okV then return true, v end
			end
		end
		if gethiddenproperty then
			local ok, v = pcall(gethiddenproperty, obj, p.name)
			if ok and v ~= nil then return true, v end
		end
		-- InitialSize (the mesh's own size) is also readable as MeshSize
		if p.name == "InitialSize" then
			local ok, v = pcall(function() return obj.MeshSize end)
			if ok and typeof(v) == "Vector3" then return true, v end
		end
		return false
	end
	local decompiled = 0
	local decompileFails = {}
	local function scriptSource(obj)
		local src
		if OPTIONS.noscripts then
			src = "-- kUSI: noscripts is on"
		elseif decompileIgnore[obj] or decompileIgnore[obj.ClassName] then
			src = "-- kUSI: in DecompileIgnore"
		elseif OPTIONS.Decompile then
			local fn = decompile or exists({ "decompile", "Decompile" }, "function")
			if not fn then
				decompileFails["decompile is missing"] = (decompileFails["decompile is missing"] or 0) + 1
			else
				local ok, out = pcall(fn, obj)
				if ok and type(out) == "string" and out ~= "" then
					src = out
					decompiled += 1
				else
					local why = ok and (type(out) == "string" and "returned an empty string" or ("returned " .. typeof(out))) or tostring(out):sub(1, 120)
					decompileFails[why] = (decompileFails[why] or 0) + 1
				end
			end
		end
		src = src or "-- kUSI: couldn't decompile this script"
		if OPTIONS.SaveBytecode and getscriptbytecode then
			local ok, bc = pcall(getscriptbytecode, obj)
			if ok and type(bc) == "string" and bc ~= "" then src ..= "\n\n--[[ bytecode (base64)\n" .. base64(bc) .. "\n]]" end
		end
		return src
	end

	------------------------------------------------ pass 1: referents
	local refs, count = {}, 0
	local playerChars = {}
	if OPTIONS.RemovePlayerCharacters then
		for _, plr in Players:GetPlayers() do if plr.Character then playerChars[plr.Character] = true end end
	end
	local function include(obj, isRoot)
		if ignore[obj] or playerChars[obj] then return false end
		local okC, className = pcall(function() return obj.ClassName end)
		if not okC or ignoreClass[className] then return false end
		if obj:IsA("Players") and not OPTIONS.SavePlayers then return false end
		if obj:IsA("Terrain") then return OPTIONS.SaveTerrain == true end
		if not isRoot then
			if obj:IsA("Camera") and obj == workspace.CurrentCamera then return true end
			if not OPTIONS.SaveNonCreatable and not isCreatable(className) and not obj:IsA("LuaSourceContainer") then return false end
		end
		if OPTIONS.IgnoreNotArchivable then
			local okA, arch = pcall(function() return obj.Archivable end)
			if okA and arch == false then return false end
		end
		return true
	end
	local function collect(obj, isRoot)
		if refs[obj] or not include(obj, isRoot) then return end
		refs[obj] = "RBX" .. HttpService:GenerateGUID(false):gsub("-", "")
		count += 1
		if count % 1000 == 0 then status(("found %d instances"):format(count)) task.wait() end
		for _, child in obj:GetChildren() do collect(child, false) end
	end

	-- game → its children (by mode); anything else → that instance
	local roots = {}
	if isPlace then
		if OPTIONS.mode == "full" then
			for _, child in game:GetChildren() do table.insert(roots, child) end
		else
			for _, s in PLACE_SERVICES do
				local ok, svc = pcall(game.FindService, game, s)
				if ok and svc then table.insert(roots, svc) end
			end
		end
	else
		table.insert(roots, target)
	end
	for _, v in OPTIONS.ExtraInstances do table.insert(roots, v) end
	for _, r in roots do collect(r, true) end

	local extraFolders = {}
	-- IsolateLocalPlayer: PlayerGui / Backpack / PlayerScripts in their own folder
	if isPlace and OPTIONS.IsolateLocalPlayer and Players.LocalPlayer then
		local list = {}
		for _, name in { "PlayerGui", "Backpack", "PlayerScripts" } do
			local f = Players.LocalPlayer:FindFirstChild(name)
			if f then for _, child in f:GetChildren() do collect(child, false) if refs[child] then table.insert(list, child) end end end
		end
		table.insert(extraFolders, { name = "LocalPlayer", items = list })
	end
	if isPlace and OPTIONS.NilInstances then
		local list = {}
		local ok, nils = pcall(getnilinstances)
		for _, obj in ok and nils or {} do
			if not refs[obj] then collect(obj, false) if refs[obj] then table.insert(list, obj) end end
		end
		table.insert(extraFolders, { name = "Nil Instances", items = list })
	end

	------------------------------------------------ pass 2: write
	local skipped = {}
	local leftOut = {}
	local currentObj
	local function skip(vt)
		skipped[vt] = (skipped[vt] or 0) + 1
		return nil
	end
	local encode
	do
		local OPTIONS_ENCODE = nil
		
		encode = function(p, v)
			local name, vt = p.name, p.vt
			if p.cat == "Enum" then
				if typeof(v) ~= "EnumItem" then return skip(vt) end
				return T("token", name, int(v.Value))
			elseif p.cat == "Class" then
				local r = typeof(v) == "Instance" and refs[v] or nil
				return T("Ref", name, r or "null")
			end
			local t = typeof(v)
			if vt == "bool" then return T("bool", name, v and "true" or "false") end
			if vt == "int" or vt == "int64" then
				if type(v) ~= "number" then return skip(vt) end
				return T(vt, name, int(v))
			end
			if vt == "float" or vt == "double" then
				if type(v) ~= "number" then return skip(vt) end
				return T(vt, name, num(v))
			end
			if vt == "string" then
				if type(v) ~= "string" then return skip(vt) end
				return T("string", name, esc(v))
			end
			if vt == "ProtectedString" then return T("ProtectedString", name, cdata(v)) end
			if vt == "BinaryString" then
				if type(v) ~= "string" then return skip(vt) end
				return T("BinaryString", name, base64(v))
			end
			if vt == "ContentId" then
				local s = type(v) == "string" and v or ""
				return T("Content", name, s == "" and "<null></null>" or "<url>" .. esc(s) .. "</url>")
			end
			if vt == "Content" then
				if t == "string" then return T("Content", name, v == "" and "<null></null>" or "<uri>" .. esc(v) .. "</uri>") end
				if t ~= "Content" then return skip(vt) end
				local okU, uri = pcall(function() return v.Uri end)
				if okU and type(uri) == "string" and uri ~= "" then return T("Content", name, "<uri>" .. esc(uri) .. "</uri>") end
				local okO, o = pcall(function() return v.Object end)
				if okO and typeof(o) == "Instance" and refs[o] then return T("Content", name, "<Ref>" .. refs[o] .. "</Ref>") end
				return T("Content", name, "<null></null>")
			end
			if vt == "Vector3" and t == "Vector3" then return T("Vector3", name, ("<X>%s</X><Y>%s</Y><Z>%s</Z>"):format(num(v.X), num(v.Y), num(v.Z))) end
			if vt == "Vector2" and t == "Vector2" then return T("Vector2", name, ("<X>%s</X><Y>%s</Y>"):format(num(v.X), num(v.Y))) end
			if vt == "Vector3int16" and t == "Vector3int16" then return T("Vector3int16", name, ("<X>%d</X><Y>%d</Y><Z>%d</Z>"):format(v.X, v.Y, v.Z)) end
			if vt == "Vector2int16" and t == "Vector2int16" then return T("Vector2int16", name, ("<X>%d</X><Y>%d</Y>"):format(v.X, v.Y)) end
			if (vt == "CFrame" or vt == "OptionalCoordinateFrame") then
				if t ~= "CFrame" then
					if vt == "OptionalCoordinateFrame" then return T("OptionalCoordinateFrame", name, "") end
					return skip(vt)
				end
				local c = { v:GetComponents() }
				for i, x in c do c[i] = num(x) end
				local body = ("<X>%s</X><Y>%s</Y><Z>%s</Z><R00>%s</R00><R01>%s</R01><R02>%s</R02><R10>%s</R10><R11>%s</R11><R12>%s</R12><R20>%s</R20><R21>%s</R21><R22>%s</R22>"):format(table.unpack(c))
				if vt == "OptionalCoordinateFrame" then return T("OptionalCoordinateFrame", name, "<CFrame>" .. body .. "</CFrame>") end
				return T("CoordinateFrame", name, body)
			end
			if vt == "Color3uint8" and t == "Color3" then
				local r, gg, b = math.clamp(math.floor(v.R * 255 + 0.5), 0, 255), math.clamp(math.floor(v.G * 255 + 0.5), 0, 255), math.clamp(math.floor(v.B * 255 + 0.5), 0, 255)
				return T("Color3uint8", name, string.format("%d", 0xFF000000 + r * 0x10000 + gg * 0x100 + b))
			end
			if vt == "Color3" and t == "Color3" then return T("Color3", name, ("<R>%s</R><G>%s</G><B>%s</B>"):format(num(v.R), num(v.G), num(v.B))) end
			if vt == "BrickColor" and t == "BrickColor" then return T("int", name, int(v.Number)) end
			if vt == "UDim" and t == "UDim" then return T("UDim", name, ("<S>%s</S><O>%d</O>"):format(num(v.Scale), v.Offset)) end
			if vt == "UDim2" and t == "UDim2" then return T("UDim2", name, ("<XS>%s</XS><XO>%d</XO><YS>%s</YS><YO>%d</YO>"):format(num(v.X.Scale), v.X.Offset, num(v.Y.Scale), v.Y.Offset)) end
			if vt == "NumberRange" and t == "NumberRange" then return T("NumberRange", name, num(v.Min) .. " " .. num(v.Max) .. " ") end
			if vt == "NumberSequence" and t == "NumberSequence" then
				local out = {}
				for _, k in v.Keypoints do table.insert(out, num(k.Time) .. " " .. num(k.Value) .. " " .. num(k.Envelope) .. " ") end
				return T("NumberSequence", name, table.concat(out))
			end
			if vt == "ColorSequence" and t == "ColorSequence" then
				local out = {}
				for _, k in v.Keypoints do table.insert(out, ("%s %s %s %s 0 "):format(num(k.Time), num(k.Value.R), num(k.Value.G), num(k.Value.B))) end
				return T("ColorSequence", name, table.concat(out))
			end
			if vt == "Rect" and t == "Rect" then
				return T("Rect2D", name, ("<min><X>%s</X><Y>%s</Y></min><max><X>%s</X><Y>%s</Y></max>"):format(num(v.Min.X), num(v.Min.Y), num(v.Max.X), num(v.Max.Y)))
			end
			if vt == "Faces" and t == "Faces" then
				local bits = 0
				for i, f in { "Right", "Top", "Back", "Left", "Bottom", "Front" } do if v[f] then bits += 2 ^ (i - 1) end end
				return T("Faces", name, "<faces>" .. bits .. "</faces>")
			end
			if vt == "Axes" and t == "Axes" then return T("Axes", name, "<axes>" .. ((v.X and 1 or 0) + (v.Y and 2 or 0) + (v.Z and 4 or 0)) .. "</axes>") end
			if vt == "PhysicalProperties" then
				if t ~= "PhysicalProperties" then return T("PhysicalProperties", name, "<CustomPhysics>false</CustomPhysics>") end
				local okA, aa = pcall(function() return v.AcousticAbsorption end)
				return T("PhysicalProperties", name, ("<CustomPhysics>true</CustomPhysics><Density>%s</Density><Friction>%s</Friction><Elasticity>%s</Elasticity><FrictionWeight>%s</FrictionWeight><ElasticityWeight>%s</ElasticityWeight>%s")
					:format(num(v.Density), num(v.Friction), num(v.Elasticity), num(v.FrictionWeight), num(v.ElasticityWeight),
						okA and type(aa) == "number" and ("<AcousticAbsorption>" .. num(aa) .. "</AcousticAbsorption>") or ""))
			end
			if vt == "Font" and t == "Font" then
				return T("Font", name, ("<Family><url>%s</url></Family><Weight>%d</Weight><Style>%s</Style>"):format(esc(v.Family), v.Weight.Value, v.Style.Name))
			end
			return skip(vt)
		end
		
	end

	local out = { '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" version="4">', "<External>null</External><External>nil</External>" }
	local written, props = 0, 0

	------------------------------------------------ terrain
	-- MaterialColors: 6 zero bytes, then RGB for each terrain material in this order
	local TERRAIN_MATERIALS = { "Grass", "Slate", "Concrete", "Brick", "Sand", "WoodPlanks", "Rock", "Glacier", "Snow",
		"Sandstone", "Mud", "Basalt", "Ground", "CrackedLava", "Asphalt", "Cobblestone", "Ice", "LeafyGrass", "Salt",
		"Limestone", "Pavement" }
	local function materialColorsBlob(terrain)
		local parts = { string.rep("\0", 6) }
		for _, name in TERRAIN_MATERIALS do
			local ok, c = pcall(terrain.GetMaterialColor, terrain, Enum.Material[name])
			if not ok then c = Color3.new(0.5, 0.5, 0.5) end
			table.insert(parts, string.char(math.clamp(math.floor(c.R * 255 + 0.5), 0, 255), math.clamp(math.floor(c.G * 255 + 0.5), 0, 255), math.clamp(math.floor(c.B * 255 + 0.5), 0, 255)))
		end
		return table.concat(parts)
	end
	local terrainGridIsReal = false
	local extraChildren = {} -- instance → extra <Item> text written inside it
	local function readTerrainBlob(terrain, name)
		if not gethiddenproperty then return nil end
		local ok, v = pcall(gethiddenproperty, terrain, name)
		if ok and type(v) == "string" and #v > 0 then return v end
		return nil
	end

	-- backup: read the voxels in 64-stud chunks, keep the non-empty ones, run-length encoded
	-- backup: find every loaded bit of terrain, then read it in 64-stud chunks
	local function captureVoxels(terrain)
		local CHUNK, RES = 64, 4
		local TOP, BOTTOM = OPTIONS.TerrainMaxY, OPTIONS.TerrainMinY
		local LIMIT = 16384 -- terrain can't go past this on X/Z
		local frameStart = os.clock()
		local function breathe(text)
			if os.clock() - frameStart > 0.008 then
				status(text)
				task.wait()
				frameStart = os.clock()
			end
		end

		-- rays that only count terrain (parts in the way are stepped through)
		local params = RaycastParams.new()
		params.IgnoreWater = false
		local function terrainHit(origin, dir)
			for _ = 1, 24 do
				local hit = workspace:Raycast(origin, dir, params)
				if not hit then return nil end
				local okT, isTerrain = pcall(function() return hit.Instance:IsA("Terrain") end)
				if okT and isTerrain then return hit end
				local travelled = (hit.Position - origin).Magnitude + 0.05
				origin = hit.Position + dir.Unit * 0.05
				dir = dir.Unit * (dir.Magnitude - travelled)
				if dir.Magnitude <= 0.1 then return nil end
			end
			return nil
		end

		-- probe one 64-stud column: its terrain top and bottom (nil = no terrain)
		local probed, columns = {}, {}
		local function probe(cx, cz)
			local key = cx .. "," .. cz
			if probed[key] ~= nil then return probed[key] end
			local top, bottom
			for ox = 8, CHUNK, 16 do
				for oz = 8, CHUNK, 16 do
					local down = terrainHit(Vector3.new(cx + ox, TOP, cz + oz), Vector3.new(0, BOTTOM - TOP, 0))
					if down then
						if not top or down.Position.Y > top then top = down.Position.Y end
						local up = terrainHit(Vector3.new(cx + ox, BOTTOM, cz + oz), Vector3.new(0, TOP - BOTTOM, 0))
						local b = up and up.Position.Y or BOTTOM
						if not bottom or b < bottom then bottom = b end
					end
				end
			end
			local found = top ~= nil
			probed[key] = found
			if found then table.insert(columns, { cx = cx, cz = cz, top = top, bottom = bottom }) end
			breathe(("finding terrain (%d columns)"):format(#columns))
			return found
		end

		-- seeds: a sparse grid over the whole world (catches far-away islands), plus the area
		-- around the origin and the camera
		local queue = {}
		local function seed(cx, cz)
			cx, cz = cx - cx % CHUNK, cz - cz % CHUNK
			if probe(cx, cz) then table.insert(queue, { cx, cz }) end
		end
		for x = -LIMIT, LIMIT - 1, 512 do
			for z = -LIMIT, LIMIT - 1, 512 do
				-- one ray per sparse cell, then probe the column it lands in
				local hit = terrainHit(Vector3.new(x + 256, TOP, z + 256), Vector3.new(0, BOTTOM - TOP, 0))
				if hit then seed(math.floor(hit.Position.X), math.floor(hit.Position.Z)) end
				breathe("finding terrain")
			end
		end
		local centers = { Vector3.zero }
		local cam = workspace.CurrentCamera
		if cam then table.insert(centers, cam.CFrame.Position) end
		for _, c in centers do
			for dx = -512, 511, CHUNK do
				for dz = -512, 511, CHUNK do seed(math.floor(c.X) + dx, math.floor(c.Z) + dz) end
			end
		end
		-- flood outward: every column with terrain probes its 8 neighbours, until the edges are empty
		while #queue > 0 do
			local cell = table.remove(queue)
			for dx = -CHUNK, CHUNK, CHUNK do
				for dz = -CHUNK, CHUNK, CHUNK do
					local nx, nz = cell[1] + dx, cell[2] + dz
					if math.abs(nx) < LIMIT and math.abs(nz) < LIMIT and probed[nx .. "," .. nz] == nil then
						if probe(nx, nz) then table.insert(queue, { nx, nz }) end
					end
				end
			end
		end

		-- read the voxels, run-length encoded straight into a buffer
		local out = buffer.create(1024)
		local cursor = 4
		local function ensure(n)
			local need = cursor + n
			local size = buffer.len(out)
			if need <= size then return end
			while size < need do size *= 2 end
			local bigger = buffer.create(size)
			buffer.copy(bigger, 0, out, 0, cursor)
			out = bigger
		end
		local chunkCount, cells, fails, lastErr = 0, 0, 0, nil
		local total, done = 0, 0
		for _, col in columns do total += math.floor((col.top - col.bottom) / CHUNK) + 2 end

		for _, col in columns do
			local y0 = math.floor(col.bottom / CHUNK) * CHUNK - CHUNK
			local y1 = math.floor(col.top / CHUNK) * CHUNK + CHUNK
			for cy = y0, y1 - 1, CHUNK do
				done += 1
				breathe(("saving terrain %d%%"):format(math.floor(math.min(done / total, 1) * 100)))
				local region = Region3.new(Vector3.new(col.cx, cy, col.cz), Vector3.new(col.cx + CHUNK, cy + CHUNK, col.cz + CHUNK)):ExpandToGrid(RES)
				local ok, mats, occs = pcall(function() return terrain:ReadVoxels(region, RES) end)
				if not ok then
					fails += 1
					lastErr = mats
					continue
				end
				local size = mats.Size
				-- header now, body length patched in after
				ensure(19)
				local headerAt = cursor
				buffer.writei32(out, cursor, col.cx)
				buffer.writei32(out, cursor + 4, cy)
				buffer.writei32(out, cursor + 8, col.cz)
				buffer.writeu8(out, cursor + 12, size.X)
				buffer.writeu8(out, cursor + 13, size.Y)
				buffer.writeu8(out, cursor + 14, size.Z)
				cursor += 19
				local bodyStart = cursor
				local any = false
				local lastM, lastO, run = -1, -1, 0
				local function flush()
					if run == 0 then return end
					ensure(5)
					buffer.writeu16(out, cursor, lastM)
					buffer.writeu8(out, cursor + 2, lastO)
					buffer.writeu16(out, cursor + 3, run)
					cursor += 5
				end
				for x = 1, size.X do
					local mx, ox = mats[x], occs[x]
					for y = 1, size.Y do
						local my, oy = mx[y], ox[y]
						for z = 1, size.Z do
							local m = my[z]
							local o = math.floor(oy[z] * 255 + 0.5)
							if m == Enum.Material.Air then o = 0 end
							local mv = 0
							if o > 0 then
								any = true
								cells += 1
								mv = m.Value
							end
							if mv == lastM and o == lastO and run < 65535 then
								run += 1
							else
								flush()
								lastM, lastO, run = mv, o, 1
							end
						end
					end
				end
				flush()
				if any then
					buffer.writeu32(out, headerAt + 15, cursor - bodyStart)
					chunkCount += 1
				else
					cursor = headerAt -- all air: drop the chunk
				end
			end
		end
		buffer.writeu32(out, 0, chunkCount)
		if fails > 0 then warn(("[kUSI] ReadVoxels failed on %d chunks: %s"):format(fails, tostring(lastErr))) end
		return buffer.readstring(out, 0, cursor), chunkCount, cells
	end
	local REBUILD_SOURCE = [==[
-- kUSI terrain backup. Rebuild it from the command bar:
--     require(game.ReplicatedStorage.kUSI_Terrain)()
local DATA = [=[__KUSI_DATA__]=]

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function decode(s)
	local map = {}
	for i = 1, 64 do map[B64:byte(i)] = i - 1 end
	local out, bits, n = buffer.create(#s * 3 // 4 + 3), 0, 0
	local len, acc = 0, 0
	for i = 1, #s do
		local v = map[s:byte(i)]
		if v then
			acc = acc * 64 + v
			bits += 6
			if bits >= 8 then
				bits -= 8
				local byte = acc // (2 ^ bits)
				acc -= byte * (2 ^ bits)
				buffer.writeu8(out, len, byte)
				len += 1
			end
		end
	end
	return buffer.readstring(out, 0, len)
end

return function()
	local data = decode(DATA)
	local terrain = workspace.Terrain
	local materials = {}
	for _, m in Enum.Material:GetEnumItems() do materials[m.Value] = m end
	local count, pos = string.unpack("<I4", data, 1)
	for c = 1, count do
		local cx, cy, cz, sx, sy, sz, bodyLen
		cx, cy, cz, sx, sy, sz, bodyLen, pos = string.unpack("<iiiBBBI4", data, pos)
		local stop = pos + bodyLen
		local mats, occs = {}, {}
		for x = 1, sx do
			mats[x], occs[x] = {}, {}
			for y = 1, sy do mats[x][y], occs[x][y] = {}, {} end
		end
		local x, y, z = 1, 1, 1
		while pos < stop do
			local mv, o, run
			mv, o, run, pos = string.unpack("<I2BI2", data, pos)
			local m = o > 0 and materials[mv] or Enum.Material.Air
			for _ = 1, run do
				mats[x][y][z], occs[x][y][z] = m, o / 255
				z += 1
				if z > sz then z = 1 y += 1 if y > sy then y = 1 x += 1 end end
			end
		end
		local region = Region3.new(Vector3.new(cx, cy, cz), Vector3.new(cx + sx * 4, cy + sy * 4, cz + sz * 4)):ExpandToGrid(4)
		terrain:WriteVoxels(region, 4, mats, occs)
		if c % 32 == 0 then task.wait() end
	end
	print(("[kUSI] terrain rebuilt: %d chunks"):format(count))
end
]==]

	local function write(obj)
		local ref = refs[obj]
		if not ref then return end
		written += 1
		if written % OPTIONS.YieldEvery == 0 then
			status(("saving %d / %d"):format(written, count))
			task.wait()
		end
		table.insert(out, ('<Item class="%s" referent="%s"><Properties>'):format(obj.ClassName, ref))
		local isScript = obj:IsA("LuaSourceContainer")
		local isTerrain = obj:IsA("Terrain")
		if isTerrain then
			-- the real voxel data when the executor can read it (like other executors' savers)
			local grid = readTerrainBlob(obj, "SmoothGrid")
			if grid then
				terrainGridIsReal = true
				table.insert(out, T("BinaryString", "SmoothGrid", base64(grid)))
				local physics = readTerrainBlob(obj, "PhysicsGrid")
				if physics then table.insert(out, T("BinaryString", "PhysicsGrid", base64(physics))) end
			end
			local colors = readTerrainBlob(obj, "MaterialColors") or materialColorsBlob(obj)
			table.insert(out, T("BinaryString", "MaterialColors", base64(colors)))
		end
		for _, p in propsOf(obj.ClassName) do
			if ignoreProp[p.name] then continue end
			if isTerrain and (p.name == "SmoothGrid" or p.name == "PhysicsGrid" or p.name == "MaterialColors") then continue end
			if scriptsOnly and not isScript and p.name ~= "Name" then continue end
			local ok, v
			if p.name == "Source" and isScript then ok, v = true, scriptSource(obj)
			else ok, v = read(obj, p) end
			if ok then
				local okE, enc = pcall(encode, p, v)
				if okE and enc then table.insert(out, enc) props += 1
				else
					if not okE then skip(p.vt .. "!") end
					local key = obj.ClassName .. "." .. p.name
					local e = leftOut[key]
					if not e then e = { n = 0, want = p.vt, got = typeof(v) } leftOut[key] = e end
					e.n += 1
				end
			end
		end
		local tags = CollectionService:GetTags(obj)
		if #tags > 0 then table.insert(out, T("BinaryString", "Tags", base64(table.concat(tags, "\0")))) end
		local okAt, attrs = pcall(attributesBlob, obj)
		if okAt and attrs then table.insert(out, T("BinaryString", "AttributesSerialize", base64(attrs))) end
		table.insert(out, "</Properties>")
		for _, child in obj:GetChildren() do write(child) end
		-- keyed by class: a service can come back as a different reference than the one we looked up
		if obj.Parent == game then
			for _, extra in extraChildren[obj.ClassName] or {} do table.insert(out, extra) end
			extraChildren[obj.ClassName] = nil
		end
		table.insert(out, "</Item>")
	end
	local function folder(name, items)
		table.insert(out, ('<Item class="Folder" referent="RBX%s"><Properties>%s</Properties>'):format(HttpService:GenerateGUID(false):gsub("-", ""), T("string", "Name", name)))
		for _, obj in items do write(obj) end
		table.insert(out, "</Item>")
	end
	-- terrain backup module (when the real grid couldn't be read, or always if asked)
	local terrainNote = nil
	if isPlace and OPTIONS.SaveTerrain and OPTIONS.TerrainBackup ~= "never"
		and (OPTIONS.TerrainBackup == "always" or not readTerrainBlob(workspace.Terrain, "SmoothGrid")) then
		local okT, blob, chunkCount, cells = pcall(captureVoxels, workspace.Terrain)
		if okT and chunkCount > 0 then
			-- plain splice (no :format, the rebuild code has % signs of its own)
			local at = REBUILD_SOURCE:find("__KUSI_DATA__", 1, true)
			local encoded = base64big(blob)
			local source = REBUILD_SOURCE:sub(1, at - 1) .. encoded .. REBUILD_SOURCE:sub(at + #"__KUSI_DATA__")
			extraChildren.ReplicatedStorage = extraChildren.ReplicatedStorage or {}
			local guid = (HttpService:GenerateGUID(false):gsub("-", ""))
			table.insert(extraChildren.ReplicatedStorage, '<Item class="ModuleScript" referent="RBX' .. guid .. '"><Properties>'
				.. T("string", "Name", "kUSI_Terrain") .. '<ProtectedString name="Source">' .. cdata(source) .. "</ProtectedString></Properties></Item>")
			terrainNote = ("terrain backup: %d chunks, %d filled voxels → run require(game.ReplicatedStorage.kUSI_Terrain)() in Studio"):format(chunkCount, cells)
		elseif not okT then
			warn("[kUSI] terrain backup failed: " .. tostring(blob))
		else
			warn(("[kUSI] terrain backup found no loaded terrain (Y %d to %d)"):format(OPTIONS.TerrainMinY, OPTIONS.TerrainMaxY))
		end
	elseif isPlace and OPTIONS.SaveTerrain and OPTIONS.TerrainBackup == "auto" then
		print("[kUSI] terrain: the real SmoothGrid was readable, no backup needed")
	end

	for _, r in roots do write(r) end
	for className, extras in extraChildren do
		-- its service wasn't saved: give it one so the module still lands there
		table.insert(out, ('<Item class="%s" referent="RBX%s"><Properties></Properties>'):format(className, HttpService:GenerateGUID(false):gsub("-", "")))
		for _, extra in extras do table.insert(out, extra) end
		table.insert(out, "</Item>")
	end
	for _, f in extraFolders do folder(f.name, f.items) end


	if OPTIONS.ReadMe and isPlace then
		local exec = select(1, pcall(identifyexecutor)) and identifyexecutor() or "Unknown"
		table.insert(out, ('<Item class="Script" referent="RBX%s"><Properties>%s%s%s</Properties></Item>'):format(
			HttpService:GenerateGUID(false):gsub("-", ""), T("string", "Name", "README"), T("bool", "Disabled", "true"),
			T("ProtectedString", "Source", cdata(("--[[\n\tSaved with kUSI on %s\n\tPlace %d, %d instances\n\tScripts are decompiled: they may not match the originals.\n]]"):format(tostring(exec), game.PlaceId, count)))))
	end
	table.insert(out, "</roblox>")
	local xml = table.concat(out)

	------------------------------------------------ structure check
	local opens = select(2, xml:gsub("<Item ", ""))
	local closes = select(2, xml:gsub("</Item>", ""))
	assert(opens == closes, ("[kUSI] broken structure: %d <Item> vs %d </Item>"):format(opens, closes))
	assert(utf8.len(xml) ~= nil, "[kUSI] the file has invalid UTF-8")

	------------------------------------------------ output
	local ext = isPlace and ".rbxlx" or ".rbxmx"
	local path = OPTIONS.FilePath or (isPlace and ("place_" .. game.PlaceId) or (target.Name:gsub("[^%w%-_ ]", "_")))
	if not path:match("%.rbx[ml]x$") then path ..= ext end
	local savedTo = path
	if type(OPTIONS.Callback) == "function" then
		OPTIONS.Callback(xml)
		savedTo = "callback"
	elseif writefile then
		writefile(path, xml)
		if OPTIONS.CopyToClipboard and setclipboard then pcall(setclipboard, xml) end
	else
		-- nowhere to write: give the text back (and copy it if we can) so it can be pasted into a file
		savedTo = nil
		if setclipboard then pcall(setclipboard, xml) end
	end
	status(("done: %d instances, %d scripts decompiled"):format(written, decompiled))
	done()

	local list = {}
	for k, c in skipped do table.insert(list, ("%s ×%d"):format(k, c)) end
	table.sort(list)
	print(("[kUSI] %s: %d instances, %d properties, %d scripts decompiled (%.1f KB) in %.2f s")
		:format(savedTo or "returned as text", written, props, decompiled, #xml / 1024, os.clock() - START))
	if not savedTo then
		print(("[kUSI] no writefile here: saveinstance returned the file text%s. Paste it into a file named %s and open it in Studio.")
			:format(setclipboard and " and copied it to the clipboard" or "", path))
	end
	if terrainNote then print("[kUSI] " .. terrainNote) end
	if terrainGridIsReal then print("[kUSI] terrain saved from the real SmoothGrid") end
	if #list > 0 then print("[kUSI] values left out (Studio uses defaults): " .. table.concat(list, ", ")) end
	for why, n in decompileFails do warn(("[kUSI] decompile failed ×%d: %s"):format(n, why)) end
	if OPTIONS.Debug then
		local rows = {}
		for key, e in leftOut do table.insert(rows, ("   %s ×%d (wants %s, got %s)"):format(key, e.n, e.want, e.got)) end
		table.sort(rows)
		print("[kUSI] left-out properties:\n" .. table.concat(rows, "\n"))
	end
	-- written: the path (like before). Not written: the file text itself
	if savedTo == nil then return xml end
	return path
end

genv.saveinstance_kusi = saveinstance
return saveinstance
