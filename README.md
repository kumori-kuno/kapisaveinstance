# kapisaveinstance
save isntace for kAPI

```luau
config = {
	["mode"] = "optimized",
	["noscripts"] = false,
	["Decompile"] = true,
	["DecompileIgnore"] = {},
	["NilInstances"] = true,
	["IgnoreList"] = {},
	["IgnoreProperties"] = {},
	["IgnoreNotArchivable"] = false,
	["RemovePlayerCharacters"] = false,
	["SavePlayers"] = true,
	["IsolateLocalPlayer"] = false,
	["ExtraInstances"] = {},
	["FilePath"] = nil,
	["SaveBytecode"] = false,
	["ShowStatus"] = true,
	["Callback"] = nil,
	["ReadMe"] = true,
	["YieldEvery"] = 400,
}
local saveinstance = loadstring(game:HttpGet("https://raw.githubusercontent.com/kumori-kuno/kapisaveinstance/refs/heads/main/main.luau"))()
saveinstance(game,config)
```
