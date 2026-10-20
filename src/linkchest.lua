-- Linked chests: a sending chest moves its items to the receiving chests of the same owner and channel, at any distance, paying energy for each item.

local S = luabots.S
local FS = function(...) return core.formspec_escape(S(...)) end
local esc = core.formspec_escape
local config = luabots.config
local util = luabots.util
local compat = luabots.compat
local gui = luabots.gui
local storage = luabots.mod_storage

local SEND = "luabots:link_chest"
local RECEIVE = "luabots:link_chest_receive"
local MAX_ENERGY = 10000
local MAX_CHANNEL = 32
local RETRY = 10 -- seconds before a blocked chest tries again
local PER_CYCLE = 32 -- sending chests handled every 2 seconds

local function is_link(name) return name == SEND or name == RECEIVE end

-- Registry of every linked chest, so chests in unloaded areas can be found.
-- position hash -> {pos, owner, channel, mode, pending}
local chests = core.deserialize(storage:get_string("link_chests")) or {}
local dirty = false
local retry_at = {} -- position hash -> time
local clock = 0

local function save()
	if not dirty then return end
	storage:set_string("link_chests", core.serialize(chests))
	dirty = false
end
core.register_on_shutdown(save)

local function unregister(pos)
	local h = core.hash_node_position(pos)
	if chests[h] then
		chests[h] = nil
		retry_at[h] = nil
		dirty = true
	end
end

-- Update the entry of the chest at 'pos' from its node and metadata
local function register(pos)
	local node = core.get_node(pos)
	if not is_link(node.name) then return unregister(pos) end
	local meta = core.get_meta(pos)
	local h = core.hash_node_position(pos)
	local mode = node.name == RECEIVE and "receive" or "send"
	local pending = mode == "send" and not meta:get_inventory():is_empty("main")
	local e = chests[h]
	local owner, channel = meta:get_string("owner"), meta:get_string("channel")
	if not e or e.owner ~= owner or e.channel ~= channel or e.mode ~= mode or e.pending ~= pending then
		chests[h] = {pos = util.plain_pos(pos), owner = owner, channel = channel, mode = mode, pending = pending}
		dirty = true
	end
	retry_at[h] = nil
end

-- Level limit of the owner (math.huge when unlimited)
local function limit(owner, key)
	local n = luabots.get_level(owner)[key]
	return n > 0 and n or math.huge
end

local function count_owned(owner)
	local n = 0
	for _, e in pairs(chests) do
		if e.owner == owner then n = n + 1 end
	end
	return n
end

local function count_receivers(owner, channel, except)
	local n = 0
	for h, e in pairs(chests) do
		if h ~= except and e.mode == "receive" and e.owner == owner and e.channel == channel then
			n = n + 1
		end
	end
	return n
end

local function energy_free(owner)
	return not config.energy or (config.link_energy <= 0 and config.link_distance_energy <= 0)
		or core.is_creative_enabled(owner)
end

local STATUS = {
	no_receiver = S("No receiving chest on this channel"),
	no_energy = S("Out of energy: add fuel or charge it with a robot"),
	full = S("The receiving chests are full"),
}

