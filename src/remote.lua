-- Remote control keys and the shared control panel
-- A linked remote stores a secret key of its robot. Whoever holds a remote with the current key can start and stop the robot (to share a robot with friends). The owner can change the key: every remote linked before stops working, so a stolen remote is useless.

local S = luabots.S
local FS = function(...) return core.formspec_escape(S(...)) end
local esc = core.formspec_escape
local gui = luabots.gui

local function new_key()
	local bytes
	if SecureRandom then
		local ok, rng = pcall(SecureRandom)
		if ok and rng then bytes = rng:next_bytes(12) end
	end
	if not bytes then
		local t = {}
		for i = 1, 12 do t[i] = string.char(math.random(0, 255)) end
		bytes = table.concat(t)
	end
	return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

-- Key of the robot, created the first time a remote is linked
function luabots.remote_key(rec)
	if not rec.remote_key then
		rec.remote_key = new_key()
		luabots.mark_dirty(rec.id)
	end
	return rec.remote_key
end

function luabots.link_remote(stack, rec)
	local meta = stack:get_meta()
	meta:set_string("robot_id", rec.id)
	meta:set_string("robot_key", luabots.remote_key(rec))
	meta:set_string("description", S("Robot Remote Control") .. "\n" ..
		core.colorize("#9fe0ff", S("Linked to @1", luabots.display_name(rec))))
end

-- Invalidate every remote linked to the robot
function luabots.unlink_remotes(rec)
	rec.remote_key = new_key()
	luabots.mark_dirty(rec.id)
	-- close shared panels opened with the old key
	for name, ctx in pairs(luabots.remote_contexts) do
		if ctx.id == rec.id then
			luabots.remote_contexts[name] = nil
			core.close_formspec(name, "luabots:remote")
		end
	end
end

-- Record of the robot a remote works with, or nil and a message
function luabots.remote_record(stack)
	local meta = stack:get_meta()
	local rec = luabots.get_record(meta:get_string("robot_id"))
	if not rec then
		return nil, S("This remote is not linked. Place it on a robot base to link it.")
	end
	-- remotes linked before keys existed work until the first key is made
	local key = meta:get_string("robot_key")
	if rec.remote_key and key ~= rec.remote_key then
		return nil, S("The owner of @1 unlinked this remote.", luabots.display_name(rec)), true
	end
	return rec
end

-- Clear the link of a remote that no longer works
function luabots.forget_remote(stack)
	local meta = stack:get_meta()
	meta:set_string("robot_id", "")
	meta:set_string("robot_key", "")
	meta:set_string("description", "")
end

-- Shared control panel

local contexts = {}
luabots.remote_contexts = contexts

function luabots.show_remote_panel(name, rec)
	contexts[name] = {id = rec.id, key = rec.remote_key}
	local owner = name == rec.owner or luabots.is_admin(name)
	local W, H = 10, 7.4
	local fs = {
		gui.header(W, H, luabots.util.hypertext_escape(luabots.display_name(rec)), 5.4),
		gui.status_pill(rec, 6.2, 0.2, 3.45, 0.5),
		"label[0.35,1.35;", core.colorize("#9aa1aa", FS("Owner")), "  ",
			core.colorize("#eceef0", esc(rec.owner)), "]",
		gui.color_button("run", "cyan"),
		gui.color_button("stop", "red"),
		"button[0.35,1.8;3,0.7;run;", FS("Run"), "]",
		"button[3.5,1.8;3,0.7;stop;", FS("Stop"), "]",
		"button[6.65,1.8;3,0.7;refresh;", FS("Refresh"), "]",
		gui.caption(0.35, 2.95, S("CONSOLE")),
		gui.panel(0.35, 3.25, W - 0.7, 3.2),
		"hypertext[0.5,3.35;", ("%.2f"):format(W - 1), ",3;console;", esc(gui.console_text(rec)), "]",
	}
	if owner then
		fs[#fs + 1] = "button[0.35,6.6;4.5,0.6;drive;" .. FS("Drive manually") .. "]"
		fs[#fs + 1] = "button[5.15,6.6;4.5,0.6;unlink;" .. FS("Unlink all remotes") .. "]"
		fs[#fs + 1] = "tooltip[unlink;" .. FS("Remotes linked before stop working (use it if one was stolen)") .. "]"
	else
		fs[#fs + 1] = "label[0.35,6.9;" .. core.colorize("#9aa1aa",
			FS("Shared robot: you can start and stop it.")) .. "]"
	end
	core.show_formspec(name, "luabots:remote", table.concat(fs))
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "luabots:remote" then return false end
	local name = player:get_player_name()
	local ctx = contexts[name]
	if fields.quit or not ctx then
		contexts[name] = nil
		return true
	end
	local rec = luabots.get_record(ctx.id)
	-- the key may have changed since the panel was opened
	if not rec or rec.remote_key ~= ctx.key then
		contexts[name] = nil
		core.close_formspec(name, "luabots:remote")
		return true
	end
	local owner = name == rec.owner or luabots.is_admin(name)
	if fields.run then
		luabots.stop(rec, "stopped")
		local note = name ~= rec.owner and S("started by @1", name) or nil
		luabots.start(rec, note, name)
	elseif fields.stop then
		local st = luabots.states[rec.id]
		if st and st.status == "running" then
			luabots.stop(rec, "stopped", "[" .. S("stopped by @1", name) .. "]")
		end
	elseif fields.drive and owner then
		contexts[name] = nil
		luabots.show_manual(name, rec)
		return true
	elseif fields.unlink and owner then
		luabots.unlink_remotes(rec)
		core.chat_send_player(name, S("All remotes of @1 were unlinked. Place your remote on the base to link it again.",
			luabots.display_name(rec)))
		return true
	elseif not fields.refresh then
		return true
	end
	luabots.show_remote_panel(name, rec)
	return true
end)

core.register_on_leaveplayer(function(player)
	contexts[player:get_player_name()] = nil
end)
