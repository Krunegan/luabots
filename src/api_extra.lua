-- Extra API: path finding (path.*, move.to), combat.*, admin.*

local config = luabots.config
local util = luabots.util

local SEARCH_LIMIT = {player = 2000, advanced = 8000, admin = 30000}

-- A* over passable nodes. Robots fly, so all 6 neighbours are valid moves.
local NEIGHBOURS = {
	vector.new(1, 0, 0), vector.new(-1, 0, 0), vector.new(0, 0, 1),
	vector.new(0, 0, -1), vector.new(0, 1, 0), vector.new(0, -1, 0),
}

local function heap_push(h, item, prio)
	local i = #h + 1
	h[i] = {item, prio}
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p][2] <= h[i][2] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end

local function heap_pop(h)
	local top = h[1]
	if not top then return nil end
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r = 2 * i, 2 * i + 1
			local m = i
			if h[l] and h[l][2] < h[m][2] then m = l end
			if h[r] and h[r][2] < h[m][2] then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]
			i = m
		end
	end
	return top[1]
end

-- Returns list of positions (excluding start) or nil, reason
function luabots.find_path(bot, start, goal, limit)
	local hash = core.hash_node_position
	local function passable(p)
		if not bot.in_range(p) then return false end
		local n = core.get_node_or_nil(p)
		if not util.is_passable(n) then return false end
		return not luabots.robot_at(p, bot.rec.id)
	end
	if not passable(goal) then return nil, "goal blocked" end
	local function h(p)
		return math.abs(p.x - goal.x) + math.abs(p.y - goal.y) + math.abs(p.z - goal.z)
	end
	local open = {}
	local came = {}
	local cost = {[hash(start)] = 0}
	local nodes = {[hash(start)] = start}
	heap_push(open, start, h(start))
	local expanded = 0
	local goal_h = hash(goal)
	while true do
		local cur = heap_pop(open)
		if not cur then return nil, "no path" end
		local ch = hash(cur)
		if ch == goal_h then
			local path = {}
			while ch ~= hash(start) do
				table.insert(path, 1, nodes[ch])
				ch = came[ch]
			end
			return path, expanded
		end
		expanded = expanded + 1
		if expanded > limit then return nil, "too far (search limit reached)" end
		for _, off in ipairs(NEIGHBOURS) do
			local np = vector.add(cur, off)
			local nh = hash(np)
			local nc = cost[ch] + 1
			if (cost[nh] == nil or nc < cost[nh]) and passable(np) then
				cost[nh] = nc
				came[nh] = ch
				nodes[nh] = np
				heap_push(open, np, nc + h(np))
			end
		end
	end
end

-- Which relative move reaches 'to' from 'from' for a given facing
local function step_direction(rec, to)
	local d = vector.subtract(to, rec.pos)
	if d.y == 1 then return "up" end
	if d.y == -1 then return "down" end
	for _, dir in ipairs({"forward", "back", "left", "right"}) do
		if vector.equals(util.dir_offset(rec.facing, dir), d) then return dir end
	end
	return nil
end

-- Combat

local function can_attack(bot, obj)
	if config.combat == "off" then return false, "combat is disabled on this server" end
	if obj:is_player() then
		if config.combat ~= "all" then return false, "attacking players is disabled" end
		if not core.settings:get_bool("enable_pvp", true) then return false, "PvP is disabled" end
		if obj:get_player_name() == bot.rec.owner then return false, "cannot attack owner" end
		if core.is_protected(vector.round(obj:get_pos()), bot.rec.owner) then
			return false, "target is in a protected area"
		end
		return true
	end
	local ent = obj:get_luaentity()
	if not ent then return false, "invalid target" end
	if ent.name == "__builtin:item" or ent.name == "luabots:robot" then
		return false, "invalid target"
	end
	local armor = obj:get_armor_groups()
	if armor.immortal and armor.immortal > 0 then return false, "target is immortal" end
	return true
end

