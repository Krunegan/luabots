-- Chat commands: /luabots <subcommand>

local S = luabots.S

local function list_robots(filter)
	local out = {}
	for _, rec in pairs(luabots.records) do
		if filter == nil or rec.owner == filter then out[#out + 1] = rec end
	end
	table.sort(out, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
	return out
end

local function find_managed(name, query)
	local rec = luabots.find_record(query, name)
	if not rec then return nil, S("No robot called '@1'.", query) end
	if rec.owner ~= name and not luabots.is_admin(name) then
		return nil, S("This robot belongs to @1.", rec.owner)
	end
	return rec
end

local subcommands = {}

subcommands.list = function(name, param)
	local filter = name
	if param == "all" or (param ~= "" and param ~= name) then
		if not luabots.is_admin(name) then
			return false, S("Only LuaBots admins can list other players' robots.")
		end
		filter = param ~= "all" and param or nil
	end
	local robots = list_robots(filter)
	if #robots == 0 then return true, S("No robots.") end
	local lines = {}
	for _, rec in ipairs(robots) do
		lines[#lines + 1] = ("#%s [ID %d] %s %s - %s"):format(rec.id, rec.slot or 1, luabots.display_name(rec),
			core.pos_to_string(rec.pos), luabots.status_text(rec))
	end
	return true, table.concat(lines, "\n")
end

subcommands.start = function(name, param)
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	luabots.stop(rec, "stopped")
	local ok, cerr = luabots.start(rec, nil, name)
	if not ok then return false, cerr end
	return true, S("@1 started.", luabots.display_name(rec))
end

subcommands.track = function(name, param)
	if param == "" or param == "off" then
		luabots.hud_untrack(name)
		return true, S("Robot tracking off.")
	end
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	luabots.hud_track(name, rec)
	return true, S("Tracking @1 on your screen. /luabots track off to stop.", luabots.display_name(rec))
end

subcommands.unlink = function(name, param)
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	luabots.unlink_remotes(rec)
	return true, S("All remotes of @1 were unlinked. Place your remote on the base to link it again.",
		luabots.display_name(rec))
end

subcommands.stop = function(name, param)
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	luabots.stop(rec, "stopped")
	return true, S("@1 stopped.", luabots.display_name(rec))
end

subcommands.edit = function(name, param)
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	luabots.show_editor(name, rec)
	return true
end

subcommands.console = function(name, param)
	local rec, err = find_managed(name, param)
	if not rec then return false, err end
	local st = luabots.states[rec.id]
	local lines = {}
	for _, l in ipairs(st and st.console or {}) do lines[#lines + 1] = l.text end
	local first = math.max(1, #lines - 15)
	return true, table.concat(lines, "\n", first)
end

subcommands.msg = function(name, param)
	local target, text = param:match("^(%S+)%s+(.+)$")
	if not target then return false, S("Usage: /luabots msg <robot> <text>") end
	local rec = luabots.find_record(target, name)
	if not rec then return false, S("No robot called '@1'.", target) end
	if #text > 300 then text = text:sub(1, 300) end
	if luabots.push_event(rec.id, "chat", {name = name, msg = text, direct = true}) then
		return true, S("Message sent to @1.", luabots.display_name(rec))
	end
	return false, S("Robot @1 is not running.", luabots.display_name(rec))
end

subcommands.info = function(name)
	local level = luabots.get_level(name)
	local bases = level.max_bases > 0 and tostring(level.max_bases) or "-"
	return true, S("Level: @1. Bases: @2/@3. Running at the same time: @4. Instructions per tick: @5. Range: @6.",
		level.label, luabots.owner_count(name), bases, level.max_running, level.instructions, level.range)
end

subcommands.buy = function(name, param)
	return luabots.shop_command(name, param)
end

subcommands.help = function(name)
	luabots.show_help(name, 1)
	return true
end

subcommands.stopall = function(name, param)
	if not luabots.is_admin(name) then
		return false, S("Only LuaBots admins can do this.")
	end
	local n = 0
	for _, rec in pairs(luabots.records) do
		local st = luabots.states[rec.id]
		if st and st.status == "running" and (param == "" or rec.owner == param) then
			luabots.stop(rec, "stopped", "[" .. S("stopped by @1", name) .. "]")
			n = n + 1
		end
	end
	core.log("action", "[luabots] " .. name .. " stopped " .. n .. " robots")
	return true, S("@1 robots stopped.", n)
end

core.register_chatcommand("luabots", {
	params = "list [all|<player>] | start <robot> | stop <robot> | unlink <robot> | track <robot|off> | edit <robot> | "
		.. "console <robot> | msg <robot> <text> | buy [<owner>/<robot>] | info | help | stopall [<player>]",
	description = S("Manage your LuaBots robots"),
	func = function(name, param)
		local cmd, rest = param:match("^(%S+)%s*(.*)$")
		cmd = cmd or "list"
		rest = rest or ""
		local f = subcommands[cmd]
		if not f then
			return false, S("Unknown subcommand. Try /help luabots")
		end
		if (cmd == "start" or cmd == "stop" or cmd == "edit" or cmd == "console") and rest == "" then
			return false, S("Usage: /luabots @1 <robot>", cmd)
		end
		return f(name, rest)
	end,
})
