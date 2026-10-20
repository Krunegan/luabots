-- Robot base, keyboard keys, remote control, data disk and recipes

local S = luabots.S
local compat = luabots.compat
local util = luabots.util

-- Robot base

local function base_record(pos)
	local meta = core.get_meta(pos)
	local rec = luabots.get_record(meta:get_string("robot_id"))
	-- A copied base (e.g. WorldEdit) points at another robot: ignore it
	if rec and vector.equals(rec.home, pos) then return rec end
	return nil
end
luabots.base_record = base_record

local function update_infotext(pos, rec)
	core.get_meta(pos):set_string("infotext", S("Robot base") .. "\n" ..
		luabots.display_name(rec))
end

-- Delete a robot whose base is gone, dropping its inventory where the base was
local function destroy_robot(rec)
	local inv = luabots.get_inventory(rec)
	for list, size in pairs(luabots.INV_SIZES) do
		for i = 1, size do
			local stack = inv:get_stack(list, i)
			if not stack:is_empty() then core.add_item(rec.home, stack) end
		end
	end
	luabots.destroy(rec)
end

local function create_robot(pos, owner)
	local level = luabots.get_level(owner)
	if level.max_bases > 0 and luabots.owner_count(owner) >= level.max_bases then
		core.chat_send_player(owner, S("You cannot own more robots (limit: @1).", level.max_bases))
		return nil
	end
	local rec = luabots.new_record(owner, pos)
	rec.slot = luabots.free_slot(owner, rec.id)
	-- The base turns its front towards whoever placed it; the robot looks
	-- that way too (placed while looking south -> the robot faces north).
	local node = core.get_node(pos)
	if node.name == "luabots:base" and node.param2 < 4 then
		local dir = vector.multiply(core.facedir_to_dir(node.param2), -1)
		rec.facing = util.vector_to_facing(dir) or 0
	end
	rec.home_facing = rec.facing
	local meta = core.get_meta(pos)
	meta:set_string("robot_id", rec.id)
	meta:set_string("owner", owner)
	update_infotext(pos, rec)
	local above = core.get_node_or_nil(rec.pos)
	if above and util.is_passable(above) then
		luabots.spawn_body(rec)
	end
	return rec
end

core.register_node("luabots:base", {
	description = S("Robot Base") .. "\n" .. core.colorize("#9fe0ff",
		S("Place it and right-click to program your robot")),
	tiles = {
		"luabots_base_top.png",
		"luabots_base_bottom.png",
		"luabots_base_side.png",
	},
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = compat.node_groups({cracky = 2, luabots_base = 1}),
	_mcl_hardness = compat.mcl_hardness,
	_mcl_blast_resistance = 6,
	sounds = compat.metal_sounds(),
	stack_max = 1,

	after_place_node = function(pos, placer)
		if not placer or not placer:is_player() then return end
		local name = placer:get_player_name()
		if not create_robot(pos, name) then
			core.remove_node(pos)
			return true -- keep the item
		end
	end,

	on_rightclick = function(pos, node, clicker, itemstack)
		if not clicker or not clicker:is_player() then return itemstack end
		local name = clicker:get_player_name()
		local rec = base_record(pos)
		if not rec then
			local meta_owner = core.get_meta(pos):get_string("owner")
			if meta_owner ~= "" and meta_owner ~= name and not luabots.is_admin(name) then
				core.chat_send_player(name, S("This robot belongs to @1.", meta_owner))
				return itemstack
			end
			if core.is_protected(pos, name) then
				core.record_protection_violation(pos, name)
				return itemstack
			end
			rec = create_robot(pos, meta_owner ~= "" and meta_owner or name)
			if not rec then return itemstack end
		end
		if name == rec.owner or luabots.is_admin(name) then
			luabots.show_editor(name, rec)
		else
			core.chat_send_player(name, S("This robot belongs to @1.", rec.owner))
		end
		return itemstack
	end,

	can_dig = function(pos, player)
		local rec = base_record(pos)
		if not rec then return true end
		local name = player and player:get_player_name() or ""
		if name ~= rec.owner and not luabots.is_admin(name) then
			return false
		end
		if not luabots.inventory_is_empty(rec) then
			core.chat_send_player(name, S("Empty the robot inventory before removing its base."))
			return false
		end
		return true
	end,

	on_destruct = function(pos)
		local rec = base_record(pos)
		if not rec then return end
		-- base destroyed by other means (explosion, ...)
		destroy_robot(rec)
	end,

	on_blast = function(pos)
		-- robots bases resist explosions
	end,
})

-- Bases removed without on_destruct (VoxelManip, WorldEdit, swap_node...): delete their robots too
local orphan_timer = 0
core.register_globalstep(function(dtime)
	orphan_timer = orphan_timer + dtime
	if orphan_timer < 5 then return end
	orphan_timer = 0
	for _, rec in pairs(luabots.records) do
		local node = core.get_node_or_nil(rec.home)
		if node and node.name ~= "luabots:base" then
			core.log("action", ("[luabots] base of %s (%s) is gone, robot removed"):format(
				luabots.display_name(rec), rec.id))
			destroy_robot(rec)
		end
	end
end)