local function update_infotext(pos)
	local node = core.get_node(pos)
	local meta = core.get_meta(pos)
	local owner, channel = meta:get_string("owner"), meta:get_string("channel")
	local lines = {S("Linked chest of @1", owner)}
	if channel == "" then
		lines[#lines + 1] = S("No channel: open it to choose one")
	elseif node.name == RECEIVE then
		lines[#lines + 1] = S("Receives on channel '@1'", channel)
	else
		lines[#lines + 1] = S("Sends on channel '@1'", channel)
		if not energy_free(owner) then
			lines[#lines + 1] = S("Energy: @1", math.floor(meta:get_float("energy")))
		end
		local status = STATUS[meta:get_string("status")]
		if status then lines[#lines + 1] = status end
	end
	meta:set_string("infotext", table.concat(lines, "\n"))
end

-- Burn one item of the fuel slot. Returns the energy gained.
-- Replacement items (empty buckets...) are added to 'extras', to be put in the chest later.
local function burn_one(pos, inv, extras)
	local stack = inv:get_stack("fuel", 1)
	if stack:is_empty() then return 0 end
	local fuel, res = compat.fuel_time(stack)
	if fuel <= 0 then return 0 end
	local name = stack:get_name()
	local _, dec = core.get_craft_result({method = "fuel", width = 1, items = {stack}})
	local rest = dec and dec.items and dec.items[1]
	if rest and rest:get_name() == name then
		inv:set_stack("fuel", 1, rest)
	else
		stack:take_item(1)
		inv:set_stack("fuel", 1, stack)
		local extra = (res.replacements and res.replacements[1]) or rest
		if extra and not extra:is_empty() then extras[#extras + 1] = extra end
	end
	return fuel
end

-- Map blocks the chests may still load from disk this round (config.link_loads)
local loads_left = 0

-- Make sure the area of 'pos' is in memory. False when this round's load budget is used up.
local function ensure_loaded(pos)
	if core.get_node_or_nil(pos) then return true end
	if loads_left <= 0 then return false end
	loads_left = loads_left - 1
	core.load_area(pos)
	return true
end

-- Receiving chests of a channel in a fixed order, up to the owner's limit
local function receivers(owner, channel)
	local list = {}
	for h, e in pairs(chests) do
		if e.mode == "receive" and e.owner == owner and e.channel == channel then
			list[#list + 1] = h
		end
	end
	table.sort(list)
	for i = #list, limit(owner, "link_receivers") + 1, -1 do list[i] = nil end
	return list
end

-- {inv, pos} of a receiving chest, false if it is no longer one, nil if the load budget is used up
local function open_receiver(h, owner, channel)
	local e = chests[h]
	if not e then return false end
	if not ensure_loaded(e.pos) then return nil end
	local meta = core.get_meta(e.pos)
	if core.get_node(e.pos).name == RECEIVE and meta:get_string("owner") == owner
			and meta:get_string("channel") == channel then
		return {inv = meta:get_inventory(), pos = e.pos}
	end
	register(e.pos) -- removed or changed by other means
	return false
end

local function item_cost(from, to)
	return config.link_energy + vector.distance(from, to) / 100 * config.link_distance_energy
end

-- Send up to config.link_stacks stacks. Each stack fills the receivers in order.
-- Returns "blocked" (try again later), "budget" (load budget used up) or nil.
local function send(h, e)
	local pos = e.pos
	if not ensure_loaded(pos) then return "budget" end
	if core.get_node(pos).name ~= SEND then
		register(pos)
		return
	end
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	if inv:is_empty("main") or e.channel == "" then
		e.pending = false
		dirty = true
		if meta:get_string("status") ~= "" then
			meta:set_string("status", "")
			update_infotext(pos)
		end
		return
	end
	local list = receivers(e.owner, e.channel)
	local targets = {} -- index in list -> {inv, pos} or false
	local free = energy_free(e.owner)
	local energy = meta:get_float("energy")
	local extras = {}
	local status, budget, found = "", false, false
	local sent = 0
	for i = 1, inv:get_size("main") do
		if sent >= config.link_stacks or status == "no_energy" or budget then break end
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() then
			local moved = 0
			for k, th in ipairs(list) do
				if stack:is_empty() then break end
				if targets[k] == nil then
					targets[k] = open_receiver(th, e.owner, e.channel)
					if targets[k] == nil then
						budget = true
						break
					end
				end
				local t = targets[k]
				if t then
					found = true
					local can, cost = stack:get_count(), 0
					if not free then
						cost = item_cost(pos, t.pos)
						while energy < can * cost do
							local gained = burn_one(pos, inv, extras)
							if gained <= 0 then break end
							energy = energy + gained
						end
						can = math.min(can, math.floor(energy / cost + 1e-9))
					end
					if can == 0 then
						status = "no_energy"
						break
					end
					local piece = ItemStack(stack)
					piece:set_count(can)
					local n = can - t.inv:add_item("main", piece):get_count()
					if n > 0 then
						stack:take_item(n)
						moved = moved + n
						energy = energy - n * cost
					end
				end
			end
			if moved > 0 then
				inv:set_stack("main", i, stack)
				sent = sent + 1
			end
			if not stack:is_empty() and status == "" and not budget and found then status = "full" end
		end
	end
	if not free then meta:set_float("energy", math.max(0, energy)) end
	for _, extra in ipairs(extras) do
		local left = inv:add_item("main", extra)
		if not left:is_empty() then core.add_item(pos, left) end
	end
	local pending = not inv:is_empty("main")
	if e.pending ~= pending then
		e.pending = pending
		dirty = true
	end
	if budget then
		update_infotext(pos)
		return "budget"
	end
	if not found then status = "no_receiver" end
	meta:set_string("status", status)
	update_infotext(pos)
	return status ~= "" and "blocked" or nil
end

local timer = 0
local cursor = 0
core.register_globalstep(function(dtime)
	clock = clock + dtime
	timer = timer + dtime
	if timer < 2 then return end
	timer = 0
	loads_left = config.link_loads
	local ready = {}
	for h, e in pairs(chests) do
		if e.mode == "send" then
			-- items added without inventory callbacks (other mods)
			if not e.pending and e.channel ~= "" and core.get_node_or_nil(e.pos) then
				if not core.get_meta(e.pos):get_inventory():is_empty("main") then
					e.pending = true
					dirty = true
				end
			end
			if e.pending and (retry_at[h] or 0) <= clock then ready[#ready + 1] = h end
		end
	end
	table.sort(ready)
	local n = #ready
	local handled = 0
	for k = 1, math.min(n, PER_CYCLE) do
		local h = ready[(cursor + k - 1) % n + 1]
		local e = chests[h]
		local result = e and send(h, e)
		handled = k
		if result == "blocked" then retry_at[h] = clock + RETRY end
		if result == "budget" then break end
	end
	if n > 0 then cursor = (cursor + handled) % n end
	save()
end)

-- Chest is ready to try again (new items, fuel, energy or a new receiver)
local function wake(pos)
	local e = chests[core.hash_node_position(pos)]
	if e and e.mode == "send" then
		retry_at[core.hash_node_position(pos)] = nil
		if not e.pending then
			e.pending = true
			dirty = true
		end
	elseif e and e.mode == "receive" then
		for h, other in pairs(chests) do
			if other.mode == "send" and other.owner == e.owner and other.channel == e.channel then
				retry_at[h] = nil
			end
		end
	end
end

-- Window

local contexts = {} -- player name -> pos

local function can_use(pos, name)
	return name == core.get_meta(pos):get_string("owner") or luabots.is_admin(name)
end

local function n(v) return ("%.2f"):format(v) end

local function show(name, pos)
	contexts[name] = vector.copy(pos)
	local node = core.get_node(pos)
	local meta = core.get_meta(pos)
	local receive = node.name == RECEIVE
	local loc = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local player = core.get_player_by_name(name)
	local pw = player and player:hud_get_hotbar_itemcount() or 8
	if pw < 1 or pw > 12 then pw = 8 end
	local psize = player and player:get_inventory():get_size("main") or 32
	local prows = math.max(1, math.min(4, math.ceil(psize / pw)))
	local slot = 1.25
	local W = 0.5 + math.max(8, pw) * slot - 0.25 + 0.5
	local PY = 2.9 + 4 * slot + 2.2
	local H = PY + 0.45 + prows * slot - 0.25 + 0.45
	local owner = meta:get_string("owner")
	local energy_text, cost_text
	if energy_free(owner) then
		energy_text = S("Energy: not needed")
	else
		energy_text = S("Energy: @1", math.floor(meta:get_float("energy")))
		if config.link_distance_energy > 0 then
			cost_text = S("Cost per item: @1 + @2 every 100 nodes", config.link_energy,
				config.link_distance_energy)
		else
			cost_text = S("Cost per item: @1", config.link_energy)
		end
	end
	local status = STATUS[meta:get_string("status")]
	local fs = {
		gui.header(W, H, util.hypertext_escape(S("Linked chest"))),
		gui.caption(0.5, 1.3, S("CHANNEL")),
		"field_close_on_enter[channel;false]",
		"field[0.5,1.55;4.3,0.7;channel;;", esc(meta:get_string("channel")), "]",
		"button[4.95,1.55;1.6,0.7;save;", FS("Save"), "]",
		receive and gui.color_button("mode", "cyan") or "",
		"button[", n(W - 3.95), ",1.55;3.45,0.7;mode;",
			receive and FS("Mode: receive") or FS("Mode: send"), "]",
		"tooltip[mode;", FS("Sending chests move their items to the receiving chests of the same channel"), "]",
		gui.caption(0.5, 2.6, S("CHEST")),
		"list[", loc, ";main;0.5,2.9;8,4;]",
	}
	local y = 2.9 + 4 * slot + 0.2
	if receive then
		fs[#fs + 1] = "label[0.5," .. n(y + 0.55) .. ";" .. core.colorize("#9aa1aa",
			FS("Items sent on channel '@1' arrive here.", meta:get_string("channel"))) .. "]"
	else
		fs[#fs + 1] = gui.caption(0.5, y + 0.1, S("FUEL"))
		fs[#fs + 1] = "list[" .. loc .. ";fuel;0.5," .. n(y + 0.35) .. ";1,1;]"
		fs[#fs + 1] = "label[1.95," .. n(y + 0.6) .. ";" .. esc(energy_text) .. "]"
		if cost_text then
			fs[#fs + 1] = "label[1.95," .. n(y + 1.0) .. ";" .. core.colorize("#9aa1aa", esc(cost_text)) .. "]"
		end
		if status then
			fs[#fs + 1] = "label[1.95," .. n(y + 1.4) .. ";" .. core.colorize("#ff8a7a", esc(status)) .. "]"
		end
	end
	fs[#fs + 1] = gui.caption(0.5, PY + 0.1, S("YOUR INVENTORY"))
	fs[#fs + 1] = "list[current_player;main;0.5," .. n(PY + 0.45) .. ";" .. pw .. "," .. prows .. ";]"
	fs[#fs + 1] = "listring[" .. loc .. ";main]"
	fs[#fs + 1] = "listring[current_player;main]"
	core.show_formspec(name, "luabots:link_chest", table.concat(fs))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:link_chest" then return false end
	local name = player:get_player_name()
	local pos = contexts[name]
	if not pos then return true end
	local node = core.get_node(pos)
	if not is_link(node.name) or not can_use(pos, name)
			or vector.distance(player:get_pos(), pos) > 10 then
		contexts[name] = nil
		return true
	end
	local meta = core.get_meta(pos)
	local owner = meta:get_string("owner")
	local old_channel = meta:get_string("channel")
	-- the typed channel is kept on Save, Enter and also when the window is closed
	local channel = old_channel
	if type(fields.channel) == "string" then
		channel = fields.channel:gsub("%c", ""):match("^%s*(.-)%s*$"):sub(1, MAX_CHANNEL)
	end
	local new_name = node.name
	if fields.mode then new_name = node.name == SEND and RECEIVE or SEND end
	local changed = channel ~= old_channel or new_name ~= node.name
	if changed and new_name == RECEIVE and channel ~= "" then
		local max = limit(owner, "link_receivers")
		if count_receivers(owner, channel, core.hash_node_position(pos)) >= max then
			core.chat_send_player(name, S("Channel '@1' already has @2 receiving chests, the limit.", channel, max))
			changed = false
		end
	end
	if changed then
		meta:set_string("channel", channel)
		if new_name ~= node.name then
			node.name = new_name
			core.swap_node(pos, node)
		end
		meta:set_string("status", "")
		register(pos)
		wake(pos)
		update_infotext(pos)
	end
	if fields.quit then
		contexts[name] = nil
	elseif changed or fields.save or fields.mode then
		show(name, pos)
	end
	return true
end)

core.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)

-- Nodes

local function allow_put(pos, listname, _, stack, player)
	if not player or not can_use(pos, player:get_player_name()) then return 0 end
	if listname == "fuel" and compat.fuel_time(stack) <= 0 then return 0 end
	return stack:get_count()
end

local base = {
	description = S("Linked Chest") .. "\n" .. core.colorize("#9fe0ff",
		S("Sends its items to the chests of the same channel, at any distance")),
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = compat.node_groups({cracky = 2, oddly_breakable_by_hand = 1}),
	_mcl_hardness = 2,
	_mcl_blast_resistance = 1200,
	sounds = compat.metal_sounds(),
	drop = SEND,
	on_rotate = false,

	after_place_node = function(pos, placer)
		local owner = placer and placer:get_player_name() or ""
		local max = limit(owner, "link_chests")
		if count_owned(owner) >= max then
			core.remove_node(pos)
			core.chat_send_player(owner, S("You cannot own more linked chests (limit: @1).", max))
			return true -- keep the item
		end
		local meta = core.get_meta(pos)
		meta:set_string("owner", owner)
		local inv = meta:get_inventory()
		inv:set_size("main", 32)
		inv:set_size("fuel", 1)
		register(pos)
		update_infotext(pos)
	end,

	on_rightclick = function(pos, _, clicker)
		local name = clicker and clicker:get_player_name() or ""
		if name == "" then return end
		if can_use(pos, name) then
			show(name, pos)
		else
			core.chat_send_player(name, S("This chest belongs to @1", core.get_meta(pos):get_string("owner")))
		end
	end,

	can_dig = function(pos, player)
		local meta = core.get_meta(pos)
		local inv = meta:get_inventory()
		return player and can_use(pos, player:get_player_name())
			and inv:is_empty("main") and inv:is_empty("fuel")
	end,

	allow_metadata_inventory_put = allow_put,
	allow_metadata_inventory_take = function(pos, _, _, stack, player)
		if not player or not can_use(pos, player:get_player_name()) then return 0 end
		return stack:get_count()
	end,
	allow_metadata_inventory_move = function(pos, from_list, from_index, to_list, _, count, player)
		if not player or not can_use(pos, player:get_player_name()) then return 0 end
		if to_list == "fuel" then
			local stack = core.get_meta(pos):get_inventory():get_stack(from_list, from_index)
			if compat.fuel_time(stack) <= 0 then return 0 end
		end
		return count
	end,
	on_metadata_inventory_put = function(pos) wake(pos) end,
	on_metadata_inventory_move = function(pos) wake(pos) end,
	on_metadata_inventory_take = function(pos) wake(pos) end,

	after_destruct = function(pos) unregister(pos) end,
	on_blast = function() end, -- resists explosions, like robot bases
}

local send_def = table.copy(base)
send_def.tiles = {
	"luabots_link_top.png", "luabots_base_bottom.png", "luabots_link_side.png",
	"luabots_link_side.png", "luabots_link_side.png", "luabots_link_front_send.png",
}
core.register_node(SEND, send_def)

local receive_def = table.copy(base)
receive_def.tiles = {
	"luabots_link_top.png", "luabots_base_bottom.png", "luabots_link_side.png",
	"luabots_link_side.png", "luabots_link_side.png", "luabots_link_front_receive.png",
}
receive_def.groups = table.copy(base.groups)
receive_def.groups.not_in_creative_inventory = 1
core.register_node(RECEIVE, receive_def)

-- Chests copied or moved without callbacks (WorldEdit, schematics) join the registry when their area loads
core.register_lbm({
	label = "Register linked chests",
	name = "luabots:link_chest_register",
	nodenames = {SEND, RECEIVE},
	run_at_every_load = true,
	action = function(pos)
		local owner = core.get_meta(pos):get_string("owner")
		if owner == "" then return end
		if chests[core.hash_node_position(pos)] or count_owned(owner) < limit(owner, "link_chests") then
			register(pos)
		end
	end,
})

local metal = compat.material("metal")
local gem = compat.material("gem")
local glass = compat.material("glass")
if metal and gem and glass then
	core.register_craft({
		output = SEND .. " 2",
		recipe = {
			{metal, metal, metal},
			{gem, glass, gem},
			{metal, metal, metal},
		},
	})
end

-- Program API: machine.charge(amount, dir) gives robot energy to a linked chest

luabots.register_api(function(bot, env)
	local rec = bot.rec
	env.machine.charge = bot.wrap("machine.charge", function(amount, dir)
		amount = util.check_number(amount, "amount", 0, MAX_ENERGY)
		local pos = luabots.api_target(bot, dir)
		if not bot.in_range(pos) then return 0, "out of range" end
		local node = core.get_node_or_nil(pos)
		if not node or not is_link(node.name) then return 0, "no linked chest there" end
		local meta = core.get_meta(pos)
		if meta:get_string("owner") ~= rec.owner then return 0, "not your chest" end
		local energy = meta:get_float("energy")
		if amount == 0 then return 0, energy end
		amount = math.min(amount, MAX_ENERGY - energy)
		if amount <= 0 then return 0, "the chest is full" end
		if not luabots.ensure_energy(rec, amount) then
			amount = math.min(amount, rec.energy or 0)
			if amount <= 0 then return 0, "not enough energy" end
		end
		luabots.spend_energy(rec, amount)
		meta:set_float("energy", energy + amount)
		wake(pos)
		update_infotext(pos)
		bot.act(0.2)
		return amount, energy + amount
	end, 100)
end)
