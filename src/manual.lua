-- Manual control: drive the robot with the remote control panel when no program is running. Actions use exactly the same code as programs (protection, tools, range...), and act as the robot's owner.

local S = luabots.S
local FS = function(...) return core.formspec_escape(S(...)) end
local esc = core.formspec_escape
local util = luabots.util
local gui = luabots.gui

local contexts = {} -- player name -> {id, item, message}

local function n(v) return ("%.2f"):format(v) end

-- A small stand-in for the program "bot" object used by the action code.
-- Instead of pausing, waiting time is added up: the robot is busy until then.
local function manual_bot(rec)
	local bot = {
		id = rec.id,
		rec = rec,
		state = luabots.get_state(rec.id),
		level = luabots.get_level(rec.owner),
		wait = 0,
	}
	function bot.in_range(pos)
		return vector.distance(pos, rec.home) <= bot.level.range
	end
	function bot.body()
		return luabots.get_body(rec.id)
	end
	function bot.act(seconds)
		bot.wait = bot.wait + seconds / math.max(0.1, bot.level.speed)
	end
	bot.sleep = bot.act
	return bot
end

local function can_drive(name, rec)
	return name == rec.owner or luabots.is_admin(name)
end

-- Distinct item names in the robot inventory (for the place selector)
local function inventory_items(rec)
	local inv = luabots.get_inventory(rec)
	local names, seen = {}, {}
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		local nm = stack:get_name()
		if nm ~= "" and not seen[nm] then
			seen[nm] = true
			names[#names + 1] = nm
		end
	end
	return names
end

local FACING_LABELS = {[0] = S("north"), [1] = S("west"), [2] = S("south"), [3] = S("east")}

-- Pick up items lying around the robot
function luabots.do_pickup(bot, radius)
	local inv = luabots.get_inventory(bot.rec)
	local picked = 0
	for _, obj in ipairs(core.get_objects_inside_radius(bot.rec.pos, radius)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item" and ent.itemstring ~= "" then
			local stack = ItemStack(ent.itemstring)
			local left = inv:add_item("main", stack)
			picked = picked + stack:get_count() - left:get_count()
			if left:is_empty() then obj:remove() else ent:set_item(left) end
		end
	end
	luabots.mark_dirty(bot.rec.id)
	if picked == 0 then return false, "nothing to pick up" end
	bot.act(0.2)
	return true
end

local REASONS = {
	["blocked"] = S("blocked"),
	["blocked by a robot"] = S("blocked by a robot"),
	["out of range"] = S("too far from the base"),
	["area not loaded"] = S("area not loaded"),
	["nothing to dig"] = S("nothing to dig"),
	["protected"] = S("protected area"),
	["tool cannot dig this"] = S("the tool cannot dig this (put a better tool in the tool slot)"),
	["occupied"] = S("the place is occupied"),
	["item not in inventory"] = S("the robot does not have that item"),
	["no body"] = S("the robot is not in the world"),
	["nothing to pick up"] = S("nothing to pick up"),
	["no energy"] = S("no energy: put fuel (coal, wood...) in the robot inventory"),
	["could not dig"] = S("could not dig"),
	["could not place"] = S("could not place"),
	["node changed"] = S("the node changed"),
	["blocked by the server"] = S("the server does not allow robots to do this with that node"),
}

function luabots.show_manual(name, rec)
	local ctx = contexts[name]
	if not ctx or ctx.id ~= rec.id then
		ctx = {id = rec.id}
		contexts[name] = ctx
	end
	local items = inventory_items(rec)
	local selected = 1
	for i, it in ipairs(items) do
		if it == ctx.item then selected = i end
	end
	ctx.item = items[selected]
	ctx.items = items

	local W, H = 13.2, 10.6
	local fs = {
		gui.header(W, H, util.hypertext_escape(S("Remote control") .. ": " .. luabots.display_name(rec))),
		gui.color_button("forward", "cyan"),
		gui.color_button("dig_forward", "red"),
		gui.color_button("dig_up", "red"),
		gui.color_button("dig_down", "red"),
	}
	local function btn(x, y, w, fname, label)
		fs[#fs + 1] = ("button[%s,%s;%s,0.8;%s;%s]"):format(n(x), n(y), n(w), fname, esc(label))
	end

	-- movement
	fs[#fs + 1] = gui.caption(0.4, 1.3, S("MOVE"))
	btn(0.4, 1.6, 2.0, "turn_left", S("Turn left"))
	btn(2.5, 1.6, 2.0, "forward", S("Forward"))
	btn(4.6, 1.6, 2.0, "turn_right", S("Turn right"))
	btn(0.4, 2.5, 2.0, "left", S("Left"))
	btn(2.5, 2.5, 2.0, "back", S("Back"))
	btn(4.6, 2.5, 2.0, "right", S("Right"))
	btn(0.4, 3.4, 3.05, "up", S("Up"))
	btn(3.55, 3.4, 3.05, "down", S("Down"))
	btn(0.4, 4.3, 6.2, "turn_around", S("Turn around"))

	-- digging
	fs[#fs + 1] = gui.caption(7.0, 1.3, S("DIG"))
	btn(7.0, 1.6, 5.8, "dig_forward", S("Dig forward"))
	btn(7.0, 2.5, 2.85, "dig_up", S("Dig up"))
	btn(9.95, 2.5, 2.85, "dig_down", S("Dig down"))
	btn(7.0, 3.4, 2.85, "dig_forward_up", S("Forward up"))
	btn(9.95, 3.4, 2.85, "dig_forward_down", S("Forward down"))
	btn(7.0, 4.3, 5.8, "pickup", S("Pick up items"))

	-- placing
	fs[#fs + 1] = gui.caption(0.4, 5.55, S("PLACE"))
	if #items > 0 then
		local list = {}
		for i, it in ipairs(items) do
			local def = core.registered_items[it]
			local desc = def and def.description or it
			desc = desc:match("^([^\n]*)") or it
			list[i] = esc(desc)
		end
		fs[#fs + 1] = "item_image[0.4,5.85;0.8,0.8;" .. esc(ctx.item) .. "]"
		fs[#fs + 1] = "dropdown[1.35,5.85;5.25,0.8;item;" .. table.concat(list, ",") ..
			";" .. selected .. ";true]"
	else
		fs[#fs + 1] = "label[0.4,6.25;" .. core.colorize("#9aa1aa",
			FS("The robot inventory is empty.")) .. "]"
	end
	btn(7.0, 5.85, 1.87, "place_forward", S("Forward"))
	btn(8.97, 5.85, 1.87, "place_up", S("Up"))
	btn(10.94, 5.85, 1.87, "place_down", S("Down"))

	-- status
	local f = FACING_LABELS[rec.facing % 4]
	fs[#fs + 1] = gui.panel(0.4, 7.1, W - 0.8, 1.5)
	fs[#fs + 1] = "label[0.65,7.45;" .. core.colorize("#9aa1aa", FS("Position")) .. "  " ..
		core.colorize("#eceef0", esc(core.pos_to_string(rec.pos))) .. "     " ..
		core.colorize("#9aa1aa", FS("Facing")) .. "  " .. core.colorize("#eceef0", esc(f)) .. "     " ..
		core.colorize("#9aa1aa", FS("Energy")) .. "  " ..
		core.colorize("#eceef0", tostring(math.floor(rec.energy or 0))) .. "]"
	if ctx.message then
		fs[#fs + 1] = "label[0.65,8.05;" .. core.colorize(ctx.message_color or "#eceef0",
			esc(ctx.message)) .. "]"
	end
	btn(0.4, 9.2, 4.0, "inventory", S("Inventory"))
	btn(4.6, 9.2, 4.0, "editor", S("Program"))
	fs[#fs + 1] = "button_exit[8.8,9.2;4.0,0.8;close;" .. FS("Close") .. "]"
	core.show_formspec(name, "luabots:manual", table.concat(fs))
end

local ACTIONS = {
	forward = function(bot) return luabots.do_move(bot, "forward") end,
	back = function(bot) return luabots.do_move(bot, "back") end,
	left = function(bot) return luabots.do_move(bot, "left") end,
	right = function(bot) return luabots.do_move(bot, "right") end,
	up = function(bot) return luabots.do_move(bot, "up") end,
	down = function(bot) return luabots.do_move(bot, "down") end,
	turn_left = function(bot) return luabots.do_turn(bot, 1) end,
	turn_right = function(bot) return luabots.do_turn(bot, -1) end,
	turn_around = function(bot) return luabots.do_turn(bot, 2) end,
	dig_forward = function(bot) return luabots.do_dig(bot, "forward") end,
	dig_up = function(bot) return luabots.do_dig(bot, "up") end,
	dig_down = function(bot) return luabots.do_dig(bot, "down") end,
	dig_forward_up = function(bot) return luabots.do_dig(bot, "forward_up") end,
	dig_forward_down = function(bot) return luabots.do_dig(bot, "forward_down") end,
	pickup = function(bot) return luabots.do_pickup(bot, 2) end,
}

local function place_action(dir)
	return function(bot, ctx)
		if not ctx.item then return false, "item not in inventory" end
		return luabots.do_place(bot, dir, ctx.item)
	end
end
ACTIONS.place_forward = place_action("forward")
ACTIONS.place_up = place_action("up")
ACTIONS.place_down = place_action("down")

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:manual" then return false end
	local name = player:get_player_name()
	local ctx = contexts[name]
	if not ctx then return true end
	local rec = luabots.get_record(ctx.id)
	if not rec or not can_drive(name, rec) then
		contexts[name] = nil
		return true
	end
	if fields.quit or fields.close then
		contexts[name] = nil
		return true
	end
	if fields.item and ctx.items then
		local idx = tonumber(fields.item)
		if idx and ctx.items[idx] then ctx.item = ctx.items[idx] end
	end
	if fields.inventory then
		if name == rec.owner then luabots.show_inventory(name, rec) end
		return true
	elseif fields.editor then
		contexts[name] = nil
		luabots.show_editor(name, rec)
		return true
	end

	for action, fn in pairs(ACTIONS) do
		if fields[action] then
			local st = luabots.get_state(rec.id)
			if st.status == "running" then
				ctx.message, ctx.message_color = S("A program is running: stop it to drive manually."), "#ffcc66"
				break
			end
			local now = luabots.now()
			if (st.manual_busy or 0) > now then
				ctx.message, ctx.message_color = S("Busy..."), "#ffcc66"
				break
			end
			if not luabots.get_body(rec.id) then
				local node = core.get_node_or_nil(rec.pos)
				if node and util.is_passable(node) then luabots.spawn_body(rec) end
			end
			local bot = manual_bot(rec)
			local ok, res, why = pcall(fn, bot, ctx)
			if not ok then
				ctx.message, ctx.message_color = util.format_error(res), "#ff9a8f"
			elseif res then
				ctx.message, ctx.message_color = S("OK"), "#8fe3a8"
			else
				ctx.message, ctx.message_color = REASONS[why] or tostring(why or S("could not do it")), "#ff9a8f"
			end
			st.manual_busy = now + math.min(bot.wait, 3)
			break
		end
	end
	luabots.show_manual(name, rec)
	return true
end)

core.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)
