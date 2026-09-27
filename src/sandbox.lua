-- Program sandbox: compilation, environment, instruction and memory limits.
-- How programs are limited:
--  * Code is loaded as text only (bytecode is rejected by the engine) with its own environment table, and LuaJIT compilation is disabled for it, so the instruction count hook always fires.
--  * While a program runs, a count hook fires every HOOK_STEP instructions. It enforces the CPU limit of the current tick and the memory limit.
--  * Robot API calls happen with the hook disabled ("trusted zone") and the program is paused automatically at those calls when its budget for the tick is spent.
--  * The string metatable points at the program's own safe string library while it runs, so ("x"):rep(1e9) is covered too.

local sandbox = {}
luabots.sandbox = sandbox

local config = luabots.config
local util = luabots.util
local safestd = luabots.safestd

local HOOK_STEP = 10
local MAX_CONCAT_CHAIN = 16

-- Private sentinels. Programs can never obtain references to them.
local KILL = {}
local WAIT = {}   -- yielded by actions that take time
local PAUSE = {}  -- yielded when the tick budget is spent
sandbox.KILL, sandbox.WAIT, sandbox.PAUSE = KILL, WAIT, PAUSE
sandbox.internal_tokens = {[WAIT] = true, [PAUSE] = true}

local string_mt = getmetatable("")
local real_string_index = string_mt.__index
local sethook, gethook = debug.sethook, debug.gethook
local c_yield = coroutine.yield

sandbox.current = nil

function sandbox.enter(ctx)
	sandbox.current = ctx
	string_mt.__index = ctx.env_string
	sethook(ctx.hook, "", ctx.killed and 1 or HOOK_STEP)
end

function sandbox.leave()
	sethook()
	string_mt.__index = real_string_index
end

-- Stop the running program from inside the hook
local function kill(ctx, reason)
	ctx.killed = true
	ctx.kill_reason = reason
	sethook(ctx.hook, "", 1)
	error(KILL, 0)
end

local co_running = coroutine.running

local getinfo = debug.getinfo

-- Code of the program (not of mods it calls, with full access)
local function program_code()
	local info = getinfo(3, "S")
	local src = info and info.source or ""
	return src == "=program" or src == "=builder" or src:sub(1, 6) == "=disk:"
end

local function make_hook(ctx)
	return function()
		-- The hook may fire in the few scheduler instructions between the end of a slice and sandbox.leave(). That code runs on the main thread (never a coroutine), so it is ignored here.
		if not co_running() then return end
		-- with full access the program calls mods directly: never stop it
		-- in the middle of their code, only in its own
		if ctx.full and not program_code() then return end
		local used = ctx.used + HOOK_STEP
		ctx.used = used
		if ctx.killed then error(KILL, 0) end
		if used > ctx.hard_limit then
			kill(ctx, ("CPU limit exceeded (%d instructions without pausing). "
				.. "Call yield() or sleep() inside long loops."):format(ctx.hard_limit))
		end
		local mem = collectgarbage("count")
		if mem > ctx.mem_mark then
			if not ctx.collected then
				ctx.collected = true
				collectgarbage("collect")
				mem = collectgarbage("count")
			end
			if mem > ctx.mem_mark then
				kill(ctx, ("memory limit exceeded (%d MB per tick)"):format(ctx.level.memory_mb))
			end
		end
		if mem > config.global_memory_mb * 1024 then
			collectgarbage("collect")
			if collectgarbage("count") > config.global_memory_mb * 1024 then
				kill(ctx, "server memory limit reached")
			end
		end
	end
end

-- Compile a program. Returns function or nil, error. 'chunkname' names the code in error messages ("program" by default, "disk:<title>" for disks).
function sandbox.compile(code, level, chunkname)
	if type(code) ~= "string" then return nil, "no program" end
	if #code > level.code_kb * 1024 then
		return nil, ("program too large (max %d KB)"):format(level.code_kb)
	end
	if code:byte(1) == 27 then
		return nil, "binary chunks are not allowed"
	end
	local err = luabots.lexer.check(code, MAX_CONCAT_CHAIN)
	if err then return nil, err end
	local fn, cerr = loadstring(code, "=" .. (chunkname or "program"))
	if not fn then return nil, cerr end
	if jit then jit.off(fn, true) end
	return fn
