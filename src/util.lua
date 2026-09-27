-- Small helpers shared by all modules

local util = {}
luabots.util = util

-- Facing index 0..3 matches yaw = index * 90 degrees
-- (0 = +Z north, 1 = -X west, 2 = -Z south, 3 = +X east)
util.facing_vectors = {
	[0] = vector.new(0, 0, 1),
	[1] = vector.new(-1, 0, 0),
	[2] = vector.new(0, 0, -1),
	[3] = vector.new(1, 0, 0),
}
util.facing_names = {[0] = "north", [1] = "west", [2] = "south", [3] = "east"}
util.facing_by_name = {north = 0, west = 1, south = 2, east = 3}

function util.facing_to_yaw(f)
	return (f % 4) * math.pi / 2
end

-- Facing index of a horizontal unit vector, or nil
function util.vector_to_facing(v)
	for f = 0, 3 do
		local d = util.facing_vectors[f]
		if d.x == v.x and d.z == v.z then return f end
	end
	return nil
end

function util.yaw_to_facing(yaw)
	return math.floor((yaw or 0) / (math.pi / 2) + 0.5) % 4
end

-- Relative directions understood by the robot API
-- Each entry: {horizontal = offset of facing (nil = none), y = vertical}
util.directions = {
	forward = {h = 0, y = 0},
	back = {h = 2, y = 0},
	left = {h = 1, y = 0},
	right = {h = 3, y = 0},
	up = {y = 1},
	down = {y = -1},
	forward_up = {h = 0, y = 1},
	forward_down = {h = 0, y = -1},
	back_up = {h = 2, y = 1},
	back_down = {h = 2, y = -1},
	left_up = {h = 1, y = 1},
	left_down = {h = 1, y = -1},
	right_up = {h = 3, y = 1},
	right_down = {h = 3, y = -1},
}
util.direction_list = {
	"forward", "back", "left", "right", "up", "down",
	"forward_up", "forward_down", "back_up", "back_down",
	"left_up", "left_down", "right_up", "right_down",
}
util.move_directions = {"forward", "back", "left", "right", "up", "down"}

-- Offset vector for a relative direction name, or nil
function util.dir_offset(facing, dirname)
	local d = util.directions[dirname]
	if not d then return nil end
	local off = vector.new(0, d.y, 0)
	if d.h then
		off = vector.add(off, util.facing_vectors[(facing + d.h) % 4])
	end
	return off
end

-- Errors raised by API functions (shown to the program, not logged as bugs)
local API_ERROR = {}
util.API_ERROR = API_ERROR

function util.api_error(msg)
	error({[API_ERROR] = true, msg = msg}, 0)
end

function util.is_api_error(e)
	return type(e) == "table" and rawget(e, API_ERROR) == true
end

function util.check_type(value, expected, argname)
	if type(value) ~= expected then
		util.api_error(("bad argument '%s' (%s expected, got %s)"):format(
			argname, expected, type(value)))
	end
	return value
end

function util.check_string(value, argname, maxlen)
	util.check_type(value, "string", argname)
	if maxlen and #value > maxlen then
		util.api_error(("argument '%s' is too long (max %d characters)"):format(argname, maxlen))
	end
	return value
end

