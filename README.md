# kSSI — kAPI Save Instance

A full **saveinstance** written in plain Luau, using only standard executor globals.
Save a whole game as a `.rbxlx`, or any instance as a `.rbxmx`, and it opens cleanly in Roblox Studio.

Made for and tested on **[kAPI](#about-kapi)**. It only needs common executor functions, so it works on other executors too.

---

## Quick start

```lua
local config = {
    ["Debug"] = false,
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

saveinstance(game,config)               -- the whole place → place_<PlaceId>.rbxlx
saveinstance(workspace.MyModel)  -- one instance  → MyModel.rbxmx
```

With options:

```lua
saveinstance(game, {
	noscripts = true,
	NilInstances = true,
})
```

The USSI-style table call works too:

```lua
saveinstance({ Object = workspace.MyModel, mode = "scripts" })
```

After it loads once, it's also available as the global `saveinstance_kssi`.

---

## What gets saved

| You pass | You get |
|---|---|
| `game` | A **place file** (`.rbxlx`) with the game's services (depends on `mode`) |
| Any other instance | A **model file** (`.rbxmx`) with that instance and everything under it |

---

## Options

| Option | Default | What it does |
|---|---|---|
| `mode` | `"optimized"` | `"optimized"` saves the usual services. `"full"` saves everything under `game`. `"scripts"` keeps the tree but only writes scripts (and names). |
| `noscripts` | `false` | Don't decompile scripts. |
| `Decompile` | `true` | Decompile scripts with the executor's `decompile`. |
| `DecompileIgnore` | `{}` | Instances or class names to skip decompiling. |
| `IgnoreList` | `{}` | Instances or class names to leave out completely. |
| `IgnoreProperties` | `{}` | Property names to never write. |
| `IgnoreNotArchivable` | `true` | Skip instances with `Archivable = false`. |
| `NilInstances` | `false` | Save `getnilinstances()` into a **Nil Instances** folder. |
| `RemovePlayerCharacters` | `true` | Leave player characters out. |
| `SavePlayers` | `false` | Save the Players service. |
| `IsolateLocalPlayer` | `false` | Save your PlayerGui, Backpack and PlayerScripts into a **LocalPlayer** folder. |
| `ExtraInstances` | `{}` | More instances to save alongside the main one. |
| `FilePath` | auto | Output file name. The extension is added if missing. |
| `SaveBytecode` | `false` | Add each script's bytecode (base64) under its source. |
| `ShowStatus` | `true` | Show a progress bar at the top of the screen. |
| `Callback` | `nil` | `function(xml)`: get the file text instead of writing it. |
| `ReadMe` | `true` | Add a disabled **README** script with save info. |
| `Debug` | `false` | Print every property that couldn't be written, with the type it got. |
| `YieldEvery` | `400` | Instances per frame (lower = smoother, slower). |

---

## Why the files don't corrupt

- **Two passes.** Every instance gets its referent before anything is written, so `Ref` properties (`PrimaryPart`, `Part0`, ...) never point at something missing from the file.
- **Right tag for every type.** It reads the live Roblox API dump and writes each property with the tag its type needs: `OptionalCoordinateFrame`, `Color3uint8`, `Content` vs `ContentId`, `token`, `int64`, and so on.
- **Only loadable properties.** Only properties Roblox can both save and load back get written.
- **No duplicate content.** When a property has both an old and a new `Content` version (`Image` / `ImageContent`, `SoundId` / `AudioContent`, ...), only one is written.
- **Clean text.** Strings are cleaned to valid UTF-8 without control characters, and scripts go in CDATA.
- **Attributes and tags** are written in Roblox's binary formats.
- **Self-check.** The finished file is checked (balanced items, valid UTF-8) before it's saved.

---

## What it needs

Every global is looked up once, under any of its common names, with a fallback when it's missing:

| Needed | Optional (better results) |
|---|---|
| `writefile` | `decompile`, `gethiddenproperty`, `isscriptable`, `getnilinstances`, `getscriptbytecode`, `crypt.base64encode`, `gethui`, `protectgui`, `request` |

Without `crypt.base64encode`, a built-in Luau base64 is used. If `writefile` is missing, kSSI stops with a clear error.

---

## Credits
- Inspired by [UniversalSynSaveInstance](https://github.com/luau/UniversalSynSaveInstance)
- API dump from [MaximumADHD/Roblox-Client-Tracker](https://github.com/MaximumADHD/Roblox-Client-Tracker)
