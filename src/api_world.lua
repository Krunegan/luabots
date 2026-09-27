-- World API: move, turn, dig, place, sense

local S = luabots.S
local config = luabots.config
local util = luabots.util

-- Robot occupancy: node hash -> robot id (robots cannot overlap)
local occupied = {}
luabots.occupied = occupied

function luabots.occupy(rec, old_pos)
	if old_pos then
		local h = core.hash_node_position(old_pos)
		if occupied[h] == rec.id then occupied[h] = nil end
	end
	if rec.pos then
		occupied[core.hash_node_position(rec.pos)] = rec.id
	end
end

function luabots.release(rec)
	local h = core.hash_node_position(rec.pos)
	if occupied[h] == rec.id then occupied[h] = nil end
end

local function robot_at(pos, except_id)
	local id = occupied[core.hash_node_position(pos)]
	if id and id ~= except_id and luabots.get_body(id) then return id end
	return nil
end
luabots.robot_at = robot_at

-- Resolve a relative direction name (default "forward")
local function target(bot, dir)
	dir = dir or "forward"
	if type(dir) ~= "string" or not util.directions[dir] then
		util.api_error("invalid direction '" .. util.safe_tostring(dir) .. "'")
	end
	return vector.add(bot.rec.pos, util.dir_offset(bot.rec.facing, dir)), dir
end
luabots.api_target = target

-- Resolve either a direction name or an absolute position within sensing range
local function sense_target(bot, where)
	if type(where) == "table" then
		local pos = util.check_pos(where, "position")
		if vector.distance(pos, bot.rec.pos) > bot.level.sense_radius
				and not bot.in_range(pos) then
			util.api_error("position out of range")
		end
		return pos
	end
	return (target(bot, where))
end

-- Errors raised by other mods' callbacks are logged once per message
local warned = {}
local function warn_once(msg)
	if warned[msg] then return end
	warned[msg] = true
	core.log("warning", "[luabots] " .. msg)
end

local function play(sound, pos)
	if sound and (type(sound) == "string" or sound.name) then
		core.sound_play(sound, {pos = pos, max_hear_distance = 16}, true)
	end
end

-- Movement

function luabots.do_move(bot, dir)
	local rec = bot.rec
	local pos = target(bot, dir)
	if not bot.in_range(pos) then return false, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return false, "area not loaded" end
	if not util.is_passable(node) then return false, "blocked" end
	if robot_at(pos, rec.id) then return false, "blocked by a robot" end
	local body = bot.body()
	if not body then return false, "no body" end
	if not luabots.ensure_energy(rec, config.move_energy) then return false, "no energy" end
	luabots.spend_energy(rec, config.move_energy)
	local old = rec.pos
	rec.pos = pos
	luabots.occupy(rec, old)
	luabots.mark_dirty(rec.id)
	body:move_to(pos, true)
	bot.act(config.move_time)
	return true
end

local function set_facing(bot, f)
	local rec = bot.rec
	rec.facing = f % 4
	rec.angle = nil
	luabots.mark_dirty(rec.id)
	local body = bot.body()
	if body then body:set_yaw(luabots.body_yaw(rec)) end
	bot.act(config.turn_time)
	return true
end

-- Turn by any angle (degrees, positive = left). The robot moves and acts towards the closest of the four directions.
local function turn_angle(bot, degrees)
	local rec = bot.rec
	local total = (rec.facing * 90 + (rec.angle or 0) + degrees) % 360
	local f = math.floor(total / 90 + 0.5) % 4
	local rest = total - f * 90
	if rest > 180 then rest = rest - 360 end
	rec.facing = f
	rec.angle = math.abs(rest) > 0.01 and rest or nil
	luabots.mark_dirty(rec.id)
	local body = bot.body()
	if body then body:set_yaw(luabots.body_yaw(rec)) end
	bot.act(config.turn_time)
	return true
end

-- Digging

