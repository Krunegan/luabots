-- Items API: inv.*, craft.*, machine.*

local config = luabots.config
local util = luabots.util
local compat = luabots.compat

local MAX_ENERGY = 100000

local function robot_inv(bot)
	return luabots.get_inventory(bot.rec)
end

local function stack_info(stack, slot)
	return {
		slot = slot,
		name = stack:get_name(),
		count = stack:get_count(),
		wear = stack:get_wear(),
		description = stack:get_short_description(),
	}
end

-- Add items to the robot, dropping what does not fit next to it
local function give(bot, stack)
	local left = robot_inv(bot):add_item("main", stack)
	if not left:is_empty() then
		core.add_item(bot.rec.pos, left)
	end
	luabots.mark_dirty(bot.rec.id)
end
luabots.give_item = give

local function count_items(inv, name)
	local n = 0
	for i = 1, inv:get_size("main") do
		local s = inv:get_stack("main", i)
		if s:get_name() == name then n = n + s:get_count() end
	end
	return n
end

-- Energy

local function is_tool(stack)
	local def = stack:get_definition()
	return def.type == "tool" or def.tool_capabilities ~= nil
end

-- Burn one item of inventory slot 'idx'. Returns the energy gained (0 if it is not a fuel or the robot is full).
function luabots.burn_one(rec, idx)
	local inv = luabots.get_inventory(rec)
	local stack = inv:get_stack("main", idx)
	if stack:is_empty() then return 0 end
	local fuel, res = compat.fuel_time(stack)
	if fuel <= 0 then return 0, "not a fuel" end
	if (rec.energy or 0) + fuel > MAX_ENERGY then return 0, "energy full" end
	local name = stack:get_name()
	local _, dec = core.get_craft_result({method = "fuel", width = 1, items = {stack}})
	local rest = dec and dec.items and dec.items[1]
	if rest and rest:get_name() == name then
		inv:set_stack("main", idx, rest)
	else
		stack:take_item(1)
		inv:set_stack("main", idx, stack)
		local extra = (res.replacements and res.replacements[1]) or rest
		if extra and not extra:is_empty() then
			local left = inv:add_item("main", extra)
			if not left:is_empty() then core.add_item(rec.pos, left) end
		end
	end
	rec.energy = (rec.energy or 0) + fuel
	luabots.mark_dirty(rec.id)
	return fuel
end

-- Best fuel of the inventory: coal first, then the one that burns longest.
-- Tools are never burned.
function luabots.find_fuel(rec)
	local inv = luabots.get_inventory(rec)
	local best, best_score
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() and not is_tool(stack) then
			local fuel = compat.fuel_time(stack)
			if fuel > 0 then
				local score = fuel
				if core.get_item_group(stack:get_name(), "coal") > 0 then score = score + 1e6 end
				if not best_score or score > best_score then best, best_score = i, score end
			end
		end
	end
	return best
end

local function energy_free(rec)
	return not config.energy or core.is_creative_enabled(rec.owner)
end

-- Make sure the robot has 'cost' energy, burning fuel if needed
function luabots.ensure_energy(rec, cost)
	if cost <= 0 or energy_free(rec) then return true end
	if not config.auto_refuel or rec.auto_refuel == false then
		return (rec.energy or 0) >= cost
	end
	for _ = 1, 16 do
		if (rec.energy or 0) >= cost then return true end
		local idx = luabots.find_fuel(rec)
		if not idx or luabots.burn_one(rec, idx) <= 0 then break end
	end
	return (rec.energy or 0) >= cost
end

function luabots.spend_energy(rec, cost)
	if cost <= 0 or energy_free(rec) then return end
	rec.energy = math.max(0, (rec.energy or 0) - cost)
	luabots.mark_dirty(rec.id)
end

-- Node inventory access

-- Inventory lists a node shows in the formspec stored in its metadata, or nil when it has none (the mod builds its interface in code)
local function visible_lists(pos)
	local fs = core.get_meta(pos):get_string("formspec")
	if fs == "" then return nil end
	local here = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local set = {}
	for loc, lname in fs:gmatch("list%[([^;%]]*);([^;%]]+)") do
		loc = loc:gsub("%s", "")
		if loc == "context" or loc == "current_name" or loc == here then set[lname] = true end
	end
	return set
