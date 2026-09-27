-- Building: blueprints (copy a structure onto a data disk and build it again somewhere else) and build.fill (floors, walls, roofs).
-- Blueprints are stored relative to the robot that scanned them: x to its right, y up, z forward. A robot builds them in front of itself, starting at the node in front of it and going to its right, so the structure turns with the robot (the direction of stairs, doors... turns too).

local util = luabots.util
local sandbox = luabots.sandbox

local HEADER = "LUABOTS BLUEPRINT 1"
local MAX_SIDE = 64
local MAX_NODES = {player = 4096, advanced = 32768, admin = 262144}

-- Rotating directions around Y

-- quarter turns to the left (the way robot.facing grows)
local function rotate(v, q)
	local x, z = v.x, v.z
	for _ = 1, q % 4 do x, z = -z, x end
	return vector.new(x, v.y, z)
end

local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

-- param2 of a node turned q quarter turns (facedir, 4dir, wallmounted)
local function rotate_param2(name, p2, q)
	if q % 4 == 0 then return p2 end
	local def = core.registered_nodes[name]
	local pt = def and def.paramtype2
	if pt == "facedir" or pt == "colorfacedir" then
		local low = p2 % 32
		local group = low - low % 4
		if group ~= 0 and group ~= 20 then return p2 end   -- only turned around Y
		local want = rotate(core.facedir_to_dir(low), q)
		for c = group, group + 3 do
			if same(core.facedir_to_dir(c), want) then return p2 - low + c end
		end
	elseif (pt == "4dir" or pt == "color4dir") and core.fourdir_to_dir then
		local low = p2 % 4
		local want = rotate(core.fourdir_to_dir(low), q)
		for c = 0, 3 do
			if same(core.fourdir_to_dir(c), want) then return p2 - low + c end
		end
	elseif pt == "wallmounted" or pt == "colorwallmounted" then
		local low = p2 % 8
		if low < 2 or low > 5 then return p2 end
		local want = rotate(core.wallmounted_to_dir(low), q)
		for c = 2, 5 do
			if same(core.wallmounted_to_dir(c), want) then return p2 - low + c end
		end
	end
	return p2
end

-- Scanning

