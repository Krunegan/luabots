-- Text displays: a screen on the robot face (robot.display) and the robot screen block (screen.write). Text is drawn with a 3x5 pixel font by combining one small texture per character.

local S = luabots.S
local util = luabots.util

local CW, CH = 4, 6 -- character cell in texture pixels (3x5 + spacing)
local MAX_COLS, MAX_ROWS = 40, 16
local MAX_CHARS = 320
local BG = "#0b0d10"
local FG = "#8ff3ff"

-- Characters with a glyph (see luabots_tests/key_textures.py)
local GLYPHS = {}
for c in ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
	GLYPHS[c] = true
end
local ACCENTS = {
	["á"] = "A", ["é"] = "E", ["í"] = "I", ["ó"] = "O", ["ú"] = "U", ["ü"] = "U", ["ñ"] = "N",
	["Á"] = "A", ["É"] = "E", ["Í"] = "I", ["Ó"] = "O", ["Ú"] = "U", ["Ü"] = "U", ["Ñ"] = "N",
	["à"] = "A", ["è"] = "E", ["ì"] = "I", ["ò"] = "O", ["ù"] = "U", ["ç"] = "C", ["Ç"] = "C",
	["¿"] = "?", ["¡"] = "!",
}

-- Text as lines of drawable characters, wrapped at 'cols'
local function layout(text, cols)
	local chars = {}
	for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if ch == "\n" then
			chars[#chars + 1] = "\n"
		elseif ch == "\t" then
			chars[#chars + 1] = " "
		else
			local up = ACCENTS[ch] or ch:upper()
			chars[#chars + 1] = GLYPHS[up] and up or "?"
		end
		if #chars >= MAX_CHARS then break end
	end
	local lines = {}
	local line = {}
	for _, ch in ipairs(chars) do
		if ch == "\n" or #line >= cols then
			lines[#lines + 1] = table.concat(line)
			line = {}
			if #lines >= MAX_ROWS then return lines end
		end
		if ch ~= "\n" and not (ch == " " and #line == 0 and #lines > 0) then
			line[#line + 1] = ch
		end
	end
	if #line > 0 or #lines == 0 then lines[#lines + 1] = table.concat(line) end
	while #lines > MAX_ROWS do table.remove(lines) end
	return lines
end

-- Texture with the text; returns texture, width, height (texture pixels)
function luabots.text_texture(text, cols, color)
	local lines = layout(text, cols)
	local width = 1
	for _, l in ipairs(lines) do width = math.max(width, #l) end
	local W, H = width * CW + 1, #lines * CH + 1
	local parts = {}
	for row, l in ipairs(lines) do
		for col = 1, #l do
			local ch = l:sub(col, col)
			if ch ~= " " then
				parts[#parts + 1] = ("%d,%d=luabots_ch_%d.png"):format(
					1 + (col - 1) * CW, 1 + (row - 1) * CH, ch:byte())
			end
		end
	end
	local glyphs = ("[combine:%dx%d"):format(W, H)
	if #parts > 0 then glyphs = glyphs .. ":" .. table.concat(parts, ":") end
	-- scaled up so filtering does not blur the pixel font
	local tex = ("[fill:%dx%d:%s^(%s^[multiply:%s)^[resize:%dx%d"):format(
		W, H, BG, glyphs, color or FG, W * 4, H * 4)
	return tex, W, H
end

local function cube_textures(tex)
	-- +Y, -Y, +X, -X, +Z (front), -Z
	return {"blank.png", "blank.png", "blank.png", "blank.png", tex, "blank.png"}
end

core.register_entity("luabots:display", {
	initial_properties = {
		visual = "cube",
		textures = cube_textures("blank.png"),
		use_texture_alpha = true,
		physical = false,
		collide_with_objects = false,
		pointable = false,
		static_save = false,
		glow = 8,
		visual_size = {x = 0.5, y = 0.5, z = 0.01},
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
	end,
})

-- Robot face

-- Show or remove the screen on the front of the robot body
function luabots.update_face_display(rec)
	local st = luabots.get_state(rec.id)
	local body = luabots.get_body(rec.id)
	local obj = st.display_obj
	if obj and not obj:get_pos() then obj = nil end
	local d = rec.display
	if not d or not body then
		if obj then obj:remove() end
		st.display_obj = nil
		return
	end
	local tex, W, H = luabots.text_texture(d.text, d.cols, d.color)
	local s = (rec.size or 1)
	-- fit the robot chest (12/16 x 7/16 node), scaled by 'size'
	local w = 0.72 * d.size
	local h = w * H / W
	local max_h = 0.42 * d.size
	if h > max_h then
		w = w * max_h / h
		h = max_h
	end
	if not obj then
		obj = core.add_entity(body:get_pos(), "luabots:display")
		if not obj then return end
		st.display_obj = obj
	end
	obj:set_properties({
		textures = cube_textures(tex),
		visual_size = {x = w * s, y = h * s, z = 0.01},
	})
	-- attachment offsets are in 1/10 node; the chest centre is 1.5/16 below the middle and its front 5/16 ahead
	obj:set_attach(body, "", {x = 0, y = -0.94 * s, z = (3.125 + 0.1) * s}, {x = 0, y = 0, z = 0})
end

-- Screen block

local function screen_front(node)
	return vector.multiply(core.facedir_to_dir(node.param2 % 32), -1)
end

local function screen_objects(pos)
	local out = {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 0.9)) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "luabots:display" and ent.screen_pos
				and vector.equals(ent.screen_pos, pos) then
			out[#out + 1] = obj
		end
	end
	return out
end

-- Screens a program wrote without keep = true are cleared when it stops, unless someone wrote something else on them since
function luabots.clear_program_screens(st, id)
	for _, s in pairs(st.temp_screens or {}) do
		local meta = core.get_meta(s.pos)
		if core.get_node(s.pos).name == "luabots:screen" and meta:get_string("robot_id") == id
				and meta:get_string("text") == s.text then
			meta:set_string("text", "")
			meta:set_string("infotext", "")
			luabots.update_screen(s.pos)
		end
	end
	st.temp_screens = nil
end

function luabots.update_screen(pos)
	local node = core.get_node_or_nil(pos)
	if not node or node.name ~= "luabots:screen" then return end
	local meta = core.get_meta(pos)
	local text = meta:get_string("text")
	local objs = screen_objects(pos)
	for i = 2, #objs do objs[i]:remove() end
	local obj = objs[1]
	if text == "" then
		if obj then obj:remove() end
		return
	end
	local cols = meta:get_int("cols")
	if cols < 1 then cols = 16 end
	local color = meta:get_string("color")
	local tex, W, H = luabots.text_texture(text, cols, color ~= "" and color or nil)
	local w, h = 0.86, 0.86 * H / W
	if h > 0.86 then
		w, h = 0.86 * W / H, 0.86
	end
	local front = screen_front(node)
	local p = vector.add(pos, vector.multiply(front, 0.5 + 0.006))
	if not obj then
		obj = core.add_entity(p, "luabots:display")
		if not obj then return end
	end
	obj:get_luaentity().screen_pos = vector.copy(pos)
	obj:set_pos(p)
	obj:set_yaw(util.facing_to_yaw(util.vector_to_facing(front) or 0))
	obj:set_properties({textures = cube_textures(tex), visual_size = {x = w, y = h, z = 0.01}})
end

core.register_node("luabots:screen", {
	description = S("Robot Screen") .. "\n" .. core.colorize("#9fe0ff",
		S("Robots write on it with screen.write()")),
	tiles = {
		"luabots_screen_side.png", "luabots_screen_side.png", "luabots_screen_side.png",
		"luabots_screen_side.png", "luabots_screen_side.png", "luabots_screen_front.png",
	},
	paramtype = "light",
	paramtype2 = "facedir",
	light_source = 3,
	is_ground_content = false,
	groups = luabots.compat.node_groups({cracky = 3, oddly_breakable_by_hand = 2}),
	_mcl_hardness = 0.5,
	sounds = luabots.compat.metal_sounds(),
	on_rotate = false,
	after_destruct = function(pos)
		for _, obj in ipairs(screen_objects(pos)) do obj:remove() end
	end,
})

-- Entities are not saved: bring the text back when the area loads
core.register_lbm({
	label = "Show text of robot screens",
	name = "luabots:screen_text",
	nodenames = {"luabots:screen"},
	run_at_every_load = true,
	action = function(pos)
		core.after(0, luabots.update_screen, pos)
	end,
})

-- Program API

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec, st = bot.rec, bot.state
	local last = 0

	-- at most 10 display updates per second
	local function throttle()
		local wait = 0.1 - (luabots.now() - last)
		if wait > 0 then bot.sleep(wait) end
		last = luabots.now()
	end

	local function options(text, cols, color)
		text = util.check_string(tostring(text), "text", 2000)
		if cols ~= nil then cols = math.floor(util.check_number(cols, "cols", 1, MAX_COLS)) end
		if color ~= nil then color = util.check_color(color, "color") end
		return text, cols, color
	end

	-- Longest line (after wrapping at MAX_COLS) as the default width
	local function auto_cols(text, max)
		local longest = 1
		for l in (text .. "\n"):gmatch("(.-)\n") do
			longest = math.max(longest, #l)
		end
		return math.min(longest, max)
	end

	-- robot.display(text, cols, size, color): text on the robot face
	env.robot.display = wrap("robot.display", function(text, cols, size, color)
		if text == nil or text == "" then
			rec.display = nil
		else
			local t, c, col = options(text, cols, color)
			size = util.check_number(size or 1, "size", 0.2, 3)
			rec.display = {text = t, cols = c or auto_cols(t, 12), size = size, color = col}
		end
		throttle()
		luabots.mark_dirty(rec.id)
		luabots.update_face_display(rec)
		return true
	end, 100)

	-- screen.write(dir, text, cols, color, keep) / screen.clear(dir)
	-- The text is cleared when the program stops, unless keep is true.
	local screen = {}
	env.screen = screen
	-- a direction next to the robot, or the position of a screen it can sense
	local function target_screen(dir)
		local pos
		if type(dir) == "table" then
			pos = vector.round(util.check_pos(dir, "position"))
			if vector.distance(pos, rec.pos) > bot.level.sense_radius then return nil, "too far" end
		else
			pos = luabots.api_target(bot, dir)
		end
		if not bot.in_range(pos) then return nil, "out of range" end
		local node = core.get_node_or_nil(pos)
		if not node then return nil, "area not loaded" end
		if node.name ~= "luabots:screen" then return nil, "not a screen" end
		if core.is_protected(pos, rec.owner) then return nil, "protected" end
		return pos
	end

	screen.write = wrap("screen.write", function(dir, text, cols, color, keep)
		local pos, err = target_screen(dir)
		if not pos then return false, err end
		local t, c, col = options(text, cols, color)
		local meta = core.get_meta(pos)
		meta:set_string("text", t)
		meta:set_int("cols", c or auto_cols(t, 16))
		meta:set_string("color", col or "")
		meta:set_string("infotext", t)
		meta:set_string("robot_id", rec.id)
		local key = core.pos_to_string(pos)
		st.temp_screens = st.temp_screens or {}
		st.temp_screens[key] = (keep ~= true) and {pos = pos, text = t} or nil
		throttle()
		luabots.update_screen(pos)
		return true
	end, 150)

	screen.clear = wrap("screen.clear", function(dir)
		local pos, err = target_screen(dir)
		if not pos then return false, err end
		local meta = core.get_meta(pos)
		meta:set_string("text", "")
		meta:set_string("infotext", "")
		luabots.update_screen(pos)
		return true
	end, 100)
end)
