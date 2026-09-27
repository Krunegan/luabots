-- Core API: print, sleep, yield, time, robot.*, storage.*

local config = luabots.config
local util = luabots.util
local sandbox = luabots.sandbox

local SOUNDS = {beep = true, boop = true, ok = true, error = true, step = true}

-- Every sound of the loaded mods ("default_dig_cracky" for the files default_dig_cracky.ogg, default_dig_cracky.1.ogg...), found once
local game_sounds, sound_list
local function find_sounds()
	if game_sounds then return end
	game_sounds, sound_list = {}, {}
	for _, mod in ipairs(core.get_modnames()) do
		local dir = core.get_modpath(mod) .. "/sounds"
		for _, file in ipairs(core.get_dir_list(dir, false) or {}) do
			local name = file:match("^(.-)%.ogg$")
			name = name and (name:match("^(.-)%.%d+$") or name)
			if name and not game_sounds[name] then
				game_sounds[name] = true
				sound_list[#sound_list + 1] = name
			end
		end
	end
	table.sort(sound_list)
end

-- Sounds and particles of the robots of each owner in the current second
local owner_sounds, owner_particles = {}, {}
local MAX_HANDLES = 64 -- sounds robot.sound_stop can still stop
local PARTICLES_SERVER = 200 -- particles per second of all robots together
local PARTICLE_DISTANCE = 32 -- only players this close receive them

-- File of a sound name ("beep" -> luabots_beep); admins can always use game sounds
function luabots.resolve_sound(name, admin)
	util.check_string(name, "name", 100)
	if SOUNDS[name] then return "luabots_" .. name end
	find_sounds()
	if not config.game_sounds and not admin then
		util.api_error("unknown sound (use beep, boop, ok, error or step; game sounds are disabled)")
	elseif not game_sounds[name] then
		util.api_error("unknown sound '" .. name .. "' (see robot.sounds())")
	end
	return name
end

-- Remember a sound so robot.sound_stop and the end of the program can stop it
function luabots.track_sound(st, handle)
	if not handle then return end
	local list = st.sound_handles or {}
	st.sound_handles = list
	list[#list + 1] = handle
	-- forget (not stop) the oldest: short notes end by themselves
	if #list > MAX_HANDLES then table.remove(list, 1) end
end

local function per_second(counts, owner, max)
	local second = math.floor(luabots.now())
	local used = counts[owner]
	if not used or used.second ~= second then
		used = {second = second, n = 0}
		counts[owner] = used
	end
	if used.n >= max then return false end
	used.n = used.n + 1
	return true
end
luabots.SKINS = {
	{name = "steel", color = "#8e959e"},
	{name = "ruby", color = "#a8443c"},
	{name = "emerald", color = "#4a8f5c"},
	{name = "sapphire", color = "#4a6fa8"},
	{name = "gold", color = "#c8963a"},
	{name = "violet", color = "#7a5ab0"},
}

luabots.register_api(function(bot, env)
	local rec, st = bot.rec, bot.state
	local wrap = bot.wrap
	local PAUSE = sandbox.PAUSE
	local c_yield = coroutine.yield
	local tostring, select, concat = tostring, select, table.concat

	-- print: arguments are converted inside the program (tostring may call the program's own __tostring), then handed to the trusted side.
	local console_print = wrap("print", function(text)
		luabots.console(rec.id, text)
	end, 50)
	env.print = function(...)
		local n = select("#", ...)
		local parts = {}
		for i = 1, n do
			parts[i] = tostring((select(i, ...)))
		end
		local text = concat(parts, "\t")
		if #text > 2000 then text = text:sub(1, 2000) .. "..." end
		return console_print(text)
	end

	-- Text with a color, for robot.label (like core.colorize)
	env.colorize = wrap("colorize", function(color, text)
		color = util.check_color(color, "color")
		text = util.check_string(tostring(text), "text", 1000)
		return core.colorize(color, text)
	end, 5)

	env.sleep = wrap("sleep", function(seconds)
		seconds = util.check_number(seconds or 0, "seconds", 0, 86400)
		bot.sleep(seconds)
	end)

	env.yield = function()
		c_yield(PAUSE)
	end

	local started = luabots.now()
	env.time = wrap("time", function()
		return luabots.now() - started
	end, 5)

	-- robot.* 
	local R = {}
	env.robot = R

	R.id = function() return rec.id end
	R.name = wrap("robot.name", function() return rec.name end, 5)
	R.run_id = wrap("robot.run_id", function() return rec.slot or 1 end, 5)
	R.owner = wrap("robot.owner", function() return rec.owner end, 5)
	R.level = wrap("robot.level", function() return bot.level.name end, 5)
	R.limits = wrap("robot.limits", function()
		local l = bot.level
		return {
			level = l.name, instructions = l.instructions, memory_mb = l.memory_mb,
			range = l.range, sense_radius = l.sense_radius, code_kb = l.code_kb,
			storage_kb = l.storage_kb, speed = l.speed,
			max_running = l.max_running, max_bases = l.max_bases,
		}
	end)
	R.pos = wrap("robot.pos", function() return util.plain_pos(rec.pos) end, 5)
	R.home = wrap("robot.home", function() return util.plain_pos(rec.home) end, 5)
	R.facing = wrap("robot.facing", function()
		local f = rec.facing % 4
		return util.facing_names[f], util.plain_pos(util.facing_vectors[f])
	end, 5)
	R.energy = wrap("robot.energy", function() return rec.energy or 0 end, 5)

	R.label = wrap("robot.label", function(text)
		-- 80 visible characters; colors from colorize() are kept
		text = util.clean_colored(util.check_string(text or "", "text", 4000), 80)
		rec.label = text
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
	end)

	R.skin = wrap("robot.skin", function(n)
		n = math.floor(util.check_number(n, "skin", 1, #luabots.SKINS))
		rec.skin = n
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
	end)

	R.size = wrap("robot.size", function(s)
		local max = bot.level.name == "admin" and 3 or 1.5
		rec.size = util.check_number(s, "size", 0.5, max)
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
	end)

	-- robot.sound(name, gain, pitch): beep, boop, ok, error, step or any sound of the loaded mods ("default_dig_cracky", "mesecons_noteblock_c"...)
	-- (admins: no limit; admin.sound plays for the whole server)
	R.sound = wrap("robot.sound", function(name, gain, pitch)
		local admin = bot.level.name == "admin"
		local file = luabots.resolve_sound(name, admin)
		gain = util.check_number(gain or 1, "gain", 0, 1)
		pitch = util.check_number(pitch or 1, "pitch", 0.25, 4)
		if not admin and not per_second(owner_sounds, rec.owner, config.sounds_per_second) then
			return false, "too many sounds"
		end
		luabots.track_sound(st, core.sound_play(file, {pos = rec.pos, gain = gain, pitch = pitch,
			max_hear_distance = config.sound_distance}))
		return true
	end)

	-- robot.particle(texture, size, colour): a particle rising from the robot (texture of any mod, e.g. "notepart.png"; no texture modifiers)
	-- (admins: no limits and any texture; admin.particle has every option)
	R.particle = wrap("robot.particle", function(texture, size, colour)
		local admin = bot.level.name == "admin"
		util.check_string(texture, "texture", admin and 4096 or 100)
		if not admin and not texture:match("^[%w_%-]+%.png$") then
			util.api_error("texture must be a file name like 'default_dirt.png'")
		end
		size = util.check_number(size or 3, "size", 0.5, admin and 100 or 8)
		if colour ~= nil then
			util.check_string(colour, "colour", 20)
			if not colour:match("^#%x+$") and not colour:match("^%a+$") then
				util.api_error("colour must be like '#ff8800' or 'red'")
			end
			texture = texture .. "^[multiply:" .. colour
		end
		if not admin and (not per_second(owner_particles, rec.owner, config.particles_per_second)
				or not per_second(owner_particles, "", PARTICLES_SERVER)) then
			return false, "too many particles"
		end
		-- one short particle, sent only to the players near the robot (not to everyone)
		local def = {
			pos = vector.offset(rec.pos, (math.random() - 0.5) * 0.4, 0.6, (math.random() - 0.5) * 0.4),
			velocity = {x = (math.random() - 0.5) * 0.3, y = 1, z = (math.random() - 0.5) * 0.3},
			expirationtime = 1.2,
			size = size,
			texture = texture,
			glow = 8,
		}
		for _, player in ipairs(core.get_connected_players()) do
			if vector.distance(player:get_pos(), rec.pos) <= PARTICLE_DISTANCE then
				def.playername = player:get_player_name()
				core.add_particle(def)
			end
		end
		return true
	end)

	-- robot.sound_stop(): stop the sounds of this robot that are still playing
	R.sound_stop = wrap("robot.sound_stop", function()
		for _, h in ipairs(st.sound_handles or {}) do core.sound_stop(h) end
		st.sound_handles = nil
		return true
	end)

	-- robot.sounds(filter): names of the sounds that robot.sound can play
	R.sounds = wrap("robot.sounds", function(filter)
		if filter ~= nil then util.check_string(filter, "filter", 100) end
		find_sounds()
		local out = {}
		for name in pairs(SOUNDS) do
			if not filter or name:find(filter, 1, true) then out[#out + 1] = name end
		end
		if config.game_sounds then
			for _, name in ipairs(sound_list) do
				if not filter or name:find(filter, 1, true) then
					out[#out + 1] = name
					if #out >= 500 then break end
				end
			end
		end
		return out
	end, 100)

	R.stop = wrap("robot.stop", function()
		luabots.stop(rec, "stopped")
		sandbox.wait(bot.ctx, 1e9)
	end)

	R.hp = wrap("robot.hp", function()
		local body = bot.body()
		return body and body:get_hp() or 0
	end, 5)

	R.used = wrap("robot.used", function()
		return bot.ctx.used
	end, 1)

	-- storage.* : persistent key/value store
	local ST = {}
	env.storage = ST
	rec.data = rec.data or {}

	local function data_size()
		return #core.serialize(rec.data)
	end

	ST.get = wrap("storage.get", function(key)
		util.check_string(key, "key", 128)
		local v = rec.data[key]
		if type(v) == "table" then return util.copy_data(v, 1e9) end
		return v
	end)

	ST.set = wrap("storage.set", function(key, value)
		util.check_string(key, "key", 128)
		-- storage_kb 0: no limit (admins by default)
		local limit = bot.level.storage_kb > 0 and bot.level.storage_kb * 1024 or math.huge
		local copy = util.sanitize(value, {left = limit})
		local old = rec.data[key]
		rec.data[key] = copy
		if limit < math.huge and data_size() > limit then
			rec.data[key] = old
			util.api_error(("storage full (max %d KB)"):format(bot.level.storage_kb))
		end
		luabots.mark_dirty(rec.id)
	end, 200)

	ST.keys = wrap("storage.keys", function()
		local out = {}
		for k in pairs(rec.data) do out[#out + 1] = k end
		table.sort(out)
		return out
	end)

	ST.clear = wrap("storage.clear", function()
		rec.data = {}
		luabots.mark_dirty(rec.id)
	end)
end)