-- Full access: robots of the server owner (luabots_admin + the privilege of luabots.full_access_priv, "server" by default) get the real server API in their programs: core, _G with every mod, unlimited string/table...
-- This lets them write mods live, without restarting the server.
-- What a program registers with core.register_* (chat commands, globalsteps, on_* callbacks), core.after jobs and core.add_entity objects stay while the robot runs, and are removed when the program stops or runs again, so editing the code and pressing Run reloads the "mod". Errors in those callbacks go to the robot console instead of crashing the server.

local config = luabots.config
local util = luabots.util

function luabots.has_full_access(owner)
	local priv = config.full_access_priv
	if priv == "" or not owner then return false end
	local privs = core.get_player_privs(owner)
	return privs.luabots_admin == true and privs[priv] == true
end

local function pack(...) return {n = select("#", ...), ...} end

-- A callback of the program that cannot crash the server
local function protect(bot, fn, what)
	return function(...)
		local r = pack(xpcall(fn, function(e) return e end, ...))
		if r[1] then return unpack(r, 2, r.n) end
		local msg = util.format_error(r[2])
		luabots.console(bot.id, "[error in " .. what .. "] " .. msg, "error")
		core.log("error", ("[luabots] full access robot %s, error in %s: %s"):format(
			luabots.display_name(bot.rec), what, msg))
		return nil
	end
end

-- The list where core.register_<x> keeps its callbacks
local function registry(key)
	local suffix = key:sub(#"register_" + 1)
	local list = core["registered_" .. suffix .. "s"]
	if type(list) ~= "table" then list = core["registered_" .. suffix] end
	if type(list) == "table" and (#list > 0 or next(list) == nil) then return list end
end

-- core seen by the program: the real one, but registrations are protected and remembered so they can be removed
local function core_proxy(bot, done)
	local cache = {}
	return setmetatable({}, {
		__index = function(_, key)
			local value = core[key]
			if type(value) ~= "function" or type(key) ~= "string" then return value end
			if cache[key] then return cache[key] end
			local w = value
			if key == "register_chatcommand" then
				w = function(name, def)
					if type(def) == "table" and type(def.func) == "function" then
						local copy = {}
						for k, v in pairs(def) do copy[k] = v end
						copy.func = protect(bot, def.func, "/" .. tostring(name))
						def = copy
					end
					local previous = core.registered_chatcommands[name]
					value(name, def)
					done[#done + 1] = {kind = "command", name = name, def = core.registered_chatcommands[name],
						previous = previous}
				end
			elseif key == "add_entity" or key == "add_item" then
				w = function(...)
					local obj = value(...)
					if obj then done[#done + 1] = {kind = "object", obj = obj} end
					return obj
				end
			elseif key == "after" then
				w = function(t, fn, ...)
					local job = value(t, protect(bot, fn, "core.after"), ...)
					done[#done + 1] = {kind = "job", job = job}
					return job
				end
			elseif key:match("^register_") and registry(key) then
				w = function(fn, ...)
					if type(fn) ~= "function" then return value(fn, ...) end
					local safe = protect(bot, fn, "core." .. key)
					local r = pack(value(safe, ...))
					done[#done + 1] = {kind = "callback", key = key, fn = safe}
					return unpack(r, 1, r.n)
				end
			end
			cache[key] = w
			return w
		end,
		__newindex = function(_, key, value) core[key] = value end,
	})
end

-- Remove what a program registered (called when it stops)
function luabots.full_access_cleanup(st)
	local done = st.full_registrations
	st.full_registrations = nil
	if not done then return end
	for i = #done, 1, -1 do
		local d = done[i]
		if d.kind == "stop" then
			d.fn()
		elseif d.kind == "command" then
			-- remove it, or give back the command it replaced
			if core.registered_chatcommands[d.name] == d.def then
				core.registered_chatcommands[d.name] = d.previous
			end
		elseif d.kind == "object" then
			if d.obj:get_pos() then d.obj:remove() end
		elseif d.kind == "job" then
			if d.job and d.job.cancel then d.job:cancel() end
		elseif d.kind == "callback" then
			local list = registry(d.key)
			for j = #(list or {}), 1, -1 do
				if list[j] == d.fn then table.remove(list, j) end
			end
			if core.callback_origins then core.callback_origins[d.fn] = nil end
		end
	end
end

-- Give a program environment the real server API
function luabots.full_access_env(bot, env)
	local done = {}
	bot.state.full_registrations = done
	local proxy = core_proxy(bot, done)
	local G = setmetatable({}, {
		__index = function(_, key)
			if key == "core" or key == "minetest" then return proxy end
			return rawget(_G, key)
		end,
		__newindex = function(_, key, value) rawset(_G, key, value) end,
	})
	env.core, env.minetest, env._G = proxy, proxy, G
	-- robot.on_stop(fn): fn runs when the program stops (any reason)
	env.robot.on_stop = function(fn)
		if type(fn) ~= "function" then error("robot.on_stop: function expected", 2) end
		done[#done + 1] = {kind = "stop", fn = protect(bot, fn, "robot.on_stop")}
	end
	env.string, env.table, env.math, env.os = string, table, math, os
	env.vector = vector
	env.getmetatable, env.setmetatable = getmetatable, setmetatable
	setmetatable(env, {__index = G})
end