local function dig(bot, dir)
	local rec = bot.rec
	local pos = target(bot, dir)
	if not bot.in_range(pos) then return false, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return false, "area not loaded" end
	local def = core.registered_nodes[node.name]
	if not def or node.name == "air" or node.name == "ignore" then
		return false, "nothing to dig"
	end
	if def.diggable == false then return false, "not diggable" end
	if def.pointable == false and def.buildable_to then return false, "nothing to dig" end
	if core.is_protected(pos, rec.owner) then return false, "protected" end
	if bot.level.name ~= "admin" and luabots.node_in_list(config.no_dig, node.name) then
		return false, "blocked by the server"
	end

	local inv = luabots.get_inventory(rec)
	local tool = inv:get_stack("tool", 1)
	local params = core.get_dig_params(def.groups or {}, tool:get_tool_capabilities(), tool:get_wear())
	if not params.diggable then
		-- like a player: what the tool cannot dig is dug by hand (a pickaxe digs dirt slowly)
		local hand = core.registered_items[""]
		params = core.get_dig_params(def.groups or {}, hand and hand.tool_capabilities or {})
	end
	if not params.diggable then return false, "tool cannot dig this" end

	if not luabots.ensure_energy(rec, config.dig_energy) then
		return false, "no energy"
	end

	if def.sounds then play(def.sounds.dig, pos) end
	bot.act(util.clamp(params.time * config.dig_time_factor, 0.1, 15))

	local now_node = core.get_node_or_nil(pos)
	if not now_node or now_node.name ~= node.name then return false, "node changed" end
	local fake = luabots.get_fake_player(rec)
	local on_dig = def.on_dig or core.node_dig
	local called, ok = pcall(on_dig, pos, now_node, fake)
	luabots.mark_dirty(rec.id)
	local after = core.get_node(pos)
	local changed = after.name ~= node.name or after.param2 ~= node.param2
	if not called then
		-- a callback of another mod failed; judge by the world state
		warn_once("error while digging " .. node.name .. ": " .. tostring(ok))
		ok = changed
	end
	if ok == false or not changed then
		return false, "could not dig"
	end
	luabots.spend_energy(rec, config.dig_energy)
	if def.sounds and def.sounds.dug then
		core.sound_play(def.sounds.dug, {pos = pos, to_player = rec.owner, max_hear_distance = 16}, true)
	end
	-- Some games (MineClone...) drop items in the world instead of giving
	-- them to the digger: collect what fell where the node was.
	local inv2 = luabots.get_inventory(rec)
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 0.9)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item" and ent.itemstring ~= "" then
			local left = inv2:add_item("main", ItemStack(ent.itemstring))
			if left:is_empty() then
				obj:remove()
			else
				ent:set_item(left)
			end
		end
	end
	return true
end

-- Placing

local function find_slot(inv, name)
	for i = 1, inv:get_size("main") do
		if inv:get_stack("main", i):get_name() == name then return i end
	end
	return nil
end

