-- Robot program runtime: start/stop, console, event queues and scheduler

local S = luabots.S
local config = luabots.config
local util = luabots.util
local sandbox = luabots.sandbox

local states = {}
luabots.states = states

local CONSOLE_LINES = 100
local QUEUE_MAX = 64

luabots.api_builders = {}

-- Register a function(bot, env) that adds API functions to programs
function luabots.register_api(builder)
	table.insert(luabots.api_builders, builder)
end

function luabots.get_state(id)
	local st = states[id]
	if not st then
		st = {
			id = id,
			status = "stopped",
			console = {},
			queues = {},
			wake = 0,
		}
		states[id] = st
	end
	return st
end

local function now()
	return core.get_us_time() / 1e6
end
luabots.now = now

-- Console

-- kind: nil (program output), "system" or "error"
function luabots.console(id, text, kind)
	local st = luabots.get_state(id)
	text = tostring(text)
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if #line > 400 then line = line:sub(1, 400) .. "..." end
		st.console[#st.console + 1] = {text = line, kind = kind}
	end
	while #st.console > CONSOLE_LINES do
		table.remove(st.console, 1)
	end
	st.console_changed = true
end

function luabots.clear_console(id)
	luabots.get_state(id).console = {}
end

-- Event queues

function luabots.push_event(id, queue, event)
	local st = states[id]
	if not st or st.status ~= "running" then return false end
	local q = st.queues[queue]
	if not q then
		q = {}
		st.queues[queue] = q
	end
	q[#q + 1] = event
	if #q > QUEUE_MAX then table.remove(q, 1) end
	return true
end

function luabots.pop_event(id, queue)
	local st = states[id]
	local q = st and st.queues[queue]
	if not q or #q == 0 then return nil end
	return table.remove(q, 1)
end

-- Bodies

function luabots.get_body(id)
	local st = states[id]
	local body = st and st.body
	if body and body:get_pos() then return body end
	if st then st.body = nil end
	return nil
end

function luabots.spawn_body(rec)
	local body = luabots.get_body(rec.id)
	if body then return body end
	rec.spawned = true
	luabots.mark_dirty(rec.id)
	local obj = core.add_entity(rec.pos, "luabots:robot", rec.id)
	return obj
end

function luabots.remove_body(rec)
	local body = luabots.get_body(rec.id)
	rec.spawned = false
	luabots.mark_dirty(rec.id)
	if body then
		local st = states[rec.id]
		st.body = nil
		if st.display_obj then
			st.display_obj:remove()
			st.display_obj = nil
		end
		body:remove()
	end
end

-- Error lines

-- Line number of the program mentioned by an error message (nil if none)
function luabots.error_line(msg)
	if type(msg) ~= "string" then return nil end
	return tonumber(msg:match("program:(%d+):") or msg:match("^line (%d+):")
		or msg:match("%] line (%d+):"))
end

-- Text of line 'n' of a program
function luabots.code_line(code, n)
	local i = 0
	for line in ((code or "") .. "\n"):gmatch("(.-)\r?\n") do
		i = i + 1
		if i == n then return line end
	end
end

-- Remember the line of an error and show that line in the console
local function note_error_line(rec, st, msg)
	local line = luabots.error_line(msg)
	st.error_line = line
	if not line then return msg end
	local text = luabots.code_line(st.code or rec.code, line)
	if not text then return msg end
	text = text:gsub("\t", "    "):gsub("^%s+", "")
	if #text > 120 then text = text:sub(1, 120) .. "..." end
	return msg .. "\n  >> " .. line .. " | " .. text
end

-- Program lifecycle

-- API calls that count as "what the robot is doing"
local DOING = {move = true, turn = true, dig = true, place = true, inv = true, craft = true,
	machine = true, combat = true, build = true, blueprint = true, interact = true,
	screen = true, sleep = true}

local function build_env(rec, st)
	return function(ctx, env)
		local bot = {
			id = rec.id,
			rec = rec,
			state = st,
			ctx = ctx,
			level = ctx.level,
		}
		function bot.wrap(name, f, cost)
			local prefix = name:match("^([%w_]+)")
			if DOING[prefix] then
				-- remember the last action, shown on the owner's HUD
				local inner = f
				f = function(...)
					st.doing = name
					return inner(...)
				end
			end
			return sandbox.wrap(ctx, name, f, cost)
		end
		-- Wait for an action; duration is scaled by the level speed
		function bot.act(seconds)
			sandbox.wait(ctx, seconds / math.max(0.1, bot.level.speed))
		end
		function bot.sleep(seconds)
			sandbox.wait(ctx, seconds)
		end
		function bot.body()
			return luabots.get_body(rec.id)
		end
		function bot.in_range(pos)
			return vector.distance(pos, rec.home) <= bot.level.range
		end
		st.bot = bot
		for _, builder in ipairs(luabots.api_builders) do
			builder(bot, env)
		end
		bot.full = ctx.full
		if ctx.full then luabots.full_access_env(bot, env) end
	end
end

-- Lowest run ID not used by another robot of the owner (or 1)
function luabots.free_slot(owner, except_id)
	local level = luabots.get_level(owner)
	local used = {}
	for id, r in pairs(luabots.records) do
		if r.owner == owner and id ~= except_id then used[r.slot or 1] = true end
	end
	for s = 1, level.max_running do
		if not used[s] then return s end
	end
	return 1
end

-- Stop the other running robots of the owner that use the same run ID
local function take_slot(rec)
	local slot = rec.slot or 1
	for id, other in pairs(luabots.records) do
		if id ~= rec.id and other.owner == rec.owner and (other.slot or 1) == slot then
			local ost = states[id]
			if ost and ost.status == "running" then
				luabots.stop(other, "stopped", "[" .. S("stopped: run ID @1 is now used by @2",
					slot, rec.name) .. "]")
			end
		end
	end
end
luabots.take_slot = take_slot

-- Direction the robot looks when it is on its base (robots created before this was stored get it from the base orientation)
function luabots.home_facing(rec)
	if rec.home_facing then return rec.home_facing end
	local node = core.get_node_or_nil(rec.home)
	if node and node.name == "luabots:base" and node.param2 < 4 then
		local dir = vector.multiply(core.facedir_to_dir(node.param2), -1)
		rec.home_facing = util.vector_to_facing(dir) or 0
		luabots.mark_dirty(rec.id)
		return rec.home_facing
	end
	return 0
end

-- Yaw of the body: the facing plus the free angle of turn.angle()
function luabots.body_yaw(rec)
	return util.facing_to_yaw(rec.facing) + math.rad(rec.angle or 0)
end

-- Every run starts with the robot on top of its base, looking the way the base was placed, so programs always start from the same place.
function luabots.return_home(rec)
	local spawn = vector.offset(rec.home, 0, 1, 0)
	local node = core.get_node_or_nil(spawn)
	if node and not util.is_passable(node) then
		return false, S("There is no free space above the robot base.")
	end
	if luabots.robot_at(spawn, rec.id) then
		return false, S("Another robot is standing on the base.")
	end
	local old = rec.pos
	rec.pos = spawn
	rec.facing = luabots.home_facing(rec)
	rec.angle = nil
	luabots.occupy(rec, old)
	luabots.mark_dirty(rec.id)
	local body = luabots.get_body(rec.id)
	if body then
		body:set_pos(spawn)
		body:set_yaw(luabots.body_yaw(rec))
	end
	return true
end

-- Forget what the program changed in the robot look (face screen, label, appearance). Kept when a program finishes by itself, so a program can just set a label and end.
local function clear_looks(rec)
	if rec.display or (rec.label or "") ~= "" or rec.appearance then
		rec.display = nil
		rec.label = ""
		rec.appearance = nil
		luabots.mark_dirty(rec.id)
	end
end
luabots.clear_looks = clear_looks

-- starter: player who starts the robot (the owner or a friend with the remote)
-- reason: "manual" (default), "server restart" or "resumed"
function luabots.start(rec, note, starter, reason)
	local st = luabots.get_state(rec.id)
	st.run_reason = reason or "manual"
	st.doing = nil
	st.status_text = nil
	rec.resume_when_near = nil
	if starter then
		rec.started_by = starter
		luabots.mark_dirty(rec.id)
	end
	st.idle_since = nil
	local level = luabots.get_level(rec.owner)
	local slot = rec.slot or 1
	if slot > level.max_running then
		local msg = S("Run ID @1 is not available: your level allows IDs 1 to @2.", slot, level.max_running)
		luabots.stop(rec, "error", "[" .. S("error") .. "] " .. msg)
		return false, msg
	end
	local home_ok, home_err = luabots.return_home(rec)
	if not home_ok then
		luabots.stop(rec, "error", "[" .. S("error") .. "] " .. home_err)
		return false, home_err
	end
	take_slot(rec)
	clear_looks(rec)
	local fn, err = sandbox.compile(rec.code, level)
	st.queues = {}
	st.listening = false
	st.remote_listening = false
	st.punch_listening = false
	st.code = rec.code
	st.error_line = nil
	if not fn then
		st.status = "error"
		st.ctx = nil
		st.error = err
		luabots.console(rec.id, note_error_line(rec, st, "[" .. S("compile error") .. "] " .. err), "error")
		rec.running = false
		luabots.mark_dirty(rec.id)
		luabots.update_body_look(rec)
		return false, err
	end
	luabots.full_access_cleanup(st)
	local full = luabots.has_full_access(rec.owner)
	local ok, ctx = pcall(sandbox.new_context, fn, level, build_env(rec, st), full)
	if not ok then
		core.log("error", "[luabots] cannot create program context: " .. tostring(ctx))
		return false, "internal error"
	end
	st.ctx = ctx
	st.status = "running"
	st.error = nil
	st.wake = 0
	st.started = now()
	rec.running = true
	luabots.mark_dirty(rec.id)
	luabots.console(rec.id, "[" .. (note or S("started")) .. "]", "system")
	luabots.spawn_body(rec)
	luabots.update_body_look(rec)
	return true
end

-- status: "stopped" | "finished" | "error"
function luabots.stop(rec, status, message)
	local st = luabots.get_state(rec.id)
	status = status or "stopped"
	rec.resume_when_near = nil
	local was_running = st.status == "running"
	st.status = status
	st.ctx = nil
	st.bot = nil
	st.queues = {}
	st.listening = false
	-- long sounds (music) end with the program
	for _, h in ipairs(st.sound_handles or {}) do core.sound_stop(h) end
	st.sound_handles = nil
	luabots.full_access_cleanup(st)
	luabots.clear_program_screens(st, rec.id)
	luabots.clear_program_keys(st, rec.id)
	for id in pairs(st.particle_spawners or {}) do core.delete_particlespawner(id) end
	st.particle_spawners = nil
	if status ~= "finished" then clear_looks(rec) end
	if status == "error" then
		message = message and note_error_line(rec, st, message)
		st.error = message
	end
	rec.running = false
	luabots.mark_dirty(rec.id)
	if message then
		luabots.console(rec.id, message, status == "error" and "error" or "system")
	elseif was_running then
		luabots.console(rec.id, "[" .. S("stopped") .. "]", "system")
	end
	luabots.update_body_look(rec)
end

-- Extract the program lines of a traceback
local function program_traceback(co)
	local tb = debug.traceback(co) or ""
	local lines = {}
	for line in tb:gmatch("[^\n]+") do
		local l = line:match("^%s*(program:%d+:.*)$")
		if l then lines[#lines + 1] = "  " .. l end
		if #lines >= 8 then break end
	end
	return table.concat(lines, "\n")
end

-- Scheduler

local order = {}
local rr = 0

local function rebuild_order()
	order = {}
	for id, st in pairs(states) do
		if st.status == "running" then order[#order + 1] = id end
	end
	table.sort(order)
end

local function run_slice(st, rec, t)
	local ctx = st.ctx
	if ctx.full and not luabots.has_full_access(rec.owner) then
		luabots.stop(rec, "error", "[" .. S("error") .. "] " .. S("The owner lost full access."))
		return
	end
	local level = luabots.get_level(rec.owner)
	sandbox.set_level(ctx, level)
	st.bot.level = level
	local ok, value = sandbox.resume(ctx)
	st.last_used = ctx.used
	if st.status ~= "running" or st.ctx ~= ctx then
		return -- stopped from inside the program
	end
	if not ok then
		local msg
		if value == sandbox.KILL then
			msg = ctx.kill_reason or "stopped"
		else
			msg = util.format_error(value)
			local tb = program_traceback(ctx.co)
			if tb ~= "" then msg = msg .. "\n" .. tb end
		end
		luabots.stop(rec, "error", "[" .. S("error") .. "] " .. msg)
		return
	end
	if coroutine.status(ctx.co) == "dead" then
		luabots.stop(rec, "finished", "[" .. S("program finished") .. "]")
		return
	end
	if value == sandbox.WAIT then
		st.wake = t + (ctx.wake_in or 0)
	else
		st.wake = t
	end
end

core.register_globalstep(function()
	rebuild_order()
	local n = #order
	if n == 0 then return end
	local t0 = now()
	if collectgarbage("count") > config.global_memory_mb * 1024 then
		collectgarbage("collect")
		if collectgarbage("count") > config.global_memory_mb * 1024 then
			return -- let memory settle before running robots
		end
	end
	local done = 0
	for _ = 1, n do
		rr = rr % n + 1
		local id = order[rr]
		local st = states[id]
		local rec = luabots.get_record(id)
		if not rec then
			states[id] = nil
		elseif st.status == "running" and st.wake <= t0 and luabots.get_body(id) then
			run_slice(st, rec, t0)
			done = done + 1
			if done >= config.max_slices_per_step or now() - t0 > config.step_time_budget then
				break
			end
		end
	end
end)

-- Idle robots

-- Why a running robot should be switched off (nil if it should keep running)
local function idle_reason(rec)
	if luabots.get_level(rec.owner).name == "admin" then return nil end
	if config.stop_when_offline and not core.get_player_by_name(rec.owner)
			and not (rec.started_by and core.get_player_by_name(rec.started_by)) then
		return S("stopped: its players are offline")
	end
	if config.idle_radius > 0 then
		for _, player in ipairs(core.get_connected_players()) do
			if vector.distance(player:get_pos(), rec.pos) <= config.idle_radius then return nil end
		end
		return S("stopped: nobody nearby")
	end
end
luabots.idle_reason = idle_reason

local idle_timer = 0
core.register_globalstep(function(dtime)
	idle_timer = idle_timer + dtime
	if idle_timer < 2 then return end
	idle_timer = 0
	local t = now()
	for id, st in pairs(states) do
		if st.status == "running" then
			local rec = luabots.get_record(id)
			local reason = rec and idle_reason(rec)
			if not reason then
				st.idle_since = nil
			elseif not st.idle_since then
				st.idle_since = t
			elseif t - st.idle_since >= config.idle_seconds then
				luabots.stop(rec, "stopped", "[" .. reason .. "]")
				-- a program with a job going starts again when someone comes back
				if rec.job_active then
					rec.resume_when_near = true
					luabots.mark_dirty(rec.id)
				end
			end
		end
	end
	for id, rec in pairs(luabots.records) do
		if rec.resume_when_near and not (states[id] and states[id].status == "running")
				and not idle_reason(rec) then
			luabots.start(rec, S("resumed: someone came back"), nil, "resumed")
		end
	end
end)

-- Delete a robot completely (base removed)
function luabots.destroy(rec)
	luabots.stop(rec, "stopped")
	luabots.remove_body(rec)
	states[rec.id] = nil
	luabots.delete_record(rec.id)
end

-- Status text for GUIs
function luabots.status_text(rec)
	local st = states[rec.id]
	local status = st and st.status or "stopped"
	if status == "running" and not luabots.get_body(rec.id) then
		return S("waiting (area not loaded)")
	end
	local names = {
		running = S("running"),
		stopped = S("stopped"),
		finished = S("finished"),
		error = S("error"),
	}
	return names[status] or status
end
