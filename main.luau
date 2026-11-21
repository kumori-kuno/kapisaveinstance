--[[
	kSSI — kAPI's take on UniversalSynSaveInstance, built only on executor globals.

	local saveinstance = loadstring(readfile("kSSI.lua"))()  -- or paste and call directly
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
local httpget           = exists("request", "function") and function(url)
	local r = exists("request", "function")({ Url = url, Method = "GET" })
	return r.Body
end or function(url) return game:HttpGet(url, true) end

if not writefile then error("[kSSI] this executor has no writefile", 0) end
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

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local DEFAULTS = {
	mode = "optimized", noscripts = false, Decompile = true, DecompileIgnore = {},
	IgnoreList = {}, IgnoreProperties = {}, IgnoreNotArchivable = true, NilInstances = false,
	RemovePlayerCharacters = true, SavePlayers = false, IsolateLocalPlayer = false,
	ExtraInstances = {}, FilePath = nil, SaveBytecode = false, ShowStatus = true,
	Callback = nil, ReadMe = true, YieldEvery = 400, Debug = false,
}

--------------------------------------------------------------- API dump (cached between calls)
local classes
local function loadDump()
	if classes then return end
	local dump = HttpService:JSONDecode(httpget("https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Full-API-Dump.json"))
	classes = {}
	for _, c in dump.Classes do classes[c.Name] = c end
end

local function tagged(list, t)
	for _, x in list or {} do if x == t then return true end end
	return false
end

-- properties that load back, with their serialized name (xml names win over script names)
local SKIP = { Parent = true, Archivable = true, UniqueId = true, HistoryId = true, ScriptGuid = true, Capabilities = true, DefinesCapabilities = true, SourceAssetId = true }
local propCache = {}
local function propsOf(className)
	local cached = propCache[className]
	if cached then return cached end
	local list, seen, class = {}, {}, classes[className]
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
		if not (p.vt == "ContentId" and twinOf(p.name)) then table.insert(final, p) end
	end
	list = final
	propCache[className] = list
	return list
end
local function isCreatable(className)
	local c = classes[className]
	return c ~= nil and not tagged(c.Tags, "NotCreatable")
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
	gui.Name = "kSSI"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1e6
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 26)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = 16
	label.Text = "kSSI: starting"
	label.Parent = gui
	if protectgui then pcall(protectgui, gui) end
	local parent = gethui and select(2, pcall(gethui))
	if typeof(parent) ~= "Instance" and type(parent) ~= "userdata" then parent = game:GetService("CoreGui") end
	if not pcall(function() gui.Parent = parent end) then gui.Parent = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui") end
	return function(text) label.Text = "kSSI: " .. text end, function() task.delay(2, gui.Destroy, gui) end
end

--------------------------------------------------------------- the saver
local PLACE_SERVICES = { "Workspace", "Lighting", "ReplicatedFirst", "ReplicatedStorage", "StarterGui", "StarterPack",
	"StarterPlayer", "SoundService", "Teams", "Chat", "TextChatService", "MaterialService", "LocalizationService" }

local function saveinstance(target, options)
	local START = os.clock()
	-- USSI table style: saveinstance({ Object = x, ... })
	if type(target) == "table" and options == nil then
		options, target = target, target.Object or target.object or game
	end
	local OPTIONS = table.clone(DEFAULTS)
	for k, v in options or {} do OPTIONS[k] = v end
	if OPTIONS.noscripts then OPTIONS.Decompile = false end
	if typeof(target) ~= "Instance" and type(target) ~= "userdata" then error("[kSSI] expected an Instance to save", 2) end

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
		return false
	end
	local decompiled = 0
	local decompileFails = {}
	local function scriptSource(obj)
		local src
		if OPTIONS.noscripts then
			src = "-- kSSI: noscripts is on"
		elseif decompileIgnore[obj] or decompileIgnore[obj.ClassName] then
			src = "-- kSSI: in DecompileIgnore"
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
					local why = ok and ("returned " .. typeof(out)) or tostring(out):sub(1, 120)
					decompileFails[why] = (decompileFails[why] or 0) + 1
				end
			end
		end
		src = src or "-- kSSI: couldn't decompile this script"
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
		if obj:IsA("Terrain") then return false end
		if not isRoot then
			if obj:IsA("Camera") and obj == workspace.CurrentCamera then return true end
			if not isCreatable(className) and not obj:IsA("LuaSourceContainer") then return false end
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
		for _, p in propsOf(obj.ClassName) do
			if ignoreProp[p.name] then continue end
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
		table.insert(out, "</Item>")
	end
	local function folder(name, items)
		table.insert(out, ('<Item class="Folder" referent="RBX%s"><Properties>%s</Properties>'):format(HttpService:GenerateGUID(false):gsub("-", ""), T("string", "Name", name)))
		for _, obj in items do write(obj) end
		table.insert(out, "</Item>")
	end
	for _, r in roots do write(r) end
	for _, f in extraFolders do folder(f.name, f.items) end
	if OPTIONS.ReadMe and isPlace then
		local exec = select(1, pcall(identifyexecutor)) and identifyexecutor() or "Unknown"
		table.insert(out, ('<Item class="Script" referent="RBX%s"><Properties>%s%s%s</Properties></Item>'):format(
			HttpService:GenerateGUID(false):gsub("-", ""), T("string", "Name", "README"), T("bool", "Disabled", "true"),
			T("ProtectedString", "Source", cdata(("--[[\n\tSaved with kSSI on %s\n\tPlace %d, %d instances\n\tScripts are decompiled: they may not match the originals.\n]]"):format(tostring(exec), game.PlaceId, count)))))
	end
	table.insert(out, "</roblox>")
	local xml = table.concat(out)

	------------------------------------------------ structure check
	local opens = select(2, xml:gsub("<Item ", ""))
	local closes = select(2, xml:gsub("</Item>", ""))
	assert(opens == closes, ("[kSSI] broken structure: %d <Item> vs %d </Item>"):format(opens, closes))
	assert(utf8.len(xml) ~= nil, "[kSSI] the file has invalid UTF-8")

	------------------------------------------------ output
	local ext = isPlace and ".rbxlx" or ".rbxmx"
	local path = OPTIONS.FilePath or (isPlace and ("place_" .. game.PlaceId) or (target.Name:gsub("[^%w%-_ ]", "_")))
	if not path:match("%.rbx[ml]x$") then path ..= ext end
	if type(OPTIONS.Callback) == "function" then
		OPTIONS.Callback(xml)
	else
		writefile(path, xml)
	end
	status(("done: %d instances, %d scripts decompiled"):format(written, decompiled))
	done()

	local list = {}
	for k, c in skipped do table.insert(list, ("%s ×%d"):format(k, c)) end
	table.sort(list)
	print(("[kSSI] %s: %d instances, %d properties, %d scripts decompiled (%.1f KB) in %.2f s")
		:format(OPTIONS.Callback and "callback" or path, written, props, decompiled, #xml / 1024, os.clock() - START))
	if #list > 0 then print("[kSSI] values left out (Studio uses defaults): " .. table.concat(list, ", ")) end
	for why, n in decompileFails do warn(("[kSSI] decompile failed ×%d: %s"):format(n, why)) end
	if OPTIONS.Debug then
		local rows = {}
		for key, e in leftOut do table.insert(rows, ("   %s ×%d (wants %s, got %s)"):format(key, e.n, e.want, e.got)) end
		table.sort(rows)
		print("[kSSI] left-out properties:\n" .. table.concat(rows, "\n"))
	end
	return path
end

genv.saveinstance_kssi = saveinstance
return saveinstance