local function scan(bot, pos1, pos2)
	local rec = bot.rec
	pos1 = vector.round(util.check_pos(pos1, "pos1"))
	pos2 = vector.round(util.check_pos(pos2, "pos2"))
	local pmin, pmax = vector.sort(pos1, pos2)
	local size = vector.add(vector.subtract(pmax, pmin), 1)
	if size.x > MAX_SIDE or size.y > MAX_SIDE or size.z > MAX_SIDE then
		return nil, "area too big (max " .. MAX_SIDE .. " per side)"
	end
	local limit = MAX_NODES[bot.level.name] or MAX_NODES.player
	if size.x * size.y * size.z > limit then
		return nil, "area too big (max " .. limit .. " nodes for your level)"
	end
	if not bot.in_range(pmin) or not bot.in_range(pmax) then return nil, "out of range" end
	bot.ctx.used = bot.ctx.used + size.x * size.y * size.z / 4

	local vm = core.get_voxel_manip(pmin, pmax)
	local emin, emax = vm:read_from_map(pmin, pmax)
	local area = VoxelArea(emin, emax)
	local data, p2data = vm:get_data(), vm:get_param2_data()
	local c_air, c_ignore = core.CONTENT_AIR, core.CONTENT_IGNORE

	-- robot frame: x right, y up, z forward (turn the world by -facing)
	local f = rec.facing % 4
	local function frame(p)
		local d = rotate(vector.subtract(p, rec.pos), -f)
		return d
	end
	local fmin
	for _, cx in ipairs({pmin.x, pmax.x}) do
		for _, cz in ipairs({pmin.z, pmax.z}) do
			local d = frame(vector.new(cx, pmin.y, cz))
			fmin = fmin and vector.new(math.min(fmin.x, d.x), d.y, math.min(fmin.z, d.z)) or d
		end
	end
	local fsize = rotate(size, f % 2) -- width and depth swap every quarter turn
	fsize = vector.new(math.abs(fsize.x), size.y, math.abs(fsize.z))

	local palette, index = {}, {}
	local out = {}
	for z = pmin.z, pmax.z do
		for y = pmin.y, pmax.y do
			for x = pmin.x, pmax.x do
				local c = data[area:index(x, y, z)]
				if c == c_ignore then return nil, "area not loaded" end
				if c ~= c_air then
					local name = core.get_name_from_content_id(c)
					local i = index[name]
					if not i then
						palette[#palette + 1] = name
						i = #palette
						index[name] = i
					end
					local d = vector.subtract(frame(vector.new(x, y, z)), fmin)
					local p2 = rotate_param2(name, p2data[area:index(x, y, z)], -f)
					out[#out + 1] = ("%d,%d,%d,%d,%d"):format(d.x, d.y, d.z, i, p2)
				end
			end
		end
	end
	local text = table.concat({
		HEADER,
		("size %d %d %d"):format(fsize.x, fsize.y, fsize.z),
		"palette " .. table.concat(palette, " "),
		table.concat(out, ";"),
	}, "\n")
	if #text > 65536 then return nil, "the blueprint does not fit on a disk (too many nodes)" end
	return text, #out
end

-- Reading a blueprint: text, or the title of a disk in the library slots
local function blueprint_text(bot, src)
	util.check_string(src, "blueprint", 70000)
	if src:sub(1, #HEADER) == HEADER then return src end
	local inv = luabots.get_inventory(bot.rec)
	for i = 1, luabots.INV_SIZES.disks do
		local title, text = luabots.read_book(inv:get_stack("disks", i))
		if title == src then return text end
	end
	for i = 1, inv:get_size("main") do
		local title, text = luabots.read_book(inv:get_stack("main", i))
		if title == src then return text end
	end
	return nil, "no blueprint called '" .. src .. "'"
end

-- The item that places a node: itself, or for nodes players cannot have (the halves of a door, wall torches...) the item they drop. nil: nothing to place (the hidden top of a door).
local function item_for(name)
	local def = core.registered_nodes[name]
	if not def or ((def.groups or {}).not_in_creative_inventory or 0) == 0 then return name end
	if type(def.drop) == "string" then
		local item = ItemStack(def.drop):get_name()
		if item == "" then return nil end
		if core.registered_items[item] then return item end
	end
	return name
end

-- Nodes to place, in building order (bottom up, zigzag), with param2 turned to the robot's current facing
local function parse(bot, src)
	local text, err = blueprint_text(bot, src)
	if not text then return nil, err end
	local lines = {}
	for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
	if lines[1] ~= HEADER then return nil, "not a blueprint" end
	local sx, sy, sz = (lines[2] or ""):match("^size (%d+) (%d+) (%d+)$")
	if not sx then return nil, "broken blueprint" end
	local palette = {}
	for name in (lines[3] or ""):gsub("^palette ", ""):gmatch("%S+") do palette[#palette + 1] = name end
	local f = bot.rec.facing % 4
	local nodes = {}
	for x, y, z, i, p2 in (lines[4] or ""):gmatch("(%-?%d+),(%-?%d+),(%-?%d+),(%d+),(%d+)") do
		local name = palette[tonumber(i)]
		if name then
			local item = item_for(name)
			if item then
				nodes[#nodes + 1] = {x = tonumber(x), y = tonumber(y), z = tonumber(z), name = name,
					item = item, param2 = rotate_param2(name, tonumber(p2), f)}
			end
		end
		if #nodes > MAX_NODES.admin then break end
	end
	bot.ctx.used = bot.ctx.used + #nodes * 4
	table.sort(nodes, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		if a.z ~= b.z then return a.z < b.z end
		if a.z % 2 == 0 then return a.x < b.x end
		return a.x > b.x
	end)
	return {size = {x = tonumber(sx), y = tonumber(sy), z = tonumber(sz)}, nodes = nodes}
end

-- Building (runs inside the sandbox, so it pauses and counts like a program)

local BUILDER = [[
local move, place, sense, error, tostring = move, place, sense, error, tostring
local plan = ...

-- Place 'nodes' (x right, y up, z forward; 0,0,0 = the node in front of the
-- robot). The robot flies one node above each one and places it downwards.
function plan.build_nodes(nodes, label)
	local cx, cy, cz = 0, 0, -1
	local placed, skipped = 0, 0
	local function step(dir, dx, dy, dz)
		local ok, why = move[dir]()
		if not ok then
			error(label .. ": cannot move " .. dir .. " (" .. tostring(why) .. ")", 0)
		end
		cx, cy, cz = cx + dx, cy + dy, cz + dz
	end
	local function go(tx, ty, tz)
		while cy < ty do step("up", 0, 1, 0) end
		while cx < tx do step("right", 1, 0, 0) end
		while cx > tx do step("left", -1, 0, 0) end
		while cz < tz do step("forward", 0, 0, 1) end
		while cz > tz do step("back", 0, 0, -1) end
		while cy > ty do step("down", 0, -1, 0) end
	end
	local top = 0
	for i = 1, #nodes do
		local n = nodes[i]
		if n.y + 1 > top then top = n.y + 1 end
		go(n.x, n.y + 1, n.z)
		if sense.node("down") ~= n.name then
			local item = n.item or n.name
			local ok, why = place.down(item, item == n.name and n.param2 or nil)
			if ok then
				placed = placed + 1
			elseif why == "item not in inventory" then
				error(label .. ": missing " .. item .. " (" .. placed .. " placed)", 0)
			else
				skipped = skipped + 1
			end
		end
	end
	-- back to where it started
	go(cx, top, cz)
	go(0, top, -1)
	go(0, 0, -1)
	return placed, skipped
end
]]

luabots.register_api(function(bot, env)
	local wrap = bot.wrap

	local blueprint, build = {}, {}
	env.blueprint, env.build = blueprint, build

	-- blueprint.scan(pos1, pos2): the structure between two corners, as text (write it on a disk with books.write)
	blueprint.scan = wrap("blueprint.scan", function(pos1, pos2)
		return scan(bot, pos1, pos2)
	end, 500)

	-- blueprint.save(title, text): write a blueprint on a disk of the robot: a disk that already has this title, or else a blank one (library first)
	blueprint.save = wrap("blueprint.save", function(title, text)
		util.check_string(title, "title", 80)
		util.check_string(text, "blueprint", 65536)
		if title == "" then util.api_error("the title cannot be empty") end
		if text:sub(1, #HEADER) ~= HEADER then return false, "not a blueprint" end
		local rec = bot.rec
		local inv = luabots.get_inventory(rec)
		local function find(want_title)
			for _, list in ipairs({"disks", "main"}) do
				for i = 1, inv:get_size(list) do
					local stack = inv:get_stack(list, i)
					if stack:get_name() == "luabots:disk" and stack:get_meta():get_string("title") == want_title then
						return list, i
					end
				end
			end
		end
		local list, i = find(title)
		if not list then list, i = find("") end
		if not list then return false, "no blank disk in the robot" end
		local stack = inv:get_stack(list, i)
		if stack:get_count() > 1 then
			-- write one disk of the stack and keep the rest
			local one = luabots.write_disk(stack:take_item(1), title, text, rec.owner)
			inv:set_stack(list, i, stack)
			local left = inv:add_item("main", one)
			if not left:is_empty() then core.add_item(rec.pos, left) end
		else
			inv:set_stack(list, i, luabots.write_disk(stack, title, text, rec.owner))
		end
		luabots.mark_dirty(rec.id)
		bot.act(0.5)
		return true
	end, 300)

	-- blueprint.read(name): {size = {x, y, z}, nodes = {...}} of a blueprint (disk title in the library or main inventory, or the text itself)
	blueprint.read = wrap("blueprint.read", function(src)
		return parse(bot, src)
	end, 500)

	-- blueprint.materials(name): items needed, {["default:cobble"] = 20, ...}
	blueprint.materials = wrap("blueprint.materials", function(src)
		local bp, err = parse(bot, src)
		if not bp then return nil, err end
		local out = {}
		for _, n in ipairs(bp.nodes) do out[n.item] = (out[n.item] or 0) + 1 end
		return out
	end, 300)

	-- Builder code, compiled into the program environment
	local fn = sandbox.compile(BUILDER, bot.level, "builder")
	setfenv(fn, env)
	local plan = {}
	fn(plan)

	-- blueprint.build(name): build it in front of the robot
	function blueprint.build(src)
		local bp, err = blueprint.read(src)
		if not bp then return nil, err end
		return plan.build_nodes(bp.nodes, "blueprint.build")
	end

	-- build.fill(length, width, height, item): a solid box in front of the robot, to its right and up
	local check = wrap("build.fill", function(l, w, h, item)
		l = math.floor(util.check_number(l, "length", 1, MAX_SIDE))
		w = math.floor(util.check_number(w, "width", 1, MAX_SIDE))
		h = math.floor(util.check_number(h, "height", 1, MAX_SIDE))
		util.check_itemname(item, "item")
		local limit = MAX_NODES[bot.level.name] or MAX_NODES.player
		if l * w * h > limit then util.api_error("too big (max " .. limit .. " nodes for your level)") end
		return l, w, h
	end, 50)
	function build.fill(l, w, h, item)
		l, w, h = check(l, w, h, item)
		local nodes = {}
		for y = 0, h - 1 do
			for z = 0, l - 1 do
				for i = 0, w - 1 do
					local x = (z % 2 == 0) and i or (w - 1 - i)
					nodes[#nodes + 1] = {x = x, y = y, z = z, name = item}
				end
			end
		end
		return plan.build_nodes(nodes, "build.fill")
	end
end)