end

-- Why a robot cannot use a list of a node (nil if it can)
local function list_blocked(bot, pos, node, listname)
	if bot.level.name == "admin" then return nil end
	if luabots.node_in_list(config.no_inventory, node.name) then return "blocked by the server" end
	if config.visible_lists_only and listname then
		local vis = visible_lists(pos)
		if vis and not vis[listname] then return "list '" .. listname .. "' is not accessible" end
	end
end

local function container(bot, dir, listname)
	local rec = bot.rec
	local pos = luabots.api_target(bot, dir)
	listname = util.check_string(listname or "main", "list", 64)
	if not bot.in_range(pos) then return nil, "out of range" end
	local node = core.get_node_or_nil(pos)
	if not node then return nil, "area not loaded" end
	if core.is_protected(pos, rec.owner) then return nil, "protected" end
	local ninv = core.get_meta(pos):get_inventory()
	if not ninv or ninv:get_size(listname) == 0 then return nil, "no inventory '" .. listname .. "'" end
	local blocked = list_blocked(bot, pos, node, listname)
	if blocked then return nil, blocked end
	return pos, ninv, listname, core.registered_nodes[node.name] or {}
end

local function put(bot, dir, name, count, listname)
	name = util.check_itemname(name, "item")
	count = math.floor(util.check_number(count or 99, "count", 1, 65535))
	local pos, ninv, list, def = container(bot, dir, listname)
	if not pos then return 0, ninv end
	local rinv = robot_inv(bot)
	local fake = luabots.get_fake_player(bot.rec)
	local moved = 0
	for i = 1, rinv:get_size("main") do
		if moved >= count then break end
		local rs = rinv:get_stack("main", i)
		if rs:get_name() == name then
			local piece = rs:peek_item(math.min(count - moved, rs:get_count()))
			if def.allow_metadata_inventory_put then
				local idx = 1
				for j = 1, ninv:get_size(list) do
					if ninv:get_stack(list, j):item_fits(piece) then idx = j break end
				end
				local allowed = def.allow_metadata_inventory_put(pos, list, idx, piece, fake)
				if not allowed or allowed <= 0 then break end
				if allowed < piece:get_count() then piece:set_count(allowed) end
			end
			local left = ninv:add_item(list, piece)
			local n = piece:get_count() - left:get_count()
			if n > 0 then
				rs:take_item(n)
				rinv:set_stack("main", i, rs)
				moved = moved + n
				if def.on_metadata_inventory_put then
					local done = ItemStack(piece)
					done:set_count(n)
					def.on_metadata_inventory_put(pos, list, 1, done, fake)
				end
			end
			if not left:is_empty() then break end
		end
	end
	luabots.mark_dirty(bot.rec.id)
	return moved
end

local function take(bot, dir, name, count, listname)
	if name ~= nil then name = util.check_itemname(name, "item") end
	count = math.floor(util.check_number(count or 99, "count", 1, 65535))
	local pos, ninv, list, def = container(bot, dir, listname)
	if not pos then return 0, ninv end
	local rinv = robot_inv(bot)
	local fake = luabots.get_fake_player(bot.rec)
	local moved = 0
	for i = 1, ninv:get_size(list) do
		if moved >= count then break end
		local ns = ninv:get_stack(list, i)
		if not ns:is_empty() and (name == nil or ns:get_name() == name) then
			local piece = ns:peek_item(math.min(count - moved, ns:get_count()))
			if def.allow_metadata_inventory_take then
				local allowed = def.allow_metadata_inventory_take(pos, list, i, piece, fake)
				if allowed and allowed < 0 then allowed = piece:get_count() end -- infinite source
				if not allowed or allowed == 0 then piece:set_count(0) end
				if allowed and allowed > 0 and allowed < piece:get_count() then piece:set_count(allowed) end
			end
			if not piece:is_empty() then
				local left = rinv:add_item("main", piece)
				local n = piece:get_count() - left:get_count()
				if n > 0 then
					ns:take_item(n)
					ninv:set_stack(list, i, ns)
					moved = moved + n
					if def.on_metadata_inventory_take then
						local done = ItemStack(piece)
						done:set_count(n)
						def.on_metadata_inventory_take(pos, list, i, done, fake)
					end
				end
				if not left:is_empty() then break end
			end
		end
	end
	luabots.mark_dirty(bot.rec.id)
	return moved
