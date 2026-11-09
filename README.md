# Lucida for Roblox

## Install

From GitHub, [lucidaanalytics/lucida-roblox](https://github.com/lucidaanalytics/lucida-roblox), release `v0.1.0`: download `lucida-roblox-v0.1.0.zip` from the [release page](https://github.com/lucidaanalytics/lucida-roblox/releases/tag/v0.1.0), unzip it and run `rojo build -o Lucida.rbxm` (its `default.project.json` maps `src` to the `Lucida` module tree), then insert the model into `ServerScriptService`.


Tests: `cd sdks/roblox && lune run tests/run` runs `src/*.spec.luau` under [Lune](https://lune-org.github.io/docs)
with the ModuleScripts loaded behind fake `script` instances and fake `game`/HttpService/Players. The same specs
run in Studio with TestEZ (`TestEZ.TestBootstrap:run({ ServerScriptService.Lucida })`) after `rojo build`.

Server-side ModuleScript (Roblox allows HttpService on the server only). Enable **Allow HTTP Requests** in Game
Settings > Security.

```lua
local Lucida = require(game.ServerScriptService.Lucida)
local lucida = Lucida.new({ apiKey = "lc_pk_...", consent = "opt_in" })
lucida:start() -- $session_start / $session_end per player, flush loop, final flush in BindToClose

game.Players.PlayerAdded:Connect(function(player)
    -- after your consent prompt (opt_in mode: nothing is captured for a player before this)
    lucida:setConsent(player, true)
    lucida:capture(player, "joined_lobby", { lobby = "main" })
    if lucida:isFeatureEnabled(player, "new-shop") then end
end)
```

- Each player is the distinct id `roblox:<UserId>`. `identify(player, set, setOnce)` sets person properties.
- Events go to `POST /v1/batch` (20 events or 5 s, at most 100 per request) with a uuid each for dedupe; 408,
  429, 5xx and network errors retry with backoff (5 tries). `$lc_*` properties are dropped.
- Consent is per player and held in memory only. The SDK never writes a DataStore, so nothing is stored before
  (or without) consent; a returning player is asked again. Events queued when the server stops are flushed in
  `BindToClose`, within Roblox's 30 s shutdown budget.
- Flags: `reloadFlags(player)` (also on join) calls `POST /v1/flags`; flag values ride on events as `$feature/<key>`.

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.