end

-- Creates a program context: environment + coroutine + limits
-- robot_env_builder(ctx, env) adds the robot API to env
function sandbox.new_context(fn, level, robot_env_builder, full)
	local ctx = {
		KILL = KILL,
		WAIT = WAIT,
		PAUSE = PAUSE,
		internal_tokens = sandbox.internal_tokens,
		used = 0,
		level = level,
		killed = false,
		full = full or false,
	}
	ctx.hook = make_hook(ctx)

	-- Pause automatically when the budget of this tick is spent.
	-- Called from library functions and API calls (never from the hook).
	function ctx.checkpoint()
		if ctx.used >= ctx.soft_limit and not ctx.no_pause then
			pcall(c_yield, PAUSE)
		end
	end

	local env = {}
	safestd.make_base(ctx, env)
	env.string = safestd.make_string(ctx)
	env.table = safestd.make_table(ctx)
	env.math = safestd.make_math(ctx)
	env.os = safestd.make_os()
	env.coroutine = safestd.make_coroutine(ctx)
	env.vector = safestd.make_vector()
	env.json = safestd.make_json(ctx)
	if bit then
		env.bit = {}
		for k, v in pairs(bit) do env.bit[k] = v end
	end
	env._G = env
	ctx.env = env
	ctx.env_string = env.string

	robot_env_builder(ctx, env)
	if ctx.full then ctx.env_string = real_string_index end

	setfenv(fn, env)
	ctx.co = coroutine.create(fn)
	sandbox.set_level(ctx, level)
	return ctx
end

function sandbox.set_level(ctx, level)
	ctx.level = level
	ctx.soft_limit = level.instructions
	ctx.hard_limit = level.instructions * config.hard_limit_factor
	ctx.mem_allow = level.memory_mb * 1024
end

-- Run the program until it yields. Returns ok, value
function sandbox.resume(ctx, ...)
	local h, m, c = gethook()
	ctx.used = 0
	ctx.collected = false
	ctx.mem_mark = collectgarbage("count") + ctx.mem_allow
	sandbox.enter(ctx)
	local ok, value = coroutine.resume(ctx.co, ...)
	sandbox.leave()
	sandbox.current = nil
	if h then sethook(h, m, c) end
	return ok, value
end

local function pack(...)
	return {n = select("#", ...), ...}
end

-- Wrap a trusted API function so that it runs outside the sandbox.
-- f receives the arguments unchanged: it must validate them and must never call metamethods of program values (no tostring on tables, ...).
function sandbox.wrap(ctx, name, f, cost)
	cost = cost or 20
	local traceback = debug.traceback
	local function handler(e)
		if util.is_api_error(e) or e == KILL then return e end
		return {internal = true, msg = tostring(e), tb = traceback("", 2)}
	end
	return function(...)
		-- called from a callback the program registered (full access): not inside the program, so no sandbox to leave or enter
		if not co_running() then
			local r = pack(xpcall(f, handler, ...))
			if r[1] then return unpack(r, 2, r.n) end
			local e = r[2]
			error(name .. ": " .. (util.is_api_error(e) and e.msg or "internal error (details in server log)"), 2)
		end
		sandbox.leave()
		ctx.used = ctx.used + cost
		local r = pack(xpcall(f, handler, ...))
		sandbox.enter(ctx)
		if not r[1] then
			local e = r[2]
			if util.is_api_error(e) then
				error(name .. ": " .. e.msg, 2)
			elseif e == KILL then
				error(KILL, 0)
			else
				core.log("error", ("[luabots] internal error in %s: %s%s"):format(
					name, util.format_error(e.msg), e.tb or ""))
				error(name .. ": internal error (details in server log)", 2)
			end
		end
		ctx.checkpoint()
		return unpack(r, 2, r.n)
	end
end

-- Used by actions (inside a wrapped API function) to wait for some time.
-- The scheduler resumes the program after 'seconds'.
function sandbox.wait(ctx, seconds)
	ctx.wake_in = seconds
	c_yield(WAIT)
	-- resumed by the scheduler, which re-entered the sandbox
	sandbox.leave()
end
