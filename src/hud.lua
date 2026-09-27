-- Robot tracking on the HUD: a waypoint over the robot with its name, status, energy and what it is doing (/luabots track, editor button).

local S = luabots.S

local tracked = {} -- player name -> {id = robot id, hud = hud id}
luabots.hud_tracked = tracked

local function label(rec)
	local st = luabots.states[rec.id]
	local parts = {luabots.display_name(rec), luabots.status_text(rec),
		S("energy @1", math.floor(rec.energy or 0))}
	if st and st.status == "running" then
		if st.status_text and st.status_text ~= "" then
			parts[#parts + 1] = st.status_text
		elseif st.doing then
			parts[#parts + 1] = st.doing
		end
	end
	return table.concat(parts, " | ")
end

local function color(rec)
	local st = luabots.states[rec.id]
	local status = st and st.status or "stopped"
	if status == "running" then return 0x3ee8ff end
	if status == "error" then return 0xff4a3a end
	return 0xb9bdc3
end

function luabots.hud_untrack(name)
	local t = tracked[name]
	if not t then return end
	local player = core.get_player_by_name(name)
	if player and t.hud then player:hud_remove(t.hud) end
	tracked[name] = nil
end

function luabots.hud_track(name, rec)
	luabots.hud_untrack(name)
	local player = core.get_player_by_name(name)
	if not player then return end
	tracked[name] = {
		id = rec.id,
		hud = player:hud_add({
			type = "waypoint",
			name = label(rec),
			text = "m",
			precision = 1,
			number = color(rec),
			world_pos = vector.offset(rec.pos, 0, 0.8, 0),
		}),
	}
end

function luabots.hud_is_tracking(name, rec)
	return tracked[name] ~= nil and tracked[name].id == rec.id
end

local timer = 0
core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < 0.5 then return end
	timer = 0
	for name, t in pairs(tracked) do
		local player = core.get_player_by_name(name)
		local rec = luabots.get_record(t.id)
		if not player then
			tracked[name] = nil
		elseif not rec then
			luabots.hud_untrack(name)
		else
			player:hud_change(t.hud, "world_pos", vector.offset(rec.pos, 0, 0.8, 0))
			player:hud_change(t.hud, "name", label(rec))
			player:hud_change(t.hud, "number", color(rec))
		end
	end
end)

core.register_on_leaveplayer(function(player)
	tracked[player:get_player_name()] = nil
end)
