--[[
================================================================================
  BALL TWEAKS  -  Gravity / Material / Ball-Colour controller + Ball Waypoints
  for  "Getting Over It"-style ball+axe game (playerModels architecture)

  UI: Rayfield Gen2   (https://docs.sirius.menu/rayfield-gen2)
      The window is built in code by the library that is fetched on startup.
      If that fetch fails you still get the hotkeys, the notifications (printed
      to the console) and every function through _G.__BALLTWEAKS.

  Built from the game's instance tree:
      workspace.playerModels[<YourName>].ball   (UnionOperation, physics driven)
      workspace.playerModels[<YourName>].axe    (UnionOperation)
      ball.BodyPosition / ball.BodyGyro / axe.BodyPosition / axe.BodyGyro
      workspace.Gravity                          -> world gravity
      workspace.map.safePoints.01..NN            -> the game's own checkpoints
      workspace.map.splits.01..NN                -> the speedrun split gates
      <map>.FINISH.Zone                          -> the pad that ends the run

  WHAT IT DOES
    * Gravity switch   - writes workspace.Gravity every 0.6 s while ON
    * Material switch  - writes ball.Material (and axe.Material if you tick it)
    * Colour switch    - writes ball.Color    (and axe.Color    if you tick it)
    While a switch is OFF the *original* (vanilla) value is re-applied on the
    same 0.6 s tick, so nothing can silently stay modified. Toggling ON again
    stops the "disabled" writes and starts the "enabled" writes.
    Values survive respawns / level resets / R-resets because the parts are
    re-resolved and rewritten on every tick.

  BALL WAYPOINTS  (section 5d, "Waypoints" tab)
    * Save the ball's position and jump back to it (F5 / F6), with the axe and
      the movers moved together so the jump sticks.
    * NOTHING is drawn in the world by default. The map's own checkpoints are a
      LIST in the window (name + kind + distance), never a marker: a level can
      hold dozens of them and a sphere on each one buries the level. Markers for
      your own waypoints / crumbs are two switches, both off by default.
    * The FINISH pad is listed as "info only" and refuses to be a jump target
      unless you turn that on: landing in its zone is what submits a run time.
    * A trail: crumbs recorded while you climb, F7 undoes the last fall.
      Optional watchdog: if you drop more than N studs, jump back by itself.
    * The map's own checkpoints, read straight out of the level: safePoints
      (the game's), the split gates, the FINISH pad and the elevator. Jump to
      any of them, or to the nearest one.

  GAME HACKS  ("Hacks" tab, both run every frame - not on the 0.6 s tick)
    * Speed hack       - ball + axe travel multiplier, 0.1x - 10x (1x = off).
                         Below 1x it is slow motion (0.1 / 0.25 / 0.5 / 0.75 /
                         0.99 presets), above it is a speed up.
                         Extra displacement along their own motion, so the
                         velocity is never inflated and nothing runs away.
    * Infinite axe reach - pushes the axe target the game computes from your
                         aim further out along the same direction, 1x - 50x
                         ("inf"), and grows the axe hitbox with it. 1x = off.
    They stay out of the way while the TAS is replaying a tape, and stay ON
    while the TAS is recording (so the tape contains them).

  ANTI-AFK  (section 5e, "Hacks" tab, off by default)
    Roblox fires LocalPlayer.Idled before it kicks you for being idle; one
    harmless input from there resets the timer (VirtualUser first, then the
    executor's keypress helper). If the executor allows neither, the script says
    so instead of pretending.

  CONFIG: BallTweaks/config.json, saved every 60 s (overwrite), loaded on run.
          The waypoints ride along in it (section 3b) - the trail does not.
          A waypoint also stores the level it was saved in, so a jump after a
          rejoin cannot silently mean a different place.

  EXECUTOR SAFETY (no fancy API used)
    game:GetService, game:HttpGet + loadstring (only to fetch Rayfield Gen2),
    RunService.Heartbeat / RenderStepped, UserInputService, Instance.new,
    Color3, Enum, CFrame, pcall.
    No hookfunction / getconnections / VirtualInputManager / mousemoverel /
    gethui / setfflag. Every Rayfield call is pcall-guarded, so a dead link or
    a build of the library without one element costs you that element, not the
    script.

  KEYS  (rebindable in the window; read by this script, not by the library, so
         they work even when the menu never loaded)
    RightShift  show / hide the window
    F5          save a waypoint where the ball is
    F6          jump the ball to the selected waypoint
    F7          back one crumb (or to the newest waypoint)
================================================================================
]]

--============================================================================
-- 0. RE-RUN GUARD
--============================================================================
do
	local old = _G.__BALLTWEAKS
	if type(old) == "table" and type(old.destroy) == "function" then
		pcall(old.destroy)
	end
end

--============================================================================
-- 1. SERVICES
--============================================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

-- Rayfield Gen2 (the window). Fetched up here so the whole file can see it:
-- section 6 builds the interface, section 9 decides what to say about it.
local loadstringFn = rawget(_G, "loadstring") or loadstring
local okRayfield, Rayfield = pcall(function()
	if type(loadstringFn) ~= "function" then
		error("this executor has no loadstring")
	end
	return loadstringFn(game:HttpGet("https://sirius.menu/gen2"))()
end)
local rayfieldError
if okRayfield and type(Rayfield) == "table" then
	rayfieldError = nil
else
	rayfieldError = tostring(Rayfield)
	Rayfield = nil
end

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	LocalPlayer = Players:GetPlayers()[1]
end

--============================================================================
-- 2. SMALL HELPERS
--============================================================================
local function clampNum(v, a, b)
	if v ~= v then return a end -- NaN guard
	if v < a then return a end
	if v > b then return b end
	return v
end

local function round(v, decimals)
	local m = 10 ^ (decimals or 0)
	return math.floor(v * m + 0.5) / m
end

local function toHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5))
end

local function fromHex(s)
	s = tostring(s or ""):gsub("#", "")
	if #s == 3 then
		s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
	end
	if #s ~= 6 or s:match("%X") == nil then return nil end
	local r = tonumber(s:sub(1, 2), 16)
	local g = tonumber(s:sub(3, 4), 16)
	local b = tonumber(s:sub(5, 6), 16)
	if not r or not g or not b then return nil end
	return Color3.fromRGB(r, g, b)
end

local function newInstance(class, props, parent)
	local inst = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			pcall(function() inst[k] = v end)
		end
	end
	if parent then inst.Parent = parent end
	return inst
end

--============================================================================
-- 2b. LOG + NOTIFICATIONS
--     notifyUser and logConsole are filled in by the UI section (6) - they are
--     declared here so the engine sections above the window can already use
--     them (a nil global would silently do nothing). Until then: print.
--============================================================================
local LOG_LINES, LOG_MAX = {}, 80
local notifyUser           -- assigned in section 6
local logConsole           -- the "Log" console handle, assigned in section 6
local configConsole        -- the "Config log" console handle, assigned in section 6
local refreshGameDropdown  -- the map-point dropdown, assigned in section 6

local function logLine(fmt, ...)
	local text
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		text = ok and formatted or tostring(fmt)
	else
		text = tostring(fmt)
	end
	LOG_LINES[#LOG_LINES + 1] = text
	while #LOG_LINES > LOG_MAX do table.remove(LOG_LINES, 1) end
	print("[BallTweaks] " .. text)
	if logConsole then pcall(function() logConsole:Append(text) end) end
	return text
end

-- the Config tab's own little console: what the autosave did, and when
local function configLine(fmt, ...)
	local text
	if select("#", ...) > 0 then
		local ok, formatted = pcall(string.format, fmt, ...)
		text = ok and formatted or tostring(fmt)
	else
		text = tostring(fmt)
	end
	if configConsole then pcall(function() configConsole:Append(text) end) end
	return text
end

--============================================================================
-- 3. STATE  (kept in _G so a re-run keeps your values)
--============================================================================
local DEFAULTS = {
	uiVisible   = true,
	minimized   = false,
	keyName     = "RightShift",
	-- config file behaviour
	autosave    = true,   -- write the config every autosaveInterval seconds
	autosaveInterval = 60,
	loadSwitches = true,  -- also restore the on/off state of the switches
	windowX     = 24,
	windowY     = 120,
	gravity     = 120,
	materialName= "Ice",
	r = 255, g = 60, b = 60,
	axeMaterial = false,
	axeColor    = false,
	enabled     = { gravity = false, material = false, color = false },
	interval    = 0.6,
	-- game hacks (see section 5c)
	speedHack     = false,  -- ball + axe travel multiplier, 1x = off
	speedHackMult = 2,
	reachOn       = false,  -- infinite axe reach
	reachMult     = 4,
	reachHitbox   = true,   -- grow the axe hitbox with the reach
	-- ball waypoints (see section 5d)
	wpSchema     = 2,       -- bumped when a default changed in a way old files must follow
	wpMarkers    = false,   -- markers are opt-in: the map is left clean by default
	wpLabels     = true,    -- with a label and the distance (only if markers are on)
	wpHotkeys    = true,    -- F5 / F6 / F7 do their thing
	wpPersist    = true,    -- keep the waypoints in the config file
	wpLift       = 3,       -- studs above the saved point the ball is put
	wpAssert     = true,    -- hold the spot for a moment after a jump
	wpAssertTime = 0.3,
	wpHold       = false,   -- ...or keep holding it until you switch this off
	wpMerge      = 6,       -- a save closer than this to the last one moves it
	wpLevelGuard = true,    -- refuse ways saved in another level
	allowFinishJump = false,-- the FINISH pad is what submits a time: off by default
	wpSaveKey    = "F5",
	wpJumpKey    = "F6",
	wpBackKey    = "F7",
	wpIndex      = 1,       -- selected waypoint
	gameIndex    = 1,       -- selected map point
	-- trail of crumbs while you climb
	trailOn      = false,
	trailSpacing = 25,      -- studs between crumbs
	trailMax     = 40,
	trailMarkers = false,   -- same: no spheres unless you ask for them
	trailAuto    = false,   -- jump back by itself after a fall (off: levels go down too)
	trailFall    = 60,      -- a fall deeper than this counts
	-- the map's own checkpoints (listed in the window, never drawn in the world)
	scanAuto     = true,    -- rescan when the level changes
	scanSplits   = false,   -- include the speedrun split gates
	-- keep the 20 minute idle kick away
	antiAfk      = false,
}

local S = _G.__BALLTWEAKS_STATE
-- "the state we found was already written by a build that knows the schema"
-- is read BEFORE the defaults below can fill the key in, because that is the
-- difference between "an old session" and "a session that already migrated".
local stateHadSchema = type(S) == "table" and tonumber(S.wpSchema) == 2
local staleState = false
if type(S) ~= "table" then
	S = {}
	for k, v in pairs(DEFAULTS) do S[k] = v end
	S.enabled = { gravity = false, material = false, color = false }
else
	staleState = not stateHadSchema -- an old build of this script wrote this state
	-- a re-run inside the same session (or a state from an older build of this
	-- script) must still get every key the current version expects
	for k, v in pairs(DEFAULTS) do
		if S[k] == nil then S[k] = v end
	end
	if type(S.enabled) ~= "table" then S.enabled = { gravity = false, material = false, color = false } end
	for _, key in ipairs({ "gravity", "material", "color" }) do
		if S.enabled[key] == nil then S.enabled[key] = false end
	end
end
-- One-time tidy-up for state written before the markers became opt-in: the old
-- build defaulted to a neon sphere on every point it could find, which is what
-- put markers all over the map. Anyone carrying that state follows the new
-- default once, then it is their own switch again.
if staleState then
	S.wpMarkers = false
	S.trailMarkers = false
	logLine("state from an older build: the world markers are switched off (turn them back on on the Waypoints tab)")
end
S.wpSchema = 2

-- the waypoint lists live in the state table so a re-run keeps them; they are
-- written to the config file too (see section 3b)
if type(S.waypoints) ~= "table" then S.waypoints = {} end
if type(S.trail) ~= "table" then S.trail = {} end
_G.__BALLTWEAKS_STATE = S

local VANILLA = _G.__BALLTWEAKS_VANILLA
if type(VANILLA) ~= "table" then
	VANILLA = {}
	_G.__BALLTWEAKS_VANILLA = VANILLA
end

--============================================================================
-- 3b. CONFIG FILE
--     Saved every autosaveInterval seconds (60 by default), always
--     overwriting the same file, and loaded again when the script is run.
--============================================================================
-- filled in further down, declared here so the config loader can validate
-- a saved material name against the real list
local MATERIAL_NAMES

local CONFIG_FOLDER = "BallTweaks"
local CONFIG_PATH = CONFIG_FOLDER .. "/config.json"

-- the executor's file functions are looked up on every call: some executors
-- inject them a little after the script starts
local function ioWrite()
	local fn = _G.writefile or writefile
	return type(fn) == "function" and fn or nil
end

local function ioRead()
	local fn = _G.readfile or readfile
	return type(fn) == "function" and fn or nil
end

local function ioIsFile()
	local fn = _G.isfile or isfile
	return type(fn) == "function" and fn or nil
end

local function ioMakeFolder()
	local fn = _G.makefolder or makefolder
	return type(fn) == "function" and fn or nil
end

local configStatus = "no save yet"
local configLoaded = false

local function configAvailable()
	return ioWrite() ~= nil and ioRead() ~= nil
end

local function configBlob()
	local payload = {
		version = 2, -- 1 -> 2: waypoint markers became opt-in, the FINISH guard arrived
		savedAt = os.time(),
		gravity = S.gravity,
		materialName = S.materialName,
		color = { S.r, S.g, S.b },
		axeMaterial = S.axeMaterial,
		axeColor = S.axeColor,
		interval = S.interval,
		keyName = S.keyName,
		windowX = S.windowX,
		windowY = S.windowY,
		antiAfk = S.antiAfk,
		speedHack = S.speedHack,
		speedHackMult = S.speedHackMult,
		reachOn = S.reachOn,
		reachMult = S.reachMult,
		reachHitbox = S.reachHitbox,
		enabled = {
			gravity = S.enabled.gravity,
			material = S.enabled.material,
			color = S.enabled.color,
		},
		-- waypoints: the whole point of them is that a fall on a later climb is
		-- cheap, so they have to survive a rejoin. The trail ('crumbs') does not:
		-- it belongs to the climb you are doing right now.
		wp = {
			markers = S.wpMarkers,
			labels = S.wpLabels,
			persist = S.wpPersist,
			lift = S.wpLift,
			assertOn = S.wpAssert,
			assertTime = S.wpAssertTime,
			merge = S.wpMerge,
			saveKey = S.wpSaveKey,
			jumpKey = S.wpJumpKey,
			backKey = S.wpBackKey,
			trailOn = S.trailOn,
			trailSpacing = S.trailSpacing,
			trailMax = S.trailMax,
			trailMarkers = S.trailMarkers,
			hold = S.wpHold,
			levelGuard = S.wpLevelGuard,
			allowFinish = S.allowFinishJump,
			schema = S.wpSchema,
			trailAuto = S.trailAuto,
			trailFall = S.trailFall,
			scanAuto = S.scanAuto,
			scanSplits = S.scanSplits,
		},
	}
	if S.wpPersist then
		local list = {}
		for _, entry in ipairs(S.waypoints) do
			list[#list + 1] = {
				x = round(entry.x, 2), y = round(entry.y, 2), z = round(entry.z, 2),
				name = tostring(entry.name or ""),
				level = entry.level and tostring(entry.level):sub(1, 24) or nil,
			}
		end
		payload.waypoints = list
	end
	return payload
end

local function saveConfig(reason)
	if not configAvailable() then
		configStatus = "no writefile on this executor - config not saved"
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false, configStatus
	end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(configBlob()) end)
	if not ok or type(encoded) ~= "string" then
		configStatus = "encode failed"
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false, configStatus
	end
	local makeFolder = ioMakeFolder()
	if makeFolder then pcall(function() makeFolder(CONFIG_FOLDER) end) end
	local writer = ioWrite()
	local wrote, err = pcall(function() writer(CONFIG_PATH, encoded) end)
	if not wrote then
		configStatus = "write failed: " .. tostring(err)
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false, configStatus
	end
	S.lastSaveTime = os.time()
	configStatus = string.format("saved %s (%s)", reason or "manual", os.date("%H:%M:%S"))
	configLine("%s  %s  %d waypoint(s)  %d bytes", os.date("%H:%M:%S"), tostring(reason or "manual"),
		#S.waypoints, #encoded)
	return true, configStatus
end

local function loadConfig()
	if not configAvailable() then
		configStatus = "no readfile on this executor - using defaults"
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false
	end
	local isFile = ioIsFile()
	if isFile then
		local ok, result = pcall(isFile, CONFIG_PATH)
		if not (ok and result) then
			configStatus = "no config file yet"
			configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
			return false
		end
	end
	local reader = ioRead()
	local ok, data = pcall(function() return reader(CONFIG_PATH) end)
	if not ok or type(data) ~= "string" or data == "" then
		configStatus = "read failed"
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false
	end
	local okDecode, cfg = pcall(function() return HttpService:JSONDecode(data) end)
	if not okDecode or type(cfg) ~= "table" then
		configStatus = "config file is corrupt"
		configLine("%s  %s", os.date("%H:%M:%S"), configStatus)
		return false
	end

	-- ---- validate every field before it touches the live state -----------
	local function num(value, fallback, low, high)
		if type(value) ~= "number" or value ~= value then return fallback end
		return clampNum(value, low, high)
	end

	S.gravity = num(cfg.gravity, S.gravity, -1000, 10000)
	S.interval = num(cfg.interval, S.interval, 0.1, 10)
	S.windowX = num(cfg.windowX, S.windowX, -5000, 5000)
	S.windowY = num(cfg.windowY, S.windowY, -5000, 5000)

	if type(cfg.materialName) == "string" then
		for _, name in ipairs(MATERIAL_NAMES) do
			if name == cfg.materialName then
				S.materialName = name
				break
			end
		end
	end
	if type(cfg.color) == "table" then
		S.r = math.floor(num(cfg.color[1], S.r, 0, 255))
		S.g = math.floor(num(cfg.color[2], S.g, 0, 255))
		S.b = math.floor(num(cfg.color[3], S.b, 0, 255))
	end
	-- game hacks
	if type(cfg.speedHack) == "boolean" then S.speedHack = cfg.speedHack end
	S.speedHackMult = num(cfg.speedHackMult, S.speedHackMult, 0.1, 10) -- same range as SPEED_HACK_MIN/MAX
	if type(cfg.reachOn) == "boolean" then S.reachOn = cfg.reachOn end
	S.reachMult = num(cfg.reachMult, S.reachMult, 1, 50)
	if type(cfg.reachHitbox) == "boolean" then S.reachHitbox = cfg.reachHitbox end
	if type(cfg.axeMaterial) == "boolean" then S.axeMaterial = cfg.axeMaterial end
	if type(cfg.axeColor) == "boolean" then S.axeColor = cfg.axeColor end
	if type(cfg.keyName) == "string" and cfg.keyName ~= "" then S.keyName = cfg.keyName end

	if S.loadSwitches and type(cfg.enabled) == "table" then
		S.enabled.gravity = cfg.enabled.gravity == true
		S.enabled.material = cfg.enabled.material == true
		S.enabled.color = cfg.enabled.color == true
	end

	-- ---- waypoint settings -------------------------------------------------
	if type(cfg.wp) == "table" then
		local wp = cfg.wp
		local function flag(key, value)
			if type(value) == "boolean" then S[key] = value end
		end
		-- a v1 file was written when markers defaulted to ON: following it would
		-- put the spheres back, so those two flags are skipped for that file (the
		-- state itself is migrated once, in section 3)
		if stateHadSchema or tonumber(cfg.version or 1) >= 2 then
			flag("wpMarkers", wp.markers)
		end
		flag("wpLabels", wp.labels)
		flag("wpPersist", wp.persist)
		flag("wpAssert", wp.assertOn)
		flag("trailOn", wp.trailOn)
		if stateHadSchema or tonumber(cfg.version or 1) >= 2 then
			flag("trailMarkers", wp.trailMarkers)
		end
		flag("trailAuto", wp.trailAuto)
		flag("scanAuto", wp.scanAuto)
		flag("scanSplits", wp.scanSplits)
		flag("wpHold", wp.hold)
		flag("wpLevelGuard", wp.levelGuard)
		flag("allowFinishJump", wp.allowFinish)
		flag("antiAfk", cfg.antiAfk)
		S.wpLift = num(wp.lift, S.wpLift, 0, 20)
		S.wpAssertTime = num(wp.assertTime, S.wpAssertTime, 0.05, 1.5)
		S.wpMerge = num(wp.merge, S.wpMerge, 0, 50)
		S.trailSpacing = num(wp.trailSpacing, S.trailSpacing, 5, 200)
		S.trailMax = math.floor(num(wp.trailMax, S.trailMax, 5, 120))
		S.trailFall = num(wp.trailFall, S.trailFall, 10, 300)
		for key, value in pairs({ saveKey = "wpSaveKey", jumpKey = "wpJumpKey", backKey = "wpBackKey" }) do
			local saved = wp[key]
			if type(saved) == "string" and saved ~= "" then
				local okKey = pcall(function() return Enum.KeyCode[saved] end)
				if okKey then S[value] = saved end
			end
		end
	end

	-- ---- the waypoints themselves -----------------------------------------
	if type(cfg.waypoints) == "table" then
		local list = {}
		for _, entry in ipairs(cfg.waypoints) do
			if type(entry) == "table" then
				local x = num(entry.x, nil, -100000, 100000)
				local y = num(entry.y, nil, -100000, 100000)
				local z = num(entry.z, nil, -100000, 100000)
				if x and y and z then
					local name = type(entry.name) == "string" and entry.name:sub(1, 32) or ""
					local level = type(entry.level) == "string" and entry.level:sub(1, 24) or nil
					list[#list + 1] = { x = x, y = y, z = z, name = name, level = level }
					if #list >= 50 then break end
				end
			end
		end
		S.waypoints = list
		S.wpIndex = math.floor(num(S.wpIndex, 1, 1, math.max(#list, 1)))
		-- a file from the build that put a sphere on every point it found is
		-- followed by the new default once, then it is the switch's own business
		if tonumber(cfg.version or 1) < 2 and not stateHadSchema then
			configLine("%s  old config (v%s) - world markers stay off, waypoints kept",
				os.date("%H:%M:%S"), tostring(cfg.version or 1))
		end
	end

	S.lastSaveTime = tonumber(cfg.savedAt) or nil
	configLoaded = true
	local stamp = ""
	if S.lastSaveTime then
		local okDate, text = pcall(os.date, "%H:%M:%S", S.lastSaveTime)
		if okDate and text then stamp = " from " .. tostring(text) end
	end
	configStatus = "loaded" .. stamp
	configLine("%s  loaded %d waypoint(s) from %s", os.date("%H:%M:%S"), #S.waypoints, CONFIG_PATH)
	return true
end

--============================================================================
-- 4. PART RESOLUTION  (re-resolved on every tick -> survives resets)
--============================================================================
local function getPlayerModel()
	local folder = workspace:FindFirstChild("playerModels")
	if not folder then return nil end
	return folder:FindFirstChild(LocalPlayer.Name)
end

local function resolveParts()
	local model = getPlayerModel()
	if not model then return nil, nil end
	return model:FindFirstChild("ball"), model:FindFirstChild("axe")
end

-- fallback scan: some levels swap the ball for a custom one
local function findBallFallback()
	local model = getPlayerModel()
	if not model then return nil end
	for _, d in ipairs(model:GetChildren()) do
		if d.Name:lower():find("ball") and d:IsA("BasePart") then
			return d
		end
	end
	return nil
end

local function captureVanilla(force)
	local ball, axe = resolveParts()
	if not ball then ball = findBallFallback() end

	if force or VANILLA.gravity == nil then
		VANILLA.gravity = workspace.Gravity
	end
	if ball and (force or VANILLA.ballMaterial == nil) then
		VANILLA.ballMaterial = ball.Material
		VANILLA.ballColor = ball.Color
	end
	if axe and (force or VANILLA.axeMaterial == nil) then
		VANILLA.axeMaterial = axe.Material
		VANILLA.axeColor = axe.Color
	end
end

--============================================================================
-- 5. APPLY ENGINE  (the 0.6 s "spam")
--============================================================================
MATERIAL_NAMES = {
	"Plastic", "SmoothPlastic", "Neon", "Wood", "WoodPlanks", "Metal", "DiamondPlate",
	"Ice", "Glass", "Marble", "Granite", "Slate", "Concrete", "Brick", "Sand",
	"Fabric", "Grass", "LeafyGrass", "Mud", "Sandstone", "Basalt", "Limestone",
	"Cobblestone", "Pebble", "Rock", "CorrodedMetal", "Foil", "ForceField", "Rubber",
	"Cardboard", "Carpet", "CeramicTiles", "ClayRoofTiles", "Glacier", "Snow", "Asphalt",
	"Ground", "Salt", "RoofShingles",
}

local function matEnum(name)
	local ok, m = pcall(function() return Enum.Material[name] end)
	if ok and m then return m end
	return Enum.Material.Plastic
end

-- the quick colours on the Colour tab (used by the Rayfield buttons in section 6)
COLOR_PRESETS = {
	{ "white", 255, 255, 255 },
	{ "black", 20, 20, 20 },
	{ "red", 255, 60, 60 },
	{ "green", 80, 230, 110 },
	{ "blue", 90, 150, 255 },
	{ "gold", 255, 200, 60 },
	{ "purple", 180, 110, 255 },
}

local applyCount = 0
local lastStatus = "idle"

local function applyNow(reason)
	local ball, axe = resolveParts()
	if not ball then ball = findBallFallback() end

	-- ---- gravity -------------------------------------------------------
	if S.enabled.gravity then
		local target = VANILLA.gravity
		-- vanilla follows the game only while the switch was never forced:
		-- re-read it when the difference is large (level changed gravity)
		if target and math.abs(workspace.Gravity - target) > 400 then
			VANILLA.gravity = workspace.Gravity
			target = VANILLA.gravity
		end
		pcall(function() workspace.Gravity = S.gravity end)
	else
		if VANILLA.gravity ~= nil then
			pcall(function() workspace.Gravity = VANILLA.gravity end)
		end
	end

	-- ---- material ------------------------------------------------------
	local matWanted
	if S.enabled.material then
		matWanted = matEnum(S.materialName)
	else
		matWanted = VANILLA.ballMaterial
	end
	if ball and matWanted then
		pcall(function() ball.Material = matWanted end)
	end
	if axe then
		local axeWanted
		if S.enabled.material and S.axeMaterial then
			axeWanted = matEnum(S.materialName)
		else
			axeWanted = VANILLA.axeMaterial
		end
		if axeWanted then
			pcall(function() axe.Material = axeWanted end)
		end
	end

	-- ---- colour --------------------------------------------------------
	local colWanted
	if S.enabled.color then
		colWanted = Color3.fromRGB(S.r, S.g, S.b)
	else
		colWanted = VANILLA.ballColor
	end
	if ball and colWanted then
		pcall(function() ball.Color = colWanted end)
	end
	if axe then
		local axeWanted
		if S.enabled.color and S.axeColor then
			axeWanted = Color3.fromRGB(S.r, S.g, S.b)
		else
			axeWanted = VANILLA.axeColor
		end
		if axeWanted then
			pcall(function() axe.Color = axeWanted end)
		end
	end

	applyCount = applyCount + 1

	-- ---- status line ---------------------------------------------------
	local parts = "ball: " .. (ball and "ok" or "MISSING")
	lastStatus = string.format(
		"grav %s (%s)  |  mat %s (%s)  |  col %s (%s)  |  %s  |  ticks %d\n%s",
		S.enabled.gravity and "ON " or "off", tostring(S.gravity),
		S.enabled.material and "ON " or "off", tostring(S.materialName),
		S.enabled.color and "ON " or "off", toHex(Color3.fromRGB(S.r, S.g, S.b)),
		parts, applyCount, hackStatus)
end

--============================================================================
-- 5c. GAME HACKS  (speed hack + infinite axe reach)
--     These two run EVERY FRAME, not on the 0.6 s tick: they have to be smooth.
--     The 0.6 s tick only re-asserts the "enabled" state through applyNow().
--============================================================================
local SPEED_HACK_MIN   = 0.1
local SPEED_HACK_MAX   = 10
local REACH_MULT_MAX   = 50
local REACH_MAX_STUDS  = 1500  -- "infinite", but the physics stays sane
local REACH_HITBOX_MAX = 10    -- the hitbox may grow at most 10x

local hackStatus = "hacks off"
local reachApplied = false
local lastReachOut, lastReachRaw = nil, nil

-- The TAS writes the recorded mover targets while it is testing a tape and pins
-- the parts onto the tape, so our hacks would only fight the replay: they step
-- aside. While the TAS is RECORDING they stay on (that is the point - the tape
-- then contains the boosted run), unless the TAS is applying its own world
-- speed hack, which would otherwise double up.
local function tasHackGuard()
	local handle = _G.__SIMPLE_TAS
	local st = handle and handle.state
	if type(st) ~= "table" then return nil end
	if st.mode == 3 then return "tape replay" end
	if st.mode == 2 and (st.worldSpeed or 1) > 1.001 then return "TAS world speed" end
	return nil
end

local function boostPart(part, k, dt)
	if not part then return end
	local extra = (k - 1) * dt
	pcall(function()
		local v = part.AssemblyLinearVelocity
		if v and v.Magnitude > 0.01 then
			-- extra travel along the part's own direction of motion. Velocity is
			-- never scaled, so nothing runs away and nothing drifts when idle.
			part.CFrame = part.CFrame + v * extra
		end
	end)
end

local function firstChildOfClass(part, className, name)
	if not part then return nil end
	local byName = part:FindFirstChild(name)
	if byName then return byName end
	local ok, found = pcall(function() return part:FindFirstChildWhichIsA(className) end)
	if ok and found then return found end
	local children = part:GetChildren()
	for _, child in ipairs(children) do
		if child.ClassName == className then return child end
	end
	return nil
end

local function applyHacks(dt)
	local ball, axe = resolveParts()
	if not ball then ball = findBallFallback() end

	local guard = tasHackGuard()

	-- ---- speed hack ----------------------------------------------------
	local speedNote = "off"
	if S.speedHack then
		local k = clampNum(tonumber(S.speedHackMult) or 1, SPEED_HACK_MIN, SPEED_HACK_MAX)
		if guard then
			speedNote = "paused (" .. guard .. ")"
		elseif math.abs(k - 1) > 0.001 then
			-- below 1x the same displacement is negative, which is slow motion
			boostPart(ball, k, dt)
			boostPart(axe, k, dt)
			speedNote = string.format("%.2fx%s", k, k < 1 and " slow" or "")
		else
			speedNote = "1x (no effect)"
		end
	end

	-- ---- infinite axe reach --------------------------------------------
	local reachNote = "off"
	local bp = firstChildOfClass(axe, "BodyPosition", "BodyPosition")
	if S.reachOn then
		local mult = clampNum(tonumber(S.reachMult) or 1, 1, REACH_MULT_MAX)
		if guard then
			reachNote = "paused (" .. guard .. ")"
		elseif not (ball and axe and bp) then
			reachNote = "waiting for the axe"
		else
			local base = ball.Position
			local target = bp.Position
			-- if the game did not rewrite the target since our last write (mouse
			-- idle) we must not scale our own scaled value again
			if lastReachOut and lastReachRaw and (target - lastReachOut).Magnitude < 0.01 then
				target = lastReachRaw
			end
			local offset = target - base
			local len = offset.Magnitude
			if len < 0.05 then
				reachNote = "no aim direction yet"
			else
				local want = math.min(len * mult, REACH_MAX_STUDS)
				lastReachRaw = target
				lastReachOut = base + offset.Unit * want
				pcall(function() bp.Position = lastReachOut end)
				reachApplied = true
				reachNote = string.format("%.1fx (arm %.1f studs)", mult, want)
			end
			if S.reachHitbox and axe then
				local hitbox = axe:FindFirstChild("hitHitbox")
				if hitbox and hitbox.Size then
					if VANILLA.hitboxSize == nil then
						VANILLA.hitboxSize = Vector3.new(hitbox.Size.X, hitbox.Size.Y, hitbox.Size.Z)
					end
					local f = clampNum(mult, 1, REACH_HITBOX_MAX)
					pcall(function()
						hitbox.Size = Vector3.new(
							VANILLA.hitboxSize.X * f,
							VANILLA.hitboxSize.Y * f,
							VANILLA.hitboxSize.Z * f)
					end)
				end
			end
		end
	elseif reachApplied then
		-- switched off: put the hitbox back to its own size once
		reachApplied = false
		lastReachRaw, lastReachOut = nil, nil
		local hitbox = axe and axe:FindFirstChild("hitHitbox")
		if hitbox and VANILLA.hitboxSize and hitbox.Size then
			pcall(function()
				hitbox.Size = Vector3.new(VANILLA.hitboxSize.X, VANILLA.hitboxSize.Y, VANILLA.hitboxSize.Z)
			end)
		end
	end

	hackStatus = string.format("speed hack %s  |  reach %s", speedNote, reachNote)
end


--============================================================================
-- 5d. BALL WAYPOINTS
--     A Getting-Over-It climb is spent re-climbing what you already climbed.
--     So: save the ball's position, jump the ball back to it, and let the game
--     do the same thing for you by reading the layout in the OTHER direction:
--     the map's own checkpoints.
--
--       your waypoints   F5 saves where the ball is, F6 jumps back, F7 = undo
--       the map's own     workspace.map.safePoints.01..NN (the game's checkpoints)
--                         workspace.map.splits.01..NN   (speedrun gates)
--                         <FINISH>.Zone                 (the end of the run)
--       trail            crumbs recorded while you climb, "back one" = undo a fall
--
--     NOTHING here draws anything in the world by default. The map's own
--     checkpoints are a LIST in the window (name, kind, distance) and are never
--     given a marker: a level can hold dozens of them and a sphere on each one
--     buries the level you are trying to play. Markers for YOUR OWN waypoints
--     and crumbs are a switch, off by default, and the FINISH pad is never a
--     jump target unless you explicitly allow it (see WP.jump).
--============================================================================
local WP = {}

local WP_MAX = 50          -- your own waypoints, capped
local WP_POINT_CAP = 60    -- map points in the list / dropdown, capped
local WP_MARKER_CAP = 160  -- markers on screen at once (waypoints + crumbs + map)
local KIND_COLOR = {
	own        = Color3.fromRGB(120, 200, 255),
	crumbs     = Color3.fromRGB(255, 214, 90),
	checkpoint = Color3.fromRGB(120, 255, 140),
	split      = Color3.fromRGB(255, 150, 60),
	finish     = Color3.fromRGB(255, 80, 220),
	elevator   = Color3.fromRGB(160, 220, 255),
}
local KIND_ORDER = { checkpoint = 1, finish = 2, elevator = 3, split = 4 }

-- the level the ball is in right now (the game's own LevelName / CurrentLevel)
local function wpLevelName()
	local okLevel, levelName = pcall(function() return workspace:FindFirstChild("LevelName") end)
	if okLevel and levelName then
		local okV, v = pcall(function() return levelName.Value end)
		if okV and v ~= nil and tostring(v) ~= "" then return tostring(v) end
	end
	local okCur, cur = pcall(function() return workspace:FindFirstChild("CurrentLevel") end)
	if okCur and cur then
		local okV, v = pcall(function() return cur.Value end)
		if okV and v ~= nil and tostring(v) ~= "" then return "level " .. tostring(v) end
	end
	return nil
end

WP.markers = {}       -- key -> marker part
WP.points = {}        -- the map's own points (filled by WP.scanGame)
WP.assertPos = nil    -- while set, the jump keeps re-asserting the landing spot
WP.assertUntil = 0
WP.lastJump = -99
WP.lastScanLevel = nil
WP.lastScanAt = -99
WP.saveCount = 0

local function wpFolder()
	local folder = workspace:FindFirstChild("BallTweaksWP")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "BallTweaksWP"
		pcall(function() folder.Parent = workspace end)
	end
	return folder
end

local function looksLikeVec3(v)
	if v == nil then return false end
	if type(v) == "table" then
		return tonumber(v.X) ~= nil and tonumber(v.Y) ~= nil and tonumber(v.Z) ~= nil
	end
	local ok, kind = pcall(function() return typeof(v) end) -- Roblox: Vector3 is userdata
	return ok and (kind == "Vector3" or kind == "Vector3int16")
end

local function wpVec(entry)
	if type(entry) ~= "table" then return nil end
	-- the map scan keeps a real Vector3, our own waypoints keep plain numbers
	if looksLikeVec3(entry.pos) then
		local p = entry.pos
		return Vector3.new(tonumber(p.X), tonumber(p.Y), tonumber(p.Z))
	end
	local x, y, z = tonumber(entry.x or entry[1]), tonumber(entry.y or entry[2]), tonumber(entry.z or entry[3])
	if not x or not y or not z then return nil end
	return Vector3.new(x, y, z)
end

local function wpBall()
	local ball = select(1, resolveParts())
	if not ball then ball = findBallFallback() end
	if ball and ball.Parent == nil then ball = nil end
	return ball
end

function WP.here()
	local ball = wpBall()
	return ball and ball.Position or nil
end

-- ---- markers ------------------------------------------------------------
-- one neon ball per point, with a Highlight so it reads through the geometry
-- and a BillboardGui label so you know which one is which
local function wpMakeMarker(key, pos, color)
	local folder = wpFolder()
	if not folder then return nil end
	local m = Instance.new("Part")
	m.Name = "wp_" .. tostring(key)
	m.Shape = Enum.PartType.Ball
	m.Size = Vector3.new(0.9, 0.9, 0.9)
	m.Anchored = true
	m.CanCollide = false
	m.CanQuery = false
	m.CanTouch = false
	m.Material = Enum.Material.Neon
	m.Color = color
	m.Transparency = 0.2
	m.CFrame = CFrame.new(pos)
	pcall(function() m.CastShadow = false end)
	m.Parent = folder
	pcall(function()
		local hl = Instance.new("Highlight")
		hl.Name = "glow"
		hl.Adornee = m
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.FillColor = color
		hl.OutlineColor = color
		hl.FillTransparency = 0.6
		hl.OutlineTransparency = 0.1
		hl.Parent = m
	end)
	pcall(function()
		local bb = Instance.new("BillboardGui")
		bb.Name = "label"
		bb.Adornee = m
		bb.AlwaysOnTop = true
		bb.Size = UDim2.new(0, 190, 0, 18)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 1.4, 0)
		local t = Instance.new("TextLabel")
		t.Name = "text"
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, 0, 1, 0)
		t.Font = Enum.Font.Code
		t.TextSize = 13
		t.TextColor3 = color
		t.TextStrokeColor3 = Color3.new(0, 0, 0)
		t.TextStrokeTransparency = 0.4
		t.Text = ""
		t.Parent = bb
		bb.Parent = m
	end)
	return m
end

local function wpMarkerText(key, text)
	local m = WP.markers[key]
	if not m then return end
	pcall(function()
		local bb = m:FindFirstChild("label")
		local t = bb and bb:FindFirstChild("text")
		if t then t.Text = text end
	end)
end

function WP.markerPos(key)
	local m = WP.markers[key]
	if not m then return nil end
	local ok, pos = pcall(function() return m.Position end)
	return ok and pos or nil
end

-- rebuild the marker set so it matches the waypoints / crumbs / map points
function WP.syncMarkers()
	local wanted = {}
	local ball = wpBall()
	local rp = ball and ball.Position or nil
	local function distanceText(pos)
		if not (S.wpLabels and rp) then return "" end
		return string.format("  (%.0f studs)", (pos - rp).Magnitude)
	end

	if S.wpMarkers then
		for i, entry in ipairs(S.waypoints) do
			local pos = wpVec(entry)
			if pos then
				wanted["w" .. i] = {
					pos = pos,
					color = KIND_COLOR.own,
					text = string.format("#%d %s%s", i, tostring(entry.name or "waypoint"), distanceText(pos)),
				}
			end
		end
	end
	if S.trailMarkers and #S.trail > 0 then
		for i, entry in ipairs(S.trail) do
			local pos = wpVec(entry)
			if pos then
				wanted["t" .. i] = {
					pos = pos,
					color = KIND_COLOR.crumbs,
					text = string.format("crumb %d%s", i, distanceText(pos)),
				}
			end
		end
	end
	-- drop the ones that are no longer wanted
	for key, marker in pairs(WP.markers) do
		if not wanted[key] then
			pcall(function() marker:Destroy() end)
			WP.markers[key] = nil
		end
	end
	-- add the missing ones (with the cap, so a 200-crumb trail cannot tank fps)
	if next(wanted) == nil and next(WP.markers) == nil then
		-- nothing to draw: take the (old) empty folder out of the world too
		local stale = workspace:FindFirstChild("BallTweaksWP")
		if stale then
			local ok, children = pcall(function() return #stale:GetChildren() end)
			if not ok or children == 0 then pcall(function() stale:Destroy() end) end
		end
	end
	local made = 0
	for key, entry in pairs(wanted) do
		if not WP.markers[key] then
			if made < WP_MARKER_CAP then
				WP.markers[key] = wpMakeMarker(key, entry.pos, entry.color)
				made = made + 1
			end
		else
			pcall(function() WP.markers[key].CFrame = CFrame.new(entry.pos) end)
			local ok, color = pcall(function() return WP.markers[key].Color end)
			if ok and color ~= entry.color then
				pcall(function() WP.markers[key].Color = entry.color end)
			end
		end
		wpMarkerText(key, entry.text)
	end
end

function WP.clearMarkers()
	for key, marker in pairs(WP.markers) do
		pcall(function() marker:Destroy() end)
		WP.markers[key] = nil
	end
	-- the old build left an empty folder behind, which is exactly what makes
	-- someone wonder what used to be in it: clean it up
	local folder = workspace:FindFirstChild("BallTweaksWP")
	if folder then
		local ok, children = pcall(function() return #folder:GetChildren() end)
		if not ok or children == 0 then pcall(function() folder:Destroy() end) end
	end
end

-- ---- your waypoints -----------------------------------------------------
function WP.count()
	return #S.waypoints
end

function WP.add(pos, name)
	pos = pos or WP.here()
	if not pos then return nil, "the ball is not in the world yet" end
	-- standing still and pressing save twice should not stack points
	local mergeAt = S.wpMerge or 6
	for i, entry in ipairs(S.waypoints) do
		local other = wpVec(entry)
		if other and (other - pos).Magnitude <= mergeAt then
			entry.x, entry.y, entry.z = pos.X, pos.Y, pos.Z
			entry.level = wpLevelName() or entry.level
			S.wpIndex = i -- the one you just touched is the one a jump goes back to
			return i, "moved", true
		end
	end
	if #S.waypoints >= WP_MAX then
		return nil, string.format("the list is full (%d) - delete one first", WP_MAX)
	end
	local entry = {
		x = pos.X, y = pos.Y, z = pos.Z,
		name = tostring(name or ""),
		level = wpLevelName(), -- so a jump after a rejoin cannot land in the wrong level
	}
	if entry.name == "" then
		WP.saveCount = (WP.saveCount or 0) + 1
		entry.name = string.format("%s climb %d", os.date("%H:%M"), WP.saveCount)
	end
	S.waypoints[#S.waypoints + 1] = entry
	S.wpIndex = #S.waypoints
	return #S.waypoints, "added", false
end

function WP.remove(index)
	index = tonumber(index)
	if not index or not S.waypoints[index] then return false end
	table.remove(S.waypoints, index)
	return true
end

function WP.clear()
	S.waypoints = {}
	WP.saveCount = 0
	return true
end

function WP.selected()
	local i = tonumber(S.wpIndex) or #S.waypoints
	local entry = S.waypoints[i]
	if entry then return entry, i end
	return S.waypoints[#S.waypoints], #S.waypoints
end

function WP.nearest(pos)
	pos = pos or WP.here()
	if not pos then return nil end
	local best, bestD, bestI
	for i, entry in ipairs(S.waypoints) do
		local p = wpVec(entry)
		if p then
			local d = (p - pos).Magnitude
			if not bestD or d < bestD then best, bestD, bestI = p, d, i end
		end
	end
	if best then return S.waypoints[bestI], bestI, bestD end
	return nil
end

-- the FINISH pad is the one piece of the map that must not be a jump target:
-- its touch zone is what submits a run time, and a 0.2 s "run" is the kind of
-- thing an anti-cheat looks at. It shows up in the list so you know where the
-- end is; it just refuses to take you there unless you say so.
local FINISH_GUARD = 20 -- studs: landing this close to the pad counts as "on it"

function WP.finishNear(pos, radius)
	if not pos then return nil end
	local limit = tonumber(radius) or FINISH_GUARD
	local best, bestD
	for _, entry in ipairs(WP.points) do
		if entry.kind == "finish" and entry.pos then
			local d = (entry.pos - pos).Magnitude
			if d <= limit and (not bestD or d < bestD) then best, bestD = entry, d end
		end
	end
	return best, bestD
end

-- ---- the jump -----------------------------------------------------------
-- Move the whole player model (ball + axe together, or they get ripped apart),
-- kill the velocity that was carrying you towards the floor, and re-aim the
-- movers the game uses to drive the ball - otherwise they pull you straight back.
function WP.jump(entry, label, liftOverride)
	local ball = wpBall()
	local pos = wpVec(entry)
	if not ball then return false, "no ball" end
	if not pos then return false, "no position" end

	-- a waypoint saved in another level is a position that means nothing here
	-- (this is what makes a jump "teleport you somewhere odd" after a rejoin)
	if S.wpLevelGuard and type(entry) == "table" and entry.level then
		local here = wpLevelName()
		if here and tostring(entry.level) ~= tostring(here) then
			WP.lastRefusal = string.format("that waypoint was saved in '%s', you are in '%s'", tostring(entry.level), tostring(here))
			return false, WP.lastRefusal
		end
	end

	-- the end of the run is not a place to teleport to
	local finish, finishDist = WP.finishNear(pos)
	if finish and not S.allowFinishJump then
		WP.lastRefusal = string.format("that spot is %.0f studs from the FINISH pad - touching it submits a time (that is what a " ..
			"leaderboard check sees). Switch on 'Allow jumps onto the FINISH pad' if you really want it.", finishDist or 0)
		return false, WP.lastRefusal
	end

	local lift = tonumber(liftOverride) or tonumber(S.wpLift) or 3
	local target = pos + Vector3.new(0, lift, 0)
	local delta = target - ball.Position
	local model = getPlayerModel()

	local moved = false
	if model then
		moved = pcall(function()
			model:PivotTo(model:GetPivot() + delta)
		end)
	end
	if not moved then
		-- no PivotTo (old levels / mocks): move the parts by the same delta and
		-- their relative layout survives
		pcall(function() ball.CFrame = ball.CFrame + delta end)
		local axe = select(2, resolveParts())
		if axe then pcall(function() axe.CFrame = axe.CFrame + delta end) end
	end
	-- stop dead: otherwise the ball keeps the speed it had when it fell
	pcall(function() ball.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
	pcall(function() ball.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
	local bp = ball:FindFirstChildOfClass("BodyPosition")
	if bp then
		pcall(function() bp.Position = target end)
	end
	local bg = ball:FindFirstChildOfClass("BodyGyro")
	if bg then
		pcall(function() bg.CFrame = ball.CFrame end)
	end
	-- hold the spot: either for the short window, or until this is switched off
	if S.wpAssert or S.wpHold then
		WP.assertPos = target
		if S.wpHold then
			WP.hold = true
			WP.assertUntil = math.huge
		else
			WP.hold = false
			WP.assertUntil = os.clock() + (tonumber(S.wpAssertTime) or 0.3)
		end
	else
		WP.assertPos = nil
		WP.hold = false
	end
	WP.lastJump = os.clock()
	-- watch the landing for a moment: if the game drags the ball back to where
	-- it thinks you are, say so instead of letting you wonder
	WP.watch = { pos = target, expires = os.clock() + 2.5, warned = false }
	return true
end

-- give up the spot (the "hold" switch, F6 again, or a level change)
function WP.releaseHold(reason)
	if WP.hold then
		WP.hold = false
		WP.assertPos = nil
		WP.assertUntil = 0
		logLine("stopped holding the spot (%s)", tostring(reason or "released"))
		return true
	end
	return false
end

function WP.jumpSelected()
	local entry, index = WP.selected()
	if not entry then return false, "no waypoints saved yet" end
	local ok, err = WP.jump(entry, "waypoint")
	if ok then return true, string.format("jumped to #%d", index) end
	return false, err
end

function WP.jumpNearest()
	local entry, index, dist = WP.nearest()
	if not entry then return false, "no waypoints saved yet" end
	local ok, err = WP.jump(entry, "nearest")
	if ok then return true, string.format("jumped to #%d (%.0f studs away)", index, dist or 0) end
	return false, err
end

function WP.save()
	local index, how, movedExisting = WP.add(WP.here())
	if not index then return false, how end
	if movedExisting then
		return true, string.format("waypoint #%d moved here", index)
	end
	return true, string.format("waypoint #%d saved", index)
end

function WP.undo()
	if #S.waypoints == 0 then return false, "nothing to undo" end
	local removed = table.remove(S.waypoints)
	return true, string.format("removed '%s'", tostring(removed and removed.name or "?"))
end

-- ---- trail (crumbs) -----------------------------------------------------
function WP.trailPush(pos)
	S.trail[#S.trail + 1] = { x = pos.X, y = pos.Y, z = pos.Z, t = os.time() }
	while #S.trail > (tonumber(S.trailMax) or 40) do table.remove(S.trail, 1) end
	WP.trailDirty = true
end

function WP.trailClear()
	S.trail = {}
	WP.trailDirty = true
end

function WP.trailCount()
	return #S.trail
end

function WP.trailBack()
	local entry = S.trail[#S.trail]
	if entry then
		local ok, err = WP.jump(entry, "crumb", 2)
		if ok then
			table.remove(S.trail)
			WP.trailDirty = true
			return true, string.format("back to the last crumb (%d left)", #S.trail)
		end
		return false, err
	end
	-- no crumbs: fall back to the newest waypoint, so F7 is never dead
	local entry2, index = WP.selected()
	if entry2 then
		local ok, err = WP.jump(entry2, "waypoint", 2)
		if ok then return true, string.format("no crumbs - jumped to waypoint #%d", index) end
		return false, err
	end
	return false, "no crumbs and no waypoints"
end

-- per-frame: the re-assert window, the trail, and the fall watchdog
function WP.tickFast(dt)
	local ball = wpBall()
	local pos = ball and ball.Position or nil

	-- keep the landing spot: the game's own positionUpdate can snap the ball back
	-- (for the short window, or for as long as "hold" is on)
	if WP.assertPos then
		if os.clock() < WP.assertUntil then
			if ball and (ball.Position - WP.assertPos).Magnitude > 0.6 then
				local delta = WP.assertPos - ball.Position
				local model = getPlayerModel()
				local ok = false
				if model then ok = pcall(function() model:PivotTo(model:GetPivot() + delta) end) end
				if not ok then pcall(function() ball.CFrame = ball.CFrame + delta end) end
				pcall(function() ball.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end)
			end
		else
			WP.assertPos = nil
			WP.hold = false
		end
	end

	if not pos then return end

	-- did the game take the ball back? say so (this is the "my waypoint does
	-- nothing after a rejoin" case: the server decides where you are)
	if WP.watch and not WP.watch.warned then
		if os.clock() > WP.watch.expires then
			WP.watch = nil
		elseif (pos - WP.watch.pos).Magnitude > 30 then
			WP.watch.warned = true
			local pulled = (pos - WP.watch.pos).Magnitude
			logLine("the game pulled the ball %.0f studs off the landing spot - the server is re-writing your position", pulled)
			notifyUser("the game pulled you back",
				string.format("something rewrote your position (%.0f studs). Turn on 'Hold the spot' on the Waypoints tab, " ..
					"or use the map's own checkpoints - a client script cannot overrule a server that checks.", pulled), 8)
		end
	end

	local settling = (os.clock() - (WP.lastJump or -99)) < 0.5
	if S.trailOn and not settling then
		local last = wpVec(S.trail[#S.trail])
		if not last then
			WP.trailPush(pos)
		elseif (last - pos).Magnitude >= (tonumber(S.trailSpacing) or 25) then
			-- crumbs are the places you stood on the way up: the bottom of a fall
			-- is not one of them, or F7 would helpfully send you back down there
			if (last.Y - pos.Y) < (tonumber(S.trailFall) or 60) then
				WP.trailPush(pos)
			end
		end
	end

	-- fell? offer the crumb back (never while a jump is still settling)
	if S.trailAuto and #S.trail > 0 then
		if (os.clock() - (WP.lastJump or -99)) > 2 then
			local top = wpVec(S.trail[#S.trail])
			if top and (top.Y - pos.Y) >= (tonumber(S.trailFall) or 60) then
				local entry = S.trail[#S.trail]
				WP.jump(entry, "fall recovery", 2)
				notifyUser("you fell " .. string.format("%.0f", top.Y - pos.Y) .. " studs",
					"put you back on the last crumb")
			end
		end
	end
end

-- slower pass: distances on the labels, and rebuild the marker set if it moved
function WP.tickSlow()
	-- note: the map's own checkpoints never get markers, so they are not in here
	if not S.wpMarkers and not S.trailMarkers then
		if next(WP.markers) ~= nil then WP.syncMarkers() end
		return
	end
	local ball = wpBall()
	local rp = ball and ball.Position or nil
	if not rp then return end
	for key, marker in pairs(WP.markers) do
		local ok, pos = pcall(function() return marker.Position end)
		if ok and pos then
			local text
			local kind, index = key:sub(1, 1), tonumber(key:sub(2))
			if kind == "w" and S.waypoints[index] then
				text = string.format("#%d %s", index, tostring(S.waypoints[index].name or "waypoint"))
			elseif kind == "t" and S.trail[index] then
				text = string.format("crumb %d", index)
			elseif kind == "g" and WP.points[index] then
				text = string.format("%s %s", WP.points[index].kind, WP.points[index].name)
			end
			if text then
				if S.wpLabels then text = text .. string.format("  (%.0f studs)", (pos - rp).Magnitude) end
				wpMarkerText(key, text)
			end
		end
	end
	if WP.trailDirty then
		WP.trailDirty = false
		WP.syncMarkers()
	end
end

-- ---- the map's own checkpoints -----------------------------------------
local SCAN_ROOTS = { "map", "outerMap", "mainMap", "Temporary", "LevelMap" }

-- a part counts as a checkpoint / split / finish pad if it is named that way OR
-- sits inside something that is (map.FINISH.Zone, map.Elevator.Platform, ...)
local function kindOfName(name)
	name = tostring(name or ""):lower()
	if name:find("safepoint") or name:find("safe_point") or name:find("checkpoint") then return "checkpoint" end
	if name:find("elevator") then return "elevator" end
	if name:find("finish") then return "finish" end
	if name:find("split") and S.scanSplits then return "split" end
	return nil
end

local function kindFor(inst)
	local kind = kindOfName(inst.Name)
	if kind then return kind end
	local node, depth = inst.Parent, 0
	while node and depth < 4 do
		if node == workspace or node == game then break end
		local k = kindOfName(node.Name)
		if k then return k end
		node = node.Parent
		depth = depth + 1
	end
	return nil
end

function WP.scanGame(verbose)
	local found, seen = {}, {}
	local function consider(inst)
		if not inst or seen[inst] then return end
		seen[inst] = true
		if not inst:IsA("BasePart") then return end
		local kind = kindFor(inst)
		if not kind then return end
		local ok, pos = pcall(function() return inst.Position end)
		if not ok or not pos then return end
		found[#found + 1] = {
			pos = pos,
			name = tostring(inst.Name),
			parent = (function()
				local okP, parent = pcall(function() return inst.Parent end)
				if okP and parent then return tostring(parent.Name) end
				return nil
			end)(),
			kind = kind,
			fullName = (function()
				local okN, n = pcall(function() return inst:GetFullName() end)
				return okN and n or tostring(inst.Name)
			end)(),
		}
	end
	for _, rootName in ipairs(SCAN_ROOTS) do
		local root = workspace:FindFirstChild(rootName)
		if root then
			local target = root
			if root.ClassName == "ObjectValue" then target = root.Value end
			if target then
				consider(target)
				local ok, list = pcall(function() return target:GetDescendants() end)
				if ok and type(list) == "table" then
					for _, d in ipairs(list) do consider(d) end
				end
			end
		end
	end
	if #found == 0 then
		-- some levels put the map straight in workspace
		local ok, list = pcall(function() return workspace:GetDescendants() end)
		if ok and type(list) == "table" then
			for _, d in ipairs(list) do consider(d) end
		end
	end
	local ball = wpBall()
	local rp = ball and ball.Position or nil
	if rp then
		for _, entry in ipairs(found) do
			entry.dist = (entry.pos - rp).Magnitude
		end
	end
	table.sort(found, function(a, b)
		local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
		if ka ~= kb then return ka < kb end
		return a.name < b.name
	end)
	local capped = false
	if #found > WP_POINT_CAP then
		capped = true
		local kept = {}
		for i = 1, WP_POINT_CAP do kept[i] = found[i] end
		found = kept
	end
	WP.points = found
	WP.capped = capped
	WP.lastScanAt = os.clock()
	WP.trailDirty = true
	-- deliberately NO markers here: a level can hold dozens of these and the
	-- world stays clean - they are a list in the window, nothing else
	local counts = {}
	for _, entry in ipairs(found) do
		counts[entry.kind] = (counts[entry.kind] or 0) + 1
	end
	local parts = {}
	for _, kind in ipairs({ "checkpoint", "finish", "elevator", "split" }) do
		if counts[kind] then parts[#parts + 1] = string.format("%d %s", counts[kind], kind) end
	end
	local summary
	if #parts == 0 then
		summary = "nothing found - this level may keep its checkpoints on the server"
	else
		summary = table.concat(parts, ", ")
		if capped then
			summary = summary .. string.format(" (showing the nearest %d)", WP_POINT_CAP)
		end
	end
	if verbose then
		logLine("map scan: " .. summary)
		for i, entry in ipairs(found) do
			if i <= 12 then
				logLine(string.format("   %2d. %-9s %-18s at (%.0f, %.0f, %.0f)", i, entry.kind, entry.name,
					entry.pos.X, entry.pos.Y, entry.pos.Z))
			end
		end
		notifyUser("map scan", summary)
	end
	refreshGameDropdown()
	return #found, summary
end

function WP.jumpGame(index)
	local entry = WP.points[tonumber(index) or 0]
	if not entry then return false, "nothing scanned yet - press Scan now" end
	if entry.kind == "finish" and not S.allowFinishJump then
		return false, string.format("'%s' is the FINISH pad: landing on it is what submits a run time. " ..
			"It is listed so you know where the end is - turn on 'Allow jumps onto the FINISH pad' if you really want it.",
			tostring(entry.name))
	end
	local ok, err = WP.jump(entry, entry.kind, 3)
	if ok then return true, string.format("jumped to %s %s", entry.kind, entry.name) end
	return false, err
end

function WP.jumpNearestGame()
	local ball = wpBall()
	local rp = ball and ball.Position or nil
	local best, bestD, bestI
	for i, entry in ipairs(WP.points) do
		if rp then
			local d = (entry.pos - rp).Magnitude
			if entry.kind ~= "finish" and (not bestD or d < bestD) then best, bestD, bestI = entry, d, i end
		end
	end
	if not best then return false, "nothing scanned yet" end
	local ok, err = WP.jump(best, best.kind, 3)
	if ok then return true, string.format("jumped to %s %s (%.0f studs)", best.kind, best.name, bestD or 0) end
	return false, err
end

-- rescan when the level changes (a new level loads its own checkpoints)
function WP.levelWatch()
	local name
	local okName, levelName = pcall(function() return workspace:FindFirstChild("LevelName") end)
	if okName and levelName then
		local okV, v = pcall(function() return levelName.Value end)
		if okV then name = tostring(v) end
	end
	if not name then
		local okC, cur = pcall(function() return workspace:FindFirstChild("CurrentLevel") end)
		if okC and cur then
			local okV, v = pcall(function() return cur.Value end)
			if okV then name = "level " .. tostring(v) end
		end
	end
	if not name then return end
	if WP.lastScanLevel == nil then
		WP.lastScanLevel = name
		if S.scanAuto then WP.scanGame(false) end
		return
	end
	if name ~= WP.lastScanLevel then
		WP.lastScanLevel = name
		WP.watch = nil
		WP.releaseHold("the level changed")
		if S.scanAuto then
			task.defer(function() WP.scanGame(false) end)
			logLine("level changed to " .. name .. " - rescanning the checkpoints")
		end
	end
end

--============================================================================
-- 5e. ANTI-AFK  (the 20 minute kick while you are away from the keyboard)
--     Roblox fires LocalPlayer.Idled shortly before it kicks you for being idle;
--     sending one harmless input from there resets the timer. Two ways to do
--     that, tried in order, and if the executor allows neither we say so instead
--     of pretending:
--       1. VirtualUser:CaptureController + a click  (what most executors expose)
--       2. the executor's own keypress / presskey helper
--     The switch is off by default and nothing is sent while it is off.
--============================================================================
local ANTI = { mode = nil, pokes = 0, lastPoke = 0, failed = false }

function ANTI.poke()
	-- 1) VirtualUser (Roblox's own "pretend the player did something" service)
	local okVu = pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new(0, 0))
	end)
	if okVu then
		ANTI.mode = "VirtualUser"
		return true, ANTI.mode
	end
	-- 2) the executor's key helper
	for _, name in ipairs({ "keypress", "presskey" }) do
		local fn = rawget(_G, name)
		if type(fn) == "function" then
			local okPress = pcall(fn, "space")
			if okPress then
				ANTI.mode = name
				return true, ANTI.mode
			end
		end
	end
	ANTI.failed = true
	return false, "this executor cannot fake an input (no VirtualUser, no keypress) - the idle kick cannot be avoided by this script"
end

function ANTI.handle()
	ANTI.pokes = ANTI.pokes + 1
	ANTI.lastPoke = os.time()
	local ok, mode = ANTI.poke()
	if ok then
		logLine("idle kick incoming - sent a %s input (poke %d)", tostring(mode), ANTI.pokes)
	else
		logLine("idle kick incoming - " .. tostring(mode))
		notifyUser("idle kick incoming", tostring(mode), 8)
	end
	return ok
end

--============================================================================
-- 6. RAYFIELD GEN2 UI   (https://docs.sirius.menu/rayfield-gen2)
--     Everything here is optional: if the library cannot be fetched you still
--     get the hotkeys, the notifications (printed) and every switch still
--     works from the console through _G.__BALLTWEAKS.
--============================================================================
local UI = { handles = {}, tabs = {}, window = nil, ok = false, consoles = {} }

local function safe(fn, ...)
	if type(fn) ~= "function" then return false end
	local ok, err = pcall(fn, ...)
	if not ok then pcall(logLine, "ui callback error: " .. tostring(err)) end
	return ok
end

-- notifyUser was forward-declared in section 2b: the window is filled in here
notifyUser = function(title, content, duration)
	if UI.window then
		local ok = pcall(function()
			UI.window:Notify({ title = tostring(title), content = tostring(content), duration = duration or 4 })
		end)
		if ok then return true end
	end
	print(string.format("[BallTweaks] %s - %s", tostring(title), tostring(content)))
	return false
end

local function hudLine(text, important)
	if UI.consoles.status then
		pcall(function() UI.consoles.status:Set(text) end)
	end
	if important then pcall(logLine, text) end
end

local function makeElement(tab, method, props)
	if not tab then return nil end
	local fn = tab[method]
	if type(fn) ~= "function" then
		logLine("this Rayfield Gen2 build has no %s", method)
		return nil
	end
	local ok, handle = pcall(fn, tab, props)
	if not ok then
		logLine("element %s failed: %s", tostring(props and props.name), tostring(handle))
		return nil
	end
	return handle
end

local function addSection(tab, name)
	return makeElement(tab, "CreateSection", { name = name })
end

-- a few widgets live on a sub-table of S ("enabled.gravity"), so these walk the
-- dots instead of writing one flat key
local function stateGet(key)
	local node = S
	for part in tostring(key):gmatch("[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
	end
	return node
end

local function stateSet(key, value)
	local parts = {}
	for part in tostring(key):gmatch("[^%.]+") do parts[#parts + 1] = part end
	if #parts == 0 then return end
	local node = S
	for i = 1, #parts - 1 do
		if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
		node = node[parts[i]]
	end
	node[parts[#parts]] = value
end

local function addToggle(tab, name, desc, key, default, onChange)
	if stateGet(key) == nil and default ~= nil then stateSet(key, default) end
	local h = makeElement(tab, "CreateToggle", {
		name = name,
		description = desc,
		value = stateGet(key),
		flag = "BT_" .. key,
		callback = function(v)
			stateSet(key, v)
			if onChange then safe(onChange, v) end
		end,
	})
	if h then UI.handles[key] = h end
	return h
end

local function addSlider(tab, name, desc, key, min, max, step, suffix, onChange)
	local h = makeElement(tab, "CreateSlider", {
		name = name,
		description = desc,
		range = { min, max },
		increment = step,
		value = stateGet(key) or min,
		suffix = suffix,
		flag = "BT_" .. key,
		callback = function(v)
			stateSet(key, v)
			if onChange then safe(onChange, v) end
		end,
	})
	if h then UI.handles[key] = h end
	return h
end

-- a key of "!something" = a picker that only drives a callback (the waypoint /
-- checkpoint lists): its value belongs in S.wpIndex, not in a state key of its own
local function uiOnlyKey(key)
	local text = tostring(key)
	if text:sub(1, 1) == "!" then return text:sub(2), true end
	return text, false
end

local function addDropdown(tab, name, desc, key, options, default, onChange)
	local stateKey, uiOnly = uiOnlyKey(key)
	local h = makeElement(tab, "CreateDropdown", {
		name = name,
		description = desc,
		options = options,
		value = uiOnly and options[1] or (stateGet(stateKey) or default),
		flag = "BT_" .. stateKey,
		callback = function(sel)
			-- Gen2 always hands a dropdown a table, single-select or not
			local v = type(sel) == "table" and sel[1] or sel
			if not uiOnly then stateSet(stateKey, v) end
			if onChange then safe(onChange, v) end
		end,
	})
	if h then UI.handles[stateKey] = h end
	return h
end

local function addInput(tab, name, desc, key, default, onChange, extra)
	local props = {
		name = name,
		description = desc,
		placeholder = tostring(stateGet(key) or default or ""),
		value = tostring(stateGet(key) or default or ""),
		flag = "BT_" .. key,
		callback = function(text)
			stateSet(key, text)
			if onChange then safe(onChange, text) end
		end,
	}
	-- numeric / clearOnFocus and anything else Gen2 adds later
	if type(extra) == "table" then
		for k, v in pairs(extra) do props[k] = v end
	end
	local h = makeElement(tab, "CreateInput", props)
	if h then UI.handles[key] = h end
	return h
end

local function addButton(tab, name, desc, cb)
	return makeElement(tab, "CreateButton", {
		name = name,
		description = desc,
		callback = function() safe(cb) end,
	})
end

-- "Enum.KeyCode.F5", an EnumItem, or the plain "F5" -> always "F5"
local function plainKeyName(v)
	if v == nil then return nil end
	if type(v) == "string" then
		local tail = v:match("([%w_]+)$")
		return tail ~= "" and tail or nil
	end
	local okN, itemName = pcall(function() return v.Name end)
	if okN and type(itemName) == "string" and itemName ~= "" then return itemName end
	local okS, text = pcall(function() return tostring(v) end)
	if okS and type(text) == "string" then
		local tail = text:match("([%w_]+)$")
		return tail ~= "" and tail or nil
	end
	return nil
end

local function keyEnumFor(name, fallback)
	for _, candidate in ipairs({ name, fallback, "F5" }) do
		local text = plainKeyName(candidate)
		if text then
			local ok, item = pcall(function() return Enum.KeyCode[text] end)
			if ok and item then return item end
		end
	end
	return nil
end

local function addKeybind(tab, name, desc, key, default)
	-- Gen2 wants a real Enum.KeyCode here, and the state keeps the plain name
	local enum = keyEnumFor(stateGet(key), default)
	if not enum then
		logLine("no Enum.KeyCode for %s - the %s keybind is skipped (the key still works)", tostring(stateGet(key)), key)
		return nil
	end
	local h = makeElement(tab, "CreateKeybind", {
		name = name,
		description = desc,
		value = enum,
		flag = "BT_" .. key,
		-- the script fires the action itself (see section 7), so a keybind here
		-- only ever *rebinds*: no double action, and it works with no menu too
		onChanged = function(v)
			local plain = plainKeyName(v)
			if plain then stateSet(key, plain) end
		end,
	})
	if h then UI.handles[key] = h end
	return h
end

local function addText(tab, name, body)
	-- Gen2's Text card takes { name = the title, text = the body }; the older
	-- Rayfield spellings are kept as fallbacks
	local h = makeElement(tab, "CreateText", { name = name, text = body })
	if not h then h = makeElement(tab, "CreateText", { name = name, content = body }) end
	if not h then h = makeElement(tab, "CreateParagraph", { Title = name, Content = body }) end
	return h
end

local function addConsole(tab, key, name, height, follow)
	local h = makeElement(tab, "CreateConsole", {
		name = name,
		height = height or 110,
		follow = follow ~= false,
		maxLines = 200,
	})
	if h then
		UI.consoles[key] = h
		if key == "log" then logConsole = h end
		if key == "config" then configConsole = h end
	end
	return h
end

-- ---- the widgets that read back into the state ---------------------------
local function rgbColor()
	return Color3.fromRGB(S.r, S.g, S.b)
end

local syncWidgets -- forward: pushing S into every element (used after a load)

local function setRGB(r, g, b, reason)
	S.r = math.floor(clampNum(tonumber(r) or S.r, 0, 255))
	S.g = math.floor(clampNum(tonumber(g) or S.g, 0, 255))
	S.b = math.floor(clampNum(tonumber(b) or S.b, 0, 255))
	if syncWidgets then syncWidgets() end
	applyNow(reason or "colour")
end

-- ---- dropdowns that have to be rebuilt when the data changes -------------
local function waypointOptions()
	local out = {}
	local rp = WP.here()
	for i, entry in ipairs(S.waypoints) do
		local pos = Vector3.new(entry.x, entry.y, entry.z)
		local extra = rp and string.format("  (%.0f studs)", (pos - rp).Magnitude) or ""
		out[#out + 1] = string.format("#%d  %s%s", i, tostring(entry.name or "waypoint"), extra)
	end
	if #out == 0 then out[1] = "(nothing saved yet - press F5)" end
	return out
end

local function gameOptions()
	local out = {}
	for i, entry in ipairs(WP.points) do
		local tag = entry.kind == "finish" and "   (info only - ending a run from here is what gets flagged)" or ""
		local where = entry.parent and ("  (" .. tostring(entry.parent) .. ")") or ""
		out[#out + 1] = string.format("%d. %s  %s%s%s", i, entry.kind, entry.name, where, tag)
	end
	if #out == 0 then out[1] = "(nothing scanned yet - press Scan the map now)" end
	return out
end

local function indexFromOption(list, text, pattern)
	if not text then return nil end
	local n = tostring(text):match(pattern or "^#(%d+)")
	return tonumber(n)
end

local function refreshWaypointDropdown()
	local h = UI.handles.wpPick
	if h and h.Refresh then pcall(function() h:Refresh(waypointOptions()) end)
	elseif h and h.Set then
		local opts = waypointOptions()
		pcall(function() h:Set(opts[1], true) end)
	end
end

refreshGameDropdown = function()
	local h = UI.handles.gamePick
	if h and h.Refresh then pcall(function() h:Refresh(gameOptions()) end)
	elseif h and h.Set then
		local opts = gameOptions()
		pcall(function() h:Set(opts[1], true) end)
	end
end

-- ---- the window ---------------------------------------------------------
local function buildUI()
	local okWin, win = pcall(function()
		return Rayfield:CreateWindow({
			name = "Ball Tweaks",
			subtitle = "gravity / material / colour / hacks / waypoints",
			sidebarLayout = true,
			showName = "Ball Tweaks",
		})
	end)
	if not okWin or not win then
		logLine("Rayfield Gen2 did not load - running with hotkeys only (%s)", tostring(win))
		return false
	end
	UI.window = win

	local function tab(name, icon)
		local okT, t = pcall(function() return win:CreateTab({ name = name, icon = icon }) end)
		if okT then
			UI.tabs[name] = t
			return t
		end
		return nil
	end

	--====================================================== GRAVITY ========
	local tGrav = tab("Gravity", 98998359168436)
	if tGrav then
		addSection(tGrav, "World gravity")
		addToggle(tGrav, "Gravity override", "Writes workspace.Gravity every 0.6 s while this is on.", "enabled.gravity",
			false, function() applyNow("gravity toggle") end)
		addSlider(tGrav, "Gravity", "The value it writes. 196.2 is Roblox's default.",
			"gravity", -200, 1000, 0.1, "", function() applyNow("gravity slider") end)
		addInput(tGrav, "Exact gravity", "Type any number, up to +/-10000.", "gravityText", tostring(S.gravity),
			function(text)
				local n = tonumber(text)
				if n then
					S.gravity = clampNum(n, -10000, 10000)
					local h = UI.handles.gravity
					if h then pcall(function() h:Set(S.gravity, true) end) end
					applyNow("gravity typed")
				else
					notifyUser("that is not a number", "gravity kept at " .. tostring(S.gravity))
				end
			end, { numeric = true })
		addSection(tGrav, "Presets")
		addButton(tGrav, "0 - float", "No gravity at all.", function()
			S.gravity = 0 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "20 - moon", "", function()
			S.gravity = 20 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "50 - low", "", function()
			S.gravity = 50 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "98.1 - real life (9.81 x 10)", "", function()
			S.gravity = 98.1 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "120 - floaty", "", function()
			S.gravity = 120 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "196.2 - vanilla", "Roblox's own value: the same as switching this off.", function()
			S.gravity = 196.2 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "300 - heavy", "", function()
			S.gravity = 300 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addButton(tGrav, "500 - anvil", "", function()
			S.gravity = 500 ; syncWidgets() ; applyNow("gravity preset")
		end)
		addText(tGrav, "How it behaves",
			"While the switch is off the captured vanilla value is re-applied on the same 0.6 s tick, so the " ..
			"world can never quietly stay modified. Turning it back on writes the slider value instead. " ..
			"Low gravity on a climb makes every mistake recoverable; high gravity makes the ball grip.")
	end

	--===================================================== MATERIAL ========
	local tMat = tab("Material", 98998512143119)
	if tMat then
		addSection(tMat, "Ball material")
		addToggle(tMat, "Material override", "Writes ball.Material every 0.6 s while on.", "enabled.material",
			false, function() applyNow("material toggle") end)
		addDropdown(tMat, "Material", "Ice and Glass slide, Neon glows, Foil is light.", "materialName",
			MATERIAL_NAMES, "Ice", function() applyNow("material pick") end)
		addToggle(tMat, "Take the axe with it", "Also writes the material on the axe.", "axeMaterial",
			false, function() applyNow("axe material") end)
		addText(tMat, "Why material is not only cosmetic",
			"Ice, Glass, Marble, Granite and SmoothPlastic slide: they keep you moving where Plastic would stop you. " ..
			"Neon and ForceField make the ball easy to keep track of, which matters more than it sounds when it " ..
			"ends up half a screen away. The physics numbers behind a material are set by the game, so a material " ..
			"change is a friction change, not a speed hack - the speed hack is in the Hacks tab.")
	end

	--======================================================= COLOUR ========
	local tCol = tab("Colour", 98998506126645)
	if tCol then
		addSection(tCol, "Ball colour")
		addToggle(tCol, "Colour override", "Writes ball.Color every 0.6 s while on.", "enabled.color",
			false, function() applyNow("colour toggle") end)
		local okPick = pcall(function()
			return tCol:CreateColorPicker({
				name = "Ball colour",
				color = rgbColor(),
				flag = "BT_colour",
				callback = function(color)
					setRGB(color.R * 255, color.G * 255, color.B * 255, "colour picker")
				end,
			})
		end)
		if okPick then
			-- pcall returns true on success; grab the handle properly instead
		end
		local picker = makeElement(tCol, "CreateColorPicker", {
			name = "Ball colour",
			description = "Pick it here, or type a hex code further down.",
			color = rgbColor(),
			flag = "BT_colour",
			callback = function(color)
				setRGB(color.R * 255, color.G * 255, color.B * 255, "colour picker")
			end,
		})
		if picker then UI.handles.colour = picker end
		addSlider(tCol, "Red", "", "r", 0, 255, 1, "", function(v)
			setRGB(v, S.g, S.b, "colour slider")
		end)
		addSlider(tCol, "Green", "", "g", 0, 255, 1, "", function(v)
			setRGB(S.r, v, S.b, "colour slider")
		end)
		addSlider(tCol, "Blue", "", "b", 0, 255, 1, "", function(v)
			setRGB(S.r, S.g, v, "colour slider")
		end)
		addInput(tCol, "Hex code", "Like #FF3C3C.", "hexText", "#FF3C3C", function(text)
			local c = fromHex(text)
			if c then
				setRGB(c.R * 255, c.G * 255, c.B * 255, "hex")
			else
				notifyUser("not a hex colour", tostring(text) .. " - try #FF3C3C")
				syncWidgets()
			end
		end, { clearOnFocus = true })
		addToggle(tCol, "Take the axe with it", "Also writes the colour on the axe.", "axeColor",
			false, function() applyNow("axe colour") end)
		addSection(tCol, "Quick colours")
		for _, preset in ipairs(COLOR_PRESETS) do
			local p = preset
			addButton(tCol, p[1], "", function()
				setRGB(p[2], p[3], p[4], "colour preset")
			end)
		end
		addButton(tCol, "random", "Any colour at all.", function()
			setRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255), "random colour")
		end)
	end

	--======================================================== HACKS ========
	local tHack = tab("Hacks", 98998485922479)
	if tHack then
		addSection(tHack, "Speed hack (ball + axe travel multiplier)")
		addToggle(tHack, "Speed hack", "Runs every frame. 1x = off. It stands down while the TAS replays, and stays on while it records. ",
			"speedHack", false, function() applyNow("speed hack toggle") end)
		addSlider(tHack, "Multiplier", "0.1x is slow motion, 10x is a rocket.", "speedHackMult",
			0.1, 10, 0.01, "x", function() applyNow("speed hack slider") end)
		addButton(tHack, "0.1x slow motion", "", function()
			S.speedHackMult = 0.1 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "0.25x", "", function()
			S.speedHackMult = 0.25 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "0.5x", "", function()
			S.speedHackMult = 0.5 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "0.75x", "", function()
			S.speedHackMult = 0.75 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "0.99x", "", function()
			S.speedHackMult = 0.99 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "1.5x", "", function()
			S.speedHackMult = 1.5 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "2x", "", function()
			S.speedHackMult = 2 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "3x", "", function()
			S.speedHackMult = 3 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "5x", "", function()
			S.speedHackMult = 5 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "8x", "", function()
			S.speedHackMult = 8 ; syncWidgets() ; applyNow("speed preset")
		end)
		addButton(tHack, "10x", "", function()
			S.speedHackMult = 10 ; syncWidgets() ; applyNow("speed preset")
		end)

		addSection(tHack, "Infinite axe reach")
		addToggle(tHack, "Infinite reach", "Pushes the axe target the game computes from your aim further out, every frame.",
			"reachOn", false, function() applyNow("reach toggle") end)
		addSlider(tHack, "Reach multiplier", "1x leaves the axe exactly as the game made it.", "reachMult",
			1, 50, 0.5, "x", function() applyNow("reach slider") end)
		addButton(tHack, "2x", "", function()
			S.reachMult = 2 ; syncWidgets() ; applyNow("reach preset")
		end)
		addButton(tHack, "4x", "", function()
			S.reachMult = 4 ; syncWidgets() ; applyNow("reach preset")
		end)
		addButton(tHack, "8x", "", function()
			S.reachMult = 8 ; syncWidgets() ; applyNow("reach preset")
		end)
		addButton(tHack, "20x", "", function()
			S.reachMult = 20 ; syncWidgets() ; applyNow("reach preset")
		end)
		addButton(tHack, "inf (50x)", "The most the slider allows.", function()
			S.reachMult = 50 ; syncWidgets() ; applyNow("reach preset")
		end)
		addToggle(tHack, "Hitbox grows with the reach", "The axe keeps its grip on distant geometry instead of passing through it.",
			"reachHitbox", true, function() applyNow("hitbox toggle") end)
		addSection(tHack, "Anti-AFK")
		addToggle(tHack, "Stop the 20 minute idle kick",
			"When Roblox is about to kick you for being idle, send one harmless input so the timer resets. " ..
			"Off by default; if the executor refuses both ways of faking an input the script says so and does nothing.",
			"antiAfk", false, function(v)
				if v then
					local ok, mode = ANTI.poke()
					notifyUser(ok and "anti-AFK on" or "anti-AFK cannot work here", ok and ("idle pokes will use " .. tostring(mode)) or
						tostring(mode), 6)
				else
					hudLine("anti-AFK off")
				end
			end)
		addText(tHack, "Both of these run every frame, not on the 0.6 s tick",
			"They land after the game writes its own mover targets and before the physics step, which is what makes " ..
			"the speed hack visible in a recorded tape. While the TAS is testing a tape the script stays out of the " ..
			"way automatically, so a test plays at normal speed.")
	end

	--==================================================== WAYPOINTS ========
	local tWp = tab("Waypoints", 98998460561405)
	if tWp then
		addSection(tWp, "Your waypoints")
		addButton(tWp, "Save a waypoint here  (F5)", "Stores the ball's exact position, ready to jump back to.", function()
			local ok, text = WP.save()
			refreshWaypointDropdown()
			notifyUser(ok and "waypoint saved" or "not saved", text, 3)
			hudLine(text)
		end)
		addDropdown(tWp, "Waypoint", "The list grows as you save. Pick one for the buttons below.",
			"!wpPick", waypointOptions(), nil, function(sel)
				local v = type(sel) == "table" and sel[1] or sel
				S.wpIndex = indexFromOption(v) or S.wpIndex
			end)
		addButton(tWp, "Jump to it  (F6)", "Moves the ball (and the axe) there, kills the velocity and re-aims the movers.", function()
			local ok, text = WP.jumpSelected()
			notifyUser(ok and "jumped" or "no jump", text, 3)
			hudLine(text)
		end)
		addButton(tWp, "Jump to the nearest waypoint", "Handy after a fall: whatever is closest to you now.", function()
			local ok, text = WP.jumpNearest()
			notifyUser(ok and "jumped" or "no jump", text, 3)
			hudLine(text)
		end)
		addButton(tWp, "Move the selected waypoint here", "Rewrite #n to where the ball is now.", function()
			local index = tonumber(S.wpIndex) or WP.count()
			if not index or not S.waypoints[index] then
				notifyUser("nothing selected", "save a waypoint first")
				return
			end
			local pos = WP.here()
			if not pos then return end
			local entry = S.waypoints[index]
			entry.x, entry.y, entry.z = pos.X, pos.Y, pos.Z
			WP.syncMarkers()
			refreshWaypointDropdown()
			hudLine(string.format("waypoint #%d moved here", index))
		end)
		addButton(tWp, "Delete the selected waypoint", "", function()
			local index = tonumber(S.wpIndex) or WP.count()
			if WP.remove(index) then
				WP.syncMarkers()
				refreshWaypointDropdown()
				hudLine(string.format("waypoint #%d deleted", index))
			else
				notifyUser("nothing to delete", "the list is empty")
			end
		end)
		addButton(tWp, "Undo (remove the last one)  (F7 = jump back instead)", "", function()
			local ok, text = WP.undo()
			WP.syncMarkers()
			refreshWaypointDropdown()
			notifyUser(ok and "removed" or "nothing removed", text, 3)
			hudLine(text)
		end)
		addButton(tWp, "Clear every waypoint", "The map's own checkpoints are not touched.", function()
			WP.clear()
			WP.syncMarkers()
			refreshWaypointDropdown()
			notifyUser("waypoints cleared", "the list is empty again")
		end)
		addSlider(tWp, "Landing offset", "How far above the saved spot the ball is put, so it does not spawn inside the floor.",
			"wpLift", 0, 20, 0.5, " studs")
		addToggle(tWp, "Hold the spot for a moment after a jump", "Re-asserts the position for a fraction of a second: beats the game snapping you back.",
			"wpAssert", true)
		addSlider(tWp, "Hold it for", "", "wpAssertTime", 0.05, 1.5, 0.05, " s")
		addToggle(tWp, "Keep holding the spot until I switch it off",
			"Pins the ball at the landing spot every frame, for as long as this is on. The hardest the client can hold a position - " ..
			"if a jump works and then slides away, this is the switch to turn on. It stops on a level change.", "wpHold", false,
			function(v)
				if v then
					if WP.assertPos then
						WP.hold = true
						WP.assertUntil = math.huge
						notifyUser("holding the spot", "the ball is pinned where it landed until you switch this off")
					else
						notifyUser("nothing to hold yet", "jump somewhere first (F6) - then this pins you there", 5)
					end
				else
					WP.releaseHold("switch off")
					hudLine("released the spot")
				end
			end)
		addToggle(tWp, "Markers for your waypoints",
			"OFF by default: the world stays clean. On = a small neon ball + a see-through Highlight on each of YOUR waypoints " ..
			"(never on the map's checkpoints).", "wpMarkers", false, function() WP.syncMarkers() end)
		addToggle(tWp, "Labels + distance on every marker", "", "wpLabels", true)
		addToggle(tWp, "Waypoint hotkeys (F5 / F6 / F7)", "Off = the keys do nothing, so they are free for the game.",
			"wpHotkeys", true)
		addKeybind(tWp, "Save key", "Defaults to F5.", "wpSaveKey", "F5")
		addKeybind(tWp, "Jump key", "Defaults to F6.", "wpJumpKey", "F6")
		addKeybind(tWp, "Back key", "Jumps to the last crumb, or the newest waypoint if there are none. Defaults to F7.",
			"wpBackKey", "F7")
		addToggle(tWp, "Keep waypoints in the config file", "They come back when you rejoin.", "wpPersist", true)
		addText(tWp, "What a jump actually does",
			"Moves the whole player model (ball and axe together, or they get ripped apart), zeroes the velocity that " ..
			"was already carrying you towards the floor, and re-points the BodyPosition/BodyGyro the game uses to drive " ..
			"the ball - otherwise they drag you straight back.\n\n" ..
			"If a jump that used to work now does nothing, or lands you back where the game thinks you are, that is the " ..
			"server re-writing your position: turn on 'Keep holding the spot', and use the map's own checkpoints, which " ..
			"are places the game itself expects the ball to be. When that happens the script tells you (notification + log) " ..
			"rather than leaving you guessing.")
		addText(tWp, "Two things this will not do",
			"1. It will not jump you onto the FINISH pad. Landing in that zone is what submits a run time, and a " ..
			"0.2 second run is exactly what a leaderboard check is looking for. The pad is still listed (marked " ..
			"'info only') so you can see where the end is; the switch below is the only way to make it a target.\n" ..
			"2. It will not put a marker on the map's own checkpoints. A level can hold dozens of them and a sphere on " ..
			"each one buries the level you are playing, so they are a LIST here (name, kind, distance) - nothing is ever " ..
			"drawn in the world for them. Markers for your own waypoints and crumbs are the two switches above.")
		addSection(tWp, "Safety")
		addToggle(tWp, "Allow jumps onto the FINISH pad",
			"Off by default, and it is the thing that got a run flagged: the pad's touch zone is what submits your time.", "allowFinishJump", false)
		addToggle(tWp, "Refuse jumps to waypoints saved in another level",
			"A waypoint is world coordinates, so after a rejoin or a level change it can mean somewhere completely " ..
			"different. This refuses the jump and says which level it came from.", "wpLevelGuard", true)

		addSection(tWp, "The map's own checkpoints")
		addButton(tWp, "Scan the map now", "safePoints (the game's checkpoints), the split gates, the FINISH pad, the elevator.",
			function()
				local count, summary = WP.scanGame(true)
				refreshGameDropdown()
				logLine("scan finished: %s", tostring(summary))
				notifyUser("scan finished", summary, 5)
			end)
		addDropdown(tWp, "Found on this map", "Filled in by the scan (and automatically when a level loads).",
			"!gamePick", gameOptions(), nil, function(sel)
				local v = type(sel) == "table" and sel[1] or sel
				S.gameIndex = indexFromOption(v, tostring(v), "^(%d+)%.") or S.gameIndex
			end)
		addButton(tWp, "Jump to it", "Uses the game's own checkpoint instead of one you saved.", function()
			local ok, text = WP.jumpGame(S.gameIndex)
			notifyUser(ok and "jumped" or "no jump", text, 3)
			hudLine(text)
		end)
		addButton(tWp, "Jump to the nearest one", "Ignores the FINISH pad, so it never teleports you to the end.", function()
			local ok, text = WP.jumpNearestGame()
			notifyUser(ok and "jumped" or "no jump", text, 3)
			hudLine(text)
		end)
		addToggle(tWp, "Rescan when a level loads", "Watches CurrentLevel / LevelName.", "scanAuto", true)
		addToggle(tWp, "Include the speedrun split gates", "map.splits.01..NN - they are gates, not checkpoints.", "scanSplits",
			false, function()
				if #WP.points > 0 then WP.scanGame(false) end
			end)

		addSection(tWp, "Trail (auto crumbs, for climbs)")
		addToggle(tWp, "Record crumbs while you climb", "Drops a crumb every N studs of travel. Falls become cheap.",
			"trailOn", false, function() WP.syncMarkers() end)
		addSlider(tWp, "A crumb every", "", "trailSpacing", 5, 200, 1, " studs")
		addSlider(tWp, "Keep at most", "Old crumbs roll off the end.", "trailMax", 5, 120, 1, " crumbs",
			function() WP.syncMarkers() end)
		addToggle(tWp, "Markers on the crumbs too", "", "trailMarkers", true, function() WP.syncMarkers() end)
		addToggle(tWp, "Jump back by itself after a fall", "Off by default: a level that goes DOWN would trigger it.",
			"trailAuto", false)
		addSlider(tWp, "A fall deeper than", "", "trailFall", 10, 300, 5, " studs")
		addButton(tWp, "Back one crumb  (F7)", "Undo the last fall.", function()
			local ok, text = WP.trailBack()
			WP.syncMarkers()
			notifyUser(ok and "back" or "nothing to go back to", text, 3)
			hudLine(text)
		end)
		addButton(tWp, "Clear the trail", "", function()
			WP.trailClear()
			WP.syncMarkers()
			notifyUser("trail cleared", "crumbs are gone")
		end)
	end

	--======================================================= CONFIG ========
	local tCfg = tab("Config", 98998341869974)
	if tCfg then
		addSection(tCfg, "The script's own file")
		addToggle(tCfg, "Autosave", "Overwrites the same file every N seconds.", "autosave", true)
		addSlider(tCfg, "Autosave every", "", "autosaveInterval", 5, 300, 5, " s")
		addToggle(tCfg, "Restore the switch states too", "Off = the values come back but everything starts switched off.",
			"loadSwitches", true)
		addButton(tCfg, "Save now", "Writes " .. CONFIG_PATH .. ".", function()
			local ok, text = saveConfig("manual")
			hudLine(text, true)
		end)
		addButton(tCfg, "Load the file", "Reads it back and pushes every value into the window.", function()
			local ok = loadConfig()
			syncWidgets()
			applyNow("load config")
			hudLine(configStatus, true)
			notifyUser(ok and "config loaded" or "config not loaded", configStatus, 4)
		end)
		addButton(tCfg, "Reset to the defaults", "Values reset and saved. Waypoints are kept unless you clear them.",
			function()
				for key, value in pairs(DEFAULTS) do
					if type(value) ~= "table" then S[key] = value end
				end
				S.enabled = { gravity = false, material = false, color = false }
				syncWidgets()
				applyNow("config reset")
				saveConfig("reset")
				hudLine("config reset to the defaults", true)
				notifyUser("reset", "every value is back to the default")
			end)
		addText(tCfg, "This file is not Rayfield's",
			"Rayfield Gen2 can save element state on its own, but this script keeps its own file so the rules you " ..
			"asked for hold: one file, overwritten every minute, loaded again when the script is executed. " ..
			"Path: " .. CONFIG_PATH .. " (writefile/readfile permitting - on an executor without them the settings " ..
			"live in memory only and the window says so).")
		addConsole(tCfg, "config", "Config log", 120)
	end

	--========================================================= INFO ========
	local tInfo = tab("Info", 98998333308405)
	if tInfo then
		addConsole(tInfo, "status", "Live status", 66, false)
		addConsole(tInfo, "log", "Log", 150)
		addSection(tInfo, "Vanilla values")
		addButton(tInfo, "Re-read vanilla from the game", "Reads the ball/axe/gravity as they are right now and remembers them.",
			function()
				captureVanilla(true)
				applyNow("reread")
				hudLine("vanilla re-read from the live game", true)
				notifyUser("vanilla captured", string.format("gravity %s, material %s", tostring(VANILLA.gravity),
					tostring(VANILLA.ballMaterial)), 4)
			end)
		addButton(tInfo, "Force vanilla now", "Switches all three overrides off and puts the original values back.", function()
			S.enabled.gravity = false
			S.enabled.material = false
			S.enabled.color = false
			syncWidgets()
			applyNow("force vanilla")
			hudLine("back to vanilla", true)
		end)
		addText(tInfo, "What this script can and cannot do",
			"Everything here writes values your own client owns: workspace.Gravity, the ball's Material, the ball's " ..
			"Colour, and the ball's position. That works in any game, filter-enabled or not, because the client is " ..
			"allowed to say where its own ball should be and what it looks like. What it CANNOT do is change what the " ..
			"server thinks: a level that validates positions can pull the ball back, times are the server's, and the " ..
			"leaderboard is not something a client can edit. The speed hack is an extra displacement along the ball's " ..
			"own motion, which is why it looks like fast movement rather than teleporting.")
		addText(tInfo, "Keys",
			tostring(S.keyName) .. "  show / hide the window (rebindable below)\n" ..
			tostring(S.wpSaveKey) .. "  save a waypoint where the ball is\n" ..
			tostring(S.wpJumpKey) .. "  jump the ball to the selected waypoint\n" ..
			tostring(S.wpBackKey) .. "  back one crumb (or to the newest waypoint)\n" ..
			"The hotkeys are read by this script, so they work even if the Rayfield link is dead.")
		addKeybind(tInfo, "Show / hide the window", "Defaults to Right Shift.", "keyName", "RightShift")
	end

	UI.ok = true
	return true
end

-- every key syncWidgets pushes into: a widget that failed to build shows up as
-- "missing" in the report below instead of quietly doing nothing
local PUSH_KEYS = {}

-- push every value in S into the window (after a config load / a preset)
syncWidgets = function()
	local function push(key, value, skip)
		PUSH_KEYS[key] = true
		local h = UI.handles[key]
		if h and h.Set then pcall(function() h:Set(value, skip ~= false) end) end
	end
	push("gravity", S.gravity)
	push("gravityText", tostring(S.gravity))
	push("enabled.gravity", S.enabled.gravity == true)
	push("materialName", S.materialName)
	push("enabled.material", S.enabled.material == true)
	push("axeMaterial", S.axeMaterial == true)
	push("axeColor", S.axeColor == true)
	push("enabled.color", S.enabled.color == true)
	push("r", S.r)
	push("g", S.g)
	push("b", S.b)
	local c = rgbColor()
	push("hexText", toHex(c))
	local picker = UI.handles.colour
	if picker and picker.Set then pcall(function() picker:Set(c, true) end) end
	push("speedHack", S.speedHack == true)
	push("speedHackMult", S.speedHackMult)
	push("reachOn", S.reachOn == true)
	push("reachMult", S.reachMult)
	push("reachHitbox", S.reachHitbox == true)
	push("wpLift", S.wpLift)
	push("wpAssert", S.wpAssert == true)
	push("wpAssertTime", S.wpAssertTime)
	push("wpHold", S.wpHold == true)
	push("wpLevelGuard", S.wpLevelGuard == true)
	push("allowFinishJump", S.allowFinishJump == true)
	push("antiAfk", S.antiAfk == true)
	push("wpMarkers", S.wpMarkers == true)
	push("wpLabels", S.wpLabels == true)
	push("wpHotkeys", S.wpHotkeys == true)
	push("wpPersist", S.wpPersist == true)
	push("trailOn", S.trailOn == true)
	push("trailSpacing", S.trailSpacing)
	push("trailMax", S.trailMax)
	push("trailMarkers", S.trailMarkers == true)
	push("trailAuto", S.trailAuto == true)
	push("trailFall", S.trailFall)
	push("scanAuto", S.scanAuto == true)
	push("scanSplits", S.scanSplits == true)
	push("autosave", S.autosave == true)
	push("autosaveInterval", S.autosaveInterval)
	push("loadSwitches", S.loadSwitches == true)
	refreshWaypointDropdown()
	refreshGameDropdown()
	if S.wpMarkers then WP.syncMarkers() end
end

-- what the window ended up looking like (and what it could not build)
local function uiReport()
	if not UI.window then
		-- with no window there is nothing to be missing: that is what noWindow says
		return { built = false, window = false, tabs = 0, elements = 0, pushed = 0, missing = {}, noWindow = true }
	end
	local missing, pushed = {}, 0
	for key in pairs(PUSH_KEYS) do
		pushed = pushed + 1
		if not UI.handles[key] then missing[#missing + 1] = key end
	end
	table.sort(missing)
	local elements, tabs = 0, 0
	for _ in pairs(UI.handles) do elements = elements + 1 end
	for _ in pairs(UI.tabs) do tabs = tabs + 1 end
	return {
		built = UI.ok == true,
		window = UI.window ~= nil,
		tabs = tabs,
		elements = elements,
		pushed = pushed,
		missing = missing,
	}
end

--============================================================================
-- 7. WINDOW BEHAVIOUR + HOTKEYS
--     The keys are read here rather than through Rayfield's keybind elements,
--     so they keep working when the menu itself could not load.
--============================================================================
local function setVisible(v)
	S.uiVisible = v and true or false
	if UI.window then
		if S.uiVisible then
			pcall(function() UI.window:Show() end)
		else
			pcall(function() UI.window:Hide() end)
		end
	end
end

local function keyNameOf(input)
	local k = input and input.KeyCode
	if k and k ~= Enum.KeyCode.Unknown then return k.Name end
	return nil
end

local function typing()
	local ok, box = pcall(function() return UIS:GetFocusedTextBox() end)
	return ok and box ~= nil
end

local keyConnection = UIS.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local name = keyNameOf(input)
	if not name then return end
	if typing() then return end

	if name == S.keyName then
		setVisible(not S.uiVisible)
		return
	end
	if not S.wpHotkeys then return end
	if name == S.wpSaveKey then
		local ok, text = WP.save()
		WP.syncMarkers()
		refreshWaypointDropdown()
		notifyUser(ok and "waypoint saved" or "not saved", text, 3)
		hudLine(text)
	elseif name == S.wpJumpKey then
		local ok, text = WP.jumpSelected()
		notifyUser(ok and "jumped" or "no jump", text, 3)
		hudLine(text)
	elseif name == S.wpBackKey then
		local ok, text = WP.trailBack()
		WP.syncMarkers()
		notifyUser(ok and "back" or "nowhere to go", text, 3)
		hudLine(text)
	end
end)

--============================================================================
-- 8. THE STATUS LINE  (what the Info tab shows on every tick)
--============================================================================
local lastStatusShown = ""

local function statusText()
	local ball = wpBall()
	local pos = ball and ball.Position or nil
	local where = pos and string.format("(%.0f, %.0f, %.0f)", pos.X, pos.Y, pos.Z) or "not spawned"
	local wpExtra = ""
	if WP.hold and WP.assertPos then
		wpExtra = string.format(" | HOLDING (%.0f, %.0f, %.0f)", WP.assertPos.X, WP.assertPos.Y, WP.assertPos.Z)
	end
	local anti = S.antiAfk and ("anti-AFK on" .. (ANTI.mode and (" (" .. ANTI.mode .. ")") or "")) or "anti-AFK off"
	return string.format("%s\nball %s | %s\nsaved %d | crumbs %d | map points %d%s\n%s | %s\n%s | %s",
		tostring(lastStatus),
		where,
		tostring(hackStatus),
		WP.count(), WP.trailCount(), #WP.points, wpExtra,
		tostring(configStatus),
		tostring(S.keyName) .. " = window",
		anti,
		tostring(S.wpJumpKey) .. " jump / " .. tostring(S.wpSaveKey) .. " save / " .. tostring(S.wpBackKey) .. " back")
end

local function pushStatus(force)
	local text = statusText()
	if text == lastStatusShown and not force then return end
	lastStatusShown = text
	if UI.consoles.status then
		pcall(function() UI.consoles.status:Set(text) end)
	end
end

--============================================================================
-- 9. MAIN LOOP
--============================================================================
local accumulator = 0
local running = true
local autosaveAccumulator = 0
local uiBuilt = false

local heartbeat
heartbeat = RunService.Heartbeat:Connect(function(dt)
	if not running then return end

	-- config autosave: one file, overwritten every autosaveInterval seconds
	if S.autosave then
		autosaveAccumulator = autosaveAccumulator + dt
		if autosaveAccumulator >= (S.autosaveInterval or 60) then
			autosaveAccumulator = 0
			pcall(function()
				local ok, text = saveConfig("auto")
				if not ok then logLine("autosave: " .. tostring(text)) end
			end)
		end
	end

	accumulator = accumulator + dt
	if accumulator < (S.interval or 0.6) then
		pushStatus(false)
		return
	end
	accumulator = 0
	local ok, err = pcall(applyNow, "tick")
	if not ok then
		logLine("apply error: " .. tostring(err))
	end
	pcall(WP.tickSlow)
	pcall(WP.levelWatch)
	pushStatus(false)
end)

-- the idle kick: one connection, always there, only acts when the switch is on
local antiConnection
antiConnection = LocalPlayer.Idled:Connect(function()
	if not running then return end
	if not S.antiAfk then return end
	pcall(ANTI.handle)
end)

-- the frame-rate work: the two game hacks, the waypoint re-assert, the trail
-- and the fall watchdog. It has to be smooth, and running here means it lands
-- after the game wrote its mover targets and before the physics step - which
-- is also why a TAS recording captures the hacks.
local hackConnection
hackConnection = RunService.RenderStepped:Connect(function(dt)
	if not running then return end
	if S.speedHack or S.reachOn or reachApplied then
		local ok, err = pcall(applyHacks, dt)
		if not ok then
			hackStatus = "hack error: " .. tostring(err)
		end
	end
	if WP.assertPos or S.trailOn or S.trailAuto then
		pcall(WP.tickFast, dt)
	end
end)

-- instant first application + vanilla capture. The saved config is loaded first,
-- so the switch states and every value from your last session come back.
-- GUI first: everything below reports into it
if Rayfield then
	local okUI, errUI = pcall(buildUI)
	uiBuilt = okUI and UI.ok == true
	if not okUI then
		logLine("building the window failed: " .. tostring(errUI))
	end
else
	logLine("Rayfield Gen2 could not be loaded (%s)", tostring(rayfieldError or "no loadstring"))
end

pcall(function()
	loadConfig()
	if syncWidgets then syncWidgets() end
	captureVanilla(false)
	applyNow("startup")
	if S.scanAuto then
		task.defer(function() pcall(WP.scanGame, false) end)
	end
	if S.wpMarkers or S.trailMarkers then WP.syncMarkers() end
end)

if uiBuilt then
	notifyUser("Ball Tweaks " .. tostring(S.keyName) .. " = window",
		"Gravity, material, colour, the speed hack, infinite reach and waypoints (F5 save / F6 jump / F7 back).", 6)
else
	logLine("no window: hotkeys only - %s = show/hide was skipped, F5/F6/F7 still work",
		tostring(S.keyName))
end
pushStatus(true)

--============================================================================
-- 10. PUBLIC HANDLE
--============================================================================
local API
API = {
	state = S,
	vanilla = VANILLA,
	apply = applyNow,
	applyHacks = applyHacks,
	hackStatus = function() return hackStatus end,
	captureVanilla = captureVanilla,
	saveConfig = saveConfig,
	loadConfig = loadConfig,
	configPath = CONFIG_PATH,
	setVisible = function(v) setVisible(v) end,
	notify = function(title, content, duration) return notifyUser(title, content, duration) end,
	log = function(...) return logLine(...) end,
	status = function() return statusText() end,
	ui = UI,
	uiReport = uiReport,
	syncWidgets = function() syncWidgets() end,
	-- ---- waypoints ----
	waypoints = WP,
	saveWaypoint = function(name) return WP.add(nil, name) end,
	removeWaypoint = function(i) return WP.remove(i) end,
	clearWaypoints = function() return WP.clear() end,
	listWaypoints = function() return S.waypoints end,
	jumpTo = function(i)
		local entry = S.waypoints[tonumber(i) or 0]
		if not entry then return false, "no such waypoint" end
		return WP.jump(entry, "api")
	end,
	jumpToPoint = function(pos, lift) return WP.jump({ x = pos.X, y = pos.Y, z = pos.Z }, "api", lift) end,
	scanMap = function(verbose) return WP.scanGame(verbose) end,
	mapPoints = function() return WP.points end,
	finishNear = function(pos, radius) return WP.finishNear(pos or WP.here(), radius) end,
	releaseHold = function(reason) return WP.releaseHold(reason) end,
	holding = function() return WP.hold == true, WP.assertPos end,
	idlePoke = function() return ANTI.poke() end,
	trail = function() return S.trail end,
	trailCount = function() return WP.trailCount() end,
	clearTrail = function() return WP.trailClear() end,
	crumbing = function() return WP.trailBack() end,
	markers = function() return WP.markers end,
	destroy = function()
		running = false
		if heartbeat then pcall(function() heartbeat:Disconnect() end) end
		if hackConnection then pcall(function() hackConnection:Disconnect() end) end
		if keyConnection then pcall(function() keyConnection:Disconnect() end) end
		if antiConnection then pcall(function() antiConnection:Disconnect() end) end
		pcall(WP.clearMarkers)
		if UI.window then pcall(function() UI.window:Unload() end) end
		_G.__BALLTWEAKS = nil
	end,
}

_G.__BALLTWEAKS = API
return API
