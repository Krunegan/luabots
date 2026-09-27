-- Acting on the world like a player: using items on nodes and creatures,
-- right-clicking nodes (doors, levers, buttons), saved jobs, a status text
-- and a safe shop (/buy).

local S = luabots.S
local FS = function(...) return core.formspec_escape(S(...)) end
local config = luabots.config
local util = luabots.util

local logged = {}
local function log_once(msg)
	if logged[msg] then return end
	logged[msg] = true
	core.log("warning", "[luabots] " .. msg)
end

-- A creature (not a player, robot, item or display) standing in the node at pos
local function creature_at(pos, rec)
	local best, best_d
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.2)) do
		local ent = obj:get_luaentity()
		if ent and ent.name ~= "__builtin:item" and ent.name:sub(1, 8) ~= "luabots:" then
			local p = obj:get_pos()
			if math.abs(p.x - pos.x) <= 0.6 and math.abs(p.z - pos.z) <= 0.6
					and p.y >= pos.y - 0.6 and p.y <= pos.y + 0.6 then
				local d = vector.distance(p, pos)
				if not best_d or d < best_d then best, best_d = obj, d end
			end
		end
	end
	return best
end

-- The face of the node at pos that looks at the robot (for pointed things)
local function face_toward(pos, from)
	local d = vector.subtract(from, pos)
	local ax, ay, az = math.abs(d.x), math.abs(d.y), math.abs(d.z)
	if ay >= ax and ay >= az then
		return vector.offset(pos, 0, d.y >= 0 and 1 or -1, 0)
	elseif ax >= az then
		return vector.offset(pos, d.x >= 0 and 1 or -1, 0, 0)
	end
	return vector.offset(pos, 0, 0, d.z >= 0 and 1 or -1)
end

local function is_food(def)
	for g in pairs(def.groups or {}) do
		if g == "food" or g == "eatable" or g:sub(1, 5) == "food_" then return true end
	end
	return false
end

-- Nodes open their windows for the clicker: robots must not pop them up in
-- front of their owner, so formspecs are dropped while a robot clicks.
local function without_formspecs(owner, f, ...)
	local show = core.show_formspec
	core.show_formspec = function(name, ...)
		if name ~= owner then return show(name, ...) end
	end
	local r = {pcall(f, ...)}
	core.show_formspec = show
	return unpack(r)
end

local function find_item(inv, name)
	if inv:get_stack("tool", 1):get_name() == name then return "tool", 1 end
	for i = 1, inv:get_size("main") do
		if inv:get_stack("main", i):get_name() == name then return "main", i end
	end
end

