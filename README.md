# kapisaveinstance
save isntace for kAPI

```luau
config = {
	["mode"] = "optimized",
	["noscripts"] = true,
	["Decompile"] = true,
	["DecompileIgnore"] = {},
	["NilInstances"] = false,
	["IgnoreList"] = {},
	["IgnoreProperties"] = {},
	["IgnoreNotArchivable"] = true,
	["RemovePlayerCharacters"] = true,
	["SavePlayers"] = false,
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