-- Keep only color escapes (from colorize) and printable characters, with at
-- most max_visible visible characters
function util.clean_colored(text, max_visible)
	local out, visible, colors = {}, 0, 0
	local i, n = 1, #text
	while i <= n do
		local _, e, color = text:find("^\27%(c@([#%w]+)%)", i)
		if e then
			colors = colors + 1
			if #color <= 16 and colors <= 256 then out[#out + 1] = "\27(c@" .. color .. ")" end
			i = e + 1
		else
			local ch = text:sub(i, i)
			local b = ch:byte()
			if b < 32 or b == 127 then ch = " " end
			if b < 0x80 or b >= 0xC0 then visible = visible + 1 end  -- UTF-8 lead byte
			if visible > max_visible then break end
			out[#out + 1] = ch
			i = i + 1
		end
	end
	return table.concat(out)
end

function util.check_color(value, argname)
	util.check_string(value, argname, 16)
	if not value:match("^#?%w+$") then
		util.api_error(("bad argument '%s': use a color like \"#F00\", \"#ff8800\" or \"red\""):format(argname))
	end
	return value
end

function util.check_number(value, argname, min, max)
	if type(value) ~= "number" or value ~= value then
		util.api_error(("bad argument '%s' (number expected, got %s)"):format(argname, type(value)))
	end
	if min and value < min then value = min end
	if max and value > max then value = max end
	return value
end

-- Accepts {x=,y=,z=} tables with finite numbers and returns a rounded vector
function util.check_pos(value, argname)
	if type(value) ~= "table" then
		util.api_error(("bad argument '%s' (position {x=,y=,z=} expected)"):format(argname))
	end
	local x, y, z = rawget(value, "x"), rawget(value, "y"), rawget(value, "z")
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number"
			or x ~= x or y ~= y or z ~= z
			or math.abs(x) > 31000 or math.abs(y) > 31000 or math.abs(z) > 31000 then
		util.api_error(("bad argument '%s' (position {x=,y=,z=} expected)"):format(argname))
	end
	return vector.round(vector.new(x, y, z))
end

-- Validate an item name coming from a program
function util.check_itemname(value, argname)
	util.check_string(value, argname, 200)
	local name = ItemStack(value):get_name()
	if name == "" or not core.registered_items[name] then
		util.api_error(("unknown item '%s'"):format(value))
	end
	return name
end

-- Plain {x,y,z} copy without metatable, safe to hand to programs
function util.plain_pos(p)
	if not p then return nil end
	return {x = p.x, y = p.y, z = p.z}
end

-- Deep copy of plain data coming from a program.
-- Never triggers metamethods; drops functions/userdata/cycles.
-- budget: {left = number} counts elements and string bytes
function util.sanitize(value, budget, depth)
	depth = depth or 0
	local t = type(value)
	if t == "string" then
		budget.left = budget.left - #value
		if budget.left < 0 then util.api_error("data too large") end
		return value
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return 0 end
		budget.left = budget.left - 8
		return value
	elseif t == "boolean" then
		return value
	elseif t == "table" then
		if depth >= 16 then util.api_error("data nested too deeply") end
		local out = {}
		local k, v = next(value)
		while k ~= nil do
			budget.left = budget.left - 16
			if budget.left < 0 then util.api_error("data too large") end
			local kt = type(k)
			if kt == "string" or kt == "number" or kt == "boolean" then
				local cv = util.sanitize(v, budget, depth + 1)
				if cv ~= nil then
					out[util.sanitize(k, budget, depth + 1)] = cv
				end
			end
			k, v = next(value, k)
		end
		return out
	end
	return nil
end

function util.copy_data(value, max_bytes)
	return util.sanitize(value, {left = max_bytes or 65536})
end

-- tostring that never runs code from a program
function util.safe_tostring(v)
	local t = type(v)
	if t == "string" then return v end
	if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
	return "<" .. t .. ">"
end

-- Format an error value from a program without calling its metamethods
function util.format_error(e)
	if type(e) == "string" then return e end
	if util.is_api_error(e) then return e.msg end
	if type(e) == "number" or type(e) == "boolean" or e == nil then
		return "error: " .. tostring(e)
	end
	return "error object (" .. type(e) .. ")"
end

function util.distance(a, b)
	return vector.distance(a, b)
end

function util.pos_to_string(p)
	return ("(%d,%d,%d)"):format(p.x, p.y, p.z)
end

-- Escape text for hypertext[] (works on all supported engine versions)
function util.hypertext_escape(s)
	return (s:gsub("\\", "\\\\"):gsub("<", "\\<"):gsub(">", "\\>"))
end

function util.clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Returns the node def or a safe default
function util.node_def(name)
	return core.registered_nodes[name] or core.nodedef_default
end

function util.is_buildable(node)
	if not node then return false end
	local def = core.registered_nodes[node.name]
	return def and def.buildable_to or false
end

-- A robot can pass through nodes that are not walkable (air, water, plants...)
function util.is_passable(node)
	if not node or node.name == "ignore" then return false end
	local def = core.registered_nodes[node.name]
	if not def then return false end
	return not def.walkable
end