-- Use an item on the node or creature in direction 'dir'
local function use_item(bot, dir, itemname, mode)
	local rec = bot.rec
	local pos = luabots.api_target(bot, dir)
	if not bot.in_range(pos) then return false, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return false, "area not loaded" end
	if core.is_protected(pos, rec.owner) then return false, "protected" end
	local inv = luabots.get_inventory(rec)
	local list, idx
	if itemname == nil then
		list, idx = "tool", 1
		if inv:get_stack("tool", 1):is_empty() then return false, "no item in the tool slot" end
	else
		itemname = util.check_itemname(itemname, "item")
		list, idx = find_item(inv, itemname)
		if not list then return false, "item not in inventory" end
	end
	mode = mode or "auto"
	if mode ~= "auto" and mode ~= "left" and mode ~= "right" then
		util.api_error("mode must be \"auto\", \"left\" or \"right\"")
	end

	bot.act(0.3)

	local stack = inv:get_stack(list, idx)
	if stack:is_empty() or (itemname and stack:get_name() ~= itemname) then
		return false, "item not in inventory"
	end
	local name, count, wear = stack:get_name(), stack:get_count(), stack:get_wear()
	local def = stack:get_definition()
	local obj = creature_at(pos, rec)
	local left
	if mode == "left" then
		left = true
	elseif mode == "right" then
		left = false
	else
		left = not obj and def.on_use ~= nil and not is_food(def)
	end
	local fake = luabots.get_fake_player(rec)
	fake:wield(list, idx)
	fake:set_sneak(true)

	local fn
	if obj then
		if left then return false, "robots do not hit creatures with inv.use (use combat.attack)" end
		local ent = obj:get_luaentity()
		if not ent or not ent.on_rightclick then return false, "nothing happens" end
		-- creature mods usually only react to players
		fake.is_player = function() return true end
		fn = function() ent:on_rightclick(fake) end
	elseif left then
		if not def.on_use then return false, "this item has no use" end
		local pointed = {type = "node", under = pos, above = face_toward(pos, rec.pos)}
		fn = function() return def.on_use(stack, fake, pointed) end
	else
		local pointed = {type = "node", under = pos, above = face_toward(pos, rec.pos)}
		local on_place = def.on_place or core.item_place
		fn = function() return on_place(stack, fake, pointed) end
	end

	local ok, result = without_formspecs(rec.owner, fn)
	if not ok then
		log_once("error while using " .. name .. ": " .. tostring(result))
		return false, "could not use it"
	end
	if result ~= nil then
		inv:set_stack(list, idx, ItemStack(result))
	end
	luabots.mark_dirty(rec.id)
	local now = inv:get_stack(list, idx)
	local after = core.get_node(pos)
	local changed = after.name ~= node.name or after.param2 ~= node.param2
		or now:get_name() ~= name or now:get_count() ~= count or now:get_wear() ~= wear
	if obj then return true end
	if not changed then return false, "nothing happens" end
	return true
end

-- Right-click (or punch) a node with an empty hand
local function interact(bot, dir, mode)
	local rec = bot.rec
	local pos = luabots.api_target(bot, dir)
	if not bot.in_range(pos) then return false, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return false, "area not loaded" end
	mode = mode or "right"
	local def = core.registered_nodes[node.name]
	if not def then return false, "unknown node" end
	if bot.level.name ~= "admin" and luabots.node_in_list(config.no_inventory, node.name) then
		return false, "blocked by the server"
	end
	-- Doors and trapdoors of Minetest Game only open for real players: use
	-- their API. Doors with an owner (steel doors) open only for its robots.
	local doors = rawget(_G, "doors")
	local toggle = mode == "right" and doors and (
		(doors.registered_doors and doors.registered_doors[node.name] and doors.door_toggle) or
		(doors.registered_trapdoors and doors.registered_trapdoors[node.name] and doors.trapdoor_toggle))
	if toggle then
		local owner = core.get_meta(pos):get_string("owner")
		if owner ~= "" and owner ~= rec.owner then return false, "locked" end
		bot.act(0.2)
		local ok, res = pcall(toggle, pos, node, nil)
		if not ok then
			log_once("error while interacting with " .. node.name .. ": " .. tostring(res))
			return false, "could not do it"
		end
		if res == false then return false, "could not do it" end
		return true
	end

	local fake = luabots.get_fake_player(rec)
	fake:wield("tool", 1)
	local pointed = {type = "node", under = pos, above = face_toward(pos, rec.pos)}
	local fn
	if mode == "right" then
		if not def.on_rightclick then return false, "nothing to interact with" end
		fn = function() return def.on_rightclick(pos, node, fake, ItemStack(""), pointed) end
	elseif mode == "punch" then
		local on_punch = def.on_punch or core.node_punch
		fn = function() return on_punch(pos, node, fake, pointed) end
	else
		util.api_error("mode must be \"right\" or \"punch\"")
	end
	bot.act(0.2)
	local ok, err = without_formspecs(rec.owner, fn)
	if not ok then
		log_once("error while interacting with " .. node.name .. ": " .. tostring(err))
		return false, "could not do it"
	end
	return true
end