end

-- Crafting

local function item_matches(itemname, wanted)
	if wanted:sub(1, 6) == "group:" then
		for g in wanted:sub(7):gmatch("[^,]+") do
			if core.get_item_group(itemname, g) == 0 then return false end
		end
		return true
	end
	return itemname == wanted
end

-- Try one recipe; returns true if crafted
local function try_recipe(bot, recipe, itemname)
	local inv = robot_inv(bot)
	local size = inv:get_size("main")
	local reserved = {}
	local grid = {}
	local used_slots = {}
	local width = recipe.width
	local n_items = 0
	for k in pairs(recipe.items) do
		if k > n_items then n_items = k end
	end
	for idx = 1, n_items do
		local wanted = recipe.items[idx]
		if wanted and wanted ~= "" then
			local found
			for i = 1, size do
				local s = inv:get_stack("main", i)
				if not s:is_empty() and (s:get_count() - (reserved[i] or 0)) > 0
						and item_matches(s:get_name(), wanted) then
					found = i
					break
				end
			end
			if not found then return false end
			reserved[found] = (reserved[found] or 0) + 1
			local one = inv:get_stack("main", found)
			one:set_count(1)
			grid[idx] = one
			used_slots[idx] = found
		else
			grid[idx] = ItemStack("")
		end
	end
	if width == 0 then width = 3 end
	local total = math.max(n_items, width)
	total = math.ceil(total / width) * width
	for i = 1, total do grid[i] = grid[i] or ItemStack("") end
	local output, decremented = core.get_craft_result({method = "normal", width = width, items = grid})
	if not output or output.item:is_empty() or output.item:get_name() ~= itemname then
		return false
	end
	for idx, slot in pairs(used_slots) do
		local s = inv:get_stack("main", slot)
		s:take_item(1)
		inv:set_stack("main", slot, s)
	end
	give(bot, output.item)
	for _, rest in ipairs(decremented.items) do
		if not rest:is_empty() then give(bot, rest) end
	end
	return true
end

local function craft(bot, itemname, times)
	itemname = util.check_itemname(itemname, "item")
	times = math.floor(util.check_number(times or 1, "times", 1, 99))
	local recipes = core.get_all_craft_recipes(itemname)
	if not recipes then return 0, "no recipe" end
	local done = 0
	for _ = 1, times do
		local ok = false
		for _, recipe in ipairs(recipes) do
			if (recipe.method or "normal") == "normal" and try_recipe(bot, recipe, itemname) then
				ok = true
				break
			end
		end
		if not ok then
			if done == 0 then return 0, "missing ingredients" end
			break
		end
		done = done + 1
		bot.act(0.3)
	end
	luabots.mark_dirty(bot.rec.id)
	return done