-- Choose the node the item is placed against (like a player pointing at it)
local function pick_under(pos, rec, dir)
	local candidates = {vector.new(0, -1, 0)}
	local d = util.directions[dir]
	if d and d.h then
		candidates[#candidates + 1] = util.facing_vectors[(rec.facing + d.h) % 4]
	end
	for f = 0, 3 do candidates[#candidates + 1] = util.facing_vectors[f] end
	candidates[#candidates + 1] = vector.new(0, 1, 0)
	for _, off in ipairs(candidates) do
		local p = vector.add(pos, off)
		local n = core.get_node_or_nil(p)
		local def = n and core.registered_nodes[n.name]
		if def and not def.buildable_to and not def.on_rightclick
				and not vector.equals(p, rec.pos) then
			return p
		end
	end
	return pos
end

local function place(bot, dir, itemname, param2)
	local rec = bot.rec
	local pos = target(bot, dir)
	itemname = util.check_itemname(itemname, "item")
	if param2 ~= nil then param2 = math.floor(util.check_number(param2, "param2", 0, 255)) end
	if not bot.in_range(pos) then return false, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return false, "area not loaded" end
	if not util.is_buildable(node) then return false, "occupied" end
	if robot_at(pos) then return false, "a robot is in the way" end
	if core.is_protected(pos, rec.owner) then return false, "protected" end
	local inv = luabots.get_inventory(rec)
	if not find_slot(inv, itemname) then return false, "item not in inventory" end
	if not luabots.ensure_energy(rec, config.place_energy) then return false, "no energy" end

	bot.act(config.place_time)

	local idx = find_slot(inv, itemname)
	if not idx then return false, "item not in inventory" end
	node = core.get_node_or_nil(pos)
	if not node or not util.is_buildable(node) then return false, "occupied" end

	local stack = inv:get_stack("main", idx)
	local count = stack:get_count()
	local def = stack:get_definition()
	local fake = luabots.get_fake_player(rec)
	local pointed = {type = "node", under = pick_under(pos, rec, dir), above = pos}
	if vector.equals(pointed.under, pos) then pointed.under = pos end
	local placer_fn
	if param2 and def.type == "node" then
		placer_fn = function() return core.item_place_node(stack, fake, pointed, param2) end
	else
		local on_place = def.on_place or core.item_place
		placer_fn = function() return on_place(stack, fake, pointed) end
	end
	local called, result = pcall(placer_fn)
	local after = core.get_node(pos)
	local changed = after.name ~= node.name
	if not called then
		-- a callback of another mod failed after (maybe) placing: make sure the item is consumed if the node was placed (no duplication)
		warn_once("error while placing " .. itemname .. ": " .. tostring(result))
		result = stack
		if changed and stack:get_count() == count and not core.is_creative_enabled(rec.owner) then
			result:take_item(1)
		end
	end
	if result ~= nil then
		inv:set_stack("main", idx, ItemStack(result))
	end
	luabots.mark_dirty(rec.id)
	local used = result ~= nil and ItemStack(result):get_count() ~= count
	if not changed and not used then return false, "could not place" end
	luabots.spend_energy(rec, config.place_energy)
	return true
end

-- Used by the manual control panel
luabots.do_dig = dig
luabots.do_place = place
function luabots.do_turn(bot, delta)
	return set_facing(bot, bot.rec.facing + delta)
end

-- Registration

luabots.register_api(function(bot, env)
	local wrap = bot.wrap

	local move = {}
	for _, dir in ipairs(util.move_directions) do
		move[dir] = wrap("move." .. dir, function() return luabots.do_move(bot, dir) end)
	end
	env.move = move

	local turn = {}
	turn.left = wrap("turn.left", function() return set_facing(bot, bot.rec.facing + 1) end)
	turn.right = wrap("turn.right", function() return set_facing(bot, bot.rec.facing - 1) end)
	turn.around = wrap("turn.around", function() return set_facing(bot, bot.rec.facing + 2) end)
	turn.angle = wrap("turn.angle", function(degrees)
		return turn_angle(bot, util.check_number(degrees, "degrees", -3600, 3600))
	end)
	turn.face = wrap("turn.face", function(name)
		util.check_string(name, "direction", 10)
		local f = util.facing_by_name[name]
		if not f then util.api_error("use north, south, east or west") end
		return set_facing(bot, f)
	end)
	env.turn = turn

	local digt, placet = {}, {}
	for _, dir in ipairs(util.direction_list) do
		digt[dir] = wrap("dig." .. dir, function() return dig(bot, dir) end, 100)
		placet[dir] = wrap("place." .. dir, function(item, param2)
			return place(bot, dir, item, param2)
		end, 100)
	end
	env.dig = digt
	env.place = placet

	-- sense.*
	local sense = {}
	env.sense = sense

	sense.node = wrap("sense.node", function(where)
		local pos = sense_target(bot, where)
		local node = core.get_node_or_nil(pos)
		if not node then return nil, "area not loaded" end
		return node.name, node.param2
	end, 30)

	sense.light = wrap("sense.light", function(where)
		local pos = sense_target(bot, where)
		return core.get_node_light(pos)
	end, 30)

	sense.is_protected = wrap("sense.is_protected", function(where)
		local pos = sense_target(bot, where)
		return core.is_protected(pos, bot.rec.owner)
	end, 50)

	sense.robot = wrap("sense.robot", function(where)
		local pos = sense_target(bot, where)
		return robot_at(pos)
	end, 20)

	sense.text = wrap("sense.text", function(where)
		local pos = sense_target(bot, where)
		if not core.get_node_or_nil(pos) then return nil, "area not loaded" end
		local meta = core.get_meta(pos)
		local text = meta:get_string("text")
		if text == "" then text = meta:get_string("infotext") end
		return text
	end, 50)

	sense.write_text = wrap("sense.write_text", function(dir, text)
		local rec = bot.rec
		local pos = target(bot, dir)
		text = util.check_string(text, "text", 512)
		if not bot.in_range(pos) then return false, "out of range" end
		local node = core.get_node_or_nil(pos)
		if not node then return false, "area not loaded" end
		if core.is_protected(pos, rec.owner) then return false, "protected" end
		local def = core.registered_nodes[node.name]
		if not def or not def.on_receive_fields then return false, "cannot write here" end
		def.on_receive_fields(pos, "", {text = text, key_enter = "true",
			key_enter_field = "text", ok = "true"}, luabots.get_fake_player(rec))
		bot.act(config.place_time)
		return true
	end, 100)

	local function object_info(obj)
		if obj:is_player() then
			return {type = "player", name = obj:get_player_name()}
		end
		local ent = obj:get_luaentity()
		if not ent then return nil end
		if ent.name == "__builtin:item" then
			local stack = ItemStack(ent.itemstring)
			return {type = "item", name = stack:get_name(), count = stack:get_count()}
		elseif ent.name == "luabots:robot" then
			local r = luabots.get_record(ent.robot_id)
			if r then
				return {type = "robot", name = luabots.display_name(r), id = r.id}
			end
			return nil
		end
		return {type = "entity", name = ent.name, hp = obj:get_hp()}
	end

	sense.objects = wrap("sense.objects", function(radius, kind)
		radius = util.check_number(radius or bot.level.sense_radius, "radius", 0, bot.level.sense_radius)
		if kind ~= nil then util.check_string(kind, "kind", 20) end
		local out = {}
		local me = bot.body()
		for _, obj in ipairs(core.get_objects_inside_radius(bot.rec.pos, radius)) do
			if obj ~= me then
				local info = object_info(obj)
				if info and (kind == nil or info.type == kind) then
					local p = obj:get_pos()
					info.pos = {
						x = math.floor(p.x * 100 + 0.5) / 100,
						y = math.floor(p.y * 100 + 0.5) / 100,
						z = math.floor(p.z * 100 + 0.5) / 100,
					}
					out[#out + 1] = info
					if #out >= 100 then break end
				end
			end
		end
		return out
	end, 300)

	sense.players = wrap("sense.players", function(radius)
		radius = util.check_number(radius or bot.level.sense_radius, "radius", 0, bot.level.sense_radius)
		local out = {}
		for _, obj in ipairs(core.get_objects_inside_radius(bot.rec.pos, radius)) do
			if obj:is_player() then out[#out + 1] = obj:get_player_name() end
		end
		return out
	end, 200)

	sense.find = wrap("sense.find", function(names, radius, max)
		local list = {}
		if type(names) == "string" then
			list[1] = names
		elseif type(names) == "table" then
			for i = 1, 16 do
				local v = rawget(names, i)
				if v == nil then break end
				list[#list + 1] = util.check_string(v, "names", 100)
			end
		else
			util.api_error("names must be a node name, 'group:x' or a list of them")
		end
		for _, n in ipairs(list) do util.check_string(n, "names", 100) end
		radius = math.floor(util.check_number(radius or 8, "radius", 1, bot.level.sense_radius))
		max = math.floor(util.check_number(max or 64, "max", 1, 256))
		local p = bot.rec.pos
		bot.ctx.used = bot.ctx.used + (2 * radius + 1) ^ 3 / 10
		local found = core.find_nodes_in_area(vector.subtract(p, radius), vector.add(p, radius), list)
		table.sort(found, function(a, b)
			return vector.distance(a, p) < vector.distance(b, p)
		end)
		local out = {}
		for i = 1, math.min(#found, max) do out[i] = util.plain_pos(found[i]) end
		return out
	end, 200)

	sense.time_of_day = wrap("sense.time_of_day", function()
		return core.get_timeofday()
	end, 5)

	sense.day_count = wrap("sense.day_count", function()
		return core.get_day_count()
	end, 5)
end)