-- Shop
-- A program puts offers in its shop; players near the robot open the list
-- themselves with /buy (a window made by the mod, the program cannot fake
-- it or open it) and each purchase happens at once, only if both sides have
-- the items and room for what they get. The robot never opens windows here.

local MAX_OFFERS = 20
local buy_ctx = {} -- player name -> {only = robot id or nil, rows = {row}}

local function item_label(name, count)
	local def = core.registered_items[name]
	local desc = def and def.description or name
	desc = desc:match("^[^\n]*") or desc
	return core.get_translated_string("en", desc) .. " x" .. count
end

local function count_item(inv, name)
	local n = 0
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if stack:get_name() == name then n = n + stack:get_count() end
	end
	return n
end

-- Offers of the running robots near the player (all of them, or only robot 'only')
local function shops_near(pname, only)
	local player = core.get_player_by_name(pname)
	if not player then return {} end
	local ppos = player:get_pos()
	local rows = {}
	for id, st in pairs(luabots.states) do
		local rec = st.status == "running" and st.shop and luabots.get_record(id)
		local dist = rec and vector.distance(ppos, rec.pos)
		if rec and dist <= config.form_radius and (not only or only == id) then
			local rinv = luabots.get_inventory(rec)
			local ns = {}
			for n in pairs(st.shop) do ns[#ns + 1] = n end
			table.sort(ns)
			for _, n in ipairs(ns) do
				local o = st.shop[n]
				rows[#rows + 1] = {id = id, n = n, dist = dist, name = luabots.display_name(rec),
					give = o.give, give_count = o.give_count, want = o.want, want_count = o.want_count,
					stock = math.floor(count_item(rinv, o.give) / o.give_count)}
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.dist ~= b.dist then return a.dist < b.dist end
		if a.id ~= b.id then return tonumber(a.id) < tonumber(b.id) end
		return a.n < b.n
	end)
	return rows
end

