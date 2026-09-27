-- Communication API: chat.*, net.*, forms.*, remote.*, keyboard.*, books.*

local S = luabots.S
local config = luabots.config
local util = luabots.util
local compat = luabots.compat

-- Text for the chat: colours made with colorize() stay, every other control character (new lines, other escape sequences) becomes a space
local function clean_text(text, max)
	if #text > max then text = text:sub(1, max) end
	local out, i = {}, 1
	while i <= #text do
		local s, e = text:find("\27%(c@[#%w]+%)", i)
		out[#out + 1] = (text:sub(i, (s or #text + 1) - 1):gsub("%c", " "))
		if not s then break end
		out[#out + 1] = text:sub(s, e)
		i = e + 1
	end
	return table.concat(out)
end
luabots.clean_chat_text = clean_text

-- Chat listening

core.register_on_chat_message(function(name, message)
	if message:sub(1, 1) == "/" then return end
	local player = core.get_player_by_name(name)
	local ppos = player and player:get_pos()
	for id, st in pairs(luabots.states) do
		if st.status == "running" and st.listening then
			local rec = luabots.get_record(id)
			local body = luabots.get_body(id)
			if rec and body then
				local hear = luabots.get_level(rec.owner).name == "admin"
					or (ppos and vector.distance(ppos, rec.pos) <= config.chat_radius)
				if hear then
					luabots.push_event(id, "chat", {name = name, msg = message, direct = false})
				end
			end
		end
	end
end)

-- Custom forms
-- A robot can open a new window to another player only if that player did not close one of the robots of the same owner in the last seconds, and is not fighting: robots cannot be used to flood someone with windows.

local closed_at = {} -- player name -> {owner -> time}
local fought_at = {} -- player name -> time

core.register_on_punchplayer(function(player, hitter)
	local t = luabots.now()
	fought_at[player:get_player_name()] = t
	if hitter and hitter:is_player() then fought_at[hitter:get_player_name()] = t end
end)

local function note_closed(pname, owner)
	if pname == owner then return end
	closed_at[pname] = closed_at[pname] or {}
	closed_at[pname][owner] = luabots.now()
end

-- Why a robot of 'owner' cannot open a new window to 'pname' now (or nil)
local function form_pause(pname, owner)
	local t = luabots.now()
	if fought_at[pname] and t - fought_at[pname] < config.form_combat_pause then
		return "player is fighting"
	end
	local c = closed_at[pname] and closed_at[pname][owner]
	if c and t - c < config.form_close_pause then
		return "player closed a window recently"
	end
end

core.register_on_player_receive_fields(function(player, formname, fields)
	local id = formname:match("^luabots:form_(%d+)$")
	if not id then return false end
	local pname = player:get_player_name()
	local st = luabots.states[id]
	if not st or st.status ~= "running" or not st.forms_shown or not st.forms_shown[pname] then
		return true -- stale or forged submission, ignore
	end
	if fields.quit then
		st.forms_shown[pname] = nil
		local rec = luabots.get_record(id)
		if rec then note_closed(pname, rec.owner) end
	end
	local copy = {}
	local n = 0
	for k, v in pairs(fields) do
		if type(k) == "string" and type(v) == "string" and #k <= 256 then
			copy[k] = v:sub(1, 16384)
			n = n + 1
			if n >= 200 then break end
		end
	end
	luabots.push_event(id, "forms", {player = pname, fields = copy})
	return true
end)

core.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	for _, st in pairs(luabots.states) do
		if st.forms_shown then st.forms_shown[pname] = nil end
	end
	closed_at[pname] = nil
	fought_at[pname] = nil
end)

-- Keys (keyboard)

luabots.KEYS = {}
luabots.KEY_COLORS = {
	white = "#f0f0f0", gray = "#8a8a8a", black = "#262626", red = "#d83a34",
	orange = "#ec8a2e", yellow = "#f0d63a", lime = "#8ad83a", green = "#2f9e44",
	cyan = "#35c0c8", blue = "#3563d8", purple = "#8a3fd0", magenta = "#d23fb4",
	pink = "#f09ab8", brown = "#8a5a32",
}
for c in pairs(luabots.KEY_COLORS) do luabots.KEYS[c] = true end
for i = 0, 9 do luabots.KEYS[tostring(i)] = true end
for c in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do luabots.KEYS[c] = true end
luabots.KEYS.blank = true

-- Keys a program placed without keep = true are removed when it stops
-- (only if they are still keys of this robot)
function luabots.clear_program_keys(st, id)
	for _, p in pairs(st.temp_keys or {}) do
		local node = core.get_node_or_nil(p)
		if node and core.get_item_group(node.name, "luabots_key") > 0
				and core.get_meta(p):get_string("robot_id") == id then
			core.remove_node(p)
		end
	end
	st.temp_keys = nil
end

-- Books

local function read_book(stack)
	local name = stack:get_name()
	if name == "luabots:disk" then
		local meta = stack:get_meta()
		return meta:get_string("title"), meta:get_string("text"), meta:get_string("author")
	end
	local reader = compat.book_readers[name]
	if reader then return reader(stack) end
	return nil
end
luabots.read_book = read_book

function luabots.write_disk(stack, title, text, author)
	local meta = stack:get_meta()
	meta:set_string("title", title)
	meta:set_string("text", text)
	meta:set_string("author", author)
	-- a disk with data looks different from a blank one
	local image = text ~= "" and "luabots_disk_written.png" or ""
	meta:set_string("inventory_image", image)
	meta:set_string("wield_image", image)
	if title ~= "" then
		meta:set_string("description", S("Data disk") .. "\n" ..
			core.colorize("#9fe0ff", ("\"%s\" by %s"):format(title, author)))
	else
		meta:set_string("description", "")
	end
	return stack
end

-- Time of the last chat message sent by the robots of each owner (shared by all their robots, so more robots do not mean more messages)
local last_msg = {}

core.register_on_leaveplayer(function(player)
	last_msg[player:get_player_name()] = nil
end)

luabots.register_api(function(bot, env)
	local wrap = bot.wrap
	local rec, st = bot.rec, bot.state

	-- chat.*
	local chat = {}
	env.chat = chat

	-- Robots talk for their owner: a muted owner (no shout) cannot talk through them either
	local function can_talk()
		if not core.check_player_privs(rec.owner, {shout = true}) then
			return false, "the owner does not have the shout privilege"
		end
		local t = luabots.now()
		if t - (last_msg[rec.owner] or 0) < config.say_interval then return false, "too fast" end
		last_msg[rec.owner] = t
		return true
	end

	local function line(text, to)
		local who = luabots.display_name(rec) .. (to and (" -> " .. to) or "")
		return core.colorize("#7fd4ff", "[" .. who .. "] ") .. text
	end

	-- chat.nearby(text): players within luabots.chat_radius of the robot
	chat.nearby = wrap("chat.nearby", function(text)
		text = clean_text(util.check_string(text, "text", 1000), 300)
		local ok, why = can_talk()
		if not ok then return false, why end
		local msg = line(text)
		for _, p in ipairs(core.get_connected_players()) do
			if vector.distance(p:get_pos(), rec.pos) <= config.chat_radius then
				core.chat_send_player(p:get_player_name(), msg)
			end
		end
		return true
	end, 100)

	-- chat.all(text): every player on the server (advanced and admin levels)
	chat.all = wrap("chat.all", function(text)
		if bot.level.rank < 2 then util.api_error("chat.all requires the luabots privilege") end
		text = clean_text(util.check_string(text, "text", 1000), 300)
		local ok, why = can_talk()
		if not ok then return false, why end
		core.chat_send_all(line(text))
		return true
	end, 100)

	-- chat.tell(player, text): one player
	local function tell(player, text)
		util.check_string(player, "player", 64)
		text = clean_text(util.check_string(text, "text", 1000), 300)
		if not core.get_player_by_name(player) then return false, "player not online" end
		local ok, why = can_talk()
		if not ok then return false, why end
		core.chat_send_player(player, line(text, player))
		return true
	end
	chat.tell = wrap("chat.tell", tell, 100)

	-- chat.owner(text): the owner of the robot
	chat.owner = wrap("chat.owner", function(text)
		return tell(rec.owner, text)
	end, 100)

	chat.listen = wrap("chat.listen", function(on)
		st.listening = on ~= false
		return true
	end)

	chat.receive = wrap("chat.receive", function()
		local e = luabots.pop_event(rec.id, "chat")
		if not e then return nil end
		return e.name, e.msg, e.direct
	end)

	-- net.* : messages between robots
	local net = {}
	env.net = net
	local sent_window, sent_count = 0, 0

	local function net_rate()
		local t = luabots.now()
		if t - sent_window > 1 then sent_window, sent_count = t, 0 end
		sent_count = sent_count + 1
		return sent_count <= 50
	end

	local function deliver(to_id, data)
		return luabots.push_event(to_id, "net", {from = rec.id, owner = rec.owner, data = data})
	end

	net.send = wrap("net.send", function(to, data)
		if type(to) ~= "string" and type(to) ~= "number" then util.api_error("robot id expected") end
		local target = luabots.get_record(tostring(to)) or
			(type(to) == "string" and luabots.find_record(to, rec.owner))
		if not target then return false, "no such robot" end
		if not net_rate() then return false, "too fast" end
		local copy = util.copy_data(data, 16384)
		if deliver(target.id, copy) then return true end
		return false, "robot not running"
	end, 100)

	net.broadcast = wrap("net.broadcast", function(data, radius)
		radius = util.check_number(radius or bot.level.sense_radius, "radius", 1, bot.level.sense_radius)
		if not net_rate() then return 0, "too fast" end
		local copy = util.copy_data(data, 16384)
		local n = 0
		for id, other in pairs(luabots.states) do
			local r = luabots.get_record(id)
			if id ~= rec.id and r and other.status == "running"
					and vector.distance(r.pos, rec.pos) <= radius then
				if deliver(id, util.copy_data(copy, 16384)) then n = n + 1 end
			end
		end
		return n
	end, 300)

	net.receive = wrap("net.receive", function()
		local e = luabots.pop_event(rec.id, "net")
		if not e then return nil end
		return e.from, e.data, e.owner
	end)

	net.find = wrap("net.find", function(name)
		util.check_string(name, "name", 100)
		local r = luabots.find_record(name, rec.owner)
		return r and r.id or nil
	end)

	-- forms.* 
	local forms = {}
	env.forms = forms
	st.forms_shown = {}
	local form_times = {}

	forms.show = wrap("forms.show", function(player, formspec)
		util.check_string(player, "player", 64)
		util.check_string(formspec, "formspec", 65536)
		local p = core.get_player_by_name(player)
		if not p then return false, "player not online" end
		if bot.level.name ~= "admin" and player ~= rec.owner then
			if vector.distance(p:get_pos(), rec.pos) > config.form_radius then
				return false, "player too far"
			end
			-- updating an open window is fine, a new one may be paused
			local why = not st.forms_shown[player] and form_pause(player, rec.owner)
			if why then return false, why end
		end
		local t = luabots.now()
		if form_times[player] and t - form_times[player] < 0.5 then return false, "too fast" end
		form_times[player] = t
		st.forms_shown[player] = true
		core.show_formspec(player, "luabots:form_" .. rec.id, formspec)
		return true
	end, 200)

	forms.close = wrap("forms.close", function(player)
		util.check_string(player, "player", 64)
		if st.forms_shown[player] then
			st.forms_shown[player] = nil
			note_closed(player, rec.owner)
			core.close_formspec(player, "luabots:form_" .. rec.id)
		end
		return true
	end)

	forms.receive = wrap("forms.receive", function()
		local e = luabots.pop_event(rec.id, "forms")
		if not e then return nil end
		return e.player, e.fields
	end)

	forms.escape = wrap("forms.escape", function(text)
		return core.formspec_escape(util.check_string(text, "text", 65536))
	end)

	-- remote.*
	env.remote = {
		receive = wrap("remote.receive", function()
			st.remote_listening = true -- clicks with the remote now go to the program
			local e = luabots.pop_event(rec.id, "remote")
			if not e then return nil end
			return e.player, e.action, e.pos
		end),
	}

	-- keyboard.*
	local keyboard = {}
	env.keyboard = keyboard

	local function key_pos(pos)
		pos = util.check_pos(pos, "pos")
		if not bot.in_range(pos) then return nil, "out of range" end
		local node = core.get_node_or_nil(pos)
		if not node then return nil, "area not loaded" end
		return pos, node
	end

	local RANK = {player = 1, advanced = 2, admin = 3}
	local PRIV = {advanced = "luabots", admin = "luabots_admin"}

	-- keyboard.set(pos, key, keep): removed when the program stops, unless keep
	keyboard.set = wrap("keyboard.set", function(pos, key, keep)
		if RANK[bot.level.name] < RANK[config.keyboard_level] then
			util.api_error("keyboard.set requires the " .. PRIV[config.keyboard_level] .. " privilege")
		end
		util.check_string(key, "key", 20)
		key = key:lower()
		if not luabots.KEYS[key] then util.api_error("unknown key '" .. key .. "'") end
		local p, node = key_pos(pos)
		if not p then return false, node end
		local is_key = core.get_item_group(node.name, "luabots_key") > 0
		if not is_key and node.name ~= "air" then return false, "occupied" end
		if core.is_protected(p, rec.owner) then return false, "protected" end
		if luabots.robot_at(p) then return false, "a robot is in the way" end
		core.set_node(p, {name = "luabots:key_" .. key})
		local meta = core.get_meta(p)
		meta:set_string("robot_id", rec.id)
		meta:set_string("owner", rec.owner)
		st.temp_keys = st.temp_keys or {}
		st.temp_keys[core.pos_to_string(p)] = (keep ~= true) and p or nil
		return true
	end, 150)

	keyboard.clear = wrap("keyboard.clear", function(pos)
		local p, node = key_pos(pos)
		if not p then return false, node end
		if core.get_item_group(node.name, "luabots_key") == 0 then return false, "not a key" end
		if core.is_protected(p, rec.owner) then return false, "protected" end
		core.remove_node(p)
		if st.temp_keys then st.temp_keys[core.pos_to_string(p)] = nil end
		return true
	end, 150)

	keyboard.get = wrap("keyboard.get", function(pos)
		local p, node = key_pos(pos)
		if not p then return nil, node end
		if core.get_item_group(node.name, "luabots_key") == 0 then return nil end
		return node.name:sub(#"luabots:key_" + 1)
	end, 30)

	keyboard.receive = wrap("keyboard.receive", function()
		local e = luabots.pop_event(rec.id, "keyboard")
		if not e then return nil end
		return e.player, e.key, e.pos, e.action
	end)

	-- books.*
	local books = {}
	env.books = books

	books.read = wrap("books.read", function(slot)
		slot = math.floor(util.check_number(slot, "slot", 1, luabots.INV_SIZES.main))
		local stack = luabots.get_inventory(rec):get_stack("main", slot)
		if stack:is_empty() then return nil, "empty slot" end
		local title, text, author = read_book(stack)
		if not title then return nil, "not a book or disk" end
		return title, text, author
	end, 100)

	books.write = wrap("books.write", function(slot, title, text)
		slot = math.floor(util.check_number(slot, "slot", 1, luabots.INV_SIZES.main))
		title = clean_text(util.check_string(title, "title", 200), 80)
		text = util.check_string(text, "text", 65536)
		local inv = luabots.get_inventory(rec)
		local stack = inv:get_stack("main", slot)
		if stack:is_empty() then return false, "empty slot" end
		local name = stack:get_name()
		local written
		if name == "luabots:disk" then
			if stack:get_count() > 1 then
				written = luabots.write_disk(stack:take_item(1), title, text, rec.owner)
			else
				inv:set_stack("main", slot, luabots.write_disk(stack, title, text, rec.owner))
				luabots.mark_dirty(rec.id)
				bot.act(0.5)
				return true
			end
		elseif compat.book_writers[name] then
			written = compat.book_writers[name](stack:take_item(1), title, text, rec.owner)
		else
			return false, "not a blank book or disk"
		end
		inv:set_stack("main", slot, stack)
		luabots.give_item(bot, written)
		luabots.mark_dirty(rec.id)
		bot.act(0.5)
		return true
	end, 300)

	-- Library: code on the disks and books of the "disks" slots
	local disks = {}
	env.disks = disks

	local function library()
		local inv = luabots.get_inventory(rec)
		local out = {}
		for i = 1, luabots.INV_SIZES.disks do
			local stack = inv:get_stack("disks", i)
			if not stack:is_empty() then
				local title, text, author = read_book(stack)
				if title then out[#out + 1] = {slot = i, title = title, text = text or "", author = author} end
			end
		end
		return out
	end

	disks.list = wrap("disks.list", function()
		local out = {}
		for i, d in ipairs(library()) do out[i] = {slot = d.slot, title = d.title} end
		return out
	end, 50)

	-- Compile the code of a library disk (by title or slot) for this program
	local load_disk = wrap("disks.load", function(name)
		local found
		if type(name) == "number" then
			local slot = math.floor(util.check_number(name, "slot", 1, luabots.INV_SIZES.disks))
			for _, d in ipairs(library()) do
				if d.slot == slot then found = d end
			end
		else
			util.check_string(name, "name", 80)
			for _, d in ipairs(library()) do
				if d.title == name then found = d break end
			end
		end
		if not found then
			return nil, "no disk called '" .. tostring(name) .. "' in the library slots"
		end
		if bot.full and found.author ~= rec.owner then
			return nil, "disk '" .. tostring(found.title) .. "' was not written by " .. rec.owner
				.. " (full access robots only run their owner's disks)"
		end
		bot.ctx.used = bot.ctx.used + #found.text / 20
		local label = (found.title ~= "" and found.title or tostring(found.slot)):gsub("[^%w_%-%. ]", "_")
		local fn, err = luabots.sandbox.compile(found.text, bot.level, "disk:" .. label)
		if not fn then return nil, "error in disk '" .. label .. "': " .. err end
		setfenv(fn, bot.ctx.env)
		return fn
	end, 100)

	-- disks.run(name, ...): run the code of a disk every time, with arguments errors point to the line of the program that called (level 2)
	function disks.run(name, ...)
		local fn, err = load_disk(name)
		if not fn then error("disks.run: " .. err, 2) end
		return fn(...)
	end

	-- require(name): load a disk once, like a Lua module
	local modules, loading = {}, {}
	function env.require(name)
		local m = modules[name]
		if m ~= nil then return m end
		if loading[name] then error("require: '" .. tostring(name) .. "' requires itself", 2) end
		local fn, err = load_disk(name)
		if not fn then error("require: " .. err, 2) end
		loading[name] = true
		local ok, result = pcall(fn, name)
		loading[name] = nil
		if not ok then error(result, 0) end
		if result == nil then result = true end
		modules[name] = result
		return result
	end
end)