end

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec = bot.rec

	local inv = {}
	env.inv = inv

	inv.list = wrap("inv.list", function()
		local out = {}
		local ri = robot_inv(bot)
		for i = 1, ri:get_size("main") do
			local s = ri:get_stack("main", i)
			if not s:is_empty() then out[#out + 1] = stack_info(s, i) end
		end
		return out
	end, 100)

	inv.slot = wrap("inv.slot", function(i)
		i = math.floor(util.check_number(i, "slot", 1, luabots.INV_SIZES.main))
		local s = robot_inv(bot):get_stack("main", i)
		if s:is_empty() then return nil end
		return s:get_name(), s:get_count(), s:get_wear()
	end)

	inv.count = wrap("inv.count", function(name)
		name = util.check_itemname(name, "item")
		return count_items(robot_inv(bot), name)
	end, 50)

	inv.has = wrap("inv.has", function(name, n)
		name = util.check_itemname(name, "item")
		n = util.check_number(n or 1, "count", 1)
		return count_items(robot_inv(bot), name) >= n
	end, 50)

	inv.free = wrap("inv.free", function()
		local ri = robot_inv(bot)
		local n = 0
		for i = 1, ri:get_size("main") do
			if ri:get_stack("main", i):is_empty() then n = n + 1 end
		end
		return n
	end, 50)

	inv.tool = wrap("inv.tool", function()
		local s = robot_inv(bot):get_stack("tool", 1)
		if s:is_empty() then return nil end
		return s:get_name(), s:get_wear()
	end)

	inv.equip = wrap("inv.equip", function(name)
		name = util.check_itemname(name, "item")
		local ri = robot_inv(bot)
		for i = 1, ri:get_size("main") do
			local s = ri:get_stack("main", i)
			if s:get_name() == name then
				local current = ri:get_stack("tool", 1)
				local one = s:take_item(1)
				ri:set_stack("main", i, s)
				ri:set_stack("tool", 1, one)
				if not current:is_empty() then give(bot, current) end
				luabots.mark_dirty(rec.id)
				bot.act(0.2)
				return true
			end
		end
		return false, "item not in inventory"
	end)

	inv.unequip = wrap("inv.unequip", function()
		local ri = robot_inv(bot)
		local current = ri:get_stack("tool", 1)
		if current:is_empty() then return false end
		if not ri:room_for_item("main", current) then return false, "inventory full" end
		ri:set_stack("tool", 1, ItemStack(""))
		give(bot, current)
		return true
	end)

	inv.swap = wrap("inv.swap", function(a, b)
		local size = luabots.INV_SIZES.main
		a = math.floor(util.check_number(a, "slot_a", 1, size))
		b = math.floor(util.check_number(b, "slot_b", 1, size))
		local ri = robot_inv(bot)
		local sa, sb = ri:get_stack("main", a), ri:get_stack("main", b)
		ri:set_stack("main", a, sb)
		ri:set_stack("main", b, sa)
		luabots.mark_dirty(rec.id)
		return true
	end)

	inv.drop = wrap("inv.drop", function(name, count, dir)
		name = util.check_itemname(name, "item")
		count = math.floor(util.check_number(count or 1, "count", 1, 65535))
		local pos = luabots.api_target(bot, dir)
		if not bot.in_range(pos) then return 0, "out of range" end
		local ri = robot_inv(bot)
		local have = count_items(ri, name)
		if have == 0 then return 0, "item not in inventory" end
		local removed = ri:remove_item("main", ItemStack(name .. " " .. math.min(have, count)))
		core.add_item(pos, removed)
		luabots.mark_dirty(rec.id)
		bot.act(0.2)
		return removed:get_count()
	end, 100)

	inv.put = wrap("inv.put", function(dir, name, count, list)
		local n, err = put(bot, dir, name, count, list)
		if n > 0 then bot.act(0.2) end
		return n, err
	end, 200)

	inv.take = wrap("inv.take", function(dir, name, count, list)
		local n, err = take(bot, dir, name, count, list)
		if n > 0 then bot.act(0.2) end
		return n, err
	end, 200)

	inv.peek = wrap("inv.peek", function(dir, list)
		local pos, ninv, lname = container(bot, dir, list)
		if not pos then return nil, ninv end
		local out = {}
		for i = 1, ninv:get_size(lname) do
			local s = ninv:get_stack(lname, i)
			if not s:is_empty() then out[#out + 1] = stack_info(s, i) end
		end
		return out
	end, 200)

	inv.lists = wrap("inv.lists", function(dir)
		local pos = luabots.api_target(bot, dir)
		local node = core.get_node_or_nil(pos)
		if not bot.in_range(pos) or not node then return {} end
		local out = {}
		for name, list in pairs(core.get_meta(pos):get_inventory():get_lists()) do
			if not list_blocked(bot, pos, node, name) then
				out[#out + 1] = {name = name, size = #list}
			end
		end
		return out
	end, 100)

	inv.pickup = wrap("inv.pickup", function(radius)
		radius = util.check_number(radius or 2, "radius", 0.5, math.max(2, bot.level.sense_radius / 4))
		local ri = robot_inv(bot)
		local picked = 0
		for _, obj in ipairs(core.get_objects_inside_radius(rec.pos, radius)) do
			local ent = obj:get_luaentity()
			if ent and ent.name == "__builtin:item" and ent.itemstring ~= "" then
				local stack = ItemStack(ent.itemstring)
				local left = ri:add_item("main", stack)
				picked = picked + stack:get_count() - left:get_count()
				if left:is_empty() then
					obj:remove()
				else
					ent:set_item(left)
				end
			end
		end
		if picked > 0 then
			luabots.mark_dirty(rec.id)
			bot.act(0.2)
		end
		return picked
	end, 200)

	-- craft.* 
	local craftt = {}
	env.craft = craftt

	craftt.make = wrap("craft.make", function(item, times)
		return craft(bot, item, times)
	end, 500)

	craftt.recipes = wrap("craft.recipes", function(item)
		item = util.check_itemname(item, "item")
		local out = {}
		for _, r in ipairs(core.get_all_craft_recipes(item) or {}) do
			local items = {}
			for k, v in pairs(r.items) do items[k] = v end
			out[#out + 1] = {
				method = r.method or "normal",
				width = r.width,
				items = items,
				output = r.output,
			}
			if #out >= 16 then break end
		end
		return out
	end, 300)

	-- machine.*
	local machine = {}
	env.machine = machine

	machine.energy = wrap("machine.energy", function() return rec.energy or 0 end, 5)

	machine.burn = wrap("machine.burn", function(name, count)
		name = util.check_itemname(name, "item")
		count = math.floor(util.check_number(count or 1, "count", 1, 99))
		local ri = robot_inv(bot)
		local gained, burned = 0, 0
		for _ = 1, count do
			local idx
			for i = 1, ri:get_size("main") do
				if ri:get_stack("main", i):get_name() == name then idx = i break end
			end
			if not idx then break end
			local got, why = luabots.burn_one(rec, idx)
			if got <= 0 then
				if burned == 0 then return 0, why end
				break
			end
			gained = gained + got
			burned = burned + 1
		end
		if burned > 0 then bot.act(0.2) end
		return gained
	end, 200)

	-- Turn automatic refuelling on/off for this robot (on by default)
	machine.auto_refuel = wrap("machine.auto_refuel", function(on)
		rec.auto_refuel = on ~= false
		luabots.mark_dirty(rec.id)
		return config.auto_refuel and rec.auto_refuel
	end, 5)

	-- Burn the best fuel of the inventory until energy reaches 'amount'
	machine.refuel = wrap("machine.refuel", function(amount)
		amount = util.check_number(amount or 100, "amount", 0, MAX_ENERGY)
		local before = rec.energy or 0
		for _ = 1, 64 do
			if (rec.energy or 0) >= amount then break end
			local idx = luabots.find_fuel(rec)
			if not idx or luabots.burn_one(rec, idx) <= 0 then break end
		end
		local gained = (rec.energy or 0) - before
		if gained > 0 then bot.act(0.2) end
		return gained
	end, 200)

	machine.cook = wrap("machine.cook", function(name, count)
		name = util.check_itemname(name, "item")
		count = math.floor(util.check_number(count or 1, "count", 1, 99))
		local ri = robot_inv(bot)
		local cooked = 0
		for _ = 1, count do
			local idx
			for i = 1, ri:get_size("main") do
				if ri:get_stack("main", i):get_name() == name then idx = i break end
			end
			if not idx then break end
			local stack = ri:get_stack("main", idx)
			local res, dec = compat.cook_result(stack)
			if not res then
				if cooked == 0 then return 0, "cannot be cooked" end
				break
			end
			if (rec.energy or 0) < res.time then
				if cooked == 0 then return 0, "not enough energy" end
				break
			end
			rec.energy = rec.energy - res.time
			ri:set_stack("main", idx, dec.items[1])
			give(bot, res.item)
			for i = 1, #(res.replacements or {}) do give(bot, res.replacements[i]) end
			cooked = cooked + 1
			bot.act(util.clamp(res.time / 4, 0.2, 5))
		end
		luabots.mark_dirty(rec.id)
		return cooked
	end, 200)
end)