local ATTACK_RANGE = 3

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec = bot.rec

	-- path.*
	local path = {}
	env.path = path

	local function limit()
		return SEARCH_LIMIT[bot.level.name] or 2000
	end

	path.find = wrap("path.find", function(goal)
		goal = util.check_pos(goal, "goal")
		local p, info = luabots.find_path(bot, rec.pos, goal, limit())
		if type(info) == "number" then bot.ctx.used = bot.ctx.used + info * 20 end
		if not p then return nil, info end
		local out = {}
		for i, v in ipairs(p) do out[i] = util.plain_pos(v) end
		return out
	end, 200)

	-- move.to(goal): walk there, turning as needed
	if env.move then
		env.move.to = wrap("move.to", function(goal)
			goal = util.check_pos(goal, "goal")
			for _ = 1, 4 do -- retry if something blocks the path on the way
				if vector.equals(rec.pos, goal) then return true end
				local p, info = luabots.find_path(bot, rec.pos, goal, limit())
				if type(info) == "number" then bot.ctx.used = bot.ctx.used + info * 20 end
				if not p then return false, info end
				local blocked = false
				for _, step in ipairs(p) do
					local dir = step_direction(rec, step)
					if not dir then blocked = true break end
					local ok = luabots.do_move(bot, dir)
					if not ok then blocked = true break end
				end
				if not blocked then return vector.equals(rec.pos, goal) end
			end
			return false, "path blocked"
		end, 300)
	end

	-- combat.*
	local combat = {}
	env.combat = combat

	combat.attack = wrap("combat.attack", function(target)
		if target ~= nil then util.check_string(target, "target", 100) end
		local body = bot.body()
		if not body then return false, "no body" end
		local best, best_d
		for _, obj in ipairs(core.get_objects_inside_radius(rec.pos, ATTACK_RANGE)) do
			if obj ~= body then
				local match
				if target == nil then
					match = not obj:is_player()
				elseif obj:is_player() then
					match = obj:get_player_name() == target
				else
					local ent = obj:get_luaentity()
					match = ent and ent.name == target
				end
				if match and can_attack(bot, obj) then
					local d = vector.distance(obj:get_pos(), rec.pos)
					if not best_d or d < best_d then best, best_d = obj, d end
				end
			end
		end
		if not best then
			if target then
				for _, obj in ipairs(core.get_objects_inside_radius(rec.pos, ATTACK_RANGE)) do
					if obj ~= body and (obj:is_player() and obj:get_player_name() == target) then
						local _, why = can_attack(bot, obj)
						return false, why
					end
				end
			end
			return false, "no target in range"
		end
		local inv = luabots.get_inventory(rec)
		local tool = inv:get_stack("tool", 1)
		local caps = tool:get_tool_capabilities()
		local dir = vector.direction(rec.pos, best:get_pos())
		best:punch(body, 1.0, caps, dir)
		if not tool:is_empty() and not core.is_creative_enabled(rec.owner) then
			local hp = core.get_hit_params(best:get_armor_groups(), caps, 1.0, tool:get_wear())
			if hp and hp.wear then
				tool:add_wear(hp.wear)
				inv:set_stack("tool", 1, tool)
				luabots.mark_dirty(rec.id)
			end
		end
		bot.act(0.6)
		return true
	end, 200)

	combat.hp = wrap("combat.hp", function()
		local b = bot.body()
		return b and b:get_hp() or 0
	end, 5)

	-- admin.* : only for owners with the luabots_admin privilege
	local admin = {}
	env.admin = admin

	local function require_admin(what)
		if bot.level.name ~= "admin" then
			util.api_error(what .. " requires the luabots_admin privilege")
		end
	end

	local function log(action)
		core.log("action", ("[luabots] admin robot %s (%s): %s"):format(
			luabots.display_name(rec), rec.id, action))
	end

	admin.is_admin = wrap("admin.is_admin", function()
		return bot.level.name == "admin"
	end, 5)

	-- admin.sound(name, gain, pitch, to): to = nil (every player, at full volume wherever they are), a player name, or a distance from the robot
	admin.sound = wrap("admin.sound", function(name, gain, pitch, to)
		require_admin("admin.sound")
		local file = luabots.resolve_sound(name, true)
		local params = {
			gain = util.check_number(gain or 1, "gain", 0, 10),
			pitch = util.check_number(pitch or 1, "pitch", 0.1, 10),
		}
		if type(to) == "string" then
			if not core.get_player_by_name(to) then return false, "player not online" end
			params.to_player = to
		elseif type(to) == "number" then
			params.pos = rec.pos
			params.max_hear_distance = util.check_number(to, "distance", 1, 1e6)
		elseif to ~= nil then
			util.api_error("to must be nil (everyone), a player name or a distance")
		end
		luabots.track_sound(bot.state, core.sound_play(file, params))
		return true
	end, 20)

	-- Particle definitions from programs: plain data only, near the robot by default
	local function particle_def(def, spawner)
		if type(def) ~= "table" then util.api_error("particle definition (table) expected") end
		def = util.copy_data(def, 65536)
		def.attached, def.attached_node = nil, nil
		if def.playername ~= nil then
			util.check_string(def.playername, "playername", 64)
			if not core.get_player_by_name(def.playername) then return nil, "player not online" end
		end
		if spawner then
			if not (def.pos or def.minpos) then
				def.minpos = vector.offset(rec.pos, -0.5, 0, -0.5)
				def.maxpos = vector.offset(rec.pos, 0.5, 1, 0.5)
			end
		elseif not def.pos then
			def.pos = vector.offset(rec.pos, 0, 0.6, 0)
		end
		return def
	end

	-- admin.particle(def): one particle, same fields as core.add_particle
	admin.particle = wrap("admin.particle", function(def)
		require_admin("admin.particle")
		local d, err = particle_def(def, false)
		if not d then return false, err end
		core.add_particle(d)
		return true
	end, 20)

	-- admin.particles(def): a particle spawner (core.add_particlespawner); returns its id. Spawners are removed when the program stops.
	admin.particles = wrap("admin.particles", function(def)
		require_admin("admin.particles")
		local d, err = particle_def(def, true)
		if not d then return nil, err end
		local id = core.add_particlespawner(d)
		if id and id >= 0 then
			bot.state.particle_spawners = bot.state.particle_spawners or {}
			bot.state.particle_spawners[id] = true
			return id
		end
		return nil, "could not create it"
	end, 50)

	-- admin.particles_stop(id): remove a spawner (nil: all of this robot)
	admin.particles_stop = wrap("admin.particles_stop", function(id)
		require_admin("admin.particles_stop")
		local list = bot.state.particle_spawners or {}
		if id == nil then
			for sid in pairs(list) do core.delete_particlespawner(sid) end
			bot.state.particle_spawners = nil
			return true
		end
		id = util.check_number(id, "id")
		if not list[id] then return false, "not a spawner of this robot" end
		core.delete_particlespawner(id)
		list[id] = nil
		return true
	end)

	admin.get_node = wrap("admin.get_node", function(pos)
		require_admin("admin.get_node")
		pos = util.check_pos(pos, "pos")
		local node = core.get_node_or_nil(pos)
		if not node then return nil, "area not loaded" end
		return node.name, node.param2
	end, 30)

	admin.set_node = wrap("admin.set_node", function(pos, name, param2)
		require_admin("admin.set_node")
		pos = util.check_pos(pos, "pos")
		util.check_string(name, "name", 200)
		if name ~= "air" and not core.registered_nodes[name] then
			util.api_error("unknown node '" .. name .. "'")
		end
		param2 = math.floor(util.check_number(param2 or 0, "param2", 0, 255))
		if not core.get_node_or_nil(pos) then return false, "area not loaded" end
		if core.is_protected(pos, rec.owner) then return false, "protected" end
		core.set_node(pos, {name = name, param2 = param2})
		log("set_node " .. name .. " at " .. util.pos_to_string(pos))
		return true
	end, 100)

	admin.teleport = wrap("admin.teleport", function(pos)
		require_admin("admin.teleport")
		pos = util.check_pos(pos, "pos")
		local node = core.get_node_or_nil(pos)
		if not node then return false, "area not loaded" end
		if not util.is_passable(node) or luabots.robot_at(pos, rec.id) then return false, "blocked" end
		local body = bot.body()
		if not body then return false, "no body" end
		local old = rec.pos
		rec.pos = pos
		luabots.occupy(rec, old)
		luabots.mark_dirty(rec.id)
		body:set_pos(pos)
		log("teleport to " .. util.pos_to_string(pos))
		bot.act(0.5)
		return true
	end, 100)

	admin.players = wrap("admin.players", function()
		require_admin("admin.players")
		local out = {}
		for _, p in ipairs(core.get_connected_players()) do
			out[#out + 1] = p:get_player_name()
		end
		return out
	end, 100)

	-- Details of an online player. The IP address is only included when the owner could see it anyway (ban or server privilege).
	admin.player_info = wrap("admin.player_info", function(pname)
		require_admin("admin.player_info")
		util.check_string(pname, "name", 64)
		local player = core.get_player_by_name(pname)
		if not player then return nil, "player not online" end
		local info = core.get_player_information(pname) or {}
		local privs = {}
		for priv in pairs(core.get_player_privs(pname)) do privs[#privs + 1] = priv end
		table.sort(privs)
		local out = {
			name = pname,
			pos = util.plain_pos(vector.round(player:get_pos())),
			hp = player:get_hp(),
			ping = info.avg_rtt and math.floor(info.avg_rtt * 1000 + 0.5),
			connected = info.connection_uptime,
			version = info.version_string,
			lang = info.lang_code,
			privs = privs,
		}
		if core.check_player_privs(rec.owner, {ban = true})
				or core.check_player_privs(rec.owner, {server = true}) then
			out.ip = info.address
		end
		log("player_info " .. pname)
		return out
	end, 100)

	local run_warned = false
	admin.run = wrap("admin.run", function(cmdline)
		require_admin("admin.run")
		util.check_string(cmdline, "command", 1000)
		if not config.allow_admin_commands then
			local why = "disabled by server setting luabots.allow_admin_commands"
			if not run_warned then
				-- programs often ignore the result, so say it once in the console
				run_warned = true
				luabots.console(rec.id, "[admin.run: " .. why .. "]", "error")
			end
			return false, why
		end
		local cmd, params = cmdline:match("^/?(%S+)%s*(.*)$")
		if not cmd then return false, "empty command" end
		local def = core.registered_chatcommands[cmd]
		if not def then return false, "unknown command" end
		local ok, missing = core.check_player_privs(rec.owner, def.privs or {})
		if not ok then
			return false, "owner lacks privileges: " .. table.concat(missing, ", ")
		end
		log("run /" .. cmd .. " " .. params)
		local success, msg = def.func(rec.owner, params)
		bot.act(0.2)
		return success ~= false, msg
	end, 500)
end)
