-- More program functions: players, basic cryptography, energy transfer between robots and node punch events.

local util = luabots.util

-- Node punches near listening robots become "punch" events
function luabots.on_punchnode(pos, node, puncher)
	if not puncher or not puncher:is_player() then return end
	for id, st in pairs(luabots.states) do
		if st.status == "running" and st.punch_listening then
			local rec = luabots.get_record(id)
			if rec and vector.distance(pos, rec.pos) <= luabots.get_level(rec.owner).sense_radius then
				luabots.push_event(id, "punch", {
					player = puncher:get_player_name(), pos = util.plain_pos(pos), node = node.name,
				})
			end
		end
	end
end
core.register_on_punchnode(luabots.on_punchnode)

local function to_hex(s)
	return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function from_hex(s)
	if #s % 2 == 1 or s:find("[^%x]") then util.api_error("text is not an encrypted hex string") end
	return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Byte-wise key shift (a Vigenere cipher): simple, not real security
local function shift(text, key, sign)
	local out = {}
	local k = #key
	for i = 1, #text do
		local kb = key:byte((i - 1) % k + 1)
		out[i] = string.char((text:byte(i) + sign * kb) % 256)
	end
	return table.concat(out)
end

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec, st = bot.rec, bot.state

	-- player.*
	local player = {}
	env.player = player

	player.connected = wrap("player.connected", function()
		local out = {}
		for _, p in ipairs(core.get_connected_players()) do out[#out + 1] = p:get_player_name() end
		return out
	end, 50)

	-- Only players the robot can sense (admins: anywhere)
	local function near_player(name)
		util.check_string(name, "name", 64)
		local p = core.get_player_by_name(name)
		if not p then return nil, "player not online" end
		if bot.level.name ~= "admin"
				and vector.distance(p:get_pos(), rec.pos) > bot.level.sense_radius then
			return nil, "too far"
		end
		return p
	end

	player.pos = wrap("player.pos", function(name)
		local p, err = near_player(name)
		if not p then return nil, err end
		local pos = p:get_pos()
		return {x = math.floor(pos.x * 100 + 0.5) / 100, y = math.floor(pos.y * 100 + 0.5) / 100,
			z = math.floor(pos.z * 100 + 0.5) / 100}
	end, 30)

	player.view = wrap("player.view", function(name)
		local p, err = near_player(name)
		if not p then return nil, err end
		local d = p:get_look_dir()
		return {x = d.x, y = d.y, z = d.z}
	end, 30)

	-- punch.*
	env.punch = {
		listen = wrap("punch.listen", function(on)
			st.punch_listening = on ~= false
			return true
		end),
		-- returns player, pos, node name of the next punched node near the robot
		receive = wrap("punch.receive", function()
			local e = luabots.pop_event(rec.id, "punch")
			if not e then return nil end
			return e.player, e.pos, e.node
		end),
	}

	-- crypto.*
	local crypto = {}
	env.crypto = crypto

	local function key_arg(key)
		key = util.check_string(tostring(key), "key", 256)
		if key == "" then util.api_error("the key cannot be empty") end
		return key
	end

	crypto.encrypt = wrap("crypto.encrypt", function(text, key)
		text = util.check_string(tostring(text), "text", 16384)
		bot.ctx.used = bot.ctx.used + #text
		return to_hex(shift(text, key_arg(key), 1))
	end, 50)

	crypto.decrypt = wrap("crypto.decrypt", function(hex, key)
		util.check_string(hex, "text", 32768)
		bot.ctx.used = bot.ctx.used + #hex
		return shift(from_hex(hex), key_arg(key), -1)
	end, 50)

	-- Same letters in a different order; reverse = true puts them back
	crypto.scramble = wrap("crypto.scramble", function(text, seed, reverse)
		text = util.check_string(tostring(text), "text", 16384)
		seed = math.floor(util.check_number(seed, "seed", -2 ^ 31, 2 ^ 31))
		bot.ctx.used = bot.ctx.used + #text * 2
		local n = #text
		local order = {}
		for i = 1, n do order[i] = i end
		local rng = PcgRandom(seed)
		for i = n, 2, -1 do
			local j = rng:next(1, i)
			order[i], order[j] = order[j], order[i]
		end
		local out = {}
		for i = 1, n do
			if reverse then
				out[order[i]] = text:sub(i, i)
			else
				out[i] = text:sub(order[i], order[i])
			end
		end
		return table.concat(out)
	end, 50)

	crypto.hash = wrap("crypto.hash", function(text)
		text = util.check_string(tostring(text), "text", 65536)
		bot.ctx.used = bot.ctx.used + #text / 4
		return core.sha1(text)
	end, 50)

	-- machine.transfer(amount, robot_name): give energy to another robot of the owner
	env.machine.transfer = wrap("machine.transfer", function(amount, name)
		amount = util.check_number(amount, "amount", 0, 1e6)
		util.check_string(name, "robot", 64)
		local other = luabots.find_record(name, rec.owner)
		if not other or other.owner ~= rec.owner then return false, "no robot called '" .. name .. "'" end
		if other.id == rec.id then return false, "that is this robot" end
		if vector.distance(other.pos, rec.pos) > bot.level.sense_radius then return false, "too far" end
		if (rec.energy or 0) < amount then return false, "not enough energy" end
		if (other.energy or 0) + amount > 100000 then return false, "the other robot is full" end
		rec.energy = rec.energy - amount
		other.energy = (other.energy or 0) + amount
		luabots.mark_dirty(rec.id)
		luabots.mark_dirty(other.id)
		bot.act(0.2)
		return true
	end, 100)
end)
