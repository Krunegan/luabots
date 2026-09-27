-- The robot body (an entity drawn like a small robot-shaped node)

local S = luabots.S
local config = luabots.config
local util = luabots.util

-- Model nodes: one per skin and status (eye colour shows the status)
local EYES = {
	on = "#58f0ff",    -- running
	off = "#5a6068",   -- stopped / finished
	err = "#ff4a3a",   -- error
}

-- Node box of the robot (units of 1/16 node)
local function box(x1, y1, z1, x2, y2, z2)
	return {x1 / 16, y1 / 16, z1 / 16, x2 / 16, y2 / 16, z2 / 16}
end
local MODEL_BOXES = {
	box(-7, -8, -6, 7, -5, 6),    -- treads
	box(-6, -5, -5, 6, 2, 5),     -- body
	box(-5, 2, -4, 5, 7, 5),      -- head
	box(-1, 7, 0, 1, 8, 2),       -- antenna
	box(-8, -3, -1, -6, 1, 2),    -- right arm
	box(6, -3, -1, 8, 1, 2),      -- left arm
}

local function tile(base, accent, eyes, skin_color, eye_color)
	local t = base .. "^(" .. accent .. "^[multiply:" .. skin_color .. ")"
	if eyes then
		t = t .. "^(" .. eyes .. "^[multiply:" .. eye_color .. ")"
	end
	return t
end

for skin_i, skin in ipairs(luabots.SKINS) do
	for state, eye_color in pairs(EYES) do
		local c = skin.color
		core.register_node(("luabots:model_%d_%s"):format(skin_i, state), {
			description = "LuaBots robot model",
			drawtype = "nodebox",
			paramtype = "light",
			node_box = {type = "fixed", fixed = MODEL_BOXES},
			tiles = {
				tile("luabots_robot_top.png", "luabots_robot_top_accent.png", nil, c),
				tile("luabots_robot_bottom.png", "luabots_robot_bottom_accent.png", nil, c),
				tile("luabots_robot_side.png", "luabots_robot_side_accent.png", nil, c),
				tile("luabots_robot_side.png", "luabots_robot_side_accent.png", nil, c),
				tile("luabots_robot_front.png", "luabots_robot_front_accent.png",
					"luabots_robot_eyes.png", c, eye_color),
				tile("luabots_robot_back.png", "luabots_robot_back_accent.png", nil, c),
			},
			groups = {not_in_creative_inventory = 1},
			drop = "",
			pointable = false,
			diggable = false,
		})
	end
end

local GLOW = 6

local function eye_state(rec)
	local st = luabots.states[rec.id]
	local status = st and st.status or "stopped"
	return status == "running" and "on" or (status == "error" and "err" or "off")
end

local function model_name(rec)
	local skin = rec.skin or 1
	if not luabots.SKINS[skin] then skin = 1 end
	return ("luabots:model_%d_%s"):format(skin, eye_state(rec))
end

function luabots.update_body_look(rec)
	local body = luabots.get_body(rec.id)
	if not body then return end
	local s = rec.size or 1
	local props = {
		visual = "node",
		node = {name = model_name(rec)},
		visual_size = {x = s, y = s, z = s},
		collisionbox = {-0.45 * s, -0.5 * s, -0.45 * s, 0.45 * s, 0.45 * s, 0.45 * s},
		selectionbox = {-0.45 * s, -0.5 * s, -0.45 * s, 0.45 * s, 0.45 * s, 0.45 * s},
		nametag = rec.label or "",
		nametag_color = "#aee8ff",
		-- a little light while running (or on error) so the eyes show at night
		glow = eye_state(rec) == "off" and 0 or GLOW,
		infotext = luabots.display_name(rec) .. "\n" .. luabots.status_text(rec),
	}
	-- custom look chosen by the program (robot.appearance)
	local a = rec.appearance
	if a then
		props.visual = a.visual
		props.mesh = a.mesh
		props.textures = a.textures
		props.visual_size = {x = a.size.x * s, y = a.size.y * s, z = a.size.z * s}
	end
	body:set_properties(props)
	if a and a.animation then
		local an = a.animation
		body:set_animation({x = an[1], y = an[2]}, an[3], an[4])
	end
	if luabots.update_face_display and (rec.display or luabots.get_state(rec.id).display_obj) then
		luabots.update_face_display(rec)
	end
end

core.register_entity("luabots:robot", {
	initial_properties = {
		visual = "node",
		node = {name = "luabots:model_1_off"},
		-- solid for players (they can stand on it); robots still move through them
		physical = true,
		collide_with_objects = true,
		pointable = true,
		collisionbox = {-0.45, -0.5, -0.45, 0.45, 0.45, 0.45},
		selectionbox = {-0.45, -0.5, -0.45, 0.45, 0.45, 0.45},
		hp_max = config.robot_hp,
		static_save = true,
		makes_footstep_sound = false,
		nametag = "",
	},

	on_activate = function(self, staticdata)
		local id = staticdata ~= "" and staticdata or nil
		local rec = luabots.get_record(id)
		if not rec or not rec.spawned then
			self.object:remove()
			return
		end
		local existing = luabots.get_body(id)
		if existing and existing ~= self.object then
			self.object:remove()
			return
		end
		self.robot_id = id
		local st = luabots.get_state(id)
		st.body = self.object
		self.object:set_armor_groups(config.mortal and {fleshy = 100} or {immortal = 1})
		self.object:set_pos(rec.pos)
		self.object:set_yaw(luabots.body_yaw(rec))
		luabots.occupy(rec)
		luabots.update_body_look(rec)
		-- Program was running before the server restarted
		if rec.running and st.status ~= "running" then
			core.after(0, function()
				local r = luabots.get_record(id)
				if not r or not r.running or luabots.get_state(id).status == "running" then return end
				if config.autostart then
					luabots.start(r, S("restarted after server restart"), nil, "server restart")
				else
					luabots.stop(r, "stopped")
				end
			end)
		end
	end,

	get_staticdata = function(self)
		return self.robot_id or ""
	end,

	on_deactivate = function(self)
		local st = luabots.states[self.robot_id or ""]
		if st and st.body == self.object then st.body = nil end
	end,

	on_punch = function(self)
		-- returning true prevents damage
		return not config.mortal
	end,

	on_death = function(self)
		local rec = luabots.get_record(self.robot_id)
		if not rec then return end
		luabots.stop(rec, "error", "[" .. S("robot destroyed") .. "]")
		rec.spawned = false
		luabots.release(rec)
		rec.pos = vector.offset(rec.home, 0, 1, 0)
		luabots.mark_dirty(rec.id)
		local st = luabots.states[rec.id]
		if st then
			st.body = nil
			if st.display_obj then st.display_obj:remove() end
			st.display_obj = nil
		end
	end,

	on_rightclick = function(self, clicker)
		local rec = luabots.get_record(self.robot_id)
		if not rec or not clicker or not clicker:is_player() then return end
		local name = clicker:get_player_name()
		if name == rec.owner or luabots.is_admin(name) then
			luabots.show_editor(name, rec)
		else
			core.chat_send_player(name, S("This robot belongs to @1.", rec.owner))
		end
	end,
})