-- Keyboard keys

local function key_event(pos, player, action)
	if not player or not player:is_player() then return end
	local node = core.get_node(pos)
	local id = core.get_meta(pos):get_string("robot_id")
	if id == "" then return end
	luabots.push_event(id, "keyboard", {
		player = player:get_player_name(),
		key = node.name:sub(#"luabots:key_" + 1),
		pos = util.plain_pos(pos),
		action = action,
	})
end

for key in pairs(luabots.KEYS) do
	local tex
	if luabots.KEY_COLORS[key] then
		tex = "luabots_key.png^[multiply:" .. luabots.KEY_COLORS[key]
	elseif key == "blank" then
		tex = "luabots_key.png"
	else
		tex = "luabots_key.png^luabots_glyph_" .. key .. ".png"
	end
	core.register_node("luabots:key_" .. key, {
		description = S("Robot key (@1)", key),
		tiles = {tex},
		is_ground_content = false,
		groups = {dig_immediate = 2, luabots_key = 1, not_in_creative_inventory = 1,
			handy = 1, oddly_breakable_by_hand = 3},
		_mcl_hardness = 0.2,
		drop = "",
		sounds = compat.stone_sounds(),
		on_punch = function(pos, node, puncher)
			key_event(pos, puncher, "punch")
		end,
		on_rightclick = function(pos, node, clicker, itemstack)
			key_event(pos, clicker, "rightclick")
			return itemstack
		end,
	})
end

-- Remote control

local function remote_send(itemstack, user, pointed, action)
	if not user or not user:is_player() then return end
	local name = user:get_player_name()
	local rec, msg, revoked = luabots.remote_record(itemstack)
	if not rec then
		core.chat_send_player(name, msg)
		if revoked then luabots.forget_remote(itemstack) end
		return
	end
	local id = rec.id
	local pos
	if pointed and pointed.type == "node" then
		pos = util.plain_pos(pointed.under)
	elseif pointed and pointed.type == "object" then
		pos = util.plain_pos(vector.round(pointed.ref:get_pos()))
	end
	local st = luabots.states[rec.id]
	local running = st and st.status == "running"
	if running and not st.remote_listening or user:get_player_control().sneak then
		-- control panel (start, stop, console). Clicks only go to programs
		-- that read them with remote.receive(); sneak + use always opens it.
		luabots.show_remote_panel(name, rec)
		return
	elseif not running then
		-- the owner drives it by hand; friends get the control panel
		if name == rec.owner or luabots.is_admin(name) then
			luabots.show_manual(name, rec)
		else
			luabots.show_remote_panel(name, rec)
		end
		return
	end
	if not luabots.push_event(id, "remote", {player = name, action = action, pos = pos}) then
		core.chat_send_player(name, S("Robot @1 is not running.", luabots.display_name(rec)))
	end
end

core.register_tool("luabots:remote", {
	description = S("Robot Remote Control") .. "\n" .. core.colorize("#9fe0ff",
		S("Place on a robot base to link it. Use it to drive the robot, or to send events to its program") ..
		"\n" .. S("Sneak + use: start and stop it (anyone holding it can)")),
	inventory_image = "luabots_remote.png",
	stack_max = 1,
	range = 16,
	on_use = function(itemstack, user, pointed)
		remote_send(itemstack, user, pointed, "use")
		return itemstack
	end,
	on_place = function(itemstack, placer, pointed)
		if pointed.type == "node" and placer and placer:is_player() then
			local node = core.get_node(pointed.under)
			if node.name == "luabots:base" then
				local rec = base_record(pointed.under)
				local name = placer:get_player_name()
				if rec and (rec.owner == name or luabots.is_admin(name)) then
					luabots.link_remote(itemstack, rec)
					core.chat_send_player(name, S("Remote linked to @1.", luabots.display_name(rec)))
					return itemstack
				end
			end
			-- let nodes with a right-click action work normally
			local def = core.registered_nodes[node.name]
			if def and def.on_rightclick and not placer:get_player_control().sneak then
				return def.on_rightclick(pointed.under, node, placer, itemstack, pointed)
			end
		end
		remote_send(itemstack, placer, pointed, "place")
		return itemstack
	end,
	on_secondary_use = function(itemstack, user, pointed)
		remote_send(itemstack, user, pointed, "place")
		return itemstack
	end,
})

-- Data disk

local disk_ctx = {}

-- Disk window: same look as the program editor (Edit / Line numbers tabs)
local function show_disk(name, stack)
	local ctx = disk_ctx[name]
	local meta = stack:get_meta()
	ctx.title = ctx.title or meta:get_string("title")
	ctx.text = ctx.text or meta:get_string("text")
	local gui = luabots.gui
	local esc = core.formspec_escape
	local lines = ctx.view == "lines"
	local fs = {
		gui.header(16, 12, luabots.util.hypertext_escape(S("Data disk")), 3.2),
		"label[3.7,0.45;", core.colorize("#9aa1aa", esc(S("Title"))), "]",
		"box[4.55,0.17;6.6,0.56;#0f1114]",
		"field[4.65,0.17;6.5,0.56;title;;", esc(ctx.title), "]",
		"field_close_on_enter[title;false]",
		gui.color_button(lines and "tab_lines" or "tab_edit", "cyan"),
		"button[0.35,1.2;2.1,0.5;tab_edit;", esc(S("Edit")), "]",
		"button[2.55,1.2;2.9,0.5;tab_lines;", esc(S("Line numbers")), "]",
		"label[5.8,1.45;", core.colorize("#9aa1aa",
			esc(S("Put it in the LIBRARY slots of a robot: require('title')"))), "]",
		gui.panel(0.35, 1.82, 15.3, 8.98),
	}
	if lines then
		fs[#fs + 1] = gui.numbered_code("lines", 0.41, 1.88, 15.18, 8.86, ctx.text)
	else
		fs[#fs + 1] = "style[text;font=mono;textcolor=#e0e3e7]"
		fs[#fs + 1] = "set_focus[text;true]"   -- before the element it focuses
		fs[#fs + 1] = ("textarea[0.47,1.9;15.1,8.82;text;;%s]"):format(esc(ctx.text))
	end
	fs[#fs + 1] = ("label[0.35,11.45;%s]"):format(core.colorize("#666c74",
		esc(S("@1 characters", #ctx.text))))
	fs[#fs + 1] = "button_exit[8.7,11.1;3.4,0.6;close;" .. esc(S("Close")) .. "]"
	fs[#fs + 1] = gui.color_button("save", "cyan")
	fs[#fs + 1] = "button_exit[12.25,11.1;3.4,0.6;save;" .. esc(S("Save")) .. "]"
	core.show_formspec(name, "luabots:disk", table.concat(fs))
end

core.register_craftitem("luabots:disk", {
	description = S("Data disk") .. "\n" .. core.colorize("#9fe0ff",
		S("Robots can read and write it. Use it to read or edit.")),
	inventory_image = "luabots_disk.png",
	stack_max = 1,   -- each disk has its own content
	on_use = function(itemstack, user)
		if not user or not user:is_player() then return end
		local name = user:get_player_name()
		disk_ctx[name] = {index = user:get_wield_index()}
		show_disk(name, itemstack)
	end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:disk" then return false end
	local name = player:get_player_name()
	local ctx = disk_ctx[name]
	if not ctx then return true end
	-- keep what was typed (the text area is not sent from the line view)
	if fields.title then ctx.title = fields.title:sub(1, 80):gsub("%c", " ") end
	if fields.text then ctx.text = fields.text:sub(1, 65536) end
	local inv = player:get_inventory()
	local stack = inv:get_stack("main", ctx.index)
	local holding = stack:get_name() == "luabots:disk"
	if fields.tab_edit or fields.tab_lines then
		ctx.view = fields.tab_lines and "lines" or nil
		if holding then show_disk(name, stack) end
		return true
	end
	if not fields.save then
		if fields.quit or fields.close then disk_ctx[name] = nil end
		return true
	end
	disk_ctx[name] = nil
	if not holding or stack:get_count() ~= 1 then
		if holding then
			core.chat_send_player(name, S("Hold a single disk to write it."))
		end
		return true
	end
	luabots.write_disk(stack, ctx.title, ctx.text, name)
	inv:set_stack("main", ctx.index, stack)
	return true
end)

core.register_on_leaveplayer(function(player)
	disk_ctx[player:get_player_name()] = nil
end)

-- Recipes (only when the game provides the materials) 

local metal = compat.material("metal")
local gem = compat.material("gem")
local glass = compat.material("glass")
local paper = compat.material("paper")
local copper = compat.material("copper")

if metal and gem and glass then
	core.register_craft({
		output = "luabots:base",
		recipe = {
			{metal, glass, metal},
			{metal, gem, metal},
			{metal, metal, metal},
		},
	})
	core.register_craft({
		output = "luabots:screen 2",
		recipe = {
			{metal, metal, metal},
			{metal, glass, metal},
			{metal, metal, metal},
		},
	})
	core.register_craft({
		output = "luabots:remote",
		recipe = {
			{"", gem, ""},
			{metal, glass, metal},
			{metal, metal, metal},
		},
	})
end
if paper and (copper or metal) then
	core.register_craft({
		output = "luabots:disk",
		recipe = {
			{paper, copper or metal, paper},
		},
	})
end