local function show_shops(pname, rows, msg, ok)
	local gui = luabots.gui
	local W, H = 12, 9.6
	local fs = {
		gui.header(W, H, util.hypertext_escape(S("Robot shops")), W - 1),
		gui.caption(0.55, 1.35, S("YOU GET")),
		gui.caption(3.05, 1.35, S("YOU PAY")),
		gui.caption(5.6, 1.35, S("SELLER")),
		gui.panel(0.3, 1.6, W - 0.6, 6.9),
		"scroll_container[0.35,1.65;", W - 1.2, ",6.8;shops;vertical;0.1]",
	}
	for i, r in ipairs(rows) do
		local y = (i - 1) * 1.1 + 0.1
		local function at(x, dy) return x .. "," .. (y + dy) end
		fs[#fs + 1] = table.concat({
			"box[0.1,", y, ";", W - 1.6, ",1;#1b1e23]",
			"item_image[", at(0.2, 0.1), ";0.8,0.8;", core.formspec_escape(r.give), "]",
			"tooltip[", at(0.2, 0.1), ";0.8,0.8;", core.formspec_escape(item_label(r.give, r.give_count)), "]",
			"label[", at(1.15, 0.5), ";x", r.give_count, "]",
			"item_image[", at(2.7, 0.1), ";0.8,0.8;", core.formspec_escape(r.want), "]",
			"tooltip[", at(2.7, 0.1), ";0.8,0.8;", core.formspec_escape(item_label(r.want, r.want_count)), "]",
			"label[", at(3.65, 0.5), ";x", r.want_count, "]",
			"label[", at(5.25, 0.3), ";", core.formspec_escape(r.name), "]",
			"label[", at(5.25, 0.72), ";", core.colorize(r.stock > 0 and "#9aa1aa" or "#e06c5f",
				FS("@1 m, in stock: @2", math.floor(r.dist + 0.5), r.stock)), "]",
			gui.color_button("buy_" .. i, "cyan"),
			"button[", at(W - 3.1, 0.15), ";1.6,0.7;buy_", i, ";", FS("Buy"), "]",
		})
	end
	fs[#fs + 1] = "scroll_container_end[]"
	if #rows > 6 then
		fs[#fs + 1] = ("scrollbaroptions[max=%d]scrollbar[%s,1.65;0.3,6.8;vertical;shops;0]")
			:format(math.ceil((#rows - 6) * 11), W - 0.65)
	end
	if msg then
		fs[#fs + 1] = "label[0.45,9.0;" .. core.colorize(ok and "#7fd07f" or "#e06c5f",
			core.formspec_escape(msg)) .. "]"
	end
	core.show_formspec(pname, "luabots:buy", table.concat(fs))
end

local function open_shops(pname, only, msg, ok)
	local rows = shops_near(pname, only)
	buy_ctx[pname] = {only = only, rows = rows}
	show_shops(pname, rows, msg, ok)
end

local function buy(pname, r)
	local rec = luabots.get_record(r.id)
	local st = luabots.states[r.id]
	local player = core.get_player_by_name(pname)
	if not rec or not player or not st or st.status ~= "running" or not st.shop then
		return false, S("The shop is closed.")
	end
	-- the offer must be exactly the one the player saw
	local o = st.shop[r.n]
	if not o or o.give ~= r.give or o.give_count ~= r.give_count or o.want ~= r.want
			or o.want_count ~= r.want_count then
		return false, S("The offer changed.")
	end
	if vector.distance(player:get_pos(), rec.pos) > config.form_radius then
		return false, S("You are too far from the robot.")
	end
	local rinv = luabots.get_inventory(rec)
	local pinv = player:get_inventory()
	local give = ItemStack(o.give .. " " .. o.give_count)
	local want = ItemStack(o.want .. " " .. o.want_count)
	if not rinv:contains_item("main", give) then return false, S("Out of stock.") end
	if not pinv:contains_item("main", want) then return false, S("You do not have the payment.") end
	if not pinv:room_for_item("main", give) then return false, S("No room in your inventory.") end
	if not rinv:room_for_item("main", want) then return false, S("No room in the robot.") end
	-- move the stacks really taken, so wear and metadata go with them
	local paid = pinv:remove_item("main", want)
	local goods = rinv:remove_item("main", give)
	pinv:add_item("main", goods)
	rinv:add_item("main", paid)
	luabots.mark_dirty(rec.id)
	luabots.push_event(rec.id, "shop", {player = pname, n = r.n, give = o.give, give_count = o.give_count,
		want = o.want, want_count = o.want_count})
	core.log("action", ("[luabots] %s bought %s for %s from robot %s"):format(
		pname, goods:to_string(), paid:to_string(), luabots.display_name(rec)))
	return true, S("Bought @1.", item_label(o.give, o.give_count))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:buy" then return false end
	local pname = player:get_player_name()
	local ctx = buy_ctx[pname]
	if not ctx then return true end
	if fields.quit then
		buy_ctx[pname] = nil
		return true
	end
	for k in pairs(fields) do
		local i = type(k) == "string" and tonumber(k:match("^buy_(%d+)$"))
		local r = i and ctx.rows[i]
		if r then
			local ok, msg = buy(pname, r)
			open_shops(pname, ctx.only, msg, ok)
			break
		end
	end
	return true
end)

core.register_on_leaveplayer(function(player)
	buy_ctx[player:get_player_name()] = nil
end)

-- /buy [owner/robot]: the shops near the player (or the one of a robot)
function luabots.shop_command(name, param)
	if not core.get_player_by_name(name) then return false, S("You must be in the game.") end
	local only
	param = (param or ""):match("^%s*(.-)%s*$")
	if param ~= "" then
		local rec = luabots.find_record(param, name)
		if not rec then return false, S("No robot called '@1'.", param) end
		only = rec.id
	end
	if #shops_near(name, only) == 0 then
		if only then return false, S("That robot is not selling anything near you.") end
		return false, S("There are no robot shops near you.")
	end
	open_shops(name, only)
	return true
end

-- /buy unless another mod has it; /luabots buy always works
if not core.registered_chatcommands.buy then
	core.register_chatcommand("buy", {
		params = "[<owner>/<robot>]",
		description = S("Buy from the robot shops near you"),
		func = luabots.shop_command,
	})
end

-- Program API

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec, st = bot.rec, bot.state

	-- inv.use(dir, item, mode): use an item like a player (mode "auto", "left", "right")
	env.inv.use = wrap("inv.use", function(dir, item, mode)
		return use_item(bot, dir, item, mode)
	end, 150)

	-- interact(dir, mode): right-click (or "punch") a door, lever, button...
	env.interact = wrap("interact", function(dir, mode)
		return interact(bot, dir, mode)
	end, 100)

	-- robot.status(text): a short text shown on the owner's HUD
	env.robot.status = wrap("robot.status", function(text)
		text = util.check_string(tostring(text or ""), "text", 200):gsub("%c", " ")
		st.status_text = text:sub(1, 60)
		return true
	end, 10)

	-- robot.run_reason(): "manual", "server restart" or "resumed"
	env.robot.run_reason = wrap("robot.run_reason", function()
		return st.run_reason or "manual"
	end, 5)

	-- job.*: progress of long tasks, kept across stops and server restarts.
	-- A robot switched off because nobody was near starts again by itself
	-- when someone comes back, if its program had a job going.
	local storage = env.storage
	env.job = {
		save = function(value)
			local ok, err = storage.set("__job", value)
			if ok ~= false then
				rec.job_active = true
				luabots.mark_dirty(rec.id)
			end
			return ok, err
		end,
		load = function() return storage.get("__job") end,
		done = wrap("job.done", function()
			rec.job_active = nil
			luabots.mark_dirty(rec.id)
			return true
		end),
	}
	local job_done = env.job.done
	env.job.done = function()
		storage.set("__job", nil)
		return job_done()
	end

	-- shop.*: offers that players near the robot can buy with /buy
	local function check_offer(give, give_count, want, want_count)
		give = util.check_itemname(give, "give_item")
		want = util.check_itemname(want, "want_item")
		if give == "air" or want == "air" or give == "ignore" or want == "ignore" then
			util.api_error("items cannot be air")
		end
		give_count = math.floor(util.check_number(give_count or 1, "give_count", 1, 65535))
		want_count = math.floor(util.check_number(want_count or 1, "want_count", 1, 65535))
		return {give = give, give_count = give_count, want = want, want_count = want_count}
	end
	local function copy_offer(o)
		return {give = o.give, give_count = o.give_count, want = o.want, want_count = o.want_count}
	end
	st.shop = {}
	local next_offer = 1
	env.shop = {
		-- shop.add(give_item, give_count, want_item, want_count) -> offer number
		add = wrap("shop.add", function(give, give_count, want, want_count)
			local o = check_offer(give, give_count, want, want_count)
			local count = 0
			for _ in pairs(st.shop) do count = count + 1 end
			if count >= MAX_OFFERS then return nil, "too many offers" end
			local n = next_offer
			next_offer = next_offer + 1
			st.shop[n] = o
			return n
		end, 20),
		remove = wrap("shop.remove", function(n)
			n = util.check_number(n, "offer", 1, 1e9)
			if not st.shop[n] then return false, "no such offer" end
			st.shop[n] = nil
			return true
		end),
		clear = wrap("shop.clear", function()
			st.shop = {}
			return true
		end),
		-- {[n] = {give, give_count, want, want_count}}
		list = wrap("shop.list", function()
			local out = {}
			for n, o in pairs(st.shop) do out[n] = copy_offer(o) end
			return out
		end, 20),
		-- returns player, offer number, offer (a copy)
		receive = wrap("shop.receive", function()
			local e = luabots.pop_event(rec.id, "shop")
			if not e then return nil end
			return e.player, e.n, copy_offer(e)
		end),
	}
end)
