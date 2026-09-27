-- Settings and privilege levels

local S = luabots.S
local settings = core.settings

local function num(key, default, min, max)
	local v = tonumber(settings:get("luabots." .. key)) or default
	if min and v < min then v = min end
	if max and v > max then v = max end
	return v
end

local function bool(key, default)
	return settings:get_bool("luabots." .. key, default)
end

local function str(key, default)
	local v = settings:get("luabots." .. key)
	if v == nil or v == "" then return default end
	return v
end

local config = {}
luabots.config = config

-- Global limits
config.max_slices_per_step = num("max_slices_per_step", 60, 1, 10000)
config.step_time_budget = num("step_time_budget_ms", 25, 1, 1000) / 1000
config.hard_limit_factor = num("hard_limit_factor", 5, 1, 100)
config.global_memory_mb = num("global_memory_mb", 1024, 64)
config.max_string_kb = num("max_string_kb", 1024, 16)
config.autostart = bool("autostart", true)

-- Idle robots are switched off to save server time (not admin robots)
config.idle_radius = num("idle_radius", 48, 0, 10000)
config.idle_seconds = num("idle_seconds", 60, 1, 86400)
config.stop_when_offline = bool("stop_when_offline", true)
config.save_interval = num("save_interval", 10, 1, 600)

-- Timing of physical actions (seconds, before the level speed multiplier)
config.move_time = num("move_time", 0.3, 0.05, 10)
config.turn_time = num("turn_time", 0.15, 0, 10)
config.place_time = num("place_time", 0.25, 0.05, 10)
config.dig_time_factor = num("dig_time_factor", 1.0, 0.1, 10)

-- Energy: digging (and optionally moving/placing) costs energy, obtained by burning fuel from the robot inventory
config.energy = bool("energy", true)
config.dig_energy = num("dig_energy", 1, 0, 1000)
config.move_energy = num("move_energy", 0, 0, 1000)
config.place_energy = num("place_energy", 0, 0, 1000)
config.auto_refuel = bool("auto_refuel", true)

-- Communication
config.chat_radius = num("chat_radius", 32, 1, 1000)
config.say_interval = num("say_interval", 1.0, 0, 60)
config.form_radius = num("form_radius", 16, 1, 1000)
-- Windows robots open to other players: paused after the player closes one (per robot owner) and while the player is fighting
config.form_close_pause = num("form_close_pause", 60, 0, 600)
config.form_combat_pause = num("form_combat_pause", 60, 0, 600)
-- Sounds: robots can play any sound of the loaded mods (like basic_robot)
config.game_sounds = bool("game_sounds", true)
config.sounds_per_second = num("sounds_per_second", 40, 1, 200)
config.particles_per_second = num("particles_per_second", 20, 0, 200)
config.sound_distance = num("sound_distance", 24, 1, 64)
-- Lowest level that can place keyboard keys (they cost nothing, so by default normal players cannot fill the world with them)
config.keyboard_level = str("keyboard_level", "advanced")
if config.keyboard_level ~= "player" and config.keyboard_level ~= "advanced"
		and config.keyboard_level ~= "admin" then
	config.keyboard_level = "advanced"
end

-- Combat: "off", "mobs" or "all"
config.combat = str("combat", "mobs")
if config.combat ~= "off" and config.combat ~= "mobs" and config.combat ~= "all" then
	config.combat = "mobs"
end
config.mortal = bool("mortal", false)
config.robot_hp = num("robot_hp", 20, 1, 1000)

-- Admin features
config.allow_admin_commands = bool("allow_admin_commands", false)
-- Robots of owners with luabots_admin and this privilege get the real server API (core, _G...): they can write mods live. "" disables it.
config.full_access_priv = str("full_access_priv", "server")

-- Safety: node lists ("mod:node", "mod:*" or "group:name", comma separated)
function luabots.parse_node_list(text)
	local list = {names = {}, prefixes = {}, groups = {}}
	for entry in (text or ""):gmatch("[^,%s]+") do
		if entry:sub(1, 6) == "group:" then
			list.groups[#list.groups + 1] = entry:sub(7)
		elseif entry:sub(-2) == ":*" then
			list.prefixes[#list.prefixes + 1] = entry:sub(1, -2)
		else
			list.names[entry] = true
		end
	end
	return list
end

function luabots.node_in_list(list, name)
	if list.names[name] then return true end
	for _, prefix in ipairs(list.prefixes) do
		if name:sub(1, #prefix) == prefix then return true end
	end
	for _, group in ipairs(list.groups) do
		if core.get_item_group(name, group) > 0 then return true end
	end
	return false
end

config.no_dig = luabots.parse_node_list(str("no_dig", ""))
config.no_inventory = luabots.parse_node_list(str("no_inventory", ""))
config.visible_lists_only = bool("visible_lists_only", true)

-- Entries may be aliases: also list what they point to
core.register_on_mods_loaded(function()
	for _, list in ipairs({config.no_dig, config.no_inventory}) do
		for name in pairs(table.copy(list.names)) do
			local target = core.registered_aliases[name]
			if target then list.names[target] = true end
		end
	end
end)

-- Privileges
core.register_privilege("luabots", {
	description = S("Advanced LuaBots user: more robots and higher limits"),
	give_to_singleplayer = false,
})
core.register_privilege("luabots_admin", {
	description = S("LuaBots administrator: highest limits and admin robot functions"),
	give_to_singleplayer = true,
	give_to_admin = true,
})

-- Levels. Everything a robot can do is decided by its owner's level, which is checked again on every action (privilege changes apply at once).
local function level(name, label, defaults)
	local l = {name = name, label = label}
	for key, def in pairs(defaults) do
		l[key] = num(name .. "_" .. key, def, 0)
	end
	return l
end

config.levels = {
	player = level("player", S("Player"), {
		max_bases = 20, -- robot bases a player may own (0 = unlimited)
		max_running = 3, -- robots running at the same time (run IDs 1..n)
		instructions = 20000, -- instructions per tick before auto pause
		memory_mb = 8, -- memory a program may allocate per tick
		range = 24, -- max distance from the robot base
		sense_radius = 8, -- radius for sensing objects / nodes
		code_kb = 32, -- max program size
		storage_kb = 64, -- persistent storage size
		speed = 1, -- action speed multiplier
	}),
	advanced = level("advanced", S("Advanced"), {
		max_bases = 100,
		max_running = 10,
		instructions = 100000,
		memory_mb = 32,
		range = 64,
		sense_radius = 16,
		code_kb = 128,
		storage_kb = 256,
		speed = 1.5,
	}),
	admin = level("admin", S("Admin"), {
		max_bases = 0,
		max_running = 50,
		instructions = 500000,
		memory_mb = 128,
		range = 512,
		sense_radius = 32,
		code_kb = 512,
		storage_kb = 0, -- no limit
		speed = 3,
	}),
}
config.levels.player.rank = 1
config.levels.advanced.rank = 2
config.levels.admin.rank = 3
for _, l in pairs(config.levels) do
	l.max_running = math.max(1, math.floor(l.max_running))
	l.max_bases = math.max(0, math.floor(l.max_bases))
end

-- Returns the level table of a player (works for offline players too)
function luabots.get_level(owner)
	local privs = core.get_player_privs(owner or "")
	if privs.luabots_admin then
		return config.levels.admin
	elseif privs.luabots then
		return config.levels.advanced
	end
	return config.levels.player
end

function luabots.is_admin(name)
	return core.check_player_privs(name, {luabots_admin = true})
end
