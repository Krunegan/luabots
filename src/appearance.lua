-- robot.appearance / robot.animation: change how the robot looks, like set_properties in basic_robot but limited to safe look properties that use media the server really has.

local util = luabots.util

-- Media files of every loaded mod. Like the engine, textures and models may be in any media folder (player_api keeps character.png next to its model).
local files = {["blank.png"] = true}
local media = {textures = files, models = files}
local function scan(dir, set, depth)
	for _, f in ipairs(core.get_dir_list(dir, false) or {}) do set[f] = true end
	if depth < 3 then
		for _, d in ipairs(core.get_dir_list(dir, true) or {}) do
			scan(dir .. "/" .. d, set, depth + 1)
		end
	end
end
core.register_on_mods_loaded(function()
	for _, mod in ipairs(core.get_modnames()) do
		local path = core.get_modpath(mod)
		if path then
			for _, dir in ipairs({"textures", "models", "media"}) do
				scan(path .. "/" .. dir, files, 0)
			end
		end
	end
end)
luabots.media = media

local VISUALS = {robot = true, mesh = true, cube = true, sprite = true, upright_sprite = true}

-- "name.png", optionally with one colour modifier: ^[multiply:#rgb or ^[colorize:#rgb:alpha
local function check_texture(t)
	util.check_string(t, "texture", 120)
	local name, mod = t:match("^([%w_%-%.]+%.%a%a%a)(.*)$")
	if not name or not media.textures[name] then
		util.api_error("unknown texture '" .. t .. "'")
	end
	if mod ~= "" and not (mod:match("^%^%[multiply:#?%w+$") or mod:match("^%^%[colorize:#?%w+:%d+$")) then
		util.api_error("texture modifiers allowed: ^[multiply:<color> and ^[colorize:<color>:<alpha>")
	end
	return t
end

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec = bot.rec

	-- robot.appearance({visual = "mesh", mesh = "x.b3d", textures = {...}, visual_size = {x=, y=, z=}})
	-- robot.appearance() goes back to the normal robot
	env.robot.appearance = wrap("robot.appearance", function(p)
		if p == nil then
			rec.appearance = nil
		else
			util.check_type(p, "table", "properties")
			local visual = rawget(p, "visual") or "cube"
			util.check_string(visual, "visual", 20)
			if not VISUALS[visual] then
				util.api_error("visual must be robot, mesh, cube, sprite or upright_sprite")
			end
			if visual == "robot" then
				rec.appearance = nil
			else
				local a = {visual = visual, textures = {}}
				if visual == "mesh" then
					local mesh = rawget(p, "mesh")
					util.check_string(mesh, "mesh", 120)
					if not media.models[mesh] then util.api_error("unknown mesh '" .. mesh .. "'") end
					a.mesh = mesh
				end
				local tex = rawget(p, "textures")
				if tex ~= nil then
					util.check_type(tex, "table", "textures")
					for i = 1, 6 do
						local t = rawget(tex, i)
						if t == nil then break end
						a.textures[i] = check_texture(t)
					end
				end
				if #a.textures == 0 then a.textures = {"blank.png"} end
				-- bigger robots only for admins; never too small to be seen
				local max = bot.level.name == "admin" and 10 or 3
				local vs = rawget(p, "visual_size") or {}
				util.check_type(vs, "table", "visual_size")
				local function dim(k)
					local v = rawget(vs, k)
					if v == nil then return 1 end
					return util.clamp(util.check_number(v, "visual_size." .. k, -1e6, 1e6), 0.2, max)
				end
				a.size = {x = dim("x"), y = dim("y"), z = dim("z")}
				local old = rec.appearance
				a.animation = old and old.mesh == a.mesh and old.animation or nil
				rec.appearance = a
			end
		end
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
		return true
	end, 200)

	-- robot.animation(first_frame, last_frame, speed, blend) for mesh looks
	env.robot.animation = wrap("robot.animation", function(first, last, speed, blend)
		local a = rec.appearance
		if not a or a.visual ~= "mesh" then return false, "the robot is not a mesh" end
		first = math.floor(util.check_number(first, "first_frame", 0, 100000))
		last = math.floor(util.check_number(last, "last_frame", first, 100000))
		speed = util.check_number(speed or 30, "speed", 0, 240)
		blend = util.check_number(blend or 0, "blend", 0, 10)
		a.animation = {first, last, speed, blend}
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
		return true
	end, 100)
end)
